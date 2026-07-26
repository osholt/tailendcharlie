# UK motorcycle discovery generator

This review-gated offline pipeline implements the reproducible source and
candidate-generation part of issue #64. It reads a pinned United Kingdom
Geofabrik OpenStreetMap extract, so Great Britain and Northern Ireland are both
covered without a live dependency on public Overpass servers.

## Requirements

- Python 3.11 or newer (standard library only), because the release manifest is
  read with `tomllib`. The script checks this before importing anything and
  exits with the required version rather than a bare `ModuleNotFoundError`;
  macOS system and pyenv default interpreters are often older, so name the
  interpreter explicitly (`python3.12 tools/discovery/...`);
- `osmium-tool` 1.16 or newer (`brew install osmium-tool` on macOS); and
- enough local storage for the 2.1 GB source plus temporary filtered data.

Download the exact URL in
`releases/uk-2026-07-23.toml`. The generator rejects a different byte size or
the wrong published checksum before processing it.

```bash
python3.12 tools/discovery/generate_catalogue.py \
  --manifest tools/discovery/releases/uk-2026-07-23.toml \
  --pbf /data/united-kingdom-260723.osm.pbf \
  --output /tmp/discovery-catalogue.geojson \
  --layer-directory /tmp/discovery-layers \
  --review-sample /tmp/discovery-manual-review.geojson \
  --max-twisty 1100 \
  --max-good-roads 1100 \
  --max-passes 350
```

These bounded release caps keep the combined review artefact below the 12 MiB
publication gate. A source release that exceeds the gate must be reviewed and
retuned explicitly; it must not silently emit an oversized catalogue.

The output remains `review-required`; running the script never publishes or
silently replaces the app catalogue. Before publication:

1. review the deterministic sample, which is stratified by **category as well as
   nation** so that every layer is certified by candidates from that layer: 12
   per nation core for `good_biking_road` and `twisty_highlight`, and every
   `mountain_pass` in the catalogue, reviewed exhaustively because there are few
   of them and seasonal closure is almost exclusively a pass concern. Nation
   cores are non-overlapping and border areas are deliberately excluded from the
   quota categories, because the generator does not treat coarse bounds as
   administrative truth; a pass in a border area is kept under an explicit
   `unassigned-border-area` label rather than dropped. Where a nation core holds
   fewer candidates than the quota, the sample takes what exists and records the
   shortfall in `properties.sampling.shortfalls` and on stdout instead of padding
   from another nation;
2. inspect access, surface, seasonal closure, junction churn and false-positive
   handling;
3. compare road-class coverage against OS Open Roads and traffic metadata only
   as descriptive validation, never as routing or safety evidence;
4. approve a bounded delivery format. The current app and website GeoJSON
   copies must remain byte-identical, but a UK-wide web release should move the
   line layers to immutable viewport-bounded tiles before it is enabled.

The algorithm resamples line geometry every 100 m before calculating useful
heading change per kilometre. It excludes motorways, trunk roads, roundabouts,
four-or-more-lane roads, low-speed urban segments, access restrictions and
mapped unsuitable surfaces. Unknown surfaces remain medium-confidence review
candidates rather than being described as safe.

## Tests

```bash
python3.12 -m unittest discover -s tools/discovery/tests -v
```

The fixture covers deterministic scoring, joining OSM ways, source provenance,
duplicate/schema gates, exclusion rules, pass-to-road matching, separate layer
outputs, byte-for-byte web/mobile parity, source pin rejection, category and
nation stratification of the review sample, quota shortfall reporting, and the
interpreter version guard.
