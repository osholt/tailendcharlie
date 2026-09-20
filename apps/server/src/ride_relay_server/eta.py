"""Location-free, equal-contributor motorcycle ETA calibration.

One replaceable coarse profile per random credential. No trip-level records,
heatmap identity, absolute speeds, locations, or ride dates are accepted.
"""

from __future__ import annotations

import re
from datetime import UTC, date, datetime, timedelta
from statistics import median
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator
from sqlalchemy import delete, select
from sqlalchemy.orm import Session

from .crypto import token_hash
from .models import EtaProfile
from .service import RelayServiceError

MIN_CONTRIBUTORS = 20


class EtaProfileRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    schemaVersion: Literal[1]
    consentVersion: Literal["2026-09-v1"]
    bands: dict[Literal["urban", "mixed", "open"], float] = Field(max_length=3)

    @field_validator("bands")
    @classmethod
    def coarse_ratios(cls, values: dict[str, float]) -> dict[str, float]:
        for ratio in values.values():
            if not 0.8 <= ratio <= 1.2 or abs(ratio * 20 - round(ratio * 20)) > 1e-8:
                raise ValueError("Ratios must be in 0.05 steps between 0.8 and 1.2")
        return values


def credential_hash(authorization: str) -> bytes:
    if not re.fullmatch(r"Eta eta1_[A-Za-z0-9_-]{43}", authorization):
        raise RelayServiceError(401, "ETA credential required")
    return token_hash(authorization.removeprefix("Eta "))


def save_profile(session: Session, authorization: str, payload: EtaProfileRequest) -> None:
    key = credential_hash(authorization)
    today = datetime.now(UTC).date()
    # Repeated uploads replace this contributor's profile, never increase weight.
    session.merge(
        EtaProfile(credential_hash=key, bands=payload.bands, expires_on=today + timedelta(days=90))
    )
    session.commit()


def remove_profile(session: Session, authorization: str) -> None:
    session.execute(
        delete(EtaProfile).where(EtaProfile.credential_hash == credential_hash(authorization))
    )
    session.commit()


def public_factors(session: Session, *, today: date | None = None) -> dict[str, object]:
    today = today or datetime.now(UTC).date()
    profiles = session.scalars(select(EtaProfile).where(EtaProfile.expires_on > today))
    values: dict[str, list[float]] = {band: [] for band in ("urban", "mixed", "open")}
    for profile in profiles:
        for band, ratio in profile.bands.items():
            values[band].append(ratio)
    factors = {}
    for band, ratios in values.items():
        if len(ratios) >= MIN_CONTRIBUTORS:
            # Strong prior: launch-size cohorts have only half weight. Bound
            # both directions, and publish no exact counts or individual data.
            factor = 1 + (median(ratios) - 1) * min(0.75, len(ratios) / (len(ratios) + 20))
            factors[band] = round(max(0.85, min(1.15, factor)) * 20) / 20
    return {"schemaVersion": 1, "minimumContributors": MIN_CONTRIBUTORS, "factors": factors}


def cleanup_eta(session: Session) -> None:
    session.execute(delete(EtaProfile).where(EtaProfile.expires_on <= datetime.now(UTC).date()))
    session.commit()
