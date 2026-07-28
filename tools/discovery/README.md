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

## Enrichment and publication

The generator produces geometry and a score. It does not produce anything a rider
can act on, so a second stage adds that. The two stages are deliberately separate,
and the split is the important part:

**Derived facts** — speed limit, average speed checks, fixed cameras, road class,
nearest settlement. These come from the checksummed extract, so `enrich_deterministic.py`
owns them and they are refreshed on every run.

**Researched content** — a good name, evidence that riders use the road, busy
periods, the rider description. These cannot be re-derived from the extract. They
live in `editorial-overlay.json` and are merged at publication time. Putting them in
the generated file would mean the next regeneration silently destroyed them.

Overlay entries are keyed by candidate id *and* carry `sourceFeatureId`, because
candidate ids are content hashes: a new extract can change them, and the source id is
what lets an orphaned entry be re-matched rather than lost. `publish_catalogue.py`
looks up the candidate id first and falls back to `sourceFeatureId`; without that
fallback a regeneration would silently revert every researched pass to a generated
`pending` note, which is the failure the overlay exists to prevent. A source id shared
by two entries is a real ambiguity, so neither is offered for re-matching — attaching
the wrong prose to a pass is worse than falling back to a generated note. A candidate
with no overlay entry is `pending`, never a crash, so a fresh extract that introduces
a new pass cannot break publication. `properties.editorialOverlay` reports how many
entries were re-matched on each run.

A pass candidate's `sourceFeatureId` is the summit *node*, which carries no speed
limit of its own, so passes used to report `unknown` across the board.
`enrich_deterministic.py` now resolves a summit node to the catalogue ways it is a
vertex of — an exact id join, not a distance threshold, so it cannot pick up a car
park lane next door. Where the crossing way is not itself a catalogue candidate the
limit stays `unknown` rather than being guessed by proximity, and the note says which
of those two situations applies.

```bash
export DISCOVERY_WORK_DIR=/path/to/working/dir
export PYTHONPATH=tools/discovery   # these stages import each other by module name
python3.12 tools/discovery/enrich_deterministic.py   # derived facts, all candidates
python3.12 tools/discovery/build_overlay.py          # researched content
python3.12 tools/discovery/publish_catalogue.py      # merge, tier, write both copies
python3.12 tools/discovery/build_pass_sheet.py       # review sheet, with basemap tiles
```

Optionally fetch rider ratings first (see below). `publish_catalogue.py` reads
`$DISCOVERY_WORK_DIR/road-ratings.json` when it exists and ignores its absence, so
a run without an export behaves exactly as before:

```bash
curl -sS -H "Authorization: Bearer $RIDE_RELAY_DISCOVERY_ADMIN_TOKEN" \
  https://<relay>/api/v1/admin/discovery/road-ratings \
  > "$DISCOVERY_WORK_DIR/road-ratings.json"
```

### Rider ratings (#159)

The third source of truth, after the extract and the directories: riders who have
actually ridden the road. The app asks about at most three catalogued roads at the
end of a ride, one binary tap each, and the relay holds the answers as anonymous
tallies. `road_ratings.py` turns that export into a decision.

| Outcome | Condition | Effect on publication |
| --- | --- | --- |
| `promote` | >= 5 answers, >= 70% worth including | `researchStatus` -> `researched`; `tail-end-charlie-riders` added to `evidenceSources`; counted as `rider-verified` |
| `review-for-removal` | >= 5 answers, >= 60% not worth including | Written to `$DISCOVERY_WORK_DIR/rider-removal-review.json` and counted as `rider-flagged-for-removal`. **Nothing is removed.** |
| `insufficient` | fewer than 5 answers, or no clear majority | Nothing |

Five is the floor because the ratings are deliberately unauthenticated — the
relay stores no submitter identity, so the signal cannot be deduplicated per
person and is not sybil-resistant. A threshold one determined person could reach
alone would be worthless.

Promotion is automatic because adding a road several riders vouch for is a
cheap mistake to make. **Removal never is.** One rider's dislike must not remove
a road and neither may twenty: a negative verdict produces a flag for a human,
and a road leaves the catalogue only through an `editorial-overlay.json` verdict.

The thresholds are defined in `ROAD_RATING_*` in
`apps/server/src/ride_relay_server/discovery.py` and mirrored in
`road_ratings.py`; `tests/test_road_ratings.py` fails if the two disagree, and
`road_ratings.index` refuses an export the relay aggregated under a different
rule rather than applying this one to those numbers. Ratings are matched on
`sourceFeatureId` before candidate `id`, for the same reason overlay entries are,
and only ever against the catalogue release they were given on.

