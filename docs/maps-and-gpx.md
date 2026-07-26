# Maps, GPX and offline regions

GPX route geometry, waypoints, current position, hazards, and riders are stored
and rendered locally. The production map path uses the open-source MapLibre
Native SDK on both iOS and Android. It does not depend on Apple Maps and it does
not bulk-download from the public OpenStreetMap tile servers.

## GPX behaviour

- Imports GPX 1.1 tracks, routes, and waypoints through the system picker.
- Preserves disconnected segments, elevation, timestamps, and waypoint detail.
- Stores a versioned parsed route in application support storage.
- Accepts UTF-8 files up to 10 MB and 200,000 points.
- Rejects invalid coordinates, document type declarations, and empty geometry.
- Treats recorded `<trk>` geometry as authoritative and never reroutes it.
- Recognises web-planner tracks carrying the Tail End Charlie
  `<tec:road-route>` extension as calculated road routes. During review the app
  can refresh those through the road router to recover manoeuvre instructions;
  an ordinary recorded track remains untouched.
- Attempts to match sparse `<rte>` geometry, or waypoint-only GPX files, to the
  road network after an explicit import. If routing is unavailable, the original
  GPX remains usable and is stored unchanged.
- Includes a valid 17.5 km, 484-point GPX track following roads from the King's
  Oak Academy car park to the Cross Hands Hotel car park.

## Motorcycle discovery layers

Twisty highlights, mountain passes and good biking roads are independent and
off by default. The initial bundled Wales catalogue is a bounded,
manually-reviewed proof of concept derived from OpenStreetMap under ODbL. The
planned route remains visually dominant; tapping a highlight shows its source,
confidence, last-verified date and safety warning, and can append a routed leg
without discarding existing geometry or waypoints.

Suggestions are first saved as private offline drafts. A build only exposes the
explicit send action when `RIDE_RELAY_DISCOVERY_API_URL` is configured, and the
rider must confirm that action after connectivity returns. Public map data can
only come from the server's separately authenticated moderation pipeline.

```text
--dart-define=RIDE_RELAY_DISCOVERY_API_URL=https://api.tailendcharlie.app
```

Highlights are descriptive planning aids, not safety endorsements. Riders must
check signs, closures, restrictions, weather, surface and current conditions.

## Riding display

While an active-ride screen is foregrounded, the app requests the platform
screen wake lock for the whole ride surface, not only while GPS says the bike
is moving or while the Map tab is selected. It reasserts that request when the
app resumes and every 15 seconds because iOS or Android may release a one-shot
request after window or lifecycle changes. The request is removed when the
ride surface is exited. This prevents automatic display sleep only; it does
not override a rider manually locking the phone, keep the app running after a
force-quit, or grant background CPU execution.

The map uses foreground GPS speed, heading, and remaining route geometry to
enter a heading-up follow view while moving. Landscape uses a wider zoom.
Manual pan or zoom suspends camera following and shows a **Re-centre** action
instead of snapping back on the next GPS update.

### Forward-looking framing

`NavigationCameraPlanner` drives zoom, tilt and forward bias from one
smoothstep curve on smoothed road speed, so the value and the gradient are
continuous and nothing snaps as the rider crosses a speed. The curve saturates
at 30 m/s.

- **Tilt** runs 51° to 58° in portrait and 53° to 58° in landscape. MapLibre
  Native clamps pitch at 60° on both Android and iOS, so 58° is the working
  ceiling with margin; a plan the platform silently clamps would end a
  transition somewhere other than where it was aimed.
- **Forward bias** puts the rider low in the frame rather than at its centre:
  0.56 to 0.70 of the viewport height in portrait, 0.58 to 0.72 in landscape,
  measured from the top edge. `maplibre_gl` exposes no camera padding, so the
  bias is applied by aiming the camera at a ground point ahead of the rider,
  computed from the tilt, zoom and measured viewport height, which lands the
  rider on the planned fraction rather than guessing a look-ahead distance. On
  the `flutter_map` fallback the same bias is a screen-space anchor offset.
- Portrait chrome sits in a band directly under the rider, so the bias is
  pulled back to keep the marker clear of the measured band height. With every
  overlay live at once the framing degrades towards a centred follow camera and,
  in the extreme, above centre: keeping the rider's own marker visible always
  beats keeping the bias. Landscape chrome is confined to side rails, so
  landscape keeps its full bias.

### Rotation

