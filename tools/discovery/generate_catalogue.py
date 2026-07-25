#!/usr/bin/env python3
"""Generate review-gated UK motorcycle discovery candidates from OSM data."""

from __future__ import annotations

import argparse
import hashlib
import itertools
import json
import math
import shutil
import sqlite3
import subprocess
import tempfile
import tomllib
from collections import Counter, defaultdict
from collections.abc import Iterable, Iterator, Mapping, Sequence
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

EARTH_RADIUS_METRES = 6_371_000.0
ALLOWED_HIGHWAYS = {"primary", "secondary", "tertiary", "unclassified"}
EXCLUDED_ACCESS = {"no", "private"}
EXCLUDED_SURFACES = {
    "compacted",
    "dirt",
    "earth",
    "fine_gravel",
    "grass",
    "gravel",
    "ground",
    "mud",
    "sand",
    "unpaved",
}
KNOWN_PAVED_SURFACES = {
    "asphalt",
    "chipseal",
    "concrete",
    "concrete:lanes",
    "concrete:plates",
    "paved",
    "paving_stones",
    "sett",
}
LAYER_FILENAMES = {
    "twisty_highlight": "twisty-highlights.geojson",
    "mountain_pass": "mountain-passes.geojson",
    "good_biking_road": "good-biking-roads.geojson",
}
WARNINGS = {
    "twisty_highlight": (
        "Descriptive bend highlight only; not a speed target or safety "
        "endorsement. Check current access, closures, weather and road conditions."
    ),
    "mountain_pass": (
        "Not a safety endorsement; check current access, weather and road conditions."
    ),
    "good_biking_road": (
        "Descriptive discovery hint only; check width, surface, access, closures "
        "and current conditions before riding."
    ),
}


@dataclass(frozen=True)
class ReleaseManifest:
    catalogue_version: str
    region: str
    source_url: str
    source_filename: str
    source_release: str
    source_md5: str
    source_size_bytes: int
    last_verified: str

    @classmethod
    def load(cls, path: Path) -> ReleaseManifest:
        payload = tomllib.loads(path.read_text(encoding="utf-8"))
        source = payload["source"]
        catalogue = payload["catalogue"]
        manifest = cls(
            catalogue_version=str(catalogue["version"]),
            region=str(catalogue["region"]),
            source_url=str(source["url"]),
            source_filename=str(source["filename"]),
            source_release=str(source["release"]),
            source_md5=str(source["md5"]).lower(),
            source_size_bytes=int(source["size_bytes"]),
            last_verified=str(catalogue["last_verified"]),
        )
        if len(manifest.source_md5) != 32:
            raise ValueError("The release manifest must pin a 32-character MD5")
        datetime.fromisoformat(manifest.source_release.replace("Z", "+00:00"))
        datetime.fromisoformat(manifest.last_verified)
        return manifest


@dataclass(frozen=True)
class Road:
    source_id: str
    route_key: str
    name: str
    ref: str
    highway: str
    surface: str
    coordinates: tuple[tuple[float, float], ...]


@dataclass(frozen=True)
class PassPoint:
    source_id: str
    name: str
    elevation: str | None
    coordinate: tuple[float, float]


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--pbf", type=Path)
    source.add_argument(
        "--geojson-sequence",
        type=Path,
        help="Pre-filtered Osmium GeoJSON sequence, primarily for deterministic tests.",
    )
    parser.add_argument(
        "--output",
        action="append",
        type=Path,
        required=True,
        help="Combined catalogue destination; repeat for byte-identical web/mobile copies.",
    )
    parser.add_argument("--layer-directory", type=Path)
    parser.add_argument("--review-sample", type=Path)
    parser.add_argument("--max-twisty", type=int, default=1_100)
    parser.add_argument("--max-good-roads", type=int, default=1_100)
    parser.add_argument("--max-passes", type=int, default=350)
    parser.add_argument("--max-output-bytes", type=int, default=12 * 1024 * 1024)
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    manifest = ReleaseManifest.load(args.manifest)
    with tempfile.TemporaryDirectory(prefix="tec-discovery-") as temporary:
        temporary_path = Path(temporary)
        sequence = args.geojson_sequence
        if args.pbf is not None:
            validate_pbf(args.pbf, manifest)
            sequence = export_relevant_osm(args.pbf, temporary_path)
        assert sequence is not None
        collection = generate_catalogue(
            sequence,
            manifest,
            limits={
                "twisty_highlight": args.max_twisty,
                "good_biking_road": args.max_good_roads,
                "mountain_pass": args.max_passes,
            },
            database_path=temporary_path / "working.sqlite3",
        )

    encoded = encode_collection(collection)
    if len(encoded) > args.max_output_bytes:
        raise ValueError(
            f"Combined catalogue is {len(encoded):,} bytes, exceeding the "
            f"{args.max_output_bytes:,}-byte publication gate"
        )
    for destination in args.output:
        write_bytes(destination, encoded)
    if args.layer_directory is not None:
        write_layers(args.layer_directory, collection)
    if args.review_sample is not None:
        write_review_sample(args.review_sample, collection)
    return 0


