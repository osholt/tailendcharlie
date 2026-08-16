from __future__ import annotations

import hmac
import math
from collections import defaultdict
from datetime import UTC, date, datetime, timedelta

from sqlalchemy import delete, func, select, update
from sqlalchemy.orm import Session

from .crypto import base64url, sha256, token_hash
from .models import (
    HeatmapContributor,
    HeatmapContributorCell,
    HeatmapPublicCell,
    HeatmapSnapshot,
    HeatmapUploadReceipt,
)
from .schemas import HeatmapContributionRequest, HeatmapContributorRegistrationRequest
from .service import RelayServiceError

CANONICAL_ZOOM = 17
MIN_PUBLIC_ZOOM = 8
MAX_PUBLIC_CELLS = 5_000
MIN_CONTRIBUTORS = 3
UK_WEST = -11.5
UK_EAST = 3.0
UK_SOUTH = 49.0
UK_NORTH = 61.5


def expected_proof(handle: str, secret: str) -> str:
    digest = hmac.new(
        secret.encode("ascii"),
        f"tail-end-charlie-heatmap-v1\n{handle}".encode(),
        "sha256",
    ).digest()
    return "hmp1_" + base64url(digest)


def register_contributor(
    session: Session,
    payload: HeatmapContributorRegistrationRequest,
    *,
    today: date | None = None,
) -> dict[str, object]:
    today = today or datetime.now(UTC).date()
    handle_hash = token_hash(payload.clientHandle)
    proof_hash = token_hash(payload.proof)
    existing = session.get(HeatmapContributor, handle_hash)
    if existing is not None:
        if not hmac.compare_digest(existing.proof_hash, proof_hash):
            raise RelayServiceError(409, "Heatmap contributor handle is already registered")
        existing.last_seen_on = today
        session.commit()
    else:
        session.add(
            HeatmapContributor(
                handle_hash=handle_hash,
                proof_hash=proof_hash,
                consent_version=payload.consentVersion,
                created_on=today,
                last_seen_on=today,
            )
        )
        session.commit()
    return {
        "schemaVersion": 1,
        "handle": payload.clientHandle,
        "serverNonce": "hmn1_" + base64url(sha256(handle_hash + today.isoformat().encode())[:16]),
    }


def authenticate_contributor(session: Session, authorization: str) -> HeatmapContributor:
    if not authorization.startswith("Heatmap "):
        raise RelayServiceError(401, "Heatmap contributor credential required")
    token = authorization[len("Heatmap ") :]
    if "." not in token:
        raise RelayServiceError(401, "Heatmap contributor credential is invalid")
    handle, secret = token.split(".", 1)
    if not (
        handle.startswith("hm1_")
        and len(handle) == 47
        and secret.startswith("hms1_")
        and len(secret) == 48
    ):
        raise RelayServiceError(401, "Heatmap contributor credential is invalid")
    contributor = session.get(HeatmapContributor, token_hash(handle))
    supplied = token_hash(expected_proof(handle, secret))
    if contributor is None or not hmac.compare_digest(contributor.proof_hash, supplied):
        raise RelayServiceError(401, "Heatmap contributor credential is invalid")
    return contributor


def accept_contribution(
    session: Session,
    contributor: HeatmapContributor,
    payload: HeatmapContributionRequest,
    *,
    maximum_uploads_per_day: int,
    today: date | None = None,
) -> dict[str, object]:
    today = today or datetime.now(UTC).date()
    upload_hash = token_hash(payload.uploadId)
    receipt_key = (contributor.handle_hash, upload_hash)
    if session.get(HeatmapUploadReceipt, receipt_key) is not None:
        return {"schemaVersion": 1, "accepted": True, "duplicate": True}

    uploads_today = session.scalar(
        select(func.count())
        .select_from(HeatmapUploadReceipt)
        .where(
            HeatmapUploadReceipt.handle_hash == contributor.handle_hash,
            HeatmapUploadReceipt.received_on == today,
        )
    )
    if int(uploads_today or 0) >= maximum_uploads_per_day:
        raise RelayServiceError(429, "Daily heatmap contribution limit exceeded")

    for cell in payload.cells:
        if not tile_is_in_supported_region(cell.x, cell.y, cell.z):
            raise RelayServiceError(400, "Heatmap cells must be inside the UK and Isle of Man")

    month = today.replace(day=1)
    for cell in payload.cells:
        key = (contributor.handle_hash, month, cell.z, cell.x, cell.y)
        stored = session.get(HeatmapContributorCell, key)
        if stored is None:
            session.add(
                HeatmapContributorCell(
                    handle_hash=contributor.handle_hash,
                    receipt_month=month,
                    z=cell.z,
                    x=cell.x,
                    y=cell.y,
                    visit_count=1,
                )
            )
        else:
            stored.visit_count = min(20, stored.visit_count + 1)
    session.add(
        HeatmapUploadReceipt(
            handle_hash=contributor.handle_hash,
            upload_id_hash=upload_hash,
            received_on=today,
            delete_after=today + timedelta(days=30),
        )
    )
    contributor.last_seen_on = today
    session.commit()
    return {
        "schemaVersion": 1,
        "accepted": True,
        "duplicate": False,
        "cellCount": len(payload.cells),
    }


