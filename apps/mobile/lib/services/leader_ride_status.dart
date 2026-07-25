import 'dart:math' as math;

import '../domain/geo_point.dart';
import '../domain/ride_role.dart';
import '../domain/rider_location.dart';
import '../domain/route_alert.dart';
import 'geo_calculations.dart';
import 'route_rejoin_planner.dart' show LeaderTrackExemption;

class LeaderOffCourseAlert {
  const LeaderOffCourseAlert({
    required this.riderId,
    required this.displayName,
    required this.level,
    this.distanceFromRouteMeters,
  });

  final String riderId;
  final String displayName;
  final RouteAlertLevel level;
  final double? distanceFromRouteMeters;
}

class LeaderRideStatus {
  const LeaderRideStatus({
    required this.offCourseAlerts,
    this.tecName,
    this.distanceToTecMeters,
    this.estimatedTimeToTec,
    this.tecLocationAge,
  });

  final String? tecName;
  final double? distanceToTecMeters;
  final Duration? estimatedTimeToTec;
  final Duration? tecLocationAge;
  final List<LeaderOffCourseAlert> offCourseAlerts;
}

class LeaderRideStatusCalculator {
  const LeaderRideStatusCalculator({
    this.defaultMovingSpeedMetersPerSecond = 13.4,
    this.maximumOnRouteDistanceMeters = 250,
    this.staleAfter = const Duration(minutes: 2),
    this.leaderTrackCorridorMeters = 120,
  });

  final double defaultMovingSpeedMetersPerSecond;
  final double maximumOnRouteDistanceMeters;
  final Duration staleAfter;

  /// Corridor around the leader's own recorded track inside which a rider is
  /// following the leader rather than off course. See [LeaderTrackExemption].
  final double leaderTrackCorridorMeters;

  /// [leaderTrail] is the leader's own recorded track. A rider inside its
  /// corridor is following the leader and is never counted as off course, even
  /// if a deviation alert for them arrived from a device that had not yet seen
  /// the leader leave the GPX.
  LeaderRideStatus? calculate({
    required RideRole localRole,
    required String localRiderId,
    required RiderLocation? localLocation,
    required List<RiderLocation> riderLocations,
    required List<RiderRouteAlert> routeAlerts,
    required List<GeoPoint> route,
    List<GeoPoint> leaderTrail = const [],
    DateTime? now,
  }) {
    if (localRole != RideRole.lead) return null;
    final evaluatedAt = now ?? DateTime.now();
    final currentRiderIds = riderLocations
        .map((location) => location.riderId)
        .toSet();
    final locationsById = {
      for (final location in riderLocations) location.riderId: location,
    };
    final currentOffCourseAlerts = <String, RiderRouteAlert>{};
    for (final alert in routeAlerts) {
      if (alert.riderId == localRiderId ||
          !currentRiderIds.contains(alert.riderId) ||
          alert.acknowledged ||
          alert.assessment.state != RouteTrackingState.offRoute ||
          !alert.assessment.coordinatorActionRequired) {
        continue;
      }
      final location = locationsById[alert.riderId];
      if (location != null &&
          LeaderTrackExemption.isFollowingLeaderTrack(
            position: location.sample.position,
            accuracyMeters: location.sample.accuracyMeters,
            leaderTrack: leaderTrail,
            corridorMeters: leaderTrackCorridorMeters,
          )) {
        continue;
      }
      final previous = currentOffCourseAlerts[alert.riderId];
      if (previous == null ||
          alert.assessment.evaluatedAt.isAfter(
            previous.assessment.evaluatedAt,
          )) {
        currentOffCourseAlerts[alert.riderId] = alert;
      }
    }
    final offCourseAlerts =
        currentOffCourseAlerts.values
            .map(
              (alert) => LeaderOffCourseAlert(
                riderId: alert.riderId,
                displayName: alert.displayName,
                level: alert.assessment.alertLevel,
                distanceFromRouteMeters:
                    alert.assessment.distanceFromRouteMeters,
              ),
            )
            .toList(growable: false)
          ..sort((first, second) {
            final byLevel = second.level.index.compareTo(first.level.index);
            return byLevel != 0
                ? byLevel
                : first.displayName.compareTo(second.displayName);
          });

    final tecCandidates =
        riderLocations
            .where(
              (location) =>
                  location.riderId != localRiderId &&
                  location.role == RideRole.tailEndCharlie,
            )
            .toList(growable: false)
          ..sort(
            (first, second) =>
                second.sample.recordedAt.compareTo(first.sample.recordedAt),
          );
    final tec = tecCandidates.firstOrNull;
    if (tec == null) {
      return LeaderRideStatus(offCourseAlerts: offCourseAlerts);
    }

    final age = tec.sample.ageAt(evaluatedAt);
    if (localLocation == null || age > staleAfter) {
      return LeaderRideStatus(
        tecName: tec.displayName,
        tecLocationAge: age,
        offCourseAlerts: offCourseAlerts,
      );
    }

    final distance = _distanceBetween(localLocation, tec, route);
    final movingSpeeds = [
      localLocation.sample.speedMetersPerSecond,
      tec.sample.speedMetersPerSecond,
    ].whereType<double>().where((speed) => speed >= 2).toList(growable: false);
    final speed = movingSpeeds.isEmpty
        ? defaultMovingSpeedMetersPerSecond
        : movingSpeeds.reduce((a, b) => a + b) / movingSpeeds.length;
    final seconds = distance < 25 ? 0 : (distance / speed).round();
    return LeaderRideStatus(
      tecName: tec.displayName,
      distanceToTecMeters: distance,
      estimatedTimeToTec: Duration(seconds: seconds),
      tecLocationAge: age,
      offCourseAlerts: offCourseAlerts,
    );
  }

  double _distanceBetween(
    RiderLocation lead,
    RiderLocation tec,
    List<GeoPoint> route,
  ) {
    if (route.length >= 2) {
      final leadProjection = GeoCalculations.projectOntoPolyline(
        lead.sample.position,
        route,
      );
      final tecProjection = GeoCalculations.projectOntoPolyline(
        tec.sample.position,
        route,
      );
      if (leadProjection.distanceFromRouteMeters <=
              maximumOnRouteDistanceMeters &&
          tecProjection.distanceFromRouteMeters <=
              maximumOnRouteDistanceMeters) {
        final alongRouteDistance =
            (leadProjection.distanceAlongRouteMeters -
                    tecProjection.distanceAlongRouteMeters)
                .abs();
        if (GeoCalculations.distanceMeters(route.first, route.last) <= 25) {
          var routeDistance = 0.0;
          for (var index = 1; index < route.length; index += 1) {
            routeDistance += GeoCalculations.distanceMeters(
              route[index - 1],
              route[index],
            );
          }
          return math.min(
            alongRouteDistance,
            math.max(0, routeDistance - alongRouteDistance),
          );
        }
        return alongRouteDistance;
      }
    }
    return GeoCalculations.distanceMeters(
      lead.sample.position,
      tec.sample.position,
    );
  }
}
