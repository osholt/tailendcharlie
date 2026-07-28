#!/usr/bin/env python3
"""Build the OPL inputs used by the discovery enrichment pipeline.

The rider-facing catalogue is generated from a pinned, checksummed OSM extract,
but the enrichment stage also needs the source objects behind each candidate,
enforcement relations and nearby named places.  Those files used to be made by
ad-hoc shell commands outside the repository.  This tool makes that boundary
repeatable and records hashes for every derived input.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import tempfile
from collections.abc import Sequence
from pathlib import Path

from generate_catalogue import ReleaseManifest, validate_pbf

OSM_TYPE_PREFIXES = {"node": "n", "way": "w", "relation": "r"}
OUTPUT_FILENAMES = (
    "candidate-osm-ids.txt",
    "candidate-objects.opl",
    "enforcement.opl",
    "places.opl",
    "enrichment-inputs.json",
)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(4 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def catalogue_source_ids(catalogue: dict[str, object]) -> list[str]:
    """Return the real OSM source IDs in stable type/numeric order."""
    features = catalogue.get("features")
    if not isinstance(features, list) or not features:
        raise ValueError("Catalogue has no features")

    source_ids: set[str] = set()
    for index, feature in enumerate(features):
        if not isinstance(feature, dict):
            raise ValueError(f"Catalogue feature {index} is not an object")
        properties = feature.get("properties")
        if not isinstance(properties, dict):
            raise ValueError(f"Catalogue feature {index} has no properties")

        raw_ids = properties.get("sourceFeatureIds")
        if raw_ids is None:
            raw_ids = [properties.get("sourceFeatureId")]
        if not isinstance(raw_ids, list):
            raise ValueError(f"Catalogue feature {index} has invalid sourceFeatureIds")

        feature_ids = 0
        for source_id in raw_ids:
            if not isinstance(source_id, str):
                raise ValueError(f"Catalogue feature {index} has a non-string source ID")
            if source_id.startswith("derived/"):
                continue
            kind, separator, identifier = source_id.partition("/")
            if (
                not separator
                or kind not in OSM_TYPE_PREFIXES
                or not identifier.isdigit()
                or int(identifier) <= 0
            ):
                raise ValueError(
                    f"Catalogue feature {index} has invalid OSM source ID {source_id!r}"
                )
            source_ids.add(source_id)
            feature_ids += 1
        if feature_ids == 0:
            raise ValueError(f"Catalogue feature {index} has no real OSM source ID")

    type_order = {kind: index for index, kind in enumerate(OSM_TYPE_PREFIXES)}
    return sorted(
        source_ids,
        key=lambda value: (
            type_order[value.split("/", 1)[0]],
            int(value.split("/", 1)[1]),
        ),
    )


def _run(command: Sequence[str]) -> None:
    subprocess.run(command, check=True)  # noqa: S603 - executable is resolved locally


def _write_opl_inputs(
    *,
    osmium: str,
    pbf: Path,
    source_ids: list[str],
    directory: Path,
) -> None:
    canonical_ids = directory / "candidate-osm-ids.txt"
    canonical_ids.write_text("".join(f"{source_id}\n" for source_id in source_ids))

    getid_ids = directory / "getid-ids.txt"
    getid_ids.write_text(
        "".join(
            f"{OSM_TYPE_PREFIXES[kind]}{identifier}\n"
            for kind, identifier in (source_id.split("/", 1) for source_id in source_ids)
        )
    )

    _run(
        [
            osmium,
            "getid",
            "--id-file",
            str(getid_ids),
            "--output-format",
            "opl",
            "--output",
            str(directory / "candidate-objects.opl"),
            str(pbf),
        ]
    )
    _run(
        [
            osmium,
            "tags-filter",
            "--output-format",
            "opl",
            "--output",
            str(directory / "enforcement.opl"),
            str(pbf),
            "n/highway=speed_camera",
            "r/type=enforcement",
        ]
    )
    _run(
        [
            osmium,
            "tags-filter",
            "--omit-referenced",
            "--output-format",
            "opl",
            "--output",
            str(directory / "places.opl"),
            str(pbf),
            "n/place=city,town,village,hamlet,suburb",
            "n/natural=peak",
        ]
    )


def prepare_enrichment_inputs(
    *,
    manifest_path: Path,
    pbf: Path,
    catalogue_path: Path,
    output_directory: Path,
    overwrite: bool = False,
) -> dict[str, object]:
    manifest = ReleaseManifest.load(manifest_path)
    validate_pbf(pbf, manifest)

    osmium = shutil.which("osmium")
    if osmium is None:
        raise RuntimeError(
            "osmium-tool is required; install it with `brew install osmium-tool` "
            "or the equivalent package manager"
        )

    catalogue = json.loads(catalogue_path.read_text())
    source_ids = catalogue_source_ids(catalogue)
    output_directory.mkdir(parents=True, exist_ok=True)
    existing = [
        output_directory / filename
        for filename in OUTPUT_FILENAMES
        if (output_directory / filename).exists()
    ]
    if existing and not overwrite:
        names = ", ".join(path.name for path in existing)
        raise FileExistsError(f"Refusing to replace existing enrichment inputs: {names}")

    with tempfile.TemporaryDirectory(
        prefix=".enrichment-inputs-",
        dir=output_directory,
    ) as temporary:
        temporary_path = Path(temporary)
        _write_opl_inputs(
            osmium=osmium,
            pbf=pbf,
            source_ids=source_ids,
            directory=temporary_path,
        )

        derived_names = (
            "candidate-osm-ids.txt",
            "candidate-objects.opl",
            "enforcement.opl",
            "places.opl",
        )
        for filename in derived_names:
            path = temporary_path / filename
            if not path.is_file() or path.stat().st_size == 0:
                raise RuntimeError(f"osmium produced an empty {filename}")

        version = subprocess.run(  # noqa: S603 - executable is resolved locally
            [osmium, "--version"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.splitlines()[0]
        record: dict[str, object] = {
            "schemaVersion": 1,
            "catalogueVersion": manifest.catalogue_version,
            "source": {
                "url": manifest.source_url,
                "release": manifest.source_release,
                "sizeBytes": manifest.source_size_bytes,
                "md5": manifest.source_md5,
            },
            "catalogue": {
                "path": catalogue_path.name,
                "sha256": sha256(catalogue_path),
                "featureCount": len(catalogue["features"]),
                "sourceObjectCount": len(source_ids),
            },
            "generator": {"osmium": version},
            "files": {
                filename: {
                    "sizeBytes": (temporary_path / filename).stat().st_size,
                    "sha256": sha256(temporary_path / filename),
                }
                for filename in derived_names
            },
        }
        metadata = temporary_path / "enrichment-inputs.json"
        metadata.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")

        for filename in OUTPUT_FILENAMES:
            (temporary_path / filename).replace(output_directory / filename)

    return record


def parse_args(arguments: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--pbf", required=True, type=Path)
    parser.add_argument("--catalogue", required=True, type=Path)
    parser.add_argument("--output-directory", required=True, type=Path)
    parser.add_argument(
        "--overwrite",
        action="store_true",
        help="replace only the five known generated enrichment inputs",
    )
    return parser.parse_args(arguments)


def main(arguments: Sequence[str] | None = None) -> int:
    args = parse_args(arguments)
    record = prepare_enrichment_inputs(
        manifest_path=args.manifest,
        pbf=args.pbf,
        catalogue_path=args.catalogue,
        output_directory=args.output_directory,
        overwrite=args.overwrite,
    )
    print(
        "Prepared "
        f"{record['catalogue']['sourceObjectCount']} source objects for "
        f"{record['catalogue']['featureCount']} candidates in {args.output_directory}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
