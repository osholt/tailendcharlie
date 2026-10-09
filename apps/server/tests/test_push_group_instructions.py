"""Push for the one-tap alert (#849) and the leader's broadcasts (#854), per #881.

Both travel as ordinary journal events, so the relay learns of them only through
its push classifier. These tests pin what it recognises, who is told, how
urgently, in what words, and what an older app build is handed.
"""

from __future__ import annotations

import base64
import json
from datetime import UTC, datetime, timedelta

import httpx
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec, rsa
from pydantic import SecretStr
from sqlalchemy import func, select

from ride_relay_server.models import PushDelivery, RideMember
from ride_relay_server.push import (
    LEADER_BROADCAST_TEXT,
    ApnsPushProvider,
    FcmPushProvider,
    PushMessage,
    classify_push_event,
)

from .conftest import event as make_event_dict
from .test_push import SECRET, _RecordingProvider, _register

NOW = datetime(2026, 10, 9, 12, 0, 0, tzinfo=UTC)
RIDE = "ride-instructions"


def _broadcast(kind: str = "pullOver", **overrides):
    values = {
        "event_id": "broadcast-1",
        "device_id": "lead",
        "event_type": "statusMessage",
        "payload": {
            "message": kind,
            "label": "Oliver's own words",
            "senderDisplayName": "Oliver",
            "position": {"latitude": 51.5, "longitude": -0.12},
        },
        "created_at": NOW,
    }
    values.update(overrides)
    event_id = values.pop("event_id")
    return make_event_dict(RIDE, event_id, **values)


def _alert(**overrides):
    hazard = {
        "id": "hazard-1",
        "rideId": RIDE,
        "type": "other",
        "kind": "alert",
        "severity": "serious",
        "position": {"latitude": 51.5, "longitude": -0.12},
        "reporterId": "rider-b",
        "reporterName": "Becks",
        "source": "rider",
    }
    values = {
        "event_id": "alert-1",
        "device_id": "rider-b",
        "event_type": "hazardReported",
        "payload": {"hazard": hazard},
        "created_at": NOW,
    }
    values.update(overrides)
    event_id = values.pop("event_id")
    return make_event_dict(RIDE, event_id, **values)


# --- classifier ---------------------------------------------------------------


@pytest.mark.parametrize("kind", sorted(LEADER_BROADCAST_TEXT))
def test_each_leader_broadcast_is_important_not_critical(kind: str) -> None:
    message = classify_push_event(RIDE, _broadcast(kind), now=NOW)

    assert message is not None
    assert message.important and not message.critical
    assert message.time_sensitive
    assert message.category == "leaderBroadcast"
    assert message.all_members and not message.recipient_ids
    assert message.sender_must_lead
    assert message.body == LEADER_BROADCAST_TEXT[kind]


def test_the_lock_screen_says_the_relays_words_not_the_phones() -> None:
    message = classify_push_event(RIDE, _broadcast("wrongWay"), now=NOW)

    assert message is not None
    assert message.body == "Wrong way \u2013 turn around"
    text = f"{message.title} {message.body}"
    # The sender's label, name and position are in the event and never in the push.
    assert "Oliver" not in text
    assert "51.5" not in text
    assert "-0.12" not in text


def test_a_broadcast_kind_the_relay_does_not_know_is_not_pushed() -> None:
    assert classify_push_event(RIDE, _broadcast("goFaster"), now=NOW) is None


def test_an_acknowledgement_of_a_broadcast_is_not_a_broadcast() -> None:
    event = _broadcast(
        "pullOver",
        payload={
            "message": "pullOver",
            "label": "Seen: Pull over",
            "acknowledgesQuickMessageEventId": "broadcast-1",
            "recipientRiderIds": ["lead"],
        },
    )

    assert classify_push_event(RIDE, event, now=NOW) is None


def test_a_broadcast_addressed_to_riders_goes_to_them_alone() -> None:
    event = _broadcast(
        payload={"message": "pullOver", "label": "Pull over", "recipientRiderIds": ["rider-a"]}
    )

    message = classify_push_event(RIDE, event, now=NOW)

    assert message is not None
    assert message.recipient_ids == frozenset({"rider-a"})
    assert not message.all_members


