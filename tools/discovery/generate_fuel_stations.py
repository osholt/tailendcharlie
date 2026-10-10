#!/usr/bin/env python3
"""Generate the bundled fuel station and charger layer from OpenStreetMap (#951).

Stations and chargers are where a rider needs them most when there is no
signal, so the layer is a static extract shipped in the app bundle, like the
speed camera and mini-roundabout layers. Prices are not in it: they are live,
come from the relay, and are joined to these stations at run time. See
`docs/fuel-and-charging-data-decision.md`.

Input is Overpass JSON (one or more files, so a large region can be fetched in
tiles) holding `amenity=fuel` and `amenity=charging_station` elements, with
`out center tags` so a mapped area has a single point. Output is compact JSON:
two arrays of small rows rather than GeoJSON, because the charger list alone
runs to tens of thousands of entries and every byte ships in the app.

    {"schemaVersion": 1, "attribution": ..., "extractDate": ...,
     "fuel": [[lat_e5, lon_e5, label, sells, doesNotSell], ...],
     "charging": [[lat_e5, lon_e5, label, connectors, maxKw], ...]}

Positions are degrees times 100,000 (about a metre). `sells` and
`doesNotSell` are bit masks over the grades a rider can choose (see
`FUEL_GRADE_BITS`); a grade in neither mask is simply not recorded, and the app
treats it as possibly sold. `connectors` is a bit mask over `CONNECTOR_BITS`;
zero means no connector is recorded, not that there are none. `maxKw` is the
highest output tagged anywhere on the site, or 0 when none is.
"""

from __future__ import annotations

import argparse
import json
import math
import re
from collections.abc import Iterable, Iterator, Mapping, Sequence
from datetime import date
from pathlib import Path

ATTRIBUTION = "© OpenStreetMap contributors, ODbL"

# Bits shared with the app (`FuelGrade` in lib/services/fuel_station_catalogue.dart).
FUEL_GRADE_BITS = {"e10": 1, "e5": 2, "diesel": 4}

# Which OpenStreetMap `fuel:*` keys say a station sells each grade. UK standard
# unleaded has been E10 since September 2021, so a 95-octane pump is the E10
# answer; super unleaded is 97 octane and above.
FUEL_GRADE_KEYS = {
    "e10": ("fuel:e10", "fuel:octane_95"),
    "e5": ("fuel:octane_97", "fuel:octane_98", "fuel:octane_99", "fuel:octane_100"),
    "diesel": ("fuel:diesel",),
}

# Bits shared with the app (`ChargerConnector`). A tethered Type 2 cable serves
# the same vehicles as a Type 2 socket, so both set the Type 2 bit.
CONNECTOR_BITS = {"type2": 1, "ccs": 2, "chademo": 4, "threePin": 8}
CONNECTOR_KEYS = {
    "type2": ("socket:type2", "socket:type2_cable"),
    "ccs": ("socket:type2_combo",),
    "chademo": ("socket:chademo",),
    "threePin": ("socket:bs1363",),
}

GENERIC_LABELS = {"fuel": "Fuel station", "charging": "Charger"}

# A label must never be an identifier (#860). The same shapes the published
# label scan looks for: a UUID, a bare hash, an OpenStreetMap element reference.
_UUID = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
_HEX_RUN = re.compile(r"(?<![0-9A-Za-z])[0-9a-fA-F]{16,}(?![0-9A-Za-z])")
_OSM_ELEMENT = re.compile(r"(?<![A-Za-z])(?:node|way|relation)[/ ]\d+", re.IGNORECASE)

_REFUSED_ACCESS = {"private", "no"}

# A node drawn on a forecourt that is also mapped as an area is the same
# station twice. Within this distance, and only between a node and an area with
# compatible labels, the two are merged. Two separately mapped stations facing
# each other across a dual carriageway are never merged: sending a rider to the
# wrong side is worse than drawing two pins.
FUEL_DUPLICATE_METRES = 40.0
# Charge posts in one car park are often mapped one node each. Within this
# distance and with compatible labels they are one site to a rider.
CHARGER_SITE_METRES = 25.0


