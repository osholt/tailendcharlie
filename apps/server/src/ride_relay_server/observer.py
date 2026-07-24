from __future__ import annotations

import hmac
import re
import secrets
import threading
import uuid
from collections.abc import Callable
from datetime import UTC, datetime, timedelta
from typing import Any

from sqlalchemy import func, select, update
from sqlalchemy.orm import Session

from .config import Settings
from .crypto import DataCipher, base64url, token_hash
from .models import ObserverGrant, Ride
from .schemas import CreateObserverGrantRequest, PublishObserverSnapshotRequest
from .service import RelayServiceError

IDENTIFIER = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
MANAGEMENT_TOKEN = re.compile(r"^om1_[A-Za-z0-9_-]{43}$")
PUBLISHER_TOKEN = re.compile(r"^op1_[A-Za-z0-9_-]{43}$")
OBSERVER_TOKEN = re.compile(r"^ro1_[A-Za-z0-9_-]{43}$")
RIDE_TOKEN = re.compile(r"^rr1_[A-Za-z0-9_-]{43}$")
_CREATE_LOCKS = tuple(threading.Lock() for _ in range(64))


def create_observer_grant(
    session: Session,
    *,
    settings: Settings,
    ride_id: str,
    bearer_token: str,
    request: CreateObserverGrantRequest,
    now: datetime | None = None,
) -> tuple[ObserverGrant, str, str, str]:
    now = now or datetime.now(UTC)
    label = " ".join(request.label.split())
    if not label:
        raise RelayServiceError(400, "Observer label is required")
    lock_index = int.from_bytes(ride_id.encode()[:8].ljust(8, b"\0")) % len(_CREATE_LOCKS)
    with _CREATE_LOCKS[lock_index]:
        with session.begin():
            ride = _authenticated_ride(
                session,
                ride_id,
                bearer_token,
                lock_for_update=True,
            )
            active_count = (
                session.scalar(
                    select(func.count(ObserverGrant.id)).where(
                        ObserverGrant.ride_id == ride_id,
                        ObserverGrant.revoked_at.is_(None),
                        ObserverGrant.expires_at > now,
                    )
                )
                or 0
            )
            if active_count >= settings.maximum_observer_grants_per_ride:
                raise RelayServiceError(409, "Active observer limit reached")
            management_token = _new_token("om1")
            publisher_token = _new_token("op1")
            observer_token = _new_token("ro1")
            expires_at = min(
                now + timedelta(minutes=request.durationMinutes),
                _as_utc(ride.delete_after),
            )
            grant = ObserverGrant(
                id=str(uuid.uuid4()),
                ride_id=ride_id,
                label=label,
                management_token_hash=token_hash(management_token),
                publisher_token_hash=token_hash(publisher_token),
                observer_token_hash=token_hash(observer_token),
                created_at=now,
                expires_at=expires_at,
            )
            session.add(grant)
            session.flush()
            return grant, management_token, publisher_token, observer_token


def get_managed_observer_grant(
    session: Session,
    *,
    grant_id: str,
    management_token: str,
    now: datetime | None = None,
) -> ObserverGrant:
    return _authorized_grant(
        session,
        grant_id=grant_id,
        supplied_token=management_token,
        pattern=MANAGEMENT_TOKEN,
        expected_hash=lambda grant: grant.management_token_hash,
        now=now,
    )


def revoke_observer_grant(
    session: Session,
    *,
    grant_id: str,
    management_token: str,
    now: datetime | None = None,
) -> None:
    now = now or datetime.now(UTC)
    if not MANAGEMENT_TOKEN.fullmatch(management_token):
        raise RelayServiceError(404, "Observer access is unavailable")
    with session.begin():
        result = session.execute(
            update(ObserverGrant)
            .where(
                ObserverGrant.id == grant_id,
                ObserverGrant.management_token_hash == token_hash(management_token),
                ObserverGrant.revoked_at.is_(None),
                ObserverGrant.expires_at > now,
            )
            .values(
                revoked_at=now,
                snapshot_ciphertext=None,
                snapshot_updated_at=None,
                snapshot_version_at=None,
            )
        )
        if result.rowcount != 1:
            raise RelayServiceError(404, "Observer access is unavailable")


