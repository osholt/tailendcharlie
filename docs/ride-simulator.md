# Ride Lab simulator

Ride Lab exercises the production navigation and situational-awareness UI
without requiring several phones or physical travel.

## Start a simulation

1. Leave any active ride.
2. Select **Try a simulated ride** on the start screen.
3. Use **Map** to watch the ride or **Ride Lab** to control it.

The bundled 36.2 km Peak District GPX is loaded automatically. Five synthetic
bikes start as a moving group: a lead, three riders, and a Tail End Charlie.
The default 8x time scale completes the loop in a few minutes.

Ride Lab can:

- pause or resume movement and select a 1x, 4x, 8x, or 16x time scale;
- send Alex 220 m off route, exercising alert hysteresis and the magenta
  off-route trail;
- slow Tail End Charlie to exercise the leader distance/time display; and
- inject a synthetic roadworks hazard at the lead bike's current position.

Restart creates a clean simulation ride and resets route progress, events,
alerts, and trails.

## Isolation and limitations

Simulation sessions are explicitly tagged in persisted session metadata. The
active-ride shell does not start device location, the internet relay worker, or
the nearby radio transport for these sessions. Virtual riders still generate
properly signed ride events and use the normal event store, awareness
controller, map overlays, route-deviation detector, and leader status
calculator. Leaving or restarting the simulation deletes its local events.

Map tiles may still be requested from the configured basemap provider. The
simulator validates application behavior, not Bluetooth range, background
execution, real GPS noise, battery use, or cross-platform radio behavior;
those remain field-test requirements.
