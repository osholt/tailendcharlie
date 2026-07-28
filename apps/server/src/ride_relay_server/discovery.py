from __future__ import annotations

import json
import uuid
from datetime import UTC, date, datetime, timedelta

from sqlalchemy import delete, select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from .crypto import sha256
from .models import (
    DiscoveryFeature,
    DiscoveryModerationEvent,
    DiscoveryRoadRating,
    DiscoverySuggestion,
)
from .schemas import (
    DiscoveryModerationRequest,
    DiscoverySuggestionRequest,
    RoadRatingRequest,
)
from .service import RelayServiceError

PUBLIC_WARNING = (
    "Discovery highlights are descriptive and are not safety endorsements. "
    "Check current access, closures, weather and road conditions."
)


def create_suggestion(
    session: Session,
    payload: DiscoverySuggestionRequest,
    *,
    now: datetime | None = None,
) -> DiscoverySuggestion:
    now = now or datetime.now(UTC)
    canonical = json.dumps(
        payload.model_dump(mode="json"),
        sort_keys=True,
        separators=(",", ":"),
    ).encode()
    request_hash = sha256(canonical)
    existing = session.scalar(
        select(DiscoverySuggestion).where(
            DiscoverySuggestion.client_submission_id == payload.clientSubmissionId
        )
    )
    if existing is not None:
        if existing.request_hash != request_hash:
            raise RelayServiceError(409, "Submission identifier already used")
        return existing

    suggestion = DiscoverySuggestion(
        id=str(uuid.uuid4()),
        client_submission_id=payload.clientSubmissionId,
        request_hash=request_hash,
        category=payload.category,
        action=payload.action,
        target_feature_id=payload.targetFeatureId,
        name=payload.name.strip(),
        reason=payload.reason.strip(),
        evidence_url=str(payload.evidenceUrl) if payload.evidenceUrl else None,
        geometry_json=payload.geometry.model_dump(mode="json"),
        status="pending",
        submitted_at=now,
        updated_at=now,
    )
    session.add(suggestion)
    session.commit()
    return suggestion


def list_suggestions(
    session: Session,
    *,
    status: str,
    limit: int = 100,
) -> list[DiscoverySuggestion]:
    return list(
        session.scalars(
            select(DiscoverySuggestion)
            .where(DiscoverySuggestion.status == status)
            .order_by(DiscoverySuggestion.submitted_at)
            .limit(limit)
        )
    )


def purge_expired_private_suggestions(
    session: Session,
    *,
    retention_days: int,
    now: datetime | None = None,
) -> int:
    cutoff = (now or datetime.now(UTC)) - timedelta(days=retention_days)
    result = session.execute(
        delete(DiscoverySuggestion).where(
            DiscoverySuggestion.status.in_({"rejected", "superseded"}),
            DiscoverySuggestion.updated_at < cutoff,
        )
    )
    session.commit()
    return result.rowcount or 0


def moderate_suggestion(
    session: Session,
    suggestion_id: str,
    request: DiscoveryModerationRequest,
    *,
    reviewer: str,
    now: datetime | None = None,
) -> DiscoverySuggestion:
    now = now or datetime.now(UTC)
    suggestion = session.get(DiscoverySuggestion, suggestion_id)
    if suggestion is None:
        raise RelayServiceError(404, "Suggestion not found")
    if suggestion.status not in {"pending", "changes_requested"}:
        raise RelayServiceError(409, "Suggestion has already been moderated")

    status = {
        "approve": "approved",
        "reject": "rejected",
        "request_changes": "changes_requested",
        "supersede": "superseded",
    }[request.action]
    suggestion.status = status
    suggestion.updated_at = now
    suggestion.reviewed_at = now
    suggestion.reviewer = reviewer
    suggestion.moderation_reason = request.reason.strip()
    if request.action == "approve":
        suggestion.published_feature_id = _publish_approved_revision(
            session,
            suggestion,
            now,
        )
    session.add(
        DiscoveryModerationEvent(
            suggestion_id=suggestion.id,
            action=request.action,
            actor=reviewer,
            reason=request.reason.strip(),
            created_at=now,
        )
    )
    session.commit()
    return suggestion


def public_feature_collection(
    session: Session,
    *,
    west: float,
    south: float,
    east: float,
    north: float,
    categories: set[str],
) -> dict:
    features = session.scalars(
        select(DiscoveryFeature)
        .where(
            DiscoveryFeature.status == "active",
            DiscoveryFeature.category.in_(categories),
        )
        .limit(1000)
    )
    return {
        "type": "FeatureCollection",
        "features": [
            _feature_geojson(feature)
            for feature in features
            if _intersects_bounds(
                feature.geometry_json,
                west=west,
                south=south,
                east=east,
                north=north,
            )
        ],
    }


