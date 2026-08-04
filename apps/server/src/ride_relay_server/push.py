from __future__ import annotations

import base64
import hmac
import json
import re
import time
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any, Protocol

import httpx
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, padding, rsa
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
from sqlalchemy import delete, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from .config import Settings
from .crypto import DataCipher, base64url, sha256, token_hash
from .membership import MembershipEvent, project_membership_events
from .models import PushDelivery, PushRegistration, Ride, RideMember, StoredEvent
from .schemas import PushRegistrationRequest
from .service import RelayServiceError


@dataclass(frozen=True)
class PushMessage:
    event_id: str
    ride_id: str
    category: str
    title: str
    body: str
    critical: bool
    recipient_ids: frozenset[str] = frozenset()
    recipient_roles: frozenset[str] = frozenset()
    all_members: bool = False

    @property
    def data(self) -> dict[str, str]:
        return {
            "rideId": self.ride_id,
            "eventId": self.event_id,
            "category": self.category,
        }


@dataclass(frozen=True)
class PushProviderResult:
    delivered: bool
    message_id: str | None = None
    error_code: str | None = None
    permanently_invalid: bool = False


@dataclass(frozen=True)
class PushDispatchReport:
    delivered: int = 0
    failed: int = 0
    not_configured: int = 0

    @property
    def attempted(self) -> int:
        return self.delivered + self.failed + self.not_configured


class PushProvider(Protocol):
    def send(self, token: str, message: PushMessage) -> PushProviderResult: ...

    def close(self) -> None: ...


def register_push(
    session: Session,
    *,
    cipher: DataCipher,
    ride_id: str,
    bearer_token: str,
    installation_id: str,
    device_header: str,
    request: PushRegistrationRequest,
    now: datetime | None = None,
) -> PushRegistration:
    now = now or datetime.now(UTC)
    _authorize_installation(
        session,
        ride_id=ride_id,
        bearer_token=bearer_token,
        installation_id=installation_id,
        device_header=device_header,
    )
    token = request.token.strip()
    valid_provider_token = (
        re.fullmatch(r"[0-9A-Fa-f]{32,256}", token)
        if request.provider == "apns"
        else re.fullmatch(r"[A-Za-z0-9_:-]{16,4096}", token)
    )
    if valid_provider_token is None:
        raise RelayServiceError(400, "Push token is invalid")
    aad = _token_aad(ride_id, installation_id, request.provider)
    encrypted = cipher.encrypt_json({"token": token}, associated_data=aad)
    digest = token_hash(token)

    registration = session.scalar(
        select(PushRegistration)
        .where(
            PushRegistration.ride_id == ride_id,
            PushRegistration.installation_id == installation_id,
            PushRegistration.provider == request.provider,
        )
        .with_for_update()
    )
    if registration is None:
        registration = PushRegistration(
            ride_id=ride_id,
            installation_id=installation_id,
            platform=request.platform,
            provider=request.provider,
            token_hash=digest,
            token_ciphertext=encrypted,
            role=request.role,
            safety_enabled=request.preferences.safety,
            status_enabled=request.preferences.status,
            administrative_enabled=request.preferences.administrative,
            created_at=now,
            updated_at=now,
            last_seen_at=now,
        )
        session.add(registration)
    else:
        registration.platform = request.platform
        registration.token_hash = digest
        registration.token_ciphertext = encrypted
        registration.role = request.role
        registration.safety_enabled = request.preferences.safety
        registration.status_enabled = request.preferences.status
        registration.administrative_enabled = request.preferences.administrative
        registration.updated_at = now
        registration.last_seen_at = now
        registration.revoked_at = None
    session.commit()
    return registration


def revoke_push(
    session: Session,
    *,
    ride_id: str,
    bearer_token: str,
    installation_id: str,
    device_header: str,
    now: datetime | None = None,
) -> int:
    now = now or datetime.now(UTC)
    _authorize_installation(
        session,
        ride_id=ride_id,
        bearer_token=bearer_token,
        installation_id=installation_id,
        device_header=device_header,
    )
    registrations = session.scalars(
        select(PushRegistration).where(
            PushRegistration.ride_id == ride_id,
            PushRegistration.installation_id == installation_id,
            PushRegistration.revoked_at.is_(None),
        )
    ).all()
    for registration in registrations:
        registration.revoked_at = now
        registration.updated_at = now
    session.commit()
    return len(registrations)


