# UK motorcycle discovery generator

This review-gated offline pipeline implements the reproducible source and
candidate-generation part of issue #64. It reads a pinned United Kingdom
Geofabrik OpenStreetMap extract, so Great Britain and Northern Ireland are both
covered without a live dependency on public Overpass servers.

## Requirements

- Python 3.12 or newer (standard library only);
- `osmium-tool` 1.16 or newer (`brew install osmium-tool` on macOS); and
- enough local storage for the 2.1 GB source plus temporary filtered data.

Download the exact URL in
`releases/uk-2026-07-23.toml`. The generator rejects a different byte size or
the wrong published checksum before processing it.

```bash
python3 tools/discovery/generate_catalogue.py \
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

1. review the deterministic, non-overlapping nation-core sample from England,
   Scotland, Wales and Northern Ireland; border areas are deliberately excluded
   because the generator does not treat coarse bounds as administrative truth;
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
python3 -m unittest discover -s tools/discovery/tests -v
```

The fixture covers deterministic scoring, joining OSM ways, source provenance,
duplicate/schema gates, exclusion rules, pass-to-road matching, separate layer
outputs, byte-for-byte web/mobile parity, and source pin rejection.
