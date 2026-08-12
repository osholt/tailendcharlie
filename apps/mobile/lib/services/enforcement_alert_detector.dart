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
    this.targetWarningTime = const Duration(seconds: 30),
    this.minimumWarningDistanceMeters = 250,
    this.maximumWarningDistanceMeters = 1000,
    this.fallbackWarningDistanceMeters = 400,
    this.routeCorridorMeters = 250,
    this.aheadHeadingToleranceDegrees = 75,
  });

  /// The approach time the warning aims to provide.
  ///
  /// Thirty seconds works out at about 0.25 miles at 30 mph and 0.58 miles at
  /// 70 mph. That keeps an urban warning relevant without making a motorway
  /// warning late.
  final Duration targetWarningTime;

  /// Bounds protect the alert from a stopped or noisy speed sample.
  final double minimumWarningDistanceMeters;
  final double maximumWarningDistanceMeters;

  /// Used while the platform has no finite speed sample.
  final double fallbackWarningDistanceMeters;

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
    double? speedMetersPerSecond,
    String? activeHazardId,
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

    final warningDistance = _warningDistance(speedMetersPerSecond);
    EnforcementAlert? nearest;
    EnforcementAlert? active;
    for (final hazard in candidates) {
      final distance = _distanceAhead(
        position: position,
        headingDegrees: headingDegrees,
        hazard: hazard.position,
        route: hasRoute ? route : const [],
        riderDistanceAlongRouteMeters:
            riderAlongRoute?.distanceAlongRouteMeters,
      );
      if (distance == null) continue;
      // Once announced, keep the same warning stable until it is passed,
      // dismissed, or expires. Slowing for traffic must not make it vanish and
      // then re-arm as the speed-derived threshold contracts.
      if (hazard.id == activeHazardId) {
        active = EnforcementAlert(hazard: hazard, distanceMeters: distance);
        continue;
      }
      if (distance > warningDistance) continue;
      if (nearest == null || distance < nearest.distanceMeters) {
        nearest = EnforcementAlert(hazard: hazard, distanceMeters: distance);
      }
    }
    return active ?? nearest;
  }

  double _warningDistance(double? speedMetersPerSecond) {
    if (speedMetersPerSecond == null || !speedMetersPerSecond.isFinite) {
      return fallbackWarningDistanceMeters
          .clamp(minimumWarningDistanceMeters, maximumWarningDistanceMeters)
          .toDouble();
    }
    return (speedMetersPerSecond * targetWarningTime.inMilliseconds / 1000)
        .clamp(minimumWarningDistanceMeters, maximumWarningDistanceMeters)
        .toDouble();
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