def registration_json(registration: PushRegistration) -> dict[str, Any]:
    return {
        "installationId": registration.installation_id,
        "platform": registration.platform,
        "provider": registration.provider,
        "role": registration.role,
        "preferences": {
            "safety": registration.safety_enabled,
            "status": registration.status_enabled,
            "administrative": registration.administrative_enabled,
        },
        "registeredAt": registration.created_at,
        "updatedAt": registration.updated_at,
    }


class PushDispatcher:
    def __init__(
        self,
        *,
        cipher: DataCipher,
        providers: dict[str, PushProvider],
        inactive_after: timedelta = timedelta(minutes=2),
        expire_after: timedelta = timedelta(hours=12),
    ) -> None:
        self._cipher = cipher
        self._providers = providers
        self._inactive_after = inactive_after
        self._expire_after = expire_after

    @classmethod
    def from_settings(cls, settings: Settings, cipher: DataCipher) -> PushDispatcher:
        providers: dict[str, PushProvider] = {}
        if settings.apns_configured:
            providers["apns"] = ApnsPushProvider(settings)
        if settings.fcm_configured:
            providers["fcm"] = FcmPushProvider(settings)
        return cls(cipher=cipher, providers=providers)

    def dispatch(
        self,
        session: Session,
        *,
        ride_id: str,
        events: list[dict[str, Any]],
        now: datetime | None = None,
    ) -> PushDispatchReport:
        now = now or datetime.now(UTC)
        messages = [
            message
            for event in events
            if (message := classify_push_event(ride_id, event)) is not None
        ]
        if not messages:
            return PushDispatchReport()
        memberships = self._memberships(session, ride_id, now)
        registrations = session.scalars(
            select(PushRegistration).where(
                PushRegistration.ride_id == ride_id,
                PushRegistration.revoked_at.is_(None),
            )
        ).all()
        outcomes = {"delivered": 0, "failed": 0, "not_configured": 0}
        for message in messages:
            sender_id = next(
                (event.get("deviceId") for event in events if event.get("id") == message.event_id),
                None,
            )
            for registration in registrations:
                membership = memberships.get(registration.installation_id)
                if (
                    membership is None
                    or membership.state in {"left", "expired"}
                    or registration.installation_id == sender_id
                    or not self._targets(message, membership)
                    or not self._preference_allows(message, registration)
                ):
                    continue
                delivery = self._reserve_delivery(
                    session,
                    registration=registration,
                    message=message,
                    now=now,
                )
                if delivery is None:
                    continue
                outcome = self._deliver(
                    session,
                    registration,
                    message,
                    delivery,
                    now,
                )
                outcomes[outcome] += 1
        session.commit()
        return PushDispatchReport(**outcomes)

    def close(self) -> None:
        for provider in self._providers.values():
            provider.close()

    def _deliver(
        self,
        session: Session,
        registration: PushRegistration,
        message: PushMessage,
        delivery: PushDelivery,
        now: datetime,
    ) -> str:
        provider = self._providers.get(registration.provider)
        if provider is None:
            delivery.status = "not_configured"
            delivery.error_code = "provider_not_configured"
            return "not_configured"
        try:
            value = self._cipher.decrypt_json(
                registration.token_ciphertext,
                associated_data=_token_aad(
                    registration.ride_id,
                    registration.installation_id,
                    registration.provider,
                ),
            )
            token = value.get("token") if isinstance(value, dict) else None
            if not isinstance(token, str):
                raise ValueError("push token is unavailable")
            result = provider.send(token, message)
        except Exception:
            result = PushProviderResult(
                delivered=False,
                error_code="provider_delivery_failed",
            )
        delivery.status = "delivered" if result.delivered else "failed"
        delivery.provider_message_id = result.message_id
        delivery.error_code = result.error_code
        if result.permanently_invalid:
            registration.revoked_at = now
            registration.updated_at = now
        return "delivered" if result.delivered else "failed"

    def _memberships(
        self,
        session: Session,
        ride_id: str,
        now: datetime,
    ) -> dict[str, _Membership]:
        ride = session.scalar(select(Ride).where(Ride.id == ride_id).with_for_update())
        if ride is None:
            return {}
        if not ride.membership_projection_ready:
            self._rebuild_membership_projection(session, ride)
        result = {
            row.device_id: _Membership(
                rider_id=row.device_id,
                role=row.role,
                state=row.state,
                last_seen_at=_as_utc(row.last_seen_at),
            )
            for row in session.scalars(select(RideMember).where(RideMember.ride_id == ride_id))
        }
        for membership in result.values():
            if membership.state == "left":
                continue
            age = now - membership.last_seen_at
            if age >= self._expire_after:
                membership.state = "expired"
            elif age >= self._inactive_after:
                membership.state = "inactive"
            else:
                membership.state = "active"
        return result

    def _rebuild_membership_projection(self, session: Session, ride: Ride) -> None:
        """Upgrade an in-flight pre-projection ride once, under its row lock."""

        session.execute(delete(RideMember).where(RideMember.ride_id == ride.id))
        events: list[MembershipEvent] = []
        rows = session.scalars(
            select(StoredEvent).where(StoredEvent.ride_id == ride.id).order_by(StoredEvent.sequence)
        ).all()
        for row in rows:
            try:
                event = self._cipher.decrypt_json(
                    row.body_ciphertext,
                    associated_data=f"event:{ride.id}:{row.event_id}".encode(),
                )
            except (TypeError, ValueError):
                event = None
            if not isinstance(event, dict):
                continue
            payload = event.get("payload")
            events.append(
                MembershipEvent(
                    device_id=row.device_id,
                    event_type=row.event_type,
                    created_at=_as_utc(row.created_at),
                    payload=payload if isinstance(payload, dict) else {},
                )
            )
        project_membership_events(session, ride_id=ride.id, events=events)
        ride.membership_projection_ready = True
        session.flush()

    @staticmethod
    def _targets(message: PushMessage, membership: _Membership) -> bool:
        return (
            message.all_members
            or membership.rider_id in message.recipient_ids
            or membership.role in message.recipient_roles
        )

    @staticmethod
    def _preference_allows(
        message: PushMessage,
        registration: PushRegistration,
    ) -> bool:
        if message.critical:
            return True
        if message.category == "safety":
            return registration.safety_enabled
        if message.category == "administrative":
            return registration.administrative_enabled
        return registration.status_enabled

    @staticmethod
    def _reserve_delivery(
        session: Session,
        *,
        registration: PushRegistration,
        message: PushMessage,
        now: datetime,
    ) -> PushDelivery | None:
        delivery = PushDelivery(
            ride_id=message.ride_id,
            event_id=message.event_id,
            registration_id=registration.id,
            category=message.category,
            status="pending",
            attempted_at=now,
        )
        try:
            with session.begin_nested():
                session.add(delivery)
                session.flush()
        except IntegrityError:
            return None
        return delivery


