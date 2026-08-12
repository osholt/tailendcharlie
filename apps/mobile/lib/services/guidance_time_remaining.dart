/// How long until the next manoeuvre, for the car's estimate (#452).
///
/// ## What was wrong
///
/// The CarPlay bridge sent `CPTravelEstimates(distanceRemaining:, timeRemaining: 0)`
/// — the distance was the point of #453 and the time was passed as zero because
/// nothing needed it. Zero is not "unknown". `CPTravelEstimates.h` is explicit:
///
/// > A distance value less than 0 or a time remaining value less than 0 will
/// > render as "--" in the ETA and trip preview cards, indicating that distance or
/// > time remaining are unavailable […] Values less than 0 are distinguished from
/// > distance or time values equal to 0; your app may display 0 as the user is
/// > imminently arriving at their destination.
///
/// So zero told the car the rider was *arriving now*, every update, and the car
/// dutifully rendered an arrival time of the current clock. It only visibly moved
/// when the estimates were refreshed after a route change, which is exactly what
/// was reported:
///
/// > If there was an ETA calculation going on, it was always showing the last time
/// > the route was rerouted.
///
/// ## Why the arithmetic is here and not in Swift
///
/// It is a decision with edge cases — no speed, a stationary bike, a nonsense fix
/// — and every one of them is reachable in a unit test here and reachable only by
/// riding there. Swift is left with one thing to do: pass this along, or pass a
/// negative when it is null.
library;

/// Below this, a speed cannot carry an estimate.
///
/// A bike at walking pace projects an absurd time — 400 m at 0.4 m/s is a
/// quarter of an hour — and a rider stopped at lights would watch the estimate
/// climb. Better "--" than a number that is wrong in a way the rider can see.
///
/// The same 3 m/s the stopped-speed readout uses (#445), for the same reason: it
/// is the speed below which a motorcycle is not really under way.
const guidanceEstimateMinimumSpeedMetersPerSecond = 3.0;

/// Seconds to the manoeuvre, or null when no honest estimate can be made.
///
/// Null rather than a fallback: an invented estimate on the car's ETA card is
/// indistinguishable from a real one, which is the whole defect being fixed.
double? guidanceSecondsRemaining({
  required double? distanceMeters,
  required double? speedMetersPerSecond,
}) {
  final distance = distanceMeters;
  final speed = speedMetersPerSecond;
  if (distance == null || !distance.isFinite || distance < 0) return null;
  if (speed == null ||
      !speed.isFinite ||
      speed < guidanceEstimateMinimumSpeedMetersPerSecond) {
    return null;
  }
  return distance / speed;
}

/// What Swift sends when there is no estimate.
///
/// Negative on purpose, per the header quoted above: it is the documented way to
/// say "unavailable" and renders as "--". Zero would say "arriving now".
const guidanceTimeRemainingUnavailable = -1.0;