def test_a_stale_or_expired_broadcast_is_not_pushed() -> None:
    nine_minutes_old = _broadcast(created_at=NOW - timedelta(minutes=9))
    eleven_minutes_old = _broadcast(created_at=NOW - timedelta(minutes=11))
    expired = _broadcast(
        created_at=NOW - timedelta(minutes=2), expires_at=NOW - timedelta(seconds=1)
    )
    unexpired = _broadcast(
        created_at=NOW - timedelta(minutes=2), expires_at=NOW + timedelta(minutes=8)
    )
    undated = _broadcast()
    undated["createdAt"] = "yesterday-ish"

    assert classify_push_event(RIDE, nine_minutes_old, now=NOW) is not None
    assert classify_push_event(RIDE, eleven_minutes_old, now=NOW) is None
    assert classify_push_event(RIDE, expired, now=NOW) is None
    assert classify_push_event(RIDE, unexpired, now=NOW) is not None
    assert classify_push_event(RIDE, undated, now=NOW) is None


def test_the_one_tap_alert_is_important_not_critical() -> None:
    message = classify_push_event(RIDE, _alert(), now=NOW)

    assert message is not None
    assert message.important and not message.critical
    assert message.category == "groupAlert"
    assert message.all_members and not message.sender_must_lead
    text = f"{message.title} {message.body}"
    # Who raised it and where are in the event; the push says neither, nor what kind
    # of alert it is.
    assert "Becks" not in text
    assert "51.5" not in text
    for word in ("camera", "police", "speed"):
        assert word not in text.lower()


def test_only_a_hazard_marked_as_an_alert_is_an_alert() -> None:
    plain_other = _alert()
    del plain_other["payload"]["hazard"]["kind"]
    police = _alert()
    police["payload"]["hazard"].update({"type": "policeActivity"})
    del police["payload"]["hazard"]["kind"]
    other_kind = _alert()
    other_kind["payload"]["hazard"]["kind"] = "roadworks"
    not_a_hazard = _alert(payload={"hazard": "alert"})

    for event in (plain_other, police, other_kind, not_a_hazard, _alert(payload={})):
        assert classify_push_event(RIDE, event, now=NOW) is None


def test_the_kind_marker_wins_over_the_wire_type() -> None:
    # The app reads `kind` first so a later build may pick another legacy-safe type.
    event = _alert()
    event["payload"]["hazard"]["type"] = "debris"

    assert classify_push_event(RIDE, event, now=NOW) is not None


def test_a_stale_alert_is_not_pushed() -> None:
    assert (
        classify_push_event(RIDE, _alert(created_at=NOW - timedelta(minutes=11)), now=NOW) is None
    )


def test_the_data_an_older_build_reads_is_three_plain_strings() -> None:
    # Builds 101 and 102 read exactly rideId, eventId and category from the push
    # data, as strings, and show the notification's own title and body. FCM rejects
    # a data value that is not a string, so a new key or a number would lose the push.
    for event in (_broadcast("regroupNextStop"), _alert()):
        message = classify_push_event(RIDE, event, now=NOW)
        assert message is not None
        assert message.data == {
            "rideId": RIDE,
            "eventId": event["id"],
            "category": message.category,
        }
        assert all(isinstance(value, str) for value in message.data.values())
        # Nothing in the title or body is a payload an older build would print raw.
        for text in (message.title, message.body):
            assert text and not text.lstrip().startswith(("{", "["))


# --- provider requests --------------------------------------------------------


def _apns_provider(settings, handler) -> ApnsPushProvider:
    key = ec.generate_private_key(ec.SECP256R1())
    pem = key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    )
    configured = settings.model_copy(
        update={
            "apns_team_id": "TEAM123456",
            "apns_key_id": "KEY1234567",
            "apns_bundle_id": "app.tailendcharlie",
            "apns_private_key_base64": SecretStr(base64.b64encode(pem).decode()),
        }
    )
    provider = ApnsPushProvider(configured)
    provider._client.close()
    provider._client = httpx.Client(transport=httpx.MockTransport(handler))
    return provider


