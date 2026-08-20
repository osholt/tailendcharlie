# Ride heatmaps: privacy and system design

Status: proposed for #491  
Audience: mobile, relay, website, privacy and release reviewers

## Decision

Tail End Charlie may offer two different overlays, with two deliberately
different data paths:

- **Personal rides** is calculated on the phone from the travelled tracks in
  `CompletedRideStore`. It never needs an account, relay request or consent to
  upload because it never leaves the phone.
- **Global rides** is a public aggregate of explicitly contributed coverage.
  The phone trims the beginning and end, converts the remainder into an
  unordered set of fixed Web Mercator cells and sends only those cells through
  a heatmap-specific API and credential. It never sends a GPX track, ordered
  polyline, ride code, rider name, speed, ride time or live-ride identifier.

Viewing the global layer and contributing to it are separate controls. Turning
the layer on does not opt a rider into sharing.

This feature is disabled in tester and production builds until the privacy and
terms text, migrations, revocation path and suppression tests described here
have landed.

## User controls

### Personal layer

The map layer menu offers **Personal rides**. It is on by default and the
choice is remembered. The derived cache is rebuilt when a completed ride is
saved or deleted. Deleting a completed ride removes it from the personal layer.

The layer renders travelled tracks, never planned routes. Track segments stay
separate so a GPS recording gap is not drawn as a road the rider used.

### Global viewing and contribution

The layer menu separately offers **Global rides**. It is off by default and is
safe to view without a contribution credential.

Settings offers **Contribute my completed rides** with these values:

- **Never** (default)
- **Ask after each ride**
- **Always after a ride**

The first change away from Never shows the data summary and endpoint control.
The endpoint control is **Hide at each end** with 0, 500 m, 1 km (default) and
2 km choices. The same value is removed from both ends. A recording with no
geometry left after trimming is not uploaded. Changing the value affects future
uploads; the rider can remove all earlier contributions and contribute again if
they want the new trim applied to them.

**Stop contributing and remove my data** deletes the server-side contributor
record and every monthly cell row linked to it, removes the local credential
and switches consent to Never. It does not delete the rider's local completed
rides.

The post-ride Ask action names the chosen trim before the rider confirms. A
failure is non-blocking: archiving the completed ride succeeds even when
contribution does not.

## Data flow

```mermaid
flowchart LR
    R["CompletedRide travelled segments"] --> P["Private overlay cache on phone"]
    R --> T["Trim each end on phone"]
    T --> Q["Quantise to z17 cells"]
    Q --> U["Discard order and duplicate cells"]
    U -->|"explicit consent + separate credential"| A["Heatmap contribution API"]
    A --> C[("Monthly contributor-cell rows")]
    C --> S["Daily thresholded snapshot"]
    S --> G["Global viewport API"]
    G --> M["Mobile global overlay"]
    G --> W["Web planner global overlay"]
```

The heatmap tables are not children of `rides`, and the heatmap client must not
reuse the live relay bearer, installation identifier or event journal. This
keeps global contribution outside the transport-only ride boundary described in
`docs/server-architecture.md`.

## Geometry transformation on the phone

1. Use only `CompletedRide.traveledRoute` paths whose kind is `track`.
2. Preserve gaps between paths. Never manufacture a connecting segment.
3. Walk chronological track distance from the first point and remove the
   selected start distance. Walk backwards from the last point and remove the
   selected end distance. Interpolate the two cut points within their segments.
4. If less than two points or less than one metre remains, stop without a
   request.
5. Convert every remaining segment to the Web Mercator tiles it intersects at
   canonical zoom 17. Rasterise between points so a sparse recording cannot
   skip cells.
6. Deduplicate cells and shuffle them before serialising. There is no sequence,
   segment identifier or start/end flag in the request.
7. Enforce the UK and Isle of Man service boundary and the request limits before
   crossing the transport interface.

At UK latitudes a zoom-17 cell is roughly 170–210 m across. This is not treated
as anonymisation: a set of cells still describes where somebody rode. Endpoint
trimming, storage separation, retention and the public contributor threshold
all remain necessary.

The upload includes the chosen trim distance so support can explain the local
decision, but the server cannot prove that a hostile client really trimmed.
Privacy tests therefore hold the transformation on the trusted app side; the
server rejects coordinate and polyline fields but must not claim to validate a
route it never receives.

## Contribution credential and revocation

On first opt-in the phone creates 32 random bytes in Keychain/Android Keystore
and registers a heatmap credential. The registration response returns an opaque
contributor handle. The database stores only keyed hashes of the handle and
secret. Neither value is shared with the ride relay protocol.

Every upload has a random 128-bit upload identifier. A keyed hash of that
identifier is retained for 30 days to make retries idempotent, without retaining
a per-ride geometry record. Cell rows are merged into the contributor's current
calendar-month bucket. Consequently the database can answer “which cells this
opaque contributor covered this month”, but cannot reconstruct individual rides,
their order, date or direction.