def looks_like_identifier(text: str) -> bool:
    return bool(_UUID.search(text) or _HEX_RUN.search(text) or _OSM_ELEMENT.search(text))


def _elements(documents: Iterable[Mapping[str, object]]) -> Iterator[Mapping[str, object]]:
    for document in documents:
        elements = document.get("elements")
        if not isinstance(elements, list):
            continue
        for element in elements:
            if isinstance(element, Mapping):
                yield element


def _position(element: Mapping[str, object]) -> tuple[float, float] | None:
    if element.get("type") == "node":
        latitude, longitude = element.get("lat"), element.get("lon")
    else:
        centre = element.get("center")
        if not isinstance(centre, Mapping):
            return None
        latitude, longitude = centre.get("lat"), centre.get("lon")
    if not isinstance(latitude, int | float) or not isinstance(longitude, int | float):
        return None
    if not (-90 <= latitude <= 90 and -180 <= longitude <= 180):
        return None
    return float(latitude), float(longitude)


def _label(tags: Mapping[str, object], kind: str) -> tuple[str, bool]:
    """The rider-facing label, and whether an identifier had to be skipped.

    Name, then brand, then operator, then network, then a generic word. A
    candidate that is an identifier is passed over, never shown (#860).
    """
    replaced = False
    for key in ("name", "brand", "operator", "network"):
        value = tags.get(key)
        if not isinstance(value, str):
            continue
        cleaned = " ".join(value.split())[:60]
        if not cleaned:
            continue
        if looks_like_identifier(cleaned):
            replaced = True
            continue
        return cleaned, replaced
    return GENERIC_LABELS[kind], replaced


def _usable(tags: Mapping[str, object]) -> bool:
    """Whether a rider on a motorcycle may use it at all."""

    def value(key: str) -> str:
        raw = tags.get(key)
        return raw.strip().lower() if isinstance(raw, str) else ""

    if value("access") in _REFUSED_ACCESS:
        return False
    if value("motorcycle") == "yes":
        return True
    if value("motorcycle") == "no":
        return False
    # Boat fuel, and chargers for bicycles only.
    return value("motor_vehicle") != "no" and value("motorcar") != "no"


def _yes(value: object) -> bool:
    return isinstance(value, str) and value.strip().lower() == "yes"


def _no(value: object) -> bool:
    return isinstance(value, str) and value.strip().lower() == "no"


def fuel_masks(tags: Mapping[str, object]) -> tuple[int, int]:
    """(sells, does not sell) over `FUEL_GRADE_BITS`.

    A grade is sold if any of its keys says yes, and known not to be sold only
    if at least one key says no and none says yes. Untagged is unknown.
    """
    sells = 0
    refuses = 0
    for grade, keys in FUEL_GRADE_KEYS.items():
        values = [tags.get(key) for key in keys]
        if any(_yes(value) for value in values):
            sells |= FUEL_GRADE_BITS[grade]
        elif any(_no(value) for value in values):
            refuses |= FUEL_GRADE_BITS[grade]
    return sells, refuses


_KILOWATTS = re.compile(r"(\d+(?:\.\d+)?)\s*(kW|W)?", re.IGNORECASE)


def _kilowatts(value: object) -> int:
    """The largest output in a tag value such as `50 kW;7 kW`, in whole kW."""
    if not isinstance(value, str):
        return 0
    best = 0.0
    for part in value.split(";"):
        match = _KILOWATTS.search(part)
        if not match:
            continue
        number = float(match.group(1))
        unit = (match.group(2) or "kW").lower()
        if unit == "w":
            number /= 1000
        # A charger above 1 MW is a mapping slip, not a site a bike can use.
        if 0 < number <= 1000:
            best = max(best, number)
    return math.floor(best + 0.5)


def charger_details(tags: Mapping[str, object]) -> tuple[int, int]:
    """(connector mask, highest output in kW)."""
    connectors = 0
    for connector, keys in CONNECTOR_KEYS.items():
        for key in keys:
            value = tags.get(key)
            if isinstance(value, str) and value.strip() and not _no(value) and value != "0":
                connectors |= CONNECTOR_BITS[connector]
    output = _kilowatts(tags.get("charging_station:output"))
    for key, value in tags.items():
        if isinstance(key, str) and key.startswith("socket:") and key.endswith(":output"):
            output = max(output, _kilowatts(value))
    return connectors, output


