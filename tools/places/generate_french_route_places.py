#!/usr/bin/env python3
"""Compact metropolitan French communes, separately from the OS index."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

SOURCE_URL = (
    "https://geo.api.gouv.fr/communes?fields=nom,code,mairie,population&format=json"
)


def build_index(source: Path, output: Path, *, source_version: str) -> int:
    raw = source.read_bytes()
    places = []
    seen = set()
    for commune in json.loads(raw):
        code, name = commune.get("code"), commune.get("nom")
        coordinates = (commune.get("mairie") or {}).get("coordinates", [])
        if not code or code in seen or not isinstance(name, str) or not name.strip():
            continue
        if len(coordinates) != 2:
            continue
        longitude, latitude = coordinates
        if not (-5.5 <= longitude <= 10 and 41 <= latitude <= 51.2):
            continue
        population = commune.get("population") or 0
        prominence = 0 if population >= 100_000 else 1 if population >= 2_000 else 3
        places.append(
            [round(latitude * 100_000), round(longitude * 100_000), name, prominence]
        )
        seen.add(code)
    places.sort(key=lambda row: (row[0], row[1], row[2]))
    payload = {
        "schemaVersion": 1,
        "source": "API Découpage administratif — DINUM / IGN / INSEE",
        "sourceUrl": SOURCE_URL,
        "sourceVersion": source_version,
        "sourceSha256": hashlib.sha256(raw).hexdigest(),
        "license": "ODbL-1.0",
        "licenseUrl": "https://opendatacommons.org/licenses/odbl/1-0/",
        "attribution": (
            "French places © DINUM (data.gouv.fr), IGN, INSEE — ODbL 1.0; "
            f"retrieved {source_version}"
        ),
        "places": places,
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )
    return len(places)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--source-version", required=True)
    args = parser.parse_args()
    print(build_index(args.source, args.output, source_version=args.source_version))
