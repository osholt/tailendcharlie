from __future__ import annotations

import hmac
import json
import math
import re
import secrets
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any

from sqlalchemy import delete, func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from .config import Settings
from .crypto import CursorCodec, DataCipher, base64url, sha256, token_hash
from .gpx import GpxValidationError, validate_gpx
from .membership import MembershipEvent, project_membership_events
from .models import (
    IdempotencyReplay,
    ObserverGrant,
    PreStartPosition,
    Ride,
    RideJoinCode,
    RidePlan,
    StoredEvent,
)
from .schemas import PresenceSyncRequest, SyncRequest, SyncResponse

IDENTIFIER = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
JOIN_CODE = re.compile(r"^\d{6}$")
TOKEN = re.compile(r"^rr1_[A-Za-z0-9_-]{43}$")
IDEMPOTENCY_KEY = re.compile(r"^rr1-[A-Za-z0-9_-]{43}$")
SIGNATURE = re.compile(r"^[0-9a-f]{64}$")
PLAN_CODE_ALPHABET = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"
PLAN_CODE_LENGTH = 8
PLAN_CODE = re.compile(f"^[{PLAN_CODE_ALPHABET}]{{{PLAN_CODE_LENGTH}}}$")
EVENT_TYPES = {
    "rideCreated",
    "riderJoined",
    "riderLeft",
    "roleChanged",
    "rideStarted",
    "markerStarted",
    "markerPass",
    "markerEnded",
    "statusMessage",
    "riderLocationUpdated",
    "hazardReported",
    "hazardCleared",
    "routeDeviationChanged",
    "routeAlertAcknowledged",
    "routeRevisionChunk",
    "routeRevisionPublished",
    "routeCleared",
    "ridePaused",
    "rideResumed",
    "rideEnded",
    "iceInfoShared",
    "iceInfoViewed",
    # Issue #128. Additive: an older client that does not know these names skips
    # them per event and keeps the rest of the batch, so the relay may carry
    # them for the clients that do.
    "tecRoleRequested",
    "tecRoleResponded",
    "rejoinRouteShared",
    # Issue #188. A rider's own phone number, addressed to the ride's
    # coordination roles. Deliberately distinct from "iceInfoShared", which
    # carries a rider's next of kin.
    "riderContactShared",
    # Issues #206/#207. The leader saying a ride that ended has not finished
    # after all. Deliberately not "rideResumed", which is the other half of
    # "ridePaused"; conflating them would make a pause look like a resurrection.
    "rideReopened",
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
        self._pre_start_presence_ttl = timedelta(seconds=settings.pre_start_presence_ttl_seconds)
        self._maximum_pre_start_presence_riders = settings.maximum_pre_start_presence_riders

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
            ride = self._get_or_claim_ride(session, ride_id, bearer_token, now)
            ride = session.scalar(select(Ride).where(Ride.id == ride_id).with_for_update())
            if ride is None:
                raise RelayServiceError(500, "Claimed ride is unavailable")
            if not hmac.compare_digest(ride.token_hash, token_hash(bearer_token)):
                raise RelayServiceError(403, "Ride credential rejected")
            self._purge_expired_for_ride(session, ride, now)

            # Idempotency covers the upload only. Upload and download share one
            # request, and a device with nothing to send repeats a byte-identical
            # body on every poll, so replaying the stored *download* made an idle
            # phone permanently deaf to its peers: it received nothing until it
            # happened to have an event of its own to send. The download is
            # therefore rebuilt from this request's cursor every time, and an
            # empty batch is never stored as a replay at all because it has
            # nothing to be idempotent about.
            replay = (
                session.scalar(
                    select(IdempotencyReplay).where(
                        IdempotencyReplay.ride_id == ride_id,
                        IdempotencyReplay.idempotency_key == idempotency_key,
                        IdempotencyReplay.expires_at > now,
                    )
                )
                if events
                else None
            )
            if replay is not None:
                if not hmac.compare_digest(replay.request_hash, request_hash):
                    raise RelayServiceError(409, "Idempotency key conflict")
                stored = self._cipher.decrypt_json(
                    replay.response_ciphertext,
                    associated_data=self._replay_aad(ride_id, idempotency_key),
                )
                accepted_ids = stored.get("acceptedEventIds") if isinstance(stored, dict) else None
                if not isinstance(accepted_ids, list) or not all(
                    isinstance(value, str) for value in accepted_ids
                ):
                    raise RelayServiceError(500, "Stored replay is invalid")
                response = self._build_response(
                    session,
                    ride_id=ride_id,
                    cursor_sequence=cursor_sequence,
                    accepted_ids=accepted_ids,
                    now=now,
                )
                ride.last_seen_at = now
                if ride.ended_at is None:
                    ride.delete_after = now + timedelta(hours=self._settings.ride_retention_hours)
                return response

            existing_event_ids = self._validate_event_conflicts(session, ride_id, events)
            accepted_ids = self._store_events(
                session,
                ride,
                events,
                existing_event_ids,
                now,
            )
            # Only a finished ride discards live positions. Discarding them at
            # `rideStarted` is what previously severed presence mid-ride and
            # left a rider who joined afterwards with no live channel at all.
            #
            # A batch can carry both an end and the leader's reopen of it
            # (#206/#207), so the last one in the batch decides. Discarding on the
            # end alone would cut presence for a ride that is running again.
            lifecycle = [
                event.event_type
                for event in events
                if event.event_type in ("rideEnded", "rideReopened")
            ]
            if lifecycle and lifecycle[-1] == "rideEnded":
                session.execute(delete(PreStartPosition).where(PreStartPosition.ride_id == ride_id))
            response = self._build_response(
                session,
                ride_id=ride_id,
                cursor_sequence=cursor_sequence,
                accepted_ids=accepted_ids,
                now=now,
            )
            if events:
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

    def synchronize_pre_start_presence(
        self,
        session: Session,
        *,
        ride_id: str,
        bearer_token: str,
        device_header: str,
        request: PresenceSyncRequest,
        live_presence: bool = False,
        client_protocol: int = 1,
        now: datetime | None = None,
    ) -> dict[str, Any]:
        """Ephemeral live positions plus a cursor-independent ride roster.

        ``live_presence`` is the caller's ``live-presence-v2`` capability. A
        caller without it keeps exactly the old read behaviour (no positions
        once the ride has started) but no longer *destroys* the rows a
        live-presence peer depends on: a mixed-version group is the normal case,
        so an older build must never be able to blank a newer one.
        """
        now = now or datetime.now(UTC)
        self._validate_identity(ride_id, request.deviceId, device_header)
        if not TOKEN.fullmatch(bearer_token):
            raise RelayServiceError(401, "Ride credential rejected")
        position = (
            request.position.model_dump(mode="json") if request.position is not None else None
        )
        if position is not None:
            recorded_at = request.position.sample.recordedAt
            if recorded_at < now - timedelta(minutes=5):
                raise RelayServiceError(400, "Presence sample is too old")
            if recorded_at > now + timedelta(minutes=2):
                raise RelayServiceError(400, "Presence sample is from the future")
        with session.begin():
            ride = session.scalar(select(Ride).where(Ride.id == ride_id).with_for_update())
            if ride is None:
                raise RelayServiceError(404, "Ride is not ready for presence")
            if not hmac.compare_digest(ride.token_hash, token_hash(bearer_token)):
                raise RelayServiceError(403, "Ride credential rejected")
            session.execute(
                delete(PreStartPosition).where(
                    PreStartPosition.ride_id == ride_id,
                    PreStartPosition.expires_at <= now,
                )
            )
            phase = self._ride_presence_phase(session, ride_id)
            members = self._presence_members(session, ride_id)
            if phase == "ended":
                session.execute(delete(PreStartPosition).where(PreStartPosition.ride_id == ride_id))
                positions: list[dict[str, Any]] = []
            else:
                existing = session.get(
                    PreStartPosition,
                    (ride_id, request.deviceId),
                )
                if request.clear:
                    if existing is not None:
                        session.delete(existing)
                elif position is not None:
                    if existing is None:
                        rider_count = session.scalar(
                            select(func.count(PreStartPosition.rider_id)).where(
                                PreStartPosition.ride_id == ride_id
                            )
                        )
                        if (rider_count or 0) >= self._maximum_pre_start_presence_riders:
                            raise RelayServiceError(
                                409,
                                "Live presence capacity reached",
                            )
                    expires_at = now + self._pre_start_presence_ttl
                    snapshot = {
                        **position,
                        "riderId": request.deviceId,
                        "receivedAt": now.isoformat(),
                        "expiresAt": expires_at.isoformat(),
                        "livePresence": live_presence,
                        "clientProtocol": client_protocol,
                    }
                    ciphertext = self._cipher.encrypt_json(
                        snapshot,
                        associated_data=self._pre_start_presence_aad(
                            ride_id,
                            request.deviceId,
                        ),
                    )
                    if existing is None:
                        session.add(
                            PreStartPosition(
                                ride_id=ride_id,
                                rider_id=request.deviceId,
                                snapshot_ciphertext=ciphertext,
                                received_at=now,
                                expires_at=expires_at,
                            )
                        )
                    else:
                        existing.snapshot_ciphertext = ciphertext
                        existing.received_at = now
                        existing.expires_at = expires_at
                session.flush()
                if phase == "started" and not live_presence:
                    # A legacy caller reads nothing after the start, as before,
                    # but the stored rows survive for live-presence peers.
                    positions = []
                else:
                    rows = session.scalars(
                        select(PreStartPosition)
                        .where(PreStartPosition.ride_id == ride_id)
                        .order_by(PreStartPosition.rider_id)
                    ).all()
                    positions = [self._decrypt_pre_start_position(row) for row in rows]
        return {
            "protocolVersion": 1,
            "ttlSeconds": int(self._pre_start_presence_ttl.total_seconds()),
            "positions": positions,
            "phase": phase,
            "members": members if live_presence else [],
            # The clock every arrival stamp above was taken on, so a caller can
            # age a peer's position without trusting that peer's own clock.
            "serverTime": now.isoformat(),
        }

    @staticmethod
    def _ride_presence_phase(session: Session, ride_id: str) -> str:
        # Ordered, not a set: a reopen after an end means the ride is running
        # again, and set membership cannot express "which came last" (#206/#207).
        lifecycle_types = list(
            session.scalars(
                select(StoredEvent.event_type)
                .where(
                    StoredEvent.ride_id == ride_id,
                    StoredEvent.event_type.in_(["rideStarted", "rideEnded", "rideReopened"]),
                )
                .order_by(StoredEvent.sequence)
            ).all()
        )
        ended = [name for name in lifecycle_types if name in ("rideEnded", "rideReopened")]
        if ended and ended[-1] == "rideEnded":
            return "ended"
        return "started" if "rideStarted" in lifecycle_types else "open"

    def _presence_members(self, session: Session, ride_id: str) -> list[dict[str, Any]]:
        """The ride roster, read without consulting any caller's cursor.

        Membership events are few and bounded, so this stays cheap. It exists
        because ``riderJoined`` used to be visible only through the bulk event
        batch: one wedged or backed-off sync then hid a participant entirely
        from every other device.
        """
        rows = session.scalars(
            select(StoredEvent)
            .where(
                StoredEvent.ride_id == ride_id,
                StoredEvent.event_type.in_(["rideCreated", "riderJoined", "riderLeft"]),
            )
            .order_by(StoredEvent.sequence)
            .limit(self._maximum_pre_start_presence_riders * 4)
        ).all()
        members: dict[str, dict[str, Any]] = {}
        for row in rows:
            try:
                body = self._cipher.decrypt_json(
                    row.body_ciphertext,
                    associated_data=self._event_aad(ride_id, row.event_id),
                )
            except ValueError:
                continue
            if not isinstance(body, dict):
                continue
            payload = body.get("payload")
            payload = payload if isinstance(payload, dict) else {}
            if row.event_type == "riderLeft":
                member = members.get(row.device_id)
                if member is not None:
                    member["left"] = True
                    # The departure time travels with the flag so a caller can
                    # show *when* a rider left, and can order the departure
                    # against a later rejoin, without waiting for the bulk event
                    # batch to deliver the membership events (issue #144).
                    member["leftAt"] = self._as_utc(row.created_at).isoformat()
                continue
            display_name = payload.get("displayName")
            role = payload.get("role")
            if not isinstance(display_name, str) or not display_name.strip():
                continue
            if not isinstance(role, str) or not role.strip():
                continue
            members[row.device_id] = {
                "riderId": row.device_id,
                "displayName": display_name.strip()[:80],
                "role": role.strip()[:40],
                "joinedAt": self._as_utc(row.created_at).isoformat(),
                "left": False,
            }
        return list(members.values())

    @staticmethod
    def _pre_start_presence_aad(ride_id: str, rider_id: str) -> bytes:
        return f"pre-start-presence-v1\n{ride_id}\n{rider_id}".encode()

    def _decrypt_pre_start_position(
        self,
        row: PreStartPosition,
    ) -> dict[str, Any]:
        value = self._cipher.decrypt_json(
            row.snapshot_ciphertext,
            associated_data=self._pre_start_presence_aad(
                row.ride_id,
                row.rider_id,
            ),
        )
        if not isinstance(value, dict):
            raise RelayServiceError(500, "Stored pre-start presence is invalid")
        return value

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

    def create_plan(
        self,
        session: Session,
        *,
        name: str | None,
        gpx: str,
        now: datetime | None = None,
    ) -> dict[str, str]:
        """A plan is unrelated to the live ride/join-code tables: it never
        carries a ride secret, and fetching one never claims a ride. The
        phone that loads it still runs its own unchanged create-ride flow.
        """
        now = now or datetime.now(UTC)
        if name is not None and len(name) > 200:
            raise RelayServiceError(400, "Plan name is too long")
        try:
            validate_gpx(
                gpx,
                maximum_bytes=self._settings.maximum_plan_bytes,
                maximum_points=self._settings.maximum_plan_points,
            )
        except GpxValidationError as error:
            raise RelayServiceError(400, str(error)) from error
        expires_at = now + timedelta(days=self._settings.plan_retention_days)
        with session.begin():
            session.execute(delete(RidePlan).where(RidePlan.expires_at <= now))
            for _ in range(8):
                code = self._generate_plan_code()
                ciphertext = self._cipher.encrypt_json(gpx, associated_data=self._plan_aad(code))
                try:
                    with session.begin_nested():
                        session.add(
                            RidePlan(
                                code=code,
                                name=name,
                                gpx_ciphertext=ciphertext,
                                created_at=now,
                                expires_at=expires_at,
                            )
                        )
                        session.flush()
                    return {"code": code, "expiresAt": expires_at.isoformat()}
                except IntegrityError:
                    continue
            raise RelayServiceError(500, "Could not allocate a plan code")

    def get_plan(
        self,
        session: Session,
        *,
        code: str,
        now: datetime | None = None,
    ) -> dict[str, Any]:
        now = now or datetime.now(UTC)
        if not PLAN_CODE.fullmatch(code):
            raise RelayServiceError(404, "Plan not found")
        with session.begin():
            record = session.get(RidePlan, code)
            if record is None or self._as_utc(record.expires_at) <= now:
                if record is not None:
                    session.delete(record)
                raise RelayServiceError(404, "Plan not found")
            try:
                gpx = self._cipher.decrypt_json(
                    record.gpx_ciphertext,
                    associated_data=self._plan_aad(code),
                )
            except ValueError as error:
                raise RelayServiceError(500, "Plan record is invalid") from error
            if not isinstance(gpx, str):
                raise RelayServiceError(500, "Plan record is invalid")
            return {
                "code": record.code,
                "name": record.name,
                "gpx": gpx,
                "createdAt": self._as_utc(record.created_at).isoformat(),
                "expiresAt": self._as_utc(record.expires_at).isoformat(),
            }

    @staticmethod
    def _generate_plan_code() -> str:
        return "".join(secrets.choice(PLAN_CODE_ALPHABET) for _ in range(PLAN_CODE_LENGTH))

    @staticmethod
    def _plan_aad(code: str) -> bytes:
        return f"plan:{code}".encode()

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
            stored_event_count=0,
            stored_event_bytes=0,
            membership_projection_ready=True,
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
    ) -> set[str]:
        if not events:
            return set()
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
        return set(existing)

    def _store_events(
        self,
        session: Session,
        ride: Ride,
        events: list[ValidatedEvent],
        existing_event_ids: set[str],
        now: datetime,
    ) -> list[str]:
        accepted_ids: list[str] = []
        membership_events: list[MembershipEvent] = []
        for event in events:
            accepted_ids.append(event.event_id)
            if event.event_id in existing_event_ids:
                continue
            retention_expiry = now + self._maximum_event_retention(event.event_type)
            expires_at = retention_expiry
            if event.client_expires_at is not None:
                expires_at = min(expires_at, event.client_expires_at)
            expires_at = min(expires_at, self._as_utc(ride.delete_after))
            if expires_at <= now:
                continue
            body_ciphertext = self._cipher.encrypt_json(
                event.body,
                associated_data=self._event_aad(ride.id, event.event_id),
            )
            projected_bytes = ride.stored_event_bytes + len(body_ciphertext)
            if (
                ride.stored_event_count + 1 > self._settings.maximum_events_per_ride
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
                    body_ciphertext=body_ciphertext,
                )
            )
            ride.stored_event_count += 1
            ride.stored_event_bytes = projected_bytes
            membership_events.append(
                MembershipEvent(
                    device_id=event.device_id,
                    event_type=event.event_type,
                    created_at=event.created_at,
                    payload=event.body["payload"],
                )
            )
            if event.event_type == "rideEnded" and ride.ended_at is None:
                ride.ended_at = now
                ride.delete_after = min(
                    self._as_utc(ride.delete_after),
                    now + timedelta(hours=self._settings.ended_ride_grace_hours),
                )
            elif event.event_type == "rideReopened" and ride.ended_at is not None:
                # The end shortened this ride's life to the grace period. A ride
                # that is running again gets the full retention window back, or it
                # would be deleted out from under the group (#206/#207).
                ride.ended_at = None
                ride.delete_after = max(
                    self._as_utc(ride.delete_after),
                    now + timedelta(hours=self._settings.ride_retention_hours),
                )
        project_membership_events(session, ride_id=ride.id, events=membership_events)
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
        elif value is not None and not isinstance(value, str | int | float | bool):
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
            # Carries a phone number and medical notes: capped independently
            # of the client-supplied expiry, not left to the 72h default.
            "iceInfoShared": timedelta(hours=2),
            "iceInfoViewed": timedelta(hours=2),
            # A rider's own phone number: the same cap an ICE share gets, for the
            # same reason. The client purges its copy the moment the ride ends;
            # this is the bound that applies whatever a client asks for.
            "riderContactShared": timedelta(hours=2),
            # A rider's intended path: the same retention band as where they
            # actually are, capped here as well as on the client so a share
            # cannot outlive its usefulness even if a client asks it to.
            "rejoinRouteShared": timedelta(minutes=30),
            # Who was asked to cover the back of the group, and what they said.
            # Ride-scoped coordination, not history worth keeping for days.
            "tecRoleRequested": timedelta(hours=2),
            "tecRoleResponded": timedelta(hours=2),
        }.get(event_type, timedelta(hours=72))

    @staticmethod
    def _as_utc(value: datetime) -> datetime:
        return value.replace(tzinfo=UTC) if value.tzinfo is None else value.astimezone(UTC)

    @staticmethod
    def _purge_expired_for_ride(session: Session, ride: Ride, now: datetime) -> None:
        expired_count, expired_bytes = session.execute(
            select(
                func.count(StoredEvent.sequence),
                func.coalesce(func.sum(func.length(StoredEvent.body_ciphertext)), 0),
            ).where(
                StoredEvent.ride_id == ride.id,
                StoredEvent.expires_at <= now,
            )
        ).one()
        session.execute(
            delete(StoredEvent).where(
                StoredEvent.ride_id == ride.id,
                StoredEvent.expires_at <= now,
            )
        )
        ride.stored_event_count = max(0, ride.stored_event_count - int(expired_count or 0))
        ride.stored_event_bytes = max(0, ride.stored_event_bytes - int(expired_bytes or 0))
        session.execute(
            delete(IdempotencyReplay).where(
                IdempotencyReplay.ride_id == ride.id,
                IdempotencyReplay.expires_at <= now,
            )
        )

    @staticmethod
    def _event_aad(ride_id: str, event_id: str) -> bytes:
        return f"event:{ride_id}:{event_id}".encode()

    @staticmethod
    def _replay_aad(ride_id: str, idempotency_key: str) -> bytes:
        return f"replay:{ride_id}:{idempotency_key}".encode()


