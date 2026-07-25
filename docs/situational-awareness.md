# Situational awareness development alpha

This module provides map-independent rider locations, user-reported hazards,
route-deviation state and foreground device positioning. It is designed for a
future map screen to consume without owning persistence or GPS permissions.

## Integration

`SituationalAwarenessController` accepts the shared `EventStore`, active
`RideSession`, and decoded route polyline. Its public lists are immutable and
safe for a Flutter map layer to render.

`DeviceLocationSource` is foreground-only. `inspect()` checks capability without
prompting. Permission is requested only when the rider invokes
`ForegroundLocationController.requestAndStart()`. Wire the sample callback to
`SituationalAwarenessController.recordLocalLocation()` and provide both
controllers to `SituationalAwarenessScreen` or its standalone cards.

No Android background-location/service permission or iOS background location
mode is declared. The app does not start location sampling at launch.

## Route alerts

The pure `RouteDeviationDetector` measures a fix against every route segment and
uses two thresholds:

- enter off-route outside 120 m for three accurate samples;
- recover inside 60 m for two accurate samples.

GPS fixes older than 30 seconds or less accurate than 75 m enter `gpsStale`
without advancing the off-route counter. A stale fix becomes a Lead/TEC alert
after 90 seconds. Confirmed deviations notify Lead/TEC and escalate to all-rider
critical after three minutes. Thresholds are configurable and must be calibrated
with field data before a safety claim or production release.

## Hazards

Rider reports have type, severity, coordinates, source, reporter, confirmations,
and expiry. A report of the same type within 75 m and 30 minutes confirms the
existing report rather than creating a duplicate. Expired hazards disappear on
load or refresh; clearing creates a durable event.

Riders can raise every hazard type, enforcement included. A rider-reported
camera or police sighting is a first-hand observation by the person reporting
it, which is a different thing from redistributing a provider's data, and it is
the report the group most wants. Enforcement a rider raises expires faster than
a road defect — two hours for a camera, one for police — because it is usually
a mobile van or a patrol car that moves on, and a stale sighting would raise a
full-screen warning for the whole group.

External sources implement `ExternalHazardProvider` and must expose an honest
state (`unavailable`, `needsConfiguration`, `configured`, `loading`, `ready`, or
`failed`). `WazeReadHazardProvider` is deliberately unavailable: Waze exposes no
client-side read API, so any Waze data reaches the app through the relay rather
than by direct access. The app neither scrapes Waze nor labels a source live
without a working provider implementation and appropriate rights.

`RelayTrafficHazardProvider` is the supported live UK path. A leader sends only
bounded route viewports to the Tail End Charlie relay, which keeps the provider
credentials server-side; the app then rejects incidents outside the route
corridor. Configuration, privacy limits and deployment gates are documented in
[live-traffic-incidents.md](./live-traffic-incidents.md).

## Enforcement warnings

Hazards typed `speedCamera` or `policeActivity` get the most prominent
treatment in the app. `EnforcementAlertDetector` watches the rider's own
position and raises `EnforcementAlert` for the nearest one **ahead** within one
mile; the map then covers itself with a full-screen warning showing the type
and a live distance countdown, dismissible by tapping.

Deliberate choices:

- **One mile of warning, not half.** The brief was at least half a mile; a full
  mile leaves room to react at national-speed-limit pace, and the countdown
  reads down through the half-mile mark either way.
- **Ahead, not merely nearby.** With a route loaded, "ahead" is decided by
  position along that route, so a camera already passed or one on the opposite
  carriageway stops warning. Without a route it falls back to comparing the
  bearing against the direction of travel. A fix with no usable heading warns
  anyway — a false warning costs a glance, a missed one costs more.
- **Any confidence.** Enforcement bypasses the provider confidence floor.
- **Never a reroute trigger.** Enforcement types are excluded from the
  leader's traffic-reroute candidates at both the shell and the provider. The
  rider is warned; the group's authoritative route is not redrawn around it.
- Dismissal is per hazard, so passing one and approaching the next raises a
  fresh warning.

### Reporting a sighting

A `REPORT` control sits on the ride map directly above the speed-limit sign,
sharing its anchor so it stays put whatever height the sign and its labels
take. It is 62 pt square — past the 48 dp minimum for a gloved thumb, and no
larger, because it covers the map for the whole ride.

Tapping it opens a sheet with two full-width 76 pt targets, `SPEED CAMERA` and
`POLICE`, plus cancel. Two taps rather than one is deliberate: a single
map-level tap is too easy to catch by accident at speed, and the cost of a
mis-tap is a false warning published to every rider in the group. The sheet
scrolls as a backstop on short landscape viewports, but both options fit
without scrolling. Reports are published at `serious` severity, so they drive
the same advance warning as provider data, and the map confirms what was sent.

## Event contract and limitations

Location, hazard, route-transition and acknowledgement events use the existing
append-only `RideEvent` store. New situational events are HMAC tagged and remote
ingestion rejects a wrong ride or tag. This shared-secret scheme remains a
development-alpha integrity mechanism, not production identity or authorization.

Before production, revisit event compaction for high-frequency positions,
key rotation/member removal, route-segment spatial indexing, platform lifecycle
tests, alert acknowledgement semantics, and field-calibrated false-positive
metrics. Alerts assist group coordination; they are not emergency-service or
collision-detection features.
