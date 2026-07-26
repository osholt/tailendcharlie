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

## Rejoin routing and the leader-follow exemption

`RouteRejoinPlanner` (`apps/mobile/lib/services/route_rejoin_planner.dart`)
turns a confirmed deviation into an **advisory** route back. Every drawn metre
comes from the existing road-routing service; the app never synthesises
geometry and never names a manoeuvre the engine did not return.

### Leader-follow exemption

A rider inside 120 m of the ride leader's **actual recorded track** — matched
against the most recent 600 trail points, with the rider's own GPS accuracy
allowed as slack — is on route regardless of the planned GPX, including when the
leader has abandoned the GPX. `LeaderTrackExemption` is the single definition,
applied in `SituationalAwarenessController` at both ends: when this device
evaluates a fix, and when a deviation alert arrives from a device that had not
yet seen the leader leave the route. Alert state, the relayed deviation event,
the roster, the map traces and `LeaderRideStatusCalculator`'s off-course count
all read through that one rule. Exempting a rider also resets the deviation
detector's hysteresis, so a genuine later deviation starts from a fresh
three-sample confirmation instead of arriving pre-escalated.

### Bands

| Band | Condition | Behaviour |
| --- | --- | --- |
| off route | confirmed deviation under both thresholds | route to a rejoin point on the planned route |
| massively off course | 1500 m or more from the planned route, **or** 10 minutes off it | route back via a rejoin point no further along the route than the leader, then on to the TEC (or the leader when no TEC is registered) |

The leader is also used in place of the TEC when the TEC's own fix projects
further along the planned route than the leader's: a stale or wild TEC position
must not become the excuse for sending a rider past the group.

1500 m: the detector enters off-route at 120 m, which covers GPS error and
parallel carriageways; a missed turn strands a rider a few hundred metres away
and the next junction recovers it. Past ~1.5 km — about a minute at national
limit — the rider is on a different road and an unconstrained rejoin can drop
them ahead of the group. 10 minutes catches a rider who is not far from the line
but is a long way from the group; the all-rider critical escalation already
fires at 3 minutes.

### Rejoin point selection

Candidates are taken every 250 m from 150 m ahead of the rider's last matched
progress, up to 10 km ahead, and the nearest is used, so a rider does not ride
the route backwards. Backtracking is used only when no forward candidate is
admissible and is stated in the guidance when it is. For a massively-off-course
rider the admissible window is capped at the leader's own progress (plus 100 m
of slack for the leader's GPS error), so such a rider is never routed ahead of
the leader. If the only rejoin within 25 km lies ahead of the leader the planner
refuses and says so rather than using it.

### Recompute policy

A minimum interval of 45 s is a hard floor in every case. On top of it the rider
must have moved 250 m, or a moving target (TEC/leader) 400 m, or the band/target
must have changed. 45 s bounds a moving rider to at most 80 provider calls per
hour; the movement gate removes the rest, so a rider parked at a junction or
circling tighter than 250 m makes no further calls. Consecutive routing failures
back off geometrically to 6 minutes.

### Degradation and privacy

Routing failure, no imported route, an unknown leader position, no rejoin in
range and the ahead-of-the-leader refusal all fall back to the existing "you are
off route by X" message with no breadcrumb — never a blank screen, and never
invented geometry. Rejoin plans are computed on the affected rider's own device
and are not relayed, so no other rider's breadcrumb reaches the group map. A
leader opt-in to view another rider's rejoin route would need a new relayed
event type and is deliberately not implemented yet.

Thresholds and the recompute policy are development-alpha defaults. They are
covered by unit tests but have **not** been calibrated against recorded field
data, and no real off-route excursion has been ridden against this code.

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
`failed`). `WazeReadHazardProvider` is permanently unavailable rather than
merely unconfigured: Waze exposes no client-side read API, and Tail End Charlie
is not eligible for the partner programme that does return a feed. The app
neither scrapes Waze nor labels a source live without a working provider
implementation and appropriate rights.

`RelayTrafficHazardProvider` is the supported live UK path. A leader sends only
bounded route viewports to the Tail End Charlie relay, which keeps the TomTom
Orbis key server-side; the app then rejects incidents outside the route
corridor. Configuration, privacy limits and deployment gates are documented in
[live-traffic-incidents.md](./live-traffic-incidents.md).

## Enforcement warnings

Hazards typed `speedCamera` or `policeActivity` get the most prominent
treatment in the app. Rider reports are currently the only source of them: no
enforcement provider is configured and none is eligible, so the detector below
is deliberately source-agnostic and a licensed feed would need no new UI. `EnforcementAlertDetector` watches the rider's own
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
- **Any confidence.** A sighting warns regardless of how many riders have
  confirmed it. A licensed feed, if one is ever configured, should likewise be
  exempt from any confidence floor it applies to ordinary hazards.
- **Never a reroute trigger.** Enforcement types are excluded from the
  leader's traffic-reroute candidates at both the shell and the provider. The
  rider is warned; the group's authoritative route is not redrawn around it.
- Dismissal is per hazard, so passing one and approaching the next raises a
  fresh warning.

### Reporting a sighting

A `REPORT` control sits on the ride map's single action row, beside `ALERT` and
`LEAVE`: it is a ride action, not a route action, so it is present with or
without a GPX. It is 62 pt square — past the 48 dp minimum for a gloved thumb,
and no larger, because it covers the map for the whole ride. It used to own a row
of its own above the speed sign, which cost a row in portrait and put it high in
the landscape left rail; see the overlay-placement section of
`docs/maps-and-gpx.md`.

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