def publish_observer_snapshot(
    session: Session,
    *,
    cipher: DataCipher,
    grant_id: str,
    publisher_token: str,
    request: PublishObserverSnapshotRequest,
    now: datetime | None = None,
) -> None:
    now = now or datetime.now(UTC)
    if request.snapshotGeneratedAt > now + timedelta(minutes=2):
        raise RelayServiceError(400, "Observer snapshot is from the future")
    if request.statusUpdatedAt > now + timedelta(minutes=2):
        raise RelayServiceError(400, "Observer status is from the future")
    if request.assistanceUpdatedAt > now + timedelta(minutes=2):
        raise RelayServiceError(400, "Observer assistance status is from the future")
    if request.position is not None:
        if request.position.recordedAt > now + timedelta(minutes=2):
            raise RelayServiceError(400, "Observer position is from the future")
        if request.position.recordedAt < now - timedelta(hours=24):
            raise RelayServiceError(400, "Observer position is too old")
    if request.assistance is not None:
        if request.assistance.reportedAt > now + timedelta(minutes=2):
            raise RelayServiceError(400, "Observer assistance status is from the future")
        if request.assistance.reportedAt < now - timedelta(hours=2):
            raise RelayServiceError(400, "Observer assistance status is too old")
    if not PUBLISHER_TOKEN.fullmatch(publisher_token):
        raise RelayServiceError(404, "Observer access is unavailable")
    with session.begin():
        grant = _authorized_grant(
            session,
            grant_id=grant_id,
            supplied_token=publisher_token,
            pattern=PUBLISHER_TOKEN,
            expected_hash=lambda value: value.publisher_token_hash,
            now=now,
            lock_for_update=True,
        )
        if (
            grant.snapshot_version_at is not None
            and _as_utc(grant.snapshot_version_at) >= request.snapshotGeneratedAt
        ):
            raise RelayServiceError(409, "Observer snapshot is older than current state")

        current: dict[str, Any] = {}
        if grant.snapshot_ciphertext is not None:
            try:
                decrypted = cipher.decrypt_json(
                    grant.snapshot_ciphertext,
                    associated_data=_snapshot_aad(grant.id),
                )
            except ValueError as error:
                raise RelayServiceError(500, "Stored observer state is invalid") from error
            if not isinstance(decrypted, dict):
                raise RelayServiceError(500, "Stored observer state is invalid")
            current = decrypted

        incoming = request.model_dump(mode="json")
        merged = {
            "subjectName": incoming["subjectName"],
            "rideStatus": current.get("rideStatus", "waiting"),
            "statusUpdatedAt": current.get("statusUpdatedAt"),
            "position": current.get("position"),
            "assistanceUpdatedAt": current.get("assistanceUpdatedAt"),
            "assistance": current.get("assistance"),
        }
        current_status_at = _timestamp(current.get("statusUpdatedAt"))
        if current_status_at is None or request.statusUpdatedAt >= current_status_at:
            merged["rideStatus"] = incoming["rideStatus"]
            merged["statusUpdatedAt"] = incoming["statusUpdatedAt"]

        current_position = current.get("position")
        current_position_at = (
            _timestamp(current_position.get("recordedAt"))
            if isinstance(current_position, dict)
            else None
        )
        if request.position is not None and (
            current_position_at is None or request.position.recordedAt >= current_position_at
        ):
            merged["position"] = incoming["position"]

        current_assistance_at = _timestamp(current.get("assistanceUpdatedAt"))
        if current_assistance_at is None or request.assistanceUpdatedAt >= current_assistance_at:
            merged["assistanceUpdatedAt"] = incoming["assistanceUpdatedAt"]
            merged["assistance"] = incoming["assistance"]

        grant.snapshot_ciphertext = cipher.encrypt_json(
            merged,
            associated_data=_snapshot_aad(grant.id),
        )
        grant.snapshot_updated_at = now
        grant.snapshot_version_at = request.snapshotGeneratedAt


