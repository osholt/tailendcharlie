from __future__ import annotations

import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT))

from tools.discovery.generate_catalogue import (  # noqa: E402
    LAYER_FILENAMES,
    ReleaseManifest,
    encode_collection,
    generate_catalogue,
    main,
    review_region,
    validate_features,
    validate_pbf,
)


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
            self.assertEqual(
                json.loads(review.read_text())["properties"]["publicationStatus"],
                "not-for-publication",
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


if __name__ == "__main__":
    unittest.main()
