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

  _selectionTests();
}

void _selectionTests() {
  // A straight line long enough to earn several arrows at any spacing used here.
  List<GeoPoint> line(double startLat, {int points = 40}) => [
    for (var index = 0; index < points; index += 1)
      GeoPoint(latitude: startLat + index * 0.002, longitude: -2.5),
  ];

  const sampler = TrailDirectionArrowSampler(spacingMeters: 100);

  // The defect behind #363: every arrow source was something that only exists
  // once the ride is moving, so a planned route that had not been ridden yet
  // carried no direction arrows at all - on exactly the screen where a rider is
  // working out which way round the route goes.
  test('a planned route that has not been ridden still gets arrows', () {
    final selected = selectTrailDirectionArrows<String>(
      sampler: sampler,
      sources: [
        TrailDirectionArrowSource(paths: [line(51.4)], style: 'route-ahead'),
        // No ridden path and no trails: the ride has not started.
        const TrailDirectionArrowSource(paths: [], style: 'ridden'),
      ],
    );

    expect(selected, isNotEmpty);
    expect(selected.map((item) => item.style).toSet(), {'route-ahead'});
  });

  // The route is offered first, so without a reserve a long enough route would
  // take the whole budget and leave the live rejoin instruction with none.
  test('a reserve stops one source consuming the whole budget', () {
    final selected = selectTrailDirectionArrows<String>(
      sampler: sampler,
      budget: 12,
      sources: [
        TrailDirectionArrowSource(
          paths: [line(51.4, points: 400)],
          reserve: 6,
          style: 'route-ahead',
        ),
        TrailDirectionArrowSource(paths: [line(52.4)], style: 'rejoin'),
      ],
    );

    expect(selected.where((item) => item.style == 'route-ahead'), hasLength(6));
    expect(selected.where((item) => item.style == 'rejoin'), isNotEmpty);
    expect(selected, hasLength(lessThanOrEqualTo(12)));
  });

  test('the budget is never exceeded, whatever the sources ask for', () {
    final selected = selectTrailDirectionArrows<String>(
      sampler: sampler,
      budget: 5,
      sources: [
        TrailDirectionArrowSource(
          paths: [line(51.4, points: 400)],
          reserve: 100,
          style: 'route-ahead',
        ),
        TrailDirectionArrowSource(paths: [line(52.4)], style: 'ridden'),
      ],
    );

    expect(selected, hasLength(5));
  });
}