def _metres(a: tuple[float, float], b: tuple[float, float]) -> float:
    latitude = math.radians((a[0] + b[0]) / 2)
    north = (a[0] - b[0]) * 111_320
    east = (a[1] - b[1]) * 111_320 * math.cos(latitude)
    return math.hypot(north, east)


def _compatible(a: Mapping[str, object], b: Mapping[str, object]) -> bool:
    """Whether two records could describe the same place: no naming conflict."""
    for key in ("brand", "name", "operator"):
        left, right = a.get(key), b.get(key)
        if isinstance(left, str) and isinstance(right, str):
            if left.strip().lower() != right.strip().lower():
                return False
    return True


class _Record:
    __slots__ = ("element_type", "key", "position", "tags")

    def __init__(
        self,
        key: tuple[str, int],
        element_type: str,
        position: tuple[float, float],
        tags: Mapping[str, object],
    ):
        self.key = key
        self.element_type = element_type
        self.position = position
        self.tags = tags


def _records(documents: Iterable[Mapping[str, object]], amenity: str) -> list[_Record]:
    """Distinct usable elements of one amenity, in a stable order.

    Deduplicated by element because tiled fetches overlap at their edges.
    """
    seen: dict[tuple[str, int], _Record] = {}
    for element in _elements(documents):
        element_type = element.get("type")
        element_id = element.get("id")
        if element_type not in ("node", "way", "relation") or not isinstance(element_id, int):
            continue
        raw_tags = element.get("tags")
        tags = raw_tags if isinstance(raw_tags, Mapping) else {}
        if tags.get("amenity") != amenity or not _usable(tags):
            continue
        position = _position(element)
        key = (str(element_type), element_id)
        if position is None or key in seen:
            continue
        seen[key] = _Record(key, str(element_type), position, tags)
    return [seen[key] for key in sorted(seen)]


def _merge(
    records: list[_Record], *, metres: float, node_with_area_only: bool
) -> list[list[_Record]]:
    """Group records that describe one site. Each group's first record leads it."""
    # Areas lead, so a node merges into the forecourt it sits on.
    ordered = sorted(records, key=lambda r: (r.element_type == "node", r.key))
    cell = metres / 111_320
    grid: dict[tuple[int, int], list[int]] = {}
    groups: list[list[_Record]] = []
    for record in ordered:
        row = math.floor(record.position[0] / cell)
        column = math.floor(
            record.position[1] / cell / max(0.2, math.cos(math.radians(record.position[0])))
        )
        target = None
        for d_row in (-1, 0, 1):
            for d_column in (-1, 0, 1):
                for index in grid.get((row + d_row, column + d_column), ()):
                    leader = groups[index][0]
                    if node_with_area_only and not (
                        record.element_type == "node" and leader.element_type != "node"
                    ):
                        continue
                    if _metres(leader.position, record.position) > metres:
                        continue
                    if not all(_compatible(member.tags, record.tags) for member in groups[index]):
                        continue
                    target = index
                    break
                if target is not None:
                    break
            if target is not None:
                break
        if target is None:
            grid.setdefault((row, column), []).append(len(groups))
            groups.append([record])
        else:
            groups[target].append(record)
    return groups


def _merged_tags(group: Sequence[_Record]) -> dict[str, object]:
    merged: dict[str, object] = {}
    for record in group:
        for key, value in record.tags.items():
            merged.setdefault(key, value)
    return merged


def _e5(value: float) -> int:
    return round(value * 100_000)


