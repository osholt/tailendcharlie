#!/usr/bin/env python3
"""Generate the bundled mini-roundabout layer from OpenStreetMap data.

OSRM and Valhalla both route through `highway=mini_roundabout` nodes without
necessarily emitting a manoeuvre, so a rider gets no instruction at a junction
they have to give way at. This layer restores that.

It replaces a hand-reviewed catalogue of two junctions. A catalogue only ever
covers the junctions somebody happened to report, and its hand-measured arm
bearings could not be checked against anything.

Input is Overpass JSON holding `highway=mini_roundabout` nodes. Output is a
GeoJSON FeatureCollection carrying the ODbL attribution and the extract date, in
the same shape as the discovery and speed camera layers.
"""

from __future__ import annotations

import argparse
import json
from collections.abc import Iterable, Iterator, Mapping, Sequence
from datetime import date
from pathlib import Path

ATTRIBUTION = "© OpenStreetMap contributors, ODbL"

# Which way traffic goes round. Only these two spellings mean a rotation; the
# `direction` tag is also used on some nodes for a compass bearing, and a GB
# extract carries values like `195` and `340`. Reading one of those as a
# rotation would tell a rider to go the wrong way round a junction, so anything
# unrecognised is left unstated and the app falls back to its own default.
ROTATIONS = {"clockwise": "clockwise", "anticlockwise": "anticlockwise"}


def _nodes(documents: Iterable[Mapping[str, object]]) -> Iterator[Mapping[str, object]]:
    for document in documents:
        elements = document.get("elements")
        if not isinstance(elements, list):
            continue
        for element in elements:
            if isinstance(element, Mapping) and element.get("type") == "node":
                yield element


def build_features(
    documents: Iterable[Mapping[str, object]],
) -> list[dict[str, object]]:
    """One feature per distinct OpenStreetMap node.

    Position only. Counting exits needs the bearing of every arm, which this
    layer does not carry, so the app states the direction through the junction
    and does not claim a number it cannot support.
    """
    seen: dict[int, dict[str, object]] = {}
    for node in _nodes(documents):
        node_id = node.get("id")
        latitude = node.get("lat")
        longitude = node.get("lon")
        if not isinstance(node_id, int):
            continue
        if not isinstance(latitude, (int, float)):
            continue
        if not isinstance(longitude, (int, float)):
            continue
        if node_id in seen:
            continue
        raw_tags = node.get("tags")
        tags = raw_tags if isinstance(raw_tags, Mapping) else {}
        properties: dict[str, object] = {"osmId": f"node/{node_id}"}
        raw_direction = tags.get("direction")
        if isinstance(raw_direction, str):
            rotation = ROTATIONS.get(raw_direction.strip().lower())
            if rotation is not None:
                properties["rotation"] = rotation
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
            "coverageCaveat": (
                "OpenStreetMap does not mark every mini-roundabout, and the "
                "routing engine may already announce some of these."
            ),
        },
        "features": list(features),
    }


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--overpass", type=Path, nargs="+", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--extract-date", required=True)
    parser.add_argument("--bounded-region", required=True)
    parser.add_argument(
        "--minimum-features",
        type=int,
        default=1,
        help=(
            "Fail rather than write a near-empty layer, which would restore "
            "manoeuvres at almost no junctions while appearing to work."
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
            f"Only {len(features)} mini-roundabouts were found, below the "
            f"--minimum-features floor of {args.minimum_features}. Re-run the "
            f"fetch rather than shipping a layer that restores almost nothing."
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
    print(f"Wrote {len(features)} mini-roundabouts to {args.output}")
    return 0


if __name__ == "__main__":  # pragma: no cover - CLI entry point
    raise SystemExit(main())
