"""Tests for the global road-jurisdiction layer generator."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools/discovery"))

from generate_road_jurisdictions import build_collection  # noqa: E402


def _feature(code: str, name: str) -> dict[str, object]:
    return {
        "type": "Feature",
        "properties": {"ISO_A2_EH": code, "NAME_EN": name},
        "geometry": {
            "type": "Polygon",
            "coordinates": [[[0, 0], [1, 0], [1, 1], [0, 0]]],
        },
    }


class RoadJurisdictionGeneratorTest(unittest.TestCase):
    def test_marks_france_metric_and_right_hand(self) -> None:
        collection = build_collection(
            {"features": [_feature("FR", "France")]},
            generated_at="2026-08-31",
        )

        properties = collection["features"][0]["properties"]
        self.assertEqual(properties["countryCode"], "FR")
        self.assertEqual(properties["drivingSide"], "right")
        self.assertEqual(properties["distanceUnit"], "kilometres")

    def test_marks_the_existing_uk_market_left_hand_and_miles(self) -> None:
        collection = build_collection(
            {"features": [_feature("GB", "United Kingdom")]},
            generated_at="2026-08-31",
        )

        properties = collection["features"][0]["properties"]
        self.assertEqual(properties["drivingSide"], "left")
        self.assertEqual(properties["distanceUnit"], "miles")

    def test_strips_unneeded_source_properties_and_is_stably_sorted(self) -> None:
        source = {
            "features": [
                _feature("GB", "United Kingdom"),
                _feature("FR", "France"),
            ]
        }
        source["features"][0]["properties"]["POP_EST"] = 1
        collection = build_collection(source, generated_at="2026-08-31")

        self.assertEqual(
            [item["properties"]["countryCode"] for item in collection["features"]],
            ["FR", "GB"],
        )
        self.assertNotIn("POP_EST", collection["features"][1]["properties"])
        self.assertIn("Natural Earth", collection["properties"]["attribution"])


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