Revocation authenticates with the heatmap secret and deletes, in one transaction:

- the contributor credential;
- all contributor/month/cell rows;
- outstanding upload receipts.

The next public snapshot excludes those rows. The API returns the snapshot date
so the UI can say when removal has propagated. A lost phone with no restored
secure credential cannot authenticate a deletion; the consent copy must state
this limitation and direct the rider to the privacy contact for an exceptional
operator-assisted deletion where they can provide the opaque handle.

## Storage model

Names are illustrative; #493 owns the migration.

### `heatmap_contributors`

| Column | Purpose |
| --- | --- |
| `handle_hash` | Random, heatmap-only primary identity; never returned by the public API |
| `secret_hash` | Authenticates upload and deletion |
| `consent_version` | Proves which in-app explanation was accepted |
| `created_on`, `last_seen_on` | UTC dates, not ride timestamps |

### `heatmap_contributor_cells`

Primary key: `(handle_hash, receipt_month, z, x, y)`.

| Column | Purpose |
| --- | --- |
| `receipt_month` | Calendar month of server receipt, coarse enough for retention |
| `z`, `x`, `y` | Canonical z17 Web Mercator cell |
| `visit_count` | Number of uploads that included the cell, capped at 20 per month |

Rows expire after 24 complete calendar months. Expiry is based on receipt month,
because ride time is not uploaded. Cleanup also deletes orphan contributors
with no cells or receipts for 90 days.

### `heatmap_upload_receipts`

Primary key: `(handle_hash, upload_id_hash)`. It carries only `received_on` and
expires after 30 days.

### `heatmap_public_cells`

A replace-only snapshot contains cells at zooms 8–17, a coarse intensity bucket,
the contributor-count bucket and one snapshot version/date. It contains no
contributor key or exact count. Rebuilding into a new version and atomically
switching the active version prevents a client observing cells change one
submission at a time.

## Public aggregation rule

A cell is eligible only when at least **three distinct opaque contributors**
covered it during the retained 24 months. Repeated rides by one contributor
increase intensity but never satisfy the three-contributor rule.

For each parent cell at each served zoom, aggregate all canonical cells below
it, then reapply the distinct-contributor threshold at that parent resolution.
Publish only buckets:

- contributor count: `3–4`, `5–9`, `10+`;
- visit intensity: `low`, `medium`, `high`, `very_high`.

There are no public time filters, contributor filters or exact counts. At most
one snapshot is published per UTC day. Cache headers may serve a snapshot for a
day and stale-while-revalidate it; a `snapshotVersion` in every response lets
the clients replace rather than combine snapshots.

Three is a disclosure-reduction threshold, not proof of three human beings.
This account-free product has no robust Sybil defence. Registration, IP and
credential rate limits, per-contributor upload quotas and future platform
attestation make abuse more expensive, but neither the UI nor privacy copy may
describe the aggregate as anonymous or verified.

## API contract

All JSON contracts carry `schemaVersion: 1`. Unknown fields are rejected on
contribution endpoints so a buggy client cannot quietly upload a raw track.

### Register

`POST /api/v1/heatmap/contributors`

Request: client public handle, proof derived from its secret, consent version.
Response: opaque handle and server nonce. Registration is rate-limited by IP
and handle hash. Request bodies and credentials must not appear in application
or edge logs.

### Contribute

`POST /api/v1/heatmap/contributions`

Authenticated with the heatmap credential. Body:

```json
{
  "schemaVersion": 1,
  "uploadId": "random opaque value",
  "trimMetersAtEachEnd": 1000,
  "cells": [
    {"z": 17, "x": 65492, "y": 43561}
  ]
}
```

Rules: z must equal 17; cells must be unique, inside the supported boundary and
no more than 20,000 per upload; payload at most 256 KiB; no coordinates,
timestamps, order, route/ride IDs or free text; no more than 20 successful
uploads per contributor per day. Replaying an upload ID is a successful no-op.

### Revoke

`DELETE /api/v1/heatmap/contributors/current`

Authenticated with the heatmap credential. A successful response identifies
the last public snapshot that may still contain the contribution and the date
by which the next snapshot is due.

### View

`GET /api/v1/heatmap/cells?west=…&south=…&east=…&north=…&zoom=…`

No credential. Bounds are limited to the supported region and a maximum area;
zoom is 6–18. The service chooses an aggregate cell resolution (up to z17) and
returns at most 5,000 GeoJSON point features with bucket properties plus the
snapshot version/date. Oversized requests receive 400 rather than silently
returning a misleading partial heatmap.

The first release uses bounded GeoJSON because the relay has plain PostgreSQL,
not PostGIS, and both clients already consume MapLibre GeoJSON sources. If load
requires vector tiles later, the public contract can add a tile URL without
changing the contribution/storage boundary.

## Rendering

### Mobile personal overlay