def build_layer(
    documents: Sequence[Mapping[str, object]],
) -> tuple[list[list[object]], list[list[object]], int]:
    """(fuel rows, charging rows, labels that skipped an identifier)."""
    replaced = 0
    fuel_rows: list[list[object]] = []
    for group in _merge(
        _records(documents, "fuel"), metres=FUEL_DUPLICATE_METRES, node_with_area_only=True
    ):
        tags = _merged_tags(group)
        label, skipped = _label(tags, "fuel")
        replaced += skipped
        sells, refuses = fuel_masks(tags)
        latitude, longitude = group[0].position
        fuel_rows.append([_e5(latitude), _e5(longitude), label, sells, refuses])
    charging_rows: list[list[object]] = []
    for group in _merge(
        _records(documents, "charging_station"),
        metres=CHARGER_SITE_METRES,
        node_with_area_only=False,
    ):
        label, skipped = _label(_merged_tags(group), "charging")
        replaced += skipped
        connectors = 0
        output = 0
        for record in group:
            record_connectors, record_output = charger_details(record.tags)
            connectors |= record_connectors
            output = max(output, record_output)
        latitude, longitude = group[0].position
        charging_rows.append([_e5(latitude), _e5(longitude), label, connectors, output])
    # Sorted by position so regenerating from the same extract produces an
    # identical file and a diff shows real change rather than fetch order.
    fuel_rows.sort(key=lambda row: (row[0], row[1], row[2]))
    charging_rows.sort(key=lambda row: (row[0], row[1], row[2]))
    return fuel_rows, charging_rows, replaced


def build_document(
    documents: Sequence[Mapping[str, object]],
    *,
    extract_date: str,
    bounded_region: str,
    generated_at: str,
) -> dict[str, object]:
    fuel_rows, charging_rows, replaced = build_layer(documents)
    return {
        "schemaVersion": 1,
        "attribution": ATTRIBUTION,
        "boundedRegion": bounded_region,
        "extractDate": extract_date,
        "generatedAt": generated_at,
        "fuelGradeBits": FUEL_GRADE_BITS,
        "connectorBits": CONNECTOR_BITS,
        "counts": {
            "fuel": len(fuel_rows),
            "charging": len(charging_rows),
            # Not silent: how many labels fell back past an identifier.
            "labelsThatSkippedAnIdentifier": replaced,
        },
        # Carried into the app and shown to riders.
        "coverageCaveat": (
            "Stations and chargers mapped in OpenStreetMap. Not every one is "
            "mapped, opening hours are not checked, and chargers carry no tariff "
            "or live availability."
        ),
        "fuel": fuel_rows,
        "charging": charging_rows,
    }


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--overpass",
        type=Path,
        nargs="+",
        required=True,
        help="Overpass JSON files holding amenity=fuel and amenity=charging_station.",
    )
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--extract-date", required=True, help="ISO 8601 date of the extract.")
    parser.add_argument("--bounded-region", required=True)
    parser.add_argument(
        "--minimum-fuel",
        type=int,
        default=1,
        help="Fail rather than write a layer with fewer fuel stations than this.",
    )
    parser.add_argument(
        "--minimum-charging",
        type=int,
        default=1,
        help="Fail rather than write a layer with fewer chargers than this.",
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    documents = []
    for path in args.overpass:
        with path.open(encoding="utf-8") as handle:
            documents.append(json.load(handle))
    document = build_document(
        documents,
        extract_date=args.extract_date,
        bounded_region=args.bounded_region,
        generated_at=date.today().isoformat(),
    )
    counts = document["counts"]
    assert isinstance(counts, dict)
    if counts["fuel"] < args.minimum_fuel or counts["charging"] < args.minimum_charging:
        raise SystemExit(
            f"Only {counts['fuel']} fuel stations and {counts['charging']} chargers were "
            f"found, below the floors of {args.minimum_fuel} and {args.minimum_charging}. "
            "This usually means part of a tiled fetch failed; re-run the fetch rather "
            "than shipping a layer that quietly misses a region."
        )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8") as handle:
        json.dump(document, handle, separators=(",", ":"), ensure_ascii=False)
        handle.write("\n")
    print(
        f"Wrote {counts['fuel']} fuel stations and {counts['charging']} chargers to "
        f"{args.output} ({counts['labelsThatSkippedAnIdentifier']} labels skipped an identifier)"
    )
    return 0


if __name__ == "__main__":  # pragma: no cover - CLI entry point
    raise SystemExit(main())
