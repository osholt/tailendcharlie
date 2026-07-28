from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools/discovery"))

import prepare_enrichment_inputs  # noqa: E402


def catalogue() -> dict[str, object]:
    return {
        "type": "FeatureCollection",
        "features": [
            {
                "type": "Feature",
                "properties": {
                    "sourceFeatureId": "derived/hash",
                    "sourceFeatureIds": ["way/42", "way/7"],
                },
                "geometry": {"type": "LineString", "coordinates": []},
            },
            {
                "type": "Feature",
                "properties": {"sourceFeatureId": "node/9"},
                "geometry": {"type": "Point", "coordinates": [0, 0]},
            },
            {
                "type": "Feature",
                "properties": {"sourceFeatureId": "relation/3"},
                "geometry": {"type": "Point", "coordinates": [0, 0]},
            },
        ],
    }


class PrepareEnrichmentInputsTest(unittest.TestCase):
    def test_source_ids_are_deduplicated_and_sorted_by_type_and_number(self) -> None:
        payload = catalogue()
        payload["features"].append(payload["features"][0])

        self.assertEqual(
            prepare_enrichment_inputs.catalogue_source_ids(payload),
            ["node/9", "way/7", "way/42", "relation/3"],
        )

    def test_rejects_a_feature_without_a_real_osm_source(self) -> None:
        payload = catalogue()
        payload["features"][0]["properties"] = {"sourceFeatureId": "derived/hash"}

        with self.assertRaisesRegex(ValueError, "no real OSM source ID"):
            prepare_enrichment_inputs.catalogue_source_ids(payload)

    def test_prepares_all_inputs_and_records_their_hashes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = ROOT / "tools/discovery/releases/uk-2026-07-23.toml"
            pbf = root / "source.osm.pbf"
            pbf.write_bytes(b"fixture")
            catalogue_path = root / "discovery-catalogue.geojson"
            catalogue_path.write_text(json.dumps(catalogue()))
            output = root / "out"

            commands: list[list[str]] = []

            def fake_run(command, **kwargs):
                commands.append(list(command))
                if command[1:] == ["--version"]:
                    return subprocess.CompletedProcess(
                        command,
                        0,
                        stdout="osmium version test\n",
                    )
                destination = Path(command[command.index("--output") + 1])
                destination.write_text(f"{command[1]} fixture\n")
                return subprocess.CompletedProcess(command, 0)

            with (
                mock.patch.object(prepare_enrichment_inputs, "validate_pbf"),
                mock.patch.object(
                    prepare_enrichment_inputs.shutil,
                    "which",
                    return_value="/usr/bin/osmium",
                ),
                mock.patch.object(
                    prepare_enrichment_inputs.subprocess,
                    "run",
                    side_effect=fake_run,
                ),
            ):
                record = prepare_enrichment_inputs.prepare_enrichment_inputs(
                    manifest_path=manifest,
                    pbf=pbf,
                    catalogue_path=catalogue_path,
                    output_directory=output,
                )

            self.assertEqual(
                (output / "candidate-osm-ids.txt").read_text(),
                "node/9\nway/7\nway/42\nrelation/3\n",
            )
            self.assertEqual(record["catalogue"]["sourceObjectCount"], 4)
            self.assertEqual(record["catalogue"]["featureCount"], 3)
            self.assertEqual(record["generator"]["osmium"], "osmium version test")
            metadata = json.loads((output / "enrichment-inputs.json").read_text())
            self.assertEqual(metadata, record)
            self.assertEqual(
                set(metadata["files"]),
                {
                    "candidate-osm-ids.txt",
                    "candidate-objects.opl",
                    "enforcement.opl",
                    "places.opl",
                },
            )

            getid = commands[0]
            self.assertIn("--id-file", getid)
            enforcement = commands[1]
            self.assertIn("n/highway=speed_camera", enforcement)
            self.assertIn("r/type=enforcement", enforcement)
            self.assertNotIn("--remove-tags", enforcement)
            places = commands[2]
            self.assertIn(
                "n/place=city,town,village,hamlet,suburb",
                places,
            )
            self.assertIn("n/natural=peak", places)

    def test_refuses_to_mix_new_inputs_with_an_existing_run(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            output = root / "out"
            output.mkdir()
            (output / "places.opl").write_text("old")
            catalogue_path = root / "catalogue.geojson"
            catalogue_path.write_text(json.dumps(catalogue()))
            pbf = root / "source.osm.pbf"
            pbf.write_bytes(b"fixture")

            with (
                mock.patch.object(prepare_enrichment_inputs, "validate_pbf"),
                mock.patch.object(
                    prepare_enrichment_inputs.shutil,
                    "which",
                    return_value="/usr/bin/osmium",
                ),
                self.assertRaisesRegex(FileExistsError, "places.opl"),
            ):
                prepare_enrichment_inputs.prepare_enrichment_inputs(
                    manifest_path=ROOT / "tools/discovery/releases/uk-2026-07-23.toml",
                    pbf=pbf,
                    catalogue_path=catalogue_path,
                    output_directory=output,
                )


if __name__ == "__main__":
    unittest.main()
