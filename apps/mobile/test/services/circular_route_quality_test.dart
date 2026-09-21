import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/services/circular_route_quality.dart';

GeoPoint p(double x, double y) =>
    GeoPoint(latitude: y / 111195, longitude: x / 111195);
void main() {
  final circle = [p(0, 0), p(2000, 0), p(2000, 2000), p(0, 2000), p(0, 0)];
  test('a genuine loop has no repeated road', () {
    final quality = circularRouteQuality(circle);
    expect(quality.usable, isTrue);
    expect(quality.overlapFraction, lessThan(.01));
  });
  test('detects an unannounced dead-end spur within the complete geometry', () {
    final quality = circularRouteQuality([
      circle[0],
      circle[1],
      p(2500, 0),
      circle[1],
      ...circle.skip(2),
    ]);
    expect(quality.hasUnintendedReversal, isTrue);
    expect(quality.usable, isFalse);
  });
  test('duplicate provider vertices cannot hide a reversal', () {
    final tip = p(2500, 0);
    final quality = circularRouteQuality([
      circle[0],
      circle[1],
      tip,
      tip,
      circle[1],
      ...circle.skip(2),
    ]);
    expect(quality.hasUnintendedReversal, isTrue);
  });

  test('a long common stem is rejected even without a sharp reversal', () {
    final quality = circularRouteQuality([p(-2000, 0), ...circle, p(-2000, 0)]);
    expect(quality.hasUnintendedReversal, isFalse);
    expect(quality.overlapFraction, greaterThan(.15));
    expect(quality.usable, isFalse);
  });
  test(
    'long deliberate stop access does not consume the accidental overlap budget',
    () {
      final stop = p(5000, 0);
      final route = [circle[0], circle[1], stop, circle[1], ...circle.skip(2)];
      expect(circularRouteQuality(route).usable, isFalse);
      final intentional = circularRouteQuality(route, deliberateStops: [stop]);
      expect(intentional.usable, isTrue);
      expect(intentional.overlapFraction, lessThan(.01));
    },
  );
  test('narrow adjacent lanes are not the same road centreline', () {
    final quality = circularRouteQuality([
      p(0, 0),
      p(2000, 0),
      p(2002, 1.5),
      p(2000, 3),
      p(500, 3),
      p(500, 2000),
      p(0, 2000),
      p(0, 0),
    ]);
    expect(quality.usable, isTrue);
  });

  test('a short intentional stop spur is retained', () {
    final stop = p(2300, 0);
    final quality = circularRouteQuality(
      [circle[0], circle[1], stop, circle[1], ...circle.skip(2)],
      deliberateStops: [stop],
    );
    expect(quality.hasUnintendedReversal, isFalse);
    expect(quality.usable, isTrue);
  });
  test(
    'hairpins on separate centrelines and crossing roads are not retracing',
    () {
      final hairpin = circularRouteQuality([
        p(0, 0),
        p(2000, 0),
        p(2010, 15),
        p(2000, 30),
        p(500, 30),
        p(500, 2000),
        p(0, 2000),
        p(0, 0),
      ]);
      expect(hairpin.usable, isTrue);
      final crossing = circularRouteQuality([
        p(0, 0),
        p(2000, 2000),
        p(0, 2000),
        p(2000, 0),
        p(0, 0),
      ]);
      expect(crossing.usable, isTrue);
    },
  );
  test('duplicate vertices and dense shape points do not change overlap', () {
    final sparse = [p(-2000, 0), ...circle, p(-2000, 0)];
    final dense = <GeoPoint>[];
    for (var i = 0; i < sparse.length - 1; i++) {
      for (var j = 0; j < 100; j++) {
        dense.add(
          GeoPoint(
            latitude:
                sparse[i].latitude +
                (sparse[i + 1].latitude - sparse[i].latitude) * j / 100,
            longitude:
                sparse[i].longitude +
                (sparse[i + 1].longitude - sparse[i].longitude) * j / 100,
          ),
        );
      }
    }
    dense.add(sparse.last);
    expect(
      circularRouteQuality(dense).overlapFraction,
      closeTo(circularRouteQuality(sparse).overlapFraction, .005),
    );
  });
}
