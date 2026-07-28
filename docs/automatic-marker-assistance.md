# Automatic marker assistance development alpha

Marker assistance is deliberately advisory. It never changes a rider's role or
starts marker mode by itself. A suggestion opens a review action, followed by a
separate large **Start marking** confirmation. Moving away or dismissing the
suggestion starts a cooldown.

## Suggestion contract

`MarkerSuggestionDetector` is a deterministic state machine. A suggestion needs
all of the following:

- an imported route with an explicit waypoint or a geometric turn of at least
  35 degrees;
- a recent, accurate local position within 35 m of that decision point;
- local speed below 0.8 m/s for 12 seconds, with 1.8 m/s exit hysteresis;
- at least one recent group rider at least 45 m farther along the route who is
  within 80 m of the route and moving at least 3 m/s or has advanced at least
  20 m between observations. Riders already in marker mode are excluded.

The defaults are conservative starting assumptions, not validated safety
thresholds. A rider dismissal cools suggestions down for five minutes. Movement
cancellation cools them down for two minutes. Active marker mode suppresses
suggestions completely.

For multi-path GPX files, the development alpha monitors the longest continuous
path rather than creating synthetic junctions between disconnected segments.

## What a suggested marking position is scored on

Marking exists so nobody misses a turn **the group is taking**. A road the route
does not use needs no marker, however junction-like it looks. A cul-de-sac mouth
is topologically a junction, so a detector scoring by the degree of the graph
node cannot tell a turn a rider might take from one nobody will — and it sent a
tester to the end of a no-through road (#179).

`RouteMarkerPlanAnalyzer` therefore no longer treats the route-engine manoeuvre
type as sufficient. A manoeuvre earns a suggestion only where the group's own
ridden line is ambiguous, measured against the primary ridden path — the longest
one, the same path `RouteProgressTracker` measures progress against:

1. **On the ridden line.** The manoeuvre must lie within 30 m of it. Manoeuvres
   accumulate for every path in the file, and exports commonly carry the same
   journey twice, so manoeuvres for a road the group will not ride were being
   suggested.
2. **The line must deviate.** The ridden line's heading must change by at least
   20°, or the engine must report a genuine branch choice for the route itself —
   a fork, roundabout or rotary. A junction the group rides straight through is
   what a passed cul-de-sac mouth, a side road and a farm track all look like.
   The heading comes from the engine's own `bearing_before`/`bearing_after` when
   it reports them, otherwise from the ridden geometry over a ±30 m window. A
   reading that cannot be taken at all leaves the gate open: it closes on
   evidence that the group rides straight through, never on the absence of it.
3. **The line must not double back.** A reversal of 150° or more, or a `uturn`
   modifier, means the manoeuvre is inside a no-through road. Everyone comes back
   out the way they went in, so nothing can be missed and a marker there is a
   rider sent to a dead end. Roundabouts and rotaries are excepted: their ring
   geometry legitimately reverses, and riders do miss exits.

Junction degree — how many roads meet — is not scored at all.
`RouteDecisionPointExtractor`, which feeds the live detector, gained the same
doubling-back bound: a 35°–150° band rather than a floor alone.

## Reviewing the suggestions

Assistance only ever suggests and the rider confirms, so rejection is the
missing half rather than a new principle. `MarkerPlanReview` records, per route,
which suggestions a person rejected and which junctions the detector missed and
they added. It rides inside the route document rather than a side store, so a
rejection sticks for that route through save, restart and hand-off, and the same
JSON is available to any other surface. Decisions carry a position as well as an
identifier, because a manoeuvre identifier is only an index into one routing
reply: a reroute renumbers them, a position still names the same place.

Both detectors read it. The plan drops rejected positions and adds manual ones;
the live detector receives the same rejections and additions as decision points,
so a position rejected before the ride does not raise a suggestion during it.

### Which surface does what

- **The app's route review screen** is the review surface today. It lists every
  suggested position with a reject control, keeps rejected ones visible so they
  can be restored, and offers the junctions the gates dropped so a missed one can
  be added. This runs at import and reroute time, before the route is confirmed.
- **The app's live map** handles the change on the day: tapping a suggested
  position offers to reject it for the route, and the decision is stored and
  republished immediately. Leader-only, like every other route edit.
- **The web planner** is the natural home for review at leisure and is where this
  should end up under #23, but it is not built here. It has no marker plan at
  all today, so adding review would mean a second implementation of the scoring
  rule in JavaScript — the exact way two surfaces come to disagree about which
  positions exist. The route JSON it produces can already carry a review, so the
  planner can adopt it without changing the model.

## Verified pass counting

`MarkerPassDetector` fixes the marker position when marker mode starts. A rider
must first be observed outside 60 m and then inside 30 m. The fix must be no more
than 20 seconds old, have accuracy of 40 m or better, and carry a location event
whose HMAC verifies for the ride and whose device identifier matches the rider.
Initially-near, stale, inaccurate, unauthenticated, and duplicate fixes do not
count.

This is group-secret authentication, not cryptographic proof of an individual
device identity. Per-member keys and revocation remain production security gates.

The resulting `markerPass` event records the marker session, location evidence
event, rider role and observation time. A verified Tail End Charlie passage is
shown as a prompt to finish when safe; it does not automatically end marker mode.

## Statistics and relay ordering

`MarkerStatistics` reduces append-only ride events into per-device,
per-marker-session summaries. Session identifiers prevent interleaved relay
events from different markers absorbing or closing each other. The local
dashboard shows local-device marking time, sessions, verified passes and verified
TEC passages. `rideEnded` persists the summary and keeps the durable ride session
available for final relay recovery for up to 24 hours. The rider can remove it
immediately; after that window the local session, group secret and event journal
are deleted automatically.

## Field-calibration gates

Before enabling the feature outside development alpha, complete controlled field
tests covering urban GPS multipath, staggered junctions, roundabouts, U-turns,
parallel roads, stopped traffic, very small groups, delayed relay events and TEC
role changes. Measure false suggestions, missed suggestions, false pass counts,
missed passes and time-to-cancel. Threshold changes must be based on those data.

The module uses only foreground positions already requested by the rider. It does
not start location services, declare background tracking, replace visual rider
checks, or provide an emergency-service function.
