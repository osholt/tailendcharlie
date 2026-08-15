import 'dart:math' as math;

import '../domain/imported_route.dart';
import 'route_progress.dart';

/// Route-wide information shown on the phone and CarPlay map (#413).
class RouteJourneyProgress {
  const RouteJourneyProgress({
    required this.remainingDistanceMeters,
    required this.remainingTime,
    required this.arrivalTime,
    required this.nextWaypointName,
    required this.nextWaypointDistanceMeters,
    required this.nextWaypointArrivalTime,
  });

  final double remainingDistanceMeters;
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

/// Maintains a stable ETA without pretending that standing still means arrival.
///
/// App-planned routes retain the routing engine's duration, which seeds an ETA
/// before movement. Valid moving fixes then refine that expected average speed
/// exponentially; a zero-speed fix at lights leaves the last estimate in place.
/// Imported tracks with neither planned timing nor movement remain unavailable
/// rather than receiving an invented estimate.
class RouteJourneyProgressTracker {
  RouteJourneyProgressTracker({this.minimumEtaSpeedMetersPerSecond = 3});

  final double minimumEtaSpeedMetersPerSecond;

  String? _routeFingerprint;
  double? _estimatedSpeedMetersPerSecond;

  void reset() {
    _routeFingerprint = null;
    _estimatedSpeedMetersPerSecond = null;
  }

  RouteJourneyProgress? update({
    required ImportedRoute? route,
    required RouteProgressGeometry geometry,
    required double? speedMetersPerSecond,
    required DateTime now,
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
      _estimatedSpeedMetersPerSecond =
          plannedSeconds == null || plannedSeconds <= 0
          ? null
          : geometry.totalMeters / (plannedSeconds / 1000);
    }

    if (speedMetersPerSecond != null &&
        speedMetersPerSecond.isFinite &&
        speedMetersPerSecond >= minimumEtaSpeedMetersPerSecond &&
        speedMetersPerSecond <= 70) {
      final previous = _estimatedSpeedMetersPerSecond;
      _estimatedSpeedMetersPerSecond = previous == null
          ? speedMetersPerSecond
          : previous * 0.8 + speedMetersPerSecond * 0.2;
    }

    final remaining = math
        .max(0.0, geometry.totalMeters - geometry.progressMeters)
        .toDouble();
    final speed = _estimatedSpeedMetersPerSecond;
    final remainingTime = speed == null
        ? null
        : Duration(seconds: (remaining / speed).round());
    final next = _nextWaypoint(
      route,
      progressMeters: geometry.progressMeters,
      totalMeters: geometry.totalMeters,
    );
    final nextDistance = next == null
        ? null
        : math
              .max(0.0, next.progressMeters - geometry.progressMeters)
              .toDouble();
    final nextTime = speed == null || nextDistance == null
        ? null
        : Duration(seconds: (nextDistance / speed).round());

    return RouteJourneyProgress(
      remainingDistanceMeters: remaining,
      remainingTime: remainingTime,
      arrivalTime: remainingTime == null ? null : now.add(remainingTime),
      nextWaypointName: next?.name,
      nextWaypointDistanceMeters: nextDistance,
      nextWaypointArrivalTime: nextTime == null ? null : now.add(nextTime),
    );
  }
}

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
