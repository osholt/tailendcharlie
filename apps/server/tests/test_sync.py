from __future__ import annotations

from datetime import UTC, datetime, timedelta

from sqlalchemy import select

from ride_relay_server.models import Ride, StoredEvent
from ride_relay_server.service import purge_expired

from .conftest import ride_token

SECRET = "0123456789abcdef0123456789abcdef"


def test_token_matches_mobile_golden_vector() -> None:
    assert ride_token("ride/alpha", SECRET) == ("rr1_uXTs1vSdBpQTOadPV9VW51wrlt2Cf6E-aaolArBPAac")


def test_first_sync_claims_ride_and_another_device_receives_event(
    client, synchronize, make_event
) -> None:
    ride_id = "ride-alpha"
    uploaded = make_event(ride_id, "event-1")

    first = synchronize(
        client,
        ride_id=ride_id,
        secret=SECRET,
        events=[uploaded],
    )

    assert first.status_code == 200
    assert first.json()["acceptedEventIds"] == ["event-1"]
    assert first.json()["events"] == [uploaded]

    second = synchronize(
        client,
        ride_id=ride_id,
        secret=SECRET,
        device_id="device-b",
    )
    assert second.status_code == 200
    assert second.json()["events"] == [uploaded]


def test_ice_info_shared_event_is_accepted_and_relayed(client, synchronize, make_event) -> None:
    ride_id = "ride-ice"
    shared = make_event(
        ride_id,
        "event-ice-1",
        event_type="iceInfoShared",
        payload={"contactName": "A", "contactPhone": "555", "medicalNotes": ""},
    )

    uploaded = synchronize(client, ride_id=ride_id, secret=SECRET, events=[shared])
    assert uploaded.status_code == 200
    assert uploaded.json()["acceptedEventIds"] == ["event-ice-1"]

    downloaded = synchronize(client, ride_id=ride_id, secret=SECRET, device_id="device-b")
    assert downloaded.status_code == 200
    assert downloaded.json()["events"] == [shared]


def test_ride_start_event_is_accepted_and_relayed(client, synchronize, make_event) -> None:
    ride_id = "ride-start"
    started = make_event(
        ride_id,
        "event-started",
        event_type="rideStarted",
        payload={"leaderRiderId": "device-a", "leaderDisplayName": "Lead"},
    )

    uploaded = synchronize(client, ride_id=ride_id, secret=SECRET, events=[started])
    assert uploaded.status_code == 200
    assert uploaded.json()["acceptedEventIds"] == ["event-started"]

    downloaded = synchronize(client, ride_id=ride_id, secret=SECRET, device_id="device-b")
    assert downloaded.status_code == 200
    assert downloaded.json()["events"] == [started]


def test_membership_and_route_events_are_accepted_and_relayed(
    client, synchronize, make_event
) -> None:
    ride_id = "ride-group-state"
    shared = [
        make_event(ride_id, "event-left", event_type="riderLeft"),
        make_event(ride_id, "event-route-chunk", event_type="routeRevisionChunk"),
        make_event(
            ride_id,
            "event-route-published",
            event_type="routeRevisionPublished",
        ),
        make_event(ride_id, "event-route-cleared", event_type="routeCleared"),
    ]

    uploaded = synchronize(client, ride_id=ride_id, secret=SECRET, events=shared)
    assert uploaded.status_code == 200
    assert uploaded.json()["acceptedEventIds"] == [event["id"] for event in shared]

    downloaded = synchronize(client, ride_id=ride_id, secret=SECRET, device_id="device-b")
    assert downloaded.status_code == 200
    assert downloaded.json()["events"] == shared


def test_wrong_credential_cannot_read_claimed_ride(client, synchronize) -> None:
    ride_id = "ride-private"
    assert synchronize(client, ride_id=ride_id, secret=SECRET).status_code == 200

    rejected = synchronize(
        client,
        ride_id=ride_id,
        secret="fedcba9876543210fedcba9876543210",
        device_id="intruder",
    )
    assert rejected.status_code == 403
    assert rejected.json() == {"error": "Ride credential rejected"}


def test_idempotency_replays_exact_original_response(client, synchronize, make_event) -> None:
    ride_id = "ride-replay"
    first_event = make_event(ride_id, "event-1")
    first = synchronize(client, ride_id=ride_id, secret=SECRET, events=[first_event])

    synchronize(
        client,
        ride_id=ride_id,
        secret=SECRET,
        device_id="device-b",
        events=[make_event(ride_id, "event-2", device_id="device-b")],
    )
    replay = synchronize(client, ride_id=ride_id, secret=SECRET, events=[first_event])

    assert replay.content == first.content


