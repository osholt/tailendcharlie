import 'dart:math' as math;

import '../domain/imported_route.dart';

/// The web planner's twistiness score, in Dart.
///
/// This is the score #46 established and `docs/route-twistiness.md` records:
/// 150 m sampling, heading changes below 8 degrees discarded as geometry noise,
/// changes above 70 degrees discarded as route manoeuvres, and the remainder
/// divided by route distance in kilometres. It is a port of `routeBendScore`
/// and `formatRouteBendScore` in `apps/website/planner-core.mjs`, not a second
/// notion of twisty, and the fixtures in `route_twistiness_test.dart` pin it to
/// the same numbers the web planner produces.
class RouteTwistiness {
  const RouteTwistiness._();

  /// Sampling interval along the geometry.
  static const sampleIntervalMeters = 150.0;

  /// Below this a heading change is geometry noise.
  static const minimumBendDegrees = 8.0;

  /// Above this it is more likely a U-turn, roundabout exit or urban-grid
  /// junction than a useful flowing bend.
  static const maximumBendDegrees = 70.0;

  /// Degrees of useful heading change per kilometre.
  ///
  /// [distanceMeters] is the provider's own route distance when there is one.
  /// It defaults to the geometry's own length, which is what a stored route
  /// without a provider summary has. Returns 0 for geometry too short to carry
  /// a bend, which is the same fallback the web planner uses.
  static double score(List<GeoPoint> points, {double? distanceMeters}) {
    final distance = distanceMeters ?? geometryLengthMeters(points);
    if (points.length < 3 || !distance.isFinite || distance <= 0) return 0;

    final sampled = <GeoPoint>[points.first];
    var distanceSinceSample = 0.0;
    for (var index = 1; index < points.length; index += 1) {
      distanceSinceSample += _distanceMeters(points[index - 1], points[index]);
      if (distanceSinceSample >= sampleIntervalMeters ||
          index == points.length - 1) {
        sampled.add(points[index]);
        distanceSinceSample = 0;
      }
    }

    var totalHeadingChange = 0.0;
    for (var index = 2; index < sampled.length; index += 1) {
      final before = _bearingDegrees(sampled[index - 2], sampled[index - 1]);
      final after = _bearingDegrees(sampled[index - 1], sampled[index]);
      final change = ((after - before) % 360 + 540) % 360 - 180;
      final magnitude = change.abs();
      if (magnitude >= minimumBendDegrees && magnitude <= maximumBendDegrees) {
        totalHeadingChange += magnitude;
      }
    }
    return totalHeadingChange / math.max(distance / 1000, 1);
  }

  static double geometryLengthMeters(List<GeoPoint> points) {
    var total = 0.0;
    for (var index = 1; index < points.length; index += 1) {
      total += _distanceMeters(points[index - 1], points[index]);
    }
    return total;
  }

  /// The published label bands. Same thresholds as `formatRouteBendScore`.
  static String label(double score) => switch (score) {
    >= 45 => 'Very twisty',
    >= 25 => 'Twisty',
    >= 12 => 'Flowing',
    _ => 'Gentle',
  };

  /// The web planner's summary text, e.g. `16°/km · Flowing`.
  static String describe(double score) {
    if (!score.isFinite || score < 0) return '—';
    return '${score.round()}°/km · ${label(score)}';
  }

  /// Picks the bendiest alternative a provider actually returned within the
  /// style's detour allowance.
  ///
  /// A port of `chooseRoadRoute`: the provider's first route is the quickest,
  /// the allowance is measured against its duration, and if nothing qualifies
  /// the quickest is kept. It never asks for a road the provider did not offer.
  static T? chooseWithinDetour<T>(
    List<T> alternatives, {
    required RouteStyle style,
    required double Function(T) duration,
    required double Function(T) twistiness,
  }) {
    if (alternatives.isEmpty) return null;
    final quickest = alternatives.first;
    if (!style.prefersBends || alternatives.length == 1) return quickest;

    final quickestDuration = duration(quickest);
    final allowance = quickestDuration * style.detourLimit;
    final eligible = alternatives
        .where((candidate) {
          final candidateDuration = duration(candidate);
          return candidateDuration.isFinite &&
              (!quickestDuration.isFinite || candidateDuration <= allowance);
        })
        .toList(growable: false);
    if (eligible.isEmpty) return quickest;

    return eligible.reduce(
      (best, candidate) =>
          twistiness(candidate) > twistiness(best) ? candidate : best,
    );
  }
}

double _distanceMeters(GeoPoint first, GeoPoint second) {
  const earthRadius = 6371000.0;
  const radians = math.pi / 180;
  final firstLatitude = first.latitude * radians;
  final secondLatitude = second.latitude * radians;
  final latitudeDelta = (second.latitude - first.latitude) * radians;
  final longitudeDelta = (second.longitude - first.longitude) * radians;
  final haversine =
      math.sin(latitudeDelta / 2) * math.sin(latitudeDelta / 2) +
      math.cos(firstLatitude) *
          math.cos(secondLatitude) *
          math.sin(longitudeDelta / 2) *
          math.sin(longitudeDelta / 2);
  return earthRadius *
      2 *
      math.atan2(math.sqrt(haversine), math.sqrt(1 - haversine));
}

double _bearingDegrees(GeoPoint first, GeoPoint second) {
  const radians = math.pi / 180;
  final firstLatitude = first.latitude * radians;
  final secondLatitude = second.latitude * radians;
  final longitudeDelta = (second.longitude - first.longitude) * radians;
  final y = math.sin(longitudeDelta) * math.cos(secondLatitude);
  final x =
      math.cos(firstLatitude) * math.sin(secondLatitude) -
      math.sin(firstLatitude) *
          math.cos(secondLatitude) *
          math.cos(longitudeDelta);
  return (math.atan2(y, x) / radians + 360) % 360;
}
