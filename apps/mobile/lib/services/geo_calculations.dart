import 'dart:math' as math;

import '../domain/geo_point.dart';

abstract final class GeoCalculations {
  static const earthRadiusMeters = 6371008.8;

  static double distanceMeters(GeoPoint first, GeoPoint second) {
    final latitude1 = _radians(first.latitude);
    final latitude2 = _radians(second.latitude);
    final latitudeDelta = latitude2 - latitude1;
    final longitudeDelta = _radians(
      _normaliseLongitudeDelta(second.longitude - first.longitude),
    );
    final a =
        math.pow(math.sin(latitudeDelta / 2), 2) +
        math.cos(latitude1) *
            math.cos(latitude2) *
            math.pow(math.sin(longitudeDelta / 2), 2);
    return earthRadiusMeters * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  /// Initial great-circle bearing from [from] to [to], in degrees clockwise
  /// from true north and normalised to `[0, 360)`.
  ///
  /// Used where a distance on its own is not actionable: "400 m NE" tells a
  /// rider which way to look, "400 m" does not (#151).
  static double bearingDegrees(GeoPoint from, GeoPoint to) {
    final latitude1 = _radians(from.latitude);
    final latitude2 = _radians(to.latitude);
    final longitudeDelta = _radians(
      _normaliseLongitudeDelta(to.longitude - from.longitude),
    );
    final y = math.sin(longitudeDelta) * math.cos(latitude2);
    final x =
        math.cos(latitude1) * math.sin(latitude2) -
        math.sin(latitude1) * math.cos(latitude2) * math.cos(longitudeDelta);
    final degrees = math.atan2(y, x) * 180 / math.pi;
    return (degrees + 360) % 360;
  }

  static double distanceToPolylineMeters(
    GeoPoint point,
    List<GeoPoint> polyline,
  ) {
    if (polyline.isEmpty) {
      return double.infinity;
    }
    if (polyline.length == 1) {
      return distanceMeters(point, polyline.single);
    }

    var nearest = double.infinity;
    for (var index = 0; index < polyline.length - 1; index += 1) {
      nearest = math.min(
        nearest,
        _distanceToSegmentMeters(point, polyline[index], polyline[index + 1]),
      );
    }
    return nearest;
  }

  static PolylineProjection projectOntoPolyline(
    GeoPoint point,
    List<GeoPoint> polyline,
  ) {
    if (polyline.isEmpty) {
      return const PolylineProjection(
        distanceFromRouteMeters: double.infinity,
        distanceAlongRouteMeters: 0,
      );
    }
    if (polyline.length == 1) {
      return PolylineProjection(
        distanceFromRouteMeters: distanceMeters(point, polyline.single),
        distanceAlongRouteMeters: 0,
      );
    }

    var travelled = 0.0;
    var nearestDistance = double.infinity;
    var nearestProgress = 0.0;
    for (var index = 0; index < polyline.length - 1; index += 1) {
      final start = polyline[index];
      final end = polyline[index + 1];
      final segment = _projectOntoSegment(point, start, end);
      if (segment.distanceMeters < nearestDistance) {
        nearestDistance = segment.distanceMeters;
        nearestProgress = travelled + segment.progressMeters;
      }
      travelled += distanceMeters(start, end);
    }
    return PolylineProjection(
      distanceFromRouteMeters: nearestDistance,
      distanceAlongRouteMeters: nearestProgress,
    );
  }

  static double _distanceToSegmentMeters(
    GeoPoint point,
    GeoPoint start,
    GeoPoint end,
  ) {
    return _projectOntoSegment(point, start, end).distanceMeters;
  }

  static _SegmentProjection _projectOntoSegment(
    GeoPoint point,
    GeoPoint start,
    GeoPoint end,
  ) {
    final referenceLatitude = _radians(point.latitude);
    final startX =
        _radians(_normaliseLongitudeDelta(start.longitude - point.longitude)) *
        math.cos(referenceLatitude) *
        earthRadiusMeters;
    final startY =
        _radians(start.latitude - point.latitude) * earthRadiusMeters;
    final endX =
        _radians(_normaliseLongitudeDelta(end.longitude - point.longitude)) *
        math.cos(referenceLatitude) *
        earthRadiusMeters;
    final endY = _radians(end.latitude - point.latitude) * earthRadiusMeters;

    final deltaX = endX - startX;
    final deltaY = endY - startY;
    final lengthSquared = deltaX * deltaX + deltaY * deltaY;
    if (lengthSquared == 0) {
      return _SegmentProjection(
        distanceMeters: math.sqrt(startX * startX + startY * startY),
        progressMeters: 0,
      );
    }
    final projection = (-(startX * deltaX + startY * deltaY) / lengthSquared)
        .clamp(0.0, 1.0);
    final nearestX = startX + projection * deltaX;
    final nearestY = startY + projection * deltaY;
    return _SegmentProjection(
      distanceMeters: math.sqrt(nearestX * nearestX + nearestY * nearestY),
      progressMeters: math.sqrt(lengthSquared) * projection,
    );
  }

  static double _radians(double degrees) => degrees * math.pi / 180;

  static double _normaliseLongitudeDelta(double delta) =>
      ((delta + 540) % 360) - 180;
}

class PolylineProjection {
  const PolylineProjection({
    required this.distanceFromRouteMeters,
    required this.distanceAlongRouteMeters,
  });

  final double distanceFromRouteMeters;
  final double distanceAlongRouteMeters;
}

class _SegmentProjection {
  const _SegmentProjection({
    required this.distanceMeters,
    required this.progressMeters,
  });

  final double distanceMeters;
  final double progressMeters;
}
