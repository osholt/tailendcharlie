import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/domain/ride_plan.dart';
import 'package:ride_relay/services/ride_plan_router.dart';
import 'package:ride_relay/services/road_routing.dart';

const _here = GeoPoint(latitude: 52.00, longitude: -1.00);
const _cafe = GeoPoint(latitude: 52.10, longitude: -1.00);
const _town = GeoPoint(latitude: 52.30, longitude: -1.00);
const _drawn = GeoPoint(latitude: 52.20, longitude: -1.03);

void main() {
  RidePlanRouter router(_RecordingRouting routing) => RidePlanRouter(
    routingService: routing,
    idFactory: () => 'plan-1',
    clock: () => DateTime.utc(2026, 10, 4, 9),
  );

  test('adjustments go to the router as non-stopping controls', () async {
    final routing = _RecordingRouting();
    final plan =
        RidePlan.toDestination(const RidePlanPlace(point: _town, label: 'Town'))
            .addStop(const RidePlanPlace(point: _cafe, label: 'Cafe'))
            .withShapingPoints(const [
              RouteShapingPoint(id: 'drawn', point: _drawn, legIndex: 1),
            ]);

    await router(routing).route(plan, currentLocation: _here);

    // Only the named places may split the route into legs, so only they can
    // be announced as an arrival (#839).
    expect(routing.shapingCalls, hasLength(1));
    expect(routing.shapingCalls.single.points, [_here, _cafe, _drawn, _town]);
    expect(routing.shapingCalls.single.shapingIndexes, {2});
    expect(routing.plainCalls, isEmpty);
  });

  test('a plan with nothing drawn is an ordinary request', () async {
    final routing = _RecordingRouting();

    await router(routing).route(
      RidePlan.toDestination(const RidePlanPlace(point: _town, label: 'Town')),
      currentLocation: _here,
    );

    expect(routing.plainCalls.single, [_here, _town]);
    expect(routing.shapingCalls, isEmpty);
  });

  test(
    'the route lists named places only, and keeps the adjustments',
    () async {
      final routing = _RecordingRouting();
      final plan =
          RidePlan.toDestination(
                const RidePlanPlace(
                  point: _town,
                  label: 'Town',
                  description: 'Town, Shire',
                ),
                preferences: const RoutePreferences(avoidMotorways: true),
              )
              .addStop(
                const RidePlanPlace(
                  point: _cafe,
                  label: 'Cafe',
                  symbol: 'Restaurant',
                ),
              )
              .withShapingPoints(const [
                RouteShapingPoint(id: 'drawn', point: _drawn, legIndex: 1),
              ]);

      final routed = await router(routing).route(plan, currentLocation: _here);
      final route = routed.route;

      expect(route.name, 'To Town');
      expect(route.waypoints.map((waypoint) => waypoint.name), [
        'Start',
        'Cafe',
        'Town',
      ]);
      expect(route.waypoints.first.description, 'Current location');
      expect(route.waypoints.map((waypoint) => waypoint.symbol), [
        'Flag, Blue',
        'Restaurant',
        'Flag, Red',
      ]);
      expect(route.shapingPoints.single.id, 'drawn');
      expect(route.preferences?.avoidMotorways, isTrue);
      expect(routing.preferences?.avoidMotorways, isTrue);
      expect(route.plannedDuration, const Duration(minutes: 40));

      // And it reads back as the same plan.
      final again = RidePlan.fromRoute(route);
      expect(again.startsAtCurrentLocation, isTrue);
      expect(again.stops.single.label, 'Cafe');
      expect(again.shapingPoints.single.legIndex, 1);
    },
  );

  test('no fix and no chosen start says what to do', () async {
    final routing = _RecordingRouting();

    await expectLater(
      router(routing).route(
        RidePlan.toDestination(
          const RidePlanPlace(point: _town, label: 'Town'),
        ),
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('Choose a start'),
        ),
      ),
    );
    expect(routing.plainCalls, isEmpty);
  });

  test(
    'an edit keeps the route\'s identity and a name the rider gave it',
    () async {
      final routing = _RecordingRouting();
      final base = ImportedRoute(
        id: 'sunday-run',
        name: 'Sunday run',
        importedAt: DateTime.utc(2026, 9, 1),
        sourceFileName: 'sunday.gpx',
        paths: const [
          RoutePath(kind: RoutePathKind.track, points: [_here, _town]),
        ],
        waypoints: const [
          RouteWaypoint(point: _here, name: 'Start'),
          RouteWaypoint(point: _town, name: 'Town'),
        ],
      );

      final routed = await router(routing).route(
        RidePlan.fromRoute(
          base,
        ).withDestination(const RidePlanPlace(point: _cafe, label: 'Cafe')),
        base: base,
      );

      expect(routed.route.id, 'sunday-run');
      expect(routed.route.name, 'Sunday run');
    },
  );

  test('a route named for its destination is renamed with it', () async {
    final routing = _RecordingRouting();
    final first = await router(routing).route(
      RidePlan.toDestination(const RidePlanPlace(point: _town, label: 'Town')),
      currentLocation: _here,
    );

    final edited = await router(routing).route(
      RidePlan.fromRoute(
        first.route,
      ).withDestination(const RidePlanPlace(point: _cafe, label: 'Cafe')),
      currentLocation: _here,
      base: first.route,
    );

    expect(edited.route.id, first.route.id);
    expect(edited.route.name, 'To Cafe');
  });
}

class _RecordingRouting
    implements RoadRoutingService, ShapingPointRoadRoutingService {
  final plainCalls = <List<GeoPoint>>[];
  final shapingCalls = <({List<GeoPoint> points, Set<int> shapingIndexes})>[];
  RoutePreferences? preferences;

  RoadRouteResult _result(List<GeoPoint> points) => RoadRouteResult(
    points: points,
    distanceMeters: 33000,
    duration: const Duration(minutes: 40),
    maneuvers: [RoadRouteManeuver(position: points.last, type: 'arrive')],
  );

  @override
  Future<RoadRouteResult> routeThrough(
    List<GeoPoint> waypoints, {
    RoutePreferences? preferences,
    double? originBearingDegrees,
  }) async {
    plainCalls.add(waypoints);
    this.preferences = preferences;
    return _result(waypoints);
  }

  @override
  Future<RoadRouteResult> routeThroughShapingPoints(
    List<GeoPoint> waypoints, {
    required Set<int> shapingPointIndexes,
    double shapingPointSearchRadiusMeters = 0,
    RoutePreferences? preferences,
    RoadRoutingCosting costing = RoadRoutingCosting.preferred,
    double? originBearingDegrees,
  }) async {
    shapingCalls.add((points: waypoints, shapingIndexes: shapingPointIndexes));
    this.preferences = preferences;
    return _result(waypoints);
  }
}
