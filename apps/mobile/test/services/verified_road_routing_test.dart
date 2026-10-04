import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:ride_relay/domain/distance_unit.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/services/circular_ride_planner.dart';
import 'package:ride_relay/services/road_routing.dart';
import 'package:ride_relay/services/route_attribute_provider.dart';
import 'package:ride_relay/services/route_geometry_enricher.dart';
import 'package:ride_relay/services/route_reshape_planner.dart';
import 'package:ride_relay/services/route_verification.dart';
import 'package:ride_relay/services/verified_road_routing.dart';

import 'route_verification_fixtures.dart';

/// A planned route is checked against what the rider asked for, and re-planned
/// once around what breaks it (#840, #858).
///
/// Every route and every trace here is a router response recorded on
/// 4 October 2026 (see `route_verification_fixtures.dart`), played back through
/// the real clients, so what is asserted is what the app does with what the
/// services actually said.
void main() {
  // The approach to a canal-side wharf: OSRM and Valhalla both take the last
  // 650 m over an untagged `highway=track` with gates.
  const wharfApproach = GeoPoint(latitude: 51.747143, longitude: -2.986532);
  const wharf = GeoPoint(latitude: 51.752096, longitude: -2.9971343);

  // A short run on and off the M5, which both routers take by motorway.
  const motorwayStart = GeoPoint(latitude: 51.5460, longitude: -2.5900);
  const motorwayEnd = GeoPoint(latitude: 51.6385, longitude: -2.4893);

  DestinationRoutePlanner planner(RecordedRouting routing) =>
      DestinationRoutePlanner(
        searchService: const _Places(),
        routingService: buildPlanningRoutingService(
          client: routing.client,
          configuration: planningConfiguration,
        ),
        idFactory: () => 'planned',
        clock: () => DateTime.utc(2026, 10, 4),
      );

  Future<DestinationRoutePlan> planWharf(
    RecordedRouting routing, {
    RoutePreferences preferences = RoutePreferences.defaults,
  }) => planner(routing).planForReview(
    origin: wharfApproach,
    query: 'Wharf',
    selectedDestination: const DestinationMatch(label: 'Wharf', point: wharf),
    preferences: preferences,
  );

  Future<DestinationRoutePlan> planMotorway(
    RecordedRouting routing,
    RoutePreferences preferences,
  ) => planner(routing).planForReview(
    origin: motorwayStart,
    query: 'Falfield',
    selectedDestination: const DestinationMatch(
      label: 'Falfield',
      point: motorwayEnd,
    ),
    preferences: preferences,
  );

  group('a track on the way (#840)', () {
    test('the default preferences re-plan around a gated track', () async {
      final routing = RecordedRouting(
        osrm: fixtureResponse('osrm_track_approach.json'),
        valhallaExcluding: fixtureResponse('valhalla_track_avoided.json'),
        traces: [
          fixtureResponse('trace_track_approach.json'),
          fixtureResponse('trace_track_avoided.json'),
        ],
      );

      final plan = await planWharf(routing);

      // OSRM planned it, as it does for the default preferences, and went over
      // the track: 1.27 km. The check found that and asked Valhalla again.
      expect(routing.osrmRequests, hasLength(1));
      expect(routing.traceRequests, hasLength(2));
      expect(routing.valhallaRequests, hasLength(1));
      expect(plan.distanceMeters, closeTo(2852, 1), reason: 'went round');
      final replanned = valhallaRoutePoints('valhalla_track_avoided.json');
      final points = plan.route.paths.single.points;
      expect(points, hasLength(replanned.length));
      expect(points.first.latitude, replanned.first.latitude);
      expect(points.last.longitude, replanned.last.longitude);

      final verification = plan.verification!;
      expect(verification.checked, isTrue);
      expect(verification.replan, RouteReplanOutcome.adopted);
      expect(verification.concerns, isEmpty);
      expect(verification.avoided.single.kind, RouteConcernKind.unsurfaced);
      expect(verification.avoided.single.lengthMeters, closeTo(576, 0.5));
      expect(verification.notices(DistanceUnit.miles), isEmpty);
    });

    test('the re-plan excludes the track by position and keeps what was asked '
        'for', () async {
      final routing = RecordedRouting(
        osrm: fixtureResponse('osrm_track_approach.json'),
        valhallaExcluding: fixtureResponse('valhalla_track_avoided.json'),
        traces: [
          fixtureResponse('trace_track_approach.json'),
          fixtureResponse('trace_track_avoided.json'),
        ],
      );

      await planWharf(routing);

      final request = routing.valhallaRequests.single;
      final excluded = [
        for (final location
            in (request['exclude_locations']! as List)
                .cast<Map<String, Object?>>())
          GeoPoint(
            latitude: location['lat']! as double,
            longitude: location['lon']! as double,
          ),
      ];
      // One point in the middle of each of the track's seven edges, worked out
      // here from the recorded trace and not by the code under test.
      final expected = trackEdgeMidpoints('trace_track_approach.json');
      expect(expected, hasLength(7));
      expect(excluded, hasLength(7));
      for (final (index, point) in excluded.indexed) {
        expect(
          routeDistanceMeters(point, expected[index]),
          lessThan(0.5),
          reason:
              'excluded $point, the middle of that edge is ${expected[index]}',
        );
      }
      final locations = (request['locations']! as List).cast<Map>();
      expect(locations.map((location) => location['type']), ['break', 'break']);
      final costing =
          (request['costing_options']! as Map)['motorcycle']! as Map;
      expect(costing['exclude_unpaved'], isTrue);
      expect(costing['use_trails'], 0);
      expect(request['costing'], 'motorcycle');
    });

    test('the re-planned route is itself checked before it is used', () async {
      final routing = RecordedRouting(
        osrm: fixtureResponse('osrm_track_approach.json'),
        valhallaExcluding: fixtureResponse('valhalla_track_avoided.json'),
        traces: [
          fixtureResponse('trace_track_approach.json'),
          fixtureResponse('trace_track_avoided.json'),
        ],
      );

      await planWharf(routing);

      final first = (routing.traceRequests.first['shape']! as List).cast<Map>();
      final second = (routing.traceRequests.last['shape']! as List).cast<Map>();
      expect(first.first['lat'], closeTo(51.747143, 1e-5));
      expect(second.last['lat'], closeTo(51.7519, 1e-3));
      expect(
        second.length,
        isNot(first.length),
        reason: 'the second check was made on the new geometry',
      );
    });

    test('a track that cannot be avoided is shown with its length', () async {
      // Valhalla is asked again and goes straight back over the track.
      final routing = RecordedRouting(
        osrm: fixtureResponse('osrm_track_approach.json'),
        valhallaExcluding: fixtureResponse('valhalla_track_approach.json'),
        traces: [
          fixtureResponse('trace_track_approach.json'),
          fixtureResponse('trace_track_approach.json'),
        ],
      );

      final plan = await planWharf(routing);

      expect(routing.valhallaRequests, hasLength(1), reason: 're-plans once');
      expect(routing.traceRequests, hasLength(2));
      expect(plan.distanceMeters, closeTo(1267.4, 0.1), reason: 'kept');
      final verification = plan.verification!;
      expect(verification.replan, RouteReplanOutcome.failed);
      expect(verification.notices(DistanceUnit.miles), [
        'Uses 0.4 mi of unsurfaced track, although Avoid unsurfaced byways is '
            'on. No road route that avoids it was found.',
      ]);
      expect(
        verification.notices(DistanceUnit.kilometres).single,
        contains('580 m'),
      );
    });

    test('a provider with no route that avoids the track says so', () async {
      final routing = RecordedRouting(
        osrm: fixtureResponse('osrm_track_approach.json'),
        valhallaExcluding: fixtureResponse('valhalla_no_path.json', 400),
        traces: [fixtureResponse('trace_track_approach.json')],
      );

      final plan = await planWharf(routing);

      expect(routing.valhallaRequests, hasLength(1));
      expect(routing.traceRequests, hasLength(1), reason: 'nothing to check');
      expect(plan.distanceMeters, closeTo(1267.4, 0.1));
      expect(
        plan.verification!.notices(DistanceUnit.miles).single,
        endsWith('No road route that avoids it was found.'),
      );
    });

    test('a re-plan that moves the destination is not an answer', () async {
      // The excluded request comes back as a different trip altogether.
      final routing = RecordedRouting(
        osrm: fixtureResponse('osrm_track_approach.json'),
        valhallaExcluding: fixtureResponse('valhalla_m5_avoided.json'),
        traces: [fixtureResponse('trace_track_approach.json')],
      );

      final plan = await planWharf(routing);

      expect(plan.distanceMeters, closeTo(1267.4, 0.1), reason: 'kept');
      expect(routing.traceRequests, hasLength(1), reason: 'never checked');
      expect(plan.verification!.replan, RouteReplanOutcome.failed);
      expect(
        plan.verification!.concerns.single.kind,
        RouteConcernKind.unsurfaced,
      );
    });

    test('a re-plan that is not clearly better is not used', () async {
      // Still on the track for the same 576 m: nothing was gained.
      final routing = RecordedRouting(
        osrm: fixtureResponse('osrm_track_approach.json'),
        valhallaExcluding: fixtureResponse('valhalla_track_avoided.json'),
        traces: [
          fixtureResponse('trace_track_approach.json'),
          fixtureResponse('trace_track_approach.json'),
        ],
      );

      final plan = await planWharf(routing);

      expect(plan.distanceMeters, closeTo(1267.4, 0.1));
      expect(plan.verification!.replan, RouteReplanOutcome.failed);
    });

    test(
      'a route that could not be checked says so, and is not re-planned',
      () async {
        final routing = RecordedRouting(
          osrm: fixtureResponse('osrm_track_approach.json'),
          traces: [http.Response('busy', 503)],
        );

        final plan = await planWharf(routing);

        expect(routing.valhallaRequests, isEmpty);
        expect(plan.distanceMeters, closeTo(1267.4, 0.1));
        final verification = plan.verification!;
        expect(verification.checked, isFalse);
        expect(verification.notices(DistanceUnit.miles), [
          'Could not check this route against your road preferences (avoid '
              'unsurfaced byways), so it may use roads you asked to avoid.',
        ]);
      },
    );

    test(
      'allowing unsurfaced byways asks for the track and is not told off',
      () async {
        final routing = RecordedRouting(
          valhalla: fixtureResponse('valhalla_track_approach.json'),
          traces: [fixtureResponse('trace_track_approach.json')],
        );

        final plan = await planWharf(
          routing,
          preferences: const RoutePreferences(
            bywaySurface: BywaySurfacePreference.allowUnsurfaced,
          ),
        );

        expect(
          routing.osrmRequests,
          isEmpty,
          reason: 'seeking byways is Valhalla',
        );
        expect(routing.valhallaRequests, hasLength(1));
        expect(routing.traceRequests, hasLength(1));
        expect(plan.verification!.isClean, isTrue);
        expect(plan.verification!.replan, RouteReplanOutcome.notAttempted);
      },
    );

    test(
      'the plan no longer says byways were avoided when they were not',
      () async {
        final routing = RecordedRouting(
          osrm: fixtureResponse('osrm_track_approach.json'),
          valhallaExcluding: fixtureResponse('valhalla_track_approach.json'),
          traces: [
            fixtureResponse('trace_track_approach.json'),
            fixtureResponse('trace_track_approach.json'),
          ],
        );

        final plan = await planWharf(routing);

        expect(plan.route.description, isNot(contains('byways avoided')));
        expect(plan.route.description, contains('Avoid unsurfaced byways.'));
      },
    );

    test(
      'the preferences the plan was made with are kept on the route',
      () async {
        final routing = RecordedRouting(
          osrm: fixtureResponse('osrm_track_approach.json'),
          valhallaExcluding: fixtureResponse('valhalla_track_avoided.json'),
          traces: [
            fixtureResponse('trace_track_approach.json'),
            fixtureResponse('trace_track_avoided.json'),
          ],
        );

        final plan = await planWharf(routing);

        expect(plan.route.preferences, RoutePreferences.defaults);
      },
    );
  });

  group('a motorway the rider asked to avoid (#858)', () {
    const avoidMotorways = RoutePreferences(avoidMotorways: true);

    test('is asked of Valhalla, and the avoidance is sent', () async {
      final routing = RecordedRouting(
        valhalla: fixtureResponse('valhalla_m5_avoided.json'),
        traces: [fixtureResponse('trace_m5_avoided.json')],
      );

      final plan = await planMotorway(routing, avoidMotorways);

      expect(routing.osrmRequests, isEmpty, reason: 'OSRM cannot avoid them');
      final costing =
          (routing.valhallaRequests.single['costing_options']!
                  as Map)['motorcycle']!
              as Map;
      expect(costing['exclude_highways'], isTrue);
      expect(plan.verification!.isClean, isTrue);
      expect(routing.valhallaRequests, hasLength(1), reason: 'nothing to redo');
    });

    test(
      'the plan says what was asked, not that motorways were excluded',
      () async {
        final routing = RecordedRouting(
          valhalla: fixtureResponse('valhalla_m5_avoided.json'),
          traces: [fixtureResponse('trace_m5_avoided.json')],
        );

        final plan = await planMotorway(
          routing,
          const RoutePreferences(avoidMotorways: true, avoidMajorRoads: true),
        );

        expect(
          plan.route.description,
          contains('Avoid motorways, avoid major'),
        );
        expect(plan.route.description, isNot(contains('excluded')));
      },
    );

    test(
      'one the provider routed anyway is excluded and the trip re-planned',
      () async {
        // Valhalla ignores the avoidance and returns the M5 route; the check
        // finds 12.6 km of motorway, and the stricter request answers.
        final routing = RecordedRouting(
          valhalla: fixtureResponse('valhalla_m5_stretch.json'),
          valhallaExcluding: fixtureResponse('valhalla_m5_avoided.json'),
          traces: [
            fixtureResponse('trace_m5_stretch.json'),
            fixtureResponse('trace_m5_avoided.json'),
          ],
        );

        final plan = await planMotorway(routing, avoidMotorways);

        expect(routing.valhallaRequests, hasLength(2));
        expect(
          routing.valhallaRequests.first.containsKey('exclude_locations'),
          isFalse,
        );
        final excluded =
            routing.valhallaRequests.last['exclude_locations']! as List;
        expect(excluded, hasLength(11), reason: 'one per motorway edge');
        expect(plan.distanceMeters, closeTo(16930, 1), reason: 'the A38 route');
        final verification = plan.verification!;
        expect(verification.replan, RouteReplanOutcome.adopted);
        expect(verification.avoided.single.kind, RouteConcernKind.motorway);
        expect(verification.avoided.single.labels, ['M5']);
        expect(verification.concerns, isEmpty);
      },
    );

    test('one that cannot be avoided is named, with its length', () async {
      final routing = RecordedRouting(
        valhalla: fixtureResponse('valhalla_m5_stretch.json'),
        valhallaExcluding: fixtureResponse('valhalla_no_path.json', 400),
        traces: [fixtureResponse('trace_m5_stretch.json')],
      );

      final plan = await planMotorway(routing, avoidMotorways);

      expect(plan.distanceMeters, closeTo(18805, 1), reason: 'the M5 route');
      expect(plan.verification!.notices(DistanceUnit.miles), [
        'Uses 7.8 mi of motorway (M5), although Avoid motorways is on. No '
            'motorway-free route was found.',
      ]);
      expect(plan.verification!.notices(DistanceUnit.kilometres), [
        'Uses 12.6 km of motorway (M5), although Avoid motorways is on. No '
            'motorway-free route was found.',
      ]);
    });

    test('major roads are reported, and are never re-planned', () async {
      final routing = RecordedRouting(
        valhalla: fixtureResponse('valhalla_m5_avoided.json'),
        traces: [fixtureResponse('trace_m5_avoided.json')],
      );

      final plan = await planMotorway(
        routing,
        const RoutePreferences(avoidMajorRoads: true),
      );

      expect(routing.valhallaRequests, hasLength(1));
      expect(routing.traceRequests, hasLength(1));
      expect(plan.verification!.replan, RouteReplanOutcome.notAttempted);
      expect(plan.verification!.notices(DistanceUnit.miles), [
        'Uses 7.9 mi of major roads (A38), although Avoid major roads is on.',
      ]);
    });

    test('a motorway nobody asked to avoid is not mentioned', () async {
      final routing = RecordedRouting(
        osrm: fixtureResponse('osrm_m5_stretch.json'),
        traces: [fixtureResponse('trace_m5_stretch.json')],
      );

      final plan = await planMotorway(routing, RoutePreferences.defaults);

      expect(plan.distanceMeters, closeTo(18617.7, 0.1));
      expect(plan.verification!.isClean, isTrue);
      expect(routing.valhallaRequests, isEmpty);
    });
  });

  group('the verifier', () {
    RouteTrace covering(double submitted, {double? covered, double? route}) =>
        RouteTrace(
          edges: [
            RouteEdge(
              lengthMeters: covered ?? submitted,
              beginShapeIndex: 0,
              endShapeIndex: 1,
              use: 'road',
            ),
          ],
          shape: const [
            GeoPoint(latitude: 51, longitude: -2),
            GeoPoint(latitude: 51.01, longitude: -2),
          ],
          submittedMeters: submitted,
          routeMeters: route ?? submitted,
        );
    const line = [
      GeoPoint(latitude: 51, longitude: -2),
      GeoPoint(latitude: 51.01, longitude: -2),
    ];

    test(
      'a route longer than one request can cover says how much was checked',
      () async {
        final verifier = RouteVerifier(
          attributes: _FakeAttributes(
            (_) async => covering(190000, route: 300000),
          ),
        );

        final result = await verifier.inspect(line, RoutePreferences.defaults);

        expect(result.checked, isTrue);
        expect(result.isPartial, isTrue);
        expect(
          result.notices(DistanceUnit.miles).single,
          startsWith('Only 118.1 mi'),
        );
      },
    );

    test(
      'a line the matcher could barely match tells nothing about the route',
      () async {
        final verifier = RouteVerifier(
          attributes: _FakeAttributes(
            (_) async => covering(10000, covered: 3000),
          ),
        );

        expect((await verifier.inspect(line, null)).checked, isFalse);
      },
    );

    test('a matcher that wandered off the route is not believed', () async {
      final verifier = RouteVerifier(
        attributes: _FakeAttributes(
          (_) async => covering(10000, covered: 14000),
        ),
      );

      expect((await verifier.inspect(line, null)).checked, isFalse);
    });

    test(
      'a lookup that fails is reported as unchecked, not as clean',
      () async {
        final verifier = RouteVerifier(
          attributes: _FakeAttributes(
            (_) async => throw const RouteAttributeException('down'),
          ),
        );

        final result = await verifier.inspect(line, RoutePreferences.defaults);

        expect(result.checked, isFalse);
        expect(result.isClean, isFalse);
        expect(result.routeMeters, greaterThan(1000));
      },
    );

    test('no preferences are checked as the defaults', () async {
      final verifier = RouteVerifier(
        attributes: _FakeAttributes((_) async => covering(1000)),
      );

      expect(
        (await verifier.inspect(line, null)).preferences,
        RoutePreferences.defaults,
      );
    });

    test(
      'a hard concern with nothing to exclude is reported, not re-planned',
      () async {
        var replans = 0;
        final verifier = RouteVerifier(
          attributes: _FakeAttributes(
            (_) async => RouteTrace(
              edges: const [
                RouteEdge(
                  lengthMeters: 500,
                  beginShapeIndex: 0,
                  endShapeIndex: 9,
                  use: 'track',
                  unpaved: true,
                ),
              ],
              // Fewer shape points than the edge claims: no midpoint to exclude.
              shape: line,
              submittedMeters: 500,
              routeMeters: 500,
            ),
          ),
        );

        final result = await verifier.verify(
          RoadRouteResult(
            points: line,
            distanceMeters: 500,
            duration: const Duration(minutes: 1),
          ),
          replan: (_) async {
            replans += 1;
            throw StateError('should not be asked');
          },
        );

        expect(replans, 0);
        expect(result.verification!.hasHardConcerns, isTrue);
        expect(result.verification!.replan, RouteReplanOutcome.notAttempted);
      },
    );

    test('it is told to exclude at most as many edges as it may', () async {
      List<GeoPoint>? excluded;
      final verifier = RouteVerifier(
        attributes: _FakeAttributes(
          (_) async => ValhallaRouteAttributeProvider.parseRouteTrace(
            routeVerificationFixture('trace_track_approach.json'),
            submittedMeters: 1268,
            routeMeters: 1268,
          ),
        ),
        maximumExclusions: 3,
      );

      await verifier.verify(
        RoadRouteResult(
          points: osrmFixturePoints('osrm_track_approach.json'),
          distanceMeters: 1267.4,
          duration: const Duration(minutes: 5),
        ),
        replan: (locations) async {
          excluded = locations;
          throw const RoadRoutingException('no route');
        },
      );

      expect(excluded, hasLength(3), reason: 'the track is seven edges');
    });
  });

  group('the service that checks its routes', () {
    test('keeps the controls the caller gave, including silent ones', () async {
      final inner = _CapableRouting();
      final service = VerifiedRoadRoutingService(
        routing: inner,
        verifier: RouteVerifier(
          attributes: ValhallaRouteAttributeProvider(
            client: RecordedRouting(
              traces: [
                fixtureResponse('trace_track_approach.json'),
                fixtureResponse('trace_track_avoided.json'),
              ],
            ).client,
            endpoint: Uri.parse(
              'https://valhalla.example.test/trace_attributes',
            ),
          ),
        ),
      );
      const waypoints = [
        GeoPoint(latitude: 51.747143, longitude: -2.986532),
        GeoPoint(latitude: 51.749, longitude: -2.99),
        GeoPoint(latitude: 51.752096, longitude: -2.9971343),
      ];

      await service.routeThroughShapingPoints(
        waypoints,
        shapingPointIndexes: const {1},
        shapingPointSearchRadiusMeters: 300,
        preferences: RoutePreferences.defaults,
        originBearingDegrees: 12,
      );

      expect(inner.shaping, hasLength(1));
      expect(inner.shaping.single.shapingPointIndexes, {1});
      expect(inner.shaping.single.radius, 300);
      // And the re-plan was asked for the very same trip, minus the track.
      expect(inner.excluding, hasLength(1));
      expect(inner.excluding.single.shapingPointIndexes, {1});
      expect(inner.excluding.single.radius, 300);
      expect(inner.excluding.single.bearing, 12);
      expect(inner.excluding.single.waypoints, waypoints);
      expect(inner.excluding.single.excluded, hasLength(7));
    });

    test('a service that cannot exclude roads can only report', () async {
      final routing = RecordedRouting(
        osrm: fixtureResponse('osrm_track_approach.json'),
        traces: [fixtureResponse('trace_track_approach.json')],
      );
      final service = VerifiedRoadRoutingService(
        routing: OsrmRoadRoutingService(
          client: routing.client,
          baseUrl: Uri.parse('https://osrm.example.test'),
        ),
        verifier: RouteVerifier.production(
          client: routing.client,
          configuration: planningConfiguration,
        ),
      );

      final result = await service.routeThrough(const [wharfApproach, wharf]);

      expect(result.verification!.hasHardConcerns, isTrue);
      expect(result.verification!.replan, RouteReplanOutcome.notAttempted);
      expect(result.distanceMeters, closeTo(1267.4, 0.1));
    });

    test(
      'the dispatcher cannot exclude roads through a router that cannot',
      () {
        final dispatcher = PreferenceAwareRoadRoutingService(
          osrm: _Sections(),
          motorcycle: _Sections(),
        );

        expect(
          () => dispatcher.routeThroughExcluding(
            const [wharfApproach, wharf],
            excludeLocations: const [wharf],
          ),
          throwsA(isA<RoadRoutingException>()),
        );
      },
    );

    test('offers the capabilities a planner needs and no more', () {
      final service = VerifiedRoadRoutingService(
        routing: _CapableRouting(),
        verifier: const RouteVerifier(attributes: _NoAttributes()),
      );

      expect(service, isA<ShapingPointRoadRoutingService>());
      // A circular planner tests for these to choose its engine, and would
      // choose differently - and check every candidate - if it found them.
      expect(service, isNot(isA<MotorcycleCostingRoadRoutingService>()));
      expect(service, isNot(isA<StandardCostingRoadRoutingService>()));
    });
  });

  group('every planner reports what the check found', () {
    ImportedRoute plannedRoute() => ImportedRoute(
      id: 'planned',
      name: 'To Wharf',
      importedAt: DateTime.utc(2026, 10, 4),
      sourceFileName: 'planned.gpx',
      paths: const [
        RoutePath(
          kind: RoutePathKind.track,
          points: [
            GeoPoint(latitude: 51.747143, longitude: -2.986532),
            GeoPoint(latitude: 51.752096, longitude: -2.9971343),
          ],
        ),
      ],
      waypoints: const [
        RouteWaypoint(point: wharfApproach, name: 'Start'),
        RouteWaypoint(point: wharf, name: 'Wharf'),
      ],
      preferences: RoutePreferences.defaults,
    );

    RoadRoutingService stack(RecordedRouting routing) =>
        buildPlanningRoutingService(
          client: routing.client,
          configuration: planningConfiguration,
        );

    test(
      'reshaping a route is checked, and the new route replaces the old',
      () async {
        final routing = RecordedRouting(
          osrm: fixtureResponse('osrm_track_approach.json'),
          valhallaExcluding: fixtureResponse('valhalla_track_avoided.json'),
          traces: [
            fixtureResponse('trace_track_approach.json'),
            fixtureResponse('trace_track_avoided.json'),
          ],
        );

        final result = await RouteReshapePlanner(
          routingService: stack(routing),
        ).reshape(plannedRoute(), const []);

        expect(result.verification!.replan, RouteReplanOutcome.adopted);
        expect(result.distanceMeters, closeTo(2852, 1));
      },
    );

    test(
      'a reshape that goes over a track is reported with its length',
      () async {
        final routing = RecordedRouting(
          osrm: fixtureResponse('osrm_track_approach.json'),
          valhallaExcluding: fixtureResponse('valhalla_no_path.json', 400),
          traces: [fixtureResponse('trace_track_approach.json')],
        );

        final result = await RouteReshapePlanner(
          routingService: stack(routing),
        ).reshape(plannedRoute(), const []);

        expect(
          result.verification!.concerns.single.kind,
          RouteConcernKind.unsurfaced,
        );
        expect(result.distanceMeters, closeTo(1267.4, 0.1));
      },
    );

    test('a GPX route snapped to roads is checked', () async {
      final routing = RecordedRouting(
        osrm: fixtureResponse('osrm_track_approach.json'),
        valhallaExcluding: fixtureResponse('valhalla_track_avoided.json'),
        traces: [
          fixtureResponse('trace_track_approach.json'),
          fixtureResponse('trace_track_avoided.json'),
        ],
      );
      final gpx = ImportedRoute(
        id: 'gpx',
        name: 'Imported',
        importedAt: DateTime.utc(2026, 10, 4),
        sourceFileName: 'imported.gpx',
        paths: const [
          RoutePath(
            kind: RoutePathKind.route,
            points: [
              GeoPoint(latitude: 51.747143, longitude: -2.986532),
              GeoPoint(latitude: 51.752096, longitude: -2.9971343),
            ],
          ),
        ],
        waypoints: const [],
      );

      final enrichment = await RouteGeometryEnricher(
        routingService: stack(routing),
      ).enrich(gpx);

      expect(enrichment.changed, isTrue);
      expect(enrichment.verification!.replan, RouteReplanOutcome.adopted);
      expect(
        enrichment.route.paths.single.points.length,
        greaterThan(30),
        reason: 'the re-planned geometry replaced the sparse route',
      );
    });

    test('a route left as it was has no check to report', () async {
      final routing = RecordedRouting();
      final enrichment = await RouteGeometryEnricher(
        routingService: stack(routing),
      ).enrich(plannedRoute());

      expect(enrichment.changed, isFalse);
      expect(enrichment.verification, isNull);
      expect(routing.traceRequests, isEmpty);
    });

    test(
      'a circular loop is checked once, for the loop it settles on',
      () async {
        final provider = _FakeAttributes(
          (_) async => RouteTrace(
            edges: const [
              RouteEdge(
                lengthMeters: 118000,
                beginShapeIndex: 0,
                endShapeIndex: 1,
                use: 'track',
                unpaved: true,
              ),
            ],
            shape: const [
              GeoPoint(latitude: 51, longitude: -2),
              GeoPoint(latitude: 51.1, longitude: -2),
            ],
            submittedMeters: 118000,
            routeMeters: 118000,
          ),
        );

        final plan =
            await CircularRidePlanner(
              routingService: _Sections(),
              verifier: RouteVerifier(attributes: provider),
            ).generate(
              const CircularRideRequest(
                start: GeoPoint(latitude: 51.46, longitude: -2.51),
                distanceMeters: 120000,
                direction: CircularRideDirection.northEast,
                preferences: RoutePreferences(style: RouteStyle.twisty),
              ),
            );

        expect(provider.requests, hasLength(1));
        expect(provider.requests.single, plan.route.paths.single.points);
        expect(
          plan.routeVerification!.concerns.single.kind,
          RouteConcernKind.unsurfaced,
        );
      },
    );

    test('a loop planned with no verifier is not checked', () async {
      final plan = await CircularRidePlanner(routingService: _Sections())
          .generate(
            const CircularRideRequest(
              start: GeoPoint(latitude: 51.46, longitude: -2.51),
              distanceMeters: 120000,
              direction: CircularRideDirection.northEast,
              preferences: RoutePreferences(style: RouteStyle.twisty),
            ),
          );

      expect(plan.routeVerification, isNull);
    });
  });
}