def validate_pbf(path: Path, manifest: ReleaseManifest) -> None:
    if not path.is_file():
        raise ValueError(f"OSM extract does not exist: {path}")
    size = path.stat().st_size
    if size != manifest.source_size_bytes:
        raise ValueError(f"OSM extract size is {size}, expected {manifest.source_size_bytes}")
    digest = hashlib.md5(usedforsecurity=False)
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(4 * 1024 * 1024), b""):
            digest.update(chunk)
    if digest.hexdigest() != manifest.source_md5:
        raise ValueError("OSM extract checksum does not match the pinned release")


def export_relevant_osm(pbf: Path, temporary: Path) -> Path:
    osmium = shutil.which("osmium")
    if osmium is None:
        raise RuntimeError(
            "osmium-tool is required for PBF input; install it with "
            "`brew install osmium-tool` or the equivalent package manager"
        )
    filtered = temporary / "motorcycle-roads.osm.pbf"
    sequence = temporary / "motorcycle-roads.geojsonseq"
    subprocess.run(  # noqa: S603 - executable is resolved locally, without a shell
        [
            osmium,
            "tags-filter",
            "--overwrite",
            "--remove-tags",
            "--output",
            str(filtered),
            str(pbf),
            "w/highway",
            "n/mountain_pass=yes",
        ],
        check=True,
    )
    subprocess.run(  # noqa: S603 - executable is resolved locally, without a shell
        [
            osmium,
            "export",
            "--overwrite",
            "--output-format",
            "geojsonseq",
            "--format-option",
            "print_record_separator=false",
            "--add-unique-id",
            "type_id",
            "--attributes",
            "type,id",
            "--output",
            str(sequence),
            str(filtered),
        ],
        check=True,
    )
    return sequence


def generate_catalogue(
    sequence: Path,
    manifest: ReleaseManifest,
    *,
    limits: Mapping[str, int],
    database_path: Path,
) -> dict[str, object]:
    connection = sqlite3.connect(database_path)
    try:
        create_working_schema(connection)
        passes = ingest_sequence(connection, sequence)
        road_features = list(derive_road_features(connection, manifest))
        pass_features = list(derive_pass_features(connection, passes, manifest))
    finally:
        connection.close()

    by_category: dict[str, list[dict[str, object]]] = defaultdict(list)
    for feature in itertools.chain(road_features, pass_features):
        by_category[feature["properties"]["category"]].append(feature)

    selected: list[dict[str, object]] = []
    for category in LAYER_FILENAMES:
        selected.extend(select_bounded(by_category[category], limits[category]))
    selected.sort(key=feature_sort_key)
    validate_features(selected)
    return {
        "type": "FeatureCollection",
        "properties": {
            "catalogueVersion": manifest.catalogue_version,
            "boundedRegion": manifest.region,
            "sourceRelease": manifest.source_release,
            "sourceUrl": manifest.source_url,
            "sourceChecksum": f"md5:{manifest.source_md5}",
            "lastVerified": manifest.last_verified,
            "generatedAt": manifest.last_verified,
            "attribution": "© OpenStreetMap contributors, ODbL",
            "publicationStatus": "review-required",
            "warning": (
                "Discovery highlights are descriptive and are not safety "
                "endorsements. Check current access, closures, weather and road "
                "conditions."
            ),
            "counts": {
                category: sum(
                    1 for feature in selected if feature["properties"]["category"] == category
                )
                for category in LAYER_FILENAMES
            },
        },
        "features": selected,
    }


