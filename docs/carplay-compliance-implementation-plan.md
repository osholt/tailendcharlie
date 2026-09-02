# Projected navigation compliance implementation and impact plan

**Status:** Proposed

**Date:** 2 September 2026

**Compliance baselines:** `docs/carplay-compliance-checklist.md` and Google's
[car app quality requirements](https://developer.android.com/docs/quality-guidelines/car-app-quality)
for an Android Auto Navigation-category app.

**Decision required before implementation:** approve the functionality and
layout changes in the impact assessment below.

## Outcome

Bring both projected navigation surfaces to their platform compliance baseline
while preserving Tail End Charlie's ride recording, group coordination, route,
rider and hazard data, offline behavior, and phone experience.

The compliant center-display hierarchy will be:

1. one app-owned MapLibre map in the base view;
2. route, rider, hazard and permitted heat-map geometry as map content;
3. Apple-owned `CPMapTemplate` controls;
4. Apple-owned trip preview, turn, ETA and navigation-alert panels; and
5. a bounded `CPListTemplate` opened from **Ride** for secondary group state and
   ride actions.

Android Auto will keep its host-owned `NavigationTemplate`, but gain a complete
`NavigationManager` lifecycle, typed manoeuvres, navigation notifications,
voice-intent and test-drive handling, host-driven day/night behavior, safe-area
camera fitting, and an offline-capable road basemap. Its custom surface will
draw map content only.

This is a redesign of both projected presentation adapters and their navigation
lifecycles. It is not a redesign of the phone map, event journal, location
recording, routing algorithms, or relay protocol.

## Architectural decision

### Chosen approach: one ride domain with two native navigation adapters

Keep Dart as the authoritative owner of routes, rides, recording and group
state. Give each platform an additive, typed navigation projection and native
coordinator. Swift owns CarPlay scenes, templates and `CPNavigationSession`;
Kotlin owns the Android Auto `Session`, templates, `NavigationManager`,
notifications and map surface. Both send explicit user/host events back to
Dart.

```text
RideController + routing + recorded track + group journal
                            |
             projected navigation domain (Dart)
              /              |                \
     phone presentation  CarPlay V2       Android Auto V2
                              |                |
                   Swift coordinator   Kotlin coordinator
                    /            \       /              \
             CPMapTemplate  CPNavSession NavigationManager  templates
                    |                       |                 |
             map-only MapLibre       notifications/cluster  map-only Surface
```

Both projections must be additive. Android currently consumes the same
top-level snapshot channel as CarPlay, so existing fields cannot be removed or
redefined until both migrations are complete. Prefer distinct versioned
`carplayNavigation` and `androidAutoNavigation` payloads over platform conditionals
inside one loosely typed object.

### Alternatives rejected

| Option | Benefit | Why it is not the plan |
|---|---|---|
| Keep the custom overlays and buttons | Preserves the current dense layout. | Directly conflicts with Apple's rule that the navigation base view contain only the map and no custom UI. |
| Downgrade CarPlay to a Driving Task list | Much smaller native implementation. | Removes the map, native turn cards and route guidance that the Navigation entitlement was approved to provide. |
| Mirror the phone UI | Maximum visual parity. | Conflicts with CarPlay templates, driving restrictions, varying displays and locked-phone operation. |
| Use one native adapter/protocol for both projected platforms | Fewer model types. | Apple and Google have different trip/session, notification, cluster, intent, scene and cancellation contracts. Sharing the ride domain is valuable; sharing their native lifecycle is brittle. |
| Leave Android Auto on a route-only canvas | Lowest rendering risk. | The current surface has no roads or junction context and does not meet the experience claimed by a turn-by-turn navigation app. |

## Non-negotiable state separation

Ride lifecycle and each projected navigation lifecycle must be independent
state machines.

| Event | Projected navigation | Ride recording and group session |
|---|---|---|
| Start a routed ride | Start/resume `CPNavigationSession` or call Android `navigationStarted()`. | Start the existing durable ride and recording once. |
| Start free roam | Remain navigation-idle because there is no route. | Start and record the ride normally. |
| Host gives navigation ownership to another app | Immediately stop guidance, notifications, cluster metadata and voice. | Continue recording, sharing and group safety state. |
| Rider cancels directions | Cancel route guidance. | Keep the ride active unless the rider separately chooses **Leave ride** or **End ride**. |
| Reroute | Pause with the documented reason, replace route/manoeuvres, then resume. | Continue recording without a gap or duplicate ride. |
| Arrive | Finish the navigation session. | Keep recording until the rider explicitly ends the ride. |
| Leave or end ride | Cancel or finish any active navigation session. | Perform the existing durable leave/end transition once. |
| Projected host disconnects | Release host UI objects; retain enough projection state to restore. | Continue phone-side recording and group behavior unchanged. |

This separation protects the requirement that solo, group and free-roam rides
are always recorded even when projected guidance is cancelled, replaced by
another navigation app, disconnected or never started.

## Recommended delivery order

1. Land the state-separation and schema guardrails in CarPlay #690, then the
   distinct Android projection in #700. Do not remove V1 fields yet.
2. Complete the mandatory native lifecycles: CarPlay preview/session work
   #691–#692 and Android ownership/intents/manoeuvres #684–#685/#687.
3. Correct the projected surfaces: CarPlay templates #693/#695 and Android
   safe-area/basemap/host mode #686/#701/#689.
4. Finish phone independence and audio ownership: #694/#688/#450 on iOS and
   #688/#702 on Android.
5. Add required CarPlay Dashboard/restoration work #696, then run the independent
   platform gates #698 and #703 before each closed-test rollout.
6. Only after the required baselines pass, consider optional vehicle surfaces
   and sharing in #697 and #704.

This order keeps each PR reviewable and allows either platform to reach its
release gate without waiting for the other's optional work. Do not implement
both native adapters in one PR.

### CI enforcement introduced with #690

`tools/projected-navigation-compliance.py` is the machine-checkable front door
for projected-navigation changes. Pull requests, pushes to `main`, TestFlight
uploads and Android closed-testing uploads run its incremental tester gate. It
fails when required entitlements, scene/service declarations, V2 contract
markers, decoder compatibility coverage, checklist consistency or ticket
traceability regress.

The incremental gate deliberately permits documented, ticketed FAIL/PARTIAL/
UNVERIFIED rows while this programme is in progress; otherwise no closed tester
could exercise the migration. A production candidate must additionally run:

```bash
python3 tools/projected-navigation-compliance.py --strict
```

Strict mode fails until every required CarPlay row and every applicable Android
Auto Tier 2 criterion is recorded PASS. Changing a checkbox alone is not
sufficient: the ordinary mobile workflow also runs Flutter tests, the Android
native unit suite and the iOS `RunnerTests` target.

## CarPlay implementation sequence

Each numbered unit should have one GitHub issue and one PR. Do not combine them
into a single large CarPlay rewrite. The temporary V2 feature switch may be on
for internal/closed testers, but the noncompliant legacy path must be deleted
before a production compliance claim.

### 0. Baseline, tickets and migration guardrails — #699

Checklist coverage: all IDs.

- Capture the current CarPlay screens at 800 x 480, widescreen and portrait so
  intentional removals are reviewable rather than mistaken for regressions.
- Keep the completed issue map in #699 current. Implementation work is split
  across #690–#698, with existing issues #295, #328, #367, #441, #447, #450,
  #533 and #688 linked where they overlap.
- Add a temporary `CARPLAY_NAVIGATION_V2` test-build switch with no effect on the
  phone or Android Auto.
- Record the old-to-new view mapping from the impact table in each UI issue.
- Add a source-level regression check that the base map controller contains no
  `UIButton`, status panel, second map or guidance view when V2 is enabled.

Exit gate: both old and V2 paths compile, Android snapshot parsing is unchanged,
and current phone/Android tests remain green.

### 1. Introduce a typed CarPlay V2 projection — #690

Checklist coverage: CP-NAV-02 through CP-NAV-10, CP-UI-06, CP-MAP-02.

- Split the current untyped snapshot conceptually into:
  - common map/ride data used by CarPlay and Android Auto; and
  - iOS-only navigation data used by `CPTrip`, `CPManeuver`, alerts and session
    lifecycle.
- Add stable identifiers for trip, route choice and manoeuvre so distance
  updates do not recreate panels.
- Project structured manoeuvre type, roundabout exit, traffic side, road-name
  variants, instruction variants, distance/time estimates and optional
  following manoeuvre. Do not infer manoeuvre types from English display text in
  Swift.
- Project explicit ride lifecycle and navigation lifecycle separately.
- Project unit system and locale independently of the speed-limit value; avoid
  fields named `limitMilesPerHour` at the native boundary.
- Preserve all existing top-level fields until Android Auto has migrated or
  prove its parser safely ignores the V2 payload.

Files primarily affected:

- `apps/mobile/lib/services/carplay_bridge.dart`
- route-guidance domain/projection code under `apps/mobile/lib/services/`
- `apps/mobile/ios/Runner/AppDelegate.swift`
- Android snapshot parser tests as compatibility guards

Exit gate: Dart and Swift parsing tests cover missing, stale, malformed and
out-of-order V2 messages; Android receives byte-for-byte equivalent legacy
fields.

### 2. Make route planning a preview-first transaction — #691

Checklist coverage: CP-NAV-01 and CP-NAV-02, CP-SAFE-02.

- Keep destination entry in `CPSearchTemplate` with bounded results.
- Plan the selected destination in Dart without creating a ride or publishing a
  route to the journal yet.
- Return one or more immutable route previews to Swift, each with a stable
  choice ID and current `CPTravelEstimates`.
- Build a `CPTrip` and show it using `showTripPreviews`; update the base map to
  display the currently selected `CPRouteChoice`.
- In `mapTemplate(_:startedTrip:using:)`, start a paused/loading navigation
  session, send the selected choice ID to Dart, persist/create/start exactly
  once, then populate manoeuvres and resume. Cancel the session and show a
  CarPlay error if Dart rejects the commit.
- Cancelling the preview must leave no empty ride, route event or recording.

Recommended product boundary:

- CarPlay may create and start a solo routed ride or free roam.
- A group ride should be prepared on the phone while parked, then started from
  CarPlay. Remove **Create group ride** from CarPlay unless the whole invite and
  preparation flow can be completed safely without touching the phone and Apple
  confirms it fits the approved category.

Impact: selecting a destination no longer creates a ride immediately. The user
gets Apple's route preview and **Go** confirmation first, eliminating abandoned
or accidental CarPlay-created rides.

### 3. Implement the navigation-session coordinator — #692

Checklist coverage: CP-NAV-03 through CP-NAV-10.

- Extract session behavior from the 3,000-line scene file into a small
  `CarPlayNavigationCoordinator` with explicit states: idle, previewing,
  loading, navigating, paused, rerouting, arrived and cancelled.
- Remove the unconditional cancel-and-return at the start of
  `updateNavigationSession`.
- Maintain at least one upcoming manoeuvre and provide the following manoeuvre
  when turns are close together.
- Use light/dark `CPImageSet` assets and longest-to-shortest instruction variants.
- Update manoeuvre estimates and overall trip estimates only when the values
  change materially.
- Handle start, pause, reroute/resume, arrival/finish, user cancellation,
  disconnect and reconnect idempotently.
- Implement `mapTemplateDidCancelNavigation` and tell Dart to stop route guidance
  without ending or leaving the ride.
- Publish background notification decisions and iOS 17.4+ manoeuvre metadata.
- Treat junction-marker/TEC coordination as group state or an alert, not as a
  fake road manoeuvre.

Files primarily affected:

- `apps/mobile/ios/Runner/CarPlaySceneDelegate.swift`
- new focused Swift coordinator/projection files under `ios/Runner/`
- `apps/mobile/lib/services/carplay_bridge.dart`
- active-ride navigation projection in Dart

Exit gate: native state-machine tests prove every transition, including vehicle
cancellation while recording continues and reconnect during a reroute.

### 4. Replace the custom active-ride layout with CarPlay templates — #693

Checklist coverage: CP-UI-01 through CP-UI-09.

- Reduce `CarPlayNavigationViewController` to one MapLibre map containing only
  cartographic content: basemap, route/progress lines, rider markers and
  location-bound hazard annotations.
- Remove the TEC badge, speed badge, compass badge, group mini-map, app clock,
  route-progress view, custom guidance view and `CarPlayRideActionsView` from the
  base view.
- Keep a single **Ride** navigation-bar button for bounded secondary status.
- Use system controls with no more than the supported limits:
  - map buttons are reserved for map operations: **Pan**, **Recenter**, **Zoom
    in** and **Zoom out** where applicable;
  - active navigation bar: leading **Ride** and **End directions**, trailing
    **Report** and **SOS**;
  - home/pre-ride navigation bar: **Ride**, **Start**, **Search** and **Free
    roam**, reduced further when a control is not applicable;
  - **Leave ride** remains inside the Ride list with confirmation.
- Always include **Pan** when map panning is available. Support non-touch knob
  mode and touch pan/zoom/pitch/rotation callbacks by availability.
- Keep the heat map only if it behaves as a cartographic layer, stays underneath
  roads/labels and passes legibility checks. Otherwise disable it in CarPlay.
- Apply camera padding from the current CarPlay safe area and system panels.

Exit gate: automated view-structure tests prove the base view has only the map;
all actions remain reachable using Apple-provided controls at every required
display size.

### 5. Move group status and alerts into permitted surfaces — #694 and #688

Checklist coverage: CP-NAV-07, CP-SAFE-01 through CP-SAFE-05.

- Keep the bounded `CPListTemplate` for route/ride state, TEC, marker status,
  group state and at most four relevant riders.
- Refresh the list on user entry and material state changes; throttle periodic
  Driving Task data refreshes to at least ten seconds. Map rider positions may
  continue at the existing bounded cartographic cadence.
- Use `CPNavigationAlert` for genuinely navigation-related, time-sensitive
  hazards and route decisions. Do not turn ordinary group telemetry into
  repeated driving alerts.
- Keep role requests and destructive actions in system alert/action templates;
  suppress or defer them when the host restricts the interface.
- Replace every instruction to use the iPhone with neutral wording such as
  **Setup required. Complete setup when parked, then try again.**
- Hide actions that cannot complete in CarPlay instead of leading the rider into
  a phone-dependent dead end.

Exit gate: no CarPlay string tells a moving rider to touch the phone; each
visible flow either completes in CarPlay or ends safely with a parked-setup
message. #688 can then be validated.

### 6. Make spoken guidance a correct CarPlay audio citizen — #450

Checklist coverage: CP-AUDIO-01 through CP-AUDIO-05.

- Add one iOS audio-session coordinator shared by system TTS and the natural
  voice path.
- Configure playback + voice-prompt mode with
  `interruptSpokenAudioAndMixWithOthers` and `duckOthers`.
- Remove configure-time activation. Activate immediately before a prompt and
  deactivate with notification immediately after it completes or is cancelled.
- Read `AVAudioSession.promptStyle` before every prompt:
  - `.none`: play nothing;
  - `.short`: play a short nonverbal cue;
  - `.normal`: play the full spoken prompt.
- Preserve the natural-to-system fallback, but make both outputs use the same
  prompt-scoped audio coordinator so a fallback cannot double-speak or leave
  other audio ducked.
- Verify interruptions, route changes and CarPlay disconnect cancel pending
  audio cleanly.

Impact: this changes iOS phone audio behavior as well as CarPlay because the
same speech engines are used. Android audio configuration must remain untouched.

Exit gate: automated session-transition tests plus physical checks with FM,
music, podcasts, calls and Siri. #450 remains open until physical evidence exists.

### 7. Use host appearance, correct units and country metadata — #695

Checklist coverage: CP-UI-05, CP-UI-06, CP-MAP-01 through CP-MAP-04.

- Store the connected `CPWindow` and interface controller for the scene lifetime.
- Drive CarPlay style from the scene's `contentStyle` and
  `contentStyleDidChange`, while reusing the corresponding cached MapLibre style
  document. Phone theme selection must not override a car-requested safety mode.
- Keep distance units aligned with the explicit app setting, but present current
  speed and speed limits in the selected/local unit if they appear on any
  permitted template or cluster surface.
- Project right/left traffic side explicitly from route data. Validate French
  clockwise roundabouts, exit numbers, D-roads, autoroutes and metric guidance.
- Reject implausible/off-network location jumps before they affect map camera,
  route progress, recording or heat-map geometry.
- Test offline map/style recovery without replacing the route by a straight
  interpolation across missing fixes.

Impact: the CarPlay map may switch light/dark independently from the phone. The
phone map and stored user preference remain unchanged.

Exit gate: simulator evidence for both host styles and the full France/UK matrix
in the compliance checklist.

### 8. Add Dashboard and locked-phone lifecycle support — #696

Checklist coverage: CP-SCENE-03, CP-SCENE-05, CP-SCENE-06, CP-SAFE-05.

- Add `CPSupportsDashboardNavigationScene`, the Dashboard scene configuration
  and a `CPTemplateApplicationDashboardSceneDelegate`.
- Render a minimal second map: route ahead, current location and heading-up
  camera, with no group cards or custom UI. Let the active
  `CPNavigationSession` supply system manoeuvre information.
- Share immutable map data/style resources where safe, but give each scene its
  own controller and lifecycle.
- Restore active guidance from the durable ride/route projection after CarPlay
  reconnects; never create a second ride or restart recording.
- Prove required data is readable with the phone locked and protected data
  unavailable.

Impact: a second MapLibre view increases memory, tile requests and rendering
work on vehicles that show Dashboard. Use a simplified style and reduced update
cadence, and instrument memory/thermal behavior before enabling it broadly.

Exit gate: Dashboard and center-display reconnect tests pass with the phone
locked, and memory remains within an agreed test-device budget.

### 9. Add optional modern vehicle integration — #697

Checklist coverage: CP-OPT-02 through CP-OPT-05.

After the baseline is compliant:

- add an instrument-cluster map scene only if physical access exists to validate
  safe areas, heading-up behavior and automaker restrictions;
- publish complete iOS 17.4+ manoeuvre/lane metadata;
- add iOS 26.4+ destination sharing using `CPNavigationWaypoint`; and
- add route sharing with ordered `CPRouteSegment` data, current segment updates,
  reroute handling and vehicle-requested waypoints.

All APIs must be availability-gated because the app still targets iOS 16.0.
These features must not change baseline route or ride behavior on older iOS.

### 10. Validation, closed-test rollout and release — #698

- Replace obsolete assertions in
  `apps/mobile/test/features/carplay/carplay_layout_test.dart` that currently
  require the noncompliant custom overlays and disabled Apple trip panel.
- Expand `RunnerTests` beyond the two scene-generation tests to cover parsing,
  route preview, navigation lifecycle, cancellation and template composition.
- Run Flutter formatting, analysis and focused/full tests; native iOS tests; an
  unsigned simulator build; and a signed Profile/TestFlight archive with
  entitlement inspection.
- Execute every simulator and physical-host item in
  `docs/carplay-compliance-checklist.md`, attaching build/date/device evidence.
- Release V2 to closed testers first. Ask them specifically about lost glance
  information, action discoverability, audio coexistence, locked-phone use and
  France metric/roundabout behavior.
- Remove the legacy CarPlay surface and migration flag before production.
- Update App Review notes with an exact route/demo script and explain the
  group/recording behavior without asking the reviewer to operate the phone
  while driving.

## Android Auto compliance baseline

The Android implementation has advanced beyond the old text companion: it now
declares the Navigation category, installs a `NavigationTemplate`, draws a route
and riders on the host surface, and provides bounded Search and List templates.
It is not yet a compliant release candidate. In particular, it never registers
with `NavigationManager`, advertises every manoeuvre as straight, ignores
navigation intents and auto-drive mode, draws status text on the map surface,
ignores the supplied visible area, follows the phone rather than the host for
day/night mode, and has no road basemap.

Google requires Navigation apps used while driving to meet the applicable Car
optimized (Tier 2) requirements for Play acceptance. Tier 1 cluster-map support
is useful but optional. Android Automotive OS-only requirements such as EP-4 are
outside this Android Auto plan.

| Applicable criterion | Current status | Primary work |
|---|---|---|
| PC-1 permitted category | PASS | Preserve Navigation-only projected functionality. |
| EP-1 works as described | FAIL | Accurate manoeuvres #687 and a usable road map #701. |
| EP-2 state restoration | UNVERIFIED | Typed state #700 and evidence gate #703. |
| SA-1 no distracting animation | UNVERIFIED | Bound map updates and validate in #703. |
| AD-1 and NA-1 no ads | PASS | Preserve the current no-ad surfaces and notifications. |
| IU-1 permitted image use | PASS | Keep images limited to map/navigation context. |
| VI-1 safe phone handoff | FAIL | Platform-safe parked wording #688. |
| AC-1 five screens or fewer | PASS | Current navigation, search and group hierarchy is within the limit. |
| ST-1 no auto-scrolling text | PASS | Preserve host-owned static text behavior. |
| VC-1 Gemini/Assistant commands | PARTIAL | #685 implements the public `ACTION_NAVIGATE`/`geo` contract in both Session entry points; validate spoken requests in #703. |
| DR-1–DR-3 response/launch/content latency | UNVERIFIED | Instrument and validate two-/ten-second limits in #703. |
| VD-1 contrast | UNVERIFIED | Road basemap/palettes #701 and evidence #703. |
| TH-1 custom component theming | NOT APPLICABLE | Current Car App Library is 1.7.0 and no custom host-component theme is applied; reassess before a 1.9+ upgrade. |
| DD-1 navigation audio only | PARTIAL | Natural audio is classified correctly; align system TTS and ownership in #702. |
| PA-1 payments | NOT APPLICABLE | No purchase flow is exposed in Android Auto. |
| IN-1 relevant notifications only | PARTIAL | #684 limits the ongoing notification to active turn guidance; validate rail/HUN behavior in #703. |
| NF-1 turn-by-turn directions | FAIL | Typed projection #700 and manoeuvre mapping #687. |
| NF-2 map-only surface/safe area | FAIL | Surface and camera correction #686. |
| NF-3 notifications | PARTIAL | #684 publishes an ongoing `CATEGORY_NAVIGATION` notification with `CarAppExtender`; validate in #703. |
| NF-4 cluster next-turn metadata | PARTIAL | #684 publishes current/following steps and destination estimates through `NavigationManager.updateTrip()`; validate in #703. |
| NF-5 navigation ownership | PARTIAL | #684 ends trip metadata and notifications on host pre-emption without ending the ride; audio shutdown remains #702 and hardware validation #703. |
| NF-6 external navigation requests | PARTIAL | #685 parses bounded query/coordinate navigation intents and presents them for in-car confirmation; validate in #703. |
| NF-7 simulated test drive | PARTIAL | #685 implements `onAutoDriveEnabled` with deterministic host-only trip progress that cannot enter GPS, recording or heat-map data; validate in #703. |
| MR-1 host day/night map mode | FAIL | Host configuration handling #689. |
| NF-9 cluster map | OPTIONAL TIER 1 | Separate post-baseline ticket #704. |

Parent feature: #602. Final Tier 2 evidence gate: #703.

## Android Auto implementation sequence

Keep these as one issue and one PR per numbered unit. The Android work can run
after CarPlay #690 establishes versioning rules, but it must not consume the
iOS-only payload. Use a separate `ANDROID_AUTO_NAVIGATION_V2` test-build switch
until the complete Tier 2 path is ready for closed testers.

### A0. Preserve the working shell and define the migration — #602

- Capture the current compact and ultrawide surfaces and template stack.
- Preserve the manifest Navigation category, `NAVIGATION_TEMPLATES`,
  `ACCESS_SURFACE`, host validation, independent Flutter engine, bounded search,
  prepared-ride start, free roam and group list.
- Record the old-to-new mapping from the Android impact table below.
- Inventory the minimum Car App API level for every baseline API. Retain
  `minCarApiLevel=1` only where later capabilities are feature-detected with a
  tested fallback; otherwise propose the smallest justified increase before
  changing distribution compatibility.
- Keep Android Auto distribution and code compliance separate: Play Console
  form-factor enrollment is a release task, not an app architecture change.

Exit gate: current JVM tests and a DHU smoke test pass before the V2 flag changes
any tester-visible behavior.

### A1. Add the typed Android Auto projection — #700

- Project stable route, trip and manoeuvre IDs plus structured turn type,
  roundabout exit, traffic side, lanes, road name, instruction variants and
  current/following-step estimates.
- Project navigation lifecycle separately from ride/recording lifecycle.
- Add host-event commands for start, stop, external destination, auto-drive,
  reroute, arrival and restoration acknowledgements.
- Keep V1 snapshot fields until every Kotlin consumer has migrated.
- Share contract fixtures between Dart and Kotlin so platform decoders agree.

Impact: the bridge grows, but no phone widget, route algorithm, journal event or
relay message changes. CarPlay V2 and Android Auto V2 remain separately
versioned even when they draw from the same Dart domain state.

### A2. Coordinate navigation ownership, notifications and cluster data — #684

- Obtain `NavigationManager` from `CarContext` once per active session.
- Register `NavigationManagerCallback` before navigation can begin.
- Call `navigationStarted()` and `navigationEnded()` exactly once for each host
  navigation lifecycle; use loading trip state rather than ending during a
  reroute.
- Publish `Trip` updates for current/following steps and destinations so the
  host can populate the instrument cluster and HUD.
- Maintain the required ongoing navigation notification using
  `CATEGORY_NAVIGATION` and `CarAppExtender`, with bounded update cadence and no
  irrelevant alerts.
- On `onStopNavigation`, immediately stop trip updates, notifications and voice,
  tell Dart to cancel route guidance, and keep ride recording/group membership.

Exit gate: state-machine tests cover start, repeated updates, reroute, host
pre-emption, user cancellation, arrival, disconnect and restoration without a
duplicate start/end or lost ride.

Implemented in #684: the session-retained coordinator registers the host callback before
guidance, balances every navigation start/end, publishes typed V2 trip data and the bounded
ongoing navigation notification, and suppresses stale reacquisition after host pre-emption.
The automated exit gate is covered; DHU/physical rail, cluster and ownership evidence remains
in #703.

### A3. Handle voice/external navigation requests and test-drive mode — #685

- Declare the documented navigation intent filters on the phone activity.
- Parse supported navigation URI/intent formats in both
  `Session.onCreateScreen(intent)` and `Session.onNewIntent(intent)`.
- Resolve an external destination into the same route planning/preview domain
  used by in-app search; do not start recording until the user confirms.
- Support Gemini and Google Assistant through the standard navigation contract,
  not a vendor-specific private integration.
- Implement `NavigationManagerCallback.onAutoDriveEnabled` and generate a
  deterministic simulated trip to the selected destination until the Session is
  destroyed.

Impact: Android Auto can be opened directly with a destination. The ordinary
phone deep-link planner remains unchanged, while intent parsing becomes shared,
tested domain input rather than car-service string handling.

Implemented in #685: `ACTION_NAVIGATE` requests using the documented `geo` contract are
parsed on initial and subsequent Session intents, exact coordinates or bounded search results
are shown for explicit selection, and the existing phone planner receives the confirmed place.
The review-only auto-drive callback advances deterministic trip metadata at 15 m/s and never
creates a location fix or journal event. Voice/DHU/physical evidence remains in #703.

### A4. Publish accurate manoeuvres and estimates — #687

- Map the shared manoeuvre enum to Android `Maneuver` values for left/right,
  slight/sharp, fork, merge, U-turn, depart, arrive and traffic-side-aware
  roundabouts.
- Populate road, junction/lane images only where permitted, current and
  following `Step`, remaining distance/time and destination estimate.
- Use an explicit unknown fallback with honest text; never claim
  `TYPE_STRAIGHT` for an unclassified turn.
- Update the same typed data in the NavigationTemplate, notification and cluster
  trip so they cannot disagree.

Impact: the host-drawn turn card changes from a generic straight arrow to the
real manoeuvre. The phone instruction wording and routing algorithm stay intact.

Implemented in #687: the current and following host steps now share one typed
mapper for turns, ramps, forks, merges, lane choices, traffic-side-aware U-turns
and roundabouts, with an explicit unknown fallback. The template and
`NavigationManager` trip consume those same steps, and parameterized native
tests protect every symbol family. DHU/physical evidence remains in #703.

### A5. Make the surface map-only and safe-area aware — #686

- Remove `Waiting for the phone` and ride-state text from
  `ProjectedMapRenderer`; put loading/errors in host template components.
- Persist the latest visible and stable rectangles supplied by the host and pass
  them to camera fitting.
- Keep the local rider, relevant route ahead and group bikes inside the usable
  bounds with tested margin on compact, standard and ultrawide hosts.
- Keep all interactive controls in Car App Library templates/action strips.
- Bound invalidation and rendering so route updates remain smooth without
  prohibited decorative animation.

Impact: loading or disconnected states move from the canvas into host-styled
messages. Route and rider geometry becomes less likely to sit underneath the
turn card, action strip or display cutout.

### A6. Add an offline-capable road basemap — #701

- Timebox a renderer spike comparing a supported native MapLibre-to-Surface path
  with a deterministic Canvas tile compositor. Select the option that can share
  the phone's approved style/tile cache, render offline, and stay within the
  measured frame/memory budget.
- Draw roads, junctions and labels beneath the route, ridden/remaining split,
  local rider, valid group locations and permitted drive-relevant annotations.
- Never draw cards, legends, free text or controls on the map surface.
- Retain a simple deterministic map fallback when a style/tile fails; do not
  allow a blank or black navigation screen.
- Reject implausible location jumps before camera, route progress, recording or
  heat-map projection so no straight bridge is invented between distant fixes.

Impact: Android Auto gains the largest visual and resource change in this plan.
It becomes genuinely useful at junctions, but adds native rendering, cache,
memory, thermal and offline-recovery responsibilities. The renderer choice must
be made from a working spike, not assumed from the phone's Flutter MapLibre view.

### A7. Follow host appearance and prove contrast — #689

- Derive the projected map palette from the current car host configuration and
  redraw when the host switches day/night mode.
- Keep phone theme preference independent from the projected safety mode.
- Validate road/label/route/rider/hazard contrast with and without the heat map.
- Reassess TH-1 and light/dark host-component theming before any move to Car App
  Library 1.9 or later.

Impact: the Android Auto map can change mode independently of the phone. Stored
phone preferences and screenshots remain unchanged.

### A8. Make voice guidance a correct Android Auto audio citizen — #702

- Apply `USAGE_ASSISTANCE_NAVIGATION_GUIDANCE` and transient-may-duck focus to
  both natural and system-TTS output.
- Acquire focus only for an imminent prompt and release it on completion,
  cancellation or host navigation loss.
- Serialize natural/fallback ownership so a timeout cannot double-speak.
- Stop all queued prompts on `onStopNavigation`; only explicitly starting this
  app's navigation can resume them.

Impact: Android phone audio behavior changes because the same speech engines are
used with and without Android Auto. Run phone-only Bluetooth/intercom regressions
as well as head-unit radio/music/call/Assistant tests.

### A9. Remove unsafe handoffs and dead ends — #688

- Replace shared iPhone/CarPlay strings with platform-specific messages.
- Include Google's safe-when-parked wording whenever action on the phone is
  unavoidable.
- Hide projected actions whose prerequisites cannot be completed while driving.
- Keep search, prepared-ride start, free roam and the bounded group view within
  the five-screen limit.

Impact: only error/setup wording and availability change. Core actions remain,
but an unavailable action may disappear instead of leading to a phone prompt.

### A10. Validate Tier 2 and release to closed testers — #703

- Run all contract, template, renderer and state-machine tests, Android lint, and
  a release-equivalent bundle build.
- Measure app-specific button response under two seconds and launch/content
  readiness under ten seconds.
- Exercise all applicable quality criteria in compact, standard and ultrawide
  DHU configurations, day/night, touch/rotary, parked/driving, and cluster
  emulation.
- Repeat on a physical Android Auto phone/head unit with the phone locked,
  another navigation app, radio/music/calls, network loss, UK and France routes,
  solo/group/free-roam recording, reconnect and process recreation.
- Verify Android Auto form-factor enrollment, accurate Play listing claims,
  closed-track targeting and completed car-app review before saying the build is
  available to testers.

Exit gate: every applicable Tier 2 row has dated evidence and no required row is
FAIL, PARTIAL or UNVERIFIED. Do not let a car-app review hold an unrelated urgent
phone release; Google recommends a separate release when necessary.

### A11. Add a cluster map only after baseline approval — #704

- Treat mandatory next-turn metadata in #684 separately from optional Tier 1
  map rendering.
- Render map tiles only on supported cluster displays; no group panels, weather,
  controls or other non-map UI.
- Validate first with DHU secondary-cluster emulation, then supported hardware.
- Do not advertise the feature until evidence exists.

## CarPlay view-by-view impact assessment

| Current CarPlay element | Compliant target | Functional impact |
|---|---|---|
| MapLibre basemap, route and rider markers | Retained as the only base-view content. | Core map, group positions and offline tile behavior remain. More of the route is visible. |
| Heat map | Retained only as a low-contrast cartographic layer beneath roads/labels; otherwise off in CarPlay. | May look subtler than the phone heat map to protect road legibility. |
| Custom guidance card | Apple turn card from `CPManeuver`. | Visual style and placement become vehicle-controlled; cluster/HUD and background notification support begin working. |
| Custom route ETA/progress card | Apple trip-estimate panel; next waypoint can remain in Ride status. | Less bespoke information at once, but ETA/distance are consistent with CarPlay and available outside the foreground app. |
| Group mini-map | Removed. Rider markers remain on the main map; bounded group details move to Ride. | Loses the simultaneous overview inset. Gains a larger unobstructed navigation map. |
| Persistent TEC badge | Move to Ride status; use a system alert only for a material, time-sensitive safety state. | TEC state is one action away rather than permanently visible. This is the largest group-coordination visibility trade-off. |
| Speed-limit and current-speed badge | Remove from center-display base view. Reintroduce only through a permitted cluster/vehicle API where available. | CarPlay no longer duplicates the vehicle speedometer. The phone retains its display. France no longer receives a false mph-only presentation. |
| App-drawn compass | Remove; use map orientation and supported system panning/rotation behavior. | Less chrome; heading remains visible through the map. |
| App-drawn clock | Remove; rely on CarPlay/vehicle system time. | No loss of unique ride functionality. |
| FOLLOW button | System Recenter `CPMapButton`. | Same outcome with CarPlay-native placement and accessibility. |
| ALERT/SOS button | System navigation-bar `CPBarButton` plus confirmation alert. | Capability retained; visual style becomes system-controlled. |
| REPORT button | System navigation-bar `CPBarButton` opening a bounded action template. | Capability retained without consuming a map-operation button. |
| LEAVE button | Move to Ride list or context navigation-bar action with destructive confirmation. | One additional tap, but reduced accidental activation. |
| Ride hamburger/list | Retained as a `CPBarButton` + `CPListTemplate`. | Becomes the home for secondary route/group/TEC information. |
| Search and destination action sheet | Search followed by Apple `CPTrip` preview and route choice. | Adds an explicit, safer preview/Go step; prevents route selection from creating a ride prematurely. |
| Create group ride from CarPlay | Recommended removal; start a prepared group ride instead. | Group leaders prepare and share the ride on the phone while parked. Solo route/free roam remain available from CarPlay. |
| Free roam | Retained using system controls, with no navigation session. | Recording continues exactly as today; Apple turn/ETA panels remain absent because no route exists. |
| Marker/drop-off card presented as a turn | Move to Ride status or a permitted time-sensitive alert. | Road manoeuvres remain trustworthy; group instructions no longer masquerade as navigation turns. |
| End-of-ride state | Finish/cancel navigation panel, keep ride summary on phone/Ride list. | Arrival does not silently stop recording; explicit ride end remains required. |
| CarPlay Dashboard | New minimal secondary map. | Better visibility when another CarPlay app is foregrounded, with additional memory/rendering cost. |

## Android Auto view-by-view impact assessment

| Current Android Auto element | Compliant target | Functional impact |
|---|---|---|
| Flat dark/light ground | Offline-capable roads, junctions and labels with a deterministic fallback. | Navigation becomes understandable at a glance; native rendering and cache costs increase. |
| Orange/grey route lines | Retained above the basemap, using validated day/night contrast. | Route meaning remains familiar while road context improves. |
| Local and group rider dots | Retained as map annotations, filtered to valid real fixes and fitted inside safe bounds. | Core group coordination remains; implausible jumps no longer distort the map or heat map. |
| Canvas status text | Removed from the surface; host template message/loading state. | Same information, host-styled and compliant with the map-only rule. |
| Generic straight arrow | Typed current and following `Step`/`Maneuver`. | Correct left/right/fork/roundabout/arrival symbols reach the turn card, notification and cluster. |
| Destination estimate | Retained using `TravelEstimate`, fed by typed route state. | No intended layout loss; state remains consistent after reconnect. |
| Where to? search | Retained; external intents and Assistant/Gemini enter the same destination flow. | Faster hands-free entry and interoperability without duplicating routing logic. |
| Start ride / Ride actions | Retained when available; unavailable setup actions are hidden or use safe parked wording. | Fewer dead ends, with some setup moved explicitly to pre-drive. |
| Group action/list | Retained as a bounded host-owned list. | No always-visible group card; map markers remain the glanceable group view. |
| Route alerts | Use `NavigationTemplate` alerts or relevant navigation notification behavior. | Alerts remain in context and cannot become arbitrary canvas UI. |
| Navigation notification | New ongoing `CATEGORY_NAVIGATION` notification while guidance is owned by this app. | Required phone/rail presence appears only during active guidance. |
| Cluster | Required next-turn metadata first; optional map later. | Turn information becomes available broadly without making Tier 1 hardware a release dependency. |
| Free roam | Retained with ride recording and no active navigation ownership. | No turn card, notification or cluster route is invented for a route-less ride. |
| End directions | Stops projected guidance/notification/voice only. | The ride continues recording until explicitly ended or left. |

## Cross-platform and phone impact

| Area | Expected impact | Protection |
|---|---|---|
| Phone map and ride views | No intended layout change. Projected route creation becomes preview-first/confirm-first. | Keep phone widgets and routes on existing code paths; add focused platform-origin tests. |
| Ride recording | Must continue through navigation cancellation, arrival, disconnect and free roam. | Separate navigation state from ride lifecycle and add durable-event count assertions. |
| Group coordination | Transport and journal stay unchanged. Persistent CarPlay badges become a list/alert presentation; Android keeps markers and a bounded list. | Test that projection throttling never throttles journal/relay data itself. |
| Projection bridge | Two typed native payloads add schema/versioning work. | Share immutable domain inputs and fixtures, not platform lifecycle APIs; keep V1 compatibility until both migrations finish. |
| Spoken guidance on phones | iOS session timing/mixing and Android focus classification change. | Use platform coordinators deliberately and run non-projected Bluetooth/intercom regressions. |
| Map downloads/cache | CarPlay Dashboard adds a renderer and Android Auto gains a road renderer. | Reuse approved style/tile data where supported, bound update rates, keep fallbacks, and measure memory/network/thermal use. |
| Test suite | Several current layout tests encode behavior that must be removed. | Replace them with compliance structure, state-machine, template and multi-display tests rather than simply deleting coverage. |
| iOS release/signing | Dashboard scene adds configuration but does not change the approved bundle ID or remove entitlements. | Re-run profile and exported-app entitlement checks; do not enable automatic signing. |
| Android release cadence | Car-app updates can enter additional Play review and hold the submitted bundle. | Keep car changes behind a tester flag until the compliance gate; use a separate phone release if an urgent unrelated fix must bypass car review. |

## Principal risks and mitigations

| Risk | Severity | Mitigation |
|---|---|---|
| Restoring `CPNavigationSession` reintroduces prior CarPlay crashes. | High | Keep generation guards, isolate coordinator state, never call templates before root completion, and test delayed callbacks/disconnects. |
| CarPlay cancellation accidentally ends or stops recording a ride. | High | Separate state machines; add tests asserting recording and the ride journal continue after every navigation-only cancel. |
| Removing persistent TEC/group UI makes the product less useful. | High | Keep riders on the main map, make Ride status one tap away, and reserve system alerts for material safety changes. Validate with group testers before deleting the legacy path. |
| Shared bridge changes break Android Auto. | High | Add a versioned iOS-only payload and run Android parser/native tests on every bridge change. |
| Natural/system voice paths fight for the audio session or double-speak. | High | One native audio coordinator, serialized prompt ownership, prompt-style handling and cancellation tests. |
| Dashboard doubles map memory or tile work. | Medium | Minimal layers, reduced updates, cache reuse, instrumentation and a kill switch until physical validation. |
| Apple rejects group actions as outside navigation use. | Medium | Keep secondary actions in approved templates, remove new group creation from CarPlay, and explain the driving-safety purpose in review notes. |
| System templates reduce visual parity with the phone. | Certain | Treat platform consistency and safe glanceability as the design goal; keep brand color only where Apple allows it. |
| Android's new basemap stutters, overheats or blanks on a low-end phone. | High | Choose the renderer from a measured spike, cap updates, preserve a deterministic fallback and test compact/ultrawide DHU surfaces. |
| Android navigation ownership is lost but voice/notifications continue. | High | Centralize `NavigationManagerCallback`, audio, notification and cluster teardown in one idempotent coordinator. |
| Platform payloads drift or one migration breaks the other. | High | Separate versioned payloads, shared domain fixtures, decoder compatibility tests and no removal of V1 until both adapters are live. |
| Play car-app review delays daily phone tester builds. | High | Batch Android Auto submissions, keep release evidence ready, and publish urgent unrelated phone changes in a separate release when required. |
| Host layout differences obscure the rider or group. | Medium | Treat visible/stable areas as camera inputs and test compact, portrait, widescreen and ultrawide configurations before rollout. |

## Definition of done

Projected navigation compliance is complete only when:

- all non-optional CarPlay FAIL/PARTIAL items are PASS and all baseline
  UNVERIFIED items have recorded evidence;
- all applicable Android Auto Tier 2 criteria are PASS with dated DHU or
  physical-head-unit evidence;
- routed solo and prepared-group rides, plus route-less free roam, record
  continuously through all phone and projected lifecycle events;
- both custom surfaces contain only map content;
- Apple owns CarPlay trip preview, manoeuvres, estimates, alerts and controls;
- Android `NavigationManager` owns navigation arbitration, notification and
  cluster metadata, with accurate host-owned turns and estimates;
- France shows metric values and correct traffic/roundabout metadata;
- the Android Auto map contains readable offline-capable road/junction context;
- every phone view retains its existing behavior except the deliberate
  cross-platform audio-session corrections;
- signed Profile and TestFlight archives contain both approved CarPlay
  entitlements;
- the Android bundle is enrolled for Android Auto, passes the car-app review and
  reaches the intended closed-testing group; and
- the legacy CarPlay UI and both temporary V2 switches are removed before
  production.

## Authoritative sources

- [Android car app quality](https://developer.android.com/docs/quality-guidelines/car-app-quality)
- [Build a navigation app](https://developer.android.com/training/cars/apps/navigation)
- [Test using the Desktop Head Unit](https://developer.android.com/training/cars/testing/dhu)
- [CarPlay Developer Guide (June 2026)](https://developer.apple.com/carplay/documentation/CarPlay-App-Programming-Guide.pdf)
- [CarPlay Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/carplay/)