def _fcm_provider(settings, handler) -> FcmPushProvider:
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    pem = key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    )
    configured = settings.model_copy(
        update={
            "fcm_project_id": "tec-test",
            "fcm_client_email": "relay@tec-test.iam.gserviceaccount.com",
            "fcm_private_key_base64": SecretStr(base64.b64encode(pem).decode()),
        }
    )
    provider = FcmPushProvider(configured)
    provider._client.close()
    provider._client = httpx.Client(transport=httpx.MockTransport(handler))
    return provider


def _routine() -> PushMessage:
    message = classify_push_event(
        RIDE,
        make_event_dict(RIDE, "marker-1", event_type="markerStarted", payload={}),
        now=NOW,
    )
    assert message is not None and not message.time_sensitive
    return message


def _critical() -> PushMessage:
    message = classify_push_event(
        RIDE,
        make_event_dict(
            RIDE, "sos-1", event_type="statusMessage", payload={"message": "emergencyStop"}
        ),
        now=NOW,
    )
    assert message is not None and message.critical
    return message


def _classified(event) -> PushMessage:
    message = classify_push_event(RIDE, event, now=NOW)
    assert message is not None
    return message


def test_apns_delivers_important_pushes_immediately_with_sound(settings) -> None:
    seen: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return httpx.Response(200, headers={"apns-id": "apns-1"})

    provider = _apns_provider(settings, handler)
    token = "ab" * 32
    for message in (_classified(_broadcast("wrongWay")), _classified(_alert()), _critical()):
        assert provider.send(token, message).delivered

    broadcast, alert, critical = seen
    for request in (broadcast, alert, critical):
        assert request.headers["apns-priority"] == "10"
        assert json.loads(request.content)["aps"]["sound"] == "default"
    body = json.loads(broadcast.content)
    assert body["aps"]["alert"] == {
        "title": "Message from your leader",
        "body": "Wrong way \u2013 turn around",
    }
    # Exactly what a build 101 or 102 phone reads when the notification is tapped.
    assert {key: value for key, value in body.items() if key != "aps"} == {
        "rideId": RIDE,
        "eventId": "broadcast-1",
        "category": "leaderBroadcast",
    }
    assert json.loads(alert.content)["category"] == "groupAlert"


def test_apns_still_sends_routine_updates_quietly_and_without_urgency(settings) -> None:
    seen: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return httpx.Response(200)

    provider = _apns_provider(settings, handler)
    assert provider.send("ab" * 32, _routine()).delivered

    assert seen[0].headers["apns-priority"] == "5"
    assert "sound" not in json.loads(seen[0].content)["aps"]


def test_fcm_sends_important_pushes_high_priority_on_the_heads_up_channel(settings) -> None:
    seen: list[dict] = []

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.host == "oauth2.googleapis.com":
            return httpx.Response(200, json={"access_token": "access", "expires_in": 3600})
        seen.append(json.loads(request.content)["message"])
        return httpx.Response(200, json={"name": "projects/tec-test/messages/1"})

    provider = _fcm_provider(settings, handler)
    token = "t" * 40
    for message in (_classified(_broadcast("pullOver")), _classified(_alert()), _routine()):
        assert provider.send(token, message).delivered

    broadcast, alert, routine = seen
    for important in (broadcast, alert):
        assert important["android"]["priority"] == "HIGH"
        # The channel builds 101 and 102 already create with heads-up importance.
        assert important["android"]["notification"]["channel_id"] == "ride_safety_alerts"
        assert all(isinstance(value, str) for value in important["data"].values())
    assert broadcast["notification"] == {
        "title": "Message from your leader",
        "body": "Pull over",
    }
    assert broadcast["data"] == {
        "rideId": RIDE,
        "eventId": "broadcast-1",
        "category": "leaderBroadcast",
    }
    assert routine["android"]["priority"] == "NORMAL"
    assert routine["android"]["notification"]["channel_id"] == "ride_updates"


# --- dispatch -----------------------------------------------------------------


