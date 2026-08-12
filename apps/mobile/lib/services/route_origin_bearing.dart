/// Which way the rider is pointing, told to the routing engine (#444).
///
/// ## The defect
///
/// > the new route **does not account for the current direction of travel**, so
/// > the first instruction it gives is often wrong and confusing — typically
/// > asking for a manoeuvre that only makes sense if the rider were facing the
/// > other way.
///
/// The rejoin request sent the rider's position and nothing else. A position on a
/// two-way road is ambiguous: the engine picks a direction, and half the time it
/// picks the one the rider is not facing. The first instruction is then a U-turn
/// dressed up as a left, at the moment a rider has least attention to spare and
/// least reason to doubt the app.
///
/// Both engines take a bearing on the origin waypoint. That is the standard fix
/// and it is what this supplies.
///
/// ## Why a speed floor
///
/// A heading from a stationary bike is noise — it is whatever the phone was
/// pointing at, which on a bike at a junction may be sideways or backwards.
/// Feeding that in would produce a *confidently* wrong first instruction, which
/// is the very defect being fixed rather than a smaller version of it.
///
/// So below the floor no bearing is sent at all and the engine guesses, exactly
/// as it did before. Guessing when nothing is known is honest; guessing from
/// noise is not.
library;

/// Below this, the heading is not trusted to describe the direction of travel.
///
/// The same 3 m/s the stopped-speed readout (#445) and the CarPlay estimate
/// (#452) use. One idea, one number.
const rejoinBearingMinimumSpeedMetersPerSecond = 3.0;

/// How far either side of the heading the engine may still choose a road.
///
/// Wide enough to survive GPS heading error and a bike that is leaning, narrow
/// enough to exclude the opposite carriageway — which is the whole point. ±60°
/// cannot admit a road running back the way the rider came.
const rejoinBearingToleranceDegrees = 60.0;

/// The bearing to send for the origin, or null when none should be.
double? rejoinOriginBearing({
  required double? headingDegrees,
  required double? speedMetersPerSecond,
}) {
  final heading = headingDegrees;
  final speed = speedMetersPerSecond;
  if (heading == null || !heading.isFinite) return null;
  if (heading < 0 || heading >= 360) return null;
  if (speed == null ||
      !speed.isFinite ||
      speed < rejoinBearingMinimumSpeedMetersPerSecond) {
    return null;
  }
  return heading;
}

/// OSRM's `bearings` parameter for a request with [waypointCount] coordinates.
///
/// The list must have exactly one entry per coordinate; entries may be empty,
/// which means "any direction". Only the origin is constrained — the rejoin point
/// and the target may be approached however the engine likes.
///
/// Returns null when there is no bearing to send, so the caller omits the
/// parameter entirely rather than sending a list of empties.
String? osrmBearings({
  required double? originBearingDegrees,
  required int waypointCount,
  double toleranceDegrees = rejoinBearingToleranceDegrees,
}) {
  final bearing = originBearingDegrees;
  if (bearing == null || waypointCount < 1) return null;
  final origin = '${bearing.round()},${toleranceDegrees.round()}';
  // One empty entry per remaining waypoint. OSRM rejects a list whose length
  // does not match the coordinates, so this is not cosmetic.
  return [origin, ...List.filled(waypointCount - 1, '')].join(';');
}
