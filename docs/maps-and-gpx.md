# Maps, GPX and offline tiles

Ride Relay's map feature is deliberately useful without a map provider. GPX
geometry, waypoints and the current-position/overlay inputs are stored and
rendered locally. A raster basemap is an optional enhancement.

## Integration

`RideMapFeature` is the self-contained production entry point:

```dart
RideMapFeature.fromEnvironment(
  currentPosition: currentPositionNotifier,
  overlayMarkers: hazardAndRiderMarkerNotifier,
)
```

The optional `ValueListenable<GeoPoint?>` current-position seam does not request
location permission or start tracking. The app's location owner should update
it. `MapOverlayMarker` is a presentation-only adapter for hazards, group riders
and marker positions; those features keep ownership of their domain models.

`RideMapScreen` exposes the same UI with injectable storage, import and tile
cache services for tests or a dependency-injection container.

## GPX behavior

- Imports GPX 1.1 tracks, routes and waypoints through the system file picker.
- Preserves separate track segments, route paths, elevation, valid timestamps,
  waypoint labels and descriptions.
- Stores the active parsed route as versioned JSON in application support
  storage. Route display therefore does not depend on the original GPX file.
- Accepts UTF-8 files up to 10 MB and 200,000 points. Invalid coordinates,
  document type declarations and files without geometry are rejected.
- Includes a small Peak District demo route so the screen can be exercised in
  a simulator without first adding a file to the device.

Only one active route is retained in this development alpha. Route-library
management, GPX export and route editing remain later work.

## Provider configuration

There is no default tile provider and the app never bulk-downloads tiles from
`tile.openstreetmap.org`. Supply a commercial or self-hosted provider whose
terms cover the intended display and caching behavior:

```text
--dart-define=RIDE_RELAY_TILE_URL=https://licensed.example/{z}/{x}/{y}.png?key=PUBLIC_RESTRICTED_TOKEN
--dart-define=RIDE_RELAY_TILE_ATTRIBUTION=Licensed Maps and OpenStreetMap contributors
--dart-define=RIDE_RELAY_TILE_MAX_ZOOM=18
```

The first two values enable online basemap display. Tokens compiled into a
mobile app are recoverable, so use a provider-issued public client token with
application restrictions and usage limits—not a server secret.

Offline download remains disabled unless the provider licence has been checked
and the following values are also supplied:

```text
--dart-define=RIDE_RELAY_TILE_CACHE_ALLOWED=true
--dart-define=RIDE_RELAY_TILE_CACHE_NAMESPACE=licensed-provider-style-v1
```

The namespace must contain only letters, digits, `.`, `_` or `-`. Change it
when the provider or style changes so unlike tiles cannot collide.

## What “offline” means

| State | Route and waypoints | Basemap |
|---|---|---|
| No provider | Available offline | Disabled; route-only canvas is explicit |
| Provider, caching not approved | Available offline | Online only |
| Provider, caching approved | Available offline | Downloaded route corridor is available offline |

The download button plans a one-tile-radius corridor at zoom levels 11–15,
interpolates across sparse GPX points, then downloads into app-owned storage.
It has a 2,500-tile planning cap, 3 MB per-tile cap and 250 MB cache cap. Progress
and cancellation are surfaced, already-downloaded tiles are reused, and partial
downloads remain usable. Responses with `no-store`, `no-cache` or
`must-revalidate` are rejected rather than being represented as offline-ready.

This is a bounded prefetch, not a promise that every tile at every zoom is
present. Riders should verify the downloaded route before leaving coverage.

## Primary references

- [flutter_map offline mapping](https://docs.fleaflet.dev/tile-servers/offline-mapping)
- [flutter_map tile server guidance](https://docs.fleaflet.dev/layers/tile-layer)
- [OpenStreetMap tile usage policy](https://operations.osmfoundation.org/policies/tiles/)
- [GPX 1.1 schema](https://www.topografix.com/GPX/1/1/)