def _roster(client, synchronize, make_event, members, *, ride_id=RIDE, extra_events=()):
    events = [
        make_event(
            ride_id,
            f"joined-{rider_id}",
            device_id=rider_id,
            event_type="riderJoined",
            payload={"displayName": rider_id, "role": role},
        )
        for rider_id, role in members
    ]
    events.extend(extra_events)
    assert synchronize(client, ride_id=ride_id, secret=SECRET, events=events).status_code == 200
    for rider_id, role in members:
        assert _register(client, ride_id, rider_id, role=role).status_code == 200
    provider = _RecordingProvider()
    client.app.state.push_dispatcher._providers["fcm"] = provider
    return provider


def _send(client, synchronize, *events, ride_id=RIDE):
    response = synchronize(client, ride_id=ride_id, secret=SECRET, events=list(events))
    assert response.status_code == 200


def _tokens(*riders: str) -> set[str]:
    return {f"fcm-token-{rider}-123456789" for rider in riders}


GROUP = [
    ("lead", "lead"),
    ("tec", "tailEndCharlie"),
    ("rider-a", "rider"),
    ("rider-b", "rider"),
]


def test_a_leader_broadcast_reaches_everyone_else_once(client, synchronize, make_event) -> None:
    provider = _roster(client, synchronize, make_event, [*GROUP, ("gone", "rider")])
    _send(
        client, synchronize, make_event(RIDE, "gone-left", device_id="gone", event_type="riderLeft")
    )
    broadcast = _broadcast("wrongWay", created_at=datetime.now(UTC))

    _send(client, synchronize, broadcast)
    _send(client, synchronize, broadcast)  # a retried upload of the same event

    assert sorted(provider.tokens) == sorted(_tokens("tec", "rider-a", "rider-b"))
    assert "fcm-token-lead-123456789" not in provider.tokens  # never the sender
    assert "fcm-token-gone-123456789" not in provider.tokens  # left the ride
    with client.app.state.session_factory() as session:
        assert session.scalar(select(func.count(PushDelivery.id))) == 3


def test_every_broadcast_is_its_own_push_but_never_twice(client, synchronize, make_event) -> None:
    provider = _roster(client, synchronize, make_event, GROUP)
    now = datetime.now(UTC)
    first = _broadcast("pullOver", event_id="first", created_at=now)
    second = _broadcast("pullOver", event_id="second", created_at=now)

    _send(client, synchronize, first)
    _send(client, synchronize, second)
    _send(client, synchronize, first, second)

    assert [message.event_id for message in provider.messages].count("first") == 3
    assert [message.event_id for message in provider.messages].count("second") == 3


def test_a_backgrounded_phone_is_the_one_that_gets_it(client, synchronize, make_event) -> None:
    provider = _roster(
        client, synchronize, make_event, [*GROUP, ("away", "rider"), ("asleep", "rider")]
    )
    now = datetime.now(UTC)
    with client.app.state.session_factory() as session, session.begin():
        for rider_id, age in (("away", timedelta(minutes=30)), ("asleep", timedelta(hours=13))):
            member = session.scalar(select(RideMember).where(RideMember.device_id == rider_id))
            member.last_seen_at = now - age

    _send(client, synchronize, _broadcast("wrongWay", created_at=now))

    # Not synced for half an hour is exactly a rider navigating in another app.
    assert "fcm-token-away-123456789" in provider.tokens
    # Not seen for twelve hours has expired and is left alone.
    assert "fcm-token-asleep-123456789" not in provider.tokens


def test_only_the_leader_can_make_the_group_push(client, synchronize, make_event) -> None:
    provider = _roster(client, synchronize, make_event, GROUP)
    now = datetime.now(UTC)

    _send(client, synchronize, _broadcast("pullOver", device_id="rider-a", created_at=now))
    _send(
        client,
        synchronize,
        _broadcast("pullOver", event_id="from-tec", device_id="tec", created_at=now),
    )

    assert provider.messages == []


def test_a_leader_who_handed_over_can_no_longer_broadcast(client, synchronize, make_event) -> None:
    provider = _roster(
        client,
        synchronize,
        make_event,
        GROUP,
        extra_events=[
            make_event(
                RIDE,
                "handover-down",
                device_id="lead",
                event_type="roleChanged",
                payload={"role": "rider"},
            ),
            make_event(
                RIDE,
                "handover-up",
                device_id="rider-a",
                event_type="roleChanged",
                payload={"role": "lead"},
            ),
        ],
    )
    now = datetime.now(UTC)

    _send(
        client,
        synchronize,
        _broadcast("pullOver", event_id="old-lead", device_id="lead", created_at=now),
    )
    assert provider.messages == []
    _send(
        client,
        synchronize,
        _broadcast("pullOver", event_id="new-lead", device_id="rider-a", created_at=now),
    )

    assert {message.event_id for message in provider.messages} == {"new-lead"}
    assert "fcm-token-rider-a-123456789" not in provider.tokens


