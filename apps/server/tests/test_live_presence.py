"""Live presence that spans both ride phases, and joins that do not wait for
the bulk event batch.

Every test here is written against the field failure in issue #99: a joiner
could see the leader's route but never the leader's advancing position, and the
leader never learned the joiner had joined at all.
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta

from sqlalchemy import func, select

from ride_relay_server.models import PreStartPosition
from ride_relay_server.schemas import PresenceSyncRequest

from .conftest import event, ride_token

SECRET = "0123456789abcdef0123456789abcdef"
LIVE = ["pre-start-presence-v1", "live-presence-v2"]
LEGACY = ["pre-start-presence-v1"]


def _position(latitude: float, *, name: str = "Alex", recorded_at: datetime | None = None) -> dict:
    return {
        "displayName": name,
        "role": "rider",
        "motorcycleStyle": "adventure",
        "riderColor": "blue",
        "sample": {
            "position": {"latitude": latitude, "longitude": -2.4},
            "recordedAt": (recorded_at or datetime.now(UTC)).isoformat().replace("+00:00", "Z"),
            "accuracyMeters": 4,
            "speedMetersPerSecond": 0,
            "headingDegrees": 90,
        },
    }


def _presence(
    client,
    ride_id: str,
    device_id: str,
    *,
    capabilities: list[str] | None = None,
    protocol: str = "1",
    **body,
):
    headers = {
        "authorization": f"Bearer {ride_token(ride_id, SECRET)}",
        "x-ride-relay-device": device_id,
        "x-tailendcharlie-protocol": protocol,
        "x-tailendcharlie-capabilities": ",".join(
            capabilities if capabilities is not None else LIVE
        ),
    }
    return client.post(
        f"/api/v1/rides/{ride_id}/presence:sync",
        json={"protocolVersion": 1, "deviceId": device_id, **body},
        headers=headers,
    )


def _membership_event(ride_id: str, event_id: str, device_id: str, name: str, role: str) -> dict:
    return event(
        ride_id,
        event_id,
        device_id=device_id,
        event_type="riderJoined",
        payload={"displayName": name, "role": role},
    )


def _start(client, synchronize, ride_id: str, device_id: str = "leader"):
    return synchronize(
        client,
        ride_id=ride_id,
        secret=SECRET,
        device_id=device_id,
        events=[
            event(
                ride_id,
                f"{ride_id}-started",
                device_id=device_id,
                event_type="rideStarted",
                payload={"leaderRiderId": device_id},
            )
        ],
    )


def test_presence_survives_the_ride_started_transition(client, synchronize) -> None:
    ride_id = "ride-continuity"
    assert (
        synchronize(client, ride_id=ride_id, secret=SECRET, device_id="leader").status_code == 200
    )
    assert _presence(client, ride_id, "leader", position=_position(51.0, name="Lead")).status_code
    before = _presence(client, ride_id, "rider-a", position=_position(51.5)).json()
    assert {item["riderId"] for item in before["positions"]} == {"leader", "rider-a"}
    assert before["phase"] == "open"

    assert _start(client, synchronize, ride_id).status_code == 200

    after = _presence(client, ride_id, "rider-a", position=_position(51.6)).json()
    assert after["phase"] == "started"
    # No gap and no duplicate identity across the transition.
    assert {item["riderId"] for item in after["positions"]} == {"leader", "rider-a"}
    assert len(after["positions"]) == 2


def test_a_rider_joining_an_already_started_ride_appears_without_a_cursor(
    client, synchronize
) -> None:
    ride_id = "ride-late-join"
    assert (
        synchronize(client, ride_id=ride_id, secret=SECRET, device_id="leader").status_code == 200
    )
    assert (
        synchronize(
            client,
            ride_id=ride_id,
            secret=SECRET,
            device_id="leader",
            events=[_membership_event(ride_id, "created", "leader", "Lead", "lead")],
        ).status_code
        == 200
    )
    assert _start(client, synchronize, ride_id).status_code == 200

    # The joiner uploads only its own membership event.
    assert (
        synchronize(
            client,
            ride_id=ride_id,
            secret=SECRET,
            device_id="rider-late",
            events=[_membership_event(ride_id, "joined-late", "rider-late", "Bill", "rider")],
        ).status_code
        == 200
    )
    assert (
        _presence(client, ride_id, "rider-late", position=_position(51.9, name="Bill")).status_code
        == 200
    )

    # The leader never advances a cursor here: presence alone must reveal both
    # the new member and their live position.
    observed = _presence(client, ride_id, "leader").json()
    members = {item["riderId"]: item for item in observed["members"]}
    assert members["rider-late"]["displayName"] == "Bill"
    assert members["rider-late"]["left"] is False
    assert members["leader"]["displayName"] == "Lead"
    assert {item["riderId"] for item in observed["positions"]} == {"rider-late"}


def test_roster_is_served_even_when_the_event_batch_never_advances(client, synchronize) -> None:
    ride_id = "ride-wedged-batch"
    assert (
        synchronize(client, ride_id=ride_id, secret=SECRET, device_id="leader").status_code == 200
    )
    assert (
        synchronize(
            client,
            ride_id=ride_id,
            secret=SECRET,
            device_id="rider-a",
            events=[_membership_event(ride_id, "joined-a", "rider-a", "Alex", "rider")],
        ).status_code
        == 200
    )

    # A wedged sync is modelled by simply never calling events:sync again.
    observed = _presence(client, ride_id, "leader").json()

    assert [item["riderId"] for item in observed["members"]] == ["rider-a"]


def test_rider_left_marks_the_member_rather_than_hiding_the_history(client, synchronize) -> None:
    ride_id = "ride-left"
    assert (
        synchronize(client, ride_id=ride_id, secret=SECRET, device_id="leader").status_code == 200
    )
    assert (
        synchronize(
            client,
            ride_id=ride_id,
            secret=SECRET,
            device_id="rider-a",
            events=[
                _membership_event(ride_id, "joined-a", "rider-a", "Alex", "rider"),
                event(
                    ride_id,
                    "left-a",
                    device_id="rider-a",
                    event_type="riderLeft",
                    payload={"riderId": "rider-a", "reason": "left"},
                ),
            ],
        ).status_code
        == 200
    )

    members = _presence(client, ride_id, "leader").json()["members"]

    assert len(members) == 1
    assert members[0]["riderId"] == "rider-a"
    assert members[0]["left"] is True


def test_ride_ended_discards_live_positions(client, synchronize) -> None:
    ride_id = "ride-ended-presence"
    assert (
        synchronize(client, ride_id=ride_id, secret=SECRET, device_id="leader").status_code == 200
    )
    assert _presence(client, ride_id, "rider-a", position=_position(51.0)).status_code == 200
    assert (
        synchronize(
            client,
            ride_id=ride_id,
            secret=SECRET,
            device_id="leader",
            events=[
                event(
                    ride_id,
                    "ended",
                    device_id="leader",
                    event_type="rideEnded",
                    payload={},
                )
            ],
        ).status_code
        == 200
    )

    with client.app.state.session_factory() as session:
        assert session.scalar(select(func.count()).select_from(PreStartPosition)) == 0
    observed = _presence(client, ride_id, "leader").json()
    assert observed["positions"] == []
    assert observed["phase"] == "ended"


def test_a_legacy_publisher_stays_visible_to_a_live_presence_peer_and_is_flagged(
    client, synchronize
) -> None:
    """Older client to newer client: the position still arrives, and the newer
    device is told the peer's build is older."""
    ride_id = "ride-mixed-versions"
    assert (
        synchronize(client, ride_id=ride_id, secret=SECRET, device_id="leader").status_code == 200
    )
    assert (
        _presence(
            client, ride_id, "rider-old", capabilities=LEGACY, position=_position(51.3, name="Bill")
        ).status_code
        == 200
    )
    assert (
        _presence(client, ride_id, "leader", position=_position(51.0, name="Lead")).status_code
        == 200
    )
    assert _start(client, synchronize, ride_id).status_code == 200

    observed = _presence(client, ride_id, "leader", position=_position(51.01, name="Lead")).json()

    flags = {item["riderId"]: item["livePresence"] for item in observed["positions"]}
    assert flags["rider-old"] is False
    assert flags["leader"] is True


