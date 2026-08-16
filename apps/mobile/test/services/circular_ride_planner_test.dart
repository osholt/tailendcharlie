import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/domain/recorded_route_store.dart';
import 'package:ride_relay/services/circular_ride_planner.dart';
import 'package:ride_relay/services/road_routing.dart';

void main() {
  const start = GeoPoint(latitude: 51.46, longitude: -2.51);

  test('cardinal direction shapes a closed loop in that direction', () {
    final north = circularRideShapingPoints(
      const CircularRideRequest(
        start: start,
        distanceMeters: 100000,
        direction: CircularRideDirection.north,
        preferences: RoutePreferences.defaults,
      ),
    );
    final southWest = circularRideShapingPoints(
      const CircularRideRequest(
        start: start,
        distanceMeters: 100000,
        direction: CircularRideDirection.southWest,
        preferences: RoutePreferences.defaults,
      ),
    );

    expect(north[1].latitude, greaterThan(start.latitude));
    expect(southWest[1].latitude, lessThan(start.latitude));
    expect(southWest[1].longitude, lessThan(start.longitude));
  });

  test('another route changes the shaping controls', () {
    const request = CircularRideRequest(
      start: start,
      distanceMeters: 80000,
      direction: CircularRideDirection.west,
      preferences: RoutePreferences.defaults,
    );

    expect(
      circularRideShapingPoints(request.another()).first.longitude,
      isNot(circularRideShapingPoints(request).first.longitude),
    );
  });

  test('routes through shaping points and retains editable controls', () async {
    final routing = _FakeRoadRoutingService();
    final planner = CircularRidePlanner(routingService: routing);
    final plan = await planner.generate(
      const CircularRideRequest(
        start: start,
        distanceMeters: 120000,
        direction: CircularRideDirection.northEast,
        preferences: RoutePreferences(style: RouteStyle.twisty),
        dayLength: RideDayLength.halfDay,
        plannedStops: [
          CircularRideStop(
            fraction: 0.5,
            waypoint: RouteWaypoint(
              point: GeoPoint(latitude: 51.60, longitude: -2.30),
              name: 'Suggested lunch',
            ),
          ),
        ],
      ),
    );

    expect(routing.waypoints, hasLength(6));
    expect(routing.waypoints.first.latitude, start.latitude);
    expect(routing.waypoints.last.longitude, start.longitude);
    expect(routing.preferences?.style, RouteStyle.twisty);
    expect(plan.route.shapingPoints, hasLength(3));
    expect(plan.route.waypoints, hasLength(3));
    expect(plan.route.waypoints[1].name, 'Suggested lunch');
    expect(plan.route.shapingPoints.last.legIndex, 1);
    expect(plan.route.plannedDuration, const Duration(hours: 2));
    expect(plan.route.name, contains('half-day'));
  });

  test(
    'corrects route size until it is within the documented tolerance',
    () async {
      final routing = _SequencedRoadRoutingService([200000, 125000]);
      final plan = await CircularRidePlanner(routingService: routing).generate(
        const CircularRideRequest(
          start: start,
          distanceMeters: 100000,
          direction: CircularRideDirection.north,
          preferences: RoutePreferences.defaults,
        ),
      );

      expect(routing.calls, 2);
      expect(
        circularRideDistanceWithinTolerance(
          requestedMeters: plan.requestedDistanceMeters,
          actualMeters: plan.actualDistanceMeters,
        ),
        isTrue,
      );
    },
  );

  test(
    'rejects a routed U-turn instead of presenting it as a valid loop',
    () async {
      final routing = _FakeRoadRoutingService(
        maneuvers: const [
          RoadRouteManeuver(position: start, type: 'turn', modifier: 'u-turn'),
        ],
      );

      await expectLater(
        CircularRidePlanner(routingService: routing).generate(
          const CircularRideRequest(
            start: start,
            distanceMeters: 120000,
            direction: CircularRideDirection.east,
            preferences: RoutePreferences.defaults,
          ),
        ),
        throwsA(isA<FormatException>()),
      );
    },
  );

  test(
    'a confirmed generated loop can be filed without starting a ride',
    () async {
      final store = InMemoryRecordedRouteStore();
      final route =
          (await CircularRidePlanner(
                routingService: _FakeRoadRoutingService(),
              ).generate(
                const CircularRideRequest(
                  start: start,
                  distanceMeters: 120000,
                  direction: CircularRideDirection.west,
                  preferences: RoutePreferences.defaults,
                ),
              ))
              .route;

      await saveCircularRideToLibrary(route, store);

      expect((await store.list()).single.id, route.id);
    },
  );

  test('day presets turn duration into an approximate distance', () {
    expect(dayRideDistanceMeters(RideDayLength.halfDay), 220000);
    expect(dayRideDistanceMeters(RideDayLength.fullDay), 440000);
  });

  test('mobile itinerary matches the shared web fixture', () {
    final fixture =
        jsonDecode(
              File('../../fixtures/circular-itinerary.json').readAsStringSync(),
            )
            as Map<String, dynamic>;
    for (final rawCase in fixture['cases'] as List) {
      final item = Map<String, dynamic>.from(rawCase as Map);
      final length = switch (item['dayLength']) {
        'half-day' => RideDayLength.halfDay,
        'day' => RideDayLength.fullDay,
        _ => RideDayLength.custom,
      };
      final request = CircularRideRequest(
        start: start,
        distanceMeters: 100000,
        direction: CircularRideDirection.north,
        preferences: RoutePreferences.defaults,
        dayLength: length,
        fuelEvery: Duration(minutes: fixture['fuelMinutes'] as int),
        comfortEvery: Duration(minutes: fixture['comfortMinutes'] as int),
        mealAfter: Duration(minutes: fixture['mealMinutes'] as int),
      );
      final actual = [
        for (final stop in circularRideItinerary(request))
          {
            'afterMinutes': stop.after.inMinutes,
            'kinds': stop.kinds.map((kind) => kind.name).toList()..sort(),
          },
      ];
      expect(actual, item['stops']);
    }
  });

  test(
    'heatmap preference is soft, requires coverage and excludes the start',
    () {
      const request = CircularRideRequest(
        start: start,
        distanceMeters: 80000,
        direction: CircularRideDirection.north,
        preferences: RoutePreferences.defaults,
      );
      final base = circularRideShapingPoints(request);
      final sparse = [
        for (var index = 0; index < 19; index += 1)
          CircularRideHeatCell(
            point: GeoPoint(
              latitude: base.first.latitude + index * 0.00001,
              longitude: base.first.longitude,
            ),
            weight: 1,
          ),
      ];
      expect(
        heatmapBiasedCircularRideControls(
          controls: base,
          start: start,
          cells: sparse,
          enabled: true,
          searchRadiusMeters: 20000,
        ),
        base,
      );
      final sufficient = [
        ...sparse,
        CircularRideHeatCell(
          point: GeoPoint(
            latitude: base.first.latitude + 0.01,
            longitude: base.first.longitude + 0.01,
          ),
          weight: 1,
        ),
      ];
      final nearStart = [
        for (var index = 0; index < 20; index += 1)
          CircularRideHeatCell(
            point: GeoPoint(
              latitude: start.latitude + index * 0.00001,
              longitude: start.longitude,
            ),
            weight: 1,
          ),
      ];
      expect(
        circularRideHeatmapBiasAvailable(nearStart, start: start),
        isFalse,
      );
      final biased = heatmapBiasedCircularRideControls(
        controls: base,
        start: start,
        cells: sufficient,
        enabled: true,
        searchRadiusMeters: 20000,
      );
      expect(biased.first, isNot(base.first));
      expect(
        _distance(base.first, biased.first),
        lessThan(_distance(base.first, sufficient.last.point)),
        reason: 'the tuning nudges a control and never hard-snaps it to a cell',
      );
    },
  );
}

