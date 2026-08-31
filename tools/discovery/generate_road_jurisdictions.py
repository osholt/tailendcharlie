#!/usr/bin/env python3
"""Build the compact offline road-jurisdiction layer used by the mobile app.

The source is Natural Earth's 1:110m Admin 0 countries GeoJSON. Geometry comes
from the source unchanged; this generator strips the large cartographic
property set and adds only the road facts the app needs while offline:

* which side of the road traffic uses; and
* whether rider-facing journey distances conventionally use miles or km.

The layer is deliberately global. France support must not be a coordinate-box
special case that gets the Channel coast or a border road wrong.
"""

from __future__ import annotations

import argparse
import json
from collections.abc import Mapping, Sequence
from datetime import date
from pathlib import Path

NATURAL_EARTH_SOURCE = (
    "https://github.com/nvkelso/natural-earth-vector/"
    "tree/v5.1.2/geojson/ne_110m_admin_0_countries.geojson"
)
ATTRIBUTION = "Made with Natural Earth (public domain)"

# Sovereign states and territories whose roads use left-hand traffic. Natural
# Earth represents some territories through their administering state at this
# scale; the list still names them so a higher-resolution source can replace the
# geometry without changing the policy.
LEFT_HAND_TRAFFIC = {
    "AG", "AI", "AU", "BB", "BD", "BM", "BN", "BS", "BT", "BW",
    "CY", "DM", "FJ", "FK", "GB", "GD", "GG", "GY", "HK", "ID",
    "IE", "IM", "IN", "JE", "JM", "JP", "KE", "KI", "KN", "KY",
    "LC", "LK", "LS", "MO", "MS", "MT", "MU", "MV", "MW", "MY",
    "MZ", "NA", "NP", "NR", "NZ", "PG", "PK", "SB", "SC", "SG",
    "SH", "SR", "SZ", "TC", "TH", "TL", "TO", "TT", "TV", "TZ",
    "UG", "VC", "VG", "WS", "ZA", "ZM", "ZW",
}

# Rider-facing road distances use miles in these two supported markets. Speed
# limits remain a road-jurisdiction fact of their own in the app; this set does
# not reinterpret mapped speed-limit data.
MILE_DISTANCE_COUNTRIES = {"GB", "US"}


def _country_code(properties: Mapping[str, object]) -> str | None:
    for key in ("ISO_A2_EH", "ISO_A2"):
        raw = properties.get(key)
        if isinstance(raw, str):
            code = raw.strip().upper()
            if len(code) == 2 and code.isalpha():
                return code
    return None


def build_collection(source: Mapping[str, object], *, generated_at: str) -> dict[str, object]:
    raw_features = source.get("features")
    if not isinstance(raw_features, list):
        raise ValueError("Natural Earth source has no feature list")
    features: list[dict[str, object]] = []
    for raw in raw_features:
        if not isinstance(raw, Mapping):
            continue
        properties = raw.get("properties")
        geometry = raw.get("geometry")
        if not isinstance(properties, Mapping) or not isinstance(geometry, Mapping):
            continue
        code = _country_code(properties)
        geometry_type = geometry.get("type")
        if code is None or geometry_type not in {"Polygon", "MultiPolygon"}:
            continue
        name = properties.get("NAME_EN") or properties.get("NAME") or code
        features.append(
            {
                "type": "Feature",
                "properties": {
                    "countryCode": code,
                    "name": str(name),
                    "drivingSide": "left" if code in LEFT_HAND_TRAFFIC else "right",
                    "distanceUnit": "miles" if code in MILE_DISTANCE_COUNTRIES else "kilometres",
                },
                "geometry": geometry,
            }
        )
    features.sort(key=lambda feature: str(feature["properties"]["countryCode"]))
    return {
        "type": "FeatureCollection",
        "properties": {
            "attribution": ATTRIBUTION,
            "source": NATURAL_EARTH_SOURCE,
            "sourceVersion": "5.1.2",
            "generatedAt": generated_at,
            "count": len(features),
            "precisionCaveat": (
                "Low-resolution country boundaries choose road conventions; "
                "routing geometry and roadside signs remain authoritative."
            ),
        },
        "features": features,
    }


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    with args.source.open(encoding="utf-8") as handle:
        source = json.load(handle)
    if not isinstance(source, Mapping):
        raise SystemExit("Natural Earth source is not a GeoJSON object")
    collection = build_collection(source, generated_at=date.today().isoformat())
    if len(collection["features"]) < 150:
        raise SystemExit("Natural Earth source produced too few country features")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8") as handle:
        json.dump(collection, handle, separators=(",", ":"), sort_keys=True)
        handle.write("\n")
    print(f"Wrote {len(collection['features'])} road jurisdictions to {args.output}")
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
