"""Tests for the fixed speed camera layer generator."""

from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from generate_speed_cameras import (
    build_collection,
    build_features,
    main,
)


def _node(node_id: int, lat: float, lon: float, **tags: str) -> dict[str, object]:
    node: dict[str, object] = {"type": "node", "id": node_id, "lat": lat, "lon": lon}
    if tags:
        node["tags"] = {"highway": "speed_camera", **tags}
    return node


def _document(*nodes: dict[str, object]) -> dict[str, object]:
    return {"elements": list(nodes)}


def test_deduplicates_a_camera_seen_in_two_overlapping_tiles() -> None:
    # Tiled fetches overlap at their edges. A camera counted twice would be
    # drawn twice on the map and warned about twice on the road.
    features = build_features(
        [
            _document(_node(1, 51.5, -2.45), _node(2, 51.6, -2.40)),
            _document(_node(2, 51.6, -2.40), _node(3, 51.7, -2.35)),
        ]
    )

    assert [f["properties"]["osmId"] for f in features] == [
        "node/1",
        "node/2",
        "node/3",
    ]


def test_output_is_stable_across_fetch_order() -> None:
    # So regenerating from the same extract produces an identical file and the
    # diff shows real change rather than the order Overpass answered in.
    forward = build_features([_document(_node(9, 51.5, -2.4), _node(2, 51.6, -2.3))])
    reversed_order = build_features([_document(_node(2, 51.6, -2.3), _node(9, 51.5, -2.4))])

    assert forward == reversed_order


def test_carries_only_the_tags_a_rider_is_shown() -> None:
    features = build_features(
        [
            _document(
                _node(
                    1,
                    51.5,
                    -2.45,
                    maxspeed="50 mph",
                    operator="Avon and Somerset Police",
                    source="survey",
                    ref="ASP/1234",
                )
            )
        ]
    )

    assert features[0]["properties"] == {
        "osmId": "node/1",
        "maxspeed": "50 mph",
        "operator": "Avon and Somerset Police",
    }


def test_reads_the_several_ways_openstreetmap_spells_an_average_camera() -> None:
    # All of these appear in a real GB extract for the same thing.
    features = build_features(
        [
            _document(
                _node(1, 51.5, -2.45, enforcement="average"),
                _node(2, 51.6, -2.45, speed_camera="average"),
                _node(3, 51.7, -2.45, enforcement="average_speed"),
                _node(4, 51.8, -2.45, enforcement="SPECS"),
                _node(5, 51.9, -2.45),
            )
        ]
    )

    roles = [f["properties"].get("role") for f in features]
    assert roles == ["average", "average", "average", "average", None]


def test_does_not_put_a_vendor_model_name_in_front_of_a_rider() -> None:
    # `Truvelo D-Cam` and `enforcement=maxspeed` are ordinary spot cameras. The
    # app describes a camera with no role simply as a fixed one, which is all
    # either of these supports; passing the raw string through would show a
    # rider a model number, and guessing a category would invent detail.
    features = build_features(
        [
            _document(
                _node(1, 51.5, -2.45, speed_camera="Truvelo D-Cam"),
                _node(2, 51.6, -2.45, enforcement="maxspeed"),
            )
        ]
    )

    assert [f["properties"].get("role") for f in features] == [None, None]


def test_matches_a_role_whatever_case_the_extract_used() -> None:
    features = build_features([_document(_node(1, 51.5, -2.45, enforcement="Average_Speed"))])

    assert features[0]["properties"]["role"] == "average"


def test_skips_a_node_with_no_position_rather_than_placing_it_at_null_island() -> None:
    features = build_features([_document({"type": "node", "id": 5}, _node(6, 51.5, -2.4))])

    assert [f["properties"]["osmId"] for f in features] == ["node/6"]


def test_collection_states_the_licence_the_date_and_the_coverage_limit() -> None:
    collection = build_collection(
        build_features([_document(_node(1, 51.5, -2.45))]),
        extract_date="2026-08-07",
        bounded_region="Great Britain",
        generated_at="2026-08-07",
    )

    properties = collection["properties"]
    assert "ODbL" in properties["attribution"]
    assert properties["extractDate"] == "2026-08-07"
    assert properties["count"] == 1
    # The layer must never be readable as "there are no cameras on this road".
    assert "does not list every camera" in properties["coverageCaveat"]


def test_refuses_to_write_a_layer_from_a_partly_failed_fetch(tmp_path: Path) -> None:
    # The failure this exists to stop: half the tiles time out, the generator
    # writes a thin catalogue, and the app ships warning about almost nothing
    # while looking like it works.
    overpass = tmp_path / "tile.json"
    overpass.write_text(json.dumps(_document(_node(1, 51.5, -2.45))), encoding="utf-8")
    output = tmp_path / "cameras.geojson"

    with pytest.raises(SystemExit) as excinfo:
        main(
            [
                "--overpass",
                str(overpass),
                "--output",
                str(output),
                "--extract-date",
                "2026-08-07",
                "--bounded-region",
                "Great Britain",
                "--minimum-features",
                "2000",
            ]
        )

    assert "below the" in str(excinfo.value)
    assert not output.exists()


def test_writes_a_geojson_point_layer(tmp_path: Path) -> None:
    overpass = tmp_path / "tile.json"
    overpass.write_text(
        json.dumps(_document(_node(1, 51.4672675, -2.4889995, maxspeed="30 mph"))),
        encoding="utf-8",
    )
    output = tmp_path / "cameras.geojson"

    assert (
        main(
            [
                "--overpass",
                str(overpass),
                "--output",
                str(output),
                "--extract-date",
                "2026-08-07",
                "--bounded-region",
                "Great Britain",
            ]
        )
        == 0
    )

    written = json.loads(output.read_text(encoding="utf-8"))
    assert written["type"] == "FeatureCollection"
    feature = written["features"][0]
    assert feature["geometry"]["type"] == "Point"
    # GeoJSON is longitude first. Swapping these would put every British camera
    # in the Indian Ocean, and the corridor filter would silently find none.
    assert feature["geometry"]["coordinates"] == [-2.4889995, 51.4672675]
