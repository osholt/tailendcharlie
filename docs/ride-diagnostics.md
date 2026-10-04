# Recording a ride to explain a wrong instruction

## Why it exists

The ride of 10 August 2026 produced four reports that cannot be acted on from a
description:

- #412 — a roundabout exit named "right" when it was straight on. Two candidate
  causes with **different fixes**: the app reasoning from the wrong bearings, or
  bucketing a real turn as straight inside the ±38° band.
- #409 — the spoken instruction arriving after the manoeuvre. "After" is a
  number, not an impression.
- #418 — whether the enforcement warning clears itself on passing.
- #414 — when a recalculation happened.

The per-manoeuvre sheet from #302 can answer the first, but only if a rider stops,
opens **All turns for this route** and taps the junction they remember. That is
not something to ask of someone on a motorcycle.

So the app writes down what it said, and then what the bike did, and the
discrepancy is computed rather than recalled. #408 is the standing reminder of why
that matters here: the "obvious fix" to a roundabout report would have drawn the
illegal manoeuvre, and only reading the code carefully stopped it.

## Two gates

1. **Compile time.** `RideDiagnosticsConfiguration.enabled` is a `const` read of
   `RIDE_RELAY_RIDE_DIAGNOSTICS`. Without the define the recorder is tree-shaken
   out, and `RideDiagnosticsController.isOn` reads `false` whatever storage says —
   so a phone that ran an instrumented build with the switch on, and then took an
   ordinary build over the top, does not quietly keep recording.
2. **In-app switch.** **Settings → Record ride diagnostics**, off by default. The
   row says what it records in plain words; a rider who finds it on should not
   have to infer "records where I went" from the word "diagnostics".

There is no third gate, unlike the test-control surface. That one accepts requests
from another machine, so it also needs a bearer token and an idle timeout. Nothing
reaches this from outside, and nothing leaves until the rider picks a recipient.

Tester builds carry the define (`android-internal.yml`, `testflight.yml`). The
switch is still off until a tester turns it on.

## What is in the file, and what is not

Recorded:

- each manoeuvre, as the report `maneuverDiagnosticsReport` renders for the #302
  sheet — engine type and modifier, both bearings, the heading change, the
  straight band, exit number, driving side, steps merged — plus where it was;
