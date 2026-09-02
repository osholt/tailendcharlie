# Next-agent handoff

Updated: 2026-08-12

## Current state: build 52 with testers, waiting on a ride

**The relay deploys itself and it has been proved.** A merge to `main` touching
`apps/server/**` or `deploy/**` deploys pre-production, runs the server suite and
a live smoke test, promotes to production, then verifies from outside the box.
Production has auto-deployed and been verified this way. The 2 GB swapfile is in
place. `serverBuildCommit` remains the only trustworthy answer to what is running;
the checkout on the box is not it.

**Build 52 is with testers** — iOS TestFlight (internal, no external review) and
the Android alpha track, version 1.0.1. It carries seven merges from the ride of
12 August 2026:

| Ticket | What it fixes |
| --- | --- |
| #456 | The recorded diagnostics log survives the ride and is shareable from Settings and every share door |
| #457 | The diagnostics switch works mid-ride instead of being sampled once in `initState` |
| #460 | A close pair of junctions is named in one spoken prompt |
| #446 | The camera alert is a bubble for ten seconds, then a red border alone |
| #426 | No start screen — the map is the surface |
| #431 | Search a destination from the map, then pick solo or group |
| #452 | CarPlay gets a real time to the turn instead of a zero |

### The next task is a ride, not code

Three tickets are **blocked on field evidence and must not be guessed at**:

- **#461** — the second roundabout of a close pair is described as two separate
  turns, and the wording came out as "at the end of the road". Two candidate
  causes with different fixes: the engine never calling it a roundabout, or the
  app failing to merge its two steps.
- **#450** — no audio at all on a CarPlay ride. The log distinguishes "decided to
  say nothing" from "said it and nothing came out".
- **#451** — the mapped speed limit reads a dash on roads with a posted limit.

Build 52 is the first build where the instrument for these actually works:
**Settings → Record ride diagnostics**, reachable from the home screen or the ride
menu, effective when switched on mid-ride, written to disk as it records, and
shareable afterwards from **Settings → Recorded rides**. #408 is the standing
reminder of what guessing at roundabout geometry costs here — the "obvious fix"
would have drawn an illegal manoeuvre.

### Open and not blocked

#440 stuck on the summary screen · #441 starting a ride from the phone with
CarPlay attached · #442 CarPlay layout · #444 reroute slow, silent, and ignoring
heading · #448 position lag of about 22 yards · #449 smoother distance countdown ·
#452 the clock half, still open · #412 exit direction one off · #413–#417 · #408
legibility · #398 the pre-production Caddy route · #352 Bouncy Castle · #395.

#431 stays open for the shorter ride-ending flow it also asks for, which overlaps
#440.

### Decisions recorded rather than re-argued

- `docs/geocoder-decision.md` — destination search stays on the public Nominatim
  instance and submits rather than autocompletes, because the usage policy lists
  client-side autocomplete as an unacceptable use. As-you-type needs a geocoder we
  host, and the relay has 954 MB of RAM.
- `docs/traffic-provider-decision.md` — no licensed live-traffic feed.
- The dependency graph submitted to Dependabot is scoped to runtime classpaths,
  which took alerts from 47 to 3. #350 adds `bcprov-jdk18on` as an
  `implementation` dependency, so Bouncy Castle now ships in the Android APK and
  will appear in that graph. That is expected and is how it gets tracked.


### Traps worth knowing before you start

- **The Android version code defaults to the workflow run number and collides**
  with codes already used. Build 46 failed first time on *"Version code 40 has
  already been used"*. Pass `build_number` explicitly and higher than every
  shipped code.
- **`tools/discovery` tests run under `unittest discover`, not pytest.** A
  pytest-style module is collected as zero tests and passes silently.
- **A mutation run that reports OK may never have applied.** One did in this
  session: the shell's working directory had an unavailable pyenv version, so the
  mutation script died and an unmutated suite passed. Assert the mutation landed
  before trusting the result.
- **Recreating Caddy without `compose.preproduction-proxy.yaml` silently drops
  the pre-production route.** That is how #398 happened.
- **`flutter analyze` prints warnings flush-left, not indented.** A grep for
  `^\s+(error|warning)` misses every one of them. An `unused_element` warning
  passed locally that way and failed CI, which treats warnings as errors. Read the
  "N issues found" line instead of grepping.
