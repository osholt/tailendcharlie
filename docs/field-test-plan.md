# Phase 0 nearby-relay field test

## Objective

Determine what Tail End Charlie can honestly promise when iOS and Android phones move
through a motorcycle group with locked screens and no mobile data.

Ride Lab can rehearse route progress, TEC gaps, hazards and off-course alerts
before this test, but synthetic rides are not evidence for radio, background,
battery or real-GPS pass gates.

## Reference matrix

Use at least:

- two supported iPhone generations on the oldest and newest supported iOS;
- one current Google/Samsung Android phone;
- one Android phone with aggressive battery management; and
- a mix of jacket pocket, tank mount, and top-box placement.

Record model, OS, battery health, app state, screen state, placement, weather,
and whether Wi-Fi/Bluetooth were enabled. Do not record a public precise route.
Identify a phone by model and OS version only; a UDID or serial number must
never be committed.

### Hardware actually available (31 July 2026)

| Class required | Device held | State |
| --- | --- | --- |
| Newest supported iOS | iPhone 15 Pro (`iPhone16,1`), iOS 26.5.2 | Paired and reachable |
| Oldest supported iOS | iPhone SE 3rd generation (`iPhone14,6`), iOS 26.1 | Connected, charged, Developer Mode enabled |
| Current Google/Samsung Android | **none held** | Scheduled: test group, early August 2026 |
| Aggressive battery management Android | **none held** | Scheduled: test group, early August 2026 |

Two iPhones in hand, no Android phone. Android coverage depends on a session with
the tester group rather than on owned hardware, so the Android steps are scheduled
work with a dependency on other people's phones and other people's time — plan for
one pass, not an iterative loop.

Both iPhones are in the `Tail End Charlie CarPlay Navigation Development` profile,
which expires 2027-07-29, so the device-evaluation path in
[build-and-run.md](build-and-run.md) is open for both.

The relay is deployed and live at `relay.tailendcharlie.app`. Rule 0 of
[build-and-run.md](build-and-run.md) still applies: confirm the deployed commit
matches any build being installed before concluding an app-side fix did not work.
The deployed capability set matches this tree, but a capability list is not a
commit.

The iOS deployment target is 16.0, so the "oldest supported iOS" leg is **not**
covered either: both phones run iOS 26.x. Nothing here exercises iOS 16, 17 or
18, and no evidence from this hardware supports a claim about them.

### What this hardware can and cannot evidence

**Runnable now, on iPhone↔iPhone only:** steps 1 (iPhone↔iPhone pairing only),
3, 4, 5, 6, 8, 8a (iOS↔iOS only), 8b, 9, 10, 11, 13, 14, 15 (iOS only), 16
(iOS only), 17, 18, 20 and 21.

**Blocked for want of an Android phone:** step 1's Android↔Android,
Android→iPhone and iPhone→Android pairings, step 2 in full (it repeats every
cross-platform pairing with mobile data disabled), step 7's mixed-transport
convergence, step 12's reduced-capability peer, and the Android half of steps
15 and 16.