double _distance(GeoPoint a, GeoPoint b) {
  final lat = (a.latitude - b.latitude).abs();
  final lon = (a.longitude - b.longitude).abs();
  return lat + lon;
}

class _FakeRoadRoutingService implements RoadRoutingService {
  _FakeRoadRoutingService({this.maneuvers = const []});

  List<GeoPoint> waypoints = const [];
  RoutePreferences? preferences;
  final List<RoadRouteManeuver> maneuvers;

  @override
  Future<RoadRouteResult> routeThrough(
    List<GeoPoint> waypoints, {
    RoutePreferences? preferences,
    double? originBearingDegrees,
  }) async {
    this.waypoints = waypoints;
    this.preferences = preferences;
    return RoadRouteResult(
      points: waypoints,
      distanceMeters: 118000,
      duration: const Duration(hours: 2),
      maneuvers: maneuvers,
      twistinessScore: 31,
      preferences: preferences,
    );
  }
}

class _SequencedRoadRoutingService implements RoadRoutingService {
  _SequencedRoadRoutingService(this.distances);

  final List<double> distances;
  var calls = 0;

  @override
  Future<RoadRouteResult> routeThrough(
    List<GeoPoint> waypoints, {
    RoutePreferences? preferences,
    double? originBearingDegrees,
  }) async {
    final distance = distances[calls.clamp(0, distances.length - 1).toInt()];
    calls += 1;
    return RoadRouteResult(
      points: waypoints,
      distanceMeters: distance,
      duration: const Duration(hours: 2),
      preferences: preferences,
    );
  }
}
