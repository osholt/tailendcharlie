from __future__ import annotations

from collections.abc import Iterable
from dataclasses import dataclass
from datetime import UTC, datetime

from sqlalchemy import select
from sqlalchemy.orm import Session

from .models import RideMember


@dataclass(frozen=True)
class MembershipEvent:
    device_id: str
    event_type: str
    created_at: datetime
    payload: dict[str, object]


def project_membership_events(
    session: Session,
    *,
    ride_id: str,
    events: Iterable[MembershipEvent],
) -> None:
    """Apply an accepted event batch with one lookup, not one query per event."""

    batch = list(events)
    if not batch:
        return
    device_ids = {event.device_id for event in batch}
    members = {
        member.device_id: member
        for member in session.scalars(
            select(RideMember).where(
                RideMember.ride_id == ride_id,
                RideMember.device_id.in_(device_ids),
            )
        )
    }
    for event in batch:
        member = members.get(event.device_id)
        if member is None:
            member = RideMember(
                ride_id=ride_id,
                device_id=event.device_id,
                role="rider",
                state="joined",
                last_seen_at=event.created_at,
            )
            session.add(member)
            members[event.device_id] = member
        elif _as_utc(event.created_at) > _as_utc(member.last_seen_at):
            member.last_seen_at = event.created_at

        if event.event_type == "riderJoined":
            member.role = safe_role(event.payload.get("role"))
            member.state = "joined"
        elif event.event_type == "roleChanged":
            member.role = safe_role(event.payload.get("role"))
        elif event.event_type == "markerStarted":
            member.role = "marker"
        elif event.event_type == "markerEnded":
            member.role = safe_role(event.payload.get("previousRole"))
        elif event.event_type == "riderLeft":
            member.state = "left"


def safe_role(value: object) -> str:
    if value in {"lead", "rider", "tailEndCharlie", "marker"}:
        return str(value)
    return "rider"


def _as_utc(value: datetime) -> datetime:
    return value.replace(tzinfo=UTC) if value.tzinfo is None else value.astimezone(UTC)
