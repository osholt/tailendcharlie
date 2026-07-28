"""Rider road ratings as an input to the catalogue review process (#159).

The relay collects anonymous one-tap verdicts from riders at the end of a ride and
holds them as tallies, not as submissions. This module turns that export into a
promotion decision the publisher can act on.

Fetching
--------
    curl -sS -H "Authorization: Bearer $RIDE_RELAY_DISCOVERY_ADMIN_TOKEN" \\
      https://<relay>/api/v1/admin/discovery/road-ratings \\
      > "$DISCOVERY_WORK_DIR/road-ratings.json"

The publisher reads that file if it exists and ignores its absence, so a
publication run without a relay export behaves exactly as it did before.

The rule
--------
`promote`            >= MINIMUM_RESPONSES answers and >= PROMOTION_SHARE of them
                     positive. Retires a candidate's `pending` tag.
`review-for-removal` >= MINIMUM_RESPONSES answers and >= REVIEW_SHARE of them
                     negative. Written to the review report for a human to look
                     at. It never removes a candidate: one rider's dislike must
                     not remove a road, and neither may twenty. Removal stays a
                     reviewer's decision, taken through the editorial overlay.
`insufficient`       not enough answers, or no clear majority either way.

These constants mirror ROAD_RATING_* in
apps/server/src/ride_relay_server/discovery.py. The relay's own export carries the
thresholds it used, and `load` refuses an export whose thresholds disagree with
these, rather than silently applying a different rule to the numbers.

Matching
--------
Joined on `sourceFeatureId` first and the candidate `id` second. A candidate's ID
is a content hash over its OSM source ways and moves with every extract;
`sourceFeatureId` is the stable key. A rating is only ever counted against the
catalogue release it was given on, so republished geometry starts again from zero.
"""

import json
import os
import pathlib

MINIMUM_RESPONSES = 5
PROMOTION_SHARE = 0.7
REVIEW_SHARE = 0.6

OUT = os.environ.get("DISCOVERY_WORK_DIR", "/private/tmp/discovery-out")
FILENAME = "road-ratings.json"


def recommendation(worth_including, not_worth_including):
    """The shared rule. Mirrors road_rating_recommendation on the relay."""
    total = worth_including + not_worth_including
    if total < MINIMUM_RESPONSES:
        return "insufficient"
    if worth_including / total >= PROMOTION_SHARE:
        return "promote"
    if not_worth_including / total >= REVIEW_SHARE:
        return "review-for-removal"
    return "insufficient"


def index(export, catalogue_version):
    """Ratings for one catalogue release, keyed by every ID they can be matched on.

    Both keys point at the same entry, so the publisher can try the stable
    upstream key and fall back to the candidate ID without handling two indexes.
    """
    thresholds = export.get("thresholds") or {}
    expected = {
        "minimumResponses": MINIMUM_RESPONSES,
        "promotionShare": PROMOTION_SHARE,
        "reviewShare": REVIEW_SHARE,
    }
    if thresholds and thresholds != expected:
        raise SystemExit(
            f"road rating export was aggregated under {thresholds}, but this "
            f"publisher applies {expected}. Align the rule before publishing."
        )

    result = {}
    for entry in export.get("ratings") or []:
        if entry.get("catalogueVersion") != catalogue_version:
            continue
        worth = int(entry.get("worthIncluding") or 0)
        against = int(entry.get("notWorthIncluding") or 0)
        record = {
            "worthIncluding": worth,
            "notWorthIncluding": against,
            "recommendation": recommendation(worth, against),
            "lastRatedOn": entry.get("lastRatedOn"),
        }
        for key in (entry.get("sourceFeatureId"), entry.get("featureId")):
            if key:
                result[key] = record
    return result


def load(catalogue_version, path=None):
    """The rating index for a catalogue release, or empty when there is no export."""
    resolved = pathlib.Path(path or f"{OUT}/{FILENAME}")
    if not resolved.exists():
        return {}
    with open(resolved) as handle:
        return index(json.load(handle), catalogue_version)


def lookup(ratings, properties):
    """The rating record for a candidate, matched on its stable key then its ID."""
    for key in (properties.get("sourceFeatureId"), properties.get("id")):
        if key and key in ratings:
            return ratings[key]
    return None