def test_a_leader_who_left_cannot_broadcast(client, synchronize, make_event) -> None:
    provider = _roster(client, synchronize, make_event, GROUP)
    _send(
        client, synchronize, make_event(RIDE, "lead-left", device_id="lead", event_type="riderLeft")
    )

    _send(client, synchronize, _broadcast("pullOver", created_at=datetime.now(UTC)))

    assert provider.messages == []


def test_a_leader_marking_a_junction_is_still_the_leader(client, synchronize, make_event) -> None:
    provider = _roster(
        client,
        synchronize,
        make_event,
        GROUP,
        extra_events=[
            make_event(
                RIDE,
                "lead-marks",
                device_id="lead",
                event_type="markerStarted",
                payload={"mode": "dropOff", "previousRole": "lead"},
            ),
            make_event(
                RIDE,
                "rider-marks",
                device_id="rider-b",
                event_type="markerStarted",
                payload={"mode": "dropOff", "previousRole": "rider"},
            ),
        ],
    )
    now = datetime.now(UTC)

    # The relay records both as markers; only the one who was the leader may speak.
    _send(
        client,
        synchronize,
        _broadcast("pullOver", event_id="lead-says", device_id="lead", created_at=now),
    )
    _send(
        client,
        synchronize,
        _broadcast("pullOver", event_id="rider-says", device_id="rider-b", created_at=now),
    )

    assert {message.event_id for message in provider.messages} == {"lead-says"}


def test_an_alert_from_any_rider_reaches_everyone_else_once(
    client, synchronize, make_event
) -> None:
    provider = _roster(client, synchronize, make_event, [*GROUP, ("gone", "rider")])
    _send(
        client, synchronize, make_event(RIDE, "gone-left", device_id="gone", event_type="riderLeft")
    )
    alert = _alert(created_at=datetime.now(UTC))

    _send(client, synchronize, alert)
    _send(client, synchronize, alert)

    assert sorted(provider.tokens) == sorted(_tokens("lead", "tec", "rider-a"))
    assert "fcm-token-rider-b-123456789" not in provider.tokens  # the sender
    assert {message.category for message in provider.messages} == {"groupAlert"}


def test_a_riders_safety_preference_governs_both(client, synchronize, make_event) -> None:
    provider = _roster(client, synchronize, make_event, GROUP)
    now = datetime.now(UTC)
    safety_off = {"safety": False, "status": True, "administrative": True}
    assert _register(client, RIDE, "rider-a", preferences=safety_off).status_code == 200
    # Status and administrative off, safety on: the instructions still arrive.
    only_safety = {"safety": True, "status": False, "administrative": False}
    assert _register(client, RIDE, "rider-b", preferences=only_safety).status_code == 200

    _send(client, synchronize, _broadcast("pullOver", created_at=now))
    _send(client, synchronize, _alert(event_id="alert-2", device_id="tec", created_at=now))

    by_event: dict[str, set[str]] = {}
    for token, message in zip(provider.tokens, provider.messages, strict=True):
        by_event.setdefault(message.event_id, set()).add(token)
    assert by_event["broadcast-1"] == _tokens("tec", "rider-b")
    assert by_event["alert-2"] == _tokens("lead", "rider-b")


def test_stale_instructions_are_never_dispatched(client, synchronize, make_event) -> None:
    provider = _roster(client, synchronize, make_event, GROUP)
    old = datetime.now(UTC) - timedelta(minutes=30)

    _send(client, synchronize, _broadcast("wrongWay", event_id="old-broadcast", created_at=old))
    _send(client, synchronize, _alert(event_id="old-alert", created_at=old))

    assert provider.messages == []
    with client.app.state.session_factory() as session:
        assert session.scalar(select(func.count(PushDelivery.id))) == 0
