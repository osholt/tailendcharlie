from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime, timedelta

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select
from sqlalchemy.orm import Session

from ride_relay_server.app import create_app
from ride_relay_server.models import ObserverGrant
from ride_relay_server.observer import get_managed_observer_grant
from ride_relay_server.service import RelayServiceError

from .conftest import event, ride_token, sync_request

SECRET = "observer-test-secret-0123456789"


def _create_ride(client, ride_id: str, events: list[dict] | None = None) -> None:
    response = sync_request(
        client,
        ride_id=ride_id,
        secret=SECRET,
        events=events or [event(ride_id, "ride-created")],
    )
    assert response.status_code == 200


def _create_grant(client, ride_id: str, device_header: str = "rider-a"):
    return client.post(
        f"/api/v1/rides/{ride_id}/observer-grants",
        headers={
            "authorization": f"Bearer {ride_token(ride_id, SECRET)}",
            # Deliberately irrelevant: the relay must not use this spoofable
            # group header to select observer data or grant ownership.
            "x-ride-relay-device": device_header,
        },
        json={
            "label": "Home contact",
            "durationMinutes": 60,
            "consentConfirmed": True,
        },
    )


def _authorization(token: str) -> dict[str, str]:
    return {"authorization": f"Bearer {token}"}


def _snapshot(
    now: datetime,
    *,
    snapshot_at: datetime | None = None,
    status_at: datetime | None = None,
    position_at: datetime | None = None,
    assistance_at: datetime | None = None,
    latitude: float = 51.5074,
    assistance: str | None = "assistance",
) -> dict:
    status_at = status_at or now
    position_at = position_at or now
    assistance_at = assistance_at or now
    return {
        "subjectName": "Oliver",
        "snapshotGeneratedAt": (snapshot_at or now).isoformat(),
        "rideStatus": "active",
        "statusUpdatedAt": status_at.isoformat(),
        "position": {
            "latitude": latitude,
            "longitude": -0.1278,
            "accuracyMeters": 7.5,
            "recordedAt": position_at.isoformat(),
        },
        "assistanceUpdatedAt": assistance_at.isoformat(),
        "assistance": (
            {"kind": assistance, "reportedAt": assistance_at.isoformat()}
            if assistance is not None
            else None
        ),
    }


def test_header_spoof_cannot_expose_another_riders_stored_events(client) -> None:
    ride_id = "ride-observer-header-spoof"
    now = datetime.now(UTC)
    _create_ride(
        client,
        ride_id,
        [
            event(ride_id, "created", device_id="rider-a"),
            event(
                ride_id,
                "victim-location",
                device_id="victim-rider",
                event_type="riderLocationUpdated",
                payload={
                    "location": {
                        "riderId": "victim-rider",
                        "displayName": "Must not leak",
                        "role": "rider",
                        "sample": {
                            "position": {"latitude": 52.0, "longitude": -2.0},
                            "recordedAt": now.isoformat(),
                            "accuracyMeters": 4.0,
                            "speedMetersPerSecond": 10.0,
                            "headingDegrees": 90.0,
                        },
                        "receivedAt": now.isoformat(),
                        "motorcycleStyle": "sport",
                        "riderColor": "red",
                    }
                },
                expires_at=now + timedelta(minutes=30),
            ),
        ],
    )

    created = _create_grant(client, ride_id, device_header="victim-rider")
    assert created.status_code == 201
    grant = created.json()
    unread = client.get(
        f"/api/v1/observer-grants/{grant['id']}",
        headers=_authorization(grant["observerToken"]),
    )
    assert unread.status_code == 200
    assert unread.json()["position"] is None
    assert unread.json()["subjectName"] is None
    assert "Must not leak" not in unread.text
    assert "victim-rider" not in unread.text
    assert ride_id not in unread.text


def test_independent_publisher_supplies_only_the_minimized_snapshot(client) -> None:
    ride_id = "ride-observer-publish"
    now = datetime.now(UTC)
    _create_ride(client, ride_id)
    created = _create_grant(client, ride_id)
    assert created.status_code == 201
    grant = created.json()

    published = client.put(
        f"/api/v1/observer-grants/{grant['id']}/snapshot",
        headers=_authorization(grant["publisherToken"]),
        json=_snapshot(now),
    )
    assert published.status_code == 204

    observed = client.get(
        f"/api/v1/observer-grants/{grant['id']}",
        headers=_authorization(grant["observerToken"]),
    )
    assert observed.status_code == 200
    body = observed.json()
    assert body["subjectName"] == "Oliver"
    assert body["rideStatus"] == "active"
    assert body["freshness"] == "fresh"
    assert body["position"]["latitude"] == 51.5074
    assert body["assistance"]["kind"] == "assistance"
    assert ride_id not in observed.text


