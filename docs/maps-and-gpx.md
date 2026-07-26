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

No persistent status surface is anchored to the top of the map: the upper band
is where a rider on a mounted phone reads the road ahead. Portrait stacks every
surface into one bottom-anchored band — urgent alerts, then the turn banner,
then the TEC gap and group overview, then the action targets nearest the thumb.
Landscape splits them into a bottom-left rail (turn banner, status, actions) and
a bottom-right rail (group overview, speed limit, junction marker card), leaving
the centre column and the upper viewport clear. Each rail is a single column, so
placement stays deterministic and no surface can cover another at any
simultaneous overlay count. Urgent alerts still interrupt, but they grow the
band upwards rather than claiming the top band. Safe-area insets are respected
in both orientations, with or without the app bar.

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
not invent directions from geometry alone. Route review explicitly reports
**Visual turn-by-turn ready** when manoeuvres are present.

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

## Optional mapped speed-limit display

The map, map menu and Settings screen contain an opt-in UK speed-limit display.
It is off by default. While it is off, a compact `Limits off` map control opens
the location-data explanation before enabling the layer. When enabled, the app
submits the current and a recent prior foreground GPS fix to a Valhalla
`trace_attributes` endpoint no more often than every 15 seconds and after at
least 25 metres of movement. It rejects fixes outside the UK, fixes with worse
than 50-metre accuracy, distant road matches, and matches whose direction
conflicts with travel.

Only an OpenStreetMap `maxspeed` value reported by Valhalla as
`speed_type=tagged` is displayed. A classified or inferred speed is deliberately
treated as unknown. The UI uses mph and familiar UK sign styling, labels the
reading `MAPPED`, and always warns that it is not live: temporary and variable
limits may differ and roadside signs apply.

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
