from __future__ import annotations

from datetime import UTC, datetime, timedelta

from sqlalchemy import delete, func, select

from ride_relay_server.crypto import sha256
from ride_relay_server.models import PushDelivery, PushRegistration, Ride, RideMember, StoredEvent
from ride_relay_server.push import PushMessage, PushProviderResult

from .conftest import ride_token

SECRET = "0123456789abcdef0123456789abcdef"


class _RecordingProvider:
    def __init__(self, *, permanently_invalid: bool = False) -> None:
        self.tokens: list[str] = []
        self.messages: list[PushMessage] = []
        self.permanently_invalid = permanently_invalid

    def send(self, token: str, message: PushMessage) -> PushProviderResult:
        self.tokens.append(token)
        self.messages.append(message)
        if self.permanently_invalid:
            return PushProviderResult(
                delivered=False,
                error_code="UNREGISTERED",
                permanently_invalid=True,
            )
        return PushProviderResult(
            delivered=True,
            message_id=f"message-{len(self.messages)}",
        )

    def close(self) -> None:
        pass


class _EventDecryptCounter:
    def __init__(self, delegate) -> None:
        self._delegate = delegate
        self.event_decryptions = 0

    def decrypt_json(self, value: bytes, *, associated_data: bytes):
        if associated_data.startswith(b"event:"):
            self.event_decryptions += 1
        return self._delegate.decrypt_json(value, associated_data=associated_data)


def _headers(ride_id: str, installation_id: str) -> dict[str, str]:
    return {
        "authorization": f"Bearer {ride_token(ride_id, SECRET)}",
        "x-ride-relay-device": installation_id,
    }


def _register(
    client,
    ride_id: str,
    installation_id: str,
    *,
    role: str = "rider",
    token: str | None = None,
    preferences: dict[str, bool] | None = None,
):
    return client.put(
        f"/api/v1/rides/{ride_id}/push-registrations/{installation_id}",
        headers=_headers(ride_id, installation_id),
        json={
            "platform": "android",
            "provider": "fcm",
            "token": token or f"fcm-token-{installation_id}-123456789",
            "role": role,
            "preferences": preferences or {"safety": True, "status": True, "administrative": True},
        },
    )


def test_registration_is_encrypted_rotated_and_revoked(
    client,
    synchronize,
) -> None:
    ride_id = "ride-push-registration"
    assert synchronize(client, ride_id=ride_id, secret=SECRET).status_code == 200

    first = _register(client, ride_id, "rider-a", token="first-token-1234567890")
    second = _register(client, ride_id, "rider-a", token="second-token-123456789")

    assert first.status_code == 200
    assert second.status_code == 200
    assert "token" not in second.json()
    factory = client.app.state.session_factory
    with factory() as session:
        registrations = session.scalars(select(PushRegistration)).all()
        assert len(registrations) == 1
        assert b"second-token" not in registrations[0].token_ciphertext
        assert registrations[0].revoked_at is None

    revoked = client.delete(
        f"/api/v1/rides/{ride_id}/push-registrations/rider-a",
        headers=_headers(ride_id, "rider-a"),
    )
    assert revoked.status_code == 204
    with factory() as session:
        assert session.scalar(select(PushRegistration)).revoked_at is not None


def test_urgent_alert_targets_current_coordinators_once(
    client,
    synchronize,
    make_event,
) -> None:
    ride_id = "ride-push-targeting"
    joined = [
        make_event(
            ride_id,
            f"joined-{rider_id}",
            device_id=rider_id,
            event_type="riderJoined",
            payload={"displayName": rider_id, "role": role},
        )
        for rider_id, role in [
            ("lead", "lead"),
            ("tec", "tailEndCharlie"),
            ("sender", "rider"),
            ("left", "lead"),
        ]
    ]
    joined.append(
        make_event(
            ride_id,
            "left-departed",
            device_id="left",
            event_type="riderLeft",
        )
    )
    assert synchronize(client, ride_id=ride_id, secret=SECRET, events=joined).status_code == 200
    for rider_id, role in [
        ("lead", "lead"),
        ("tec", "tailEndCharlie"),
        ("sender", "rider"),
        ("left", "lead"),
    ]:
        assert _register(client, ride_id, rider_id, role=role).status_code == 200

    provider = _RecordingProvider()
    client.app.state.push_dispatcher._providers["fcm"] = provider
    alert = make_event(
        ride_id,
        "urgent-alert",
        device_id="sender",
        event_type="statusMessage",
        payload={"message": "emergencyStop", "label": "Emergency stop"},
    )

    first = synchronize(client, ride_id=ride_id, secret=SECRET, events=[alert])
    replay = synchronize(client, ride_id=ride_id, secret=SECRET, events=[alert])

    assert first.status_code == 200
    assert replay.status_code == 200
    assert set(provider.tokens) == {
        "fcm-token-lead-123456789",
        "fcm-token-tec-123456789",
    }
    assert len(provider.tokens) == 2
    assert all("coordinate" not in message.body.lower() for message in provider.messages)
    factory = client.app.state.session_factory
    with factory() as session:
        assert session.scalar(select(func.count(PushDelivery.id))) == 2
    metrics = client.get("/metrics")
    assert 'ride_relay_push_deliveries_total{outcome="delivered"} 2.0' in metrics.text


