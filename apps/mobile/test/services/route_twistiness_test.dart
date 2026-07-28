import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/services/route_twistiness.dart';

/// The same geometry and the same expected numbers as
/// `apps/website/planner-core.test.mjs`. These fixtures exist so the app cannot
/// grow a second notion of twisty: if either implementation drifts, one of the
/// two suites fails (#46, #182).
void main() {
  test('the shared calibration fixture scores what the web planner scores', () {
    final score = RouteTwistiness.score(
      _sinusoidalLane,
      distanceMeters: _sinusoidalLaneMeters,
    );

    expect(score, closeTo(29.115031244781, 1e-9));
    expect(RouteTwistiness.label(score), 'Twisty');
    expect(RouteTwistiness.describe(score), '29°/km · Twisty');
  });

  test('the score falls back to the geometry length', () {
    expect(
      RouteTwistiness.geometryLengthMeters(_sinusoidalLane),
      closeTo(_sinusoidalLaneMeters, 1e-6),
    );
    expect(
      RouteTwistiness.score(_sinusoidalLane),
      closeTo(29.115031244781, 1e-9),
    );
  });

  test('a straight road scores zero', () {
    const straight = [
      GeoPoint(latitude: 51.4, longitude: -2.5),
      GeoPoint(latitude: 51.4, longitude: -2.4),
      GeoPoint(latitude: 51.4, longitude: -2.3),
      GeoPoint(latitude: 51.4, longitude: -2.2),
    ];

    expect(RouteTwistiness.score(straight), 0);
    expect(RouteTwistiness.label(0), 'Gentle');
  });

  test('geometry too short to carry a bend scores zero', () {
    expect(RouteTwistiness.score(const []), 0);
    expect(
      RouteTwistiness.score(const [
        GeoPoint(latitude: 51.4, longitude: -2.5),
        GeoPoint(latitude: 51.4, longitude: -2.4),
      ]),
      0,
    );
    expect(
      RouteTwistiness.score(_sinusoidalLane, distanceMeters: 0),
      0,
      reason: 'a zero distance is not a divisor',
    );
  });

  test('label bands are the published thresholds', () {
    expect(RouteTwistiness.label(11.9), 'Gentle');
    expect(RouteTwistiness.label(12), 'Flowing');
    expect(RouteTwistiness.label(24.9), 'Flowing');
    expect(RouteTwistiness.label(25), 'Twisty');
    expect(RouteTwistiness.label(44.9), 'Twisty');
    expect(RouteTwistiness.label(45), 'Very twisty');
    expect(RouteTwistiness.describe(-1), '—');
    expect(RouteTwistiness.describe(double.nan), '—');
  });

  group('alternative selection within the detour allowance', () {
    const quickest = (duration: 3600.0, twistiness: 5.0);
    const bendier = (duration: 4300.0, twistiness: 40.0);
    const bendiest = (duration: 6000.0, twistiness: 90.0);
    const candidates = [quickest, bendier, bendiest];

    ({double duration, double twistiness})? choose(RouteStyle style) =>
        RouteTwistiness.chooseWithinDetour(
          candidates,
          style: style,
          duration: (candidate) => candidate.duration,
          twistiness: (candidate) => candidate.twistiness,
        );

    test('quickest keeps the provider order and ignores bends', () {
      expect(choose(RouteStyle.quickest), quickest);
    });

    test('flowing accepts 25% and no more', () {
      // 4300 s is over the 4500 s allowance? No: 3600 * 1.25 = 4500, so it fits.
      expect(choose(RouteStyle.flowing), bendier);
    });

    test('very twisty reaches the 75% alternative', () {
      // 3600 * 1.75 = 6300 s, so the bendiest becomes eligible.
      expect(choose(RouteStyle.veryTwisty), bendiest);
    });

    test('nothing eligible keeps the quickest', () {
      expect(
        RouteTwistiness.chooseWithinDetour(
          const [quickest, bendiest],
          style: RouteStyle.flowing,
          duration: (candidate) => candidate.duration,
          twistiness: (candidate) => candidate.twistiness,
        ),
        quickest,
        reason: '6000 s exceeds the 4500 s allowance',
      );
    });

    test('a single alternative is the answer whatever the style', () {
      expect(
        RouteTwistiness.chooseWithinDetour(
          const [bendiest],
          style: RouteStyle.twisty,
          duration: (candidate) => candidate.duration,
          twistiness: (candidate) => candidate.twistiness,
        ),
        bendiest,
      );
    });

    test('no alternatives at all is null, never an invented route', () {
      expect(
        RouteTwistiness.chooseWithinDetour(
          const <({double duration, double twistiness})>[],
          style: RouteStyle.twisty,
          duration: (candidate) => candidate.duration,
          twistiness: (candidate) => candidate.twistiness,
        ),
        isNull,
      );
    });
  });
}

