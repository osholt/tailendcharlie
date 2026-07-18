# Tail End Charlie

Tail End Charlie is an open-source, offline-first group motorcycle coordination app
for iOS and Android.

It is being designed for rural rides and the second-bike drop-off system. Every
important action is stored on the phone first. The target transport combines an
internet service with encrypted, store-and-forward exchange between nearby
phones when mobile coverage disappears.

> [!IMPORTANT]
> This repository is a development alpha, not a safety product. The app and
> native nearby transports now compile, but mixed-device radio behaviour,
> background reliability, route-alert calibration, and battery use still need
> the physical-device field-test matrix before any reliability claim is made.

## Current vertical slice

- Create a ride and share its six-digit numeric code. A rider uses the code
  once while connected to join the authenticated group relay.
- Resume the active ride after restarting the app.
- Store immutable, HMAC-tagged ride events in an idempotent SQLite journal.
- Record roles, confirmation-based marker suggestions, authenticated unique
  marker passes, marking-time statistics, and priority quick messages.
- Show, copy, or share a simple six-digit numeric ride code. The service holds
  its encrypted bootstrap record only for the bounded ride-retention window.
- Import and persist GPX 1.1 routes, render them with MapLibre on both platforms,
  match sparse route/waypoint files to roads when online, and download bounded
  native offline regions when an approved style is configured.
- Enter a destination to generate a road-following route, keep it in Tail End Charlie,
  or hand its GPX to Calimoto/MyRoute-app through the native share sheet.
- Record foreground position, report/expire/deduplicate hazards, show rider and
  hazard overlays, and detect sustained route deviation with stale-GPS handling.
- Give the ride lead a compact along-route distance/ETA to Tail End Charlie and
  an immediate map alert for confirmed unacknowledged off-course riders.
- Switch into a compact, heading-up follow camera while moving, with reduced
  landscape chrome, a route-aware long look-ahead, a tile-backed group overview
  mini-map, solid ridden route progress, a faded dotted route ahead, and a
  contrasting trace for riders currently off route. Manual pan/zoom pauses
  follow mode until **Re-centre** is pressed. Landscape menus use a left rail.
- Default distance and speed units from the device locale (UK/US miles,
  kilometres elsewhere), with a persistent Settings override.
- Queue authenticated events for store-and-forward delivery over native Google
  Nearby Connections transports with reconnect, expiry, ACK, and replay safety.
- Batch authenticated events through an optional HTTPS relay with durable
  cursors, strict size/time limits, idempotent server acknowledgement, and
  automatic bounded reconnect.
- Deploy the included FastAPI/PostgreSQL relay behind Caddy TLS, with encrypted
  event storage, signed cursors, rate limits, retention cleanup, and health metrics.
- Export GPX through the native share sheet, hand destinations/previews to
  supported navigation apps, and share ride/marker summaries as text and CSV.
- Navigate between Ride, Map, and Awareness from an active ride.
- Run analysis, tests, Android debug builds, and unsigned iOS builds in CI.

See [PLAN.md](./PLAN.md) for product requirements and delivery gates, and
[docs/architecture.md](./docs/architecture.md) for the implementation shape.

## Planned navigation platforms

- **Apple CarPlay:** a glanceable route/group companion using approved CarPlay
  navigation templates, subject to Apple entitlement and review.
- **Android Auto:** a matching projected navigation/group-alert companion using
  the Android for Cars App Library and its driver-distraction restrictions.

These are planned P1 platform integrations, not features of the current alpha.
The phone remains the source of ride state and offline relay data.

## Repository layout

```text
apps/mobile/                 Flutter application and native iOS/Android shells
apps/server/                 FastAPI/PostgreSQL internet relay
deploy/                      Caddy, PostgreSQL, cleanup, and optional map service
docs/                        Architecture, field testing, and release notes
.github/workflows/           Reproducible mobile and server pipelines
```

## Local development

The project currently pins CI to Flutter `3.44.6` and Dart `3.12.2`.

```bash
cd apps/mobile
flutter pub get
flutter analyze
flutter test
flutter run
```

After creating or joining a ride, use the bottom navigation to open **Map** or
**Awareness**. The map includes a simulator-friendly demo route. GPX route
geometry works without a basemap; provider configuration and offline-caching
licence gates are documented in
[docs/maps-and-gpx.md](./docs/maps-and-gpx.md).

Select **Try a simulated ride** on the start screen to run the complete map and
situational-awareness flow with five virtual bikes. Ride Lab can accelerate
time, switch between leader/follower/TEC viewpoints, simulate a stationary
marker session, delay the TEC, send a rider off course, and add a visible hazard
ahead without using device GPS or publishing synthetic data to the
internet/nearby relays. See
[docs/ride-simulator.md](./docs/ride-simulator.md).

Navigation handoff behavior is documented in
[docs/navigation-export.md](./docs/navigation-export.md); exact GPX geometry is
shared where a target does not provide a documented full-route link.

The deployable internet relay and its contract are documented in
[docs/internet-relay.md](./docs/internet-relay.md). The app sends no server
traffic unless `RIDE_RELAY_API_BASE_URL` is supplied as an HTTPS
`--dart-define`. Deployment is covered by
[docs/server-runbook.md](./docs/server-runbook.md).

Android requires JDK 17 and a current Android SDK. iOS requires Xcode. No Apple
Developer signing identity is required for the development build:

```bash
flutter build ios --debug --no-codesign
```

Android debug builds use Android's standard debug certificate. Distribution
signing and all private key material are intentionally absent from the repo.

## Security and privacy

Do not use the current preview for real emergency coordination. See
[SECURITY.md](./SECURITY.md) for vulnerability reporting. Location events are
ride-scoped and locally persisted. A completed ride is retained locally for at
most 24 hours for final relay recovery, then its session, secure group secret,
and event journal are deleted automatically; it can also be removed immediately
from the app. The reference server encrypts retained event bodies and enforces
bounded deletion, but group-scoped credentials are not per-device identity or
end-to-end payload encryption. The six-digit join code is deliberately a
rate-limited, private-tailnet development-alpha bootstrap credential, not a
public-internet security boundary. Security/privacy review and physical-device
evidence remain release gates.

## License

Tail End Charlie is source-available under the [PolyForm Noncommercial License
1.0.0](./LICENSE). You may use, modify, and distribute it for permitted
noncommercial purposes. Commercial use requires separate permission from the
copyright holder.

This licence applies to future releases. Earlier copies that were received
under MIT remain available under their original terms.
