"""Tests for the fuel station and charger layer generator (#951)."""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "tools/discovery"))

from generate_fuel_stations import (  # noqa: E402
    CONNECTOR_BITS,
    FUEL_GRADE_BITS,
    build_document,
    build_layer,
    charger_details,
    fuel_masks,
    main,
)


def _node(element_id: int, lat: float, lon: float, **tags: str) -> dict[str, object]:
    return {"type": "node", "id": element_id, "lat": lat, "lon": lon, "tags": tags}


def _way(element_id: int, lat: float, lon: float, **tags: str) -> dict[str, object]:
    return {
        "type": "way",
        "id": element_id,
        "center": {"lat": lat, "lon": lon},
        "tags": tags,
    }


def _document(*elements: dict[str, object]) -> dict[str, object]:
    return {"elements": list(elements)}


def _fuel(element_id: int, lat: float, lon: float, **tags: str) -> dict[str, object]:
    return _node(element_id, lat, lon, amenity="fuel", **tags)


def _charger(element_id: int, lat: float, lon: float, **tags: str) -> dict[str, object]:
    return _node(element_id, lat, lon, amenity="charging_station", **tags)


class FuelGradeTest(unittest.TestCase):
    def test_a_grade_is_sold_when_any_of_its_keys_says_so(self) -> None:
        sells, refuses = fuel_masks(
            {"fuel:octane_95": "yes", "fuel:octane_98": "no", "fuel:octane_99": "yes"}
        )
        self.assertEqual(sells, FUEL_GRADE_BITS["e10"] | FUEL_GRADE_BITS["e5"])
        self.assertEqual(refuses, 0)

    def test_a_grade_is_refused_only_when_tagged_no_and_never_yes(self) -> None:
        sells, refuses = fuel_masks({"fuel:diesel": "no", "fuel:octane_98": "no"})
        self.assertEqual(sells, 0)
        self.assertEqual(refuses, FUEL_GRADE_BITS["diesel"] | FUEL_GRADE_BITS["e5"])

    def test_an_untagged_grade_is_unknown_not_refused(self) -> None:
        self.assertEqual(fuel_masks({"brand": "Example"}), (0, 0))


class ChargerDetailTest(unittest.TestCase):
    def test_connectors_and_the_highest_output_anywhere_on_the_site(self) -> None:
        connectors, output = charger_details(
            {
                "socket:type2_combo": "2",
                "socket:type2_combo:output": "150 kW;50 kW",
                "socket:type2_cable": "1",
                "socket:type2_cable:output": "22 kW",
                "socket:chademo": "0",
            }
        )
        self.assertEqual(connectors, CONNECTOR_BITS["ccs"] | CONNECTOR_BITS["type2"])
        self.assertEqual(output, 150)

    def test_watts_and_station_output_are_understood(self) -> None:
        self.assertEqual(charger_details({"charging_station:output": "7400 W"}), (0, 7))
        self.assertEqual(
            charger_details({"socket:bs1363": "yes", "charging_station:output": "3 kW"}),
            (CONNECTOR_BITS["threePin"], 3),
        )

    def test_an_absurd_output_is_ignored(self) -> None:
        self.assertEqual(
            charger_details({"socket:type2": "1", "socket:type2:output": "22000 kW"}), (1, 0)
        )