def test_push_membership_projection_does_not_decrypt_large_event_history(
    client,
    synchronize,
    make_event,
) -> None:
    ride_id = "ride-push-projection"
    joined = [
        make_event(
            ride_id,
            "joined-lead",
            device_id="lead",
            event_type="riderJoined",
            payload={"displayName": "Lead", "role": "lead"},
        ),
        make_event(
            ride_id,
            "joined-sender",
            device_id="sender",
            event_type="riderJoined",
            payload={"displayName": "Sender", "role": "rider"},
        ),
    ]
    assert synchronize(client, ride_id=ride_id, secret=SECRET, events=joined).status_code == 200
    assert _register(client, ride_id, "lead", role="lead").status_code == 200

    now = datetime.now(UTC)
    cipher = client.app.state.service._cipher
    with client.app.state.session_factory() as session, session.begin():
        ride = session.get(Ride, ride_id)
        assert ride is not None
        rows = []
        total_bytes = 0
        for index in range(2_000):
            event_id = f"position-{index:04d}"
            body = make_event(
                ride_id,
                event_id,
                device_id="sender",
                event_type="riderLocationUpdated",
                created_at=now,
            )
            body_ciphertext = cipher.encrypt_json(
                body,
                associated_data=f"event:{ride_id}:{event_id}".encode(),
            )
            total_bytes += len(body_ciphertext)
            rows.append(
                StoredEvent(
                    ride_id=ride_id,
                    event_id=event_id,
                    device_id="sender",
                    event_type="riderLocationUpdated",
                    created_at=now,
                    expires_at=now + timedelta(minutes=20),
                    body_hash=sha256(b"position" + index.to_bytes(4, "big")),
                    body_ciphertext=body_ciphertext,
                )
            )
        session.add_all(rows)
        ride.stored_event_count += len(rows)
        ride.stored_event_bytes += total_bytes

    provider = _RecordingProvider()
    counter = _EventDecryptCounter(client.app.state.push_dispatcher._cipher)
    client.app.state.push_dispatcher._providers["fcm"] = provider
    client.app.state.push_dispatcher._cipher = counter
    alert = make_event(
        ride_id,
        "projection-alert",
        device_id="sender",
        event_type="statusMessage",
        payload={"message": "emergencyStop", "label": "Emergency stop"},
    )

    assert synchronize(client, ride_id=ride_id, secret=SECRET, events=[alert]).status_code == 200

    assert counter.event_decryptions == 0
    assert provider.tokens == ["fcm-token-lead-123456789"]


def test_existing_ride_backfills_membership_projection_only_once(
    client,
    synchronize,
    make_event,
) -> None:
    ride_id = "ride-push-projection-upgrade"
    joined = [
        make_event(
            ride_id,
            "joined-lead",
            device_id="lead",
            event_type="riderJoined",
            payload={"displayName": "Lead", "role": "lead"},
        ),
        make_event(
            ride_id,
            "joined-sender",
            device_id="sender",
            event_type="riderJoined",
            payload={"displayName": "Sender", "role": "rider"},
        ),
    ]
    assert synchronize(client, ride_id=ride_id, secret=SECRET, events=joined).status_code == 200
    assert _register(client, ride_id, "lead", role="lead").status_code == 200
    with client.app.state.session_factory() as session, session.begin():
        ride = session.get(Ride, ride_id)
        assert ride is not None
        ride.membership_projection_ready = False
        session.execute(delete(RideMember).where(RideMember.ride_id == ride_id))

    provider = _RecordingProvider()
    counter = _EventDecryptCounter(client.app.state.push_dispatcher._cipher)
    client.app.state.push_dispatcher._providers["fcm"] = provider
    client.app.state.push_dispatcher._cipher = counter
    first = make_event(
        ride_id,
        "upgrade-alert-1",
        device_id="sender",
        event_type="statusMessage",
        payload={"message": "emergencyStop"},
    )
    second = make_event(
        ride_id,
        "upgrade-alert-2",
        device_id="sender",
        event_type="statusMessage",
        payload={"message": "emergencyStop"},
    )

    assert synchronize(client, ride_id=ride_id, secret=SECRET, events=[first]).status_code == 200
    after_backfill = counter.event_decryptions
    assert after_backfill == 3
    assert synchronize(client, ride_id=ride_id, secret=SECRET, events=[second]).status_code == 200
    assert counter.event_decryptions == after_backfill
    with client.app.state.session_factory() as session:
        ride = session.get(Ride, ride_id)
        assert ride is not None and ride.membership_projection_ready
        assert (
            session.scalar(
                select(func.count(RideMember.device_id)).where(RideMember.ride_id == ride_id)
            )
            == 2
        )


