# Next-agent handoff

Updated: 2026-07-26

## Current branch

Active work is on `claude/waze-integration-speed-display-15b184`, draft
[PR #116](https://github.com/osholt/tailendcharlie/pull/116): the map speed
readout and the enforcement warnings described below. `origin/main` moved
forward seven merges (#109, #113, #115, #118, #119, #120, #121) while that
branch was open and has been merged into it; #115's bottom-anchored chrome
rework overlapped the same map overlays, so re-read that resolution before
touching the overlay layout again. Do not split or overwrite the user's
unrelated local Xcode signing edit or the untracked
`docs/carplay-entitlement-submission/` material.

## Issue status

The issue list moved with those merges and is not re-audited here: check
labels directly rather than trusting a snapshot. What holds is the shape from
2026-07-25 — every issue that reached `status: ready for validation` is
implemented and waiting on physical, deployment or commercial evidence rather
than more code, with the credential and third-party gates being #38 (real
APNs/FCM credentials) and #39 (written TomTom navigation permission).
#117 tracks the flaky `ride_map_feature_test.dart` teardown seen in loaded
concurrent runs; `flutter test -j 1` is clean.

## This branch

- **Waze is closed.** A Waze for Cities relay reader was built on this branch
  and then removed: the programme is limited to government agencies and road
  operators, and this project applied and is not eligible. TomTom is again the
  only traffic provider, and the multi-source scaffolding went with the reader
  rather than being left dormant for a source that cannot arrive. Waze deep
  links for destination handoff are unaffected. Do not re-open this without new
  eligibility news.
- Enforcement warnings are now a wanted feature, reversing the exclusion in
  `docs/crowd-hazard-feed-decision.md` point 2. Police and camera alerts are
  carried at any confidence and raise a full-screen warning a mile ahead; they
  never trigger a route recalculation. See `docs/situational-awareness.md`.
  Rider reports are the only source of them: no enforcement provider is
  configured and none is eligible. The detector is source-agnostic, so a
  licensed feed would need no new UI.
- Riders can report enforcement themselves, from a `REPORT` control above the
  speed sign on the ride map and from the existing hazard sheet. Rider-raised
  enforcement expires faster than a road defect (two hours for a camera, one
  for police) because a van or patrol car moves on.
- The mapped speed-limit sign lost its surrounding panel and gained the
  rider's live GPS speed directly beneath it at the sign's own font size, in
  mph to match the sign. See `docs/maps-and-gpx.md`.

## Narrow verification

```bash
cd apps/mobile
flutter analyze
flutter test
flutter build apk --debug
```

```bash
cd apps/server
uv run ruff format --check .
uv run ruff check .
uv run python -m pytest
```

Use `uv run python -m pytest` if the direct `uv run pytest` entry point has a
stale virtual-environment shebang.

## Parked, not forgotten

Two free data sources were assessed on 2026-07-26 and parked on the P2 roadmap
in `PLAN.md` as candidates for a later paid tier, with the detail in
`docs/uk-enforcement-data-decision.md`:

- an OpenStreetMap fixed-camera layer through the existing `tools/discovery`
  generator (3,422 camera nodes, 597 enforcement relations, GB, ODbL, offline);
- roadworks from DfT Street Manager, the only free feed reaching local roads.

Neither is started. The in-app warning surface they would feed already exists.

## Remaining evidence

- TomTom's written "Navigation Functionality" permission remains the only route
  to broad all-road live incidents, and is unchanged by the Waze outcome.
- Ride past a known camera site and confirm the warning arms about a mile out,
  counts down, clears once passed, and does not fire for the opposite
  carriageway.
- Report a sighting wearing winter gloves, moving, on the largest supported
  text size, and confirm the two-tap flow is reachable without stopping and
  that a following rider receives the warning.
- Read the rider speed readout on a moving motorcycle against a known
  speedometer, in daylight and at night, over both the day and night basemaps.
- Exercise explicit leave/rejoin and roster/alert counts across mixed physical
  iOS and Android phones.
- Publish, replace and clear leader routes across late join, offline reconnect,
  restart and lead handover on both platforms.
- Deploy the compatibility endpoint and test old-client/current-server plus
  current-client/old-server rollout combinations.
- Run onboarding with at least one person who has not used the app and record
  accessibility observations at supported text sizes and with a screen reader.
- The full Nearby, background, battery, route-alert and vehicle-interface gates
  in `PLAN.md` and `docs/field-test-plan.md` remain authoritative.
