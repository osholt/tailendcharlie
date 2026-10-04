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
invented geometry.

Thresholds and the recompute policy are development-alpha defaults. They are
covered by unit tests but have **not** been calibrated against recorded field
data, and no real off-route excursion has been ridden against this code.

### Sharing a rejoin route with the leader (#128)

A rejoin plan is still computed on the affected rider's own device, and it is
still not group-visible. The one exception is the ride leader, who has a
legitimate need to see where a separated rider is being sent:
`RejoinRouteRelayGate` (`apps/mobile/lib/services/rejoin_route_share.dart`)
relays it as a `rejoinRouteShared` event **addressed to the leader**, gated on
the `rejoin-route-sharing-v1` capability.

**Relay bound: one share per rider per 120 seconds, no exceptions. A clear is
immediate and exempt.** This is deliberately independent of the 45 s local
recompute floor above. A separated rider on poor coverage is exactly the wrong
place to add event volume, and the geometry is the least urgent part of the
picture: the leader already learns *that* a rider is off course, and how badly,
from the unthrottled `routeDeviationChanged` alert. A breadcrumb two minutes old
still answers "which way have they gone", so a severity escalation or a change of
target does **not** buy an extra share — it takes the next slot. Measured worst
case for the field report's ten-minute circling rider: five shares when fed at
the 45 s recompute grid, six at the arithmetic ceiling, plus one clear. Both are
asserted in `rejoin_route_share_test.dart` rather than claimed.

The breadcrumb is resampled to at most 60 points (first and last always kept, so
the line still starts at the rider and ends at the rejoin) at five decimal
places, about 1.1 m — one decimal coarser than a rider's own position sample, and
comfortably inside the 8 KiB per-event and 128-entry payload limits.

Expiry has four independent triggers, all in one place
(`SharedRejoinRouteReducer`): the rider rejoins or has no drawable plan (an
immediate `cleared` share), the published route revision moves on (the share
carries the revision it was computed against and is discarded on sight
otherwise), the ride ends, and a hard 10-minute per-share TTL. Server retention
for `rejoinRouteShared` is capped at 30 minutes — the same band as
`riderLocationUpdated`, because a rider's intended path is as perishable as
where they actually are.

