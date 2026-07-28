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

  /// Every separate time [polyline] comes within [corridorMeters] of [point].
  ///
  /// [projectOntoPolyline] answers "where on the route is this?" with the single
  /// geometrically nearest place, which is the wrong question for a route that
  /// visits somewhere twice. An out-and-back passes the same camera at, say, 20
  /// km outbound and 40 km inbound, and the nearest projection picks one of them
  /// essentially at random - so a rider on the way home gets told the camera they
  /// are about to ride past is 15 km behind them (#135).
  ///
  /// Each returned pass is one run of segments inside the corridor, reduced to
  /// the closest segment in that run, and carries that segment's bearing so a
  /// caller can tell which way the route runs there.
  ///
  /// A run ends either when the route leaves the corridor or when it turns back
  /// on itself by more than [reversalToleranceDegrees]. The reversal split is what
  /// makes an exact out-and-back work: riding out and back down the same road puts
  /// both passes in one unbroken corridor run, and without the split they collapse
  /// into whichever came first.
  static List<PolylinePass> passesNear(
    GeoPoint point,
    List<GeoPoint> polyline, {
    required double corridorMeters,
    double reversalToleranceDegrees = 120,
  }) {
    if (polyline.length < 2) return const [];
    final passes = <PolylinePass>[];
    var travelled = 0.0;
    PolylinePass? run;
    for (var index = 0; index < polyline.length - 1; index += 1) {
      final start = polyline[index];
      final end = polyline[index + 1];
      final segment = _projectOntoSegment(point, start, end);
      final length = distanceMeters(start, end);
      if (segment.distanceMeters <= corridorMeters) {
        final bearing = length == 0 ? null : bearingDegrees(start, end);
        final runBearing = run?.bearingDegrees;
        if (run != null &&
            runBearing != null &&
            bearing != null &&
            bearingDifferenceDegrees(runBearing, bearing) >
                reversalToleranceDegrees) {
          passes.add(run);
          run = null;
        }
        if (run == null ||
            segment.distanceMeters < run.distanceFromRouteMeters) {
          run = PolylinePass(
            distanceFromRouteMeters: segment.distanceMeters,
            distanceAlongRouteMeters: travelled + segment.progressMeters,
            bearingDegrees: bearing ?? run?.bearingDegrees,
          );
        }
      } else if (run != null) {
        passes.add(run);
        run = null;
      }
      travelled += length;
    }
    if (run != null) passes.add(run);
    return passes;
  }

  /// Smallest angle between two bearings, in degrees from 0 to 180.
  static double bearingDifferenceDegrees(double first, double second) {
    final difference = (first - second).abs() % 360;
    return math.min(difference, 360 - difference);
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

/// One occasion on which a polyline runs close to a point.
class PolylinePass {
  const PolylinePass({
    required this.distanceFromRouteMeters,
    required this.distanceAlongRouteMeters,
    required this.bearingDegrees,
  });

  final double distanceFromRouteMeters;
  final double distanceAlongRouteMeters;

  /// Which way the route runs at this pass, or null where the closest segment
  /// has no length to take a bearing from.
  final double? bearingDegrees;
}

class _SegmentProjection {
  const _SegmentProjection({
    required this.distanceMeters,
    required this.progressMeters,
  });

  final double distanceMeters;
  final double progressMeters;
}