`NavigationHeadingSmoother` drives the map bearing. GPS course over ground is
the only authoritative source, and only at or above 1.5 m/s; below that the last
stable bearing is held, because a stationary GPS course is noise. The device
compass is deliberately never blended in — a phone mounted on a steel
motorcycle sits inside the bike's own magnetic field — and the only bearing
taken at rest is the first of a ride, in place of an arbitrary north-up map.
A course change is low-passed with a 0.9 s time constant, held entirely inside a
9° deadband so ordinary road curvature produces no rotation, tightened to 3°
when a manoeuvre is within 150 m, and rate limited to 45°/s so a 90° junction
settles in about two seconds without overshoot. Changes beyond 95° are rejected
until a following fix corroborates them, so GPS noise and tunnel re-acquisition
cost one update of latency instead of spinning the map. All comparisons take the
shortest angular path, so crossing north rotates the short way.

### Overlay placement

No persistent *status* surface is anchored to the top of the map: the upper band
is where a rider on a mounted phone reads the road ahead. Portrait stacks every
surface into one bottom-anchored band — urgent alerts, then the turn banner,
then the TEC gap and group overview, then one action row of glove-sized targets
nearest the thumb, then the speed sign hard right. Landscape splits them into a
bottom-left rail (turn banner, status, actions) and a bottom-right rail (group
overview, speed limit, junction marker card), leaving the centre column and the
upper viewport clear. Each rail is a single column, so placement stays
deterministic and no surface can cover another at any simultaneous overlay
count. Urgent alerts still interrupt, but they grow the band upwards rather than
claiming the top band. Safe-area insets are respected in both orientations, with
or without the app bar.

The **ride menu is the one exception**, in the top leading corner in both
orientations: a single small control that a rider reaches for by feel and that
obstructs nothing, rather than a status surface competing with the road. Nothing
else is allowed up there.

SOS, LEAVE and REPORT share one row. REPORT used to own a row of its own above
the speed sign, which in portrait made four stacked rows below the turn banner
and in landscape put it high in the left rail. Landscape tightens only the label
padding on the two extended targets, never their height, so all three fit one
run of a 42%-width rail: wrapping one onto a second run pushed an urgent banner
off the top of a 390-pixel-tall screen.

**Re-centre ("Follow me") is a recovery affordance, not chrome.** It appears when
the rider has taken the camera over with a pan, a pinch or a route fit, or when
there is no fix to follow yet, and it disappears the moment following resumes.
The flag behind it is deliberately separate from the automatic-follow
suppression, which clears as soon as the bike stops: the button has to survive
stopping, because a rider who panned and then pulled over is exactly who needs
it.

The band the camera measures is the band a test measures: the portrait rail
carries `portraitBottomChromeKey`, so the `bottomChromeFraction` below is
asserted against the real layout rather than a sum of assumed overlay heights.
Decluttering it moved a 390x844 portrait band from 431 to 342 logical pixels in
ordinary riding — a turn banner, the action row and the speed sign — which takes
the rider's viewport fraction from a clamped 0.429 to 0.535 and flips the
forward bias from 60 pixels *behind* the bike to 29 ahead of it. At the absolute
maximum overlay count the band fell from 683 to 594 pixels; that case still
clamps to the 0.35 floor, because a paused-ride banner, an off-course alert, a
turn banner with lane guidance, the TEC gap and the group overview all live at
once, and shortening those belongs to the issues that own them.

Landscape navigation also shows a compact group overview above the primary
turn-by-turn map. It uses a second, throttled view of the configured MapLibre
style, fits the latest known rider locations, distinguishes the local rider,
and includes route geometry without changing the main camera. Rider locations
are enough to show this overview; choosing a planned route is not a prerequisite.

On Android, the overview uses the local route-and-rider renderer instead of a
second nested MapLibre platform view. This avoids the black platform surface
seen on affected Samsung-class devices while retaining route geometry, rider
contrast, north indication, scale, and light/dark theme response. The iOS
overview continues to use the configured MapLibre style when available.

The primary route is split at the rider's monotonic along-route progress. That
split is a view of the *plan*: it is not a record of where anyone has been.

Every rider's travelled trail is recorded from position history alone and is
drawn whether or not a route is loaded, whether or not the rider matches it, and
on every participant's device. Route matching drives route progress and alerts
only. Each rider's history is bounded to the most recent 120 points, is dropped
when a rider stops being eligible for live position sharing, is not retained
before the ride starts, and is never added to the imported GPX. The leader's
trail also draws on the leader history the awareness controller rebuilds from the
durable journal, so it survives an app restart mid-ride as far as the journal
allows.

