from __future__ import annotations

import hashlib
import json
import sys
import tempfile
import unittest
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT))

from tools.discovery.generate_catalogue import (  # noqa: E402
    LAYER_FILENAMES,
    MINIMUM_PYTHON,
    REVIEW_SAMPLE_PER_NATION,
    REVIEW_SAMPLE_REGIONS,
    UNASSIGNED_REVIEW_REGION,
    ReleaseManifest,
    build_review_sample,
    encode_collection,
    generate_catalogue,
    main,
    review_region,
    validate_features,
    validate_pbf,
)

NATION_ANCHORS = {
    "England": (-1.9, 52.5),
    "Scotland": (-4.2, 57.2),
    "Wales": (-4.0, 52.2),
    "Northern Ireland": (-6.7, 54.6),
}
BORDER_ANCHOR = (-3.0, 55.2)


def line_feature(
    category: str,
    identifier: str,
    anchor: tuple[float, float],
    score: int,
) -> dict[str, object]:
    longitude, latitude = anchor
    return {
        "type": "Feature",
        "properties": {"id": identifier, "category": category, "score": score},
        "geometry": {
            "type": "LineString",
            "coordinates": [
                [longitude, latitude],
                [longitude + 0.01, latitude + 0.01],
                [longitude + 0.02, latitude + 0.02],
            ],
        },
    }


def point_feature(identifier: str, anchor: tuple[float, float]) -> dict[str, object]:
    return {
        "type": "Feature",
        "properties": {"id": identifier, "category": "mountain_pass", "score": None},
        "geometry": {"type": "Point", "coordinates": list(anchor)},
    }


def synthetic_collection(
    *,
    per_nation: dict[str, int],
    passes: int = 3,
    border_passes: int = 1,
) -> dict[str, object]:
    """Build a catalogue-shaped collection with known nation/category placement."""
    features: list[dict[str, object]] = []
    for nation, anchor in NATION_ANCHORS.items():
        for index in range(per_nation[nation]):
            for category in ("twisty_highlight", "good_biking_road"):
                features.append(
                    line_feature(
                        category,
                        f"{category}-{nation.replace(' ', '-').lower()}-{index:03d}",
                        (anchor[0] + index * 0.001, anchor[1] + index * 0.001),
                        score=100 - index,
                    )
                )
    for index in range(passes):
        nation = list(NATION_ANCHORS)[index % len(NATION_ANCHORS)]
        anchor = NATION_ANCHORS[nation]
        features.append(point_feature(f"pass-{index:03d}", (anchor[0], anchor[1] + index * 0.01)))
    for index in range(border_passes):
        features.append(
            point_feature(f"border-pass-{index:03d}", (BORDER_ANCHOR[0], BORDER_ANCHOR[1]))
        )
    features.sort(
        key=lambda feature: (feature["properties"]["category"], feature["properties"]["id"])
    )
    return {
        "type": "FeatureCollection",
        "properties": {"catalogueVersion": "test-version"},
        "features": features,
    }