class _Places implements DestinationSearchService {
  const _Places();

  @override
  Future<List<DestinationMatch>> search(String query) async =>
      throw StateError('The test selects its places; nothing is geocoded.');
}

class _FakeAttributes implements RouteAttributeProvider {
  _FakeAttributes(this._answer);

  final Future<RouteTrace> Function(List<GeoPoint> route) _answer;
  final requests = <List<GeoPoint>>[];

  @override
  Future<RouteTrace> trace(List<GeoPoint> route) {
    requests.add(route);
    return _answer(route);
  }
}

class _NoAttributes implements RouteAttributeProvider {
  const _NoAttributes();

  @override
  Future<RouteTrace> trace(List<GeoPoint> route) =>
      throw const RouteAttributeException('not used');
}

/// Loop sections as straight lines through their waypoints, 118 km in all.
class _Sections implements RoadRoutingService {
  @override
  Future<RoadRouteResult> routeThrough(
    List<GeoPoint> waypoints, {
    RoutePreferences? preferences,
    double? originBearingDegrees,
  }) async => RoadRouteResult(
    points: waypoints,
    distanceMeters: 118000 / 6,
    duration: const Duration(minutes: 20),
    preferences: preferences,
  );
}

/// A router with every optional capability, remembering how it was asked.
class _CapableRouting
    implements
        RoadRoutingService,
        ShapingPointRoadRoutingService,
        ExclusionRoadRoutingService {
  final shaping = <_Call>[];
  final excluding = <_Call>[];

  /// The recorded geometry, so a recorded trace of it is a fair check.
  RoadRouteResult _route(List<GeoPoint> waypoints) => RoadRouteResult(
    points: osrmFixturePoints('osrm_track_approach.json'),
    distanceMeters: 1267.4,
    duration: const Duration(minutes: 5),
  );

  @override
  Future<RoadRouteResult> routeThrough(
    List<GeoPoint> waypoints, {
    RoutePreferences? preferences,
    double? originBearingDegrees,
  }) async => _route(waypoints);

  @override
  Future<RoadRouteResult> routeThroughShapingPoints(
    List<GeoPoint> waypoints, {
    required Set<int> shapingPointIndexes,
    double shapingPointSearchRadiusMeters = 0,
    RoutePreferences? preferences,
    RoadRoutingCosting costing = RoadRoutingCosting.preferred,
    double? originBearingDegrees,
  }) async {
    shaping.add(
      _Call(
        waypoints: waypoints,
        shapingPointIndexes: shapingPointIndexes,
        radius: shapingPointSearchRadiusMeters,
        bearing: originBearingDegrees,
      ),
    );
    return _route(waypoints);
  }

  @override
  Future<RoadRouteResult> routeThroughExcluding(
    List<GeoPoint> waypoints, {
    required List<GeoPoint> excludeLocations,
    Set<int>? shapingPointIndexes,
    double shapingPointSearchRadiusMeters = 0,
    RoutePreferences? preferences,
    double? originBearingDegrees,
  }) async {
    excluding.add(
      _Call(
        waypoints: waypoints,
        shapingPointIndexes: shapingPointIndexes,
        radius: shapingPointSearchRadiusMeters,
        bearing: originBearingDegrees,
        excluded: excludeLocations,
      ),
    );
    return _route(waypoints);
  }
}