class FuelLayerTest(unittest.TestCase):
    def test_rows_are_compact_and_positions_are_in_hundred_thousandths(self) -> None:
        fuel, charging, replaced = build_layer(
            [
                _document(
                    _fuel(1, 52.123456, -1.987654, name="Example Garage", **{"fuel:diesel": "yes"}),
                    _charger(2, 52.2, -1.9, operator="Example Charge", **{"socket:type2": "2"}),
                )
            ]
        )
        self.assertEqual(fuel, [[5212346, -198765, "Example Garage", 4, 0]])
        self.assertEqual(charging, [[5220000, -190000, "Example Charge", 1, 0]])
        self.assertEqual(replaced, 0)

    def test_a_label_falls_back_past_an_identifier_and_says_so(self) -> None:
        # The field report in #860: a brand followed by a UUID.
        fuel, charging, replaced = build_layer(
            [
                _document(
                    _charger(
                        1,
                        51.6,
                        -2.6,
                        name="Gridserve 09981d11-e3db-479d-82cb-088d4dc046ba",
                        brand="Gridserve",
                    ),
                    _fuel(2, 51.7, -2.6, name="way/1234", operator="0006a6641990bc7c"),
                )
            ]
        )
        self.assertEqual(charging[0][2], "Gridserve")
        self.assertEqual(fuel[0][2], "Fuel station")
        self.assertEqual(replaced, 2)

    def test_unnamed_sites_get_a_generic_label(self) -> None:
        fuel, charging, _ = build_layer([_document(_fuel(1, 51.0, -1.0), _charger(2, 51.1, -1.0))])
        self.assertEqual(fuel[0][2], "Fuel station")
        self.assertEqual(charging[0][2], "Charger")

    def test_private_boat_and_bicycle_only_sites_are_left_out(self) -> None:
        fuel, charging, _ = build_layer(
            [
                _document(
                    _fuel(1, 51.0, -1.0, access="private"),
                    _fuel(2, 51.1, -1.0, motorcar="no", boat="yes"),
                    _charger(3, 51.2, -1.0, motorcar="no", bicycle="designated"),
                    _charger(4, 51.3, -1.0, motorcar="no", motorcycle="yes"),
                    _fuel(5, 51.4, -1.0, access="customers"),
                )
            ]
        )
        self.assertEqual([row[0] for row in fuel], [5140000])
        self.assertEqual([row[0] for row in charging], [5130000])

    def test_a_node_on_a_mapped_forecourt_is_one_station(self) -> None:
        fuel, _, _ = build_layer(
            [
                _document(
                    _way(10, 51.5, -2.0, amenity="fuel", brand="Example", **{"fuel:diesel": "yes"}),
                    _fuel(11, 51.5002, -2.0, name="Example Kingsway", **{"fuel:octane_95": "yes"}),
                )
            ]
        )
        # The area leads; the node's name and grades are kept.
        self.assertEqual(fuel, [[5150000, -200000, "Example Kingsway", 5, 0]])

    def test_two_stations_facing_each_other_stay_two(self) -> None:
        # Opposite sides of a dual carriageway: merging would send a rider to
        # the wrong side.
        fuel, _, _ = build_layer(
            [
                _document(
                    _fuel(1, 51.5, -2.0, brand="Example"),
                    _fuel(2, 51.5002, -2.0, brand="Example"),
                    _way(3, 51.6, -2.0, amenity="fuel", brand="Example"),
                    _fuel(4, 51.6002, -2.0, brand="Other"),
                )
            ]
        )
        self.assertEqual(len(fuel), 4)

    def test_charge_posts_in_one_car_park_are_one_site(self) -> None:
        _, charging, _ = build_layer(
            [
                _document(
                    _charger(1, 51.5, -2.0, operator="Example", **{"socket:type2": "1"}),
                    _charger(
                        2,
                        51.5001,
                        -2.0001,
                        operator="Example",
                        **{"socket:type2_combo": "1", "socket:type2_combo:output": "50 kW"},
                    ),
                    _charger(3, 51.5002, -2.0, operator="Different", **{"socket:chademo": "1"}),
                    _charger(4, 51.51, -2.0, operator="Example"),
                )
            ]
        )
        self.assertEqual(len(charging), 3)
        merged = next(row for row in charging if row[2] == "Example" and row[0] == 5150000)
        self.assertEqual(merged[3], CONNECTOR_BITS["type2"] | CONNECTOR_BITS["ccs"])
        self.assertEqual(merged[4], 50)

    def test_overlapping_tiles_and_fetch_order_change_nothing(self) -> None:
        a = _fuel(1, 51.5, -2.0, name="A")
        b = _fuel(2, 51.9, -2.0, name="B")
        c = _charger(3, 51.7, -2.0, name="C")
        forward = build_layer([_document(a, b), _document(b, c)])
        backward = build_layer([_document(c, b), _document(b, a)])
        self.assertEqual(forward, backward)
        self.assertEqual(len(forward[0]), 2)

    def test_the_document_carries_attribution_bits_and_counts(self) -> None:
        document = build_document(
            [_document(_fuel(1, 51.5, -2.0))],
            extract_date="2026-10-10",
            bounded_region="Test region",
            generated_at="2026-10-10",
        )
        self.assertEqual(document["attribution"], "© OpenStreetMap contributors, ODbL")
        self.assertEqual(document["fuelGradeBits"], {"e10": 1, "e5": 2, "diesel": 4})
        self.assertEqual(
            document["connectorBits"], {"type2": 1, "ccs": 2, "chademo": 4, "threePin": 8}
        )
        self.assertEqual(
            document["counts"],
            {"fuel": 1, "charging": 0, "labelsThatSkippedAnIdentifier": 0},
        )


class FuelLayerCliTest(unittest.TestCase):
    def test_refuses_to_write_a_near_empty_layer(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "overpass.json"
            source.write_text(json.dumps(_document(_fuel(1, 51.5, -2.0))), encoding="utf-8")
            output = Path(directory) / "layer.json"
            with self.assertRaises(SystemExit):
                main(
                    [
                        "--overpass",
                        str(source),
                        "--output",
                        str(output),
                        "--extract-date",
                        "2026-10-10",
                        "--bounded-region",
                        "Test",
                        "--minimum-fuel",
                        "2",
                    ]
                )
            self.assertFalse(output.exists())

    def test_writes_the_layer(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "overpass.json"
            source.write_text(
                json.dumps(_document(_fuel(1, 51.5, -2.0), _charger(2, 51.6, -2.0))),
                encoding="utf-8",
            )
            output = Path(directory) / "layer.json"
            main(
                [
                    "--overpass",
                    str(source),
                    "--output",
                    str(output),
                    "--extract-date",
                    "2026-10-10",
                    "--bounded-region",
                    "Test",
                ]
            )
            written = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(written["counts"]["fuel"], 1)
            self.assertEqual(written["counts"]["charging"], 1)


if __name__ == "__main__":
    unittest.main()