def test_tokens_are_hash_only_and_role_separated(client) -> None:
    ride_id = "ride-observer-token-boundary"
    _create_ride(client, ride_id)
    created = _create_grant(client, ride_id)
    assert created.status_code == 201
    grant = created.json()
    tokens = {
        grant["managementToken"],
        grant["publisherToken"],
        grant["observerToken"],
    }
    assert len(tokens) == 3
    assert grant["managementToken"].startswith("om1_")
    assert grant["publisherToken"].startswith("op1_")
    assert grant["observerToken"].startswith("ro1_")

    with Session(client.app.state.engine) as session:
        stored = session.scalar(select(ObserverGrant))
        assert stored is not None
        stored_values = {
            stored.management_token_hash,
            stored.publisher_token_hash,
            stored.observer_token_hash,
        }
        assert len(stored_values) == 3
        for token in tokens:
            assert all(token.encode() not in value for value in stored_values)

    read_with_publisher = client.get(
        f"/api/v1/observer-grants/{grant['id']}",
        headers=_authorization(grant["publisherToken"]),
    )
    publish_with_observer = client.put(
        f"/api/v1/observer-grants/{grant['id']}/snapshot",
        headers=_authorization(grant["observerToken"]),
        json=_snapshot(datetime.now(UTC)),
    )
    manage_with_read = client.get(
        f"/api/v1/observer-grants/{grant['id']}/management",
        headers=_authorization(grant["observerToken"]),
    )
    sync_with_observer = sync_request(
        client,
        ride_id=ride_id,
        secret=SECRET,
        token=grant["observerToken"],
    )
    assert read_with_publisher.status_code == 404
    assert publish_with_observer.status_code == 404
    assert manage_with_read.status_code == 404
    assert sync_with_observer.status_code == 401


def test_management_secret_reviews_and_revokes_all_access(client) -> None:
    ride_id = "ride-observer-revoke"
    _create_ride(client, ride_id)
    created = _create_grant(client, ride_id)
    assert created.status_code == 201
    grant = created.json()

    managed = client.get(
        f"/api/v1/observer-grants/{grant['id']}/management",
        headers=_authorization(grant["managementToken"]),
    )
    assert managed.status_code == 200
    assert managed.json()["label"] == "Home contact"
    assert "managementToken" not in managed.text
    assert (
        client.put(
            f"/api/v1/observer-grants/{grant['id']}/snapshot",
            headers=_authorization(grant["publisherToken"]),
            json=_snapshot(datetime.now(UTC)),
        ).status_code
        == 204
    )

    # A shared ride bearer plus a spoofed device header is not a management
    # credential and cannot revoke the grant.
    spoofed = client.delete(
        f"/api/v1/observer-grants/{grant['id']}/management",
        headers={
            "authorization": f"Bearer {ride_token(ride_id, SECRET)}",
            "x-ride-relay-device": "rider-a",
        },
    )
    assert spoofed.status_code == 404

    revoked = client.delete(
        f"/api/v1/observer-grants/{grant['id']}/management",
        headers=_authorization(grant["managementToken"]),
    )
    assert revoked.status_code == 204
    with Session(client.app.state.engine) as session:
        stored = session.get(ObserverGrant, grant["id"])
        assert stored is not None
        assert stored.snapshot_ciphertext is None
        assert stored.snapshot_version_at is None

    for path, token, method in (
        (f"/api/v1/observer-grants/{grant['id']}", grant["observerToken"], "get"),
        (
            f"/api/v1/observer-grants/{grant['id']}/management",
            grant["managementToken"],
            "get",
        ),
        (
            f"/api/v1/observer-grants/{grant['id']}/snapshot",
            grant["publisherToken"],
            "put",
        ),
    ):
        response = getattr(client, method)(
            path,
            headers=_authorization(token),
            **({"json": _snapshot(datetime.now(UTC))} if method == "put" else {}),
        )
        assert response.status_code == 404


def test_consent_and_bounded_duration_are_required(client) -> None:
    ride_id = "ride-observer-consent"
    _create_ride(client, ride_id)
    headers = {"authorization": f"Bearer {ride_token(ride_id, SECRET)}"}
    missing_consent = client.post(
        f"/api/v1/rides/{ride_id}/observer-grants",
        headers=headers,
        json={"label": "Home", "durationMinutes": 60},
    )
    too_long = client.post(
        f"/api/v1/rides/{ride_id}/observer-grants",
        headers=headers,
        json={
            "label": "Home",
            "durationMinutes": 24 * 60 + 1,
            "consentConfirmed": True,
        },
    )
    assert missing_consent.status_code == 400
    assert too_long.status_code == 400


