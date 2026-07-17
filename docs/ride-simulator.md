# Ride Lab simulator

Ride Lab exercises the production navigation and situational-awareness UI
without requiring several phones or physical travel.

## Start a simulation

1. Leave any active ride.
2. Select **Try a simulated ride** on the start screen.
3. Use **Map** to watch the ride or **Ride Lab** to control it.

The bundled 17.5 km GPX from the King's Oak Academy car park to the Cross Hands
Hotel car park is loaded automatically. Its 484-point track follows the routed
roads through Kingswood, Pucklechurch and Old Sodbury. Five synthetic bikes
start as a moving group: a lead, three riders, and a Tail End Charlie.

Ride Lab can:

- pause or resume movement and select a 1x, 4x, 8x, or 16x time scale;
- switch the local viewpoint between leader, follower, and Tail End Charlie;
- enter marker mode, stop the local bike, and exercise authenticated rider/TEC
  passage counting as the virtual group passes;
- send Alex 220 m off route, exercising alert hysteresis and the magenta
  off-route trail;
- slow Tail End Charlie to exercise the leader distance/time display; and
- inject a synthetic roadworks hazard 450 m ahead so it is visible on the map.

Visual positions advance at 10 Hz while signed, durable situational events are
written at 2 Hz. This keeps map motion continuous without turning the event
journal into a rendering loop.

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
