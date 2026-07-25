from __future__ import annotations

from datetime import UTC, datetime, timedelta

from sqlalchemy import func, select

from ride_relay_server.crypto import CursorCodec, DataCipher
from ride_relay_server.models import PreStartPosition, StoredEvent
from ride_relay_server.schemas import PresenceSyncRequest
from ride_relay_server.service import RelayService

from .conftest import event, ride_token

SECRET = "0123456789abcdef0123456789abcdef"


def _position(latitude: float) -> dict:
    return {
        "displayName": "Alex",
        "role": "rider",
        "motorcycleStyle": "adventure",
        "riderColor": "blue",
        "sample": {
            "position": {"latitude": latitude, "longitude": -2.4},
            "recordedAt": datetime.now(UTC).isoformat().replace("+00:00", "Z"),
            "accuracyMeters": 4,
            "speedMetersPerSecond": 0,
            "headingDegrees": 90,
        },
    }


def _presence(client, ride_id: str, device_id: str, **body):
    return client.post(
        f"/api/v1/rides/{ride_id}/presence:sync",
        json={"protocolVersion": 1, "deviceId": device_id, **body},
        headers={
            "authorization": f"Bearer {ride_token(ride_id, SECRET)}",
            "x-ride-relay-device": device_id,
            "x-tailendcharlie-protocol": "1",
            "x-tailendcharlie-capabilities": "pre-start-presence-v1",
        },
    )


def test_presence_replaces_latest_position_without_storing_events(client, synchronize) -> None:
    ride_id = "ride-presence"
    assert synchronize(client, ride_id=ride_id, secret=SECRET).status_code == 200

    first = _presence(client, ride_id, "rider-a", position=_position(51.0))
    second = _presence(client, ride_id, "rider-a", position=_position(51.1))
    observed = _presence(client, ride_id, "leader")

    assert first.status_code == 200
    assert second.status_code == 200
    positions = observed.json()["positions"]
    assert len(positions) == 1
    assert positions[0]["riderId"] == "rider-a"
    assert positions[0]["sample"]["position"]["latitude"] == 51.1
    with client.app.state.session_factory() as session:
        assert session.scalar(select(func.count(StoredEvent.sequence))) == 0
        assert session.scalar(select(func.count()).select_from(PreStartPosition)) == 1


def test_presence_is_shared_between_relay_processes(client, settings, synchronize) -> None:
    ride_id = "ride-presence-shared"
    assert synchronize(client, ride_id=ride_id, secret=SECRET).status_code == 200
    assert _presence(client, ride_id, "rider-a", position=_position(51.2)).status_code == 200

    second_process = RelayService(
        settings,
        DataCipher(settings.decoded_key("data_encryption_key")),
        CursorCodec(settings.decoded_key("cursor_signing_key")),
    )
    with client.app.state.session_factory() as session:
        observed = second_process.synchronize_pre_start_presence(
            session,
            ride_id=ride_id,
            bearer_token=ride_token(ride_id, SECRET),
            device_header="leader",
            request=PresenceSyncRequest(
                protocolVersion=1,
                deviceId="leader",
            ),
        )

    assert len(observed["positions"]) == 1
    assert observed["positions"][0]["riderId"] == "rider-a"
    assert observed["positions"][0]["sample"]["position"]["latitude"] == 51.2


def test_presence_expires_and_clears_when_the_ride_starts(client, synchronize) -> None:
    ride_id = "ride-presence-lifecycle"
    assert synchronize(client, ride_id=ride_id, secret=SECRET).status_code == 200
    assert _presence(client, ride_id, "rider-a", position=_position(51.0)).json()["positions"]

    service = client.app.state.service
    with client.app.state.session_factory() as session:
        expired = service.synchronize_pre_start_presence(
            session,
            ride_id=ride_id,
            bearer_token=ride_token(ride_id, SECRET),
            device_header="leader",
            request=PresenceSyncRequest(
                protocolVersion=1,
                deviceId="leader",
            ),
            now=datetime.now(UTC)
            + timedelta(seconds=client.app.state.settings.pre_start_presence_ttl_seconds + 1),
        )
    assert expired["positions"] == []

    assert _presence(client, ride_id, "rider-a", position=_position(51.0)).status_code == 200
    started = event(
        ride_id,
        "ride-started",
        event_type="rideStarted",
        payload={"leaderRiderId": "leader"},
    )
    assert (
        synchronize(
            client,
            ride_id=ride_id,
            secret=SECRET,
            device_id="leader",
            events=[started],
        ).status_code
        == 200
    )
    with client.app.state.session_factory() as session:
        assert session.scalar(select(func.count()).select_from(PreStartPosition)) == 0
    assert _presence(client, ride_id, "leader").json()["positions"] == []


def test_presence_requires_matching_authenticated_device(client, synchronize) -> None:
    ride_id = "ride-presence-auth"
    assert synchronize(client, ride_id=ride_id, secret=SECRET).status_code == 200

    response = client.post(
        f"/api/v1/rides/{ride_id}/presence:sync",
        json={"protocolVersion": 1, "deviceId": "rider-a"},
        headers={
            "authorization": f"Bearer {ride_token(ride_id, SECRET)}",
            "x-ride-relay-device": "rider-b",
        },
    )

    assert response.status_code == 400
