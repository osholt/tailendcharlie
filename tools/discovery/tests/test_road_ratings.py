"""The rider-rating aggregation rule (#159)."""

import json
import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

import road_ratings

CATALOGUE = "uk-osm-2026-07-23-v1"


def export(ratings, thresholds=None):
    return {
        "thresholds": thresholds
        if thresholds is not None
        else {
            "minimumResponses": road_ratings.MINIMUM_RESPONSES,
            "promotionShare": road_ratings.PROMOTION_SHARE,
            "reviewShare": road_ratings.REVIEW_SHARE,
        },
        "ratings": ratings,
    }


def rating(**overrides):
    entry = {
        "featureId": "osm-good-biking-road-aaaa",
        "sourceFeatureId": "derived/osm-good-biking-road-aaaa",
        "catalogueVersion": CATALOGUE,
        "category": "good_biking_road",
        "worthIncluding": 0,
        "notWorthIncluding": 0,
        "lastRatedOn": "2026-08-01",
    }
    entry.update(overrides)
    return entry


class RecommendationTest(unittest.TestCase):
    def test_below_the_minimum_recommends_nothing(self):
        self.assertEqual(road_ratings.recommendation(4, 0), "insufficient")
        self.assertEqual(road_ratings.recommendation(0, 4), "insufficient")

    def test_one_rider_cannot_move_a_candidate_either_way(self):
        self.assertEqual(road_ratings.recommendation(1, 0), "insufficient")
        self.assertEqual(road_ratings.recommendation(0, 1), "insufficient")

    def test_seventy_percent_positive_promotes(self):
        self.assertEqual(road_ratings.recommendation(5, 2), "promote")
        self.assertEqual(road_ratings.recommendation(4, 2), "insufficient")

    def test_sixty_percent_negative_flags_for_review(self):
        self.assertEqual(road_ratings.recommendation(2, 3), "review-for-removal")
        self.assertEqual(road_ratings.recommendation(3, 3), "insufficient")

    def test_the_rule_matches_the_relay(self):
        relay = (
            pathlib.Path(__file__).resolve().parents[3]
            / "apps/server/src/ride_relay_server/discovery.py"
        ).read_text()
        self.assertIn(
            f"ROAD_RATING_MINIMUM_RESPONSES = {road_ratings.MINIMUM_RESPONSES}",
            relay,
        )
        self.assertIn(
            f"ROAD_RATING_PROMOTION_SHARE = {road_ratings.PROMOTION_SHARE}",
            relay,
        )
        self.assertIn(f"ROAD_RATING_REVIEW_SHARE = {road_ratings.REVIEW_SHARE}", relay)


class IndexTest(unittest.TestCase):
    def test_both_ids_resolve_to_the_same_record(self):
        result = road_ratings.index(
            export([rating(worthIncluding=6, notWorthIncluding=1)]),
            CATALOGUE,
        )

        self.assertEqual(
            result["derived/osm-good-biking-road-aaaa"],
            result["osm-good-biking-road-aaaa"],
        )
        self.assertEqual(result["osm-good-biking-road-aaaa"]["recommendation"], "promote")

    def test_a_rating_for_another_release_is_not_counted(self):
        result = road_ratings.index(
            export([rating(catalogueVersion="uk-osm-2026-09-01-v1", worthIncluding=9)]),
            CATALOGUE,
        )

        self.assertEqual(result, {})

    def test_an_export_aggregated_under_a_different_rule_is_refused(self):
        with self.assertRaises(SystemExit):
            road_ratings.index(
                export([rating()], thresholds={"minimumResponses": 1}),
                CATALOGUE,
            )

    def test_lookup_prefers_the_stable_upstream_key(self):
        ratings = road_ratings.index(
            export(
                [
                    rating(worthIncluding=6),
                    rating(
                        featureId="osm-good-biking-road-bbbb",
                        sourceFeatureId=None,
                        notWorthIncluding=6,
                    ),
                ]
            ),
            CATALOGUE,
        )

        stable = road_ratings.lookup(
            ratings,
            {
                "id": "osm-good-biking-road-bbbb",
                "sourceFeatureId": "derived/osm-good-biking-road-aaaa",
            },
        )
        self.assertEqual(stable["recommendation"], "promote")

        fallback = road_ratings.lookup(
            ratings,
            {"id": "osm-good-biking-road-bbbb", "sourceFeatureId": None},
        )
        self.assertEqual(fallback["recommendation"], "review-for-removal")

        self.assertIsNone(road_ratings.lookup(ratings, {"id": "unrated"}))


class LoadTest(unittest.TestCase):
    def test_a_missing_export_is_not_an_error(self):
        with tempfile.TemporaryDirectory() as directory:
            self.assertEqual(
                road_ratings.load(CATALOGUE, path=f"{directory}/absent.json"),
                {},
            )

    def test_an_export_on_disk_is_indexed(self):
        with tempfile.TemporaryDirectory() as directory:
            path = f"{directory}/road-ratings.json"
            with open(path, "w") as handle:
                json.dump(export([rating(worthIncluding=5, notWorthIncluding=2)]), handle)

            result = road_ratings.load(CATALOGUE, path=path)

        self.assertEqual(result["osm-good-biking-road-aaaa"]["recommendation"], "promote")


if __name__ == "__main__":
    unittest.main()