@dataclass
class _Membership:
    rider_id: str
    role: str
    state: str
    last_seen_at: datetime


def classify_push_event(
    ride_id: str,
    event: dict[str, Any],
) -> PushMessage | None:
    event_id = event.get("id")
    event_type = event.get("type")
    payload = event.get("payload")
    if not isinstance(event_id, str) or not isinstance(payload, dict):
        return None
    recipients = _recipient_ids(payload)
    coordinator_roles = frozenset({"lead", "tailEndCharlie"})

    if event_type == "statusMessage":
        message_type = payload.get("message")
        if message_type in {"emergencyStop", "assistance"}:
            return PushMessage(
                event_id=event_id,
                ride_id=ride_id,
                category="safety",
                title="Urgent ride alert",
                body="Open Tail End Charlie for the authenticated ride details.",
                critical=True,
                recipient_ids=recipients,
                recipient_roles=frozenset() if recipients else coordinator_roles,
            )
        if message_type in {"stopped", "mechanical", "fuel", "routeBlocked"}:
            return PushMessage(
                event_id=event_id,
                ride_id=ride_id,
                category="safety",
                title="Ride assistance update",
                body="A rider status needs attention. Open the ride for details.",
                critical=False,
                recipient_ids=recipients,
                recipient_roles=frozenset() if recipients else coordinator_roles,
            )
        if message_type in {"allPassed", "resolved"}:
            return PushMessage(
                event_id=event_id,
                ride_id=ride_id,
                category="status",
                title="Ride status update",
                body="Open Tail End Charlie for the latest group status.",
                critical=False,
                recipient_ids=recipients,
                recipient_roles=frozenset({"lead", "tailEndCharlie", "marker"}),
            )
        return None

    if event_type == "routeDeviationChanged":
        alert = payload.get("alert")
        if not isinstance(alert, dict):
            return None
        assessment = alert.get("assessment")
        if not isinstance(assessment, dict):
            return None
        level = assessment.get("alertLevel")
        if level not in {"urgent", "critical"}:
            return None
        affected = alert.get("riderId")
        affected_ids = recipients | ({affected} if isinstance(affected, str) else set())
        audience = assessment.get("audience")
        return PushMessage(
            event_id=event_id,
            ride_id=ride_id,
            category="safety",
            title="Route attention needed",
            body="A rider may be off course. Open the ride for verified details.",
            critical=level == "critical",
            recipient_ids=frozenset(affected_ids),
            recipient_roles=coordinator_roles,
            all_members=audience == "allRiders" and level == "critical",
        )

    if event_type == "iceInfoShared":
        return PushMessage(
            event_id=event_id,
            ride_id=ride_id,
            category="safety",
            title="Emergency information shared",
            body="Open the authorised ride to view the private information.",
            critical=True,
            recipient_ids=recipients,
            all_members=not recipients,
        )

    if event_type in {"markerStarted", "markerEnded"}:
        return PushMessage(
            event_id=event_id,
            ride_id=ride_id,
            category="status",
            title="Marker status changed",
            body="Open Tail End Charlie for the current marker status.",
            critical=False,
            recipient_roles=coordinator_roles,
        )

    if event_type in {"ridePaused", "rideResumed", "rideEnded"}:
        return PushMessage(
            event_id=event_id,
            ride_id=ride_id,
            category="administrative",
            title="Ride status changed",
            body="Open Tail End Charlie for the current ride state.",
            critical=False,
            all_members=True,
        )
    return None


