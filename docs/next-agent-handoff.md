# Next-agent handoff

Updated: 2026-07-25

## Current branch

Active work is on `claude/waze-integration-speed-display-15b184`: the Waze for
Cities traffic reader and the map speed readout described below. Everything
else described in the previous handoff (draft PR #43 and the UI/navigation,
simulator, iOS crash, rider-count and screen-awake fixes) is merged; `main` at
`2d3d8e5` is the frontier and no `codex/*` or `feature/*` branch holds
unmerged content. Do not split or overwrite the user's unrelated local Xcode
signing edit or the untracked `docs/carplay-entitlement-submission/` material.

## Issue status

Every open issue is implemented and merged. None is blocked on more code; each
is at `status: ready for validation` waiting on physical, deployment or
commercial evidence:

- Field/physical-device evidence: #27, #28, #29, #30, #31, #33, #35, #42, #50,
  #51, #86 (mixed iOS/Android runs), #6 and #7 (Android Auto DHU / physical
  CarPlay and a physical Android PiP run), #5 (Harley-Davidson GPX handoff on
  the real app/device).
- Deployment/rollout evidence: #37 — both relay endpoints are live and
  advertise protocol 1; the old-client/current-server and
  current-client/old-server matrix plus store update links remain.
- Credentials and third-party terms: #38 (real APNs/FCM credentials),
  #39 (written TomTom navigation permission, and now also the Waze for Cities
  partner agreement before any feed URL is configured).
- Content approval: #64 — the generator has landed; the 48-item four-nation
  content/safety review has not.

## This branch

- Waze for Cities is a second relay-side incident source, preferred over
  TomTom for incidents when its feed URL is configured, with TomTom as the
  fallback. Waze publishes no routing API, so alternatives stay on TomTom and
  the reroute endpoint reports itself unconfigured when only Waze is present.
  See `docs/live-traffic-incidents.md`. No feed URL is configured; nothing is
  claimed as available.
- Enforcement warnings are now a wanted feature, reversing the exclusion in
  `docs/crowd-hazard-feed-decision.md` point 2. Police and camera alerts are
  carried at any confidence and raise a full-screen warning a mile ahead; they
  never trigger a route recalculation. See `docs/situational-awareness.md`.
  The detector is provider-neutral, so the Cyclops fixed-camera database in
  `docs/uk-enforcement-data-decision.md` needs only its feed, not new UI.
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

## Remaining evidence

- Record the Waze for Cities partner agreement terms (display, caching,
  redistribution, attribution) before configuring a feed URL, then capture a
  staged closure test and a provider-failure test against the real feed.
  Confirm specifically whether the agreement permits redistributing `POLICE`
  and camera alerts, since that is the part most likely to be restricted.
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
