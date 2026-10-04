"""The restricted-road limit follows the law of the nation it is in (#852).

`maxspeed:type=GB:nsl_restricted` was mapped to 30 mph everywhere. Since
17 September 2023 the default on a restricted road in Wales is 20 mph, so every
Welsh road tagged that way and not since changed was reported as 30 mph, which is
wrong. The generator has no administrative boundary data, so Wales cannot be
recognised; the rule resolves a limit only for a road wholly outside a generous
envelope of Wales, and leaves everything else unknown.
"""

import contextlib
import io
import json
import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

import enrich_deterministic as enrich

# Places, as (lon, lat). They are test inputs: nothing in the generator names them.
EDINBARNET = (-4.405, 55.925)  # Scotland
COTSWOLDS = (-1.90, 51.80)  # England, well away from Wales
PEAK_DISTRICT = (-1.80, 53.30)  # England
USK = (-2.90, 51.70)  # Wales
CARDIFF = (-3.18, 51.48)  # Wales
ANGLESEY = (-4.40, 53.30)  # Wales, an island
BRISTOL = (-2.59, 51.45)  # England, inside the envelope all the same
HOYLAKE = (-3.18, 53.39)  # England, inside the envelope all the same

RESTRICTED = {"highway": "residential", "maxspeed:type": "GB:nsl_restricted"}


class ImpliedLimitTest(unittest.TestCase):
    def test_the_national_limits_that_do_not_depend_on_the_nation_are_unchanged(self):
        for maxspeed_type, limit in (
            ("GB:nsl_single", "60 mph"),
            ("GB:nsl_dual", "70 mph"),
            ("GB:motorway", "70 mph"),
            ("GB:zone20", "20 mph"),
            ("GB:zone30", "30 mph"),
            ("GB:zone40", "40 mph"),
        ):
            for outside_wales in (False, True):
                self.assertEqual(
                    enrich.implied_limit(maxspeed_type, outside_wales=outside_wales),
                    limit,
                    msg=f"{maxspeed_type} outside_wales={outside_wales}",
                )

    def test_a_restricted_road_is_30_only_where_it_is_known_not_to_be_welsh(self):
        self.assertEqual(enrich.implied_limit("GB:nsl_restricted", outside_wales=True), "30 mph")
        self.assertIsNone(enrich.implied_limit("GB:nsl_restricted", outside_wales=False))

    def test_a_tag_that_fixes_no_limit_fixes_none(self):
        for maxspeed_type in ("", "walk", "GB:something_new", None):
            self.assertIsNone(enrich.implied_limit(maxspeed_type, outside_wales=True))

    def test_30_is_no_longer_in_the_table_for_a_restricted_road(self):
        self.assertNotIn("GB:nsl_restricted", enrich.NSL)


class WalesEnvelopeTest(unittest.TestCase):
    def test_roads_far_from_wales_are_clearly_outside_it(self):
        for place in (EDINBARNET, COTSWOLDS, PEAK_DISTRICT):
            self.assertTrue(enrich.clearly_outside_wales([place]), msg=str(place))

    def test_wales_is_never_clearly_outside_itself(self):
        for place in (USK, CARDIFF, ANGLESEY):
            self.assertFalse(enrich.clearly_outside_wales([place]), msg=str(place))

    def test_english_places_beside_wales_are_left_unresolved_not_called_welsh(self):
        # The envelope is a box, so it holds some of England. Those roads are left
        # unknown: unknown is true of them, where 30 mph might not be of Wales.
        for place in (BRISTOL, HOYLAKE):
            self.assertFalse(enrich.clearly_outside_wales([place]), msg=str(place))

    def test_a_road_that_touches_the_envelope_is_not_outside_it(self):
        self.assertFalse(enrich.clearly_outside_wales([COTSWOLDS, USK]))
        self.assertFalse(enrich.clearly_outside_wales([USK, COTSWOLDS]))

    def test_a_road_with_no_position_is_not_shown_to_be_anywhere(self):
        self.assertFalse(enrich.clearly_outside_wales([]))

    def test_the_envelope_contains_the_extremes_of_wales(self):
        west, south, east, north = enrich.WALES_ENVELOPE
        # St Davids Head, Flat Holm, Chepstow, Point Lynas: the far points of Wales.
        for lon, lat in ((-5.33, 51.92), (-3.12, 51.38), (-2.65, 51.64), (-4.29, 53.42)):
            self.assertTrue(west <= lon <= east and south <= lat <= north, msg=f"{lon},{lat}")


