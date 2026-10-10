/// Whether a moving rider is travelling *along* a route line, not merely near
/// it (#941).
///
/// ## The defect
///
/// Guidance judged "on the route" by distance alone: within 150 m of the line,
/// the next manoeuvre was presented. A manoeuvre's left, right or straight on is
/// relative to its planned approach, though. On the 10 October ride a rider
/// reached a pair of roundabouts on another arm, 43 m from the planned line and
/// heading 90° across the planned approach. They were told "take the exit
/// straight on" for the approach they were not on, took the exit straight ahead
/// of *them*, and were off route for eight minutes.
///
/// ## The rule
///
/// Near the line **and** heading along it. A rider whose usable heading is more
/// than [routeTravelHeadingToleranceDegrees] from every nearby piece of the
/// line is crossing it or riding against it.
///
/// Two things deliberately keep the old distance-only answer:
///
/// - **No usable heading.** Below the 3 m/s floor in `route_origin_bearing.dart`
///   a heading is whatever the phone was pointing at. Judging direction from it
///   would be guessing from noise.
/// - **Inside [routeTravelCorridorMeters] of the line.** GPS course lags through
///   a bend and round a ring. Lanes, carriageways and the drawn centreline also
///   sit about this far apart. A rider on the line is on it, whatever the last
///   course said, so the banner never blanks inside a junction.
library;

import 'dart:math' as math;

import '../domain/imported_route.dart';
import 'route_origin_bearing.dart';

/// What a rider's heading says about their relation to a route line.
enum RouteTravel {
  /// Travelling along the line, or on it.
  along,

  /// Near the line but heading across it or against it.
  across,

  /// No usable heading, or no line: direction says nothing either way.
  unknown,
}

/// Inside this, a rider is on the line whatever their heading.
const routeTravelCorridorMeters = 20.0;

/// Pieces of line this much further away than the nearest still count.
///
/// At a vertex both neighbouring segments are equally near, and where a route
/// uses a road twice (out and back, or a figure of eight) both directions are.
/// Either may be the one the rider is on.
const routeTravelNearbySlackMeters = 10.0;

/// How far a heading may differ from the line's direction and still be along
/// it. The same ±60° the reroute request gives the routing engine for the
/// rider's own heading: wide enough for GPS error and a leaning bike, too narrow
/// to admit a road crossing the line or running back the other way.
const routeTravelHeadingToleranceDegrees = rejoinBearingToleranceDegrees;

/// Whether a rider at [position], heading [headingDegrees] at
/// [speedMetersPerSecond], is travelling along [path].
///
/// The caller decides how near counts as near; this only says which way the
/// rider is going relative to the line around them.
RouteTravel routeTravel({
  required GeoPoint position,
  required List<GeoPoint> path,
  required double? headingDegrees,
  required double? speedMetersPerSecond,
}) {
  final heading = rejoinOriginBearing(
    headingDegrees: headingDegrees,
    speedMetersPerSecond: speedMetersPerSecond,
  );
  if (heading == null || path.length < 2) return RouteTravel.unknown;

  // A local plane around the rider, metres east and north. Exact enough for a
  // few hundred metres, and the only distances that matter here are that short.
  final cosLatitude = math.cos(position.latitude * math.pi / 180);
  double east(GeoPoint point) =>
      _longitudeDelta(point.longitude - position.longitude) *
      _metersPerDegree *
      cosLatitude;
  double north(GeoPoint point) =>
      (point.latitude - position.latitude) * _metersPerDegree;

  final segmentCount = path.length - 1;
  final distances = List<double>.filled(segmentCount, double.infinity);
  final bearings = List<double?>.filled(segmentCount, null);
  var nearest = double.infinity;
  var startEast = east(path.first);
  var startNorth = north(path.first);
  for (var index = 0; index < segmentCount; index += 1) {
    final endEast = east(path[index + 1]);
    final endNorth = north(path[index + 1]);
    final deltaEast = endEast - startEast;
    final deltaNorth = endNorth - startNorth;
    final lengthSquared = deltaEast * deltaEast + deltaNorth * deltaNorth;
    if (lengthSquared > 0) {
      final fraction =
          (-(startEast * deltaEast + startNorth * deltaNorth) / lengthSquared)
              .clamp(0.0, 1.0);
      final nearestEast = startEast + fraction * deltaEast;
      final nearestNorth = startNorth + fraction * deltaNorth;
      final distance = math.sqrt(
        nearestEast * nearestEast + nearestNorth * nearestNorth,
      );
      distances[index] = distance;
      bearings[index] =
          (math.atan2(deltaEast, deltaNorth) * 180 / math.pi + 360) % 360;
      if (distance < nearest) nearest = distance;
    }
    startEast = endEast;
    startNorth = endNorth;
  }
  if (!nearest.isFinite) return RouteTravel.unknown;
  if (nearest <= routeTravelCorridorMeters) return RouteTravel.along;
  for (var index = 0; index < segmentCount; index += 1) {
    final bearing = bearings[index];
    if (bearing == null ||
        distances[index] > nearest + routeTravelNearbySlackMeters) {
      continue;
    }
    if (_bearingDifference(heading, bearing) <=
        routeTravelHeadingToleranceDegrees) {
      return RouteTravel.along;
    }
  }
  return RouteTravel.across;
}

const _metersPerDegree = 6371008.8 * math.pi / 180;

double _longitudeDelta(double delta) => ((delta + 540) % 360) - 180;

double _bearingDifference(double first, double second) {
  final difference = (first - second).abs() % 360;
  return difference > 180 ? 360 - difference : difference;
}
