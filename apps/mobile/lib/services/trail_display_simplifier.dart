import 'dart:math' as math;

import '../domain/imported_route.dart' show GeoPoint;

/// Reduces a recorded trail to the points worth drawing.
///
/// A two-hour ride records a position roughly every 10 m — the platform
/// `distanceFilter` — so one rider arrives at several thousand points and a
/// group at tens of thousands. Drawing every one of them costs the same on
/// every frame, which is why the map got slower the longer the ride went on
/// (#165).
///
/// Simplification is deliberately here, in the shared data path, rather than in
/// either renderer: the device draws with MapLibre and the fallback draws with
/// flutter_map, and a bound that only one of them honoured would be a bound
/// that field-tests wrong (#141).
class TrailDisplaySimplifier {
  const TrailDisplaySimplifier({
    this.toleranceMeters = defaultToleranceMeters,
    this.maximumPoints = defaultMaximumPoints,
  }) : assert(toleranceMeters > 0),
       assert(maximumPoints >= 2);

  /// 5 m, chosen against what a rider can see rather than what looks tidy in a
  /// test. Trail lines are several logical pixels wide and at the most
  /// zoomed-in ride camera a pixel is still more than a metre of ground, so a
  /// 5 m deviation cannot move the drawn line clear of where it would otherwise
  /// be. It is also small enough to keep the geometry that matters: a 30 m
  /// hairpin — the tightest case #166 raises — keeps its shape, because its
  /// points deviate from the chord by far more than 5 m.
  static const defaultToleranceMeters = 5.0;

  /// A ceiling for the pathological case: a genuinely twisty road can deviate
  /// by more than the tolerance at nearly every point, so tolerance alone does
  /// not bound anything. 2,000 points is around 20 km of 10 m fixes kept in
  /// full, and finer detail than a phone screen can resolve.
  static const defaultMaximumPoints = 2000;

  final double toleranceMeters;
  final int maximumPoints;

  /// The trail as it should be drawn. The first and last points are always
  /// kept, so a trail never appears to start or stop somewhere the rider was
  /// not.
  List<GeoPoint> simplify(List<GeoPoint> points) {
    if (points.length <= 2) return points;
    var tolerance = toleranceMeters;
    var simplified = _reduce(points, tolerance);
    // Doubling converges in a handful of passes and keeps the result a true
    // simplification of the recorded trail, rather than a windowed sample that
    // could cut a corner the rider actually took.
    while (simplified.length > maximumPoints) {
      tolerance *= 2;
      simplified = _reduce(points, tolerance);
    }
    return simplified;
  }

  /// Ramer-Douglas-Peucker, iterative so a long trail cannot overflow the
  /// stack.
  List<GeoPoint> _reduce(List<GeoPoint> points, double tolerance) {
    final keep = List<bool>.filled(points.length, false);
    keep[0] = true;
    keep[points.length - 1] = true;
    // Metres per degree, evaluated once at the trail's own latitude. A ride
    // never spans enough latitude for this to drift meaningfully, and it turns
    // every distance below into flat arithmetic instead of trigonometry.
    const metresPerDegreeLatitude = 111132.0;
    final metresPerDegreeLongitude =
        metresPerDegreeLatitude *
        math.cos(points[points.length ~/ 2].latitude * math.pi / 180).abs();
    final pending = <int>[0, points.length - 1];
    while (pending.isNotEmpty) {
      final last = pending.removeLast();
      final first = pending.removeLast();
      if (last <= first + 1) continue;
      var farthest = -1;
      var farthestDistance = 0.0;
      final startX =
          (points[first].longitude - points[0].longitude) *
          metresPerDegreeLongitude;
      final startY =
          (points[first].latitude - points[0].latitude) *
          metresPerDegreeLatitude;
      final endX =
          (points[last].longitude - points[0].longitude) *
          metresPerDegreeLongitude;
      final endY =
          (points[last].latitude - points[0].latitude) *
          metresPerDegreeLatitude;
      final spanX = endX - startX;
      final spanY = endY - startY;
      final spanLengthSquared = spanX * spanX + spanY * spanY;
      for (var index = first + 1; index < last; index += 1) {
        final pointX =
            (points[index].longitude - points[0].longitude) *
            metresPerDegreeLongitude;
        final pointY =
            (points[index].latitude - points[0].latitude) *
            metresPerDegreeLatitude;
        final offsetX = pointX - startX;
        final offsetY = pointY - startY;
        double distance;
        if (spanLengthSquared == 0) {
          // A closed excursion - a car park loop returning to where it began.
          // Distance from the shared endpoint is the only meaningful measure.
          distance = math.sqrt(offsetX * offsetX + offsetY * offsetY);
        } else {
          final projection =
              ((offsetX * spanX + offsetY * spanY) / spanLengthSquared).clamp(
                0.0,
                1.0,
              );
          final nearestX = offsetX - projection * spanX;
          final nearestY = offsetY - projection * spanY;
          distance = math.sqrt(nearestX * nearestX + nearestY * nearestY);
        }
        if (distance > farthestDistance) {
          farthestDistance = distance;
          farthest = index;
        }
      }
      if (farthest < 0 || farthestDistance <= tolerance) continue;
      keep[farthest] = true;
      pending
        ..add(first)
        ..add(farthest)
        ..add(farthest)
        ..add(last);
    }
    return [
      for (var index = 0; index < points.length; index += 1)
        if (keep[index]) points[index],
    ];
  }
}
