import 'dart:math' as math;

import '../domain/imported_route.dart';
import 'route_progress.dart';

/// Route-wide information shown on the phone and CarPlay map (#413).
class RouteJourneyProgress {
  const RouteJourneyProgress({
    required this.remainingDistanceMeters,
    this.travelledDistanceMeters = 0,
    this.awaitingRejoin = false,
    required this.remainingTime,
    required this.arrivalTime,
    required this.nextWaypointName,
    required this.nextWaypointDistanceMeters,
    required this.nextWaypointArrivalTime,
  });

  final double remainingDistanceMeters;
  final double travelledDistanceMeters;
  final bool awaitingRejoin;
  final Duration? remainingTime;
  final DateTime? arrivalTime;
  final String? nextWaypointName;
  final double? nextWaypointDistanceMeters;
  final DateTime? nextWaypointArrivalTime;

  Map<String, Object?> toSnapshot() => {
    'remainingDistanceMeters': remainingDistanceMeters,
    'remainingSeconds': remainingTime?.inSeconds,
    'arrivalTimeMillis': arrivalTime?.millisecondsSinceEpoch,
    'nextWaypointName': nextWaypointName,
    'nextWaypointDistanceMeters': nextWaypointDistanceMeters,
    'nextWaypointArrivalTimeMillis':
        nextWaypointArrivalTime?.millisecondsSinceEpoch,
  };
}

/// Maintains an ETA from the routing engine's planned duration.
///
/// A GPS speed is instantaneous: junctions, traffic and short bursts make it a
/// poor estimate for the whole route. It is accepted by [update] because the
/// map and vehicle projections share this API, but it never changes the ETA.
/// Imported tracks without planned timing remain unavailable rather than
/// receiving an invented estimate from one speed reading. Road-matched routes
/// created before build 95 are the narrow exception: those builds discarded
/// timing that the matcher had returned, so they use a stable mixed-road
/// planning speed until the route is matched again.
class RouteJourneyProgressTracker {
  RouteJourneyProgressTracker();

  String? _routeFingerprint;
  double? _plannedAverageSpeedMetersPerSecond;

  void reset() {
    _routeFingerprint = null;
    _plannedAverageSpeedMetersPerSecond = null;
  }

  RouteJourneyProgress? update({
    required ImportedRoute? route,
    required RouteProgressGeometry geometry,
    required double? speedMetersPerSecond,
    required DateTime now,
    double durationFactor = 1,
    ImportedRoute? rejoinRoute,
    RouteProgressGeometry? rejoinGeometry,
  }) {
    if (route == null || geometry.totalMeters <= 0) {
      reset();
      return null;
    }
    final fingerprint =
        '${route.id}:${route.importedAt.toIso8601String()}:'
        '${route.pathPointCount}';
    if (_routeFingerprint != fingerprint) {
      _routeFingerprint = fingerprint;
      final plannedSeconds = route.plannedDuration?.inMilliseconds;
      _plannedAverageSpeedMetersPerSecond =
          plannedSeconds == null || plannedSeconds <= 0
          ? (_isLegacyRoadMatch(route)
                ? _legacyRoadMatchPlanningSpeedMetersPerSecond
                : null)
          : geometry.totalMeters / (plannedSeconds / 1000);
    }

    var alongProgress = geometry.progressMeters;
    var connectorDistance = 0.0;
    var awaitingRejoin = geometry.distanceOffRouteMeters > 150;
    Duration? connectorTime;
    if (rejoinRoute != null &&
        rejoinGeometry != null &&
        geometry.distanceOffRouteMeters > 50) {
      final endpoint = rejoinRoute.paths.lastOrNull?.points.lastOrNull;
      final join = endpoint == null
          ? null
          : routeRejoinProgress(route, endpoint, alongProgress);
      if (join != null &&
          join.distanceMeters <= 150 &&
          join.progressMeters >= alongProgress - 30) {
        awaitingRejoin = false;
        alongProgress = math.max(alongProgress, join.progressMeters);
        connectorDistance = math.max(
          0,
          rejoinGeometry.totalMeters - rejoinGeometry.progressMeters,
        );
        final duration = rejoinRoute.plannedDuration;
        if (duration != null && rejoinGeometry.totalMeters > 0) {
          connectorTime = Duration(
            milliseconds:
                (duration.inMilliseconds *
                        connectorDistance /
                        rejoinGeometry.totalMeters)
                    .round(),
          );
        }
      }
    }
    final plannedRemaining = math.max(
      0.0,
      geometry.totalMeters - alongProgress,
    );
    final remaining = plannedRemaining + connectorDistance;
    final baselineSpeed = _plannedAverageSpeedMetersPerSecond;
    final factor = durationFactor.isFinite
        ? durationFactor.clamp(.8, 1.2)
        : 1.0;
    final speed = baselineSpeed == null ? null : baselineSpeed / factor;
    final remainingTime = speed == null || awaitingRejoin
        ? null
        : Duration(
            seconds:
                (plannedRemaining / speed +
                        (connectorTime?.inSeconds ?? connectorDistance / speed))
                    .round(),
          );
    final next = _nextWaypoint(
      route,
      progressMeters: alongProgress,
      totalMeters: geometry.totalMeters,
    );
    final nextDistance = next == null
        ? null
        : math.max(0.0, next.progressMeters - alongProgress).toDouble() +
              connectorDistance;
    final nextTime = speed == null || nextDistance == null || awaitingRejoin
        ? null
        : Duration(
            seconds:
                ((nextDistance - connectorDistance) / speed +
                        (connectorTime?.inSeconds ?? connectorDistance / speed))
                    .round(),
          );

    return RouteJourneyProgress(
      remainingDistanceMeters: remaining,
      travelledDistanceMeters: geometry.travelledMeters,
      awaitingRejoin: awaitingRejoin,
      remainingTime: remainingTime,
      arrivalTime: remainingTime == null ? null : now.add(remainingTime),
      nextWaypointName: next?.name,
      nextWaypointDistanceMeters: nextDistance,
      nextWaypointArrivalTime: nextTime == null ? null : now.add(nextTime),
    );
  }
}

