#!/usr/bin/env python3
"""Build the compact offline settlement index used for ride endpoint labels."""

from __future__ import annotations

import argparse
import csv
import io
import json
import zipfile
from collections.abc import Callable, Iterable
from pathlib import Path


LOCAL_TYPE_CODES = {
    "City": 0,
    "Town": 1,
    "Suburban Area": 2,
    "Village": 3,
    "Other Settlement": 4,
    "Hamlet": 5,
}


def settlement_rows(
    archive: zipfile.ZipFile,
    transform: Callable[[float, float], tuple[float, float]],
) -> Iterable[list[object]]:
    """Yield [latitudeE5, longitudeE5, name, typeCode] records."""

    seen_ids: set[str] = set()
    for member in sorted(archive.namelist()):
        if not member.startswith("Data/") or not member.endswith(".csv"):
            continue
        with archive.open(member) as raw:
            text = io.TextIOWrapper(raw, encoding="utf-8-sig", newline="")
            for row in csv.reader(text):
                if len(row) < 10 or row[6] != "populatedPlace":
                    continue
                feature_id = row[0].strip()
                if not feature_id or feature_id in seen_ids:
                    continue
                name = " ".join(row[2].split())
                local_type = row[7].strip()
                if not name or local_type not in LOCAL_TYPE_CODES:
                    continue
                try:
                    longitude, latitude = transform(float(row[8]), float(row[9]))
                except (TypeError, ValueError):
                    continue
                if not (-90 <= latitude <= 90 and -180 <= longitude <= 180):
                    continue
                seen_ids.add(feature_id)
                yield [
                    round(latitude * 100_000),
                    round(longitude * 100_000),
                    name,
                    LOCAL_TYPE_CODES[local_type],
                ]


def build_index(
    source: Path,
    output: Path,
    *,
    source_version: str,
    transform: Callable[[float, float], tuple[float, float]],
) -> int:
    with zipfile.ZipFile(source) as archive:
        places = list(settlement_rows(archive, transform))
    places.sort(key=lambda row: (row[0], row[1], row[2]))
    payload = {
        "schemaVersion": 1,
        "source": "OS Open Names",
        "sourceVersion": source_version,
        "attribution": (
            "Contains OS data © Crown copyright and database right "
            f"{source_version.split('-', maxsplit=1)[0]}"
        ),
        "places": places,
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )
    return len(places)


def _arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path, help="OS Open Names CSV zip")
    parser.add_argument("output", type=Path)
    parser.add_argument("--source-version", required=True)
    return parser.parse_args()


def main() -> None:
    args = _arguments()
    try:
        from pyproj import Transformer
    except ImportError as error:
        raise SystemExit(
            "pyproj is required; run with `uv run --with pyproj ...`"
        ) from error
    transformer = Transformer.from_crs("EPSG:27700", "EPSG:4326", always_xy=True)
    count = build_index(
        args.source,
        args.output,
        source_version=args.source_version,
        transform=transformer.transform,
    )
    print(f"Wrote {count} settlements to {args.output}")


if __name__ == "__main__":
    main()
