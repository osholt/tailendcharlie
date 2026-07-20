from __future__ import annotations

import hmac
import json
import math
import re
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any

from sqlalchemy import delete, func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from .config import Settings
from .crypto import CursorCodec, DataCipher, base64url, sha256, token_hash
from .models import IdempotencyReplay, Ride, RideJoinCode, StoredEvent
from .schemas import SyncRequest, SyncResponse

IDENTIFIER = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
JOIN_CODE = re.compile(r"^\d{6}$")
TOKEN = re.compile(r"^rr1_[A-Za-z0-9_-]{43}$")
IDEMPOTENCY_KEY = re.compile(r"^rr1-[A-Za-z0-9_-]{43}$")
SIGNATURE = re.compile(r"^[0-9a-f]{64}$")
EVENT_TYPES = {
    "rideCreated",
    "riderJoined",
    "roleChanged",
    "markerStarted",
    "markerPass",
    "markerEnded",
    "statusMessage",
    "riderLocationUpdated",
    "hazardReported",
    "hazardCleared",
    "routeDeviationChanged",
    "routeAlertAcknowledged",
    "rideEnded",
}
PRIORITIES = {"routine", "important", "critical"}
EVENT_FIELDS = {
    "schemaVersion",
    "id",
    "rideId",
    "deviceId",
    "type",
    "priority",
    "createdAt",
    "expiresAt",
    "payload",
    "signature",
    "acknowledged",
}


class RelayServiceError(Exception):
    def __init__(self, status_code: int, message: str) -> None:
        super().__init__(message)
        self.status_code = status_code
        self.message = message


@dataclass(frozen=True)
class ValidatedEvent:
    body: dict[str, Any]
    encoded: bytes
    body_hash: bytes
    event_id: str
    device_id: str
    event_type: str
    created_at: datetime
    client_expires_at: datetime | None