def test_conflicting_event_identity_is_rejected_atomically(client, synchronize, make_event) -> None:
    ride_id = "ride-conflict"
    original = make_event(ride_id, "event-1", payload={"value": 1})
    assert synchronize(client, ride_id=ride_id, secret=SECRET, events=[original]).status_code == 200

    conflict = make_event(ride_id, "event-1", payload={"value": 2})
    response = synchronize(client, ride_id=ride_id, secret=SECRET, events=[conflict])

    assert response.status_code == 409
    assert "conflict" in response.json()["error"].lower()


def test_cursor_paginates_without_skipping_101_events(client, synchronize, make_event) -> None:
    ride_id = "ride-pages"
    for batch_index in range(6):
        batch = [
            make_event(
                ride_id,
                f"event-{batch_index * 20 + index:03d}",
                device_id="uploader",
            )
            for index in range(20)
            if batch_index * 20 + index < 101
        ]
        response = synchronize(
            client,
            ride_id=ride_id,
            secret=SECRET,
            device_id="uploader",
            events=batch,
        )
        assert response.status_code == 200

    page_one = synchronize(
        client,
        ride_id=ride_id,
        secret=SECRET,
        device_id="reader",
    )
    page_two = synchronize(
        client,
        ride_id=ride_id,
        secret=SECRET,
        device_id="reader",
        cursor=page_one.json()["cursor"],
    )

    assert len(page_one.json()["events"]) == 100
    assert len(page_two.json()["events"]) == 1
    assert {event["id"] for event in page_one.json()["events"] + page_two.json()["events"]} == {
        f"event-{index:03d}" for index in range(101)
    }


def test_expired_event_is_acknowledged_but_not_relayed(client, synchronize, make_event) -> None:
    ride_id = "ride-expired"
    expired = make_event(
        ride_id,
        "event-old",
        expires_at=datetime.now(UTC) - timedelta(seconds=1),
    )
    response = synchronize(client, ride_id=ride_id, secret=SECRET, events=[expired])

    assert response.status_code == 200
    assert response.json()["acceptedEventIds"] == ["event-old"]
    assert response.json()["events"] == []


def test_events_are_encrypted_at_rest(client, settings, synchronize, make_event) -> None:
    ride_id = "ride-encrypted"
    synchronize(
        client,
        ride_id=ride_id,
        secret=SECRET,
        events=[make_event(ride_id, "event-secret", payload={"latitude": 51.5})],
    )
    factory = client.app.state.session_factory
    with factory() as session:
        stored = session.scalar(select(StoredEvent).where(StoredEvent.ride_id == ride_id))
        assert stored is not None
        assert b"latitude" not in stored.body_ciphertext
        assert b"51.5" not in stored.body_ciphertext


def test_tampered_cursor_is_rejected(client, synchronize, make_event) -> None:
    ride_id = "ride-cursor"
    first = synchronize(
        client,
        ride_id=ride_id,
        secret=SECRET,
        events=[make_event(ride_id, "event-1")],
    )
    cursor = first.json()["cursor"]
    tampered = f"{cursor[:-1]}{'A' if cursor[-1] != 'A' else 'B'}"

    response = synchronize(
        client,
        ride_id=ride_id,
        secret=SECRET,
        device_id="reader",
        cursor=tampered,
    )

    assert response.status_code == 400
    assert response.json() == {"error": "Invalid cursor"}


def test_future_event_is_rejected(client, synchronize, make_event) -> None:
    ride_id = "ride-future"
    response = synchronize(
        client,
        ride_id=ride_id,
        secret=SECRET,
        events=[
            make_event(
                ride_id,
                "event-future",
                created_at=datetime.now(UTC) + timedelta(minutes=11),
            )
        ],
    )

    assert response.status_code == 400
    assert "future" in response.json()["error"].lower()


def test_ride_end_shortens_retention_and_cleanup_deletes_ride(
    client, settings, synchronize, make_event
) -> None:
    ride_id = "ride-ended"
    before = datetime.now(UTC)
    response = synchronize(
        client,
        ride_id=ride_id,
        secret=SECRET,
        events=[make_event(ride_id, "event-ended", event_type="rideEnded")],
    )
    assert response.status_code == 200

    factory = client.app.state.session_factory
    with factory() as session:
        ride = session.get(Ride, ride_id)
        assert ride is not None
        delete_after = ride.delete_after.replace(tzinfo=UTC)
        assert before + timedelta(hours=23) < delete_after
        assert delete_after < before + timedelta(hours=25)

    with factory() as session:
        purge_expired(session, now=before + timedelta(hours=25))
    with factory() as session:
        assert session.get(Ride, ride_id) is None