def observer_snapshot(
    session: Session,
    *,
    cipher: DataCipher,
    grant_id: str,
    observer_token: str,
    now: datetime | None = None,
) -> dict[str, Any]:
    now = now or datetime.now(UTC)
    with session.begin():
        grant = _authorized_grant(
            session,
            grant_id=grant_id,
            supplied_token=observer_token,
            pattern=OBSERVER_TOKEN,
            expected_hash=lambda value: value.observer_token_hash,
            now=now,
        )
        grant.last_read_at = now
        snapshot: dict[str, Any] = {}
        if grant.snapshot_ciphertext is not None:
            try:
                value = cipher.decrypt_json(
                    grant.snapshot_ciphertext,
                    associated_data=_snapshot_aad(grant.id),
                )
            except ValueError as error:
                raise RelayServiceError(500, "Stored observer state is invalid") from error
            if not isinstance(value, dict):
                raise RelayServiceError(500, "Stored observer state is invalid")
            snapshot = value

        position = snapshot.get("position")
        recorded_at = _timestamp(position.get("recordedAt")) if isinstance(position, dict) else None
        freshness = "unavailable"
        if recorded_at is not None:
            age = max(timedelta(0), now - recorded_at)
            freshness = (
                "fresh"
                if age <= timedelta(seconds=90)
                else "delayed"
                if age <= timedelta(minutes=5)
                else "offline"
            )
        assistance = snapshot.get("assistance")
        if isinstance(assistance, dict):
            kind = assistance.get("kind")
            reported_at = assistance.get("reportedAt")
            assistance = (
                {
                    "kind": kind,
                    "label": ("Help requested" if kind == "assistance" else "Emergency stop"),
                    "reportedAt": reported_at,
                }
                if kind in {"assistance", "emergencyStop"}
                else None
            )
        else:
            assistance = None
        return {
            "protocolVersion": 1,
            "label": grant.label,
            "subjectName": snapshot.get("subjectName"),
            "rideStatus": snapshot.get("rideStatus", "waiting"),
            "statusUpdatedAt": snapshot.get("statusUpdatedAt"),
            "freshness": freshness,
            "serverTime": now,
            "expiresAt": _as_utc(grant.expires_at),
            "position": position,
            "assistance": assistance,
        }


def grant_json(grant: ObserverGrant) -> dict[str, Any]:
    return {
        "id": grant.id,
        "label": grant.label,
        "createdAt": _as_utc(grant.created_at),
        "expiresAt": _as_utc(grant.expires_at),
        "revokedAt": _as_utc(grant.revoked_at) if grant.revoked_at else None,
    }


def _authenticated_ride(
    session: Session,
    ride_id: str,
    bearer_token: str,
    *,
    lock_for_update: bool = False,
) -> Ride:
    if not IDENTIFIER.fullmatch(ride_id):
        raise RelayServiceError(400, "Ride identity is invalid")
    if not RIDE_TOKEN.fullmatch(bearer_token):
        raise RelayServiceError(403, "Ride credential rejected")
    statement = select(Ride).where(Ride.id == ride_id)
    if lock_for_update:
        statement = statement.with_for_update()
    ride = session.scalar(statement)
    if ride is None:
        raise RelayServiceError(404, "Ride is not ready for observer access")
    if not hmac.compare_digest(ride.token_hash, token_hash(bearer_token)):
        raise RelayServiceError(403, "Ride credential rejected")
    return ride


def _authorized_grant(
    session: Session,
    *,
    grant_id: str,
    supplied_token: str,
    pattern: re.Pattern[str],
    expected_hash: Callable[[ObserverGrant], bytes],
    now: datetime | None,
    lock_for_update: bool = False,
) -> ObserverGrant:
    now = now or datetime.now(UTC)
    if not pattern.fullmatch(supplied_token):
        raise RelayServiceError(404, "Observer access is unavailable")
    statement = select(ObserverGrant).where(ObserverGrant.id == grant_id)
    if lock_for_update:
        statement = statement.with_for_update()
    grant = session.scalar(statement)
    if (
        grant is None
        or grant.revoked_at is not None
        or _as_utc(grant.expires_at) <= now
        or not hmac.compare_digest(
            expected_hash(grant),
            token_hash(supplied_token),
        )
    ):
        raise RelayServiceError(404, "Observer access is unavailable")
    return grant


def _new_token(prefix: str) -> str:
    return f"{prefix}_{base64url(secrets.token_bytes(32))}"


def _timestamp(value: Any) -> datetime | None:
    if not isinstance(value, str) or len(value) > 40:
        return None
    try:
        result = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if result.tzinfo is None:
        return None
    return result.astimezone(UTC)


def _snapshot_aad(grant_id: str) -> bytes:
    return f"observer-snapshot:{grant_id}".encode()


def _as_utc(value: datetime) -> datetime:
    return value.replace(tzinfo=UTC) if value.tzinfo is None else value.astimezone(UTC)