def test_a_legacy_reader_after_start_does_not_destroy_a_live_peers_position(
    client, synchronize
) -> None:
    ride_id = "ride-legacy-nondestructive"
    assert (
        synchronize(client, ride_id=ride_id, secret=SECRET, device_id="leader").status_code == 200
    )
    assert _presence(client, ride_id, "rider-a", position=_position(51.4)).status_code == 200
    assert _start(client, synchronize, ride_id).status_code == 200

    assert _presence(client, ride_id, "rider-old", capabilities=LEGACY).json()["positions"] == []

    still_there = _presence(client, ride_id, "leader").json()["positions"]
    assert [item["riderId"] for item in still_there] == ["rider-a"]


def test_unknown_capability_strings_are_ignored(client, synchronize) -> None:
    ride_id = "ride-unknown-capability"
    assert (
        synchronize(client, ride_id=ride_id, secret=SECRET, device_id="leader").status_code == 200
    )

    response = _presence(
        client,
        ride_id,
        "rider-a",
        capabilities=[*LIVE, "teleportation-v9", "", "  "],
        position=_position(51.0),
    )

    assert response.status_code == 200
    assert response.json()["members"] == []


def test_presence_requires_at_least_one_presence_capability(client, synchronize) -> None:
    ride_id = "ride-no-capability"
    assert (
        synchronize(client, ride_id=ride_id, secret=SECRET, device_id="leader").status_code == 200
    )

    response = _presence(client, ride_id, "rider-a", capabilities=["ride-start-v1"])

    assert response.status_code == 400
    assert response.json() == {"error": "A live presence capability is required"}


