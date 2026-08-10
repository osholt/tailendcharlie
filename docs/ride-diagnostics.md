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
- route recalculations.

Not recorded, deliberately:

- **any other rider's position.** Someone else's data.
- ride secrets, invite secrets, join tokens, bearer tokens;
- emergency-contact or ICE detail.

The same exclusions `testControlForbiddenActions` documents, for the same reasons.

## Reading it

The interesting line is the pair:

```
MANOEUVRE  at 51.454500, -2.587900
           Shown as:         right (roundabout)
           Bearing before:   10.0°
           Bearing off ring: 100.0°
           Heading change:   +90.0° (clockwise, to the right)
           Straight band:    ±38°
RIDDEN     right
           actual approach 0.0°
           actual departure 0.0°
           actual change   0.0° (straight on)
```

That example is #412: the app called a 90° right, the bike went straight on.

- **`Bearing before` does not match the road the rider approached on** → the app
  reasoned from the wrong reference. Look at where the roundabout entry
  manoeuvre's `bearingBeforeDegrees` comes from.
- **The bearings match and `Heading change` sits inside ±38° for a turn the rider
  really made** → the bucketing is at fault, and
  `_roundaboutStraightBandDegrees` is the number to argue about.

Those have different fixes, which is the whole reason for capturing rather than
guessing.

## Getting it

```bash
flutter build apk --debug --dart-define=RIDE_RELAY_RIDE_DIAGNOSTICS=true
```

Turn the switch on, ride, then share the ride at the end: the log is attached
beside the summary CSV and the GPX track, as
`tail-end-charlie-diagnostics-<code>.txt`. The share sheet includes Mail.

## Bounds worth knowing

- The log holds at most `RideDiagnosticsConfiguration.maximumEntries` entries and
  drops the oldest first, **saying how many it dropped**. Silent truncation reads
  as a complete record, which is worse than a short one.
- Position fixes are held in a short buffer, not logged. A fix a second for three
  hours is ten thousand lines of nothing; what matters is the two either side of
  each junction.
- Nothing is written to disk during the ride, so a ride that ends with the app
  killed or the battery flat leaves no file. That is a known gap — see #419 — and
  it matters most on exactly the ride worth capturing.