### Route and trail palette

Defined once in `apps/mobile/lib/features/map/route_trail_style.dart` and shared
by the MapLibre layers, the flutter_map fallback and the group mini-map. Every
line is opaque over an opaque near-black casing (`#10151C`): the bright fill
carries the contrast over a dark basemap, the casing carries it over a light one.
Because a dark basemap needs every one of these colours to be light, they cannot
all separate by luminance, so each also has a unique width and dash pattern and
stays identifiable in a greyscale render.

| line | colour | width | pattern | dark worst | dark typical |
| --- | --- | --- | --- | --- | --- |
| route ahead | `#3DDC84` | 6 | long dash 22/11 | 4.11 | 9.54 |
| travelled (plan behind you, and your own trail) | `#FF7A1A` | 5 | solid | 2.81 | 6.52 |
| leader trail | `#D3B8FF` | 8 | solid | 4.22 | 9.78 |
| off-route trail | `#FF5FD1` | 4 | dash 9/7 | 2.73 | 6.33 |
| rejoin breadcrumb (owned by off-route rerouting) | `#00E5FF` | 4.5 | dash 12/8 | 4.77 | 11.06 |

Contrast is WCAG 2.1, measured against the dark basemap this app actually
renders — the OpenFreeMap dark style after `MapStyleRepository` repaints its
near-black layers. "Dark worst" is against the lightest of those surfaces (the
`#565656` motorway fill), "dark typical" against the `#1C1C1E` background. The
casing measures 16.74:1 against the Liberty background and 18.32:1 against its
white road fills. The blue this replaced (`#3478F6`, dotted, 90% opacity)
measured 1.80:1 at the worst case, which is why it disappeared through a visor in
sunlight. The travelled orange is unchanged because the same field report found
it legible; it is the floor the other lines are held against.
`route_trail_style_test.dart` asserts these numbers. Numbers are not a substitute
for the daylight photograph the field-test log still needs.

The leader's trail is the widest line and is drawn beneath the planned route, so
the group's ground truth stays visible without hiding the plan. Off-route trails
are drawn above it, because they are the deviation from it.

The route ahead is green rather than cyan because cyan belongs to the rejoin
breadcrumb, and those are the two lines that both mean "go this way" and appear
together during a reroute. Amber or yellow was rejected for the route ahead
because the light basemap's trunk roads are already `#FFEEAA`: the line would
vanish into the road it is drawn on. The closest remaining pairs by luminance
alone are route ahead against rejoin (1.16) and route ahead against the leader
trail (1.03); hue separates the first and width and pattern separate both.

## In-app maneuver guidance

Road routes planned through OSRM retain their maneuver steps. While the rider is
near the planned route, the map shows the next useful maneuver, remaining
distance, and road name or reference in a large banner. The banner advances only
after the rider passes the maneuver, using the same monotonic route progress as
the completed-route display. It is hidden when there is no maneuver-bearing
route or the rider is substantially off route. Imported recorded GPX tracks do
not invent directions from geometry alone. Route review reports how many turn
instructions a route carries.

### Roundabouts, direction and symbols

OSRM reports a roundabout as joining the ring and then leaving it, and the
modifier on each step describes that step alone: the entry modifier is the turn
onto the ring, which in the UK is usually a slight left whatever exit is taken.
Announcing both steps produced two "slight left" instructions for a junction
that is straight on.

Tail End Charlie therefore collapses a `roundabout`/`rotary` step and its
`exit roundabout`/`exit rotary` step into one instruction, and takes the
direction from the manoeuvre's own geometry: the `bearing_before` of joining the
ring compared with the `bearing_after` of the step that leaves it. Where the
engine emits no separate exit step, the heading before the next manoeuvre is
used if it is within 250 m. `rotary` and `roundabout turn` are presented as
roundabouts, and adjacent ring steps within 25 m are treated as one gyratory.

- The exit number is only ever the engine's own `exit` count for a circular
  junction, and is dropped where two merged rings each counted their own exits.
  With no count the instruction says *"Roundabout, take the exit straight on"*.
- With no bearings — a route saved before they were stored — no direction is
  claimed: the instruction says *"Roundabout, take the 2nd exit"* rather than
  repeating the entry modifier.
