# Ride Lab simulator

Ride Lab exercises the production navigation and situational-awareness UI
without requiring several phones or physical travel.

## Start a simulation

1. Leave any active ride.
2. Select **Try a simulated ride** on the start screen and choose a demo
   route. The last choice is remembered and marked next time.
3. Press **Start ride** in the slim bar above the map. It is the only control
   a simulated ride shows before the start: no ride code, roster or route
   panel (those stay on a real ride's pre-start screen). It is the same height
   in portrait and landscape, so the map keeps over four fifths of the screen.
4. Use **Map** to watch the ride or **Ride Lab** to control it.

Two routes are bundled, each with its own offline navigation decisions and a
side of the road confirmed by hand:

- **Castle Combe to Tetbury, Cotswolds** (UK, left-hand traffic, 24.5 km). A
  public-road route from a B-road junction near Castle Combe to Tetbury town
  centre, with ten decision points (nine turns and an end of road) to drop a
  bike at. It begins and ends at public places, not at anyone's home or ride
  start. Road geometry is from OpenStreetMap (ODbL), routed through the public
  OSRM server on 10 October 2026; that server reports right-hand traffic for UK
  roads, so the side is stated in the bundled file instead of being read from
  the response. A UK-configured phone keeps miles.
- **Argentat to Saint-Privat, France** (right-hand traffic, 17.9 km). A 466-point
  excerpt of the supplied Day 3 route to Puy Mary along the D 980, ending at
  the right-hand roundabout at Saint-Privat. A UK-configured phone switches its
  automatic ride distances to kilometres on it, and the simulator covers French
  roundabout guidance without a routing request.

The choice is offered from **Try a simulated ride**, from the **Ride Lab** tab
(which starts a clean simulation on the new route) and from the map's **Load
demo route**. Which one a first-time rider gets is the Cotswolds route.

The Ride Lab fleet picker supports four to thirty synthetic bikes. It always
keeps a lead, a second bike, Alex for the off-route scenario, and a Tail End
Charlie; any extra riders are distributed between them.

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

Changing the fleet size or restarting creates a clean simulation ride and resets
route progress, events, alerts, and trails.

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
