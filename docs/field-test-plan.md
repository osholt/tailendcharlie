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
   replaced rather than drawn as a trace; wait 46 seconds and confirm it
   expires.
8. Start once from the lead, then verify early joiners begin from the same start
   time; add a late joiner and verify it becomes active without restarting.
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
17. Run the safety-contact observer matrix in `observer-access.md`: fresh,
    delayed and offline states; lock/background/force-quit; signal loss;
    revocation; expiry; ride end; and four-hour battery impact.
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
- No pre-start trace is retained; latest snapshots expire or clear at start,
  and every early/late/reconnected phone uses the same authoritative ride
  start.
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

If the gate fails, retain durable offline queues and opportunistic exchange but
do not market the product as a continuously available mesh.