Privacy, stated exactly: "leader only" here means the same thing it means for an
ICE share. The event names its intended recipient, the sharer refuses to record
anything when no leader is known, and every consumer drops a share it is not
addressed to — but the ride relay is ride-scoped rather than per-recipient
encrypted, so this is not a cryptographic guarantee against another member who
already holds the ride secret. Personal observers (#36) get nothing. A
whole-group watcher (#263) may receive only the separately disclosed planned
route outline; it never receives this rider-specific rejoin route. The publish
schema separates those scopes, and both halves are asserted in
`test/features/ride/observer_snapshot_privacy_test.dart` and
`apps/server/tests/test_tec_role_and_rejoin_sharing.py`. Group watcher sharing
is a separate leader disclosure and credential.

## The Tail End Charlie role (#128)

Roles are self-selected: `RideController.setRole` records a `roleChanged` event
for the local device and the membership reducer keys role changes by
`event.deviceId`. That is unchanged. What is new is that the leader can **ask** a
named rider to take the back-marker role.

It is a request the target accepts, not an assignment that takes effect
immediately. A rider who has not noticed they are TEC is worse than no TEC,
because the group then believes the back is covered when nobody is watching it,
so the leader sees pending, accepted, declined, expired, superseded and
target-left as distinct states (`TecRoleAssignmentReducer`,
`apps/mobile/lib/services/tec_role_assignment.dart`). Accepting records the
answer **and** the target's own `roleChanged`, so the role itself still has
exactly one source of truth.

Authority, matching how #99 rejects a forged departure:

- a request is admissible only from a device whose latest signed role **at that
  point in the journal** is `lead`, and only when the payload names its own
  author as the leader;
- an answer is admissible only from the device the request named;
- a duplicate request id is ignored and only the first answer counts, so a
  replayed frame changes nothing;
- an answer may legitimately carry an earlier timestamp than its question (two
  phones, two clocks) and still counts — the two halves are matched by request
  id, never by journal position.

Conflict resolution is deterministic: the newest request supersedes an
unanswered earlier one, an unanswered request expires after 10 minutes rather
than sitting on the leader's screen for the rest of the ride, a target who
leaves stops being the TEC whether or not they had accepted, and a request
issued while its author was leader survives a later handover while a former
leader can no longer issue one. When two riders hold the role at once — one
self-selected, one asked — `LeaderRideStatusCalculator.resolveTecTarget` takes
the leader's most recently accepted request as the tie-break; with no assignment
its previous newest-fix ordering is unchanged, and an assignment never invents a
TEC who is not registered.

Degradation is named in both directions. If the negotiated relay lacks
`tec-role-assignment-v1` nothing is recorded at all and the leader is told the
service cannot pass the request on; if live presence has already identified the
target's build as older, the leader is told so by name before asking. Neither
case leaves a request looking sent.

## Hazards

Rider reports have type, severity, coordinates, source, reporter, confirmations,
and expiry. A report of the same type within 75 m and 30 minutes confirms the
existing report rather than creating a duplicate. Expired hazards disappear on
load or refresh; clearing creates a durable event.

Riders raise one thing from the ride map: an **alert** (#849). It is a hazard of
kind `alert`, raised with a single tap, and it says nothing about what was seen —
it could be police, a speed camera or anything else. It replaced the choice
between a speed camera and the police, which a rider in gloves on a moving bike
had no second tap to spend on. A rider-raised alert is a first-hand observation by
the person raising it, which is a different thing from redistributing a
provider's data, and it is the report the group most wants.

An alert expires after one hour — the shorter of the two lifetimes the kinds it
replaced had (two hours for a camera, one for police), because it is usually a
mobile van or a patrol car that moves on, and a stale one would raise a warning
for the whole group. It is never merged with another alert, however close: two
riders raising one at the same place are two sightings, each with its own time.
A second tap from the same rider inside five seconds is the first one bouncing on
a gloved thumb and is the same alert. Road defects (potholes, debris, roadworks)
are still reported by their own kinds from the awareness screen, and still
confirm one another within 75 m and 30 minutes.

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

## Alert warnings (formerly enforcement warnings)

Three hazard kinds get the most prominent treatment in the app: the rider alert,
and the speed-camera and police kinds that builds before #849 raised. Rider
reports are currently the only source of them: no enforcement provider is
configured and none is eligible, so the detector below is deliberately
source-agnostic and a licensed feed would need no new UI. `EnforcementAlertDetector`
watches the rider's own position and raises `EnforcementAlert` for the nearest one
**ahead**; the map then shows an announcement bubble and a border, with a live
distance countdown, and the natural voice says it once.

**#849 migrated this behaviour; it did not copy it.** The alert joined the two
kinds the detector already knew (`enforcementHazardTypes`), so it arms, holds,
expires, speaks and draws through exactly the code #112, #135, #418, #446, #471 and
#544 built. The bubble and the voice say `ALERT` / "Alert ahead" for the alert and
`SPEED CAMERA` / `POLICE` for the older kinds, which are still read, warned about
and listed — a mixed group is the normal case while testers update, and an older
rider's report must not go quiet on a newer rider's phone.

Deliberate choices:

- **Speed-aware, not a fixed distance.** The warning aims for about 30 seconds of
  approach from the rider's speed, bounded between 250 m and 1 km, with 400 m used
  while there is no speed sample (#471). Once armed it stays for the whole
  approach, even if the rider slows.
- **Ahead, not merely nearby.** With a route loaded, "ahead" is decided by
  position along that route, so one already passed or on the opposite carriageway
  stops warning. Without a route it falls back to comparing the bearing against
  the direction of travel. A fix with no usable heading warns anyway — a false
  warning costs a glance, a missed one costs more.
- **Any confidence.** An alert warns regardless of how many riders have confirmed
  it.
- **Never a reroute trigger.** These kinds are excluded from the leader's
  traffic-reroute candidates at both the shell and the provider. The rider is
  warned; the group's authoritative route is not redrawn around it.
- **Announce briefly, then hold** (#446). The bubble is up for ten seconds and the
  border holds for the rest of the approach, inside the rounded display corners
  (#544).
- **Held back in France.** France prohibits carrying or using devices that warn of
  enforcement controls. The alert could be exactly that, so it is held to the same
  rule as the two kinds it replaced: it cannot be raised in France, and one that
  arrives from there is stored but not presented. Road hazards stay available.
- Dismissal is per hazard, so passing one and approaching the next raises a fresh
  warning.

### Raising an alert

A `REPORT` control sits on the ride map's single action row, beside `ALERT` (SOS)
and `LEAVE`: it is a ride action, not a route action, so it is present with or
without a GPX. It is **96 pt square** in both orientations, up from 62 — a tester
asked for it bigger — and no taller than the SOS-over-LEAVE pair beside it in
portrait, so the bottom band the camera measures is no taller than it was. It is
amber on a dark ink so it reads through a visor and is not taken for SOS, which is
red. Its label stays `REPORT`: `ALERT` is already the SOS control's own word, and
two controls side by side with the same name is how the wrong one gets pressed.
What the *group* sees is "Alert".

**One tap, no sheet, no choice, no confirmation.** A stray tap costs a glance on
everyone else's screen; the two-tap design it replaced cost the warning, because
the second tap was the one a gloved rider did not have. The button says it took —
`SENT` for three seconds — because a rider in gloves cannot feel the tap, and the
map says so too. Taps while an alert is going out are ignored.

An alert is stored and sent **outside the controller's busy guard**. That guard
drops a call that arrives while another is in flight, and location fixes and the
leader's five-minute traffic fetch both hold it, the latter for a network round
trip; a dropped alert would show the rider "sent" and warn nobody. A failure is
thrown to the map, which says "Alert not sent" rather than showing `SENT`.

The CarPlay report sheet offers the same single `Alert` (and `Road hazard`, which
stays available in France), reported through the same path.

### The ride review (#849)

Every alert is saved with its time to the second, where the rider was, and who
raised it, and listed once the ride is over:

- **Ride ended** and **Previous rides → a ride** show an alerts card: each time in
  the phone's own time zone, to the second, with the raiser and the position. Tap
  a time to copy it as `2026-10-04 14:32:07`, the form a dash-cam player shows;
  **Copy all** copies a line per alert with the UTC time as well, for a ride
  reviewed in another time zone than it was ridden in (the footage's clock does not
  follow the phone's).
- **Previous rides** plots each alert on the ride map, labelled with its time, above
  the track.
- **GPX export** (the ride-ended share and a previous ride's export) writes each
  alert as a `<wpt>` — time in UTC as GPX requires, the clock time in the name, who
  and when in the description, symbol `Danger Area` — and the shared summary text
  and CSV list them.

The log is a reduction of the same signed `hazardReported` journal events the live
warning is built from (`RideAlertLogReducer`), not a second record, so the two
cannot disagree. It counts alerts and the older camera and police kinds *when a
rider raised them*; hazards from a data provider are not alerts. It is not limited
to what is still active: an alert leaves the warning after an hour and must not
leave the log, whose whole use is afterwards. A malformed or forged event is
skipped, never allowed to break the rest.

Alerts are kept on the completed ride as their own list, **not** among the
waypoints of its recorded route. That route is offered back as a route to ride
again, and an alert is not somewhere to ride to. For the same reason the GPX marks
each alert waypoint with a `tec:alert` extension, and the GPX importer drops any
waypoint carrying it: every other `<wpt>` is read back as a named stop.

### Compatibility with builds that predate it (#849)

Testers' phones on 1.0.1+101 will meet this build in the same group. Nothing
needed a new event type, a relay capability or a server change: an alert is an
ordinary `hazardReported` event.

- **An alert on an older phone.** An older build decodes a hazard's `type` with
  `HazardType.values.byName`, which throws on a name it does not know, and the
  journal replays that decode every time the ride restarts — so one unknown name
  would not just drop the alert, it would stop the ride opening. An alert is
  therefore written as an ordinary `other` hazard carrying one extra key,
  `kind: alert` (`HazardReportWire`). The older build ignores the key and shows an
  "Other hazard" at the right place, with no warning and no speech, which is the
  honest degradation: it does not know what this is. The marker wins over `type`
  when this build reads, so a later build may choose a different legacy-safe type.
- **An older phone's report on this one.** A speed camera or police hazard still
  decodes as itself, is still warned about, still draws its own symbol, and is
  logged as an alert, with what the older rider said it was.
- `alert_protocol_compat_test.dart` holds this in both directions against a frozen
  restatement of how 1.0.1+101 decodes and presents a hazard, and fails if a new
  hazard kind puts a name on the wire that build cannot decode.

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
