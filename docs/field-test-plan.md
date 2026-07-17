# Phase 0 nearby-relay field test

## Objective

Determine what Ride Relay can honestly promise when iOS and Android phones move
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
7. Carry an event A -> B -> C where A and C never meet.
8. Ride/walk past at 20, 40, and 60 mph using safe test conditions.
9. Run four hours with GPS sampling and radio activity to measure battery use.
10. Force-quit each platform separately and document loss/recovery honestly.

## Pass gates

- 95% of priority events reach an in-range peer within 10 seconds while the app
  is in a supported active-ride state.
- No duplicate marker count after 100 event replays.
- Queued events converge without user repair after peers reunite.
- Four-hour screen-off consumption remains within the 45% planning limit.
- The observed iOS limitations are reflected in product wording and onboarding.

If the gate fails, retain durable offline queues and opportunistic exchange but
do not market the product as a continuously available mesh.
