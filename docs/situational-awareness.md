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

New first-party reports deliberately exclude police-presence and speed-camera
categories. Older journal values remain decodable for compatibility, but cannot
be created in the current UI or controller. The provider and legal decision is
recorded in
[crowd-hazard-feed-decision.md](./crowd-hazard-feed-decision.md).

External sources implement `ExternalHazardProvider` and must expose an honest
state (`unavailable`, `needsConfiguration`, `configured`, `loading`, `ready`, or
`failed`). `WazeReadHazardProvider` is deliberately unavailable: the published
[Waze partner feed documentation](https://developers.google.com/waze/data-feed/incident-information)
describes partners sending incidents and closures to Waze, not a supported
general crowd-report read feed. The app neither scrapes Waze nor labels a source
live without a working provider implementation and appropriate rights.

`RelayTrafficHazardProvider` is the supported live UK path. A leader sends only
bounded route viewports to the Tail End Charlie relay, which keeps the TomTom
Orbis key server-side; the app then rejects incidents outside the route
corridor. Configuration, privacy limits and deployment gates are documented in
[live-traffic-incidents.md](./live-traffic-incidents.md).

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
