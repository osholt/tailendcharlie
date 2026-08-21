import 'dart:async';
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

  test('keeps a directional lobe beyond fixed gateway controls', () {
    const request = CircularRideRequest(
      start: start,
      distanceMeters: 80 * 1609.344,
      direction: CircularRideDirection.northWest,
      preferences: RoutePreferences.defaults,
    );
    final controls = circularRideShapingPoints(request);
    final resized = circularRideShapingPoints(
      request,
      shapingDistanceMeters: request.distanceMeters * 0.6,
    );

    expect(controls, hasLength(4));
    expect(
      controls.every(
        (point) =>
            point.latitude > start.latitude &&
            point.longitude < start.longitude,
      ),
      isTrue,
      reason: 'the selected direction should contain the whole loop lobe',
    );
    expect(resized.first.latitude, closeTo(controls.first.latitude, 0.000001));
    expect(
      resized.first.longitude,
      closeTo(controls.first.longitude, 0.000001),
    );
    expect(resized.last.latitude, closeTo(controls.last.latitude, 0.000001));
    expect(resized.last.longitude, closeTo(controls.last.longitude, 0.000001));
    expect(resized[1].longitude, isNot(closeTo(controls[1].longitude, 0.0001)));
    expect(resized[2].latitude, isNot(closeTo(controls[2].latitude, 0.0001)));
    expect(resized[1].longitude, lessThan(resized.first.longitude));
    expect(resized[2].latitude, greaterThan(resized.last.latitude));
    expect(
      _distanceSquared(start, resized[1]),
      greaterThan(_distanceSquared(start, resized.first)),
    );
    expect(
      _distanceSquared(start, resized[2]),
      greaterThan(_distanceSquared(start, resized.last)),
    );
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
    final routing = _FakeRoadRoutingService(
      sectionDistanceMeters: 118000 / 6,
      sectionDuration: const Duration(minutes: 20),
    );
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

    expect(routing.requests, hasLength(6));
    expect(
      routing.requests.every((request) => request.waypoints.length == 2),
      isTrue,
    );
    expect(routing.requests.first.waypoints.first.latitude, start.latitude);
    expect(routing.requests.last.waypoints.last.longitude, start.longitude);
    expect(
      routing.requests.every(
        (request) => request.preferences?.style == RouteStyle.twisty,
      ),
      isTrue,
    );
    expect(plan.route.shapingPoints, hasLength(4));
    expect(plan.route.waypoints, hasLength(3));
    expect(plan.route.waypoints[1].name, 'Suggested lunch');
    expect(plan.route.shapingPoints.last.legIndex, 1);
    expect(plan.route.plannedDuration, const Duration(hours: 2));
    expect(plan.route.name, contains('half-day'));
  });

  test(
    'keeps arrival and departure prompts at deliberate stops only',
    () async {
      final plan =
          await CircularRidePlanner(
            routingService: _BoundaryManeuverRoadRoutingService(),
          ).generate(
            const CircularRideRequest(
              start: start,
              distanceMeters: 120000,
              direction: CircularRideDirection.northEast,
              preferences: RoutePreferences(style: RouteStyle.twisty),
              plannedStops: [
                CircularRideStop(
                  fraction: 0.6,
                  waypoint: RouteWaypoint(
                    point: GeoPoint(latitude: 51.60, longitude: -2.30),
                    name: 'Lunch',
                  ),
                ),
              ],
            ),
          );

      expect(plan.route.maneuvers.map((maneuver) => maneuver.type), [
        'depart',
        'turn',
        'turn',
        'turn',
        'turn',
        'arrive',
        'depart',
        'turn',
        'turn',
        'arrive',
      ]);
    },
  );

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

      expect(routing.calls, 10);
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
    'tries alternate loop shapes before rejecting repeated routed U-turns',
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
      expect(routing.calls, 20);
    },
  );

  test(
    'an alternate loop shape replaces a routed U-turn automatically',
    () async {
      final routing = _UTurnThenValidRoadRoutingService();

      final plan = await CircularRidePlanner(routingService: routing).generate(
        const CircularRideRequest(
          start: start,
          distanceMeters: 120000,
          direction: CircularRideDirection.east,
          preferences: RoutePreferences.defaults,
        ),
      );

      expect(routing.calls, 10);
      expect(plan.request.variant, 1);
      expect(plan.route.maneuvers, isEmpty);
      expect(plan.motorwayAvoidanceRelaxed, isFalse);
    },
  );

  test(
    'allows motorways after a no-path response and warns before acceptance',
    () async {
      final routing = _MotorwayFallbackRoadRoutingService();

      final plan = await CircularRidePlanner(routingService: routing).generate(
        const CircularRideRequest(
          start: start,
          distanceMeters: 80 * 1609.344,
          direction: CircularRideDirection.northWest,
          preferences: RoutePreferences(avoidMotorways: true),
        ),
      );

      expect(
        routing.attempts.where((attempt) => attempt.avoidMotorways),
        hasLength(5),
      );
      expect(
        routing.attempts.where((attempt) => !attempt.avoidMotorways),
        hasLength(1),
      );
      expect(routing.forcedMotorcycleCalls, 1);
      expect(plan.motorwayAvoidanceRelaxed, isTrue);
      expect(plan.motorwayAvoidanceRelaxedSections, 1);
      expect(plan.routeSectionCount, 5);
      final warning = circularRideMotorwayFallbackWarning(
        relaxedSectionCount: 1,
        routeSectionCount: 5,
      );
      expect(plan.warnings, [warning]);
      expect(plan.route.preferences?.avoidMotorways, isTrue);
      expect(plan.route.description, contains(warning));
      expect(
        plan.route.maneuvers.map((maneuver) => maneuver.type),
        ['depart', 'turn', 'turn', 'turn', 'turn', 'turn', 'arrive'],
        reason: 'shaping sections must not sound like separate destinations',
      );
      expect(
        routing.relaxedWaypoints,
        routing.blockedWaypoints,
        reason: 'only the blocked section may be retried with motorways',
      );
    },
  );

  test(
    'allows motorways when avoiding them makes one section unusably indirect',
    () async {
      final routing = _ExcessiveDetourRoadRoutingService(
        blockedSectionDistanceMeters: 150000,
        ordinarySectionDistanceMeters: 30000,
        relaxedSectionDistanceMeters: 40000,
        blockedSectionHasUTurn: true,
      );

      final plan = await CircularRidePlanner(routingService: routing).generate(
        const CircularRideRequest(
          start: start,
          distanceMeters: 100 * 1609.344,
          direction: CircularRideDirection.northWest,
          preferences: RoutePreferences(
            style: RouteStyle.twisty,
            avoidMotorways: true,
            avoidMajorRoads: true,
            avoidTolls: true,
          ),
        ),
      );

      expect(routing.motorwayAvoidingCalls, 5);
      expect(routing.forcedMotorcycleCalls, 1);
      expect(routing.relaxedWaypoints, routing.blockedWaypoints);
      expect(
        routing.relaxedPreferences,
        isA<RoutePreferences>()
            .having((value) => value.style, 'style', RouteStyle.twisty)
            .having((value) => value.avoidMotorways, 'avoid motorways', isFalse)
            .having(
              (value) => value.avoidMajorRoads,
              'avoid major roads',
              isTrue,
            )
            .having((value) => value.avoidTolls, 'avoid tolls', isTrue),
      );
      expect(plan.request.variant, 0);
      expect(plan.actualDistanceMeters, 160000);
      expect(plan.motorwayAvoidanceRelaxed, isTrue);
      expect(plan.motorwayAvoidanceRelaxedSections, 1);
      expect(plan.routeSectionCount, 5);
      expect(plan.route.maneuvers, isEmpty);
      expect(plan.route.preferences?.avoidMotorways, isTrue);
      final warning = circularRideMotorwayFallbackWarning(
        relaxedSectionCount: 1,
        routeSectionCount: 5,
      );
      expect(plan.warnings, [warning]);
      expect(plan.route.description, contains(warning));
    },
  );

  test('keeps avoid motorways for an ordinary section detour', () async {
    final routing = _ExcessiveDetourRoadRoutingService(
      blockedSectionDistanceMeters: 40000,
      ordinarySectionDistanceMeters: 30125,
      relaxedSectionDistanceMeters: 30000,
      blockedSectionHasUTurn: false,
    );

    final plan = await CircularRidePlanner(routingService: routing).generate(
      const CircularRideRequest(
        start: start,
        distanceMeters: 100 * 1609.344,
        direction: CircularRideDirection.northWest,
        preferences: RoutePreferences(avoidMotorways: true),
      ),
    );

    expect(routing.motorwayAvoidingCalls, 5);
    expect(routing.forcedMotorcycleCalls, 0);
    expect(plan.actualDistanceMeters, 160500);
    expect(plan.motorwayAvoidanceRelaxed, isFalse);
    expect(plan.warnings, isEmpty);
  });

  test(
    'falls back once when motorcycle routing times out and warns clearly',
    () async {
      final routing = _TimeoutFallbackRoadRoutingService();
      const preferences = RoutePreferences(
        style: RouteStyle.twisty,
        avoidMotorways: true,
        avoidMajorRoads: true,
      );

      final plan = await CircularRidePlanner(routingService: routing).generate(
        const CircularRideRequest(
          start: start,
          distanceMeters: 80 * 1609.344,
          direction: CircularRideDirection.northWest,
          preferences: preferences,
        ),
      );

      expect(
        routing.motorcycleCalls,
        1,
        reason: 'one timeout must stop repeated waits on the unavailable host',
      );
      expect(routing.standardCalls, 5);
      expect(
        routing.standardPreferences,
        everyElement(
          isA<RoutePreferences>()
              .having((value) => value.style, 'style', RouteStyle.twisty)
              .having(
                (value) => value.avoidMotorways,
                'avoid motorways',
                isFalse,
              )
              .having(
                (value) => value.avoidMajorRoads,
                'avoid major roads',
                isFalse,
              ),
        ),
        reason:
            'standard routing keeps the bend bias without claiming hard '
            'motorcycle exclusions were honoured',
      );
      expect(plan.standardRoutingFallbackSections, 5);
      expect(plan.motorwayAvoidanceRelaxed, isTrue);
      expect(plan.motorwayAvoidanceRelaxedSections, 5);
      final warning = circularRideStandardRoutingFallbackWarning(
        fallbackSectionCount: 5,
        routeSectionCount: 5,
        requestedPreferences: preferences,
      );
      expect(plan.warnings, [warning]);
      expect(warning, contains('Motorcycle routing timed out'));
      expect(warning, contains('Avoid motorways'));
      expect(warning, contains('Prefer quieter roads'));
      expect(plan.route.description, contains(warning));
    },
  );

  test(
    'explains when no route exists even after the motorway fallback',
    () async {
      await expectLater(
        CircularRidePlanner(
          routingService: _NoPathRoadRoutingService(),
        ).generate(
          const CircularRideRequest(
            start: start,
            distanceMeters: 80 * 1609.344,
            direction: CircularRideDirection.northWest,
            preferences: RoutePreferences(avoidMotorways: true),
          ),
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            'No usable circular route could be found after trying different '
                'loop shapes and allowing motorways only on blocked sections. '
                'Try another direction or adjust the distance.',
          ),
        ),
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

double _distanceSquared(GeoPoint a, GeoPoint b) {
  final latitude = a.latitude - b.latitude;
  final longitude = (a.longitude - b.longitude) * 0.62;
  return latitude * latitude + longitude * longitude;
}

class _FakeRoadRoutingService implements RoadRoutingService {
  _FakeRoadRoutingService({
    this.maneuvers = const [],
    this.sectionDistanceMeters = 118000 / 5,
    this.sectionDuration = const Duration(minutes: 24),
  });

  final requests = <_RoutingAttempt>[];
  var calls = 0;
  final List<RoadRouteManeuver> maneuvers;
  final double sectionDistanceMeters;
  final Duration sectionDuration;

  @override
  Future<RoadRouteResult> routeThrough(
    List<GeoPoint> waypoints, {
    RoutePreferences? preferences,
    double? originBearingDegrees,
  }) async {
    calls += 1;
    requests.add(
      _RoutingAttempt(
        waypoints: List.unmodifiable(waypoints),
        preferences: preferences,
      ),
    );
    return RoadRouteResult(
      points: waypoints,
      distanceMeters: sectionDistanceMeters,
      duration: sectionDuration,
      maneuvers: maneuvers,
      twistinessScore: 31,
      preferences: preferences,
    );
  }
}

class _UTurnThenValidRoadRoutingService implements RoadRoutingService {
  var calls = 0;

  @override
  Future<RoadRouteResult> routeThrough(
    List<GeoPoint> waypoints, {
    RoutePreferences? preferences,
    double? originBearingDegrees,
  }) async {
    calls += 1;
    return RoadRouteResult(
      points: waypoints,
      distanceMeters: 118000 / 5,
      duration: const Duration(minutes: 24),
      maneuvers: calls == 1
          ? const [
              RoadRouteManeuver(
                position: GeoPoint(latitude: 51.46, longitude: -2.51),
                type: 'turn',
                modifier: 'u-turn',
              ),
            ]
          : const [],
      preferences: preferences,
    );
  }
}

class _BoundaryManeuverRoadRoutingService implements RoadRoutingService {
  @override
  Future<RoadRouteResult> routeThrough(
    List<GeoPoint> waypoints, {
    RoutePreferences? preferences,
    double? originBearingDegrees,
  }) async => RoadRouteResult(
    points: waypoints,
    distanceMeters: 118000 / 6,
    duration: const Duration(minutes: 20),
    maneuvers: [
      RoadRouteManeuver(position: waypoints.first, type: 'depart'),
      RoadRouteManeuver(position: waypoints.first, type: 'turn'),
      RoadRouteManeuver(position: waypoints.last, type: 'arrive'),
    ],
    preferences: preferences,
  );
}

class _MotorwayFallbackRoadRoutingService
    implements RoadRoutingService, MotorcycleCostingRoadRoutingService {
  final attempts = <_RoutingAttempt>[];
  var forcedMotorcycleCalls = 0;
  var motorwayAvoidingCalls = 0;
  List<GeoPoint>? blockedWaypoints;
  List<GeoPoint>? relaxedWaypoints;

  @override
  Future<RoadRouteResult> routeThrough(
    List<GeoPoint> waypoints, {
    RoutePreferences? preferences,
    double? originBearingDegrees,
  }) async {
    final avoidsMotorways = preferences?.avoidMotorways ?? false;
    attempts.add(
      _RoutingAttempt(
        waypoints: List.unmodifiable(waypoints),
        preferences: preferences,
      ),
    );
    if (avoidsMotorways && motorwayAvoidingCalls++ == 1) {
      blockedWaypoints = List.unmodifiable(waypoints);
      throw const RoadRoutingException(
        'Motorcycle routing failed: No path could be found for input',
        statusCode: 400,
        providerCode: '442',
        routeNotFound: true,
      );
    }
    if (!avoidsMotorways) {
      throw StateError('Fallback must retain motorcycle costing.');
    }
    return _sectionResult(waypoints, preferences);
  }

  @override
  Future<RoadRouteResult> routeThroughMotorcycle(
    List<GeoPoint> waypoints, {
    RoutePreferences? preferences,
    double? originBearingDegrees,
  }) async {
    forcedMotorcycleCalls += 1;
    relaxedWaypoints = List.unmodifiable(waypoints);
    attempts.add(
      _RoutingAttempt(waypoints: relaxedWaypoints!, preferences: preferences),
    );
    return _sectionResult(waypoints, preferences);
  }

  RoadRouteResult _sectionResult(
    List<GeoPoint> waypoints,
    RoutePreferences? preferences,
  ) => RoadRouteResult(
    points: waypoints,
    distanceMeters: 80 * 1609.344 / 5,
    duration: const Duration(minutes: 24),
    maneuvers: [
      RoadRouteManeuver(position: waypoints.first, type: 'depart'),
      RoadRouteManeuver(position: waypoints.first, type: 'turn'),
      RoadRouteManeuver(position: waypoints.last, type: 'arrive'),
    ],
    preferences: preferences,
  );
}

class _TimeoutFallbackRoadRoutingService
    implements RoadRoutingService, StandardCostingRoadRoutingService {
  var motorcycleCalls = 0;
  var standardCalls = 0;
  final standardPreferences = <RoutePreferences?>[];

  @override
  Future<RoadRouteResult> routeThrough(
    List<GeoPoint> waypoints, {
    RoutePreferences? preferences,
    double? originBearingDegrees,
  }) async {
    motorcycleCalls += 1;
    await Future<void>.delayed(Duration.zero);
    throw TimeoutException('Motorcycle routing did not respond.');
  }

  @override
  Future<RoadRouteResult> routeThroughStandard(
    List<GeoPoint> waypoints, {
    RoutePreferences? preferences,
    double? originBearingDegrees,
  }) async {
    standardCalls += 1;
    standardPreferences.add(preferences);
    return RoadRouteResult(
      points: waypoints,
      distanceMeters: 80 * 1609.344 / 5,
      duration: const Duration(minutes: 24),
      preferences: preferences,
    );
  }
}

class _ExcessiveDetourRoadRoutingService
    implements RoadRoutingService, MotorcycleCostingRoadRoutingService {
  _ExcessiveDetourRoadRoutingService({
    required this.blockedSectionDistanceMeters,
    required this.ordinarySectionDistanceMeters,
    required this.relaxedSectionDistanceMeters,
    required this.blockedSectionHasUTurn,
  });

  final double blockedSectionDistanceMeters;
  final double ordinarySectionDistanceMeters;
  final double relaxedSectionDistanceMeters;
  final bool blockedSectionHasUTurn;
  var motorwayAvoidingCalls = 0;
  var forcedMotorcycleCalls = 0;
  List<GeoPoint>? blockedWaypoints;
  List<GeoPoint>? relaxedWaypoints;
  RoutePreferences? relaxedPreferences;

  @override
  Future<RoadRouteResult> routeThrough(
    List<GeoPoint> waypoints, {
    RoutePreferences? preferences,
    double? originBearingDegrees,
  }) async {
    if (!(preferences?.avoidMotorways ?? false)) {
      throw StateError('Fallback must retain motorcycle costing.');
    }
    motorwayAvoidingCalls += 1;
    final isBlockedSection =
        waypoints.first.longitude < -2.9 && waypoints.last.latitude > 51.6;
    if (isBlockedSection) blockedWaypoints = List.unmodifiable(waypoints);
    return RoadRouteResult(
      points: waypoints,
      distanceMeters: isBlockedSection
          ? blockedSectionDistanceMeters
          : ordinarySectionDistanceMeters,
      duration: const Duration(minutes: 30),
      maneuvers: isBlockedSection && blockedSectionHasUTurn
          ? [
              RoadRouteManeuver(
                position: waypoints.first,
                type: 'turn',
                modifier: 'u-turn',
              ),
            ]
          : const [],
      preferences: preferences,
    );
  }

  @override
  Future<RoadRouteResult> routeThroughMotorcycle(
    List<GeoPoint> waypoints, {
    RoutePreferences? preferences,
    double? originBearingDegrees,
  }) async {
    forcedMotorcycleCalls += 1;
    relaxedWaypoints = List.unmodifiable(waypoints);
    relaxedPreferences = preferences;
    return RoadRouteResult(
      points: waypoints,
      distanceMeters: relaxedSectionDistanceMeters,
      duration: const Duration(minutes: 25),
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
    final attempt = calls ~/ 5;
    final distance =
        distances[attempt.clamp(0, distances.length - 1).toInt()] / 5;
    calls += 1;
    return RoadRouteResult(
      points: waypoints,
      distanceMeters: distance,
      duration: const Duration(minutes: 30),
      preferences: preferences,
    );
  }
}

class _NoPathRoadRoutingService implements RoadRoutingService {
  @override
  Future<RoadRouteResult> routeThrough(
    List<GeoPoint> waypoints, {
    RoutePreferences? preferences,
    double? originBearingDegrees,
  }) => throw const RoadRoutingException(
    'Motorcycle routing failed: No path could be found for input',
    statusCode: 400,
    providerCode: '442',
    routeNotFound: true,
  );
}

class _RoutingAttempt {
  const _RoutingAttempt({required this.waypoints, required this.preferences});

  final List<GeoPoint> waypoints;
  final RoutePreferences? preferences;

  bool get avoidMotorways => preferences?.avoidMotorways ?? false;
}