def revoke_contributor(
    session: Session,
    contributor: HeatmapContributor,
    *,
    today: date | None = None,
) -> dict[str, object]:
    today = today or datetime.now(UTC).date()
    active = session.scalar(
        select(HeatmapSnapshot)
        .where(HeatmapSnapshot.active.is_(True))
        .order_by(HeatmapSnapshot.published_on.desc())
    )
    session.delete(contributor)
    session.commit()
    return {
        "schemaVersion": 1,
        "removed": True,
        "lastSnapshotVersion": active.version if active is not None else None,
        "nextSnapshotDueBy": (today + timedelta(days=1)).isoformat(),
    }


def rebuild_public_snapshot(
    session: Session,
    *,
    today: date | None = None,
) -> HeatmapSnapshot:
    today = today or datetime.now(UTC).date()
    version = f"hmsnap1-{today:%Y%m%d}"
    existing = session.get(HeatmapSnapshot, version)
    if existing is not None:
        return existing

    coverage: dict[tuple[int, int, int], dict[bytes, int]] = defaultdict(lambda: defaultdict(int))
    for row in session.scalars(select(HeatmapContributorCell)):
        for zoom in range(MIN_PUBLIC_ZOOM, CANONICAL_ZOOM + 1):
            shift = CANONICAL_ZOOM - zoom
            key = (zoom, row.x >> shift, row.y >> shift)
            coverage[key][row.handle_hash] += row.visit_count

    snapshot = HeatmapSnapshot(version=version, published_on=today, active=False)
    session.add(snapshot)
    session.flush()
    for (zoom, x, y), contributors in coverage.items():
        count = len(contributors)
        if count < MIN_CONTRIBUTORS:
            continue
        visits = sum(contributors.values())
        session.add(
            HeatmapPublicCell(
                snapshot_version=version,
                z=zoom,
                x=x,
                y=y,
                contributor_bucket=_contributor_bucket(count),
                intensity_bucket=_intensity_bucket(visits),
            )
        )
    session.execute(update(HeatmapSnapshot).values(active=False))
    snapshot.active = True
    session.flush()
    session.execute(delete(HeatmapSnapshot).where(HeatmapSnapshot.version != snapshot.version))
    session.commit()
    return snapshot


def public_cells(
    session: Session,
    *,
    west: float,
    south: float,
    east: float,
    north: float,
    zoom: int,
) -> dict[str, object]:
    validate_viewport(west, south, east, north, zoom)
    snapshot = session.scalar(
        select(HeatmapSnapshot)
        .where(HeatmapSnapshot.active.is_(True))
        .order_by(HeatmapSnapshot.published_on.desc())
    )
    today = datetime.now(UTC).date()
    if snapshot is None or snapshot.published_on < today:
        snapshot = rebuild_public_snapshot(session, today=today)
    resolution = min(CANONICAL_ZOOM, max(MIN_PUBLIC_ZOOM, zoom))
    minimum_x, minimum_y = tile_for_point(north, west, resolution)
    maximum_x, maximum_y = tile_for_point(south, east, resolution)
    rows = list(
        session.scalars(
            select(HeatmapPublicCell)
            .where(
                HeatmapPublicCell.snapshot_version == snapshot.version,
                HeatmapPublicCell.z == resolution,
                HeatmapPublicCell.x >= minimum_x,
                HeatmapPublicCell.x <= maximum_x,
                HeatmapPublicCell.y >= minimum_y,
                HeatmapPublicCell.y <= maximum_y,
            )
            .limit(MAX_PUBLIC_CELLS + 1)
        )
    )
    if len(rows) > MAX_PUBLIC_CELLS:
        raise RelayServiceError(400, "Heatmap viewport contains too much coverage")
    return {
        "type": "FeatureCollection",
        "schemaVersion": 1,
        "snapshotVersion": snapshot.version,
        "snapshotDate": snapshot.published_on.isoformat(),
        "resolution": resolution,
        "sparseCoverageHidden": True,
        "features": [
            {
                "type": "Feature",
                "id": f"{row.z}/{row.x}/{row.y}",
                "properties": {
                    "contributors": row.contributor_bucket,
                    "intensity": row.intensity_bucket,
                    "weight": _weight(row.intensity_bucket),
                },
                "geometry": {
                    "type": "Point",
                    "coordinates": list(tile_center(row.x, row.y, row.z)),
                },
            }
            for row in rows
        ],
    }


