import 'dart:math' as math;

import '../domain/imported_route.dart' show GeoPoint;

class TrailDirectionArrow {
  const TrailDirectionArrow({
    required this.point,
    required this.bearingDegrees,
  });

  final GeoPoint point;
  final double bearingDegrees;
}

/// Samples sparse, distance-based arrows from travelled trail geometry.
///
/// Distance spacing keeps the cue density stable even when GPS fixes arrive at
/// uneven intervals. Short but meaningful trails still receive one midpoint
/// arrow, while hard caps prevent long recordings from producing huge layers.
class TrailDirectionArrowSampler {
  const TrailDirectionArrowSampler({
    this.spacingMeters = 250,
    this.minimumTrailMeters = 30,
    this.maximumArrows = 160,
  }) : assert(spacingMeters > 0),
       assert(minimumTrailMeters >= 0),
       assert(maximumArrows > 0);

  final double spacingMeters;
  final double minimumTrailMeters;
  final int maximumArrows;

  List<TrailDirectionArrow> sample(Iterable<List<GeoPoint>> paths) {
    final arrows = <TrailDirectionArrow>[];
    for (final path in paths) {
      if (arrows.length >= maximumArrows) break;
      _samplePath(path, arrows);
    }
    return List.unmodifiable(arrows);
  }

  void _samplePath(List<GeoPoint> path, List<TrailDirectionArrow> arrows) {
    if (path.length < 2) return;
    final segments = <_TrailSegment>[];
    var totalMeters = 0.0;
    for (var index = 1; index < path.length; index += 1) {
      final start = path[index - 1];
      final end = path[index];
      final length = _distanceMeters(start, end);
      if (length < 0.5) continue;
      segments.add(_TrailSegment(start: start, end: end, lengthMeters: length));
      totalMeters += length;
    }
    if (segments.isEmpty || totalMeters < minimumTrailMeters) return;

    final firstTarget = totalMeters < spacingMeters
        ? totalMeters / 2
        : spacingMeters / 2;
    var targetMeters = firstTarget;
    var segmentIndex = 0;
    var segmentStartMeters = 0.0;
    while (targetMeters < totalMeters && arrows.length < maximumArrows) {
      while (segmentIndex < segments.length - 1 &&
          segmentStartMeters + segments[segmentIndex].lengthMeters <
              targetMeters) {
        segmentStartMeters += segments[segmentIndex].lengthMeters;
        segmentIndex += 1;
      }
      final segment = segments[segmentIndex];
      final progress =
          ((targetMeters - segmentStartMeters) / segment.lengthMeters).clamp(
            0.0,
            1.0,
          );
      arrows.add(
        TrailDirectionArrow(
          point: _interpolate(segment.start, segment.end, progress),
          bearingDegrees: _bearingDegrees(segment.start, segment.end),
        ),
      );
      targetMeters += spacingMeters;
    }
  }

  static GeoPoint _interpolate(GeoPoint start, GeoPoint end, double progress) {
    final longitudeDelta =
        ((end.longitude - start.longitude + 540) % 360) - 180;
    final longitude = start.longitude + longitudeDelta * progress;
    return GeoPoint(
      latitude: start.latitude + (end.latitude - start.latitude) * progress,
      longitude: ((longitude + 540) % 360) - 180,
    );
  }

  static double _bearingDegrees(GeoPoint from, GeoPoint to) {
    final fromLatitude = from.latitude * math.pi / 180;
    final toLatitude = to.latitude * math.pi / 180;
    final longitudeDelta = (to.longitude - from.longitude) * math.pi / 180;
    final y = math.sin(longitudeDelta) * math.cos(toLatitude);
    final x =
        math.cos(fromLatitude) * math.sin(toLatitude) -
        math.sin(fromLatitude) *
            math.cos(toLatitude) *
            math.cos(longitudeDelta);
    return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
  }

  static double _distanceMeters(GeoPoint first, GeoPoint second) {
    const earthRadiusMeters = 6371008.8;
    final latitude1 = first.latitude * math.pi / 180;
    final latitude2 = second.latitude * math.pi / 180;
    final latitudeDelta = latitude2 - latitude1;
    final longitudeDelta = (second.longitude - first.longitude) * math.pi / 180;
    final a =
        math.pow(math.sin(latitudeDelta / 2), 2) +
        math.cos(latitude1) *
            math.cos(latitude2) *
            math.pow(math.sin(longitudeDelta / 2), 2);
    return earthRadiusMeters * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }
}

class _TrailSegment {
  const _TrailSegment({
    required this.start,
    required this.end,
    required this.lengthMeters,
  });

  final GeoPoint start;
  final GeoPoint end;
  final double lengthMeters;
}