class RelayService:
    def __init__(self, settings: Settings, cipher: DataCipher, cursors: CursorCodec) -> None:
        self._settings = settings
        self._cipher = cipher
        self._cursors = cursors

    def synchronize(
        self,
        session: Session,
        *,
        ride_id: str,
        bearer_token: str,
        idempotency_key: str,
        request_hash: bytes,
        device_header: str,
        request: SyncRequest,
        now: datetime | None = None,
    ) -> dict[str, Any]:
        now = now or datetime.now(UTC)
        self._validate_identity(ride_id, request.deviceId, device_header)
        if not TOKEN.fullmatch(bearer_token):
            raise RelayServiceError(401, "Ride credential rejected")
        if not IDEMPOTENCY_KEY.fullmatch(idempotency_key):
            raise RelayServiceError(400, "Invalid idempotency key")
        if len(request.events) > self._settings.maximum_upload_events:
            raise RelayServiceError(400, "Upload event limit exceeded")

        try:
            cursor_sequence = self._cursors.decode(ride_id, request.cursor)
        except ValueError as error:
            raise RelayServiceError(400, "Invalid cursor") from error

        events = [self._validate_event(value, ride_id, now) for value in request.events]
        if len({event.event_id for event in events}) != len(events):
            raise RelayServiceError(400, "A batch cannot repeat an event ID")

        with session.begin():
            self._purge_expired_for_ride(session, ride_id, now)
            ride = self._get_or_claim_ride(session, ride_id, bearer_token, now)
            ride = session.scalar(select(Ride).where(Ride.id == ride_id).with_for_update())
            if ride is None:
                raise RelayServiceError(500, "Claimed ride is unavailable")
            if not hmac.compare_digest(ride.token_hash, token_hash(bearer_token)):
                raise RelayServiceError(403, "Ride credential rejected")

            replay = session.scalar(
                select(IdempotencyReplay).where(
                    IdempotencyReplay.ride_id == ride_id,
                    IdempotencyReplay.idempotency_key == idempotency_key,
                    IdempotencyReplay.expires_at > now,
                )
            )
            if replay is not None:
                if not hmac.compare_digest(replay.request_hash, request_hash):
                    raise RelayServiceError(409, "Idempotency key conflict")
                value = self._cipher.decrypt_json(
                    replay.response_ciphertext,
                    associated_data=self._replay_aad(ride_id, idempotency_key),
                )
                if not isinstance(value, dict):
                    raise RelayServiceError(500, "Stored replay is invalid")
                return value

            self._validate_event_conflicts(session, ride_id, events)
            accepted_ids = self._store_events(session, ride, events, now)
            response = self._build_response(
                session,
                ride_id=ride_id,
                cursor_sequence=cursor_sequence,
                accepted_ids=accepted_ids,
                now=now,
            )
            replay_ciphertext = self._cipher.encrypt_json(
                response,
                associated_data=self._replay_aad(ride_id, idempotency_key),
            )
            self._store_replay(
                session,
                ride_id=ride_id,
                idempotency_key=idempotency_key,
                request_hash=request_hash,
                response_ciphertext=replay_ciphertext,
                now=now,
            )
            ride.last_seen_at = now
            if ride.ended_at is None:
                ride.delete_after = now + timedelta(hours=self._settings.ride_retention_hours)
            return response

    def register_join_code(
        self,
        session: Session,
        *,
        ride_code: str,
        ride_id: str,
        invite_secret: str,
        bearer_token: str,
        resolve_token: str,
        now: datetime | None = None,
    ) -> None:
        now = now or datetime.now(UTC)
        self._validate_join_code(ride_code)
        self._validate_join_credential(ride_id, invite_secret, bearer_token)
        if not 16 <= len(resolve_token) <= 128:
            raise RelayServiceError(400, "Invalid ride credential")
        credential_hash = token_hash(bearer_token)
        secret_ciphertext = self._cipher.encrypt_json(
            {"inviteSecret": invite_secret, "resolveToken": resolve_token},
            associated_data=self._join_code_aad(ride_code),
        )
        with session.begin():
            session.execute(delete(RideJoinCode).where(RideJoinCode.expires_at <= now))
            existing = session.get(RideJoinCode, ride_code)
            if existing is not None:
                same_ride = existing.ride_id == ride_id
                same_credential = hmac.compare_digest(existing.token_hash, credential_hash)
                if same_ride and same_credential:
                    existing.secret_ciphertext = secret_ciphertext
                    return
                raise RelayServiceError(409, "Ride code is already in use")
            session.add(
                RideJoinCode(
                    code=ride_code,
                    ride_id=ride_id,
                    token_hash=credential_hash,
                    secret_ciphertext=secret_ciphertext,
                    created_at=now,
                    expires_at=now + timedelta(hours=self._settings.ride_retention_hours),
                )
            )

    def resolve_join_code(
        self,
        session: Session,
        *,
        ride_code: str,
        resolve_token: str | None = None,
        now: datetime | None = None,
    ) -> dict[str, str]:
        now = now or datetime.now(UTC)
        self._validate_join_code(ride_code)
        with session.begin():
            record = session.get(RideJoinCode, ride_code)
            if record is None or self._as_utc(record.expires_at) <= now:
                if record is not None:
                    session.delete(record)
                raise RelayServiceError(404, "Ride code is not active")
            try:
                value = self._cipher.decrypt_json(
                    record.secret_ciphertext,
                    associated_data=self._join_code_aad(ride_code),
                )
            except ValueError as error:
                raise RelayServiceError(500, "Ride code record is invalid") from error
            secret = value.get("inviteSecret") if isinstance(value, dict) else None
            stored_resolve_token = value.get("resolveToken") if isinstance(value, dict) else None
            if not isinstance(secret, str) or not 16 <= len(secret) <= 512:
                raise RelayServiceError(500, "Ride code record is invalid")
            valid_resolve_token = (
                isinstance(stored_resolve_token, str) and 16 <= len(stored_resolve_token) <= 128
            )
            if not valid_resolve_token:
                raise RelayServiceError(500, "Ride code record is invalid")
            if resolve_token is not None and not hmac.compare_digest(
                stored_resolve_token, resolve_token
            ):
                raise RelayServiceError(404, "Ride code is not active")
            return {
                "rideId": record.ride_id,
                "rideCode": record.code,
                "inviteSecret": secret,
                "resolveToken": stored_resolve_token,
            }

    @staticmethod
    def _validate_join_code(ride_code: str) -> None:
        if not JOIN_CODE.fullmatch(ride_code):
            raise RelayServiceError(400, "Ride code must be six digits")

    @staticmethod
    def _validate_join_credential(
        ride_id: str,
        invite_secret: str,
        bearer_token: str,
    ) -> None:
        if not IDENTIFIER.fullmatch(ride_id):
            raise RelayServiceError(400, "Invalid ride identity")
        if not 16 <= len(invite_secret) <= 512:
            raise RelayServiceError(400, "Invalid ride credential")
        expected = "rr1_" + base64url(
            hmac.new(
                invite_secret.encode(),
                f"ride-relay-internet-token-v1\n{ride_id}".encode(),
                "sha256",
            ).digest()
        )
        if not hmac.compare_digest(bearer_token, expected):
            raise RelayServiceError(403, "Ride credential rejected")

    @staticmethod
    def _join_code_aad(ride_code: str) -> bytes:
        return f"join-code:{ride_code}".encode()

    def _store_replay(
        self,
        session: Session,
        *,
        ride_id: str,
        idempotency_key: str,
        request_hash: bytes,
        response_ciphertext: bytes,
        now: datetime,
    ) -> None:
        replay_count = (
            session.scalar(
                select(func.count(IdempotencyReplay.id)).where(IdempotencyReplay.ride_id == ride_id)
            )
            or 0
        )
        replay_bytes = (
            session.scalar(
                select(
                    func.coalesce(func.sum(func.length(IdempotencyReplay.response_ciphertext)), 0)
                ).where(IdempotencyReplay.ride_id == ride_id)
            )
            or 0
        )
        if (
            replay_count + 1 > self._settings.maximum_replays_per_ride
            or replay_bytes + len(response_ciphertext)
            > self._settings.maximum_replay_bytes_per_ride
        ):
            raise RelayServiceError(413, "Ride replay quota exceeded")
        session.add(
            IdempotencyReplay(
                ride_id=ride_id,
                idempotency_key=idempotency_key,
                request_hash=request_hash,
                response_ciphertext=response_ciphertext,
                created_at=now,
                expires_at=now + timedelta(hours=self._settings.idempotency_retention_hours),
            )
        )

    def _get_or_claim_ride(
        self,
        session: Session,
        ride_id: str,
        bearer_token: str,
        now: datetime,
    ) -> Ride:
        ride = session.get(Ride, ride_id)
        if ride is not None:
            return ride
        active_rides = (
            session.scalar(select(func.count(Ride.id)).where(Ride.delete_after > now)) or 0
        )
        if active_rides >= self._settings.maximum_active_rides:
            raise RelayServiceError(503, "Relay ride capacity reached")
        claimed = Ride(
            id=ride_id,
            token_hash=token_hash(bearer_token),
            created_at=now,
            last_seen_at=now,
            delete_after=now + timedelta(hours=self._settings.ride_retention_hours),
        )
        try:
            with session.begin_nested():
                session.add(claimed)
                session.flush()
            return claimed
        except IntegrityError:
            ride = session.get(Ride, ride_id)
            if ride is None:
                raise
            return ride

    def _validate_event_conflicts(
        self,
        session: Session,
        ride_id: str,
        events: list[ValidatedEvent],
    ) -> None:
        if not events:
            return
        existing = {
            row.event_id: row.body_hash
            for row in session.scalars(
                select(StoredEvent).where(
                    StoredEvent.ride_id == ride_id,
                    StoredEvent.event_id.in_([event.event_id for event in events]),
                )
            )
        }
        for event in events:
            previous_hash = existing.get(event.event_id)
            if previous_hash is not None and not hmac.compare_digest(
                previous_hash, event.body_hash
            ):
                raise RelayServiceError(409, f"Event identity conflict: {event.event_id}")

    def _store_events(
        self,
        session: Session,
        ride: Ride,
        events: list[ValidatedEvent],
        now: datetime,
    ) -> list[str]:
        accepted_ids: list[str] = []
        stored_count = (
            session.scalar(
                select(func.count(StoredEvent.sequence)).where(StoredEvent.ride_id == ride.id)
            )
            or 0
        )
        stored_bytes = (
            session.scalar(
                select(func.coalesce(func.sum(func.length(StoredEvent.body_ciphertext)), 0)).where(
                    StoredEvent.ride_id == ride.id
                )
            )
            or 0
        )
        for event in events:
            accepted_ids.append(event.event_id)
            existing = session.scalar(
                select(StoredEvent.sequence).where(
                    StoredEvent.ride_id == ride.id,
                    StoredEvent.event_id == event.event_id,
                )
            )
            if existing is not None:
                continue
            retention_expiry = now + self._maximum_event_retention(event.event_type)
            expires_at = retention_expiry
            if event.client_expires_at is not None:
                expires_at = min(expires_at, event.client_expires_at)
            expires_at = min(expires_at, self._as_utc(ride.delete_after))
            if expires_at <= now:
                continue
            projected_bytes = stored_bytes + len(event.encoded) + 28
            if (
                stored_count + 1 > self._settings.maximum_events_per_ride
                or projected_bytes > self._settings.maximum_stored_bytes_per_ride
            ):
                raise RelayServiceError(413, "Ride storage quota exceeded")
            session.add(
                StoredEvent(
                    ride_id=ride.id,
                    event_id=event.event_id,
                    device_id=event.device_id,
                    event_type=event.event_type,
                    created_at=event.created_at,
                    expires_at=expires_at,
                    body_hash=event.body_hash,
                    body_ciphertext=self._cipher.encrypt_json(
                        event.body,
                        associated_data=self._event_aad(ride.id, event.event_id),
                    ),
                )
            )
            stored_count += 1
            stored_bytes = projected_bytes
            if event.event_type == "rideEnded" and ride.ended_at is None:
                ride.ended_at = now
                ride.delete_after = min(
                    self._as_utc(ride.delete_after),
                    now + timedelta(hours=self._settings.ended_ride_grace_hours),
                )
        session.flush()
        return accepted_ids

    def _build_response(
        self,
        session: Session,
        *,
        ride_id: str,
        cursor_sequence: int,
        accepted_ids: list[str],
        now: datetime,
    ) -> dict[str, Any]:
        rows = session.scalars(
            select(StoredEvent)
            .where(
                StoredEvent.ride_id == ride_id,
                StoredEvent.sequence > cursor_sequence,
                StoredEvent.expires_at > now,
            )
            .order_by(StoredEvent.sequence)
            .limit(self._settings.maximum_download_events + 1)
        ).all()
        result_events: list[dict[str, Any]] = []
        last_sequence = cursor_sequence
        for row in rows[: self._settings.maximum_download_events]:
            value = self._cipher.decrypt_json(
                row.body_ciphertext,
                associated_data=self._event_aad(ride_id, row.event_id),
            )
            if not isinstance(value, dict):
                raise RelayServiceError(500, "Stored event is invalid")
            candidate_events = [*result_events, value]
            candidate = SyncResponse(
                cursor=self._cursors.encode(ride_id, row.sequence),
                acceptedEventIds=accepted_ids,
                events=candidate_events,
            ).model_dump()
            encoded = json.dumps(candidate, separators=(",", ":"), allow_nan=False).encode()
            if len(encoded) > self._settings.maximum_response_bytes:
                break
            result_events = candidate_events
            last_sequence = row.sequence
        return SyncResponse(
            cursor=self._cursors.encode(ride_id, last_sequence),
            acceptedEventIds=accepted_ids,
            events=result_events,
        ).model_dump()

    def _validate_event(
        self,
        value: dict[str, Any],
        ride_id: str,
        now: datetime,
    ) -> ValidatedEvent:
        if set(value) != EVENT_FIELDS:
            raise RelayServiceError(400, "Event fields are invalid")
        if value.get("schemaVersion") != 1 or value.get("rideId") != ride_id:
            raise RelayServiceError(400, "Event is invalid for this ride")
        event_id = value.get("id")
        device_id = value.get("deviceId")
        event_type = value.get("type")
        if not isinstance(event_id, str) or not IDENTIFIER.fullmatch(event_id):
            raise RelayServiceError(400, "Event ID is invalid")
        if not isinstance(device_id, str) or not IDENTIFIER.fullmatch(device_id):
            raise RelayServiceError(400, "Event device is invalid")
        if event_type not in EVENT_TYPES or value.get("priority") not in PRIORITIES:
            raise RelayServiceError(400, "Event type or priority is invalid")
        if not isinstance(value.get("payload"), dict):
            raise RelayServiceError(400, "Event payload must be an object")
        if not isinstance(value.get("acknowledged"), bool):
            raise RelayServiceError(400, "Event acknowledgement flag is invalid")
        signature = value.get("signature")
        if not isinstance(signature, str) or not SIGNATURE.fullmatch(signature):
            raise RelayServiceError(400, "Event signature is invalid")
        created_at = self._parse_timestamp(value.get("createdAt"), "createdAt")
        if created_at > now + timedelta(minutes=10):
            raise RelayServiceError(400, "Event creation time is too far in the future")
        expires_at = (
            self._parse_timestamp(value["expiresAt"], "expiresAt")
            if value.get("expiresAt") is not None
            else None
        )
        self._validate_json_shape(value, depth=0)
        encoded = json.dumps(
            value,
            separators=(",", ":"),
            sort_keys=True,
            ensure_ascii=False,
            allow_nan=False,
        ).encode()
        if len(encoded) > self._settings.maximum_event_bytes:
            raise RelayServiceError(413, f"Event exceeds size limit: {event_id}")
        return ValidatedEvent(
            body=value,
            encoded=encoded,
            body_hash=sha256(encoded),
            event_id=event_id,
            device_id=device_id,
            event_type=event_type,
            created_at=created_at,
            client_expires_at=expires_at,
        )

    @staticmethod
    def _validate_identity(ride_id: str, body_device: str, header_device: str) -> None:
        if not IDENTIFIER.fullmatch(ride_id):
            raise RelayServiceError(400, "Ride identity is invalid")
        if not IDENTIFIER.fullmatch(body_device) or body_device != header_device:
            raise RelayServiceError(400, "Device identity headers do not match")

    @staticmethod
    def _parse_timestamp(value: Any, field: str) -> datetime:
        if not isinstance(value, str) or len(value) > 40:
            raise RelayServiceError(400, f"Event {field} is invalid")
        try:
            parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError as error:
            raise RelayServiceError(400, f"Event {field} is invalid") from error
        if parsed.tzinfo is None:
            raise RelayServiceError(400, f"Event {field} must include a timezone")
        return parsed.astimezone(UTC)

    @classmethod
    def _validate_json_shape(cls, value: Any, *, depth: int) -> None:
        if depth > 16:
            raise RelayServiceError(400, "Event JSON is too deeply nested")
        if isinstance(value, dict):
            if len(value) > 128:
                raise RelayServiceError(400, "Event object has too many fields")
            for key, item in value.items():
                if not isinstance(key, str) or len(key) > 256:
                    raise RelayServiceError(400, "Event object key is invalid")
                cls._validate_json_shape(item, depth=depth + 1)
        elif isinstance(value, list):
            if len(value) > 1000:
                raise RelayServiceError(400, "Event array is too large")
            for item in value:
                cls._validate_json_shape(item, depth=depth + 1)
        elif isinstance(value, str) and len(value) > 4096:
            raise RelayServiceError(400, "Event string is too long")
        elif isinstance(value, float) and not math.isfinite(value):
            raise RelayServiceError(400, "Event number must be finite")
        elif value is not None and not isinstance(value, (str, int, float, bool)):
            raise RelayServiceError(400, "Event JSON value is invalid")

    @staticmethod
    def _maximum_event_retention(event_type: str) -> timedelta:
        return {
            "riderLocationUpdated": timedelta(minutes=30),
            "statusMessage": timedelta(hours=2),
            "routeDeviationChanged": timedelta(hours=2),
            "routeAlertAcknowledged": timedelta(hours=2),
            "hazardReported": timedelta(hours=24),
            "hazardCleared": timedelta(hours=24),
        }.get(event_type, timedelta(hours=72))

    @staticmethod
    def _as_utc(value: datetime) -> datetime:
        return value.replace(tzinfo=UTC) if value.tzinfo is None else value.astimezone(UTC)

    @staticmethod
    def _purge_expired_for_ride(session: Session, ride_id: str, now: datetime) -> None:
        session.execute(
            delete(StoredEvent).where(
                StoredEvent.ride_id == ride_id,
                StoredEvent.expires_at <= now,
            )
        )
        session.execute(
            delete(IdempotencyReplay).where(
                IdempotencyReplay.ride_id == ride_id,
                IdempotencyReplay.expires_at <= now,
            )
        )

    @staticmethod
    def _event_aad(ride_id: str, event_id: str) -> bytes:
        return f"event:{ride_id}:{event_id}".encode()

    @staticmethod
    def _replay_aad(ride_id: str, idempotency_key: str) -> bytes:
        return f"replay:{ride_id}:{idempotency_key}".encode()


def purge_expired(session: Session, now: datetime | None = None) -> tuple[int, int, int, int]:
    now = now or datetime.now(UTC)
    with session.begin():
        events = session.execute(delete(StoredEvent).where(StoredEvent.expires_at <= now))
        replays = session.execute(
            delete(IdempotencyReplay).where(IdempotencyReplay.expires_at <= now)
        )
        rides = session.execute(delete(Ride).where(Ride.delete_after <= now))
        join_codes = session.execute(delete(RideJoinCode).where(RideJoinCode.expires_at <= now))
    return (
        events.rowcount or 0,
        replays.rowcount or 0,
        rides.rowcount or 0,
        join_codes.rowcount or 0,
    )
