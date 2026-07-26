import 'dart:math' as math;

import '../domain/geo_point.dart';
import '../domain/hazard.dart';
import 'geo_calculations.dart';

/// Hazard types riders want the earliest and loudest warning about.
const enforcementHazardTypes = <HazardType>{
  HazardType.speedCamera,
  HazardType.policeActivity,
};

/// A single enforcement hazard the rider is approaching.
class EnforcementAlert {
  const EnforcementAlert({required this.hazard, required this.distanceMeters});

  final HazardReport hazard;

  /// Distance still to run. Measured along the route when one is loaded, and
  /// straight-line otherwise, so it never reads shorter than the ride ahead.
  final double distanceMeters;

  @override
  bool operator ==(Object other) =>
      other is EnforcementAlert &&
      hazard.id == other.hazard.id &&
      distanceMeters == other.distanceMeters;

  @override
  int get hashCode => Object.hash(hazard.id, distanceMeters);
}

/// Finds the nearest enforcement hazard ahead of the rider.
///
/// "Ahead" is deliberately conservative in both directions: a camera on the
/// opposite carriageway or one already passed must stop alerting, but a real
/// one must never be missed, so a hazard with no usable direction evidence is
/// still announced.
class EnforcementAlertDetector {
  const EnforcementAlertDetector({
    this.warningDistanceMeters = 1609.344,
    this.routeCorridorMeters = 250,
    this.aheadHeadingToleranceDegrees = 75,
  });

  /// One mile. The rider asked for at least half a mile of warning; starting a
  /// full mile out leaves room to react at national-speed-limit pace.
  final double warningDistanceMeters;

  /// How far off the loaded route a hazard may sit and still count as on it.
  final double routeCorridorMeters;

  /// Without a route, how far a hazard's bearing may differ from the direction
  /// of travel before it is treated as behind or on another road.
  final double aheadHeadingToleranceDegrees;

  EnforcementAlert? detect({
    required GeoPoint? position,
    required List<HazardReport> hazards,
    required DateTime now,
    double? headingDegrees,
    List<GeoPoint> route = const [],
  }) {
    if (position == null) return null;
    final candidates = hazards.where(
      (hazard) =>
          enforcementHazardTypes.contains(hazard.type) &&
          hazard.isActiveAt(now),
    );
    if (candidates.isEmpty) return null;

    final hasRoute = route.length >= 2;
    final riderAlongRoute = hasRoute
        ? GeoCalculations.projectOntoPolyline(position, route)
        : null;

    EnforcementAlert? nearest;
    for (final hazard in candidates) {
      final distance = _distanceAhead(
        position: position,
        headingDegrees: headingDegrees,
        hazard: hazard.position,
        route: hasRoute ? route : const [],
        riderDistanceAlongRouteMeters:
            riderAlongRoute?.distanceAlongRouteMeters,
      );
      if (distance == null || distance > warningDistanceMeters) continue;
      if (nearest == null || distance < nearest.distanceMeters) {
        nearest = EnforcementAlert(hazard: hazard, distanceMeters: distance);
      }
    }
    return nearest;
  }

  double? _distanceAhead({
    required GeoPoint position,
    required double? headingDegrees,
    required GeoPoint hazard,
    required List<GeoPoint> route,
    required double? riderDistanceAlongRouteMeters,
  }) {
    if (route.isNotEmpty && riderDistanceAlongRouteMeters != null) {
      final projection = GeoCalculations.projectOntoPolyline(hazard, route);
      if (projection.distanceFromRouteMeters <= routeCorridorMeters) {
        final remaining =
            projection.distanceAlongRouteMeters - riderDistanceAlongRouteMeters;
        // Behind the rider along the planned route.
        return remaining < 0 ? null : remaining;
      }
      // Off the route corridor entirely: fall through to the heading test so a
      // hazard on a leg the rider has diverted onto is still announced.
    }
    final straightLine = GeoCalculations.distanceMeters(position, hazard);
    if (headingDegrees == null || !headingDegrees.isFinite) {
      return straightLine;
    }
    final bearing = _bearingDegrees(position, hazard);
    final difference = _headingDifference(headingDegrees, bearing);
    return difference > aheadHeadingToleranceDegrees ? null : straightLine;
  }
}

double _bearingDegrees(GeoPoint from, GeoPoint to) {
  final fromLatitude = from.latitude * math.pi / 180;
  final toLatitude = to.latitude * math.pi / 180;
  final longitudeDelta = (to.longitude - from.longitude) * math.pi / 180;
  final y = math.sin(longitudeDelta) * math.cos(toLatitude);
  final x =
      math.cos(fromLatitude) * math.sin(toLatitude) -
      math.sin(fromLatitude) * math.cos(toLatitude) * math.cos(longitudeDelta);
  return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
}

double _headingDifference(double first, double second) {
  final difference = (first - second).abs() % 360;
  return math.min(difference, 360 - difference);
}
