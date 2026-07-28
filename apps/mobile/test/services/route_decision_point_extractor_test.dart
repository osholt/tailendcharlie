import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/geo_point.dart';
import 'package:ride_relay/domain/marker_assistance.dart';
import 'package:ride_relay/services/route_decision_point_extractor.dart';

void main() {
  test('combines explicit waypoints with spaced geometric turns', () {
    final points = const RouteDecisionPointExtractor().extract(
      route: const [
        GeoPoint(latitude: 51, longitude: -1),
        GeoPoint(latitude: 51, longitude: -0.998),
        GeoPoint(latitude: 51.002, longitude: -0.998),
      ],
      explicitPoints: const [
        ExplicitDecisionPoint(
          position: GeoPoint(latitude: 51.001, longitude: -0.999),
          label: 'Named junction',
        ),
      ],
    );

    expect(points, hasLength(2));
    expect(points.first.source, DecisionPointSource.waypoint);
    expect(points.last.source, DecisionPointSource.routeGeometry);
  });

  test('does not treat a straight route as a decision point', () {
    final points = const RouteDecisionPointExtractor().extract(
      route: const [
        GeoPoint(latitude: 51, longitude: -1),
        GeoPoint(latitude: 51, longitude: -0.999),
        GeoPoint(latitude: 51, longitude: -0.998),
      ],
    );

    expect(points, isEmpty);
  });

  test('does not treat a doubling-back as a decision point', () {
    // The route runs up a no-through road and comes back out. Everyone returns
    // the way they went in, so there is no branch to miss and marking it would
    // send a rider to a dead end (#179).
    final points = const RouteDecisionPointExtractor().extract(
      route: const [
        GeoPoint(latitude: 51, longitude: -1),
        GeoPoint(latitude: 51.002, longitude: -1),
        GeoPoint(latitude: 51.0005, longitude: -1),
      ],
    );

    expect(points, isEmpty);
  });

  test('a rejected position is not offered again', () {
    const route = [
      GeoPoint(latitude: 51, longitude: -1),
      GeoPoint(latitude: 51, longitude: -0.998),
      GeoPoint(latitude: 51.002, longitude: -0.998),
    ];
    final suggested = const RouteDecisionPointExtractor().extract(route: route);
    expect(suggested, hasLength(1));

    final reviewed = const RouteDecisionPointExtractor().extract(
      route: route,
      rejectedPositions: [suggested.single.position],
    );

    expect(reviewed, isEmpty);
  });

  test('a missed junction added by hand is offered', () {
    final points = const RouteDecisionPointExtractor().extract(
      route: const [
        GeoPoint(latitude: 51, longitude: -1),
        GeoPoint(latitude: 51, longitude: -0.999),
        GeoPoint(latitude: 51, longitude: -0.998),
      ],
      addedPositions: const [
        ExplicitDecisionPoint(
          position: GeoPoint(latitude: 51, longitude: -0.999),
          label: 'Missed staggered junction',
        ),
      ],
    );

    expect(points.single.label, 'Missed staggered junction');
  });
}