class DiscoveryCatalogueTest(unittest.TestCase):
    def setUp(self) -> None:
        self.manifest_path = ROOT / "tools/discovery/releases/uk-2026-07-23.toml"
        self.manifest = ReleaseManifest.load(self.manifest_path)
        self.fixture = ROOT / "tools/discovery/tests/fixtures/osmium-export.geojsonseq"

    def generate(self, database: Path) -> dict[str, object]:
        return generate_catalogue(
            self.fixture,
            self.manifest,
            limits={
                "twisty_highlight": 100,
                "good_biking_road": 100,
                "mountain_pass": 100,
            },
            database_path=database,
        )

    def test_generates_deterministic_review_gated_layers(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            first = self.generate(Path(temporary) / "first.sqlite3")
            second = self.generate(Path(temporary) / "second.sqlite3")

        self.assertEqual(encode_collection(first), encode_collection(second))
        self.assertEqual(first["properties"]["publicationStatus"], "review-required")
        categories = [feature["properties"]["category"] for feature in first["features"]]
        self.assertIn("twisty_highlight", categories)
        self.assertIn("good_biking_road", categories)
        self.assertIn("mountain_pass", categories)
        self.assertEqual(categories.count("mountain_pass"), 1)
        self.assertTrue(
            all(
                feature["properties"]["moderationStatus"] == "generated-review-required"
                for feature in first["features"]
            )
        )
        self.assertTrue(
            all(feature["properties"]["sourceFeatureIds"] for feature in first["features"])
        )
        self.assertFalse(any("Motorway" in str(feature) for feature in first["features"]))
        self.assertFalse(any("Urban Road" in str(feature) for feature in first["features"]))

    def test_cli_writes_identical_web_mobile_and_separate_layers(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            web = root / "web.geojson"
            mobile = root / "mobile.geojson"
            layers = root / "layers"
            review = root / "manual-review.geojson"
            result = main(
                [
                    "--manifest",
                    str(self.manifest_path),
                    "--geojson-sequence",
                    str(self.fixture),
                    "--output",
                    str(web),
                    "--output",
                    str(mobile),
                    "--layer-directory",
                    str(layers),
                    "--review-sample",
                    str(review),
                ]
            )

            self.assertEqual(result, 0)
            self.assertEqual(web.read_bytes(), mobile.read_bytes())
            layer_manifest = json.loads((layers / "manifest.json").read_text())
            for category, filename in LAYER_FILENAMES.items():
                payload = (layers / filename).read_bytes()
                self.assertEqual(
                    hashlib.sha256(payload).hexdigest(),
                    layer_manifest["layers"][category]["sha256"],
                )
            sample = json.loads(review.read_text())
            self.assertEqual(sample["properties"]["publicationStatus"], "not-for-publication")
            sampling = sample["properties"]["sampling"]
            self.assertEqual(sampling["quotaPerNationPerCategory"], REVIEW_SAMPLE_PER_NATION)
            self.assertEqual(sampling["exhaustiveCategories"], ["mountain_pass"])
            self.assertEqual(sampling["selected"], len(sample["features"]))
            self.assertEqual(
                set(sampling["countsByCategoryAndRegion"]),
                {
                    feature["properties"]["category"]
                    for feature in json.loads(web.read_text())["features"]
                },
            )

    def test_rejects_extract_that_does_not_match_the_pin(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            candidate = Path(temporary) / self.manifest.source_filename
            candidate.write_bytes(b"not the two gigabyte extract")

            with self.assertRaisesRegex(ValueError, "size"):
                validate_pbf(candidate, self.manifest)

    def test_rejects_duplicate_ids_and_geometry(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            collection = self.generate(Path(temporary) / "working.sqlite3")
        first = collection["features"][0]

        with self.assertRaisesRegex(ValueError, "Duplicate discovery feature ID"):
            validate_features([first, first])

        duplicate_geometry = json.loads(json.dumps(first))
        duplicate_geometry["properties"]["id"] = "different-id"
        with self.assertRaisesRegex(ValueError, "Duplicate .* geometry"):
            validate_features([first, duplicate_geometry])

    def test_review_regions_use_non_overlapping_nation_cores(self) -> None:
        self.assertEqual(review_region((-1.9, 52.5)), "England")
        self.assertEqual(review_region((-4.2, 57.2)), "Scotland")
        self.assertEqual(review_region((-4.0, 52.2)), "Wales")
        self.assertEqual(review_region((-6.7, 54.6)), "Northern Ireland")
        self.assertIsNone(review_region((-3.0, 55.2)))

    def test_review_sample_covers_the_mountain_pass_layer(self) -> None:
        """A sample that omits a layer certifies a layer it never looked at."""
        with tempfile.TemporaryDirectory() as temporary:
            collection = self.generate(Path(temporary) / "working.sqlite3")
        sample = build_review_sample(collection)

        catalogued = Counter(
            feature["properties"]["category"] for feature in collection["features"]
        )
        sampled = Counter(feature["properties"]["category"] for feature in sample["features"])
        for category in catalogued:
            self.assertGreater(sampled[category], 0, f"{category} was not sampled")
        self.assertEqual(sampled["mountain_pass"], catalogued["mountain_pass"])

    def test_review_sample_stratifies_by_category_and_nation(self) -> None:
        collection = synthetic_collection(
            per_nation={nation: 15 for nation in NATION_ANCHORS},
            passes=6,
            border_passes=2,
        )
        sample = build_review_sample(collection)
        sampling = sample["properties"]["sampling"]

        for category in ("twisty_highlight", "good_biking_road"):
            for nation in REVIEW_SAMPLE_REGIONS:
                self.assertEqual(
                    sampling["countsByCategoryAndRegion"][category][nation],
                    REVIEW_SAMPLE_PER_NATION,
                )
        self.assertEqual(sampling["shortfalls"], [])
        self.assertEqual(sampling["selected"], 2 * 4 * REVIEW_SAMPLE_PER_NATION + 8)
        self.assertEqual(
            sampling["countsByCategoryAndRegion"]["mountain_pass"][UNASSIGNED_REVIEW_REGION],
            2,
        )
        self.assertEqual(
            sum(sampling["countsByCategoryAndRegion"]["mountain_pass"].values()),
            8,
        )
        self.assertEqual(
            {feature["properties"]["reviewRegion"] for feature in sample["features"]},
            set(REVIEW_SAMPLE_REGIONS) | {UNASSIGNED_REVIEW_REGION},
        )
        self.assertTrue(
            all(
                feature["properties"]["manualReview"] == "pending" for feature in sample["features"]
            )
        )
        self.assertEqual(sample["properties"]["publicationStatus"], "not-for-publication")

    def test_review_sample_reports_a_nation_short_of_the_quota(self) -> None:
        counts = {nation: 15 for nation in NATION_ANCHORS}
        counts["Northern Ireland"] = 4
        sample = build_review_sample(
            synthetic_collection(per_nation=counts, passes=0, border_passes=0)
        )
        sampling = sample["properties"]["sampling"]

        self.assertEqual(
            sampling["countsByCategoryAndRegion"]["twisty_highlight"]["Northern Ireland"],
            4,
        )
        shortfalls = {
            (item["category"], item["reviewRegion"]): item for item in sampling["shortfalls"]
        }
        self.assertEqual(
            set(shortfalls),
            {
                ("twisty_highlight", "Northern Ireland"),
                ("good_biking_road", "Northern Ireland"),
            },
        )
        self.assertEqual(shortfalls[("twisty_highlight", "Northern Ireland")]["selected"], 4)
        self.assertEqual(
            shortfalls[("twisty_highlight", "Northern Ireland")]["requested"],
            REVIEW_SAMPLE_PER_NATION,
        )
        # The shortfall is neither padded from another nation nor dropped.
        self.assertEqual(sampling["selected"], 2 * (3 * REVIEW_SAMPLE_PER_NATION + 4))

    def test_review_sample_is_deterministic_and_order_independent(self) -> None:
        collection = synthetic_collection(per_nation={nation: 15 for nation in NATION_ANCHORS})
        shuffled = json.loads(json.dumps(collection))
        shuffled["features"] = list(reversed(shuffled["features"]))

        self.assertEqual(
            encode_collection(build_review_sample(collection)),
            encode_collection(build_review_sample(collection)),
        )
        self.assertEqual(
            encode_collection(build_review_sample(collection)),
            encode_collection(build_review_sample(shuffled)),
        )

    def test_review_sample_refuses_to_skip_an_unknown_category(self) -> None:
        collection = synthetic_collection(per_nation={nation: 1 for nation in NATION_ANCHORS})
        collection["features"][0]["properties"]["category"] = "gravel_adventure"

        with self.assertRaisesRegex(ValueError, "REVIEW_CATEGORY_ORDER"):
            build_review_sample(collection)

    def test_interpreter_version_guard_runs_before_tomllib_is_imported(self) -> None:
        self.assertEqual(MINIMUM_PYTHON, (3, 11))
        source = (ROOT / "tools/discovery/generate_catalogue.py").read_text(encoding="utf-8")
        self.assertLess(
            source.index("if sys.version_info < MINIMUM_PYTHON"),
            source.index("import tomllib"),
            "tomllib must not be imported before the interpreter version is checked",
        )


if __name__ == "__main__":
    unittest.main()
