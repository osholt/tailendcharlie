import 'dart:math' as math;

import '../domain/imported_route.dart';

class RouteProgressGeometry {
  const RouteProgressGeometry({
    required this.riddenPaths,
    required this.remainingPaths,
    required this.progressMeters,
    required this.totalMeters,
  });

  const RouteProgressGeometry.empty()
    : riddenPaths = const [],
      remainingPaths = const [],
      progressMeters = 0,
      totalMeters = 0;

  /// The planned route behind the rider. This is a split of the *plan*, not a
  /// record of where anyone has been: it is route geometry the rider is deemed
  /// to have covered. Travelled trails come from `RiderTrailRecorder`.
  final List<List<GeoPoint>> riddenPaths;

  final List<List<GeoPoint>> remainingPaths;
  final double progressMeters;
  final double totalMeters;
}

/// Maintains monotonic progress along the primary route path.
///
/// A stateful tracker avoids a closed loop's finish point being mistaken for
/// completed progress while the rider is still at its coincident start point.
///
/// Progress deliberately stops advancing while the rider is further than
/// [maximumTrackingDistanceMeters] from the route: there is no route to be
/// progressed along out there. Nothing about drawing where a rider has been may
/// depend on this class - that mistake is what removed a leader's trail at the
/// moment they left the plan (#100).
class RouteProgressTracker {
  RouteProgressTracker({this.maximumTrackingDistanceMeters = 150});

  final double maximumTrackingDistanceMeters;

  String? _routeFingerprint;
  double _progressMeters = 0;
  bool _hasProgressFix = false;

  void reset() {
    _routeFingerprint = null;
    _progressMeters = 0;
    _hasProgressFix = false;
  }

  RouteProgressGeometry update(ImportedRoute? route, GeoPoint? position) {
    if (route == null || route.paths.isEmpty) {
      reset();
      return const RouteProgressGeometry.empty();
    }
    final fingerprint =
        '${route.id}:${route.importedAt.toIso8601String()}:'
        '${route.pathPointCount}';
    if (_routeFingerprint != fingerprint) {
      _routeFingerprint = fingerprint;
      _progressMeters = 0;
      _hasProgressFix = false;
    }

    final primaryIndex = _primaryPathIndex(route.paths);
    final primary = route.paths[primaryIndex].points;
    final total = _pathLength(primary);
    if (position != null && primary.length >= 2) {
      final candidate = _project(
        position,
        primary,
        previousProgressMeters: _hasProgressFix ? _progressMeters : null,
      );
      if (candidate.distanceMeters <= maximumTrackingDistanceMeters) {
        _progressMeters = math.max(_progressMeters, candidate.progressMeters);
        _hasProgressFix = true;
      }
    }
    _progressMeters = _progressMeters.clamp(0, total);

    final ridden = <List<GeoPoint>>[];
    final remaining = <List<GeoPoint>>[];
    for (final (index, path) in route.paths.indexed) {
      if (index != primaryIndex || path.points.length < 2) {
        if (path.points.length >= 2) remaining.add(path.points);
        continue;
      }
      final split = _split(path.points, _progressMeters);
      if (split.ridden.length >= 2) ridden.add(split.ridden);
      if (split.remaining.length >= 2) remaining.add(split.remaining);
    }
    return RouteProgressGeometry(
      riddenPaths: List.unmodifiable(ridden),
      remainingPaths: List.unmodifiable(remaining),
      progressMeters: _progressMeters,
      totalMeters: total,
    );
  }
}

int _primaryPathIndex(List<RoutePath> paths) {
  var selected = 0;
  var selectedLength = -1.0;
  for (final (index, path) in paths.indexed) {
    final length = _pathLength(path.points);
    if (length > selectedLength) {
      selected = index;
      selectedLength = length;
    }
  }
  return selected;
}

double _pathLength(List<GeoPoint> points) {
  var total = 0.0;
  for (var index = 0; index < points.length - 1; index += 1) {
    total += _distance(points[index], points[index + 1]);
  }
  return total;
}

_Projection _project(
  GeoPoint point,
  List<GeoPoint> path, {
  required double? previousProgressMeters,
}) {
  final candidates = <_Projection>[];
  var travelled = 0.0;
  for (var index = 0; index < path.length - 1; index += 1) {
    final segment = _projectToSegment(point, path[index], path[index + 1]);
    final length = _distance(path[index], path[index + 1]);
    candidates.add(
      _Projection(
        distanceMeters: segment.distanceMeters,
        progressMeters: travelled + length * segment.fraction,
      ),
    );
    travelled += length;
  }
  final nearestDistance = candidates
      .map((candidate) => candidate.distanceMeters)
      .reduce(math.min);
  final near = candidates
      .where((candidate) => candidate.distanceMeters <= nearestDistance + 4)
      .toList(growable: false);
  if (previousProgressMeters == null) {
    return near.reduce(
      (first, second) =>
          first.progressMeters <= second.progressMeters ? first : second,
    );
  }
  return near.reduce(
    (first, second) =>
        (first.progressMeters - previousProgressMeters).abs() <=
            (second.progressMeters - previousProgressMeters).abs()
        ? first
        : second,
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

_SplitPath _split(List<GeoPoint> points, double progressMeters) {
  if (progressMeters <= 0) {
    return _SplitPath(ridden: const [], remaining: List.unmodifiable(points));
  }
  final total = _pathLength(points);
  if (progressMeters >= total) {
    return _SplitPath(ridden: List.unmodifiable(points), remaining: const []);
  }
  final ridden = <GeoPoint>[points.first];
  var travelled = 0.0;
  for (var index = 0; index < points.length - 1; index += 1) {
    final start = points[index];
    final end = points[index + 1];
    final segmentLength = _distance(start, end);
    if (travelled + segmentLength < progressMeters) {
      ridden.add(end);
      travelled += segmentLength;
      continue;
    }
    final fraction = ((progressMeters - travelled) / segmentLength).clamp(
      0.0,
      1.0,
    );
    final splitPoint = GeoPoint(
      latitude: start.latitude + (end.latitude - start.latitude) * fraction,
      longitude:
          start.longitude +
          _longitudeDelta(end.longitude - start.longitude) * fraction,
    );
    if (!_samePoint(ridden.last, splitPoint)) ridden.add(splitPoint);
    final remaining = <GeoPoint>[splitPoint];
    if (!_samePoint(splitPoint, end)) remaining.add(end);
    remaining.addAll(points.skip(index + 2));
    return _SplitPath(
      ridden: List.unmodifiable(ridden),
      remaining: List.unmodifiable(remaining),
    );
  }
  return _SplitPath(ridden: List.unmodifiable(points), remaining: const []);
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

bool _samePoint(GeoPoint first, GeoPoint second) =>
    (first.latitude - second.latitude).abs() < 1e-10 &&
    _longitudeDelta(first.longitude - second.longitude).abs() < 1e-10;

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

class _SplitPath {
  const _SplitPath({required this.ridden, required this.remaining});

  final List<GeoPoint> ridden;
  final List<GeoPoint> remaining;
}