def test_nested_off_course_alert_targets_coordinators_and_affected_rider(
    client,
    synchronize,
    make_event,
) -> None:
    ride_id = "ride-push-off-course"
    joined = [
        make_event(
            ride_id,
            f"joined-{rider_id}",
            device_id=rider_id,
            event_type="riderJoined",
            payload={"displayName": rider_id, "role": role},
        )
        for rider_id, role in [
            ("observer", "rider"),
            ("affected", "rider"),
            ("lead", "lead"),
            ("tec", "tailEndCharlie"),
        ]
    ]
    assert synchronize(client, ride_id=ride_id, secret=SECRET, events=joined).status_code == 200
    for rider_id, role in [
        ("observer", "rider"),
        ("affected", "rider"),
        ("lead", "lead"),
        ("tec", "tailEndCharlie"),
    ]:
        assert _register(client, ride_id, rider_id, role=role).status_code == 200
    provider = _RecordingProvider()
    client.app.state.push_dispatcher._providers["fcm"] = provider

    alert = make_event(
        ride_id,
        "off-course-alert",
        device_id="observer",
        event_type="routeDeviationChanged",
        payload={
            "alert": {
                "riderId": "affected",
                "displayName": "Affected rider",
                "assessment": {
                    "state": "offRoute",
                    "alertLevel": "urgent",
                    "audience": "coordinators",
                    "evaluatedAt": "2026-07-23T12:00:00Z",
                    "message": "Off route",
                },
                "acknowledged": False,
            }
        },
    )
    assert synchronize(client, ride_id=ride_id, secret=SECRET, events=[alert]).status_code == 200

    assert set(provider.tokens) == {
        "fcm-token-affected-123456789",
        "fcm-token-lead-123456789",
        "fcm-token-tec-123456789",
    }


def test_preferences_filter_noncritical_but_not_critical_safety(
    client,
    synchronize,
    make_event,
) -> None:
    ride_id = "ride-push-preferences"
    events = [
        make_event(
            ride_id,
            "joined-lead",
            device_id="lead",
            event_type="riderJoined",
            payload={"displayName": "Lead", "role": "lead"},
        ),
        make_event(
            ride_id,
            "joined-rider",
            device_id="rider",
            event_type="riderJoined",
            payload={"displayName": "Rider", "role": "rider"},
        ),
    ]
    assert synchronize(client, ride_id=ride_id, secret=SECRET, events=events).status_code == 200
    assert (
        _register(
            client,
            ride_id,
            "lead",
            role="lead",
            preferences={
                "safety": False,
                "status": False,
                "administrative": False,
            },
        ).status_code
        == 200
    )
    provider = _RecordingProvider()
    client.app.state.push_dispatcher._providers["fcm"] = provider

    noncritical = make_event(
        ride_id,
        "mechanical",
        device_id="rider",
        event_type="statusMessage",
        payload={"message": "mechanical"},
    )
    critical = make_event(
        ride_id,
        "sos",
        device_id="rider",
        event_type="statusMessage",
        payload={"message": "emergencyStop"},
    )
    synchronize(client, ride_id=ride_id, secret=SECRET, events=[noncritical])
    synchronize(client, ride_id=ride_id, secret=SECRET, events=[critical])

    assert [message.event_id for message in provider.messages] == ["sos"]


def test_permanently_invalid_provider_token_is_revoked(
    client,
    synchronize,
    make_event,
) -> None:
    ride_id = "ride-push-invalid-token"
    joined = [
        make_event(
            ride_id,
            "joined-lead",
            device_id="lead",
            event_type="riderJoined",
            payload={"displayName": "Lead", "role": "lead"},
        ),
        make_event(
            ride_id,
            "joined-rider",
            device_id="rider",
            event_type="riderJoined",
            payload={"displayName": "Rider", "role": "rider"},
        ),
    ]
    synchronize(client, ride_id=ride_id, secret=SECRET, events=joined)
    _register(client, ride_id, "lead", role="lead")
    client.app.state.push_dispatcher._providers["fcm"] = _RecordingProvider(
        permanently_invalid=True
    )

    synchronize(
        client,
        ride_id=ride_id,
        secret=SECRET,
        events=[
            make_event(
                ride_id,
                "alert-invalid",
                device_id="rider",
                event_type="statusMessage",
                payload={"message": "emergencyStop"},
            )
        ],
    )

    factory = client.app.state.session_factory
    with factory() as session:
        registration = session.scalar(select(PushRegistration))
        delivery = session.scalar(select(PushDelivery))
        assert registration.revoked_at is not None
        assert delivery.status == "failed"
        assert delivery.error_code == "UNREGISTERED"