def purge_expired(
    session: Session,
    now: datetime | None = None,
) -> tuple[int, int, int, int, int, int, int]:
    now = now or datetime.now(UTC)
    with session.begin():
        expired_usage = session.execute(
            select(
                StoredEvent.ride_id,
                func.count(StoredEvent.sequence),
                func.coalesce(func.sum(func.length(StoredEvent.body_ciphertext)), 0),
            )
            .where(StoredEvent.expires_at <= now)
            .group_by(StoredEvent.ride_id)
        ).all()
        if expired_usage:
            ride_ids = [ride_id for ride_id, _, _ in expired_usage]
            rides_by_id = {
                ride.id: ride
                for ride in session.scalars(
                    select(Ride).where(Ride.id.in_(ride_ids)).with_for_update()
                )
            }
            for ride_id, expired_count, expired_bytes in expired_usage:
                if ride := rides_by_id.get(ride_id):
                    ride.stored_event_count = max(
                        0,
                        ride.stored_event_count - int(expired_count or 0),
                    )
                    ride.stored_event_bytes = max(
                        0,
                        ride.stored_event_bytes - int(expired_bytes or 0),
                    )
        events = session.execute(delete(StoredEvent).where(StoredEvent.expires_at <= now))
        replays = session.execute(
            delete(IdempotencyReplay).where(IdempotencyReplay.expires_at <= now)
        )
        rides = session.execute(
            delete(Ride)
            .where(Ride.delete_after <= now)
            .execution_options(synchronize_session=False)
        )
        join_codes = session.execute(delete(RideJoinCode).where(RideJoinCode.expires_at <= now))
        plans = session.execute(delete(RidePlan).where(RidePlan.expires_at <= now))
        observers = session.execute(delete(ObserverGrant).where(ObserverGrant.expires_at <= now))
        pre_start_positions = session.execute(
            delete(PreStartPosition).where(PreStartPosition.expires_at <= now)
        )
    return (
        events.rowcount or 0,
        replays.rowcount or 0,
        rides.rowcount or 0,
        join_codes.rowcount or 0,
        plans.rowcount or 0,
        observers.rowcount or 0,
        pre_start_positions.rowcount or 0,
    )
