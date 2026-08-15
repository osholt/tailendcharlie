import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/services/road_routing.dart';
import 'package:ride_relay/services/route_reshape_planner.dart';

void main() {
  test('a dragged point is assigned to the named-stop leg it shapes', () {
    final route = _route();
    final points = insertRouteShapingPoint(
      route,
      const [],
      const GeoPoint(latitude: 51.012, longitude: -2.012),
      id: 'shape-b',
    );

    expect(points.single.legIndex, 1);
    expect(route.waypoints, hasLength(3));
    expect(points.single.point, isNot(route.waypoints[1].point));
  });

  test(
    'controls retain named stops and shaping order without adding stops',
    () {
      final route = _route();
      final controls = routeShapingControls(route, const [
        RouteShapingPoint(
          id: 'shape-a',
          legIndex: 0,
          point: GeoPoint(latitude: 51.004, longitude: -2.004),
        ),
        RouteShapingPoint(
          id: 'shape-b',
          legIndex: 1,
          point: GeoPoint(latitude: 51.014, longitude: -2.014),
        ),
      ]);

      expect(controls, [
        route.waypoints[0].point,
        const GeoPoint(latitude: 51.004, longitude: -2.004),
        route.waypoints[1].point,
        const GeoPoint(latitude: 51.014, longitude: -2.014),
        route.waypoints[2].point,
      ]);
    },
  );

  test(
    'recalculation is an immutable preview using route preferences',
    () async {
      final routing = _RecordingRoutingService();
      final original = _route();
      const shapes = [
        RouteShapingPoint(
          id: 'shape-a',
          legIndex: 0,
          point: GeoPoint(latitude: 51.006, longitude: -2.002),
        ),
      ];

      final result = await RouteReshapePlanner(
        routingService: routing,
      ).reshape(original, shapes);

      expect(routing.preferences, original.preferences);
      expect(routing.controls, routeShapingControls(original, shapes));
      expect(result.route.waypoints, same(original.waypoints));
      expect(result.route.shapingPoints, shapes);
      expect(result.route.paths.single.points, routing.result.points);
      expect(result.route.maneuvers, routing.result.maneuvers);
      expect(result.route.plannedDuration, routing.result.duration);
      expect(original.shapingPoints, isEmpty);
    },
  );

  test('shaping points survive route JSON save and reload', () {
    final route = _route().withShapingPoints(const [
      RouteShapingPoint(
        id: 'shape-a',
        legIndex: 1,
        point: GeoPoint(latitude: 51.012, longitude: -2.012),
      ),
    ]);

    final restored = ImportedRoute.fromJsonString(route.toJsonString());

    expect(restored.shapingPoints.single.id, 'shape-a');
    expect(restored.shapingPoints.single.legIndex, 1);
    expect(restored.shapingPoints.single.point.latitude, 51.012);
  });
}

ImportedRoute _route() => ImportedRoute(
  id: 'route',
  name: 'Three stop route',
  importedAt: DateTime.utc(2026, 7, 29),
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
      name: 'Cafe',
      point: GeoPoint(latitude: 51.01, longitude: -2.01),
    ),
    RouteWaypoint(
      name: 'Finish',
      point: GeoPoint(latitude: 51.02, longitude: -2.02),
    ),
  ],
  preferences: RoutePreferences(style: RouteStyle.twisty, avoidMotorways: true),
);

class _RecordingRoutingService implements RoadRoutingService {
  List<GeoPoint> controls = const [];
  RoutePreferences? preferences;

  final result = const RoadRouteResult(
    points: [
      GeoPoint(latitude: 51, longitude: -2),
      GeoPoint(latitude: 51.006, longitude: -2.002),
      GeoPoint(latitude: 51.02, longitude: -2.02),
    ],
    distanceMeters: 3200,
    duration: Duration(minutes: 8),
    maneuvers: [
      RoadRouteManeuver(
        position: GeoPoint(latitude: 51.006, longitude: -2.002),
        type: 'turn',
        modifier: 'right',
      ),
    ],
  );

  @override
  Future<RoadRouteResult> routeThrough(
    List<GeoPoint> waypoints, {
    RoutePreferences? preferences,
    double? originBearingDegrees,
  }) async {
    controls = List.unmodifiable(waypoints);
    this.preferences = preferences;
    return result;
  }
}