def cleanup_heatmap(session: Session, *, today: date | None = None) -> tuple[int, int, int]:
    today = today or datetime.now(UTC).date()
    retention_start = _subtract_months(today.replace(day=1), 24)
    receipts = session.execute(
        delete(HeatmapUploadReceipt).where(HeatmapUploadReceipt.delete_after <= today)
    ).rowcount
    cells = session.execute(
        delete(HeatmapContributorCell).where(HeatmapContributorCell.receipt_month < retention_start)
    ).rowcount
    inactive_before = today - timedelta(days=90)
    contributors = session.execute(
        delete(HeatmapContributor).where(
            HeatmapContributor.last_seen_on < inactive_before,
            ~HeatmapContributor.handle_hash.in_(select(HeatmapContributorCell.handle_hash)),
            ~HeatmapContributor.handle_hash.in_(select(HeatmapUploadReceipt.handle_hash)),
        )
    ).rowcount
    session.commit()
    return int(receipts or 0), int(cells or 0), int(contributors or 0)


def validate_viewport(west: float, south: float, east: float, north: float, zoom: int) -> None:
    if (
        west < UK_WEST
        or east > UK_EAST
        or south < UK_SOUTH
        or north > UK_NORTH
        or west >= east
        or south >= north
        or zoom < 6
        or zoom > 18
        or east - west > 8
        or north - south > 8
        or (east - west) * (north - south) > 25
    ):
        raise RelayServiceError(400, "A bounded UK heatmap viewport is required")


def tile_for_point(latitude: float, longitude: float, zoom: int) -> tuple[int, int]:
    count = 1 << zoom
    latitude = min(85.05112878, max(-85.05112878, latitude))
    x = int((longitude + 180.0) / 360.0 * count)
    radians = math.radians(latitude)
    y = int((1.0 - math.asinh(math.tan(radians)) / math.pi) / 2.0 * count)
    return max(0, min(count - 1, x)), max(0, min(count - 1, y))


def tile_center(x: int, y: int, zoom: int) -> tuple[float, float]:
    count = 1 << zoom
    longitude = (x + 0.5) / count * 360.0 - 180.0
    mercator = math.pi * (1 - 2 * (y + 0.5) / count)
    latitude = math.degrees(math.atan(math.sinh(mercator)))
    return longitude, latitude


def tile_is_in_supported_region(x: int, y: int, zoom: int) -> bool:
    longitude, latitude = tile_center(x, y, zoom)
    return UK_WEST <= longitude <= UK_EAST and UK_SOUTH <= latitude <= UK_NORTH


def _contributor_bucket(count: int) -> str:
    if count >= 10:
        return "10+"
    if count >= 5:
        return "5-9"
    return "3-4"


def _intensity_bucket(visits: int) -> str:
    if visits > 50:
        return "very_high"
    if visits > 20:
        return "high"
    if visits > 5:
        return "medium"
    return "low"


def _weight(bucket: str) -> float:
    return {"low": 0.25, "medium": 0.5, "high": 0.75, "very_high": 1.0}[bucket]


def _subtract_months(value: date, months: int) -> date:
    absolute = value.year * 12 + value.month - 1 - months
    return date(absolute // 12, absolute % 12 + 1, 1)