def create_working_schema(connection: sqlite3.Connection) -> None:
    connection.executescript(
        """
        PRAGMA journal_mode = OFF;
        PRAGMA synchronous = OFF;
        CREATE TABLE roads (
          source_id TEXT PRIMARY KEY,
          route_key TEXT NOT NULL,
          name TEXT NOT NULL,
          ref TEXT NOT NULL,
          highway TEXT NOT NULL,
          surface TEXT NOT NULL,
          coordinates TEXT NOT NULL
        );
        CREATE INDEX roads_route_key ON roads(route_key, source_id);
        CREATE TABLE road_cells (
          cell_x INTEGER NOT NULL,
          cell_y INTEGER NOT NULL,
          source_id TEXT NOT NULL,
          PRIMARY KEY (cell_x, cell_y, source_id)
        ) WITHOUT ROWID;
        CREATE INDEX road_cells_lookup ON road_cells(cell_x, cell_y);
        """
    )


def ingest_sequence(
    connection: sqlite3.Connection,
    sequence: Path,
) -> list[PassPoint]:
    passes: list[PassPoint] = []
    with sequence.open("r", encoding="utf-8") as source:
        for line_number, raw_line in enumerate(source, start=1):
            raw_line = raw_line.lstrip("\x1e").strip()
            if not raw_line:
                continue
            try:
                feature = json.loads(raw_line)
            except json.JSONDecodeError as error:
                raise ValueError(
                    f"Invalid GeoJSON sequence record on line {line_number}"
                ) from error
            geometry = feature.get("geometry")
            properties = feature.get("properties")
            if not isinstance(geometry, Mapping) or not isinstance(properties, Mapping):
                continue
            source_id = source_feature_id(feature, properties)
            if geometry.get("type") == "Point" and properties.get("mountain_pass") == "yes":
                coordinate = coordinate_pair(geometry.get("coordinates"))
                if coordinate is None or not within_uk(coordinate):
                    continue
                passes.append(
                    PassPoint(
                        source_id=source_id,
                        name=short_text(properties.get("name"), 120) or "Mapped mountain pass",
                        elevation=short_text(properties.get("ele"), 20),
                        coordinate=coordinate,
                    )
                )
                continue
            if geometry.get("type") != "LineString":
                continue
            coordinates = normalise_line(geometry.get("coordinates"))
            road = road_from_feature(source_id, properties, coordinates)
            if road is None:
                continue
            connection.execute(
                """
                INSERT INTO roads
                  (source_id, route_key, name, ref, highway, surface, coordinates)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    road.source_id,
                    road.route_key,
                    road.name,
                    road.ref,
                    road.highway,
                    road.surface,
                    json.dumps(road.coordinates, separators=(",", ":")),
                ),
            )
            for cell_x, cell_y in road_cells(road.coordinates):
                connection.execute(
                    "INSERT OR IGNORE INTO road_cells VALUES (?, ?, ?)",
                    (cell_x, cell_y, road.source_id),
                )
    connection.commit()
    return passes


def road_from_feature(
    source_id: str,
    properties: Mapping[str, object],
    coordinates: tuple[tuple[float, float], ...],
) -> Road | None:
    if len(coordinates) < 2 or not all(within_uk(point) for point in coordinates):
        return None
    highway = short_text(properties.get("highway"), 40) or ""
    if highway not in ALLOWED_HIGHWAYS:
        return None
    if properties.get("junction") == "roundabout":
        return None
    motorcycle = short_text(properties.get("motorcycle"), 40)
    if motorcycle in EXCLUDED_ACCESS:
        return None
    if motorcycle not in {"yes", "designated", "permissive"}:
        for key in ("motor_vehicle", "vehicle", "access"):
            if short_text(properties.get(key), 40) in EXCLUDED_ACCESS:
                return None
    surface = short_text(properties.get("surface"), 40) or "unknown"
    if surface in EXCLUDED_SURFACES:
        return None
    if low_urban_speed(properties.get("maxspeed")):
        return None
    lanes = parse_positive_int(properties.get("lanes"))
    if lanes is not None and lanes >= 4:
        return None
    name = short_text(properties.get("name"), 120) or ""
    ref = short_text(properties.get("ref"), 40) or ""
    route_key = normalise_route_key(ref or name or source_id)
    return Road(
        source_id=source_id,
        route_key=route_key,
        name=name,
        ref=ref,
        highway=highway,
        surface=surface,
        coordinates=coordinates,
    )


def derive_road_features(
    connection: sqlite3.Connection,
    manifest: ReleaseManifest,
) -> Iterator[dict[str, object]]:
    cursor = connection.execute(
        """
        SELECT source_id, route_key, name, ref, highway, surface, coordinates
        FROM roads
        ORDER BY route_key, source_id
        """
    )
    for _, rows in itertools.groupby(cursor, key=lambda row: row[1]):
        roads = [
            Road(
                source_id=row[0],
                route_key=row[1],
                name=row[2],
                ref=row[3],
                highway=row[4],
                surface=row[5],
                coordinates=tuple(tuple(point) for point in json.loads(row[6])),
            )
            for row in rows
        ]
        for merged in join_roads(roads):
            for section in split_section(merged, maximum_metres=35_000):
                yield from score_section(section, manifest)


def join_roads(roads: Sequence[Road]) -> Iterator[Road]:
    by_endpoint: dict[tuple[int, int], list[tuple[int, bool]]] = defaultdict(list)
    for index, road in enumerate(roads):
        by_endpoint[endpoint_key(road.coordinates[0])].append((index, True))
        by_endpoint[endpoint_key(road.coordinates[-1])].append((index, False))
    unused = set(range(len(roads)))
    while unused:
        first = min(unused, key=lambda index: roads[index].source_id)
        unused.remove(first)
        chain = [roads[first]]
        coordinates = list(roads[first].coordinates)
        source_ids = [roads[first].source_id]
        for append_right in (True, False):
            while True:
                endpoint = coordinates[-1] if append_right else coordinates[0]
                choices = [
                    candidate
                    for candidate in by_endpoint[endpoint_key(endpoint)]
                    if candidate[0] in unused
                ]
                if not choices:
                    break
                candidate_index, candidate_starts_here = min(
                    choices, key=lambda item: roads[item[0]].source_id
                )
                unused.remove(candidate_index)
                candidate = roads[candidate_index]
                candidate_coordinates = list(candidate.coordinates)
                if append_right:
                    if not candidate_starts_here:
                        candidate_coordinates.reverse()
                    coordinates.extend(candidate_coordinates[1:])
                    chain.append(candidate)
                else:
                    if candidate_starts_here:
                        candidate_coordinates.reverse()
                    coordinates[:0] = candidate_coordinates[:-1]
                    chain.insert(0, candidate)
                source_ids.append(candidate.source_id)
        representative = chain[0]
        yield Road(
            source_id=",".join(sorted(source_ids)),
            route_key=representative.route_key,
            name=most_common_text(road.name for road in chain),
            ref=most_common_text(road.ref for road in chain),
            highway=most_common_text(road.highway for road in chain),
            surface=most_common_text(road.surface for road in chain),
            coordinates=tuple(coordinates),
        )


def split_section(road: Road, *, maximum_metres: float) -> Iterator[Road]:
    chunk = [road.coordinates[0]]
    chunk_metres = 0.0
    part = 1
    for start, end in itertools.pairwise(road.coordinates):
        chunk.append(end)
        chunk_metres += haversine_metres(start, end)
        if chunk_metres >= maximum_metres:
            yield Road(
                source_id=f"{road.source_id}#part-{part}",
                route_key=road.route_key,
                name=road.name,
                ref=road.ref,
                highway=road.highway,
                surface=road.surface,
                coordinates=tuple(chunk),
            )
            part += 1
            chunk = [end]
            chunk_metres = 0.0
    if len(chunk) >= 2:
        yield Road(
            source_id=f"{road.source_id}#part-{part}",
            route_key=road.route_key,
            name=road.name,
            ref=road.ref,
            highway=road.highway,
            surface=road.surface,
            coordinates=tuple(chunk),
        )


def score_section(
    road: Road,
    manifest: ReleaseManifest,
) -> Iterator[dict[str, object]]:
    length_metres = line_length_metres(road.coordinates)
    if length_metres < 2_500:
        return
    sampled = resample_line(road.coordinates, spacing_metres=100)
    changes = [
        heading_change(bearing(a, b), bearing(b, c))
        for a, b, c in zip(sampled, sampled[1:], sampled[2:], strict=False)
    ]
    useful_changes = [change for change in changes if 8 <= change <= 105]
    sharp_reversals = sum(1 for change in changes if change > 125)
    length_km = length_metres / 1000
    bend_density = sum(useful_changes) / length_km
    if sharp_reversals / max(length_km, 1) > 0.3:
        return
    class_bonus = {
        "primary": 5,
        "secondary": 8,
        "tertiary": 6,
        "unclassified": 2,
    }[road.highway]
    surface_known = road.surface in KNOWN_PAVED_SURFACES
    confidence = "high" if surface_known and (road.name or road.ref) else "medium"
    common = {
        "name": road.ref or road.name or "Unnamed rural road section",
        "confidence": confidence,
        "scoreComponents": {
            "bendDegreesPerKm": round(bend_density, 1),
            "lengthKm": round(length_km, 1),
            "roadClass": road.highway,
            "surface": road.surface,
            "surfaceConfidence": "mapped-paved" if surface_known else "unknown",
            "sharpReversals": sharp_reversals,
        },
        "sourceName": "OpenStreetMap via Geofabrik",
        "sourceFeatureIds": source_ids_without_parts(road.source_id),
        "sourceRelease": manifest.source_release,
        "lastVerified": manifest.last_verified,
        "moderationStatus": "generated-review-required",
    }
    geometry = {
        "type": "LineString",
        "coordinates": [list(point) for point in simplify_for_output(road.coordinates)],
    }
    if bend_density >= 35:
        score = bounded_score(24 + bend_density * 0.65 + class_bonus)
        yield feature_for_road("twisty_highlight", road, score, bend_density, common, geometry)
    if length_km >= 5 and bend_density >= 18:
        score = bounded_score(30 + bend_density * 0.45 + min(length_km, 25) * 0.6 + class_bonus)
        yield feature_for_road("good_biking_road", road, score, bend_density, common, geometry)


def feature_for_road(
    category: str,
    road: Road,
    score: int,
    bend_density: float,
    common: Mapping[str, object],
    geometry: Mapping[str, object],
) -> dict[str, object]:
    feature_id = stable_id(category, road.source_id)
    properties = {
        "id": feature_id,
        "category": category,
        **common,
        "score": score,
        "scoreExplanation": (
            f"{bend_density:.1f}° of useful heading change per km across "
            f"{common['scoreComponents']['lengthKm']:.1f} km; roundabouts, "
            "low-speed urban roads, unsuitable surfaces and access restrictions "
            "were excluded."
        ),
        "sourceFeatureId": f"derived/{feature_id}",
        "sourceUrl": source_url(common["sourceFeatureIds"][0]),
        "warning": WARNINGS[category],
    }
    return {"type": "Feature", "properties": properties, "geometry": geometry}


def derive_pass_features(
    connection: sqlite3.Connection,
    passes: Sequence[PassPoint],
    manifest: ReleaseManifest,
) -> Iterator[dict[str, object]]:
    for mountain_pass in sorted(passes, key=lambda item: item.source_id):
        nearby_ids = nearby_road_ids(connection, mountain_pass.coordinate)
        closest = math.inf
        for source_id in nearby_ids:
            row = connection.execute(
                "SELECT coordinates FROM roads WHERE source_id = ?", (source_id,)
            ).fetchone()
            if row is None:
                continue
            coordinates = tuple(tuple(point) for point in json.loads(row[0]))
            closest = min(
                closest,
                point_to_line_metres(mountain_pass.coordinate, coordinates),
            )
        if closest > 50:
            continue
        source_feature_id = osm_source_feature_id(mountain_pass.source_id)
        properties: dict[str, object] = {
            "id": stable_id("mountain_pass", mountain_pass.source_id),
            "category": "mountain_pass",
            "name": mountain_pass.name,
            "score": None,
            "scoreExplanation": (
                "Mapped OpenStreetMap mountain_pass=yes node within 50 m of a "
                "motorcycle-accessible road candidate."
            ),
            "confidence": "high" if mountain_pass.name != "Mapped mountain pass" else "medium",
            "sourceName": "OpenStreetMap via Geofabrik",
            "sourceFeatureId": source_feature_id,
            "sourceFeatureIds": [source_feature_id],
            "sourceUrl": source_url(source_feature_id),
            "sourceRelease": manifest.source_release,
            "lastVerified": manifest.last_verified,
            "moderationStatus": "generated-review-required",
            "warning": WARNINGS["mountain_pass"],
        }
        if mountain_pass.elevation is not None:
            properties["sourceElevation"] = mountain_pass.elevation
        yield {
            "type": "Feature",
            "properties": properties,
            "geometry": {
                "type": "Point",
                "coordinates": list(mountain_pass.coordinate),
            },
        }


def select_bounded(
    features: Sequence[dict[str, object]],
    maximum: int,
) -> list[dict[str, object]]:
    if maximum < 1:
        raise ValueError("Per-layer limits must be positive")
    ranked = sorted(
        features,
        key=lambda feature: (
            -(feature["properties"]["score"] or 0),
            feature["properties"]["id"],
        ),
    )
    selected: list[dict[str, object]] = []
    per_cell: Counter[tuple[int, int]] = Counter()
    for feature in ranked:
        anchor = feature_anchor(feature)
        cell = (math.floor(anchor[0]), math.floor(anchor[1]))
        if per_cell[cell] >= 150:
            continue
        per_cell[cell] += 1
        selected.append(feature)
        if len(selected) >= maximum:
            break
    return selected


def validate_features(features: Sequence[dict[str, object]]) -> None:
    ids: set[str] = set()
    geometry_fingerprints: set[str] = set()
    for feature in features:
        properties = feature["properties"]
        category = properties["category"]
        if category not in LAYER_FILENAMES:
            raise ValueError(f"Unknown category: {category}")
        feature_id = properties["id"]
        if feature_id in ids:
            raise ValueError(f"Duplicate discovery feature ID: {feature_id}")
        ids.add(feature_id)
        geometry = feature["geometry"]
        fingerprint = json.dumps(geometry, sort_keys=True, separators=(",", ":"))
        duplicate_key = f"{category}:{fingerprint}"
        if duplicate_key in geometry_fingerprints:
            raise ValueError(f"Duplicate {category} geometry")
        geometry_fingerprints.add(duplicate_key)
        if not properties.get("sourceFeatureIds"):
            raise ValueError(f"Missing source IDs for {feature_id}")
        if properties.get("moderationStatus") != "generated-review-required":
            raise ValueError(f"Generated feature bypassed review: {feature_id}")


def encode_collection(collection: Mapping[str, object]) -> bytes:
    return (
        json.dumps(
            collection,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        )
        + "\n"
    ).encode()


def write_bytes(destination: Path, content: bytes) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(content)


def write_layers(directory: Path, collection: Mapping[str, object]) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    for category, filename in LAYER_FILENAMES.items():
        layer = {
            "type": "FeatureCollection",
            "properties": {
                **collection["properties"],
                "category": category,
            },
            "features": [
                feature
                for feature in collection["features"]
                if feature["properties"]["category"] == category
            ],
        }
        write_bytes(directory / filename, encode_collection(layer))
    manifest = {
        "catalogueVersion": collection["properties"]["catalogueVersion"],
        "publicationStatus": "review-required",
        "layers": {
            category: {
                "path": filename,
                "count": collection["properties"]["counts"][category],
                "sha256": hashlib.sha256((directory / filename).read_bytes()).hexdigest(),
            }
            for category, filename in LAYER_FILENAMES.items()
        },
    }
    write_bytes(
        directory / "manifest.json",
        (json.dumps(manifest, sort_keys=True, indent=2) + "\n").encode(),
    )


def write_review_sample(
    destination: Path,
    collection: Mapping[str, object],
) -> None:
    regions = ("England", "Scotland", "Wales", "Northern Ireland")
    sample: list[dict[str, object]] = []
    for region in regions:
        candidates = [
            feature
            for feature in collection["features"]
            if review_region(feature_anchor(feature)) == region
        ]
        candidates.sort(
            key=lambda feature: (
                -(feature["properties"]["score"] or 0),
                feature["properties"]["id"],
            )
        )
        for feature in candidates[:12]:
            clone = json.loads(json.dumps(feature))
            clone["properties"]["reviewRegion"] = region
            clone["properties"]["manualReview"] = "pending"
            sample.append(clone)
    review = {
        "type": "FeatureCollection",
        "properties": {
            "catalogueVersion": collection["properties"]["catalogueVersion"],
            "purpose": "Deterministic four-nation manual review sample",
            "publicationStatus": "not-for-publication",
        },
        "features": sample,
    }
    write_bytes(destination, encode_collection(review))


def review_region(anchor: tuple[float, float]) -> str | None:
    """Assign unambiguous nation-core samples without claiming border precision."""
    core_bounds = (
        ("Northern Ireland", (-8.3, 54.0, -5.3, 55.5)),
        ("Wales", (-5.3, 51.4, -3.1, 53.5)),
        ("Scotland", (-8.7, 55.8, -0.5, 61.0)),
        ("England", (-5.8, 50.0, 1.8, 54.8)),
    )
    for region, bounds in core_bounds:
        if point_in_bounds(anchor, bounds):
            return region
    return None


def source_feature_id(
    feature: Mapping[str, object],
    properties: Mapping[str, object],
) -> str:
    identifier = feature.get("id")
    if isinstance(identifier, str) and identifier:
        return identifier
    object_type = properties.get("@type")
    object_id = properties.get("@id")
    if object_type in {"node", "way"} and isinstance(object_id, int | str):
        return f"{str(object_type)[0]}{object_id}"
    raise ValueError("Every exported feature must retain its OSM type and ID")


def osm_source_feature_id(source_id: str) -> str:
    if source_id.startswith("n") and source_id[1:].lstrip("-").isdigit():
        return f"node/{source_id[1:]}"
    if source_id.startswith("w") and source_id[1:].lstrip("-").isdigit():
        return f"way/{source_id[1:]}"
    raise ValueError(f"Unsupported OSM source ID: {source_id}")


def source_url(source_feature_id: str) -> str:
    return f"https://www.openstreetmap.org/{source_feature_id}"


def source_ids_without_parts(value: str) -> list[str]:
    source_ids: list[str] = []
    for item in value.split(","):
        item = item.split("#", 1)[0]
        source_feature_id = osm_source_feature_id(item)
        if source_feature_id not in source_ids:
            source_ids.append(source_feature_id)
    return sorted(source_ids)


def coordinate_pair(value: object) -> tuple[float, float] | None:
    if not isinstance(value, list) or len(value) < 2:
        return None
    if (
        isinstance(value[0], bool)
        or isinstance(value[1], bool)
        or not isinstance(value[0], int | float)
        or not isinstance(value[1], int | float)
    ):
        return None
    longitude = float(value[0])
    latitude = float(value[1])
    if not (-180 <= longitude <= 180 and -90 <= latitude <= 90):
        return None
    return (round(longitude, 7), round(latitude, 7))


def normalise_line(value: object) -> tuple[tuple[float, float], ...]:
    if not isinstance(value, list):
        return ()
    result = [point for item in value if (point := coordinate_pair(item)) is not None]
    deduplicated = [point for point, _ in itertools.groupby(result)]
    return tuple(deduplicated)


def short_text(value: object, maximum: int) -> str | None:
    if not isinstance(value, str):
        return None
    cleaned = " ".join(value.split())
    return cleaned[:maximum] if cleaned else None


def parse_positive_int(value: object) -> int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value if value >= 0 else None
    if not isinstance(value, str):
        return None
    first = value.split(";", 1)[0].strip()
    try:
        parsed = int(first)
    except ValueError:
        return None
    return parsed if parsed >= 0 else None


def low_urban_speed(value: object) -> bool:
    if not isinstance(value, str):
        return False
    compact = value.lower().strip()
    if compact in {"walk", "signals", "variable", "none", "national"}:
        return False
    try:
        speed = float(compact.replace("mph", "").strip())
    except ValueError:
        return False
    if "mph" in compact:
        return speed <= 30
    return speed <= 50


def normalise_route_key(value: str) -> str:
    return "".join(character.lower() for character in value if character.isalnum())[:80]


def most_common_text(values: Iterable[str]) -> str:
    counter = Counter(value for value in values if value)
    if not counter:
        return ""
    return min(counter, key=lambda value: (-counter[value], value))


def within_uk(point: tuple[float, float]) -> bool:
    longitude, latitude = point
    return -11.5 <= longitude <= 3.0 and 49.0 <= latitude <= 61.5


def endpoint_key(point: tuple[float, float]) -> tuple[int, int]:
    return (round(point[0] * 100_000), round(point[1] * 100_000))


def road_cells(
    coordinates: Sequence[tuple[float, float]],
) -> set[tuple[int, int]]:
    sampled = resample_line(coordinates, spacing_metres=500)
    return {(math.floor(lon * 100), math.floor(lat * 100)) for lon, lat in sampled}


def nearby_road_ids(
    connection: sqlite3.Connection,
    point: tuple[float, float],
) -> list[str]:
    cell_x = math.floor(point[0] * 100)
    cell_y = math.floor(point[1] * 100)
    cells = [
        coordinate
        for x in range(cell_x - 1, cell_x + 2)
        for y in range(cell_y - 1, cell_y + 2)
        for coordinate in (x, y)
    ]
    rows = connection.execute(
        """
        SELECT DISTINCT source_id
        FROM road_cells
        WHERE (cell_x, cell_y) IN (
          (?, ?), (?, ?), (?, ?),
          (?, ?), (?, ?), (?, ?),
          (?, ?), (?, ?), (?, ?)
        )
        ORDER BY source_id
        """,
        cells,
    )
    return [row[0] for row in rows]


def haversine_metres(
    first: tuple[float, float],
    second: tuple[float, float],
) -> float:
    lon1, lat1 = map(math.radians, first)
    lon2, lat2 = map(math.radians, second)
    delta_lon = lon2 - lon1
    delta_lat = lat2 - lat1
    value = (
        math.sin(delta_lat / 2) ** 2
        + math.cos(lat1) * math.cos(lat2) * math.sin(delta_lon / 2) ** 2
    )
    return 2 * EARTH_RADIUS_METRES * math.asin(min(1.0, math.sqrt(value)))


def line_length_metres(coordinates: Sequence[tuple[float, float]]) -> float:
    return sum(haversine_metres(start, end) for start, end in itertools.pairwise(coordinates))


def resample_line(
    coordinates: Sequence[tuple[float, float]],
    *,
    spacing_metres: float,
) -> tuple[tuple[float, float], ...]:
    if len(coordinates) < 2:
        return tuple(coordinates)
    result = [coordinates[0]]
    distance_to_next = spacing_metres
    for start, end in itertools.pairwise(coordinates):
        segment_length = haversine_metres(start, end)
        while segment_length >= distance_to_next and segment_length > 0:
            fraction = distance_to_next / segment_length
            interpolated = (
                start[0] + (end[0] - start[0]) * fraction,
                start[1] + (end[1] - start[1]) * fraction,
            )
            result.append(interpolated)
            start = interpolated
            segment_length = haversine_metres(start, end)
            distance_to_next = spacing_metres
        distance_to_next -= segment_length
    if result[-1] != coordinates[-1]:
        result.append(coordinates[-1])
    return tuple(result)


def bearing(
    first: tuple[float, float],
    second: tuple[float, float],
) -> float:
    lon1, lat1 = map(math.radians, first)
    lon2, lat2 = map(math.radians, second)
    x = math.sin(lon2 - lon1) * math.cos(lat2)
    y = math.cos(lat1) * math.sin(lat2) - math.sin(lat1) * math.cos(lat2) * math.cos(lon2 - lon1)
    return math.degrees(math.atan2(x, y))


def heading_change(first: float, second: float) -> float:
    return abs((second - first + 180) % 360 - 180)


def simplify_for_output(
    coordinates: Sequence[tuple[float, float]],
) -> tuple[tuple[float, float], ...]:
    if len(coordinates) <= 500:
        return tuple(coordinates)
    stride = math.ceil(len(coordinates) / 499)
    sampled = list(coordinates[::stride])
    if sampled[-1] != coordinates[-1]:
        sampled.append(coordinates[-1])
    return tuple(sampled)


def point_to_line_metres(
    point: tuple[float, float],
    coordinates: Sequence[tuple[float, float]],
) -> float:
    return min(
        point_to_segment_metres(point, start, end) for start, end in itertools.pairwise(coordinates)
    )


def point_to_segment_metres(
    point: tuple[float, float],
    start: tuple[float, float],
    end: tuple[float, float],
) -> float:
    reference_latitude = math.radians((point[1] + start[1] + end[1]) / 3)

    def project(value: tuple[float, float]) -> tuple[float, float]:
        return (
            math.radians(value[0]) * EARTH_RADIUS_METRES * math.cos(reference_latitude),
            math.radians(value[1]) * EARTH_RADIUS_METRES,
        )

    px, py = project(point)
    sx, sy = project(start)
    ex, ey = project(end)
    dx = ex - sx
    dy = ey - sy
    length_squared = dx * dx + dy * dy
    fraction = (
        0.0
        if length_squared == 0
        else max(0.0, min(1.0, ((px - sx) * dx + (py - sy) * dy) / length_squared))
    )
    return math.hypot(px - (sx + fraction * dx), py - (sy + fraction * dy))


def stable_id(category: str, source_ids: str) -> str:
    digest = hashlib.sha256(f"{category}:{source_ids}".encode()).hexdigest()[:16]
    return f"osm-{category.replace('_', '-')}-{digest}"


def bounded_score(value: float) -> int:
    return max(1, min(100, round(value)))


def feature_anchor(feature: Mapping[str, object]) -> tuple[float, float]:
    geometry = feature["geometry"]
    coordinates = geometry["coordinates"]
    if geometry["type"] == "Point":
        return tuple(coordinates)
    return tuple(coordinates[len(coordinates) // 2])


def feature_sort_key(feature: Mapping[str, object]) -> tuple[str, str]:
    return (
        feature["properties"]["category"],
        feature["properties"]["id"],
    )


def point_in_bounds(
    point: tuple[float, float],
    bounds: tuple[float, float, float, float],
) -> bool:
    west, south, east, north = bounds
    return west <= point[0] <= east and south <= point[1] <= north


if __name__ == "__main__":
    raise SystemExit(main())
