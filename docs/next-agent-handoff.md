# Next-agent handoff

Updated: 2026-07-26

## Current branch

Active work is on `claude/issue-124-routeless-chrome`: #124 (a ride with no route
kept losing SOS and Leave), #125 (declutter the ride-map chrome) and #126 (the
mapped speed limit on by default, resolved from a stationary fix). All three land
together because all three edit
`apps/mobile/lib/features/map/ride_map_feature.dart` and splitting them would
only manufacture conflicts. Do not split or overwrite the user's unrelated local
Xcode signing edit or the untracked `docs/carplay-entitlement-submission/`
material.

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

- **A ride with no GPX is a first-class mode.** `ride_map_feature.dart` gated
  the emergency alert and the leave action behind `_route != null`, so a group
  riding without a route had neither. Every safety, ride-lifecycle, camera and
  presence surface is now independent of route presence; only genuinely
  route-derived surfaces hide. Every remaining `_route` test in that file is
  justified in a comment, and the doc comment on the `_route` field lists them —
  read it before adding another, or the route-less ride quietly loses another
  control. `ride_map_feature_test.dart` asserts SOS and Leave with `route == null`
  and that the follow camera and re-centre work from position and heading alone.
- **The chrome is one action row.** The ride menu moved to the top leading
  corner — the single exception to #104, and the only thing allowed in the upper
  band. SOS, LEAVE and REPORT share a row; the speed sign sits below it hard
  right in portrait and in the right-hand rail in landscape; "Follow me" appears
  only once the rider has taken the camera over; and the caption under the speed
  readout is gone from the visual layer and preserved in the accessibility label.
  The portrait band the #105 camera measures is now findable from a test via
  `portraitBottomChromeKey`. See `docs/maps-and-gpx.md` for the measured
  before/after and what still clamps.
- **The mapped speed limit ships on and resolves where the rider stands.**
  `waitingForMovement` is retired as the entry state; ambiguity is stated as
  `unconfirmedRoad` and retried, rather than withheld. A stationary lookup is a
  single-point trace held to a tighter accuracy and match bound because it has no
  heading to corroborate it; heading disambiguation returns as soon as the bike
  moves. A rider who previously turned the feature off stays off.
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

## Branch `claude/issue-128-relayed-capabilities`

Two capabilities, grouped because they are the same shape of change — a new
relayed event type plus capability gating. Refs #128, #108, #102. Everything is
additive: three appended `RideEventType` values, two new capability strings, two
new reducers, no restructuring of anything already there. Written to merge
cleanly after #132/#134 rework the transport.

- **A leader can ask a named rider to be Tail End Charlie.** A request the target
  accepts, not a silent assignment. `TecRoleAssignmentReducer` admits a request
  only from a device whose signed role at that point in the journal is `lead`
  and whose payload names its own author, and an answer only from the rider the
  request named — the #99 forged-departure pattern. Accepting records the answer
  **and** the target's own `roleChanged`, so roles stay self-selected and the
  membership reducer is untouched. See `docs/situational-awareness.md` for the
  conflict rules (supersede, 10-minute expiry, target-left, leader handover, and
  the two-riders-hold-the-role tie-break in `resolveTecTarget`).
- **A separated rider's rejoin route reaches the leader, and only the leader.**
  `rejoinRouteShared` is addressed to the leader the same way an ICE share is;
  every consumer drops a share it is not addressed to, and the reducer fails
  closed on a share with no recipient list. **Relayed at most once per rider per
  120 s**, deliberately independent of #102's 45 s local recompute floor, with a
  clear exempt so an expiry is prompt. Ten-minute circling rider: five shares
  measured, six at the ceiling, plus one clear. Bounded to 60 breadcrumb points
  at five decimal places.
- **No map file was touched.** The leader's shared breadcrumbs are published into
  the shell's existing one trail channel as `MapOverlayTrace(kind: rejoin)`, so
  `RouteTrailStyle.rejoinBreadcrumb` renders them with no change to
  `ride_map_feature.dart` at all.
- **Both skew directions are named, not silent.** A relay without either
  capability makes the leader's request refuse to record and raises
  `tecAssignmentUnsupportedByService`; a peer already known to be on an older
  build is named before the leader asks. See
  `test/internet/tec_and_rejoin_capability_skew_test.dart`.

## Parked, not forgotten

Two free data sources were assessed on 2026-07-26 and parked on the P2 roadmap
in `PLAN.md` as candidates for a later paid tier, with the detail in
`docs/uk-enforcement-data-decision.md`:

- an OpenStreetMap fixed-camera layer through the existing `tools/discovery`
  generator (3,422 camera nodes, 597 enforcement relations, GB, ODbL, offline);
- roadworks from DfT Street Manager, the only free feed reaching local roads.

Neither is started. The in-app warning surface they would feed already exists.

## Remaining evidence

- Ride a route-less ride on a mounted phone and confirm SOS, Leave, Report, the
  ride menu, the follow camera and re-centre all work, and that no route-derived
  surface appears empty or placeholdered.
- Read the decluttered chrome on a mounted phone in both orientations, at the
  largest supported text size, and confirm nothing overlaps and the ride menu is
  reachable by feel without looking.
- Stand a phone still on a known road and confirm the mapped limit appears within
  one fix. Repeat beside a dual carriageway and at a junction, and confirm an
  honest low-confidence state rather than the wrong road's limit. The stationary
  path sends a **single-point** shape to Valhalla `trace_attributes`; that has
  not been exercised against the live FOSSGIS instance from this branch, so
  confirm it returns a match rather than an error before trusting the feature.
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
- Ask a rider to be Tail End Charlie from a leader phone and accept on theirs,
  over internet-only, nearby-only and mixed transports, then decline one, then
  leave the ride while holding the role, then hand the lead over mid-request.
  Nothing in #128 has been on two devices — the automated coverage is unit and
  widget level only.
- Ride a real off-route excursion with a leader watching, and confirm the cyan
  rejoin breadcrumb appears on the leader's map only, is distinguishable from
  every other line through a visor, and clears when the rider rejoins, when the
  leader republishes the route, and at ride end. Count the relayed events over a
  ten-minute excursion against the five-to-six bound.
- Publish, replace and clear leader routes across late join, offline reconnect,
  restart and lead handover on both platforms.
- Deploy the compatibility endpoint and test old-client/current-server plus
  current-client/old-server rollout combinations.
- Run onboarding with at least one person who has not used the app and record
  accessibility observations at supported text sizes and with a screen reader.
- The full Nearby, background, battery, route-alert and vehicle-interface gates
  in `PLAN.md` and `docs/field-test-plan.md` remain authoritative.