class SpeedLimitForTest(unittest.TestCase):
    def limit(self, ways, **kwargs):
        return enrich.speed_limit_for(ways, unknown_note="unknown", **kwargs)

    def test_a_restricted_road_outside_wales_is_inferred_at_30(self):
        result = self.limit([RESTRICTED], outside_wales=True)

        self.assertEqual(result["value"], "30 mph")
        self.assertEqual(result["provenance"], "inferred-from-maxspeed-type")

    def test_a_restricted_road_is_never_30_when_the_nation_is_not_known(self):
        result = self.limit([RESTRICTED])

        self.assertIsNone(result["value"])
        self.assertEqual(result["provenance"], "unknown")
        self.assertEqual(result["note"], enrich.RESTRICTED_LIMIT_UNKNOWN)
        self.assertIn("20 mph in Wales", result["note"])

    def test_a_restricted_road_inside_the_envelope_is_unknown_not_30(self):
        result = self.limit([RESTRICTED], outside_wales=False)

        self.assertIsNone(result["value"])
        self.assertNotIn("30", json.dumps(result["value"]))

    def test_a_limit_that_is_mapped_is_believed_wherever_the_road_is(self):
        # A Welsh road returned to 30 is mapped 30; the map says so, so the
        # generator says so, however the road is tagged beside it.
        tagged = {**RESTRICTED, "maxspeed": "30 mph"}

        for outside_wales in (False, True):
            result = self.limit([tagged], outside_wales=outside_wales)
            self.assertEqual(result["value"], "30 mph")
            self.assertEqual(result["provenance"], "tagged")

    def test_a_mapped_20_is_believed_too(self):
        result = self.limit([{"highway": "residential", "maxspeed": "20 mph"}])

        self.assertEqual((result["value"], result["provenance"]), ("20 mph", "tagged"))

    def test_an_unresolved_restricted_way_does_not_dilute_a_mapped_one(self):
        result = self.limit([{"maxspeed": "40 mph"}, RESTRICTED])

        self.assertEqual((result["value"], result["provenance"]), ("40 mph", "tagged"))
        self.assertFalse(result["mixed"])

    def test_a_road_with_no_limit_at_all_keeps_its_own_note(self):
        result = self.limit([{"highway": "residential"}])

        self.assertEqual(result["note"], "unknown")


PLACES = {
    "way/101": ("scotland", EDINBARNET),
    "way/102": ("england-away-from-wales", COTSWOLDS),
    "way/103": ("wales", USK),
    "way/104": ("england-beside-wales", BRISTOL),
    "way/105": ("wales-mapped-30", CARDIFF),
}


class MainTest(unittest.TestCase):
    """The whole stage, over a catalogue of restricted roads in five places."""

    def run_stage(self):
        features = [
            {
                "type": "Feature",
                "properties": {
                    "id": f"candidate-{name}",
                    "category": "good_biking_road",
                    "sourceFeatureId": way,
                },
                "geometry": {
                    "type": "LineString",
                    "coordinates": [list(place), [place[0] + 0.001, place[1] + 0.001]],
                },
            }
            for way, (name, place) in PLACES.items()
        ]
        with tempfile.TemporaryDirectory() as directory:
            work = pathlib.Path(directory)
            (work / "discovery-catalogue.geojson").write_text(
                json.dumps({"type": "FeatureCollection", "features": features})
            )
            lines = []
            for way in PLACES:
                tags = "highway=residential,maxspeed:type=GB:nsl_restricted"
                if way == "way/105":
                    tags += ",maxspeed=30 mph"
                lines.append(f"w{way.split('/')[1]} T{tags.replace(' ', '%20%')} Nn1,n2")
            (work / "candidate-objects.opl").write_text("\n".join(lines) + "\n")
            (work / "enforcement.opl").write_text("")
            (work / "places.opl").write_text("")
            previous = enrich.OUT
            enrich.OUT = str(work)
            try:
                with contextlib.redirect_stdout(io.StringIO()):
                    enrich.main()
            finally:
                enrich.OUT = previous
            return json.loads((work / "enrichment-deterministic.json").read_text())

    def test_each_road_is_resolved_by_where_it_is(self):
        enrichment = self.run_stage()

        limits = {
            name: enrichment[f"candidate-{name}"]["speedLimit"] for name, _ in PLACES.values()
        }
        self.assertEqual(limits["scotland"]["value"], "30 mph")
        self.assertEqual(limits["england-away-from-wales"]["value"], "30 mph")
        self.assertEqual(limits["scotland"]["provenance"], "inferred-from-maxspeed-type")

        self.assertIsNone(limits["wales"]["value"])
        self.assertEqual(limits["wales"]["provenance"], "unknown")
        self.assertIsNone(limits["england-beside-wales"]["value"])

        self.assertEqual(limits["wales-mapped-30"]["value"], "30 mph")
        self.assertEqual(limits["wales-mapped-30"]["provenance"], "tagged")

    def test_no_welsh_road_is_inferred_at_30(self):
        enrichment = self.run_stage()

        for name in ("wales", "england-beside-wales"):
            limit = enrichment[f"candidate-{name}"]["speedLimit"]
            self.assertNotEqual(limit["provenance"], "inferred-from-maxspeed-type", msg=name)


if __name__ == "__main__":
    unittest.main()