`build_overlay.py` and `enrich_deterministic.py` both read the generated catalogue, so
run them after `generate_catalogue.py` and before publication. The review sheet reports
`N researched, N pending, N rejected on classification and not published` — the last
number counts recorded decisions in `classificationRejections`, not cards on the sheet,
because rejected nodes are no longer catalogue features.

### Honesty rules

These are not style preferences. Each one exists because the opposite behaviour
would mislead a rider planning a route.

- **Speed limits carry provenance.** `tagged` means OpenStreetMap records it,
  `inferred-from-maxspeed-type` means a national-limit tag implies it, `unknown`
  means nobody has mapped it. 919 of 2,085 published candidates are `unknown`. Never
  guess a limit from road class — #145 was caused by trusting a value that never held
  what the code expected.
- **Absent enforcement data is not absence of enforcement.** Only one candidate
  matches an OSM `enforcement=average_speed` relation, yet the A57 Snake Pass has
  published average speed camera proposals that OSM does not record. Every
  enforcement field therefore carries a provenance *and* a note saying what was
  inspected: `averageSpeedCheck.present: false` reads "no relation covers this
  candidate; coverage is incomplete", and `fixedSpeedCameras.count: 0` reads "none
  mapped within 250 m", not "no cameras". Tullybaccart is the worked example —
  Police Scotland lists the A923 as a mobile camera route, and OSM records nothing.
- **An unknown limit says what was inspected.** A road candidate's own ways were
  read, so "OpenStreetMap does not record a limit on this candidate's ways" is true
  of them. A pass candidate is a *node*; if no way could be resolved, nothing was
  inspected, and the note says so rather than claiming OSM holds no limit for a road
  nobody looked at.
- **Busy periods are never silently absent.** `busyPeriods` always carries a
  provenance of `researched` or `not-researched`. An omitted field would be read as
  "not busy", which is a claim nobody made.
- **Descriptions are composed from verified facts, never invented.** A `pending`
  entry's note states road number, locality, length, bend density and speed limit —
  all from the extract. Subjective claims about how a road rides appear only on
  `researched` entries, attributed to the source that made them.
- **A ref match is evidence about the road number, not the section.** The A5 runs
  from London to Holyhead and only part of it is celebrated. Researched entries quote
  the route the directory names so a planner can judge whether their section is it.
- **Editorial claims are graded, not merely cited.** Each researched pass carries
  `sourceVerification`: `fetched` means the cited page was retrieved and the claim
  read off it; `listing-only` means the URL resolves and the claim is limited to what
  the listing establishes — that a directory lists the road, not what its reviewers
  said. `motorcycleEvidence: none-found` is a recorded outcome of searching, not a
  placeholder to fill in later.

### Tiering

| Tier | Meaning | Count |
| --- | --- | --- |
| `researched` | corroborated by a motorcycle-road directory or hand-researched | 182 |
| `pending` | carries a name or road number, not yet corroborated | 1,903 |
| discarded | anonymous, unclassified, short or straight, no corroboration | 156 |

**The generator requires a name on a `mountain_pass=yes` node.** All eight unnamed
nodes in the UK extract were ordinary local hill saddles — the lowest 100 m, on a
dead-end lane on Skye; another on the Isle of Wight — and all 37 named nodes were
real passes. An elevation threshold does not work: it would drop Tullybaccart (213 m)
and Scarth Nick (232 m). `properties.rejectedUnnamedPasses` reports the count and the
rejected source ids on every run, and `classificationRejections` in the overlay keeps
the per-node verdict and its OSM source URLs as an audit trail.

Four of those eight used to be reclassified into `good_biking_road`. They are not any
more, because they were pass *nodes*: Point geometry in a line layer. The web planner
partitions its map sources by geometry type, so every Point lands in the
mountain-pass source and is drawn in the mountain-pass colour — reclassifying put
four ordinary roads on the map as mountain passes. Three of the four roads (A4113,
A859, B9120) are already road-layer candidates on their own way geometry, which is
the right way for them to appear; the A928 is not, which is a road-layer scoring
question rather than a reason to publish it as a pass.

The score cannot drive any of this. The generator creams off the top 1,100 per
category, so published scores run 81-100 with 1,376 candidates tied at 100 —
saturated. `scoreComponents` carries the usable signal.