def test_bad_or_missing_observer_credentials_are_indistinguishable(client) -> None:
    path = "/api/v1/observer-grants/00000000-0000-0000-0000-000000000000"
    missing = client.get(path)
    malformed = client.get(
        path,
        headers={"authorization": "Bearer not-an-observer-token"},
    )
    assert missing.status_code == 404
    assert malformed.status_code == 404
    assert missing.json() == malformed.json() == {"error": "Observer access is unavailable"}
    with Session(client.app.state.engine) as session:
        with pytest.raises(RelayServiceError) as caught:
            get_managed_observer_grant(
                session,
                grant_id="00000000-0000-0000-0000-000000000000",
                management_token="om1_\N{SNOWMAN}",
            )
    assert caught.value.status_code == 404


def test_naive_snapshot_timestamps_are_rejected_without_a_server_error(client) -> None:
    ride_id = "ride-observer-naive-time"
    _create_ride(client, ride_id)
    grant = _create_grant(client, ride_id).json()
    snapshot = _snapshot(datetime.now(UTC))
    snapshot["snapshotGeneratedAt"] = "2026-07-24T12:00:00"

    response = client.put(
        f"/api/v1/observer-grants/{grant['id']}/snapshot",
        headers=_authorization(grant["publisherToken"]),
        json=snapshot,
    )

    assert response.status_code == 400
    assert response.json() == {"error": "Malformed request"}


def test_tokens_cannot_cross_grants(client) -> None:
    ride_id = "ride-observer-cross-grant"
    _create_ride(client, ride_id)
    first = _create_grant(client, ride_id).json()
    second = _create_grant(client, ride_id).json()

    assert (
        client.get(
            f"/api/v1/observer-grants/{second['id']}",
            headers=_authorization(first["observerToken"]),
        ).status_code
        == 404
    )
    assert (
        client.put(
            f"/api/v1/observer-grants/{second['id']}/snapshot",
            headers=_authorization(first["publisherToken"]),
            json=_snapshot(datetime.now(UTC)),
        ).status_code
        == 404
    )
    assert (
        client.delete(
            f"/api/v1/observer-grants/{second['id']}/management",
            headers=_authorization(first["managementToken"]),
        ).status_code
        == 404
    )


def test_expired_grant_denies_all_roles(client) -> None:
    ride_id = "ride-observer-expired"
    _create_ride(client, ride_id)
    grant = _create_grant(client, ride_id).json()
    with Session(client.app.state.engine) as session, session.begin():
        stored = session.get(ObserverGrant, grant["id"])
        assert stored is not None
        stored.expires_at = datetime.now(UTC) - timedelta(seconds=1)

    assert (
        client.get(
            f"/api/v1/observer-grants/{grant['id']}",
            headers=_authorization(grant["observerToken"]),
        ).status_code
        == 404
    )
    assert (
        client.get(
            f"/api/v1/observer-grants/{grant['id']}/management",
            headers=_authorization(grant["managementToken"]),
        ).status_code
        == 404
    )
    assert (
        client.put(
            f"/api/v1/observer-grants/{grant['id']}/snapshot",
            headers=_authorization(grant["publisherToken"]),
            json=_snapshot(datetime.now(UTC)),
        ).status_code
        == 404
    )


def test_new_status_cannot_roll_back_an_existing_position(client) -> None:
    ride_id = "ride-observer-monotonic-components"
    base = datetime.now(UTC) - timedelta(minutes=1)
    _create_ride(client, ride_id)
    grant = _create_grant(client, ride_id).json()
    path = f"/api/v1/observer-grants/{grant['id']}/snapshot"
    first = _snapshot(
        base,
        snapshot_at=base + timedelta(seconds=10),
        status_at=base + timedelta(seconds=10),
        position_at=base + timedelta(seconds=10),
        assistance_at=base + timedelta(seconds=10),
        latitude=51.5,
    )
    second = _snapshot(
        base,
        snapshot_at=base + timedelta(seconds=20),
        status_at=base + timedelta(seconds=20),
        position_at=base + timedelta(seconds=5),
        assistance_at=base + timedelta(seconds=20),
        latitude=40.0,
        assistance=None,
    )
    assert (
        client.put(
            path,
            headers=_authorization(grant["publisherToken"]),
            json=first,
        ).status_code
        == 204
    )
    assert (
        client.put(
            path,
            headers=_authorization(grant["publisherToken"]),
            json=second,
        ).status_code
        == 204
    )

    body = client.get(
        f"/api/v1/observer-grants/{grant['id']}",
        headers=_authorization(grant["observerToken"]),
    ).json()
    assert body["position"]["latitude"] == 51.5
    assert datetime.fromisoformat(body["statusUpdatedAt"].replace("Z", "+00:00")) == (
        base + timedelta(seconds=20)
    )
    assert body["assistance"] is None