/// Conservative fixed planning speed for the historical road-match timing gap.
///
/// It is deliberately independent of GPS speed. Fifty kilometres per hour is
/// representative of a mixed town/country motorcycle route without claiming
/// to reconstruct the exact duration that old builds failed to persist.
const double _legacyRoadMatchPlanningSpeedMetersPerSecond = 50 / 3.6;

bool _isLegacyRoadMatch(ImportedRoute route) =>
    route.plannedDuration == null &&
    route.sourceFileName.startsWith('matched-') &&
    route.description?.contains('Road-matched from ') == true &&
    route.maneuvers.isNotEmpty;

_WaypointProgress? _nextWaypoint(
  ImportedRoute route, {
  required double progressMeters,
  required double totalMeters,
}) {
  final progresses = routeWaypointProgressMeters(route);
  _WaypointProgress? selected;
  for (
    var index = 0;
    index < route.waypoints.length && index < progresses.length;
    index += 1
  ) {
    final waypointProgress = progresses[index]
        .clamp(0.0, totalMeters)
        .toDouble();
    // Twenty metres stops the start waypoint, or a stop being ridden through,
    // from lingering as the next destination because of ordinary GPS error.
    if (waypointProgress <= progressMeters + 20) continue;
    final waypoint = route.waypoints[index];
    final name = _waypointName(
      waypoint,
      isFinal: index == progresses.length - 1,
    );
    final candidate = _WaypointProgress(
      name: name,
      progressMeters: waypointProgress,
    );
    if (selected == null ||
        candidate.progressMeters < selected.progressMeters) {
      selected = candidate;
    }
  }
  if (selected != null) return selected;
  if (totalMeters > progressMeters + 20) {
    return _WaypointProgress(name: 'Destination', progressMeters: totalMeters);
  }
  return null;
}

String _waypointName(RouteWaypoint waypoint, {required bool isFinal}) {
  final name = waypoint.name?.trim();
  if (name != null && name.isNotEmpty) return name;
  final description = waypoint.description?.trim();
  if (description != null && description.isNotEmpty) return description;
  return isFinal ? 'Destination' : 'Next stop';
}

class _WaypointProgress {
  const _WaypointProgress({required this.name, required this.progressMeters});

  final String name;
  final double progressMeters;
}
