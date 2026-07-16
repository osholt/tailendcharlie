# Ride Relay

Ride Relay is an open-source, offline-first group motorcycle coordination app
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

- Create a private ride or join with a six-character code.
- Resume the active ride after restarting the app.
- Store immutable, HMAC-tagged ride events in an idempotent SQLite journal.
- Record roles, manual marker sessions, unique marker passes, and priority
  quick messages.
- Generate and share a QR/deep-link invitation.
- Import and persist GPX 1.1 routes, render them offline, and optionally cache a
  bounded map corridor when a licensed tile provider is configured.
- Record foreground position, report/expire/deduplicate hazards, show rider and
  hazard overlays, and detect sustained route deviation with stale-GPS handling.
- Queue authenticated events for store-and-forward delivery over native Google
  Nearby Connections transports with reconnect, expiry, ACK, and replay safety.
- Navigate between Ride, Map, and Awareness from an active ride.
- Run analysis, tests, Android debug builds, and unsigned iOS builds in CI.

See [PLAN.md](./PLAN.md) for product requirements and delivery gates, and
[docs/architecture.md](./docs/architecture.md) for the implementation shape.

## Repository layout

```text
apps/mobile/                 Flutter application and native iOS/Android shells
docs/                        Architecture, field testing, and release notes
.github/workflows/mobile.yml Reproducible quality and mobile build pipeline
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
ride-scoped and locally persisted, but production identity, encryption, data
compaction, retention/deletion enforcement, and server sync remain release
gates.

## License

[MIT](./LICENSE)