- The driving side reported by the engine only chooses clockwise or
  anticlockwise ring rendering and the handedness of a U-turn glyph. It never
  decides which way an instruction says to go.
- Roundabout symbols are drawn rather than taken from Material's
  `roundabout_left`/`roundabout_right`, which mean *which exit is taken* and
  cannot show a straight-on exit or the ring's direction of flow.
- Every instruction names a direction — left, right, straight on — or is a named
  case: U-turn, merge, fork, slip road, arrival, or an explicit
  "follow the route" where the engine gave nothing to state.

#### How the roundabout symbol is drawn

The ring is drawn as arcs with a gap where each road meets it, and the exit
leaves through its gap. A rider glances at one arrow, so the symbol carries
exactly one: the exit. There is no separate arrow for the direction of flow —
in the UK every roundabout flows clockwise, so it told a rider nothing they
needed while competing with the arrow that mattered.

- Driving side still shapes the ring: the arc from the road in round to the exit
  is the part the rider rides and is drawn heaviest, so a first exit is a short
  arc and a last exit is nearly the whole ring. Where the engine reported no
  driving side, no part of the ring is claimed as the ridden one.
- Where the exit turns so far back that it would be drawn along the road in, the
  road in swings to the other side of straight back, so a turn back on itself
  leaves as a V beside the road it came in on.
- Every part is placed inside the symbol's own box at every exit angle, so no
  arrowhead is lost to a clip in the banner or the all-turns list.
- `RoundaboutSymbolGeometry` works the shape out before anything is painted, so
  the ring gap and the single arrowhead are asserted rather than eyeballed.
  `test/features/map/maneuver_symbol_painter_test.dart` also rasterises every
  direction, both driving sides and the unstated case at each size the app
  draws, over both basemap panels, into `build/maneuver-symbols/`.

![Roundabout symbol matrix](images/roundabout-symbol-matrix.png)

![Roundabout symbol at each size](images/roundabout-symbol-sizes.png)

### Lane guidance and the manoeuvre list

Lanes come from the engine's `intersections[].lanes`. Usable lanes are marked by
colour and an underline. Nothing is shown where the engine supplied no lanes, or
where there are more lanes than fit legibly, because a truncated strip would put
the usable lane on the wrong side of the road.

An **All turns** screen lists every instruction for the current route in riding
order with distance from the start, distance from the rider, direction, exit
number, road name or reference and a lane summary. It is reachable from route
review before a ride, from the map menu, and from the ride menu while the map is
in navigation mode. It is built from the persisted route by the same planner that
drives the banner, so the two sequences match and no routing call is made.

This guidance complements the existing Google Maps, Waze, and GPX handoffs; it
does not change or remove them. Spoken prompts are deferred until audio focus,
Bluetooth/intercom routing, interruption behaviour, and helmet intelligibility
can be tested on physical iOS and Android devices. A visual-only prompt must not
be represented as voice-guided navigation in release material.

## Destination and road routing

Every calculated route, GPX import, plan-code import, recorded route and demo
route opens a full-route review before it can replace the authoritative ride
route. The leader can inspect distance, duration when available, ordered stops
and warnings; destination routes can return to editing to replace, reorder or
delete stops and recalculate. Cancelling leaves the stored and distributed
route unchanged, while confirming produces one route update.

The map's destination action performs one user-submitted place/postcode search
and routes from the current foreground location. It does not send autocomplete
or background geocoding traffic. Latitude/longitude input bypasses geocoding.
Generated road geometry is stored as an ordinary GPX-compatible track and stays
visible offline after planning.

Development-alpha builds use the public OSRM and Nominatim endpoints. Both are
replaceable without an app update:

```text
--dart-define=RIDE_RELAY_ROUTING_URL=https://routing.example.com
--dart-define=RIDE_RELAY_GEOCODING_URL=https://geocoding.example.com
```

Destination results are cached for the app session and requests identify Ride
Relay with a valid User-Agent. The public Nominatim service forbids client-side
autocomplete and limits aggregate use; production must use an approved provider
or self-hosted proxy before scale testing. OSRM uses the driving profile, so it
produces road-following routes but does not claim Calimoto-style motorcycle or
curvy-road optimization.

## Mapped speed-limit display

The map, map menu and Settings screen carry a UK speed-limit display. **It is on
by default, and an explicit opt-out is respected.** The preference is only ever
written by a rider toggling it, so an absent key means "never chose" and takes
the default while a stored `false` stays off across an upgrade. A rider who has
turned it off sees the compact `Limits off` map control, which opens the
location-data explanation before re-enabling the layer.