- **A mutation whose target has been reflowed by `dart format` silently does not
  apply**, and an unapplied mutation reads exactly like a passing test. Assert the
  marker changed, and prefer line-anchored edits over exact multi-line matches.
- **Merging a stacked PR with `--delete-branch` auto-closes its children**, and a
  PR whose base branch is gone cannot be reopened or retargeted. Retarget children
  to `main` *before* merging the parent. This cost #459, which had to be recreated
  as #463.
- **The checkout on the box is not what is deployed.** After the reboot it was at
  `c1ecb1c` while the running image reported `fa13532`. `serverBuildCommit` is
  the only trustworthy answer.

### Working agreements

- Mutation-test every fix, and say which mutations were caught.
- Never close a ticket that has not been field-validated; label it
  `status: ready for validation` instead.
- One pull request per issue.
- Ask before any release.
- **No location-specific special cases.** A catalogue of two hand-reviewed
  junctions was replaced this session by a generated layer covering every mapped
  mini-roundabout (#390). Prefer a general rule, then a generated layer from
  OpenStreetMap through `tools/discovery`, then saying the fault is unfixable —
  in that order. Claiming less is acceptable: the layer dropped exit numbers it
  could not support.

### Access

- `ssh oracle-relay` — alias in the operator's `~/.ssh/config`. **The repository
  is public; host details must stay in secrets and out of committed files.**
- Oracle CLI auth is a browser-issued session token that expires. Re-authenticate
  with `oci session authenticate --profile-name DEFAULT --region uk-london-1`,
  which needs a human at a browser, then pass
  `--auth security_token --profile DEFAULT` to every command.
- ICMP is not permitted by the security list, so `ping` proves nothing. Judge
  reachability on TCP 22 and 443.



## Current state: tester feedback 7

The 30 July tester-feedback implementation has merged to `main`. The original
checkout still contains unrelated work and must not be modified; subsequent
release work uses the clean continuation worktree documented below.

The 30 July WhatsApp export and direct tester report are tracked in #157, #242,
#254, #259, #261 and #262. The full group watcher is tracked in #263. This
work:

- replaces the recap's uncapturable native MapLibre view with a pure-Flutter
  vector map inside the exported `RepaintBoundary`;
- fixes Android route-drag hit testing by converting logical gesture
  coordinates to native pixels;
- prevents two initials wrapping vertically and enlarges every initials
  renderer to fill the rider badge;
- removes ride-time controls and guidance from the pre-start map and condenses
  its participant summary;
- offers a routed **Navigate to start** leg when the planned route begins more
  than 250 m away; and
- adds explicit Solo, Second-bike drop-off and Keep-together ride modes, with
  participant transports skipped for solo and marker behaviour restricted to
  the drop-off mode; and
- preserves the existing **Just me** watcher while adding a leader-only
  **Whole group** scope. The leader must confirm the group has been told; the
  bounded encrypted snapshot contains the current roster, last-known positions
  and planned-route outline but no rider IDs, credentials, trails, messages,
  speed, phone/ICE data or participant controls. The watcher remains read-only
  and outside the roster. Relay migration `0009` and the updated web assets
  must deploy before the mobile build.

The implementation and its automated checks have merged. Physical-device
validation remains tracked by each issue's `status: ready for validation`
label rather than by this handoff.

## Current state: CarPlay Navigation

PR #319 merged to `main` as `44e74ac`. Apple approved the navigation entitlement
under Case-ID 21286533.
On 29 July the `CarPlay Navigation App` capability was enabled for
`app.tailendcharlie`; the previous profiles became invalid and were replaced
without deleting their historical records:

- `Tail End Charlie CarPlay Navigation Development`
  (`2f1ad93d-9320-4046-a54e-908dc2639d44`)
- `Tail End Charlie CarPlay Navigation App Store`
  (`e87d428b-76d2-4aa5-b455-45e0bd3339d4`)

Both contain Driving Task and Navigation, Associated Domains, Push
Notifications and the correct APNs environment. The development profile
contains both local development certificates and both test phones. The App
Store profile uses the same certificate as the previously working CI profile;
`APPLE_APPSTORE_PROFILE_BASE64` has been replaced.

The merged implementation replaces the status-only CarPlay root with a
`CPMapTemplate` and an
app-owned MapLibre route/rider canvas using the phone's resolved style and
navigation viewport. It has rider identity badges, route progress, recenter and
pan controls, persistent TEC status, a low-frequency group overview mini-map,
Report and confirmed SOS controls. A 2 September 2026 compliance audit found
that those overlays and controls are drawn in Apple's map-only base view, and
that `updateNavigationSession` cancels the `CPNavigationSession` before its
turn/marker path can run. See `docs/carplay-compliance-checklist.md`; do not
describe this surface as compliant or field validated until its release gate
passes. Every unchecked CarPlay item is mapped to #690–#699 or the existing
audio/wording tickets. The cross-platform architecture, Android Auto Tier 2
sequence (#602, #684–#689, #700–#703), optional cluster work (#704), and
view/function impact are in
`docs/carplay-compliance-implementation-plan.md`. CarPlay reports are validated
in Dart and use the same current-location
hazard path as the phone. Issue #328 also adds a
leader-only **Start prepared ride** action: CarPlay confirms the route/no-route
state and no-TEC warning, while creation, joining, route selection and first-time
location permission stay on the phone. Dart revalidates leadership, lifecycle
and location readiness when the native action arrives.

The projected-navigation foundation for #690 merged in PR #705. The shared
snapshot contains an additive `carplayNavigation` schema V2 with separate
ride/navigation phases, stable trip/choice/manoeuvre IDs, typed directions,
roundabout exits, lanes, traffic side, road/instruction variants, estimates,
locale and unit metadata. Swift bounds and decodes it and rejects malformed,
replayed and out-of-order updates, but does not yet activate an Apple navigation
session. Issue #700 adds a separately versioned `androidAutoNavigation` schema
V2 with the same Dart-owned domain boundary, an independent strict Kotlin
decoder, replay/out-of-order protection, separate ride and navigation
lifecycles, and bounded typed host events. Android V1 snapshots continue to
decode during the migration, while CarPlay's V2 contract and behavior remain
unchanged. The incremental compliance
checker runs in mobile CI and both closed-tester upload workflows; `--strict`
remains red until all required CarPlay and Android Auto rows have evidence.

Flutter analysis, the full test suite, an Android debug APK and an unsigned iOS
simulator build passed on the PR. A signed Profile build also passed with the
replacement development profile and both CarPlay entitlements stamped into
`Runner.app`. The CarPlay Simulator has opened the navigation scene and the
main map/style/viewport were compared with the phone. The latest mini-map and
button layout were subsequently compared with the phone. The simulator helper
now handles Xcode's `CarPlay…` custom-display dialog, finds a Python interpreter
with Quartz instead of assuming the first one on PATH, installs before attaching
so the CarPlay catalogue is current, and captures the external display directly.
The installed iOS 26.5 simulator filters unsigned restricted-entitlement builds
from its CarPlay catalogue; an ad-hoc entitlement signature is installable but
cannot launch, exactly as documented. The implementation is therefore ready for
a signed TestFlight build, but #295 and #328 still require a physical iPhone and
CarPlay head-unit run before production support can be claimed. Ride creation,
joining, route choice and first-time permissions intentionally stay on the
phone; a leader can start an already-prepared ride from CarPlay.

Continue mandatory CarPlay behavior with #691–#696 and Android Auto behavior
with #684–#689. Keep #698 and #703 open until their physical head-unit evidence
gates can truthfully be completed; tester uploads remain explicit manual jobs.

## Read this first: #132, a device only received when it sent

`claude/issue-132-presence-asymmetry` fixes the defect behind #132 and the
recurrence of #99. **Upload and download share one relay request, and the relay
answered a repeated request from its idempotency replay cache — including the
download half.** A phone with nothing to send repeats a byte-identical body on
every poll (same device, same cursor, empty batch), so it was served the cached
reply and received *nothing* until it happened to have an event of its own to
upload. That is why the leader, lying still on a desk with no new GPS fix to
send, counted the follower (its first poll was not yet cached) and never saw the
follower's position, while the follower — still producing and receiving events,
so never byte-identical twice — saw everything. **The failure follows whichever
device has an empty outbound queue, not the role.**

The fix is in `apps/server`: idempotency now covers the upload only, the download
is rebuilt from the caller's cursor on every request, and an empty batch is never
stored as a replay. **It therefore needs a relay deploy — the phones in testers'
hands are fixed by deploying the server, with no app update.**

Three further defects in the same area were fixed alongside it; see "This
branch" below. Physical two-device evidence is still owed: run
`docs/field-test-plan.md` step 8b.

## Current branch

Active work is on `claude/issue-133-chrome-contrast`: #133 (the "Follow me"
regression, the portrait and landscape chrome positions, and the dark-mode
contrast audit) plus the landscape report-sheet layout from the same physical
evaluation. They land together because they all edit
`apps/mobile/lib/features/map/ride_map_feature.dart`. Do not split or overwrite
the user's unrelated local Xcode signing edit or the untracked
`docs/carplay-entitlement-submission/` material.

### What #133 changed, and the one thing to read first

- **"Follow me" is measured, not inferred.** #125 gated it on a flag set only
  when a pan interrupted an *active* follow. Follow mode needs movement, so a
  stationary phone was never following, a pan suppressed nothing, and the button
  never appeared — the map could be pushed off the rider with no way back on both
  testers' phones, because both were on a desk. It is now derived from the map's
  own camera against the framing following would produce
  (`NavigationCameraPlanner.framesRider`). **Do not reintroduce a flag that
  records how the framing was lost**; that is precisely what shipped broken. The
  test that proves it is "a stationary rider who pans away is offered the way
  back", and it fails on the pre-fix code.
- Handing the camera over now also calls `stopAnimationRaw`: `flutter_map` does
  not cancel a controller-driven animation on a gesture, so a pan begun during a
  follow transition was being dragged back onto the rider.
- **The corners carry three small things**: ride menu top-leading in both
  orientations, group overview top-trailing in portrait and bottom-trailing in
  landscape, speed sign top-trailing in landscape. The layout test asserts each
  stays against an edge and stays small. Everything else is bottom-anchored, and
  the turn banner is the last surface above the targets.
- **The dark-mode diagnosis is in `docs/maps-and-gpx.md`, and it is not what it
  looks like.** The route palette was fine; the worst ink on the map was the
  *white glyph inside a marker badge* at 1.53:1. The basemap was investigated and
  deliberately left alone, with the measured reason recorded. Read that section
  before changing any map colour — in particular, the chrome panel fills measure
  1.0–1.8:1 against the basemap and are **not** defects.
- The portrait band is 296 logical pixels in ordinary riding (431 before #125,
  342 after), which takes the camera's forward bias from 29 to 75 pixels ahead
  and stops it clamping at all at rest.

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

- **A download never depends on having something to upload** (#132). See the
  section at the top. `apps/server/src/ride_relay_server/service.py`:
  `synchronize` consults the replay cache only for a non-empty batch, replays the
  stored `acceptedEventIds` rather than the stored events and cursor, and stores
  no replay row for an idle poll. The replay path also refreshes `last_seen_at`,
  which an idle-but-replaying device never used to do.
  `test/internet/two_device_relay_sync_test.dart` is the harness that would have
  caught it: two devices over the **real** HTTP client and worker against a fake
  relay that keeps the replay rule, with one device idle throughout. Every
  earlier harness stubbed the transport and always had something queued, so the
  defect could not appear.
- **Freshness is judged on a clock both devices share.** A peer's position used
  to be aged by this phone's clock minus the *peer's* own timestamp, which
  measures the difference between two clocks as well as the age: a rider whose
  clock was a few minutes out was drawn as stale, marked `inactive`, and then
  dropped entirely at the five-minute retention bound while reporting every four
  seconds. The relay now reports `serverTime` beside the arrival stamps it
  already put on every position, `PreStartPresenceController` measures the offset,
  and `LivePresenceReconciler` ages a relay-stamped peer position on the relay's
  clock (`PresenceClockBasis.sharedRelayClock`). A clock disagreement past
  `publisherClockTolerance` is *named* — `PresenceLimitation.riderClockUntrusted`
  — never used to age a rider out.
- **One unreadable position no longer discards the whole reply.** The presence
  decoder rejected the entire response — every position and the roster — if any
  single row's `expiresAt` was not after the *local* clock. A phone whose clock
  ran more than the 45 s TTL ahead of the relay hit that on every poll and was
  told "the ride service cannot be reached" while it was answering perfectly.
  Rows are now skipped individually and counted
  (`PresenceLimitation.positionsUnreadable`), and expiry is judged on the relay's
  clock — the relay has already deleted whatever it considers expired, so a local
  re-check could only ever measure skew.
- **The count, the roster and both maps derive from one model.** `RideLiveView`
  in `lib/services/ride_membership.dart` reconciles membership with live presence
  and asserts the invariant: every counted rider is either in
  `renderedPositions` or in `countedWithoutPosition` with a stated reason
  (`RidePositionAbsence`). `RideController.participants`/`liveParticipants` and
  the ride map's `visibleRiderLocations` all come from it, so "counted but no
  marker and nothing said" is now unrepresentable rather than merely unintended.
  `test/services/ride_live_view_test.dart` asserts the agreement directly.
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
- **The mapped speed limit resolves now and one kilometre ahead.**
  `waitingForMovement` is retired as the entry state; ambiguity is stated as
  `unconfirmedRoad` and retried, rather than withheld. A stationary lookup uses
  `locate` plus a duplicated-point trace confirmation because Valhalla rejects a
  one-point trace. While moving, the remaining route is sampled every 25 metres
  in one look-ahead trace; without a route the samples follow the current
  heading. Road-and-direction answers stay in memory through a signal drop.
  After the first resolution the sign is always a number, dash or infinity, and
  conflicting nearby roads are not guessed. A rider who previously turned the
  feature off stays off.
- **The BS15 1UJ double mini-roundabout is restored from reviewed map data.**
  Live OSRM and Valhalla responses both omit OSM nodes 30983542 and 30983544 as
  manoeuvres. Their current OSM tags and mapped arms are therefore kept in a
  bounded offline regression catalogue. A route through them gains two
  persisted 2nd-exit, straight-on instructions 42 m apart; the second is shown
  while approaching the first and becomes current after it is passed. The
  catalogue intentionally claims no general mini-roundabout coverage. Physical
  or simulator validation from BS15 1UJ toward Chippenham remains the #163 gate.
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

- **Run `docs/field-test-plan.md` step 8b on the two physical phones** (#132):
  both stationary on a desk with nothing to send, then a report from one side
  only, then the roles reversed, then with one clock deliberately five minutes
  wrong. Nothing on this branch is physical-device evidence; it is a proven
  root cause with a server-side fix and simulated two-device coverage. The relay
  must be deployed before that test means anything.
- Pan the map away on a **mounted** phone, standing still and moving, in both
  orientations, and confirm "Follow me" appears every time and that tapping it
  re-centres. This was verified in widget tests and in rendered frames only.
- Read the repositioned chrome on a mounted phone in both orientations and confirm
  the group overview in its corner does not obscure anything a rider needs, and
  that the stacked SOS/LEAVE pair is reachable without looking.
- Report a sighting in landscape wearing gloves and confirm both options are
  reachable without scrolling.
- Photograph the dark map through a tinted visor in daylight. #107's outstanding
  evidence is unchanged, and #133 now adds the marker glyphs to it: the numbers
  say a dark glyph is 3–8 times better on every badge, but only a photograph shows
  whether a rider can pick their own bike out of a group at a glance.
- Ride a route-less ride on a mounted phone and confirm SOS, Leave, Report, the
  ride menu, the follow camera and re-centre all work, and that no route-derived
  surface appears empty or placeholdered.
- Read the decluttered chrome on a mounted phone in both orientations, at the
  largest supported text size, and confirm nothing overlaps and the ride menu is
  reachable by feel without looking.
- Stand a phone still on a known road and confirm the mapped limit appears within
  one fix. Repeat beside a dual carriageway and at a junction, and confirm an
  honest low-confidence state rather than the wrong road's limit. Then watch the
  sign for a whole physical ride with and without a route, including a signal
  drop, and confirm it moves between number/dash/infinity without returning to a
  spinner. The provider schema and cache are covered in tests; the mounted,
  moving behavior remains the release evidence required by #164.
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
