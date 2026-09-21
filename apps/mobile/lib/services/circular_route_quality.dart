import 'dart:math' as math;

import '../domain/imported_route.dart';

/// Geometry, rather than manoeuvre text, determines whether a loop retraces a
/// road. An atomic provider response can conceal a reversal between controls.
class CircularRouteQuality {
  const CircularRouteQuality({
    required this.repeatedMeters,
    required this.totalMeters,
    required this.hasUnintendedReversal,
  });

  final double repeatedMeters;
  final double totalMeters;
  final bool hasUnintendedReversal;
  double get overlapFraction =>
      totalMeters > 0 ? repeatedMeters / totalMeters : 1;
  bool get usable => !hasUnintendedReversal && overlapFraction <= .08;
}

CircularRouteQuality circularRouteQuality(
  List<GeoPoint> points, {
  List<GeoPoint> deliberateStops = const [],
}) {
  if (points.length < 3) {
    return const CircularRouteQuality(
      repeatedMeters: 0,
      totalMeters: 0,
      hasUnintendedReversal: true,
    );
  }
  final origin = points.first;
  final scale = math.cos(origin.latitude * math.pi / 180);
  math.Point<double> xy(GeoPoint point) => math.Point(
    ((point.longitude - origin.longitude + 540) % 360 - 180) * 111195 * scale,
    (point.latitude - origin.latitude) * 111195,
  );
  final path = <math.Point<double>>[];
  for (final point in points.map(xy)) {
    if (path.isEmpty || path.last.distanceTo(point) > .001) path.add(point);
  }
  final stops = deliberateStops.map(xy).toList(growable: false);
  final cumulative = <double>[0];
  for (var i = 1; i < path.length; i++) {
    cumulative.add(cumulative.last + path[i].distanceTo(path[i - 1]));
  }
  final total = cumulative.last;
  if (total <= 0 || !total.isFinite) {
    return const CircularRouteQuality(
      repeatedMeters: 0,
      totalMeters: 0,
      hasUnintendedReversal: true,
    );
  }
  math.Point<double> at(double distance) {
    var lo = 0;
    var hi = cumulative.length - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) ~/ 2;
      if (cumulative[mid] <= distance) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final length = cumulative[hi] - cumulative[lo];
    final fraction = length == 0
        ? 0.0
        : ((distance - cumulative[lo]) / length).clamp(0.0, 1.0);
    return path[lo] + (path[hi] - path[lo]) * fraction;
  }

  var reversal = false;
  final intentionalAccess = <(double, double)>[];
  for (var i = 1; i < path.length - 1; i++) {
    final before = path[i] - path[i - 1];
    final after = path[i + 1] - path[i];
    if (before.magnitude == 0 ||
        after.magnitude == 0 ||
        (before.x * after.x + before.y * after.y) /
                before.magnitude /
                after.magnitude >
            -.9) {
      continue;
    }
    final distance = cumulative[i];
    if (distance < 160 || distance > total - 160) {
      continue;
    }
    // Separate sides of a hairpin are different roads. Require the same
    // centreline at two distances, not merely a large change of bearing.
    if ([75.0, 150.0].every(
      (probe) => at(distance - probe).distanceTo(at(distance + probe)) < 2,
    )) {
      if (stops.any((stop) => stop.distanceTo(path[i]) < 150)) {
        var access = 150.0;
        final limit = math.min(distance, total - distance);
        while (access + 30 < limit &&
            at(distance - access - 30).distanceTo(at(distance + access + 30)) <
                2) {
          access += 30;
        }
        intentionalAccess.add((distance - access, distance + access));
      } else {
        reversal = true;
        break;
      }
    }
  }

  // Sample by distance, so shape point density cannot bias the overlap score.
  // A spatial index bounds work even for long tours. Crossings and neighbouring
  // parts of one bend are excluded by bearing and along-route separation.
  final step = math.max(30.0, total / 12000);
  final cells = <(int, int), List<_QualitySegment>>{};
  var repeated = 0.0;
  var previous = path.first;
  for (var distance = step; distance < total + step; distance += step) {
    final endDistance = math.min(distance, total);
    final end = at(endDistance);
    final segment = _QualitySegment(previous, end, endDistance);
    final midpoint = (previous + end) * .5;
    final cellSize = math.max(80.0, step * 2);
    final x = (midpoint.x / cellSize).floor();
    final y = (midpoint.y / cellSize).floor();
    var overlaps = false;
    for (var dx = -1; dx <= 1 && !overlaps; dx++) {
      for (var dy = -1; dy <= 1 && !overlaps; dy++) {
        for (final old
            in cells[(x + dx, y + dy)] ?? const <_QualitySegment>[]) {
          if (endDistance - old.distance < math.max(300, step * 4)) continue;
          final a = end - previous;
          final b = old.end - old.start;
          final product = a.magnitude * b.magnitude;
          if (product == 0 || (a.x * b.x + a.y * b.y).abs() / product < .97) {
            continue;
          }
          final offset = midpoint - old.start;
          final fraction =
              ((offset.x * b.x + offset.y * b.y) / (b.magnitude * b.magnitude))
                  .clamp(0.0, 1.0);
          if (midpoint.distanceTo(old.start + b * fraction) <= 2) {
            overlaps = true;
            break;
          }
        }
      }
    }
    final intentional = intentionalAccess.any(
      (range) => endDistance >= range.$1 && endDistance <= range.$2,
    );
    if (overlaps && !intentional) {
      repeated += math.min(step, total - (distance - step));
    }
    cells.putIfAbsent((x, y), () => []).add(segment);
    previous = end;
  }
  return CircularRouteQuality(
    repeatedMeters: repeated,
    totalMeters: total,
    hasUnintendedReversal: reversal,
  );
}

class _QualitySegment {
  const _QualitySegment(this.start, this.end, this.distance);
  final math.Point<double> start;
  final math.Point<double> end;
  final double distance;
}