class _Call {
  const _Call({
    required this.waypoints,
    required this.shapingPointIndexes,
    required this.radius,
    required this.bearing,
    this.excluded = const [],
  });

  final List<GeoPoint> waypoints;
  final Set<int>? shapingPointIndexes;
  final double radius;
  final double? bearing;
  final List<GeoPoint> excluded;
}

/// The geometry of a recorded Valhalla route response.
List<GeoPoint> valhallaRoutePoints(String fixture) {
  final trip = routeVerificationFixture(fixture)['trip']! as Map;
  final points = <GeoPoint>[];
  for (final leg in trip['legs']! as List) {
    final shape = ValhallaMotorcycleRoutingService.decodeValhallaShape(
      (leg as Map)['shape'],
    );
    points.addAll(points.isEmpty ? shape : shape.skip(1));
  }
  return points;
}

/// The point half way along each track edge of a recorded trace, found here from
/// the matched shape rather than by the code that chooses what to exclude.
List<GeoPoint> trackEdgeMidpoints(String fixture) {
  final body = routeVerificationFixture(fixture);
  final shape = ValhallaMotorcycleRoutingService.decodeValhallaShape(
    body['shape'],
  );
  final trace = ValhallaRouteAttributeProvider.parseRouteTrace(
    body,
    submittedMeters: 1,
    routeMeters: 1,
  );
  return [
    for (final edge in trace.edges)
      if (edge.use == 'track')
        _halfWayAlong(
          shape.sublist(edge.beginShapeIndex, edge.endShapeIndex + 1),
        ),
  ];
}

GeoPoint _halfWayAlong(List<GeoPoint> line) {
  double length(int from) => routeDistanceMeters(line[from], line[from + 1]);
  final total = [
    for (var i = 0; i < line.length - 1; i += 1) length(i),
  ].fold<double>(0, (sum, value) => sum + value);
  var remaining = total / 2;
  for (var i = 0; i < line.length - 1; i += 1) {
    final segment = length(i);
    if (remaining <= segment) {
      final fraction = segment == 0 ? 0.0 : remaining / segment;
      return GeoPoint(
        latitude:
            line[i].latitude +
            (line[i + 1].latitude - line[i].latitude) * fraction,
        longitude:
            line[i].longitude +
            (line[i + 1].longitude - line[i].longitude) * fraction,
      );
    }
    remaining -= segment;
  }
  return line.last;
}
