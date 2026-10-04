"""No label shipped in a bundled catalogue is an identifier (#860).

A field report showed a charging station labelled with its operator's name and
a UUID. That label came from the basemap provider's own tiles, not from anything
generated here, but the same rule applies to everything this repository
generates and bundles: a rider should never see an internal or source
identifier, so a name that is one must not reach an asset.

The check runs over the committed outputs rather than inside the generators, for
two reasons. The generators run against a 2 GB extract, so a filter inside them
could not be exercised by CI, and a filter that silently dropped a name would
hide the very data fault this is meant to surface. A catalogue is reviewed before
it is published (see `tools/discovery/README.md`); this makes the review fail
loudly if an identifier has got into a label.
"""

from __future__ import annotations

import json
import re
import unittest
from collections.abc import Iterator
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]

UUID = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
# A run of 16 or more hex digits standing alone: a hash or a database key.
HEX_RUN = re.compile(r"(?<![0-9A-Za-z])[0-9a-fA-F]{16,}(?![0-9A-Za-z])")
# An OpenStreetMap element reference such as `way/123456`.
OSM_ELEMENT = re.compile(r"(?<![A-Za-z])(?:node|way|relation)[/ ]\d+", re.IGNORECASE)

DISCOVERY_CATALOGUES = (
    "apps/mobile/assets/discovery_catalogue.geojson",
    "apps/website/data/discovery-catalogue.geojson",
)
BIKER_PLACES = "apps/mobile/assets/biker_places.json"
ROUTE_PLACES = (
    "apps/mobile/assets/route_places.json",
    "apps/mobile/assets/route_places_fr.json",
)


def looks_like_identifier(text: str) -> bool:
    """Whether a label contains a UUID, a bare hash or an OSM element reference."""
    return bool(UUID.search(text) or HEX_RUN.search(text) or OSM_ELEMENT.search(text))


def load(relative: str) -> object:
    return json.loads((ROOT / relative).read_text(encoding="utf-8"))


def discovery_labels(catalogue: dict) -> Iterator[tuple[str, str]]:
    for feature in catalogue["features"]:
        properties = feature["properties"]
        for key in ("name", "locality"):
            value = properties.get(key)
            if isinstance(value, str):
                yield f"{properties['id']}.{key}", value
        for reference in properties.get("roadRefs") or []:
            if isinstance(reference, str):
                yield f"{properties['id']}.roadRefs", reference


def biker_place_labels(catalogue: dict) -> Iterator[tuple[str, str]]:
    for place in catalogue["places"]:
        for key in ("name", "address"):
            value = place.get(key)
            if isinstance(value, str):
                yield f"{place['name']}.{key}", value
        for alias in place.get("aliases") or []:
            yield f"{place['name']}.aliases", alias


def route_place_labels(index: dict) -> Iterator[tuple[str, str]]:
    for place in index["places"]:
        # [easting, northing, name, rank]
        yield f"place {place[0]},{place[1]}", place[2]


class IdentifierDetectorTest(unittest.TestCase):
    """The detector has to see what it is looking for, or the scans prove nothing."""

    def test_recognises_the_label_from_the_field_report(self) -> None:
        self.assertTrue(looks_like_identifier("Gridserve 09981d11-e3db-479d-82cb-088d4dc046ba"))

    def test_recognises_other_identifier_shapes(self) -> None:
        for label in (
            "09981D11-E3DB-479D-82CB-088D4DC046BA",
            "osm-good-biking-road-0006a6641990bc7c",
            "0006a6641990bc7c",
            "way/1397919343",
            "Node 104478",
        ):
            with self.subTest(label=label):
                self.assertTrue(looks_like_identifier(label))

    def test_leaves_real_names_alone(self) -> None:
        for label in (
            "B9078",
            "A38(M)",
            "Cheddar Gorge",
            "Hardknott Pass",
            "King's Oak Academy car park",
            "Brook Road, Kingswood, Bristol BS15 4JT",
            "1915",
            "St Agnes",
            "Unnamed rural road section",
        ):
            with self.subTest(label=label):
                self.assertFalse(looks_like_identifier(label))


class PublishedLabelsTest(unittest.TestCase):
    def assert_no_identifiers(
        self, source: str, labels: Iterator[tuple[str, str]], *, at_least: int
    ) -> None:
        """Fail on an identifier label, or if the scan saw fewer labels than expected.

        `at_least` is how many labels the asset must yield, so a scan that quietly
        stopped reading a field cannot pass for an asset with nothing wrong in it.
        """
        seen = 0
        offenders = []
        for where, label in labels:
            seen += 1
            if looks_like_identifier(label):
                offenders.append(f"{where}: {label!r}")
        self.assertGreaterEqual(seen, at_least, f"{source} yielded too few labels to check")
        self.assertEqual(
            offenders[:10],
            [],
            f"{source} has {len(offenders)} label(s) that are identifiers",
        )

    def test_discovery_catalogues_label_roads_by_name_not_by_identifier(self) -> None:
        for relative in DISCOVERY_CATALOGUES:
            catalogue = load(relative)
            with self.subTest(catalogue=relative):
                # Every feature has a name, so at least one label each.
                self.assert_no_identifiers(
                    relative,
                    discovery_labels(catalogue),
                    at_least=len(catalogue["features"]),
                )

    def test_biker_places_carry_no_identifier(self) -> None:
        catalogue = load(BIKER_PLACES)

        # A name and an address for every place.
        self.assert_no_identifiers(
            BIKER_PLACES,
            biker_place_labels(catalogue),
            at_least=2 * len(catalogue["places"]),
        )

    def test_route_place_names_carry_no_identifier(self) -> None:
        for relative in ROUTE_PLACES:
            index = load(relative)
            with self.subTest(index=relative):
                self.assert_no_identifiers(
                    relative, route_place_labels(index), at_least=len(index["places"])
                )

    def test_the_two_discovery_copies_are_the_same_catalogue(self) -> None:
        # Both are scanned above; if they ever diverge the scan covers neither
        # as the app and the website would see it.
        first, second = ((ROOT / relative).read_bytes() for relative in DISCOVERY_CATALOGUES)
        self.assertEqual(first, second)

    def test_a_catalogue_with_an_identifier_label_would_be_caught(self) -> None:
        catalogue = {
            "features": [
                {
                    "properties": {
                        "id": "osm-test",
                        "name": "Gridserve 09981d11-e3db-479d-82cb-088d4dc046ba",
                    }
                }
            ]
        }

        with self.assertRaises(AssertionError):
            self.assert_no_identifiers("fixture", discovery_labels(catalogue), at_least=1)

    def test_a_scan_that_stops_reading_a_field_would_be_caught(self) -> None:
        catalogue = {"features": [{"properties": {"id": "osm-test", "name": "B9078"}}]}

        with self.assertRaises(AssertionError):
            self.assert_no_identifiers("fixture", iter(()), at_least=len(catalogue["features"]))


if __name__ == "__main__":
    unittest.main()
