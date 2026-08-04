from __future__ import annotations

import base64
import hashlib
import json
from datetime import UTC, datetime, timedelta

from fastapi.testclient import TestClient
from sqlalchemy import event as sqlalchemy_event
from sqlalchemy import func, select

from ride_relay_server.app import create_app
from ride_relay_server.models import Ride, StoredEvent
from ride_relay_server.rate_limit import SlidingWindowRateLimiter
from ride_relay_server.service import purge_expired

from .conftest import ride_token

SECRET = "0123456789abcdef0123456789abcdef"


def test_health_and_metrics_do_not_require_ride_credentials(client) -> None:
    assert client.get("/health/live").json() == {"status": "ok"}
    assert client.get("/health/ready").json() == {"status": "ready"}
    metrics = client.get("/metrics")
    assert metrics.status_code == 200
    assert "ride_relay_sync_requests_total" in metrics.text


def test_rejects_21_event_batch(client, synchronize, make_event) -> None:
    ride_id = "ride-bounds"
    response = synchronize(
        client,
        ride_id=ride_id,
        secret=SECRET,
        events=[make_event(ride_id, f"event-{index}") for index in range(21)],
    )
    assert response.status_code == 400


def test_device_header_must_match_body(client, synchronize) -> None:
    ride_id = "ride-device"
    body = json.dumps(
        {"protocolVersion": 1, "deviceId": "body-device", "cursor": None, "events": []},
        separators=(",", ":"),
    ).encode()
    digest = base64.urlsafe_b64encode(hashlib.sha256(body).digest()).decode().rstrip("=")
    response = client.post(
        f"/api/v1/rides/{ride_id}/events:sync",
        content=body,
        headers={
            "authorization": f"Bearer {ride_token(ride_id, SECRET)}",
            "content-type": "application/json",
            "idempotency-key": f"rr1-{digest}",
            "x-ride-relay-device": "header-device",
        },
    )
    assert response.status_code == 400


def test_streamed_body_limit_cannot_be_bypassed_by_content_length(client) -> None:
    ride_id = "ride-stream-limit"
    body = b"{" + (b" " * (64 * 1024)) + b"}"
    digest = base64.urlsafe_b64encode(hashlib.sha256(body).digest()).decode().rstrip("=")

    response = client.post(
        f"/api/v1/rides/{ride_id}/events:sync",
        content=body,
        headers={
            "authorization": f"Bearer {ride_token(ride_id, SECRET)}",
            "content-length": "1",
            "content-type": "application/json",
            "idempotency-key": f"rr1-{digest}",
            "x-ride-relay-device": "device-a",
        },
    )

    assert response.status_code == 413


def test_non_finite_payload_number_is_rejected(client, synchronize, make_event) -> None:
    ride_id = "ride-nan"
    response = synchronize(
        client,
        ride_id=ride_id,
        secret=SECRET,
        events=[make_event(ride_id, "event-nan", payload={"value": float("nan")})],
    )

    assert response.status_code == 400
    assert "finite" in response.json()["error"].lower()


def test_per_ride_event_quota_is_atomic(settings, synchronize, make_event) -> None:
    bounded = settings.model_copy(update={"maximum_events_per_ride": 100})
    ride_id = "ride-quota"
    with TestClient(create_app(bounded)) as client:
        for batch_index in range(5):
            response = synchronize(
                client,
                ride_id=ride_id,
                secret=SECRET,
                events=[
                    make_event(ride_id, f"event-{batch_index * 20 + index:03d}")
                    for index in range(20)
                ],
            )
            assert response.status_code == 200

        rejected = synchronize(
            client,
            ride_id=ride_id,
            secret=SECRET,
            events=[make_event(ride_id, "event-100")],
        )

    assert rejected.status_code == 413
    assert rejected.json() == {"error": "Ride storage quota exceeded"}


