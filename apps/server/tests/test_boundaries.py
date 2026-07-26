from __future__ import annotations

import base64
import hashlib
import json

from fastapi.testclient import TestClient

from ride_relay_server.app import create_app
from ride_relay_server.rate_limit import SlidingWindowRateLimiter

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
