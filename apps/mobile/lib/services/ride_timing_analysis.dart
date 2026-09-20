import 'dart:math' as math;

import '../domain/imported_route.dart';

/// Break-aware timing, deliberately not a sum of instantaneous GPS speeds.
/// Short traffic stops remain in travelling time. Long gaps ending close to
/// their start are probable breaks, reported separately from observed dwell.
class RideTimingAnalysis {
  const RideTimingAnalysis({
    required this.elapsed,
    required this.observedBreaks,
    required this.probableBreaks,
    required this.unknownGaps,
    required this.distanceMeters,
    required this.points,
  });
  final Duration elapsed;
  final Duration observedBreaks;
  final Duration probableBreaks;
  final Duration unknownGaps;
  final double distanceMeters;
  final List<GeoPoint> points;
  Duration get breaks => observedBreaks + probableBreaks;
  Duration get travelling => elapsed - breaks;
  bool get reliable =>
      points.length >= 20 &&
      travelling.inSeconds >= 600 &&
      unknownGaps.inSeconds <= travelling.inSeconds * .05;

  static RideTimingAnalysis? fromRoute(ImportedRoute? route) {
    if (route == null) return null;
    final points = [
      for (final path in route.paths)
        for (final point in path.points)
          if (point.recordedAt != null) point,
    ]..sort((a, b) => a.recordedAt!.compareTo(b.recordedAt!));
    if (points.length < 2) return null;
    final durations = <int>[];
    final kinds = List.filled(
      points.length - 1,
      0,
    ); // 0 travel, 1 dwell, 2 probable break, 3 unknown
    var distance = 0.0;
    for (var i = 1; i < points.length; i++) {
      final seconds = points[i].recordedAt!
          .difference(points[i - 1].recordedAt!)
          .inSeconds;
      final metres = ridePointDistance(points[i - 1], points[i]);
      durations.add(seconds);
      if (seconds >= 300 && metres <= 250) {
        kinds[i - 1] = 2;
      } else if (seconds > 120) {
        kinds[i - 1] = 3;
      } else if (seconds > 0 && metres / seconds <= 70) {
        distance += metres;
      } else if (seconds > 0) {
        kinds[i - 1] = 3; // implausible jump, not useful training evidence
      }
    }
    // Anchored dwell prevents a slowly moving queue being mistaken for a
    // lunch stop. Unknown gaps are never silently promoted to observed dwell.
    var anchor = 0;
    while (anchor < points.length - 1) {
      var end = anchor + 1;
      while (end < points.length &&
          ridePointDistance(points[anchor], points[end]) <= 60) {
        end++;
      }
      final last = end - 1;
      if (points[last].recordedAt!
              .difference(points[anchor].recordedAt!)
              .inSeconds >=
          300) {
        for (var i = anchor; i < last; i++) {
          if (kinds[i] == 0) kinds[i] = 1;
        }
        anchor = end;
      } else {
        anchor++;
      }
    }
    int secondsFor(int kind) => [
      for (var i = 0; i < kinds.length; i++)
        if (kinds[i] == kind) durations[i],
    ].fold(0, (sum, value) => sum + value);
    return RideTimingAnalysis(
      elapsed: points.last.recordedAt!.difference(points.first.recordedAt!),
      observedBreaks: Duration(seconds: secondsFor(1)),
      probableBreaks: Duration(seconds: secondsFor(2)),
      unknownGaps: Duration(seconds: secondsFor(3)),
      distanceMeters: distance,
      points: List.unmodifiable(points),
    );
  }
}

double ridePointDistance(GeoPoint a, GeoPoint b) {
  const radians = math.pi / 180;
  final dlat = (b.latitude - a.latitude) * radians;
  final dlon = (b.longitude - a.longitude) * radians;
  final h =
      math.pow(math.sin(dlat / 2), 2) +
      math.cos(a.latitude * radians) *
          math.cos(b.latitude * radians) *
          math.pow(math.sin(dlon / 2), 2);
  return 6371000 * 2 * math.asin(math.sqrt(h.clamp(0, 1)));
}

double rideRouteLength(ImportedRoute route) => route.paths.fold(0, (sum, path) {
  var length = 0.0;
  for (var i = 1; i < path.points.length; i++) {
    length += ridePointDistance(path.points[i - 1], path.points[i]);
  }
  return sum + length;
});
