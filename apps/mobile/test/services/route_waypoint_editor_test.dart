import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/services/route_waypoint_editor.dart';

void main() {
  test('inserts a POI in route order and preserves shaping controls', () {
    final route = _route().withShapingPoints(const [
      RouteShapingPoint(
        id: 'first-leg',
        legIndex: 0,
        point: GeoPoint(latitude: 51.005, longitude: -2.005),
      ),
      RouteShapingPoint(
        id: 'before-poi',
        legIndex: 1,
        point: GeoPoint(latitude: 51.012, longitude: -2.012),
      ),
      RouteShapingPoint(
        id: 'after-poi',
        legIndex: 1,
        point: GeoPoint(latitude: 51.018, longitude: -2.018),
      ),
    ]);

    final edited = insertRouteWaypoint(
      route,
      const RouteWaypoint(
        name: 'Rider Cafe',
        point: GeoPoint(latitude: 51.015, longitude: -2.015),
      ),
    );

    expect(edited.waypoints.map((point) => point.name), [
      'Start',
      'Existing stop',
      'Rider Cafe',
      'Finish',
    ]);
    expect(edited.shapingPoints.map((point) => point.legIndex), [0, 1, 2]);
    expect(edited.maneuvers, isEmpty);
  });

  test('removes an intermediate waypoint and merges its route legs', () {
    final route = insertRouteWaypoint(
      _route().withShapingPoints(const [
        RouteShapingPoint(
          id: 'after-new-stop',
          legIndex: 1,
          point: GeoPoint(latitude: 51.018, longitude: -2.018),
        ),
      ]),
      const RouteWaypoint(
        name: 'Rider Cafe',
        point: GeoPoint(latitude: 51.015, longitude: -2.015),
      ),
    );

    final edited = removeRouteWaypoint(route, 2);

    expect(edited.waypoints.map((point) => point.name), [
      'Start',
      'Existing stop',
      'Finish',
    ]);
    expect(edited.shapingPoints.single.legIndex, 1);
  });
}

ImportedRoute _route() => ImportedRoute(
  id: 'route',
  name: 'Route',
  importedAt: DateTime.utc(2026, 8, 4),
  sourceFileName: 'route.gpx',
  paths: const [
    RoutePath(
      kind: RoutePathKind.track,
      points: [
        GeoPoint(latitude: 51, longitude: -2),
        GeoPoint(latitude: 51.005, longitude: -2.005),
        GeoPoint(latitude: 51.01, longitude: -2.01),
        GeoPoint(latitude: 51.015, longitude: -2.015),
        GeoPoint(latitude: 51.02, longitude: -2.02),
      ],
    ),
  ],
  waypoints: const [
    RouteWaypoint(name: 'Start', point: GeoPoint(latitude: 51, longitude: -2)),
    RouteWaypoint(
      name: 'Existing stop',
      point: GeoPoint(latitude: 51.01, longitude: -2.01),
    ),
    RouteWaypoint(
      name: 'Finish',
      point: GeoPoint(latitude: 51.02, longitude: -2.02),
    ),
  ],
  maneuvers: const [
    RouteManeuver(
      position: GeoPoint(latitude: 51.005, longitude: -2.005),
      type: 'turn',
    ),
  ],
);
