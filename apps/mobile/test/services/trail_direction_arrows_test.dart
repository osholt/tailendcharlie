import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/services/trail_direction_arrows.dart';

void main() {
  test('samples arrows by distance instead of GPS point density', () {
    const sampler = TrailDirectionArrowSampler(spacingMeters: 400);

    final arrows = sampler.sample(const [
      [
        GeoPoint(latitude: 51, longitude: 0),
        GeoPoint(latitude: 51, longitude: 0.01),
        GeoPoint(latitude: 51, longitude: 0.02),
      ],
    ]);

    expect(arrows, hasLength(3));
    expect(
      arrows.every((arrow) => (arrow.bearingDegrees - 90).abs() < 1),
      isTrue,
    );
  });

  test('gives a short meaningful trail one midpoint arrow', () {
    const sampler = TrailDirectionArrowSampler(spacingMeters: 400);

    final arrows = sampler.sample(const [
      [
        GeoPoint(latitude: 51, longitude: 0),
        GeoPoint(latitude: 51.001, longitude: 0),
      ],
    ]);

    expect(arrows, hasLength(1));
    expect(arrows.single.point.latitude, closeTo(51.0005, 0.00001));
    expect(arrows.single.bearingDegrees, closeTo(0, 1));
  });

  test('a self-crossing trail retains distinct directions at the crossing', () {
    const sampler = TrailDirectionArrowSampler(spacingMeters: 100);
    const crossing = GeoPoint(latitude: 0, longitude: 0);

    final arrows = sampler.sample(const [
      [
        GeoPoint(latitude: -0.004, longitude: -0.004),
        GeoPoint(latitude: 0.004, longitude: 0.004),
        GeoPoint(latitude: -0.004, longitude: 0.004),
        GeoPoint(latitude: 0.004, longitude: -0.004),
      ],
    ]);
    final nearCrossing = arrows
        .where(
          (arrow) =>
              (arrow.point.latitude - crossing.latitude).abs() < 0.0009 &&
              (arrow.point.longitude - crossing.longitude).abs() < 0.0009,
        )
        .toList();

    expect(nearCrossing.length, greaterThanOrEqualTo(2));
    final bearings = nearCrossing.map((arrow) => arrow.bearingDegrees).toList();
    expect(
      bearings.any(
        (first) =>
            bearings.any((second) => ((first - second).abs() % 180) > 60),
      ),
      isTrue,
    );
  });

  test('caps arrows for very long recordings', () {
    const sampler = TrailDirectionArrowSampler(
      spacingMeters: 10,
      maximumArrows: 5,
    );

    final arrows = sampler.sample(const [
      [
        GeoPoint(latitude: 51, longitude: 0),
        GeoPoint(latitude: 51, longitude: 1),
      ],
    ]);

    expect(arrows, hasLength(5));
  });
}