class ApnsPushProvider:
    def __init__(self, settings: Settings) -> None:
        encoded_key = settings.apns_private_key_base64
        if encoded_key is None:
            raise ValueError("APNs key is not configured")
        private_key = base64.b64decode(encoded_key.get_secret_value())
        self._key = serialization.load_pem_private_key(private_key, password=None)
        if not isinstance(self._key, ec.EllipticCurvePrivateKey):
            raise ValueError("APNs private key must be an EC key")
        self._team_id = settings.apns_team_id
        self._key_id = settings.apns_key_id
        self._bundle_id = settings.apns_bundle_id
        host = (
            "https://api.sandbox.push.apple.com"
            if settings.apns_sandbox
            else "https://api.push.apple.com"
        )
        self._host = host
        self._client = httpx.Client(
            http2=True,
            timeout=settings.push_delivery_timeout_seconds,
        )
        self._cached_jwt: tuple[str, float] | None = None

    def send(self, token: str, message: PushMessage) -> PushProviderResult:
        aps: dict[str, Any] = {
            "alert": {"title": message.title, "body": message.body},
            "sound": "default" if message.critical else None,
            "thread-id": f"ride-{base64url(sha256(message.ride_id.encode()))[:24]}",
        }
        aps = {key: value for key, value in aps.items() if value is not None}
        response = self._client.post(
            f"{self._host}/3/device/{token}",
            headers={
                "authorization": f"bearer {self._jwt()}",
                "apns-topic": self._bundle_id,
                "apns-push-type": "alert",
                "apns-priority": "10" if message.critical else "5",
                "apns-collapse-id": message.event_id[:64],
            },
            json={
                "aps": aps,
                **message.data,
            },
        )
        if response.status_code == 200:
            return PushProviderResult(
                delivered=True,
                message_id=response.headers.get("apns-id"),
            )
        reason = _json_string(response, "reason") or f"http_{response.status_code}"
        return PushProviderResult(
            delivered=False,
            error_code=reason[:80],
            permanently_invalid=reason
            in {"BadDeviceToken", "DeviceTokenNotForTopic", "Unregistered"},
        )

    def close(self) -> None:
        self._client.close()

    def _jwt(self) -> str:
        now = time.time()
        if self._cached_jwt is not None and now - self._cached_jwt[1] < 50 * 60:
            return self._cached_jwt[0]
        header = base64url(
            json.dumps(
                {"alg": "ES256", "kid": self._key_id},
                separators=(",", ":"),
            ).encode()
        )
        payload = base64url(
            json.dumps(
                {"iss": self._team_id, "iat": int(now)},
                separators=(",", ":"),
            ).encode()
        )
        message = f"{header}.{payload}".encode()
        signature_der = self._key.sign(message, ec.ECDSA(hashes.SHA256()))
        r, s = decode_dss_signature(signature_der)
        signature = base64url(r.to_bytes(32, "big") + s.to_bytes(32, "big"))
        token = f"{header}.{payload}.{signature}"
        self._cached_jwt = (token, now)
        return token