**Blocked on other issues, not hardware:** step 19 needs a licensed traffic
provider (#277) and step 18 needs an operator-owned map style (#274).

Two consequences worth stating plainly, because they are the difference between
a completed gate and a partial one:

- The **cross-platform premise is untested**. The objective above is about "iOS
  and Android phones" moving through a group. On this hardware that sentence
  cannot be evidenced at all.
- #132's evidence is specifically owed on a **mixed-platform pair**, run both
  ways round. Step 8b's "swap the roles - the SE leads" was written for an
  iOS/Android pair. An iPhone-to-iPhone run is worth doing and is not that
  evidence.

Acquiring one current Android phone and one with aggressive battery management
is therefore a prerequisite for closing #268, and for the Android half of #269.

### What the Android emulator substitutes for, and what it does not

An Android emulator is available and already configured for this project: AVD
`tailendcharlie_test`, a Pixel 9 Pro on API 34 (`google_apis_playstore`,
`arm64-v8a`, `hw.gps=yes`), plus `tailendcharlie_auto_clean` for Android Auto.

The repository already draws the correct line and it is worth keeping.
[nearby-relay.md:111](nearby-relay.md#L111) records an Android 14 emulator run on
2026-07-25 that confirmed Bluetooth, BLE and Wi-Fi LAN advertising plus BLE and
Wi-Fi LAN discovery — that is evidence about the **permission and API contract**,
which the emulator can give. [nearby-relay.md:116](nearby-relay.md#L116) then
requires physical devices for the radio gate. Both statements are right.

**The emulator is real evidence for the internet-relay transport.** The relay path
is HTTPS, the emulator has full networking, and the code path is identical to a
phone's. An iPhone paired with an emulator through a relay genuinely evidences:

- step 8b in full — idle-device delivery, "both phones awake with the map open
  and both stationary on a desk". An idle emulator is a perfectly valid phone
  with nothing to send, which is the whole point of that test;
- the internet-only leg of step 8a, though not its nearby-only or mixed legs;
- steps 9 (duplicate delivery, restart, reconnect), 10 (leave/rejoin, ghost
  riders), 11 (route publish/replace/clear convergence) and 12 (old
  protocol/capability client);
- the clock-skew case in 8b step 5, which needs no radio at all.

That recovers most of the evidence owed on #99, #132 and #134 — a correction to
the note on #268, which described #132's evidence as needing a physical
mixed-platform pair. For 8b specifically it does not.

**Also emulator-testable:** Android UI and layout in both orientations and both
map styles (#29, #104, #125, #142, #143, #172 — though a black-`SurfaceView`
fault may not reproduce through the host GPU translation layer, so a reproduction
is informative and a non-reproduction proves nothing); stock Doze and
foreground-service survival via `adb shell dumpsys deviceidle force-idle` and
standby buckets (#205, for stock AOSP behaviour only); App Links verification and
deep-link launches via `adb shell pm get-app-links` and `am start` (#275); and
navigation-instruction and route-progress logic under mock-location playback,
which Ride Lab already covers ([ride-simulator.md](ride-simulator.md)).

**The emulator is not evidence for, and cannot be made to be:**

- any peer-to-peer radio between two devices — no BT or Wi-Fi Direct path exists
  between an emulator and an iPhone, so steps 1 (beyond iPhone↔iPhone), 2, 7's
  nearby and mixed transports, 13's A→B→C carry and 14's pass-by at speed all
  still need two physical phones;
- battery, at all. There is no battery. The Android half of #269 is unrunnable,
  and the aggressive-battery-management case is OEM behaviour by definition;
- real GPS. Mock locations arrive with perfect accuracy, so the multipath and
  accuracy-rejection behaviour behind `maxAcceptedAccuracyMeters = 75` — the
  urban-canyon and parallel-road cases in #270 — cannot be exercised;
- locked-screen radio behaviour, physical placement, or thermal behaviour.

**Practical setup for the cross-platform relay tests.** They need a reachable
relay, which is #273. Until one is deployed, the tailnet-only field-test host in
[server-runbook.md:190](server-runbook.md#L190) is the intended private path; an
emulator can alternatively reach a relay on the host Mac directly at `10.0.2.2`
while the iPhone uses the Mac's LAN or tailnet address.

**Recording rule.** An emulator result is labelled as such in the results record.
It never satisfies a radio, battery or real-GPS pass gate, and a step passed on an
emulator is not a step passed — per [AGENTS.md:61](../AGENTS.md#L61).

### Driving the sequence instead of tapping it

A build can carry a gated HTTP surface that another machine drives — create a
ride, join, start, report a hazard, inject a position, read the roster — so the
step-8b delays are measured rather than estimated. See
[test-control-api.md](test-control-api.md); `tools/field-test-8b.sh` runs 8b end
to end.

This matters most for 8b, because its assertions are about phones sitting
**untouched**, and picking one up to read it ends the condition under test. The
field report behind #132 was "it started working when I touched it" — which is the
defect rather than a recovery, and is not something a person holding the phone can
tell apart.

The recording rule above applies unchanged. Driving exercises the app's own code
paths, so it is evidence for delivery, convergence and roster agreement, and is
**not** evidence for radio, battery or real-GPS accuracy. Label a driven result as
driven.

## Test sequence

1. Bench discovery and authentication across Android↔Android, iPhone↔iPhone,
   Android→iPhone and iPhone→Android pairings.
2. Repeat every cross-platform pairing with mobile data disabled, Wi-Fi not
   associated to a common access point, and no personal hotspot.
3. Exchange 1 KB priority events for 30 minutes.
4. Lock every screen and repeat.
5. Background the app without force-quitting and repeat.
6. Separate peers, create events, reunite them, and verify convergence.
7. Join all phones before departure, opt in to foreground location, and verify
   that each fresh latest position converges over internet-only, nearby-only
   and mixed transport. Move a phone twice and confirm the first point is
   replaced rather than drawn as a trace. Stop reporting on one phone and
   confirm the others show it transition live -> ageing -> stale in wording as
   well as colour, and never as a current position.
8. Start once from the lead, then verify early joiners begin from the same start
   time; add a late joiner and verify it becomes active without restarting.
8a. Live presence across the whole ride (issue #99), on a two-device
    mixed-platform pair, run both ways round (iOS leader/Android joiner and the
    reverse). In each of join-before-start, join-after-start,
    rejoin-after-app-restart and rejoin-after-network-loss, verify both riders'
    positions are visible and advancing within one poll interval, that the
    leader's roster and map show the joiner with no action on either device, and
    that nobody disappears or is duplicated across the start transition. Then
    run one device with a deliberately reduced capability set and confirm the
    other names the limitation instead of showing an unexplained gap.
8b. Idle-device delivery (issue #132), the sequence that produced the field
    failure and the one this evidence is still owed for. Both phones awake with
    the map open and both **stationary on a desk**, so neither generates new GPS
    fixes and neither has anything queued to send:
    1. Leader creates the ride, follower joins, leader starts it.
    2. Leave both phones untouched for two minutes. Confirm each shows the other
       as active with a position, and that the rider count matches the number of
       markers on both the main map and the mini-map.
    3. Send a hazard report from the follower only. Confirm the leader shows it
       without the leader having sent anything of its own first, and note the
       delay. Then repeat in the other direction.
    4. Swap the roles - the SE leads - and repeat 1 to 3. The result must be
       identical: the failure must not follow either the role or the device.
    5. On one phone, turn off automatic date and time and set the clock five
       minutes wrong, in each direction. Confirm the other phone still shows that
       rider live and advancing, names the clock difference in plain language,
       and never shows them as inactive while they are reporting.
    Record which phone was which, the build number, and the observed delay for
    each direction. An idle phone receiving nothing until it happens to send
    something is the defect; treat "it started working when I touched it" as a
    failure, not a recovery.
9. Repeat the start with one phone offline, duplicate delivery, app restart,
   reconnect, and a pre-start lead-role handover.
10. Explicitly leave on one phone, verify it disappears from the current roster
    without inflating alerts, then rejoin the same ride and verify one identity.
11. Publish, replace and clear a route from the lead; verify early, late,
    offline and restarted iOS/Android clients converge without showing a route
    from another ride. Repeat after a signed lead-role handover.
12. Test an intentionally old protocol/capability client and verify that it is
    blocked or degraded before incompatible ride state is accepted.
13. Carry an event A -> B -> C where A and C never meet.
14. Ride/walk past at 20, 40, and 60 mph using safe test conditions.
15. Run four hours with GPS sampling and radio activity to measure battery use.
16. Force-quit each platform separately and document loss/recovery honestly.
17. Run the watcher matrix in `observer-access.md`. For **Just me**, cover
    fresh, delayed and offline states; lock/background/force-quit; signal loss;
    revocation; expiry; ride end; and four-hour battery impact. For **Whole
    group**, use at least three mixed-platform phones and verify the bounded
    roster, independent per-rider freshness, route outline, map re-centre,
    grant expiry/revocation, and that a former leader stops publishing after
    role handover. Confirm neither watcher appears in the ride roster or can
    access participant controls.
18. Fetch the deployed observer MapLibre style and recursively inspect every
    source tile URL, sprite URL, glyph URL and imported style. Confirm each is
    HTTPS on the ride-relay host, then verify the observer-specific CSP blocks
    a fixture that points any of them at a third party. If the operator map
    archive and style are absent, verify the page shows bounded coordinates
    without making a tile request and record the observer map as unavailable.
19. Stage one route-intersecting closure and one nearby unrelated incident
    through the licensed traffic provider. Verify only the intersecting
    incident appears, its source/freshness/expiry remain visible, and a provider
    outage retains the last useful result only until expiry. Repeat with a
    follower phone and confirm only the leader fetches provider data while the
    signed hazard converges to the follower. On the leader, review an
    alternative, cancel it once, dismiss it once, and finally accept it. Verify
    cancellation and provider failure leave the current route unchanged,
    dismissal suppresses the same incident until expiry, and acceptance
    publishes exactly one higher route revision that converges to the follower.

20. Ride roughly 1 km off the imported GPX and back, on the leader phone and on
    a follower phone, and repeat with no route imported at all. Verify each
    rider's own trail and the leader's trail keep drawing throughout the
    excursion, on every device, with no gap at the on-route/off-route/rejoined
    transitions. Restart the app mid-ride and confirm the leader's trail is
    still there.
21. Mount a phone in daylight at maximum brightness, in the dark map style, and
    photograph the screen through a tinted visor. The photograph is the evidence
    for route legibility; the measured contrast ratios in `maps-and-gpx.md` are
    not. Repeat in the light map style, and confirm the planned route, travelled
    trail, leader trail and any off-route trail are still told apart in a
    greyscale copy of the same photograph.

## Pass gates

- 95% of priority events reach an in-range peer within 10 seconds while the app
  is in a supported active-ride state.
- No duplicate marker count after 100 event replays.
- Queued events converge without user repair after peers reunite.
- No pre-start trace is retained; latest snapshots expire or clear at start, and
  every early/late/reconnected phone uses the same authoritative ride start.
  Live presence is continuous across that start: a rider visible before it stays
  visible after it, with one identity.
- A rider who joins an already-started ride is visible to everyone within one
  poll interval, and sees them, with no restart, GPS toggle or alert.
- A phone with nothing to send still receives. Delivery to a device never
  depends on that device having an event of its own to upload, and an idle phone
  is never behind by more than one poll interval plus one retry.
- The rider count equals the number of drawn markers plus the riders whose row
  states why they have no position. There is no rider in the count with neither.
- Two phones whose clocks disagree still show each other as live. A rider is
  never marked inactive while their reports are arriving, and a clock difference
  is named on screen rather than being worked out from a missing marker.
- A position that stops updating is demoted to ageing and then stale in wording
  as well as colour. It is never drawn as current, and never silently deleted -
  where a rider stopped is what the group needs to go back for them.
- Every unavailable live-position channel names its reason on the affected
  phone: capability negotiation, transport failure, permission or an
  incompatible peer.
- Every rider's travelled trail, and the leader's, keep drawing off the planned
  route and with no planned route, and the planned route is legible in a
  daylight photograph through a visor in both map styles.
- Explicit leave/rejoin produces no ghost riders, roster/alert counts match the
  signed current membership, and route publish/replace/clear converges.
- Four-hour screen-off consumption remains within the 45% planning limit.
- The observed iOS limitations are reflected in product wording and onboarding.
- Observer revocation and expiry deny the next refresh, freshness never labels
  a stale point as current, and the page never exposes another rider.
- Live traffic never erases or silently replaces the authoritative route;
  unrelated incidents do not trigger leader action, and provider failure is
  distinguishable from a verified all-clear.
- On a mounted phone, in portrait and landscape on iOS and Android, the upper
  third of the map carries no persistent overlay during an active ride, every
  surface stays readable at a glance, none covers another at the maximum
  simultaneous overlay count, and every target is reachable with gloves.
- At rest, at urban speed and at road speed, in both orientations and both map
  styles, the visible road ahead is materially greater than the road behind, the
  rider's own marker stays visible and clear of chrome, and no camera transition
  snaps as speed changes.
- A gently curving A-road produces no perceptible map rotation; a 90 degree
  junction and a roundabout exit each settle on the correct bearing within about
  two seconds with no overshoot or oscillation; a stationary phone with a noisy
  fix leaves the map still; and the bearing never misrepresents which way the
  rider faces at a junction.
- Plan or simulate BS15 1UJ toward Chippenham along New Cheltenham Road. The two
  mini-roundabouts at OSM nodes 30983542 and 30983544 each appear as a 2nd-exit,
  straight-on instruction 42 m apart; the second is visible before entering the
  first and becomes current after the first is passed.

If the gate fails, retain durable offline queues and opportunistic exchange but
do not market the product as a continuously available mesh.