**A road is resolved from the current position, not from movement.** The first
fix after the feature is enabled triggers a lookup immediately; the earlier
`waitingForMovement` entry state is retired, because withholding the readout
until the bike moved made a working feature look broken and was the reason the
field report saw `0` and `MOVE TO IDENTIFY ROAD` on a stationary phone.

The caution the delay was reaching for is now a confidence test rather than a
blanket wait:

- A **travelled** trace — two fixes at least 4 metres apart — is sent as two
  shape points. It tolerates up to 50-metre accuracy and a 40-metre road match,
  because the travel heading has to agree with the matched road's heading to
  within 50°. That is what separates the two carriageways of a dual
  carriageway, and it is the one case where movement genuinely helps.
- A **stationary** fix is sent as a single shape point and is treated as having
  no heading *whatever course the platform reports*, for the same reason
  `NavigationHeadingSmoother` refuses a course below 1.5 m/s: a stationary GPS
  course is noise. It is held instead to 25-metre accuracy and an 18-metre match,
  because there is no direction to corroborate the snap with, so the snap itself
  has to be convincing. A road the rider is probably not on is reported as
  unmatched rather than guessed at: a wrong limit is worse than an absent one.

Ambiguity is stated, not hidden. Poor accuracy or an uncertain match resolves to
`unconfirmedRoad` — named for the condition, not for a wait — which shows `GPS
accuracy too low` or `Road not confirmed` and is retried where the rider stands
every 5 seconds, or immediately once the bike moves. A settled negative (no
mapped limit on this road, outside the UK) waits for the bike to move rather than
re-asking about a spot that cannot change; an unreachable service is retried on
the ordinary 15-second interval. Once a limit is known, rechecking still needs
both 25 metres of travel and 15 seconds.

Lookups are fed from the navigation fix rather than a bare position, because the
confidence test is built on reported accuracy and heading and a position
carrying neither cannot be tested at all.

Only an OpenStreetMap `maxspeed` value reported by Valhalla as
`speed_type=tagged` is displayed. A classified or inferred speed is deliberately
treated as unknown. The UI uses mph and familiar UK sign styling, labels the
reading `MAPPED`, and always warns that it is not live: temporary and variable
limits may differ and roadside signs apply.

The sign is drawn straight onto the map with no surrounding panel. The rider's
own GPS speed appears directly beneath it at the sign's own font size, so the
two numbers can be compared at a glance. That readout stays in mph regardless
of the rider's distance-unit preference, because two different units under one
mph sign would invite a dangerous misread. It is the smoothed foreground GPS
speed already used for the navigation camera, it is never sent anywhere, and it
shows `–` when the platform reports no usable speed. Labels outside the white
sign face are stroked as well as shadowed so they stay legible over both the
day and night basemaps.

There is **no caption under the readout**. A red-ringed UK sign above a plain
number is already unambiguous, and the nine-point
`MPH · MAPPED LIMIT · GPS SPEED` line cost glance time on a moving bike without
adding meaning. Its wording was not lost: the badge's accessibility label and
tooltip still say which number is the sign and which is the rider, that the
limit is mapped rather than live, how stale it is, and — when there is no
reading — which condition is holding it up.

`PostedSpeedLimit.checkedAt` is the lookup time, not the age of the underlying
OpenStreetMap tag. The provider does not expose a reliable source-update time,
so data freshness is explicitly unknown. A reading is kept only in memory,
replaced or cleared by the next attempted match, and cleared when the user
turns the feature off; it is not persisted as a speed-limit cache.

Alpha builds default to FOSSGIS/OpenStreetMap.de's public Valhalla instance.
The endpoint is replaceable without an app update:

```text
--dart-define=RIDE_RELAY_SPEED_LIMIT_URL=https://routing.example.com/trace_attributes
```

Valhalla is MIT-licensed and its OpenStreetMap-derived road data is ODbL with
attribution required. The app credits `© OpenStreetMap contributors` in the
setting and reading detail. The FOSSGIS endpoint is a free public demo subject
to fair use and rate limits, not a contracted or production service; requests
include the requested `X-Client-Id: tailendcharlie.app`. Before any public
tester rollout that enables this endpoint, the project must notify its
operators as requested in the Valhalla repository.

