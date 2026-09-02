# CarPlay navigation compliance checklist

This is the release gate for Tail End Charlie's CarPlay navigation surface. It
translates Apple's public requirements into checks against this repository and
records which claims still require the CarPlay Simulator or a physical vehicle.

Audit date: **2 September 2026**

Primary baseline: **CarPlay Developer Guide, 8 June 2026**

Implementation sequencing and the cross-platform impact assessment are in the
[projected navigation compliance plan](./carplay-compliance-implementation-plan.md).
The complete CarPlay backlog is tracked by
[#699](https://github.com/osholt/tailendcharlie/issues/699).

## Status and release decision

**Current decision: not compliant enough to claim production-ready CarPlay
navigation.** Signing and the basic CarPlay scene are present, but the active
ride deliberately bypasses Apple's navigation session and draws guidance,
status, and interactive controls in the map-only base view. Those are direct
conflicts with the navigation-app rules.

Status meanings:

- **PASS** — demonstrated by current code or recorded signing evidence.
- **FAIL** — current code conflicts with an Apple requirement.
- **PARTIAL** — some of the requirement is implemented, but a material part is
  missing.
- **UNVERIFIED** — source inspection is insufficient; simulator, locked-phone,
  or physical-vehicle evidence is required.
- **OPTIONAL** — a supported CarPlay capability that is not part of the baseline
  release gate unless Tail End Charlie claims it.

A checked box means the item currently passes. A box stays unchecked for
**FAIL**, **PARTIAL**, and **UNVERIFIED** items.

## 1. Entitlement, signing, and submission

| Done | ID | Requirement | Status | Tail End Charlie evidence / action |
|---|---|---|---|---|
| [x] | CP-ENT-01 | Apple has approved the Navigation entitlement for the app's real category. | PASS | Navigation approval is recorded as Case-ID 21286533. |
| [x] | CP-ENT-02 | Debug/Profile and Release request `com.apple.developer.carplay-maps`; the App ID and profiles contain the managed capability. | PASS | Both entitlement files request `carplay-maps`; current development and App Store profile evidence is recorded in `docs/release-signing.md`. |
| [x] | CP-ENT-03 | The paired Driving Task capability remains consistent with the declared scene and approved app use. | PASS | Both configurations also request `com.apple.developer.carplay-driving-task`. Do not remove either restricted entitlement independently of the scene declaration. |
| [ ] | CP-ENT-04 | Every candidate archive is signed with the intended App Store profile and the exported app contains the approved entitlements. | UNVERIFIED | Repeat the `codesign` and embedded-profile checks in `docs/release-signing.md` for every release candidate. |
| [ ] | CP-ENT-05 | App Review can exercise the feature, with accurate review notes, live services, a route/demo path, and any required account details. | UNVERIFIED | Prepare a short reviewer script covering route search, route preview, guidance, cancellation, and phone-locked use. |

## 2. Scene and lifecycle

| Done | ID | Requirement | Status | Tail End Charlie evidence / action |
|---|---|---|---|---|
| [x] | CP-SCENE-01 | Declare a `CPTemplateApplicationScene` and handle its window-bearing connect and disconnect callbacks. | PASS | `Info.plist` declares the scene and `CarPlaySceneDelegate` implements both callbacks. |
| [x] | CP-SCENE-02 | Make `CPMapTemplate` the root template for a navigation app. | PASS | `CarPlaySceneDelegate` installs a `CPMapTemplate` through `setRootTemplate`. |
| [ ] | CP-SCENE-03 | Retain the interface controller and map-content window for the whole CarPlay session, then release them on disconnect. | PARTIAL | The delegate retains the map controller but stores `CPInterfaceController` weakly and does not store the `CPWindow`. Align the lifecycle with Apple's startup example. |
| [x] | CP-SCENE-04 | Ignore stale asynchronous template completions and tear down the connected scene safely. | PASS | `CarPlaySceneLifecycle` generation checks guard root installation and disconnect cleanup. |
| [ ] | CP-SCENE-05 | Declare and implement the CarPlay Dashboard navigation scene expected by Apple's navigation-app startup guidance. | FAIL | `Info.plist` has no `CPSupportsDashboardNavigationScene` flag or dashboard scene configuration, and there is no dashboard scene delegate. |
| [ ] | CP-SCENE-06 | Restore an active trip and correct map state after disconnect/reconnect, process suspension, and phone lock. | UNVERIFIED | Exercise a live route through wired and wireless reconnects with the phone locked. |

## 3. Base map, templates, and driver interaction

| Done | ID | Requirement | Status | Tail End Charlie evidence / action |
|---|---|---|---|---|
| [ ] | CP-UI-01 | Use the base view exclusively to draw one map. Do not draw windows, panels, alerts, overlays, or other UI in it. | FAIL | `CarPlayNavigationViewController` adds a TEC badge, speed badge, compass, second mini-map, clock, route-progress panel, guidance panel, and ride-action panel over the MapLibre map. |
| [ ] | CP-UI-02 | Implement every control and overlay with the CarPlay templates and APIs intended for that content. | FAIL | Active-ride guidance and ETA are app-owned views instead of the navigation-session panels. Status can use the existing `CPListTemplate`; hazards should use `CPNavigationAlert` where they concern navigation. |
| [ ] | CP-UI-03 | Do not put directly interactive controls in the base view. | FAIL | `CarPlayRideActionsView` contains custom `UIButton` controls for Follow, Alert, Leave, and Report. Move permitted actions to `CPMapButton`, navigation-bar buttons, alerts, or list templates. |
| [x] | CP-UI-04 | Draw the map across the full base view and resize it for the CarPlay display. | PASS | `MLNMapView` fills the view bounds and uses flexible width and height. |
| [ ] | CP-UI-05 | Observe the host safe area when fitting the route and current location, not merely when positioning app UI. | UNVERIFIED | Add explicit safe-area camera tests for each Apple display preset and host control layout. |
| [ ] | CP-UI-06 | Select light/dark map content from the CarPlay scene's `contentStyle` and react to `contentStyleDidChange`. | FAIL | The renderer prefers a phone-published style and falls back to UIKit traits. It does not use the CarPlay scene content-style callbacks required by the 2026 guide. |
| [ ] | CP-UI-07 | If panning is supported, always provide a `CPMapButton` that enters CarPlay panning mode, including on non-touch vehicles. | FAIL | A `panButton` helper exists but is never installed. Active rides expose no system map buttons and use a custom Follow button instead. |
| [ ] | CP-UI-08 | Restrict touch gestures to map pan, zoom, pitch, and rotation, and support applicable host callbacks. | PARTIAL | Pan callbacks exist. Zoom, pitch, and rotation coverage needs completion and simulator validation; custom base-view buttons must be removed. |
| [ ] | CP-UI-09 | Keep templates within Apple's list, keyboard, hierarchy, and driving-state restrictions. | PARTIAL | Search results and rider rows are bounded and hierarchy is shallow. Verify behavior when `CPSessionConfiguration.limitedUserInterfaces` disables the keyboard or shortens lists. |

## 4. Destination selection and route guidance

| Done | ID | Requirement | Status | Tail End Charlie evidence / action |
|---|---|---|---|---|
| [x] | CP-NAV-01 | Use system templates to select a destination. | PASS | Destination search uses `CPSearchTemplate`, `CPListTemplate`, and a bounded result set. |
| [ ] | CP-NAV-02 | Present selected destinations and routes as `CPTrip` previews, with up to three clear `CPRouteChoice` options and current trip estimates. | FAIL | The selected search result goes through `CPActionSheetTemplate` and immediately asks Flutter to plan; `showTripPreviews` is never called. |
| [ ] | CP-NAV-03 | Start an active `CPNavigationSession` when guidance starts and keep it alive for the trip. | FAIL | `updateNavigationSession` cancels any session, clears it, and returns before the retained Apple navigation code can execute. |
| [ ] | CP-NAV-04 | Maintain at least one accurate upcoming `CPManeuver`, adding a second for rapid turns or lane guidance where useful. | FAIL | No manoeuvres reach CarPlay because the navigation-session path is unreachable. |
| [ ] | CP-NAV-05 | Continuously update significant manoeuvre estimates and overall `CPTrip` estimates through CarPlay APIs. | FAIL | App-owned labels show ETA and distance; `CPNavigationSession.updateEstimates` and `CPMapTemplate.updateEstimates` are not active. |
| [ ] | CP-NAV-06 | Supply light/dark manoeuvre assets, text variants from longest to shortest, and accurate manoeuvre metadata for Dashboard, cluster, and HUD. | FAIL | Dormant code provides one text variant and one image rather than `CPImageSet` variants; no live navigation session publishes metadata. Related: #447. |
| [ ] | CP-NAV-07 | Use `CPNavigationAlert` for real-time navigation feedback and define background-notification behavior. | FAIL | Route/group alerts are placed in custom map UI or generic templates. There is no `CPNavigationAlert` presentation or notification-delegate handling. |
| [ ] | CP-NAV-08 | Immediately stop guidance when CarPlay or the vehicle requests cancellation. | FAIL | `mapTemplateDidCancelNavigation` is not implemented, and the shared route engine is not told to stop when the vehicle starts native guidance. |
| [ ] | CP-NAV-09 | Call the matching navigation-session pause, resume, finish, or cancel API for every route lifecycle transition and reroute. | FAIL | The active CarPlay experience has no live navigation session. The dormant implementation only starts/cancels and does not cover the complete lifecycle. |
| [ ] | CP-NAV-10 | Continue guidance with the phone locked and without requiring the rider to manipulate it. | UNVERIFIED | Run a complete route, reroute, group update, and arrival with the phone locked and screen off. |

## 5. Phone independence and driving suitability

| Done | ID | Requirement | Status | Tail End Charlie evidence / action |
|---|---|---|---|---|
| [ ] | CP-SAFE-01 | Never tell a driver to pick up, unlock, or manipulate the iPhone. | FAIL | `CarPlayStatusTemplate` says `Finish setup on iPhone`, and the shared unavailable reason says to allow location access on the iPhone. Fix is tracked by #688. |
| [ ] | CP-SAFE-02 | Every flow exposed in CarPlay completes in CarPlay; setup that requires the phone happens before driving. | PARTIAL | Search and free roam can start from CarPlay, but prepared/group flows and first-time permission can lead into phone-dependent states. Define which setup is strictly pre-drive and hide unavailable in-drive actions. |
| [x] | CP-SAFE-03 | Keep CarPlay content focused on navigation and tasks that materially help the drive. | PASS | Route guidance, group status, hazards, ride leave, and SOS are driving-related. Keep account management, detailed settings, and route editing off CarPlay. |
| [x] | CP-SAFE-04 | Report actionable errors on CarPlay using a system template. | PASS | `presentCarPlayError` uses `CPAlertTemplate`; remove any phone-manipulation wording from its inputs. |
| [ ] | CP-SAFE-05 | Work without unlocking the iPhone and while protected data is unavailable. | UNVERIFIED | Validate cold connect, reconnect, cached map, route state, and group state with the phone locked before and during the ride. |

## 6. Voice prompts and audio coexistence

| Done | ID | Requirement | Status | Tail End Charlie evidence / action |
|---|---|---|---|---|
| [ ] | CP-AUDIO-01 | Use the playback audio category and voice-prompt mode for spoken guidance. | PARTIAL | The system TTS path uses playback plus `voicePrompt`; the natural-voice player must be verified to set the same mode. |
| [ ] | CP-AUDIO-02 | Use `interruptSpokenAudioAndMixWithOthers` together with `duckOthers`. | FAIL | Both speech paths currently configure `mixWithOthers` plus `duckOthers`, not Apple's required interrupt-spoken-audio option. Related: #450. |
| [ ] | CP-AUDIO-03 | Activate the audio session only when a prompt is ready and deactivate it promptly afterward. | FAIL | System TTS calls `setSharedInstance(true)` during configuration, before a prompt is ready. Prove prompt-scoped activation/deactivation for both speech engines. |
| [ ] | CP-AUDIO-04 | Check `AVAudioSession.promptStyle` immediately before each prompt: silence for `.none`, tone for `.short`, full speech for `.normal`. | FAIL | No prompt-style handling was found. |
| [ ] | CP-AUDIO-05 | Voice prompts coexist with FM radio, music, podcasts/audiobooks, calls, Siri, and other system audio. | UNVERIFIED | Test every audio source on a physical CarPlay head unit, including repeated turns and natural-to-system voice fallback. |

## 7. Geography, units, and map fitness

| Done | ID | Requirement | Status | Tail End Charlie evidence / action |
|---|---|---|---|---|
| [ ] | CP-MAP-01 | The map and routing are appropriate in every supported country. | UNVERIFIED | Validate France and the UK with real routes, roundabouts, road classes, offline tiles, rerouting, and lawful road access. |
| [ ] | CP-MAP-02 | Distance, speed, and speed-limit units follow the ride locale or explicit user setting consistently. | FAIL | Guidance distance supports miles/metric, but `CarPlaySpeedLimitBadge` always converts and labels current speed and mapped limits as mph. This is incorrect in France. |
| [ ] | CP-MAP-03 | Light and dark routes, labels, riders, and hazards remain legible in direct sun and at night. | UNVERIFIED | Check both host modes in the simulator and an actual car; do not approve solely from desktop screenshots. |
| [ ] | CP-MAP-04 | Offline loss and recovery do not blank the map, invent route geometry, or stop guidance. | UNVERIFIED | Drive a cached route through a network-loss interval and confirm map, recording, guidance, and group-state degradation. |

## 8. Optional modern CarPlay capabilities

These do not block the baseline unless the release notes or product page claim
them.

| Done | ID | Capability | Status | Tail End Charlie evidence / action |
|---|---|---|---|---|
| [ ] | CP-OPT-01 | A second map in CarPlay Dashboard. | OPTIONAL | Not implemented. This becomes part of the release gate if Dashboard support is claimed. |
| [ ] | CP-OPT-02 | A second map in an instrument-cluster display. | OPTIONAL | Not implemented; no instrument-cluster scene is declared. |
| [ ] | CP-OPT-03 | Upcoming manoeuvre and lane metadata for vehicle cluster/HUD on iOS 17.4+. | OPTIONAL | Delegate opt-in exists, but the disabled navigation session means there is no live metadata to validate. |
| [ ] | CP-OPT-04 | Destination sharing with the vehicle on iOS 26.4+. | OPTIONAL | Not implemented. |
| [ ] | CP-OPT-05 | Route-segment sharing with the vehicle on iOS 26.4+. | OPTIONAL | Not implemented. |

## 9. Ticket traceability

Every unchecked row has a primary implementation or validation ticket. The
typed projection is a shared prerequisite, not a substitute for the behavior
tickets below.

| Checklist items | Primary ticket | Validation / related work |
|---|---|---|
| CP-ENT-04–05 | [#698](https://github.com/osholt/tailendcharlie/issues/698) | Release archive and App Review gate. |
| CP-SCENE-03, CP-SCENE-05–06 | [#696](https://github.com/osholt/tailendcharlie/issues/696) | Physical/reconnect evidence in #698. |
| CP-UI-01–03, CP-UI-07–09 | [#693](https://github.com/osholt/tailendcharlie/issues/693) | Existing layout context in #442 and #533. |
| CP-UI-05–06 | [#695](https://github.com/osholt/tailendcharlie/issues/695) | Multi-display evidence in #698. |
| CP-NAV-02 | [#691](https://github.com/osholt/tailendcharlie/issues/691) | Existing destination work in #367. |
| CP-NAV-03–10 | [#692](https://github.com/osholt/tailendcharlie/issues/692) | Physical/locked-phone evidence in #698; cluster issues #447/#449. |
| CP-SAFE-01 | [#688](https://github.com/osholt/tailendcharlie/issues/688) | Platform-specific wording. |
| CP-SAFE-02, CP-SAFE-05 | [#694](https://github.com/osholt/tailendcharlie/issues/694) | Locked-phone evidence in #698; prepared rides #328/#441. |
| CP-AUDIO-01–05 | [#450](https://github.com/osholt/tailendcharlie/issues/450) | Expanded compliance acceptance criteria; physical audio evidence in #698. |
| CP-MAP-01–04 | [#695](https://github.com/osholt/tailendcharlie/issues/695) | France/UK/offline evidence in #698; map context #295/#321/#451. |
| CP-OPT-01 | [#696](https://github.com/osholt/tailendcharlie/issues/696) | Becomes required only if Dashboard is claimed. |
| CP-OPT-02–05 | [#697](https://github.com/osholt/tailendcharlie/issues/697) | Post-baseline and availability-gated. |

Architecture prerequisite:
[#690](https://github.com/osholt/tailendcharlie/issues/690). Parent tracker:
[#699](https://github.com/osholt/tailendcharlie/issues/699).

CI validates this table on every mobile change. A checked row must say `PASS`,
an unchecked row must retain ticket traceability, and production candidates run
`python3 tools/projected-navigation-compliance.py --strict`. Closed-testing
builds use the incremental mode so documented gaps can be exercised without
weakening structural, contract or traceability checks.

## 10. Required validation matrix

Record the build number, iOS version, CarPlay host, date, tester, screenshot or
video, and diagnostics reference for every run.

### CarPlay Simulator

- [ ] 748 x 456 at 2x (minimum).
- [ ] 800 x 480 at 2x (standard).
- [ ] 1920 x 720 at 3x (widescreen).
- [ ] 900 x 1200 at 3x (portrait).
- [ ] Light mode and dark mode at every supported shape.
- [ ] Host safe-area changes and control overlays never cover the route, rider,
  next turn, or destination.
- [ ] Non-touch/knob panning mode can be entered and exited.
- [ ] Keyboard and list restrictions while driving leave a usable flow.
- [ ] Navigation metadata inspection shows accurate manoeuvre type, traffic
  side, road, distance, and sequence.
- [ ] App disconnect/reconnect restores exactly one active route and does not
  duplicate prompts or alerts.

### Physical iPhone and vehicle

- [ ] Wired CarPlay, phone unlocked at connection.
- [ ] Wired CarPlay, phone locked at connection and throughout guidance.
- [ ] Wireless CarPlay reconnect after leaving and returning to the bike/car.
- [ ] Start, cancel from CarPlay, cancel because vehicle navigation starts,
  reroute, arrive, and end ride.
- [ ] Network loss and recovery with a previously cached route.
- [ ] Background group updates, route recording, and navigation continue with
  the phone screen off.
- [ ] FM radio, music, podcast/audiobook, phone call, and Siri audio coexistence.
- [ ] Natural voice and system fallback both use the navigation audio channel
  without leaving other audio ducked.
- [ ] UK imperial route and speed presentation.
- [ ] France metric route and speed presentation, right-hand traffic,
  roundabouts, D-roads, motorway junctions, and French road/place labels.
- [ ] Daylight through a visor and night driving remain legible without glare or
  low-contrast roads.
- [ ] SOS, report, leave, and any role prompt are reachable using permitted
  templates and cannot be triggered accidentally.

## 11. Release gate

Do not describe CarPlay navigation as compliant or field validated until:

1. Every non-optional **FAIL** above is fixed and has an automated regression
   test where practical.
2. Every **PARTIAL** item is either completed or explicitly removed from the
   CarPlay surface.
3. Every **UNVERIFIED** baseline item has recorded evidence from the required
   simulator or physical-host test.
4. The exported App Store archive passes the entitlement/profile inspection.
5. The App Review notes accurately explain route preparation, phone-lock
   behavior, offline behavior, group data, SOS/reporting, and how the reviewer
   can exercise CarPlay without manipulating the iPhone while driving.

## Sources

- [CarPlay Developer Guide (June 2026)](https://developer.apple.com/carplay/documentation/CarPlay-App-Programming-Guide.pdf)
- [CarPlay Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/carplay/)
- [Integrating CarPlay with your navigation app](https://developer.apple.com/documentation/CarPlay/integrating-carplay-with-your-navigation-app)
- [`CPNavigationSession`](https://developer.apple.com/documentation/carplay/cpnavigationsession)
- [Requesting CarPlay entitlements](https://developer.apple.com/documentation/carplay/requesting-carplay-entitlements)
- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