class FcmPushProvider:
    _scope = "https://www.googleapis.com/auth/firebase.messaging"

    def __init__(self, settings: Settings) -> None:
        encoded_key = settings.fcm_private_key_base64
        if encoded_key is None:
            raise ValueError("FCM key is not configured")
        private_key = base64.b64decode(encoded_key.get_secret_value())
        self._key = serialization.load_pem_private_key(private_key, password=None)
        if not isinstance(self._key, rsa.RSAPrivateKey):
            raise ValueError("FCM private key must be an RSA key")
        self._project_id = settings.fcm_project_id
        self._client_email = settings.fcm_client_email
        self._client = httpx.Client(timeout=settings.push_delivery_timeout_seconds)
        self._cached_access_token: tuple[str, float] | None = None

    def send(self, token: str, message: PushMessage) -> PushProviderResult:
        response = self._client.post(
            f"https://fcm.googleapis.com/v1/projects/{self._project_id}/messages:send",
            headers={"authorization": f"Bearer {self._access_token()}"},
            json={
                "message": {
                    "token": token,
                    "notification": {
                        "title": message.title,
                        "body": message.body,
                    },
                    "data": message.data,
                    "android": {
                        "priority": "HIGH" if message.critical else "NORMAL",
                        "notification": {
                            "channel_id": (
                                "ride_safety_alerts" if message.critical else "ride_updates"
                            ),
                            "tag": message.event_id,
                        },
                    },
                }
            },
        )
        if response.status_code == 200:
            return PushProviderResult(
                delivered=True,
                message_id=_json_string(response, "name"),
            )
        code = _fcm_error_code(response) or f"http_{response.status_code}"
        return PushProviderResult(
            delivered=False,
            error_code=code[:80],
            permanently_invalid=code in {"UNREGISTERED", "SENDER_ID_MISMATCH"},
        )

    def close(self) -> None:
        self._client.close()

    def _access_token(self) -> str:
        now = time.time()
        if self._cached_access_token is not None and now < self._cached_access_token[1]:
            return self._cached_access_token[0]
        assertion = self._service_account_assertion(now)
        response = self._client.post(
            "https://oauth2.googleapis.com/token",
            data={
                "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
                "assertion": assertion,
            },
        )
        response.raise_for_status()
        value = response.json()
        token = value.get("access_token")
        expires_in = value.get("expires_in")
        if not isinstance(token, str) or not isinstance(expires_in, int):
            raise ValueError("FCM access token response is invalid")
        self._cached_access_token = (token, now + max(60, expires_in - 60))
        return token

    def _service_account_assertion(self, now: float) -> str:
        header = base64url(
            json.dumps({"alg": "RS256", "typ": "JWT"}, separators=(",", ":")).encode()
        )
        payload = base64url(
            json.dumps(
                {
                    "iss": self._client_email,
                    "scope": self._scope,
                    "aud": "https://oauth2.googleapis.com/token",
                    "iat": int(now),
                    "exp": int(now) + 3600,
                },
                separators=(",", ":"),
            ).encode()
        )
        message = f"{header}.{payload}".encode()
        signature = self._key.sign(message, padding.PKCS1v15(), hashes.SHA256())
        return f"{header}.{payload}.{base64url(signature)}"


def _authorize_installation(
    session: Session,
    *,
    ride_id: str,
    bearer_token: str,
    installation_id: str,
    device_header: str,
) -> None:
    if (
        not ride_id
        or len(ride_id) > 128
        or not installation_id
        or len(installation_id) > 128
        or not hmac.compare_digest(installation_id, device_header)
    ):
        raise RelayServiceError(400, "Ride or installation identity is invalid")
    ride = session.get(Ride, ride_id)
    if ride is None:
        raise RelayServiceError(404, "Ride is not available")
    if not hmac.compare_digest(ride.token_hash, token_hash(bearer_token)):
        raise RelayServiceError(403, "Ride credential rejected")


def _recipient_ids(payload: dict[str, Any]) -> frozenset[str]:
    values = payload.get("recipientRiderIds")
    if not isinstance(values, list):
        return frozenset()
    return frozenset(value for value in values if isinstance(value, str) and 0 < len(value) <= 128)


def _token_aad(ride_id: str, installation_id: str, provider: str) -> bytes:
    return f"push-token-v1\n{ride_id}\n{installation_id}\n{provider}".encode()


def _as_utc(value: datetime) -> datetime:
    return value.replace(tzinfo=UTC) if value.tzinfo is None else value.astimezone(UTC)


def _json_string(response: httpx.Response, key: str) -> str | None:
    try:
        value = response.json().get(key)
    except (ValueError, AttributeError):
        return None
    return value if isinstance(value, str) else None


def _fcm_error_code(response: httpx.Response) -> str | None:
    try:
        value = response.json()
    except ValueError:
        return None
    details = value.get("error", {}).get("details", [])
    if isinstance(details, list):
        for detail in details:
            if not isinstance(detail, dict):
                continue
            code = detail.get("errorCode")
            if isinstance(code, str):
                return code
    status = value.get("error", {}).get("status")
    return status if isinstance(status, str) else None