/// Distance of [_sinusoidalLane], as the web planner measures it.
const _sinusoidalLaneMeters = 12963.688380;

/// A deterministic sinusoidal lane. Byte-for-byte the coordinates used by the
/// matching web planner test.
const _sinusoidalLane = [
  GeoPoint(latitude: 51.4, longitude: -2.5),
  GeoPoint(latitude: 51.402337, longitude: -2.496),
  GeoPoint(latitude: 51.404304, longitude: -2.492),
  GeoPoint(latitude: 51.405592, longitude: -2.488),
  GeoPoint(latitude: 51.405997, longitude: -2.484),
  GeoPoint(latitude: 51.405456, longitude: -2.48),
  GeoPoint(latitude: 51.404053, longitude: -2.476),
  GeoPoint(latitude: 51.40201, longitude: -2.472),
  GeoPoint(latitude: 51.39965, longitude: -2.468),
  GeoPoint(latitude: 51.397345, longitude: -2.464),
  GeoPoint(latitude: 51.395459, longitude: -2.46),
  GeoPoint(latitude: 51.39429, longitude: -2.456),
  GeoPoint(latitude: 51.394023, longitude: -2.452),
  GeoPoint(latitude: 51.394699, longitude: -2.448),
  GeoPoint(latitude: 51.396212, longitude: -2.444),
  GeoPoint(latitude: 51.398324, longitude: -2.44),
  GeoPoint(latitude: 51.400699, longitude: -2.436),
  GeoPoint(latitude: 51.402965, longitude: -2.432),
  GeoPoint(latitude: 51.404762, longitude: -2.428),
  GeoPoint(latitude: 51.405808, longitude: -2.424),
  GeoPoint(latitude: 51.405936, longitude: -2.42),
  GeoPoint(latitude: 51.405128, longitude: -2.416),
  GeoPoint(latitude: 51.40351, longitude: -2.412),
  GeoPoint(latitude: 51.401337, longitude: -2.408),
  GeoPoint(latitude: 51.398954, longitude: -2.404),
  GeoPoint(latitude: 51.396736, longitude: -2.4),
  GeoPoint(latitude: 51.395033, longitude: -2.396),
  GeoPoint(latitude: 51.394114, longitude: -2.392),
  GeoPoint(latitude: 51.394125, longitude: -2.388),
  GeoPoint(latitude: 51.395063, longitude: -2.384),
  GeoPoint(latitude: 51.396781, longitude: -2.38),
  GeoPoint(latitude: 51.399006, longitude: -2.376),
  GeoPoint(latitude: 51.401389, longitude: -2.372),
  GeoPoint(latitude: 51.403552, longitude: -2.368),
  GeoPoint(latitude: 51.405155, longitude: -2.364),
  GeoPoint(latitude: 51.405944, longitude: -2.36),
  GeoPoint(latitude: 51.405794, longitude: -2.356),
  GeoPoint(latitude: 51.40473, longitude: -2.352),
  GeoPoint(latitude: 51.402918, longitude: -2.348),
  GeoPoint(latitude: 51.400647, longitude: -2.344),
];