def test_concurrent_creation_cannot_exceed_the_ride_cap(client) -> None:
    ride_id = "ride-observer-create-cap"
    _create_ride(client, ride_id)
    client.app.state.settings.maximum_observer_grants_per_ride = 1

    with ThreadPoolExecutor(max_workers=2) as executor:
        responses = list(executor.map(lambda _: _create_grant(client, ride_id), range(2)))

    assert sorted(response.status_code for response in responses) == [201, 409]
    with Session(client.app.state.engine) as session:
        assert (
            session.scalar(select(ObserverGrant).where(ObserverGrant.ride_id == ride_id))
            is not None
        )
        assert (
            len(
                session.scalars(select(ObserverGrant).where(ObserverGrant.ride_id == ride_id)).all()
            )
            == 1
        )


def test_revoke_wins_final_state_against_an_in_flight_publish(client) -> None:
    ride_id = "ride-observer-revoke-race"
    _create_ride(client, ride_id)
    grant = _create_grant(client, ride_id).json()
    snapshot = _snapshot(datetime.now(UTC))

    def publish():
        return client.put(
            f"/api/v1/observer-grants/{grant['id']}/snapshot",
            headers=_authorization(grant["publisherToken"]),
            json=snapshot,
        )

    def revoke():
        return client.delete(
            f"/api/v1/observer-grants/{grant['id']}/management",
            headers=_authorization(grant["managementToken"]),
        )

    with ThreadPoolExecutor(max_workers=2) as executor:
        publish_result = executor.submit(publish)
        revoke_result = executor.submit(revoke)
        responses = [publish_result.result(), revoke_result.result()]

    assert responses[1].status_code == 204
    assert responses[0].status_code in {204, 404}
    with Session(client.app.state.engine) as session:
        stored = session.get(ObserverGrant, grant["id"])
        assert stored is not None
        assert stored.revoked_at is not None
        assert stored.snapshot_ciphertext is None
        assert stored.snapshot_version_at is None


def test_shared_ip_does_not_consume_other_grants_token_budget(settings) -> None:
    settings.observer_read_rate_limit_requests = 10
    settings.observer_ip_abuse_rate_limit_requests = 100
    with TestClient(create_app(settings)) as client:
        ride_id = "ride-observer-cgnat"
        _create_ride(client, ride_id)
        first = _create_grant(client, ride_id).json()
        second = _create_grant(client, ride_id).json()

        for grant in (first, second):
            for _ in range(10):
                response = client.get(
                    f"/api/v1/observer-grants/{grant['id']}",
                    headers=_authorization(grant["observerToken"]),
                )
                assert response.status_code == 200

        limited = client.get(
            f"/api/v1/observer-grants/{first['id']}",
            headers=_authorization(first["observerToken"]),
        )
        assert limited.status_code == 429


def test_shared_ip_does_not_consume_other_rides_creation_budget(settings) -> None:
    settings.observer_create_rate_limit_requests = 2
    settings.observer_create_ip_abuse_rate_limit_requests = 100
    with TestClient(create_app(settings)) as client:
        first_ride = "ride-observer-create-cgnat-a"
        second_ride = "ride-observer-create-cgnat-b"
        _create_ride(client, first_ride)
        _create_ride(client, second_ride)

        for ride_id in (first_ride, second_ride):
            for _ in range(2):
                assert _create_grant(client, ride_id).status_code == 201

        limited = _create_grant(client, first_ride)
        assert limited.status_code == 429
        assert limited.json() == {"error": "Observer creation rate limit exceeded"}


def test_malformed_ride_secret_does_not_consume_creation_budgets(settings) -> None:
    settings.observer_create_rate_limit_requests = 1
    settings.observer_create_ip_abuse_rate_limit_requests = 100
    with TestClient(create_app(settings)) as client:
        ride_id = "ride-observer-create-malformed"
        _create_ride(client, ride_id)
        path = f"/api/v1/rides/{ride_id}/observer-grants"
        payload = {
            "label": "Home contact",
            "durationMinutes": 60,
            "consentConfirmed": True,
        }
        for malformed in ("not-a-token", "rr1_too-short"):
            response = client.post(
                path,
                headers={"authorization": f"Bearer {malformed}"},
                json=payload,
            )
            assert response.status_code == 401

        assert _create_grant(client, ride_id).status_code == 201
        assert _create_grant(client, ride_id).status_code == 429
