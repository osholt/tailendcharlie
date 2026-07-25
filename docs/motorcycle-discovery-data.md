# Motorcycle discovery layer data decision

Status: review-gated generator implemented for issue #64; UK-wide publication
and manual review remain pending.

## Decision

Build the discovery catalogue in a versioned offline pipeline, then publish
bounded vector data to the web and mobile clients. Do not query public Overpass
instances on every pan or copy routes from proprietary motorcycle products.

The initial sources are:

- The dated Geofabrik **United Kingdom** OpenStreetMap extract for road
  centre-lines, access restrictions, class, surface and speed attributes. This
  extract includes Great Britain and Northern Ireland.
- OpenStreetMap nodes tagged `mountain_pass=yes`, normally combined with
  `name=*` and `ele=*`, for the mountain-pass layer.
- Copernicus DEM GLO-30 for optional elevation-derived ranking once its access
  credentials and required attribution are configured. The road-only score
  must continue to work without elevation data.
- Admin-approved Tail End Charlie submissions as a separate, attributable
  source. Unreviewed submissions never enter published tiles.

OpenFreeMap remains the visual basemap. Its public service uses the unmodified
OpenMapTiles schema and permits normal interactive map use, but its terms do not
make it the ingestion API for a derived road database.

## Why client-side Overpass is rejected

Public Overpass instances are shared, best-effort infrastructure. Their current
guidance asks callers to issue queries sequentially, and individual instances
can impose their own limits. Querying one from every browser or phone would
also disclose each viewed bounding box to another provider and produce
inconsistent results under load.

Overpass is suitable for small validation queries and a bounded proof of
concept. Production refreshes should consume a dated regional extract or
Overture release in a controlled job.

## Pipeline

1. Download the exact dated UK extract pinned in
   `tools/discovery/releases/uk-2026-07-23.toml`; verify its published byte size
   and checksum before processing.
2. Keep road segments that permit motorcycles. Initially exclude motorways,
   motorway links, private/no-motor-vehicle access, ferries, steps, paths and
   unpaved tracks unless an administrator explicitly approves an exception.
3. Resample road geometry at a stable interval and calculate heading change in
   rolling windows. Suppress roundabouts, U-turns, short urban grids and tiny
   disconnected fragments.
4. Join adjacent candidates into useful sections and calculate transparent
   fields: bend score, length, road class, surface, elevation gain when
   available, source release and confidence.
5. Produce two line catalogues:
   - `twisty_highlight`: a high bend-density section that meets minimum length
     and access-quality thresholds;
   - `good_biking_road`: a broader candidate combining bends, continuity,
     surface/access confidence and low urban density.
6. Extract named `mountain_pass=yes` nodes that sit on a motorcycle-accessible
   road. Preserve the source elevation separately from any DEM-derived value.
7. Apply approved additions, corrections and removals. A removal/takedown wins
   over an imported source until an administrator clears it.
8. Validate geometry, duplicates, access, attribution and source freshness,
   then publish immutable versioned tiles plus a small manifest.

`tools/discovery/generate_catalogue.py` now implements the pinned-source check,
streaming Osmium export, road exclusions, 100 m resampling, bend-density score,
way joining, pass-to-road matching, deterministic limits, separate layer
outputs, review sampling, provenance and byte-identical web/mobile candidates.
Its output is always marked `review-required`; running it does not publish data.

## Published schema

Every public feature should include:

- stable Tail End Charlie ID;
- category;
- display name;
- point or line geometry;
- score and human-readable score components where applicable;
- road surface/access confidence;
- source name and source feature ID;
- source release date and last verified date;
- moderation status and approved revision ID when community supplied;
- optional source URL;
- `warning`, making clear that a highlight is not a safety endorsement.

## Delivery

- Use viewport-bounded vector tiles or PMTiles for line layers; never download
  the whole country when a user opens the planner.
- Cluster mountain-pass points at low zoom.
- Cache immutable versions aggressively and change the manifest when a new
  catalogue is approved.
- Keep each layer independently toggleable and default it off until the first
  dataset has been reviewed.
- The planned route must render above discovery roads, with distinct colours
  and a legend that cannot be mistaken for navigation guidance.

## Scoring guardrails

The bend metric is descriptive, not a speed or safety score. A road must not
rank higher merely because it contains roundabouts, repeated U-turns, junction
churn or a dense residential grid. Known restrictions, poor/unknown surface,
seasonal closure and low confidence reduce or suppress a candidate. Users must
be able to report a closure, danger or misclassification quickly.

The algorithm, thresholds and test fixtures are published with the data so a
score is reproducible. Changes create a new catalogue version rather than
silently altering existing features.

## Validation-only datasets

OS Open Roads may be used to sample-check Great Britain road classification and
coverage. DfT GB traffic counts and Northern Ireland DfI traffic counts may add
descriptive traffic context after their releases are separately pinned. None
of those datasets is a turn-by-turn source or a safety rating, and lower traffic
must never be presented as evidence that a road is safe, open or suitable.

## Licensing and attribution

- OpenStreetMap data is available under ODbL and requires visible attribution.
  A published derived database must follow the applicable attribution and
  share-alike requirements.
- Overture transportation is also published under ODbL and identifies its
  contributing sources per feature.
- Copernicus DEM GLO-30 permits adaptation and distribution but requires its
  prescribed source and no-liability notices. Access requires a registered
  Copernicus Data Space account from 28 July 2026.
- Tail End Charlie must preserve per-feature provenance and must not accept a
  suggestion traced from Google Maps, Calimoto, MyRouteApp or another
  proprietary map without explicit reusable rights.

## Proof-of-concept gate

Before enabling the layers by default, generate one bounded test region and
manually review at least:

- 20 high-, medium- and low-scoring road sections;
- every extracted mountain pass in the region;
- false positives caused by roundabouts, housing estates and grade-separated
  crossings;
- access, surface and seasonal-closure handling;
- tile size and map performance on a lower-end phone.

The generated `--review-sample` output selects candidates for England, Scotland,
Wales and Northern Ireland. Its coarse geographic buckets are a review aid, not
an administrative-boundary dataset; a reviewer must correct overlaps and sign
off each nation before publication.

## Primary references

- OpenStreetMap `mountain_pass` tag:
  https://wiki.openstreetmap.org/wiki/Key%3Amountain_pass
- Geofabrik United Kingdom extract:
  https://download.geofabrik.de/europe/united-kingdom.html
- OpenStreetMap licence and attribution:
  https://www.openstreetmap.org/about/license
- Osmium streaming export:
  https://docs.osmcode.org/osmium/latest/osmium-export.html
- OS Open Roads:
  https://docs.os.uk/os-downloads/products/transport-network-portfolio/os-open-roads
- DfT GB road traffic counts:
  https://www.data.gov.uk/dataset/208c0e7b-353f-4e2d-8b7a-1a7118467acc/gb-road-traffic-counts
- Northern Ireland DfI traffic counts:
  https://admin.opendatani.gov.uk/dataset/northern-ireland-traffic-count-data
- OpenStreetMap vector-tile policy:
  https://operations.osmfoundation.org/policies/vector/
- Overpass API instances and usage guidance:
  https://wiki.openstreetmap.org/wiki/Overpass_API
- Overture transportation segments:
  https://docs.overturemaps.org/schema/reference/transportation/segment/
- Overture attribution and licensing:
  https://docs.overturemaps.org/attribution/
- Copernicus DEM collection and obligations:
  https://dataspace.copernicus.eu/explore-data/data-collections/copernicus-contributing-missions/collections-description/COP-DEM
- OpenFreeMap service, schema and attribution:
  https://openfreemap.org/
