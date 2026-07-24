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
7. Join all phones before departure and verify that the roster converges while
   no coordinate or route trace appears on any phone.
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

## Pass gates

- 95% of priority events reach an in-range peer within 10 seconds while the app
  is in a supported active-ride state.
- No duplicate marker count after 100 event replays.
- Queued events converge without user repair after peers reunite.
- No pre-start trace is retained, and every early/late/reconnected phone uses the
  same authoritative ride start.
- Explicit leave/rejoin produces no ghost riders, roster/alert counts match the
  signed current membership, and route publish/replace/clear converges.
- Four-hour screen-off consumption remains within the 45% planning limit.
- The observed iOS limitations are reflected in product wording and onboarding.
- Observer revocation and expiry deny the next refresh, freshness never labels
  a stale point as current, and the page never exposes another rider.

If the gate fails, retain durable offline queues and opportunistic exchange but
do not market the product as a continuously available mesh.
