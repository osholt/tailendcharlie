"""Tests for the fixed speed camera layer generator."""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "tools/discovery"))

from generate_speed_cameras import (  # noqa: E402
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


class SpeedCameraFeatureTest(unittest.TestCase):
    def test_deduplicates_a_camera_seen_in_two_overlapping_tiles(self) -> None:
        """Tiled fetches overlap at their edges."""
        # A camera counted twice would be drawn twice on the map and warned
        # about twice on the road.
        features = build_features(
            [
                _document(_node(1, 51.5, -2.45), _node(2, 51.6, -2.40)),
                _document(_node(2, 51.6, -2.40), _node(3, 51.7, -2.35)),
            ]
        )

        self.assertEqual(
            [f["properties"]["osmId"] for f in features],
            ["node/1", "node/2", "node/3"],
        )

    def test_output_is_stable_across_fetch_order(self) -> None:
        """Regenerating the same extract must produce an identical file."""
        # So the diff shows real change rather than the order Overpass answered.
        forward = build_features([_document(_node(9, 51.5, -2.4), _node(2, 51.6, -2.3))])
        reversed_order = build_features([_document(_node(2, 51.6, -2.3), _node(9, 51.5, -2.4))])

        self.assertEqual(forward, reversed_order)

    def test_carries_only_the_tags_a_rider_is_shown(self) -> None:
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

        self.assertEqual(
            features[0]["properties"],
            {
                "osmId": "node/1",
                "maxspeed": "50 mph",
                "operator": "Avon and Somerset Police",
            },
        )

    def test_reads_the_several_ways_osm_spells_an_average_camera(self) -> None:
        """All of these appear in a real GB extract for the same thing."""
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

        self.assertEqual(
            [f["properties"].get("role") for f in features],
            ["average", "average", "average", "average", None],
        )

    def test_does_not_put_a_vendor_model_name_in_front_of_a_rider(self) -> None:
        """`Truvelo D-Cam` and `enforcement=maxspeed` are ordinary spot cameras."""
        # The app describes a camera with no role simply as a fixed one, which
        # is all either of these supports. Passing the raw string through would
        # show a rider a model number, and guessing a category would invent
        # detail the extract does not carry.
        features = build_features(
            [
                _document(
                    _node(1, 51.5, -2.45, speed_camera="Truvelo D-Cam"),
                    _node(2, 51.6, -2.45, enforcement="maxspeed"),
                )
            ]
        )

        self.assertEqual([f["properties"].get("role") for f in features], [None, None])

    def test_matches_a_role_whatever_case_the_extract_used(self) -> None:
        features = build_features([_document(_node(1, 51.5, -2.45, enforcement="Average_Speed"))])

        self.assertEqual(features[0]["properties"]["role"], "average")

    def test_skips_a_node_with_no_position(self) -> None:
        """Rather than placing it at Null Island."""
        features = build_features([_document({"type": "node", "id": 5}, _node(6, 51.5, -2.4))])

        self.assertEqual([f["properties"]["osmId"] for f in features], ["node/6"])


class SpeedCameraCollectionTest(unittest.TestCase):
    def test_states_the_licence_the_date_and_the_coverage_limit(self) -> None:
        collection = build_collection(
            build_features([_document(_node(1, 51.5, -2.45))]),
            extract_date="2026-08-07",
            bounded_region="Great Britain",
            generated_at="2026-08-07",
        )

        properties = collection["properties"]
        self.assertIn("ODbL", properties["attribution"])
        self.assertEqual(properties["extractDate"], "2026-08-07")
        self.assertEqual(properties["count"], 1)
        # The layer must never be readable as "there are no cameras on this road".
        self.assertIn("does not list every camera", properties["coverageCaveat"])

    def test_refuses_to_write_a_layer_from_a_partly_failed_fetch(self) -> None:
        """Half the tiles time out and the generator writes a thin catalogue."""
        # The app would then ship warning about almost nothing while looking
        # like it works, which is worse than shipping no layer at all.
        with tempfile.TemporaryDirectory() as directory:
            overpass = Path(directory) / "tile.json"
            overpass.write_text(json.dumps(_document(_node(1, 51.5, -2.45))), encoding="utf-8")
            output = Path(directory) / "cameras.geojson"

            with self.assertRaises(SystemExit) as caught:
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

            self.assertIn("below the", str(caught.exception))
            self.assertFalse(output.exists())

    def test_writes_a_geojson_point_layer(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            overpass = Path(directory) / "tile.json"
            overpass.write_text(
                json.dumps(_document(_node(1, 51.4672675, -2.4889995, maxspeed="30 mph"))),
                encoding="utf-8",
            )
            output = Path(directory) / "cameras.geojson"

            self.assertEqual(
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
                ),
                0,
            )

            written = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(written["type"], "FeatureCollection")
            feature = written["features"][0]
            self.assertEqual(feature["geometry"]["type"], "Point")
            # GeoJSON is longitude first. Swapping these would put every British
            # camera in the Indian Ocean, where the corridor filter finds none
            # and the layer silently warns about nothing.
            self.assertEqual(feature["geometry"]["coordinates"], [-2.4889995, 51.4672675])


if __name__ == "__main__":  # pragma: no cover - CLI entry point
    unittest.main()