Build a derived, versioned cache from local travelled paths. Simplify in screen
space and cap work per viewport rather than keeping every archived GPS point in
a widget tree. Render a low-opacity violet-to-orange line/heat layer below the
active route, rider trails, manoeuvres, hazard symbols and current-location
marker. The cache key includes completed-ride IDs and their archive schema
versions, so save/delete invalidates it deterministically.

### Mobile and website global overlay

Debounce pan/zoom requests, cancel superseded requests and keep the last valid
snapshot visible with an “Offline — saved coverage” status. Do not merge
different snapshot versions. The public features drive a MapLibre heatmap
layer below planned/active routes and edit handles. The layer has no gesture
handlers, so route reshaping keeps precedence.

The website reads only the public View endpoint. It never receives the phone's
archive, heatmap credential, consent mode or endpoint-trim preference.

## Threat model

| Threat | Control | Residual risk |
| --- | --- | --- |
| Home/work inferred from endpoints | On-device trimming, 1 km default, no start/end markers | A habitual route or very short commute can still imply an area |
| One rider exposes a sparse rural road | Three-distinct-contributor threshold at every published resolution | Three riders may share a household or destination |
| One frequent rider unlocks a road | Distinct contributors, not visit count, gate publication | Multiple forged credentials can bypass an account-free threshold |
| Server reconstructs individual rides | Unordered cells merged by contributor/month; no per-ride geometry or ride time | Monthly coverage still describes an opaque person's movements |
| Public differencing reveals a new rider | Daily atomic snapshots, count buckets, no time filters | Long-term snapshot comparison can still reveal bucket transitions |
| Scraping reconstructs all public coverage | Bounds/area limits, request rate limit, daily cache, bucket-only data | Public heatmap data is intentionally observable and can be mosaicked |
| Malicious cells pollute the map | UK/IoM bounds, payload/quota limits, keyed credential, moderation kill switch | No account means determined Sybil pollution remains possible |
| Live ride links to heatmap contribution | Separate endpoint, identifier and credential; contribute only after archive | Network operators still observe source IP and timing |
| Raw track leaks through schema drift | Strict request model rejects unknown/raw fields; transport-boundary tests | A hostile non-app client can still submit a fabricated cell set |
| Deleted local ride stays global | Explicit remove-all action and clear consent copy | Per-ride removal is unavailable because rides are deliberately not identified |

## Logging, metrics and operations

- Do not log contribution bodies, cell lists, credentials, handles or viewport
  coordinates. Use outcome, status class, cell-count bucket and latency only.
- IP addresses may be used in the existing in-process limiter but are not added
  to heatmap tables. Production edge-log retention must be reviewed before the
  feature flag is enabled.
- Metrics expose accepted/rejected upload counts, public response size buckets,
  snapshot age/build duration, rows expired and revocation outcomes. They have
  no geographic or contributor labels.
- A server feature flag independently disables registration/contribution while
  leaving public viewing available. A second kill switch hides the public
  snapshot if pollution or a privacy defect is found.
- Migration rollback disables writes first, then preserves tables until the
  privacy retention/deletion obligation is discharged; rollback is not an
  excuse to strand contributed data.

## Verification gates

### Mobile

- Unit tests for trimming through multiple track segments, interpolation,
  loops, gaps, short recordings and every trim option.
- A transport-spy test proves cells cross the interface only after trimming,
  quantisation, deduplication and shuffling, and proves forbidden metadata does
  not.
- Consent defaults to Never; viewing never changes it; contribution failures do
  not block local archiving.
- Personal layer tests prove no network client is invoked and deleting a ride
  invalidates the overlay cache.
- Rendering benchmark uses the documented large-archive fixture and verifies
  safety layers remain above both heatmaps.

### Relay

- Migration upgrade/downgrade smoke tests.
- Strict-schema, authentication, idempotency, bounds, payload and quota tests.
- Three-contributor suppression at canonical and parent resolutions; repeated
  rides by one contributor stay suppressed.
- Revocation cascades all private rows and removes them from the next snapshot.
- Snapshot atomicity, bucket boundaries, 24-month expiry and no sensitive log
  fields.

### Website

- Keyboard-operable layer toggle and status text.
- Debounced bounded requests on pan/zoom, snapshot replacement, failure/offline
  behaviour and CSP coverage.
- Planned route and reshape handles remain above the heatmap and retain all
  pointer gestures.
- A network assertion proves no private mobile/archive endpoint exists in the
  planner bundle.

### Release/privacy

- Privacy Policy and Terms state purpose, consent, precise fields not collected,
  monthly linkage, 24-month retention, threshold limitations, revocation and
  contact route.
- Data-protection review accepts the remaining monthly opaque coverage and lost
  credential limitation.
- A tester confirms consent, trim wording, remove-all and sparse-cell status on
  both platforms. This evidence is required before implementation tickets are
  closed.

## Implementation issues

- #492 — private on-device mobile heatmap
- #493 — contribution, storage, suppression, revocation and public aggregate API
- #494 — mobile global overlay and contribution UX
- #495 — web planner global overlay