def test_event_upload_query_count_does_not_grow_with_ride_history(
    settings,
    synchronize,
    make_event,
) -> None:
    bounded = settings.model_copy(
        update={
            "maximum_events_per_ride": 5_000,
            "maximum_upload_events": 100,
        }
    )
    ride_id = "ride-query-count"
    with TestClient(create_app(bounded)) as client:
        first = synchronize(
            client,
            ride_id=ride_id,
            secret=SECRET,
            events=[make_event(ride_id, "history-0000")],
        )
        assert first.status_code == 200
        now = datetime.now(UTC)
        cipher = client.app.state.service._cipher
        with client.app.state.session_factory() as session, session.begin():
            ride = session.get(Ride, ride_id)
            assert ride is not None
            rows = []
            total_bytes = 0
            for index in range(1, 4_900):
                event_id = f"history-{index:04d}"
                body_ciphertext = cipher.encrypt_json(
                    make_event(
                        ride_id,
                        event_id,
                        event_type="riderLocationUpdated",
                        created_at=now,
                    ),
                    associated_data=f"event:{ride_id}:{event_id}".encode(),
                )
                total_bytes += len(body_ciphertext)
                rows.append(
                    StoredEvent(
                        ride_id=ride_id,
                        event_id=event_id,
                        device_id="device-a",
                        event_type="riderLocationUpdated",
                        created_at=now,
                        expires_at=now + timedelta(minutes=20),
                        body_hash=hashlib.sha256(event_id.encode()).digest(),
                        body_ciphertext=body_ciphertext,
                    )
                )
            session.add_all(rows)
            ride.stored_event_count += len(rows)
            ride.stored_event_bytes += total_bytes

        ride_event_statements: list[str] = []

        def record_statement(_conn, _cursor, statement, _parameters, _context, _many) -> None:
            if statement.lstrip().upper().startswith("SELECT") and "ride_events" in statement:
                ride_event_statements.append(statement)

        sqlalchemy_event.listen(
            client.app.state.engine,
            "before_cursor_execute",
            record_statement,
        )
        try:
            response = synchronize(
                client,
                ride_id=ride_id,
                secret=SECRET,
                events=[make_event(ride_id, f"latest-{index:03d}") for index in range(100)],
            )
        finally:
            sqlalchemy_event.remove(
                client.app.state.engine,
                "before_cursor_execute",
                record_statement,
            )

        assert response.status_code == 200
        # At the default 5,000-event limit and configurable 100-event batch max:
        # expiry accounting, one bulk identity lookup, and the bounded download.
        # The old path issued 103 ride-event SELECTs here: two full-history
        # aggregates, one bulk identity lookup, and one lookup per upload event.
        assert len(ride_event_statements) <= 3
        with client.app.state.session_factory() as session:
            ride = session.get(Ride, ride_id)
            assert ride is not None
            assert ride.stored_event_count == 5_000
            assert ride.stored_event_bytes == session.scalar(
                select(func.sum(func.length(StoredEvent.body_ciphertext))).where(
                    StoredEvent.ride_id == ride_id
                )
            )


def test_global_expiry_cleanup_decrements_event_usage_counters(
    client,
    synchronize,
    make_event,
) -> None:
    ride_id = "ride-expiry-counters"
    now = datetime.now(UTC)
    assert (
        synchronize(
            client,
            ride_id=ride_id,
            secret=SECRET,
            events=[
                make_event(
                    ride_id,
                    "short-lived",
                    expires_at=now + timedelta(minutes=1),
                )
            ],
        ).status_code
        == 200
    )

    with client.app.state.session_factory() as session:
        purge_expired(session, now=now + timedelta(minutes=2))
    with client.app.state.session_factory() as session:
        ride = session.get(Ride, ride_id)
        assert ride is not None
        assert ride.stored_event_count == 0
        assert ride.stored_event_bytes == 0


def test_rate_limiter_bounds_tracked_identities() -> None:
    limiter = SlidingWindowRateLimiter(
        maximum_requests=10,
        window_seconds=60,
        maximum_keys=2,
    )

    assert limiter.check("first") is None
    assert limiter.check("second") is None
    assert limiter.check("third") == 60


def test_active_ride_capacity_rejects_new_claims(settings, synchronize) -> None:
    bounded = settings.model_copy(update={"maximum_active_rides": 1})
    with TestClient(create_app(bounded)) as client:
        assert synchronize(client, ride_id="ride-first", secret=SECRET).status_code == 200
        rejected = synchronize(client, ride_id="ride-second", secret=SECRET)

    assert rejected.status_code == 503
    assert rejected.json() == {"error": "Relay ride capacity reached"}


def test_per_ride_replay_quota_is_atomic(settings, synchronize, make_event) -> None:
    bounded = settings.model_copy(update={"maximum_replays_per_ride": 1})
    ride_id = "ride-replay-quota"
    # Only an upload is replay-protected, so only an upload consumes the quota.
    with TestClient(create_app(bounded)) as client:
        assert (
            synchronize(
                client,
                ride_id=ride_id,
                secret=SECRET,
                events=[make_event(ride_id, "event-a")],
            ).status_code
            == 200
        )
        rejected = synchronize(
            client,
            ride_id=ride_id,
            secret=SECRET,
            device_id="device-b",
            events=[make_event(ride_id, "event-b", device_id="device-b")],
        )

    assert rejected.status_code == 413
    assert rejected.json() == {"error": "Ride replay quota exceeded"}


def test_rate_limit_returns_bounded_retry_after(settings, synchronize) -> None:
    limited = settings.model_copy(update={"rate_limit_requests": 2})
    with TestClient(create_app(limited)) as client:
        assert synchronize(client, ride_id="ride-rate", secret=SECRET).status_code == 200
        assert (
            synchronize(
                client, ride_id="ride-rate", secret=SECRET, device_id="device-b"
            ).status_code
            == 200
        )
        response = synchronize(client, ride_id="ride-rate", secret=SECRET, device_id="device-c")
    assert response.status_code == 429
    assert 1 <= int(response.headers["retry-after"]) <= 300