def suggestion_json(suggestion: DiscoverySuggestion, *, include_private: bool) -> dict:
    result = {
        "id": suggestion.id,
        "clientSubmissionId": suggestion.client_submission_id,
        "status": suggestion.status,
        "submittedAt": suggestion.submitted_at.isoformat(),
        "updatedAt": suggestion.updated_at.isoformat(),
        "publishedFeatureId": suggestion.published_feature_id,
    }
    if include_private:
        result.update(
            {
                "category": suggestion.category,
                "action": suggestion.action,
                "targetFeatureId": suggestion.target_feature_id,
                "name": suggestion.name,
                "reason": suggestion.reason,
                "evidenceUrl": suggestion.evidence_url,
                "geometry": suggestion.geometry_json,
                "reviewedAt": suggestion.reviewed_at.isoformat()
                if suggestion.reviewed_at
                else None,
                "reviewer": suggestion.reviewer,
                "moderationReason": suggestion.moderation_reason,
                "auditTrail": [
                    {
                        "action": event.action,
                        "actor": event.actor,
                        "reason": event.reason,
                        "createdAt": event.created_at.isoformat(),
                    }
                    for event in suggestion.audit_events
                ],
            }
        )
    return result


def _publish_approved_revision(
    session: Session,
    suggestion: DiscoverySuggestion,
    now: datetime,
) -> str:
    feature_id = (
        suggestion.target_feature_id
        if suggestion.action in {"correct", "remove"}
        else f"tec-community-{suggestion.id}"
    )
    if feature_id is None:  # defended by schema, retained for service callers
        raise RelayServiceError(400, "Revision target required")
    feature = session.get(DiscoveryFeature, feature_id)
    if feature is None:
        feature = DiscoveryFeature(
            id=feature_id,
            category=suggestion.category,
            name=suggestion.name,
            geometry_json=suggestion.geometry_json,
            status="active",
            confidence="community-reviewed",
            source_name="Tail End Charlie approved submission",
            source_feature_id=suggestion.id,
            source_url=suggestion.evidence_url,
            warning=PUBLIC_WARNING,
            approved_revision_id=suggestion.id,
            last_verified_at=now,
        )
        session.add(feature)
    else:
        feature.category = suggestion.category
        feature.name = suggestion.name
        feature.geometry_json = suggestion.geometry_json
        feature.source_feature_id = suggestion.id
        feature.source_url = suggestion.evidence_url
        feature.approved_revision_id = suggestion.id
        feature.last_verified_at = now
    feature.status = "removed" if suggestion.action == "remove" else "active"
    return feature_id


def _feature_geojson(feature: DiscoveryFeature) -> dict:
    return {
        "type": "Feature",
        "properties": {
            "id": feature.id,
            "category": feature.category,
            "name": feature.name,
            "confidence": feature.confidence,
            "sourceName": feature.source_name,
            "sourceFeatureId": feature.source_feature_id,
            "sourceUrl": feature.source_url,
            "lastVerified": feature.last_verified_at.date().isoformat(),
            "moderationStatus": "approved",
            "approvedRevisionId": feature.approved_revision_id,
            "warning": feature.warning,
        },
        "geometry": feature.geometry_json,
    }


def _intersects_bounds(
    geometry: dict,
    *,
    west: float,
    south: float,
    east: float,
    north: float,
) -> bool:
    coordinates = geometry.get("coordinates", [])
    points = [coordinates] if geometry.get("type") == "Point" else coordinates
    return any(
        isinstance(point, list)
        and len(point) == 2
        and west <= point[0] <= east
        and south <= point[1] <= north
        for point in points
    )


# ---------------------------------------------------------------------------
# Anonymous rider road ratings (#159)
# ---------------------------------------------------------------------------

WORTH_INCLUDING = "worth_including"
NOT_WORTH_INCLUDING = "not_worth_including"
ROAD_RATING_VERDICTS = (WORTH_INCLUDING, NOT_WORTH_INCLUDING)

# The aggregation rule, in one place, so the relay's export and the catalogue
# tooling cannot drift apart. Also recorded in tools/discovery/README.md.
#
# Five answers, because fewer is noise. The signal is unauthenticated by design
# (see record_road_rating), so it is not sybil-resistant, and a threshold one
# determined person could reach alone would be worthless.
ROAD_RATING_MINIMUM_RESPONSES = 5

# 70% of answers saying yes retires a candidate's `pending` tag. Two dissenters
# out of seven is disagreement about a road, not evidence against it.
ROAD_RATING_PROMOTION_SHARE = 0.7

# 60% saying no flags a candidate for a human to look at. It never removes one:
# the recommendation is advisory input to the review process, and a road leaves
# the catalogue only when a reviewer says so. One rider's dislike cannot remove
# anything, and neither can twenty.
ROAD_RATING_REVIEW_SHARE = 0.6


