import json
import tempfile
import unittest
from pathlib import Path

from tools.places.generate_french_route_places import build_index


class FrenchPlacesTest(unittest.TestCase):
    def test_filters_deduplicates_and_preserves_source_attribution(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "source.json"
            output = Path(temporary) / "index.json"
            town = {
                "nom": "Limoges",
                "code": "87085",
                "population": 130000,
                "mairie": {"coordinates": [1.261, 45.835]},
            }
            source.write_text(
                json.dumps(
                    [
                        town,
                        town,
                        {"nom": "Missing geometry", "code": "1"},
                        {**town, "code": "2", "mairie": {"coordinates": [151, -33]}},
                        {**town, "nom": "Village", "code": "3", "population": 100},
                    ]
                )
            )
            self.assertEqual(build_index(source, output, source_version="test"), 2)
            payload = json.loads(output.read_text())
            self.assertEqual(
                payload["places"],
                [
                    [4583500, 126100, "Limoges", 0],
                    [4583500, 126100, "Village", 3],
                ],
            )
            self.assertEqual(payload["license"], "ODbL-1.0")
            self.assertIn("IGN", payload["attribution"])
            self.assertEqual(len(payload["sourceSha256"]), 64)


if __name__ == "__main__":
    unittest.main()
