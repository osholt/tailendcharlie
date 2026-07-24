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
enter a heading-up follow view while moving. Landscape uses a wider zoom and a
route-aware look-ahead point so bends and substantially more road ahead remain
visible while the rider stays safely on screen. Landscape navigation menus use
a narrow left rail. Manual pan or zoom suspends camera following and shows a
**Re-centre** action instead of snapping back on the next GPS update.

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

The primary route is split at the rider's monotonic along-route progress. The
completed section is solid orange and the route ahead is a translucent dotted
orange line. Suspected, confirmed, or recovering off-route riders receive a
magenta trail with a dark outline so their actual path is visually distinct
from the planned route. Rider trails are capped in memory and are not added to
the imported GPX.

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

The map menu and Settings screen contain an opt-in UK speed-limit display. It
is off by default. When enabled, the app submits the current and a recent prior
foreground GPS fix to a Valhalla `trace_attributes` endpoint no more often than
every 15 seconds and after at least 25 metres of movement. It rejects fixes
outside the UK, fixes with worse than 50-metre accuracy, distant road matches,
and matches whose direction conflicts with travel.

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
