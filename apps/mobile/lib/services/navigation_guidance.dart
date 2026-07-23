import 'dart:math' as math;

import '../domain/imported_route.dart';

class NavigationGuidance {
  const NavigationGuidance({
    required this.maneuver,
    required this.distanceMeters,
  });

  final RouteManeuver maneuver;
  final double distanceMeters;

  String get roadLabel {
    final name = maneuver.name?.trim();
    final ref = maneuver.ref?.trim();
    if (name != null && name.isNotEmpty && ref != null && ref.isNotEmpty) {
      return name.contains(ref) ? name : '$name · $ref';
    }
    if (name != null && name.isNotEmpty) return name;
    if (ref != null && ref.isNotEmpty) return ref;
    return _sentenceCase(maneuver.type);
  }
}

/// Selects the next useful route-engine instruction from persisted route data.
///
/// Progress is supplied by the map's monotonic route tracker so self-crossing
/// routes do not jump backwards. A fresh geometric projection is still used to
/// suppress guidance when the rider is clearly away from the route.
class NavigationGuidancePlanner {
  const NavigationGuidancePlanner({
    this.maximumDistanceFromRouteMeters = 150,
    this.passedToleranceMeters = 25,
    this.maximumAdvanceDistanceMeters = 5000,
  });

  final double maximumDistanceFromRouteMeters;
  final double passedToleranceMeters;
  final double maximumAdvanceDistanceMeters;

  NavigationGuidance? plan({
    required ImportedRoute? route,
    required GeoPoint? position,
    required double progressMeters,
  }) {
    if (route == null ||
        position == null ||
        route.maneuvers.isEmpty ||
        route.paths.isEmpty) {
      return null;
    }
    final path = _primaryPath(route.paths);
    if (path.length < 2) return null;
    final riderProjection = _project(position, path);
    if (riderProjection.distanceMeters > maximumDistanceFromRouteMeters) {
      return null;
    }

    ({RouteManeuver maneuver, double remaining})? next;
    for (final maneuver in route.maneuvers) {
      if (!_isGuidanceInstruction(maneuver.type)) continue;
      final projection = _project(maneuver.position, path);
      if (projection.distanceMeters > maximumDistanceFromRouteMeters) continue;
      final remaining = projection.progressMeters - progressMeters;
      if (remaining < -passedToleranceMeters ||
          remaining > maximumAdvanceDistanceMeters) {
        continue;
      }
      if (next == null || remaining < next.remaining) {
        next = (maneuver: maneuver, remaining: remaining);
      }
    }
    if (next == null) return null;
    return NavigationGuidance(
      maneuver: next.maneuver,
      distanceMeters: math.max(0, next.remaining),
    );
  }
}

List<GeoPoint> _primaryPath(List<RoutePath> paths) {
  var selected = paths.first.points;
  var selectedLength = _pathLength(selected);
  for (final path in paths.skip(1)) {
    final length = _pathLength(path.points);
    if (length > selectedLength) {
      selected = path.points;
      selectedLength = length;
    }
  }
  return selected;
}

bool _isGuidanceInstruction(String type) => !const {
  'depart',
  'notification',
  'new name',
  'continue',
}.contains(type.toLowerCase());

double _pathLength(List<GeoPoint> points) {
  var total = 0.0;
  for (var index = 0; index < points.length - 1; index += 1) {
    total += _distance(points[index], points[index + 1]);
  }
  return total;
}

_Projection _project(GeoPoint point, List<GeoPoint> path) {
  var nearestDistance = double.infinity;
  var nearestProgress = 0.0;
  var travelled = 0.0;
  for (var index = 0; index < path.length - 1; index += 1) {
    final start = path[index];
    final end = path[index + 1];
    final segment = _projectToSegment(point, start, end);
    final length = _distance(start, end);
    if (segment.distanceMeters < nearestDistance) {
      nearestDistance = segment.distanceMeters;
      nearestProgress = travelled + length * segment.fraction;
    }
    travelled += length;
  }
  return _Projection(
    distanceMeters: nearestDistance,
    progressMeters: nearestProgress,
  );
}

_SegmentProjection _projectToSegment(
  GeoPoint point,
  GeoPoint start,
  GeoPoint end,
) {
  final referenceLatitude = _radians(point.latitude);
  final startX =
      _radians(_longitudeDelta(start.longitude - point.longitude)) *
      math.cos(referenceLatitude) *
      _earthRadiusMeters;
  final startY = _radians(start.latitude - point.latitude) * _earthRadiusMeters;
  final endX =
      _radians(_longitudeDelta(end.longitude - point.longitude)) *
      math.cos(referenceLatitude) *
      _earthRadiusMeters;
  final endY = _radians(end.latitude - point.latitude) * _earthRadiusMeters;
  final deltaX = endX - startX;
  final deltaY = endY - startY;
  final lengthSquared = deltaX * deltaX + deltaY * deltaY;
  if (lengthSquared == 0) {
    return _SegmentProjection(
      distanceMeters: math.sqrt(startX * startX + startY * startY),
      fraction: 0,
    );
  }
  final fraction = (-(startX * deltaX + startY * deltaY) / lengthSquared).clamp(
    0.0,
    1.0,
  );
  final nearestX = startX + fraction * deltaX;
  final nearestY = startY + fraction * deltaY;
  return _SegmentProjection(
    distanceMeters: math.sqrt(nearestX * nearestX + nearestY * nearestY),
    fraction: fraction,
  );
}

double _distance(GeoPoint first, GeoPoint second) {
  final latitude1 = _radians(first.latitude);
  final latitude2 = _radians(second.latitude);
  final latitudeDelta = latitude2 - latitude1;
  final longitudeDelta = _radians(
    _longitudeDelta(second.longitude - first.longitude),
  );
  final a =
      math.pow(math.sin(latitudeDelta / 2), 2) +
      math.cos(latitude1) *
          math.cos(latitude2) *
          math.pow(math.sin(longitudeDelta / 2), 2);
  return _earthRadiusMeters * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}

String _sentenceCase(String value) {
  final words = value.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (words.isEmpty) return 'Continue';
  return '${words[0].toUpperCase()}${words.substring(1)}';
}

double _radians(double degrees) => degrees * math.pi / 180;

double _longitudeDelta(double delta) => ((delta + 540) % 360) - 180;

const _earthRadiusMeters = 6371008.8;

class _Projection {
  const _Projection({
    required this.distanceMeters,
    required this.progressMeters,
  });

  final double distanceMeters;
  final double progressMeters;
}

class _SegmentProjection {
  const _SegmentProjection({
    required this.distanceMeters,
    required this.fraction,
  });

  final double distanceMeters;
  final double fraction;
}
