# France follow-up validation — build 99

Release umbrella: [#802](https://github.com/osholt/tailendcharlie/issues/802).
The issue PRs are combined before protected-main checks and tester distribution.
Automated evidence below is distinct from physical ride validation.

| Issue | Implemented behaviour | Regression / mutation evidence | Remaining field check |
| --- | --- | --- | --- |
| #780 | Full-history adaptive heatmap and viewport detail | Old-area coverage and viewport omission mutations fail | England and France on the reporter's complete library |
| #776 | White major roads, brighter minor roads and labels; theme reload | Dim-road and cached-theme mutations fail | Mounted phone in sunlight and through a visor |
| #777 | Round neutral bike; pointed moving marker retained | Square neutral marker mutation fails | Stationary/moving riders on rotating maps |
| #775 | ETA/progress sizes follow Small/Medium/Large | Disabled scaling fails; narrow layout with system text 1.6 | Moving portrait/landscape readability |
| #801 | Preview endpoints use native map sources | Native marker omission fails | Pan/zoom on both platforms |
| #793 | Useful POIs at explicit zooms in native and Flutter maps | Missing POI layer and raw-style bypass fail | Actual density, collision behaviour, online/offline |
| #794 | Day/night route corridors, two-kilometre buffer, complete status, retry | Missing buffer, partial readiness, ignored preference and bypassed iOS renderer cache fail; real Flutter style/providers reopen with all networking disabled | Entire route in airplane mode, riding zoom, deviations and interrupted downloads |
| #795 | Imported/Rides/Bin, rename/bin/restore | Bin persistence, reimport restore and merged-tab regressions fail | Existing large real libraries |
| #798 | Tags, hierarchical folders, colour, filters; private sharing metadata | Persistence, replay preservation, privacy and colour mutations fail | Organisation across restart and backup restore |
| #796 | Durable original GPX snapshot and initial plan; manual legacy links | Lost source snapshot, duration and reroute-overwritten initial plan fail | New recorded journey and original-vs-actual comparison |
| #797 | Break-aware conservative personal ETA and optional coarse population model | Break suppression, minimum samples, opt-in default and cohort threshold fail | Several qualifying rides; opt-out during real signal loss |
| #799 | Non-destructive corrected copy, trim, tidy, routed section replacement | Reused identity, retained timestamps and invented replacement geometry fail | Map selection and saved copy on a device |
| #800 | Rendered thumbnail cache after successful tile readiness | Premature readiness, missing colour key and cache bypass fail | Revisit thumbnails offline; never preserve blank tiles |
| #306 | Direct ride actions; one Settings page with section shortcuts | Reintroduced nested menu and dismiss-before-profile fail | Reachability with gloves and large system text |

## Verification scope

Each issue received focused unit/widget tests and applicable analysis. The
combined local suite passes 2,248 mobile tests (24 existing skips), 163 server
tests and 92 website tests. Flutter analysis and server lint/format checks pass.
Migration 0012 upgrades, downgrades and upgrades again on a disposable database,
and Alembic reports no missing model migration. The full PostgreSQL migration,
native iOS, Android and container checks run on the protected release PR.
Build results and release run links are recorded on #802.
The iOS live map uses Flutter to avoid the prior native-renderer crash. Its downloader and live renderer now share a persistent resource cache; a fresh cache instance reloads styles, TileJSON, PBFs and sprites without any network calls. Native Android uses MapLibre regions. The new server schema is additive. Migration 0012 creates only the coarse ETA
profile table; profile deletion and 90-day expiry have server tests.

The specialist review command returned successfully but supplied no substantive
findings or completed review; it is not counted as independent review evidence.
The primary implementer reviewed the combined data flow and release diff.

## Evidence limits

- No full France GPX, exact coordinates, raw crash report or user screenshot is
  committed. [ETA analysis](eta-calibration.md) states why reconstructed timings
  are not the original displayed estimates and cannot calibrate the rider.
- Native/offline/visual tests do not establish physical navigation behaviour.
  Keep tickets requiring field evidence at `status: ready for validation`.
- #732 alone has explicit reporter confirmation that backgrounding no longer
  crashes. The earlier speed-limit source gaps and roundabout exit-count
  uncertainty remain documented in the build 98 validation report.
- Uploaded builds, internal availability, external beta review and field
  validation are distinct states. Record the actual state on #802.