- `RIDDEN`: the heading change the bike actually made through that junction;
- each spoken prompt, with the distance to the junction when it fired;
- enforcement warnings arming and clearing, and how they cleared;
- route recalculations;
- **how updates reached this phone (`TRANSPORT`, #855)**, in a group ride; see below.

Not recorded, deliberately:

- **any other rider's position.** Someone else's data.
- **any rider's name, Bluetooth device name or endpoint id.** Other phones are
  `phone A`, `phone B` in the order they were first seen;
- ride secrets, invite secrets, join tokens, bearer tokens;
- emergency-contact or ICE detail.

The same exclusions `testControlForbiddenActions` documents, for the same reasons.

## Transport evidence: did phone-to-phone sharing work? (#855)

A group ride's log answers a second question, the one the 4 October ride could not:
was another rider's position delivered by the phone signal or by the direct
phone-to-phone link? The ride service is always listening, so a good signal hides
the direct link; the log therefore records **which route delivered each update and
which was first**, as `TRANSPORT` lines:

| Line | When it is written |
| --- | --- |
| `bluetooth searching  0 phones` | the direct link's state changes, with the number of phones; also a new platform problem on the same state |
| `bluetooth peer connected  phone A  (1 phone now)` | a phone joins the link; `peer lost` when one goes |
| `internet sync ok` / `internet sync failing  retrying` | the ride service starts failing, and `(recovered after N failed attempts, S s)` when it answers again. Only the transitions: a phone with no signal does not write a line per retry |
| `bluetooth summary` / `internet summary` | about once a minute: `events` received over that route, `first` (delivered before the other route did), `presence` (live-position updates) and the age of the **least recently heard** rider, each with the change since the previous summary in brackets |
| `verdict` | once, as the ride ends: the same sentence the ride-ended screen shows |

Peers are labelled per **connection**: the platform's endpoint ids change on
reconnection, so `phone C` can be `phone A` again after it dropped out. Counts and
times only; free text from a platform message has any endpoint id or rider name
replaced before it is written. How to read these lines, and the airplane-mode check
that settles the question, are in
[field-test-plan.md](field-test-plan.md#proving-bluetooth-peer-to-peer).

## Reading it

The interesting line is the pair:

```
MANOEUVRE  at 51.454500, -2.587900
           Shown as:         right (roundabout)
           Engine modifier:  straight
           Modifier reads as: straight on (joining the ring, not the exit)
           Bearing before:   10.0°
           Bearing off ring: 100.0°
           Read from:        the roads either side of the ring, on the route line
           Engine at ring:   12.0° in, 300.0° onto the ring
           Heading change:   +90.0° (clockwise, to the right)
           Straight band:    ±38°
           Geometry reads as: right
RIDDEN     right
           actual approach 0.0°
           actual departure 0.0°
           actual change   0.0° (straight on)
```

That example is #412: the app called a 90° right, the bike went straight on.

For a roundabout, `Bearing before`, `Bearing off ring` and `Heading change` are
always the pair the instruction was worked out from, so `Geometry reads as`
agrees with `Shown as` unless the engine reported a `roundabout turn`, whose
modifier states the whole turn. `Read from` says where that pair came from: the
roads either side of the ring on the route's own line (about 45–145 m clear of
it, shortened before a neighbouring junction), or the engine's bearings where
the line could not be read. `Engine at ring` and the engine's modifier on a
`roundabout`/`rotary` step describe joining the ring, not the direction through
the junction. Until #856 a capture paired the engine's approach with the line's
departure, so the Aust roundabout read "straight on" beside "1st exit, left".

- **`Bearing before` does not match the road the rider approached on** → the app
  reasoned from the wrong reference. `Read from` says which reference it was.
- **The bearings match and `Heading change` sits inside ±38° for a turn the rider
  really made** → the bucketing is at fault, and
  `_roundaboutStraightBandDegrees` is the number to argue about.

Those have different fixes, which is the whole reason for capturing rather than
guessing.

## Getting it

```bash
flutter build apk --debug --dart-define=RIDE_RELAY_RIDE_DIAGNOSTICS=true
```

Turn the switch on, ride, then hand the log over any of these ways. The
attachment is `tail-end-charlie-diagnostics-<code>.txt` and the share sheet
includes Mail.

| Where | What it gives |
| --- | --- |
| **Settings → Recorded rides** | The log on its own, for any of the last few recorded rides. Works from anywhere, at any time, including long after the ride. A Where To navigation is listed as **Where To navigation**, a ride by its code. |
| **Ride ended → Share ride diagnostics** | The group (or solo) ride's log on its own, by name, the way a Where To ride offers its own. Only shown when the ride was recorded. |
| **Ride ended → Share ride summary** | The log beside the summary CSV and the GPX track. |
| **Ride menu → Share ride summary**, mid-ride | The same three, while still riding. |
| **End this ride? → Share summary** | The same three. Ride leader only. |

The switch can be turned on **mid-ride** and recording starts there and then;
the log opens with a note saying so, since a record that begins halfway
through and does not say so reads as a whole ride with a quiet first half.
Turning it off mid-ride stops recording and keeps what was already gathered.

There is no order to get right and no moment to catch. That is deliberate: the
first recorded ride was lost because the log left the phone through exactly one of
those doors, and the rider used a different one (#456).

## Bounds worth knowing

- The log holds at most `RideDiagnosticsConfiguration.maximumEntries` entries and
  drops the oldest first, **saying how many it dropped**. Silent truncation reads
  as a complete record, which is worse than a short one.
- Position fixes are held in a short buffer, not logged. A fix a second for three
  hours is ten thousand lines of nothing; what matters is the two either side of
  each junction.
- The log is written to disk as it records, so a ride that ends with the app killed
  or the battery flat still leaves a file. Writes are coalesced — one at a time,
  with a single follow-up covering anything recorded while one was in flight — so a
  burst of entries costs one extra write rather than one each.
- `FileRideDiagnosticsLogStore.maximumRetainedLogs` **rides** are kept and the
  oldest dropped, and `maximumRetainedPersonalLogs` **Where To navigations**
  separately. Bounded because a log holds a route, and keeping every one forever
  would quietly accumulate a location history the rider never asked for. They are
  counted apart because every Where To navigation writes a log, and an afternoon
  of replanning legs writes enough of them to push a group ride's log out of one
  shared pool of five (#855).
- **A ride's log is continued, not replaced, when its screen is rebuilt.** The log
  is stored whole under the ride id and the recorder lives with the ride screen.
  Stepping away from a running ride and rejoining it, or a relaunch mid-ride, builds
  a new recorder; it now reads the stored log back first (the writer waits for
  that), carries the earlier entries in front of its own and marks the join with
  `recording continued`. Before this the new recorder's first write replaced the
  file, so a long group ride with a café stop in it kept only its last stretch.
- **A ride that has already ended is not recorded again.** The ride-ended screen
  returns after an app relaunch with a new shell under it; starting a recorder
  there rewrote the stored log of the finished ride with its own two lines
  (`recording started`, `ride completed`). It reads the stored log instead.
- Ordering comes from the `Written:` line in the log's own header, **not** from the
  file's modification time, which has one-second resolution: two logs written in
  the same second tie, and a tie makes the sort order arbitrary. That is invisible
  on real rides and immediately visible in a test, which is how it was found —
  pruning kept the right number of logs and dropped the wrong ones.