def test_presence_rejects_a_client_below_the_minimum_protocol(client, synchronize) -> None:
    ride_id = "ride-presence-old-client"
    assert (
        synchronize(client, ride_id=ride_id, secret=SECRET, device_id="leader").status_code == 200
    )
    client.app.state.settings.minimum_client_protocol = 2

    response = _presence(client, ride_id, "rider-a", position=_position(51.0))

    assert response.status_code == 426
    assert response.json()["code"] == "update_required"


def test_presence_rejects_a_client_newer_than_the_service(client, synchronize) -> None:
    ride_id = "ride-presence-new-client"
    assert (
        synchronize(client, ride_id=ride_id, secret=SECRET, device_id="leader").status_code == 200
    )

    response = client.post(
        f"/api/v1/rides/{ride_id}/presence:sync",
        json={"protocolVersion": 1, "deviceId": "rider-a"},
        headers={
            "authorization": f"Bearer {ride_token(ride_id, SECRET)}",
            "x-ride-relay-device": "rider-a",
            "x-tailendcharlie-protocol": "2",
            "x-tailendcharlie-capabilities": ",".join(LIVE),
        },
    )

    assert response.status_code == 409
    assert response.json()["code"] == "server_upgrade_required"


def test_a_started_ride_still_expires_a_position_by_ttl(client, synchronize) -> None:
    ride_id = "ride-started-ttl"
    assert (
        synchronize(client, ride_id=ride_id, secret=SECRET, device_id="leader").status_code == 200
    )
    assert _presence(client, ride_id, "rider-a", position=_position(51.0)).status_code == 200
    assert _start(client, synchronize, ride_id).status_code == 200
    ttl = client.app.state.settings.pre_start_presence_ttl_seconds

    service = client.app.state.service
    with client.app.state.session_factory() as session:
        observed = service.synchronize_pre_start_presence(
            session,
            ride_id=ride_id,
            bearer_token=ride_token(ride_id, SECRET),
            device_header="leader",
            request=PresenceSyncRequest(protocolVersion=1, deviceId="leader"),
            live_presence=True,
            now=datetime.now(UTC) + timedelta(seconds=ttl + 1),
        )

    assert observed["positions"] == []
    assert observed["phase"] == "started"


def test_members_are_withheld_from_a_legacy_reader(client, synchronize) -> None:
    ride_id = "ride-legacy-members"
    assert (
        synchronize(client, ride_id=ride_id, secret=SECRET, device_id="leader").status_code == 200
    )
    assert (
        synchronize(
            client,
            ride_id=ride_id,
            secret=SECRET,
            device_id="rider-a",
            events=[_membership_event(ride_id, "joined-a", "rider-a", "Alex", "rider")],
        ).status_code
        == 200
    )

    legacy = _presence(client, ride_id, "leader", capabilities=LEGACY).json()

    assert legacy["members"] == []


def test_a_membership_event_without_a_usable_payload_is_skipped(client, synchronize) -> None:
    ride_id = "ride-bad-membership"
    assert (
        synchronize(client, ride_id=ride_id, secret=SECRET, device_id="leader").status_code == 200
    )
    assert (
        synchronize(
            client,
            ride_id=ride_id,
            secret=SECRET,
            device_id="rider-a",
            events=[
                event(
                    ride_id,
                    "joined-nameless",
                    device_id="rider-a",
                    event_type="riderJoined",
                    payload={"role": "rider"},
                )
            ],
        ).status_code
        == 200
    )

    observed = _presence(client, ride_id, "leader").json()

    assert observed["members"] == []
    assert observed["phase"] == "open"


def test_a_repeated_publish_replaces_rather_than_duplicating(client, synchronize) -> None:
    ride_id = "ride-duplicate-publish"
    assert (
        synchronize(client, ride_id=ride_id, secret=SECRET, device_id="leader").status_code == 200
    )
    body = _position(51.0)

    for _ in range(4):
        assert _presence(client, ride_id, "rider-a", position=body).status_code == 200

    observed = _presence(client, ride_id, "leader").json()["positions"]
    assert len(observed) == 1
    with client.app.state.session_factory() as session:
        assert session.scalar(select(func.count()).select_from(PreStartPosition)) == 1