def record_road_rating(
    session: Session,
    payload: RoadRatingRequest,
    *,
    now: datetime | None = None,
) -> None:
    """Count one anonymous verdict.

    Takes no caller identity and stores none. There is no ride, no rider, no
    device, no request hash and no client-supplied timestamp: the request schema
    forbids extra fields, so a client cannot add one, and this function has
    nowhere to write it if it did. Receipt is recorded to the day, because a
    receipt second could be lined up against the ride journal's own sequence.

    The cost is no per-submitter deduplication - one person can answer twice from
    two devices. That is a deliberate trade against anonymity, bounded by the
    endpoint's IP rate limit and by an aggregation rule that only recommends.
    """
    today = (now or datetime.now(UTC)).date()
    # Increment-or-insert without reading first, so two phones answering the same
    # road at the same moment cannot lose a count to a read-modify-write race.
    if _increment_road_rating(session, payload, today):
        session.commit()
        return
    session.add(
        DiscoveryRoadRating(
            feature_id=payload.featureId,
            catalogue_version=payload.catalogueVersion,
            verdict=payload.verdict,
            category=payload.category,
            source_feature_id=payload.sourceFeatureId,
            rating_count=1,
            first_rated_on=today,
            last_rated_on=today,
        )
    )
    try:
        session.commit()
    except IntegrityError:
        # Another worker inserted the same tally between the update and the
        # insert. Roll back and increment the row that now exists.
        session.rollback()
        _increment_road_rating(session, payload, today)
        session.commit()


def _increment_road_rating(
    session: Session,
    payload: RoadRatingRequest,
    today: date,
) -> int:
    result = session.execute(
        update(DiscoveryRoadRating)
        .where(
            DiscoveryRoadRating.feature_id == payload.featureId,
            DiscoveryRoadRating.catalogue_version == payload.catalogueVersion,
            DiscoveryRoadRating.verdict == payload.verdict,
        )
        .values(
            rating_count=DiscoveryRoadRating.rating_count + 1,
            last_rated_on=today,
        )
    )
    return result.rowcount or 0


def road_rating_recommendation(worth_including: int, not_worth_including: int) -> str:
    """What the numbers recommend to the catalogue review process.

    ``promote``            enough answers, enough of them positive, to retire a
                           candidate's `pending` tag.
    ``review-for-removal`` enough answers, enough of them negative, that a human
                           should look. Never an automatic removal.
    ``insufficient``       not enough answers, or no clear majority either way.
    """
    total = worth_including + not_worth_including
    if total < ROAD_RATING_MINIMUM_RESPONSES:
        return "insufficient"
    if worth_including / total >= ROAD_RATING_PROMOTION_SHARE:
        return "promote"
    if not_worth_including / total >= ROAD_RATING_REVIEW_SHARE:
        return "review-for-removal"
    return "insufficient"


def road_rating_report(session: Session, *, limit: int = 5000) -> dict:
    """The aggregate the catalogue review process consumes.

    One entry per (road, catalogue release), carrying the counts, the stable
    upstream key to re-match on, and the recommendation the shared rule produces.
    The thresholds travel with the report so a reviewer does not have to guess
    which version of the rule produced the verdicts.
    """
    rows = session.scalars(
        select(DiscoveryRoadRating)
        .order_by(
            DiscoveryRoadRating.feature_id,
            DiscoveryRoadRating.catalogue_version,
        )
        .limit(limit)
    )
    grouped: dict[tuple[str, str], dict] = {}
    for row in rows:
        entry = grouped.setdefault(
            (row.feature_id, row.catalogue_version),
            {
                "featureId": row.feature_id,
                "catalogueVersion": row.catalogue_version,
                "sourceFeatureId": row.source_feature_id,
                "category": row.category,
                "worthIncluding": 0,
                "notWorthIncluding": 0,
                "firstRatedOn": row.first_rated_on.isoformat(),
                "lastRatedOn": row.last_rated_on.isoformat(),
            },
        )
        if row.source_feature_id and not entry["sourceFeatureId"]:
            entry["sourceFeatureId"] = row.source_feature_id
        if row.verdict == WORTH_INCLUDING:
            entry["worthIncluding"] = row.rating_count
        elif row.verdict == NOT_WORTH_INCLUDING:
            entry["notWorthIncluding"] = row.rating_count
        entry["firstRatedOn"] = min(entry["firstRatedOn"], row.first_rated_on.isoformat())
        entry["lastRatedOn"] = max(entry["lastRatedOn"], row.last_rated_on.isoformat())

    entries = []
    for entry in grouped.values():
        entry["recommendation"] = road_rating_recommendation(
            entry["worthIncluding"],
            entry["notWorthIncluding"],
        )
        entries.append(entry)
    entries.sort(key=lambda item: (item["featureId"], item["catalogueVersion"]))
    return {
        "thresholds": {
            "minimumResponses": ROAD_RATING_MINIMUM_RESPONSES,
            "promotionShare": ROAD_RATING_PROMOTION_SHARE,
            "reviewShare": ROAD_RATING_REVIEW_SHARE,
        },
        "ratings": entries,
    }
