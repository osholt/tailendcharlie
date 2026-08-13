from __future__ import annotations

import csv
import io
import json
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from generate_route_places import build_index


HEADER_LENGTH = 34


def row(feature_id: str, name: str, feature_type: str, local_type: str) -> list[str]:
    values = [""] * HEADER_LENGTH
    values[0] = feature_id
    values[2] = name
    values[6] = feature_type
    values[7] = local_type
    values[8] = "100"
    values[9] = "200"
    return values


class GenerateRoutePlacesTest(unittest.TestCase):
    def test_filters_compacts_sorts_and_deduplicates(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "names.zip"
            output = Path(temporary) / "places.json"
            buffer = io.StringIO(newline="")
            writer = csv.writer(buffer)
            writer.writerows(
                [
                    row("2", "  Kingswood  ", "populatedPlace", "Suburban Area"),
                    row("1", "Chippenham", "populatedPlace", "Town"),
                    row("2", "Duplicate", "populatedPlace", "Town"),
                    row("3", "A road", "transportNetwork", "Named Road"),
                ]
            )
            with zipfile.ZipFile(source, "w") as archive:
                archive.writestr("Data/fixture.csv", buffer.getvalue())

            count = build_index(
                source,
                output,
                source_version="test",
                transform=lambda x, y: (x / 100, y / 100),
            )

            payload = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(count, 2)
            self.assertEqual(payload["sourceVersion"], "test")
            self.assertTrue(payload["attribution"].endswith("test"))
            self.assertEqual(
                payload["places"],
                [
                    [200000, 100000, "Chippenham", 1],
                    [200000, 100000, "Kingswood", 2],
                ],
            )


if __name__ == "__main__":
    unittest.main()
