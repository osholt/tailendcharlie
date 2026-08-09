"""Tests for the mini-roundabout layer generator."""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "tools/discovery"))

from generate_mini_roundabouts import (  # noqa: E402
    build_collection,
    build_features,
    main,
)


def _node(node_id: int, lat: float, lon: float, **tags: str) -> dict[str, object]:
    node: dict[str, object] = {"type": "node", "id": node_id, "lat": lat, "lon": lon}
    node["tags"] = {"highway": "mini_roundabout", **tags}
    return node


def _document(*nodes: dict[str, object]) -> dict[str, object]:
    return {"elements": list(nodes)}


class MiniRoundaboutFeatureTest(unittest.TestCase):
    def test_reads_the_rotation_the_map_states(self) -> None:
        features = build_features(
            [
                _document(
                    _node(1, 51.5, -2.45, direction="clockwise"),
                    _node(2, 51.6, -2.45, direction="anticlockwise"),
                )
            ]
        )

        self.assertEqual(
            [f["properties"]["rotation"] for f in features],
            ["clockwise", "anticlockwise"],
        )

    def test_does_not_read_a_compass_bearing_as_a_rotation(self) -> None:
        """A GB extract carries `direction=195` and `direction=340`."""
        # Those are compass bearings on the node, not which way traffic goes
        # round. Reading one as a rotation would send a rider the wrong way
        # round a junction, so anything unrecognised is left unstated and the
        # app falls back to its own default.
        features = build_features(
            [
                _document(
                    _node(1, 51.5, -2.45, direction="195"),
                    _node(2, 51.6, -2.45, direction="340"),
                    _node(3, 51.7, -2.45),
                )
            ]
        )

        self.assertEqual([f["properties"].get("rotation") for f in features], [None, None, None])

    def test_matches_a_rotation_whatever_case_the_extract_used(self) -> None:
        features = build_features([_document(_node(1, 51.5, -2.45, direction="Clockwise"))])

        self.assertEqual(features[0]["properties"]["rotation"], "clockwise")

    def test_carries_no_arm_bearings(self) -> None:
        """Position and rotation only."""
        # Counting exits needs every arm's bearing. The hand-reviewed catalogue
        # this replaces carried them for two junctions, measured by hand and
        # checkable against nothing. The app now states the direction through
        # the junction and claims no number.
        features = build_features([_document(_node(1, 51.5, -2.45, direction="clockwise"))])

        self.assertEqual(set(features[0]["properties"]), {"osmId", "rotation"})

    def test_deduplicates_and_orders_stably(self) -> None:
        forward = build_features(
            [
                _document(_node(9, 51.5, -2.4), _node(2, 51.6, -2.3)),
                _document(_node(2, 51.6, -2.3)),
            ]
        )
        reversed_order = build_features([_document(_node(2, 51.6, -2.3), _node(9, 51.5, -2.4))])

        self.assertEqual(forward, reversed_order)
        self.assertEqual([f["properties"]["osmId"] for f in forward], ["node/2", "node/9"])

    def test_skips_a_node_with_no_position(self) -> None:
        features = build_features([_document({"type": "node", "id": 5}, _node(6, 51.5, -2.4))])

        self.assertEqual([f["properties"]["osmId"] for f in features], ["node/6"])


class MiniRoundaboutCollectionTest(unittest.TestCase):
    def test_states_the_licence_the_date_and_the_coverage_limit(self) -> None:
        collection = build_collection(
            build_features([_document(_node(1, 51.5, -2.45))]),
            extract_date="2026-08-09",
            bounded_region="Great Britain",
            generated_at="2026-08-09",
        )

        properties = collection["properties"]
        self.assertIn("ODbL", properties["attribution"])
        self.assertEqual(properties["extractDate"], "2026-08-09")
        self.assertEqual(properties["count"], 1)
        self.assertIn("does not mark every", properties["coverageCaveat"])

    def test_refuses_to_write_a_layer_from_a_partly_failed_fetch(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            overpass = Path(directory) / "tile.json"
            overpass.write_text(json.dumps(_document(_node(1, 51.5, -2.45))), encoding="utf-8")
            output = Path(directory) / "mini.geojson"

            with self.assertRaises(SystemExit) as caught:
                main(
                    [
                        "--overpass",
                        str(overpass),
                        "--output",
                        str(output),
                        "--extract-date",
                        "2026-08-09",
                        "--bounded-region",
                        "Great Britain",
                        "--minimum-features",
                        "10000",
                    ]
                )

            self.assertIn("below the", str(caught.exception))
            self.assertFalse(output.exists())

    def test_writes_a_geojson_point_layer(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            overpass = Path(directory) / "tile.json"
            overpass.write_text(
                json.dumps(_document(_node(30983542, 51.4672133, -2.5010632))),
                encoding="utf-8",
            )
            output = Path(directory) / "mini.geojson"

            self.assertEqual(
                main(
                    [
                        "--overpass",
                        str(overpass),
                        "--output",
                        str(output),
                        "--extract-date",
                        "2026-08-09",
                        "--bounded-region",
                        "Great Britain",
                    ]
                ),
                0,
            )

            written = json.loads(output.read_text(encoding="utf-8"))
            feature = written["features"][0]
            # GeoJSON is longitude first.
            self.assertEqual(feature["geometry"]["coordinates"], [-2.5010632, 51.4672133])


if __name__ == "__main__":  # pragma: no cover - CLI entry point
    unittest.main()
