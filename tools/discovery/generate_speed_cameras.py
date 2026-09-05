#!/usr/bin/env python3
"""Generate the bundled fixed speed camera layer from OpenStreetMap data.

A fixed camera is a permanent roadside object, so this is a static extract
rather than a live feed: it is generated once, checked in, and shipped in the
app bundle. That is what lets a rider with no signal get the same warning as one
on a motorway.

Input is Overpass JSON (one or more files, so a large region can be fetched in
tiles) holding `highway=speed_camera` nodes. Output is a GeoJSON
FeatureCollection carrying the ODbL attribution and the extract date, in the
same shape as the discovery catalogue.
"""

from __future__ import annotations

import argparse
import json
from collections.abc import Iterable, Iterator, Mapping, Sequence
from datetime import date
from pathlib import Path

# Tags worth carrying to the rider. Everything else in the node is dropped: the
# layer is a warning, not a copy of the map.
ROLE_TAG = "enforcement"
CARRIED_TAGS = ("maxspeed", "operator")

# The only two distinctions a rider acts on, and every spelling a GB extract
# uses for them. `maxspeed` and vendor model names such as `Truvelo D-Cam`
# describe an ordinary spot camera and are deliberately absent: they map to no
# role, which the app describes as a fixed camera.
ROLE_VOCABULARY = {
    "average": "average",
    "average_speed": "average",
    "specs": "average",
    "vector": "average",
    "traffic_signals": "traffic_signals",
    "red_light": "traffic_signals",
}

ATTRIBUTION = "© OpenStreetMap contributors, ODbL"


def _nodes(documents: Iterable[Mapping[str, object]]) -> Iterator[Mapping[str, object]]:
    for document in documents:
        elements = document.get("elements")
        if not isinstance(elements, list):
            continue
        for element in elements:
            if isinstance(element, Mapping) and element.get("type") == "node":
                yield element


def _role(tags: Mapping[str, object]) -> str | None:
    """What kind of camera this is, in the app's vocabulary.

    Normalised here rather than in the app, because the raw values are a mess
    and only this side can be tested against real extracts. A GB extract holds
    `average_speed`, `SPECS`, `Truvelo D-Cam`, `maxspeed` and plain `average`
    for what are only two distinctions a rider acts on: whether speed is
    measured over a distance rather than at a point, and whether the camera is
    on the lights.

    Anything unrecognised returns None and is described simply as a fixed
    camera. That is the safe direction to be wrong in: a vendor's model name
    put in front of a rider says nothing, and guessing a category from it would
    invent detail the extract does not carry.
    """
    for tag in (ROLE_TAG, "speed_camera:type", "speed_camera"):
        value = tags.get(tag)
        if not isinstance(value, str) or not value.strip():
            continue
        role = ROLE_VOCABULARY.get(value.strip().lower())
        if role is not None:
            return role
    return None


def build_features(
    documents: Iterable[Mapping[str, object]],
) -> list[dict[str, object]]:
    """One feature per distinct OpenStreetMap node.

    Deduplicated by node id because tiled fetches overlap at their edges, and a
    camera counted twice would be drawn twice and warned about twice.
    """
    seen: dict[int, dict[str, object]] = {}
    for node in _nodes(documents):
        node_id = node.get("id")
        latitude = node.get("lat")
        longitude = node.get("lon")
        if not isinstance(node_id, int):
            continue
        if not isinstance(latitude, int | float):
            continue
        if not isinstance(longitude, int | float):
            continue
        if node_id in seen:
            continue
        raw_tags = node.get("tags")
        tags = raw_tags if isinstance(raw_tags, Mapping) else {}
        properties: dict[str, object] = {"osmId": f"node/{node_id}"}
        role = _role(tags)
        if role is not None:
            properties["role"] = role
        for tag in CARRIED_TAGS:
            value = tags.get(tag)
            if isinstance(value, str) and value.strip():
                properties[tag] = value.strip()
        seen[node_id] = {
            "type": "Feature",
            "geometry": {
                "type": "Point",
                "coordinates": [round(float(longitude), 7), round(float(latitude), 7)],
            },
            "properties": properties,
        }
    # Sorted by node id so regenerating from the same extract produces an
    # identical file and the diff shows real change rather than fetch order.
    return [seen[key] for key in sorted(seen)]


def build_collection(
    features: Sequence[Mapping[str, object]],
    *,
    extract_date: str,
    bounded_region: str,
    generated_at: str,
) -> dict[str, object]:
    return {
        "type": "FeatureCollection",
        "properties": {
            "attribution": ATTRIBUTION,
            "boundedRegion": bounded_region,
            "extractDate": extract_date,
            "generatedAt": generated_at,
            "count": len(features),
            # Carried into the app and shown to riders. OpenStreetMap coverage
            # of cameras is good but not complete, and a layer that implied
            # otherwise would be worse than no layer at all.
            "coverageCaveat": (
                "OpenStreetMap does not list every camera. A road with none "
                "shown has not been confirmed clear."
            ),
        },
        "features": list(features),
    }


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--overpass",
        type=Path,
        nargs="+",
        required=True,
        help="Overpass JSON files holding highway=speed_camera nodes.",
    )
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument(
        "--extract-date",
        required=True,
        help="Date of the OpenStreetMap extract, ISO 8601.",
    )
    parser.add_argument("--bounded-region", required=True)
    parser.add_argument(
        "--minimum-features",
        type=int,
        default=1,
        help=(
            "Fail rather than write a near-empty layer. A partly failed tiled "
            "fetch otherwise ships as a catalogue that quietly warns about "
            "almost nothing."
        ),
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    documents = []
    for path in args.overpass:
        with path.open(encoding="utf-8") as handle:
            documents.append(json.load(handle))
    features = build_features(documents)
    if len(features) < args.minimum_features:
        raise SystemExit(
            f"Only {len(features)} cameras were found, below the "
            f"--minimum-features floor of {args.minimum_features}. This "
            f"usually means part of a tiled fetch failed; re-run the fetch "
            f"rather than shipping a layer that warns about almost nothing."
        )
    collection = build_collection(
        features,
        extract_date=args.extract_date,
        bounded_region=args.bounded_region,
        generated_at=date.today().isoformat(),
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8") as handle:
        json.dump(collection, handle, separators=(",", ":"), sort_keys=True)
        handle.write("\n")
    print(f"Wrote {len(features)} cameras to {args.output}")
    return 0


if __name__ == "__main__":  # pragma: no cover - CLI entry point
    raise SystemExit(main())