A production release needs an operated Valhalla service or licensed provider,
capacity monitoring, and UK road tests covering direction, parallel roads,
junctions, national-speed-limit roads, temporary limits, and variable limits.
The current alpha integration has no per-request provider fee, but operating a
production instance or selecting a commercial source has an unresolved cost.

Provider references:

- [Valhalla trace attributes and country/speed metadata](https://valhalla.github.io/valhalla/api/map-matching/api-reference/)
- [Valhalla speed source semantics](https://valhalla.github.io/valhalla/concepts/speeds/)
- [Valhalla data licences](https://valhalla.github.io/valhalla/contributing/data/data-sources/)
- [Valhalla attribution requirements](https://valhalla.github.io/valhalla/mjolnir/attribution/)
- [Public demo fair-use and client identification](https://github.com/valhalla/valhalla#demo-server)

## MapLibre provider configuration

Development-alpha builds default to OpenFreeMap's public Liberty style for an
online, no-key basemap. Its public service has no availability guarantee, so it
is an alpha convenience rather than the production dependency. Persistent
offline caching stays disabled. Override the provider for production or a
self-hosted deployment with the settings below.

Supply an HTTPS MapLibre style whose tile, sprite, and glyph licences permit
mobile display and, if enabled, offline downloads:

```text
--dart-define=RIDE_RELAY_MAP_STYLE_URL=https://relay.example.com/maps/styles/ride-relay.json
--dart-define=RIDE_RELAY_TILE_ATTRIBUTION=© OpenStreetMap contributors
--dart-define=RIDE_RELAY_TILE_MAX_ZOOM=18
```

Offline download additionally requires explicit approval and a versioned cache
namespace:

```text
--dart-define=RIDE_RELAY_TILE_CACHE_ALLOWED=true
--dart-define=RIDE_RELAY_TILE_CACHE_NAMESPACE=open-map-style-v1
```

The app uses MapLibre's native offline-region database. It calculates a padded
route bounding box, downloads zoom levels 10–15, caps a request at 2,500 tiles,
shows progress, supports cancellation, and deletes only regions belonging to
the configured namespace. Long or antimeridian-crossing routes must be split.
The HTTPS style is validated, its relative resources are normalized, and an
approved copy is cached for 24 hours. If no valid style is reachable or cached,
the app falls back to a bundled blank style so the local route and overlays
remain visible instead of failing the whole map.

The older HTTPS raster XYZ configuration remains as a development fallback:

```text
--dart-define=RIDE_RELAY_TILE_URL=https://licensed.example/{z}/{x}/{y}.png
```

It is not the recommended production path.

## Self-hosted maps

The optional `maps` deployment profile runs the official MapLibre Martin tile
server and accepts operator-supplied MBTiles or PMTiles archives. Large datasets
and provider styles are deliberately excluded from Git. Put a schema-matched
archive in `deploy/maps/data`, its style/sprites/glyphs in
`deploy/maps/styles`, and start:

```bash
docker compose --env-file deploy/.env -f deploy/compose.yaml \
  --profile maps up -d --build
```

OS Open Zoomstack is a viable free Great Britain dataset if its supplied style
and attribution are adapted together. OpenStreetMap-derived OpenMapTiles or
Protomaps data are other open choices, but their attribution and data/style
licences still apply. The public `tile.openstreetmap.org` service forbids bulk
offline downloading and is never a default.

## Offline states

| State | Route | Basemap |
|---|---|---|
| No provider | Fully local | Explicit route-only canvas |
| Style, offline not approved | Fully local | Online only |
| Style, offline approved and downloaded | Fully local | Native offline region |

Riders should open the prepared route in flight mode before departure. A
successful download is not a safety guarantee; real-device storage, provider,
and coverage edges remain part of the field-test matrix.

## Primary references

- [OpenFreeMap quick start](https://openfreemap.org/quick_start/)
- [OpenFreeMap terms of service](https://openfreemap.org/tos/)
- [MapLibre Flutter SDK](https://github.com/maplibre/flutter-maplibre-gl)
- [MapLibre Martin tile server](https://maplibre.org/martin/)
- [OpenStreetMap tile usage policy](https://operations.osmfoundation.org/policies/tiles/)
- [OS Open Zoomstack](https://www.ordnancesurvey.co.uk/products/os-open-zoomstack)
- [GPX 1.1 schema](https://www.topografix.com/GPX/1/1/)
- [OSRM route service](https://project-osrm.org/docs/)
- [Nominatim usage policy](https://operations.osmfoundation.org/policies/nominatim/)
