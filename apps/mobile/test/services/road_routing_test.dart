import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/services/road_routing.dart';
import 'package:ride_relay/services/route_geometry_enricher.dart';

import 'osrm_maneuver_fixtures.dart';

void main() {
  // The mini-roundabout layer is a bundled asset.
  TestWidgetsFlutterBinding.ensureInitialized();
  test('OSRM client requests and parses full road geometry', () async {
    final client = MockClient((request) async {
      expect(request.url.path, contains('/route/v1/driving/'));
      expect(request.url.queryParameters['geometries'], 'geojson');
      expect(request.url.queryParameters['overview'], 'full');
      expect(request.url.queryParameters['steps'], 'true');
      expect(request.url.queryParameters['bearings'], isNull);
      expect(request.headers['User-Agent'], contains('TailEndCharlie'));
      return http.Response(
        jsonEncode({
          'code': 'Ok',
          'routes': [
            {
              'distance': 1250.5,
              'duration': 92.4,
              'geometry': {
                'coordinates': [
                  [-1.0, 53.0],
                  [-1.005, 53.005],
                  [-1.01, 53.01],
                ],
              },
              'legs': [
                {
                  'steps': [
                    {
                      'name': 'Gorse Lane',
                      'driving_side': 'left',
                      'maneuver': {
                        'type': 'roundabout',
                        'modifier': 'right',
                        'exit': 3,
                        'location': [-2.386091, 51.452344],
                      },
                      'intersections': [
                        {
                          'lanes': [
                            {
                              'indications': ['left'],
                              'valid': false,
                            },
                            {
                              'indications': ['straight', 'right'],
                              'valid': true,
                            },
                          ],
                        },
                      ],
                    },
                    {
                      'name': 'London Road',
                      'maneuver': {
                        'type': 'new name',
                        'location': [-2.35, 51.5],
                      },
                    },
                  ],
                },
              ],
            },
          ],
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final service = OsrmRoadRoutingService(
      client: client,
      baseUrl: Uri.parse('https://routing.example.test'),
    );

    final result = await service.routeThrough(const [
      GeoPoint(latitude: 53, longitude: -1),
      GeoPoint(latitude: 53.01, longitude: -1.01),
    ]);

    expect(result.points, hasLength(3));
    expect(result.distanceMeters, 1250.5);
    expect(result.duration, const Duration(milliseconds: 92400));
    expect(result.maneuvers, hasLength(2));
    expect(result.maneuvers.first.requiresSecondBikeDrop, isTrue);
    expect(result.maneuvers.first.name, 'Gorse Lane');
    expect(result.maneuvers.first.exitNumber, 3);
    expect(result.maneuvers.first.drivingSide, 'left');
    expect(result.maneuvers.first.lanes, hasLength(2));
    expect(result.maneuvers.first.lanes.first.valid, isFalse);
    expect(result.maneuvers.first.lanes.last.indications, [
      'straight',
      'right',
    ]);
    expect(result.maneuvers.last.requiresSecondBikeDrop, isFalse);
  });

  test('OSRM constrains only the moving reroute origin bearing', () async {
    final client = MockClient((request) async {
      // OSRM requires one bearings element per coordinate; empty elements keep
      // the normal snap at later rejoin waypoints.
      expect(request.url.queryParameters['bearings'], '91,60;;');
      return http.Response(_osrmResponse(), 200);
    });
    final service = OsrmRoadRoutingService(
      client: client,
      baseUrl: Uri.parse('https://routing.example.test'),
    );

    await service.routeThrough(const [
      GeoPoint(latitude: 53, longitude: -1),
      GeoPoint(latitude: 53.01, longitude: -1.01),
      GeoPoint(latitude: 53.02, longitude: -1.02),
    ], originBearingDegrees: 90.6);
  });

  test('roundabout steps keep their bearings, exit count and lanes', () async {
    final route = await routeFromOsrmResponse(ukRoundaboutStraightOnResponse());

    final entry = route.maneuvers[1];
    final exit = route.maneuvers[2];

    expect(entry.type, 'roundabout');
    expect(entry.exitNumber, 2);
    expect(entry.modifier, 'slight left');
    expect(entry.bearingBeforeDegrees, 1);
    expect(entry.bearingAfterDegrees, 315);
    expect(entry.drivingSide, 'left');
    expect(entry.lanes.map((lane) => lane.valid), [false, true, false]);
    expect(exit.type, 'exit roundabout');
    expect(exit.bearingAfterDegrees, 2);
  });

  test(
    'a junction the engine omits is restored from the bundled layer',
    () async {
      // The captured response is a real OSRM answer that genuinely omits two
      // mapped mini-roundabouts (#163). It used to be fixed by a hand-reviewed
      // catalogue holding those two junctions and their hand-measured arms;
      // this asserts the general OpenStreetMap layer covers them instead.
      final catalogue = await MappedMiniRoundaboutCatalogue.load();
      final response = newCheltenhamRoadOmittedRoundaboutsResponse();
      final rawLocations =
          (((response['routes'] as List).single as Map)['legs'] as List)
              .expand((leg) => ((leg as Map)['steps'] as List).whereType<Map>())
              .map((step) => (step['maneuver'] as Map)['location'])
              .toList(growable: false);
      expect(
        rawLocations,
        isNot(contains(equals([-2.5010632, 51.4672133]))),
        reason: 'the captured engine response genuinely omits the west node',
      );
      expect(
        rawLocations,
        isNot(contains(equals([-2.5005026, 51.4670501]))),
        reason: 'the captured engine response genuinely omits the east node',
      );

      final route = await routeFromOsrmResponse(
        response,
        id: 'issue-163',
        readMiniRoundabouts: () async => catalogue,
      );
      final restored = route.maneuvers
          .where(
            (maneuver) =>
                maneuver.type == 'roundabout' &&
                (maneuver.position.longitude - -2.5010632).abs() < 0.0005,
          )
          .toList(growable: false);

      expect(restored, hasLength(1));
      // No exit number is claimed. Counting exits needs every arm's bearing,
      // which this layer does not carry - the catalogue it replaced carried
      // them for two junctions by hand and for nowhere else.
      expect(restored.single.exitNumber, isNull);
      // Stated because OpenStreetMap states it for this node, not assumed.
      expect(restored.single.drivingSide, 'left');
      expect(restored.single.bearingBeforeDegrees, isNotNull);
    },
  );

  test(
    'the bundled layer is general, not a list of reported junctions',
    () async {
      final catalogue = await MappedMiniRoundaboutCatalogue.load();

      // The point of the change: coverage is whatever OpenStreetMap maps, so a
      // junction nobody has reported is served exactly as well as one that has.
      expect(catalogue.roundabouts.length, greaterThan(10000));
      expect(
        catalogue.roundabouts.where(
          (roundabout) =>
              roundabout.rotation == MiniRoundaboutRotation.clockwise,
        ),
        isNotEmpty,
      );
    },
  );

  test('restoration is bounded and never duplicates an engine step', () {
    // Arbitrary coordinates: the rule is what is under test, not a place.
    const node = GeoPoint(latitude: 53.1000, longitude: -1.5000);
    const catalogue = MappedMiniRoundaboutCatalogue([
      MappedMiniRoundabout(
        position: node,
        rotation: MiniRoundaboutRotation.clockwise,
      ),
    ]);

    const wellAway = [
      GeoPoint(latitude: 53.2000, longitude: -1.6000),
      GeoPoint(latitude: 53.2000, longitude: -1.5000),
    ];
    expect(
      catalogue.enrich(route: wellAway, maneuvers: const []),
      isEmpty,
      reason: 'ordinary route geometry is not inferred to be a roundabout',
    );

    const throughNode = [
      GeoPoint(latitude: 53.1010, longitude: -1.5010),
      node,
      GeoPoint(latitude: 53.0990, longitude: -1.4990),
    ];
    const engineManeuvers = [
      RoadRouteManeuver(position: node, type: 'roundabout', exitNumber: 2),
      RoadRouteManeuver(position: node, type: 'exit roundabout'),
    ];
    expect(
      catalogue.enrich(route: throughNode, maneuvers: engineManeuvers),
      same(engineManeuvers),
      reason: 'a future provider fix must not create duplicate instructions',
    );

    final restored = catalogue.enrich(route: throughNode, maneuvers: const []);
    expect(restored.map((maneuver) => maneuver.type), [
      'roundabout',
      'exit roundabout',
    ]);
    expect(restored.first.exitNumber, isNull);
  });

  test('a small roundabout reported as a turn still needs a marker', () {
    expect(
      const RoadRouteManeuver(
        position: GeoPoint(latitude: 51.46, longitude: -2.59),
        type: 'roundabout turn',
        modifier: 'left',
      ).requiresSecondBikeDrop,
      isTrue,
    );
  });

  test(
    'destination search supports coordinates and one-shot place search',
    () async {
      var requests = 0;
      final service = NominatimDestinationSearchService(
        client: MockClient((request) async {
          requests += 1;
          expect(request.url.queryParameters['q'], 'Matlock Bath');
          expect(request.url.queryParameters['limit'], '5');
          return http.Response(
            jsonEncode([
              {
                'lat': '53.121',
                'lon': '-1.562',
                'display_name': 'Matlock Bath, Derbyshire, United Kingdom',
              },
            ]),
            200,
          );
        }),
        baseUrl: Uri.parse('https://geocoding.example.test'),
      );

      final coordinateMatch = await service.search('53.12, -1.56');
      final placeMatch = await service.search('Matlock Bath');

      expect(coordinateMatch.single.point.latitude, 53.12);
      expect(placeMatch.single.label, startsWith('Matlock Bath'));
      expect(requests, 1);
    },
  );

  test(
    'sparse GPX route points are replaced with road track geometry',
    () async {
      final routing = _FakeRoadRoutingService();
      final route = ImportedRoute(
        id: 'route',
        name: 'Sparse route',
        importedAt: DateTime.utc(2026),
        sourceFileName: 'sparse.gpx',
        paths: const [
          RoutePath(
            kind: RoutePathKind.track,
            name: 'Recorded section',
            points: [
              GeoPoint(latitude: 52.9, longitude: -1),
              GeoPoint(latitude: 52.91, longitude: -1.01),
            ],
          ),
          RoutePath(
            kind: RoutePathKind.route,
            name: 'Planned section',
            points: [
              GeoPoint(latitude: 53, longitude: -1),
              GeoPoint(latitude: 53.1, longitude: -1.1),
            ],
          ),
        ],
        waypoints: const [],
      );

      final result = await RouteGeometryEnricher(
        routingService: routing,
      ).enrich(route);

      expect(result.changed, isTrue);
      expect(result.snappedPathCount, 1);
      expect(result.route.paths.first.kind, RoutePathKind.track);
      expect(result.route.paths.last.kind, RoutePathKind.track);
      expect(result.route.paths.last.points, hasLength(3));
      expect(result.route.maneuvers.single.name, 'High Street');
      expect(routing.requests.single, hasLength(2));
    },
  );

  test('destination plan geocodes an explicit start location instead of '
      'requiring the current position', () async {
    final search = NominatimDestinationSearchService(
      client: MockClient((request) async {
        final query = request.url.queryParameters['q'];
        final point = query == 'Matlock Bath'
            ? {'lat': '53.121', 'lon': '-1.562'}
            : {'lat': '52.0', 'lon': '-1.9'};
        return http.Response(
          jsonEncode([
            {...point, 'display_name': '$query, United Kingdom'},
          ]),
          200,
        );
      }),
      baseUrl: Uri.parse('https://geocoding.example.test'),
    );
    final routing = _FakeRoadRoutingService();
    final planner = DestinationRoutePlanner(
      searchService: search,
      routingService: routing,
    );

    final route = await planner.plan(
      originQuery: 'Bakewell',
      query: 'Matlock Bath',
    );

    expect(route.waypoints.first.point.latitude, 52.0);
    expect(routing.requests.single.first.latitude, 52.0);
    expect(route.maneuvers.single.name, 'High Street');
  });

  test(
    'destination plan requires either a current position or a start query',
    () async {
      final planner = DestinationRoutePlanner(
        searchService: NominatimDestinationSearchService(
          client: MockClient((_) async => http.Response('[]', 200)),
          baseUrl: Uri.parse('https://geocoding.example.test'),
        ),
        routingService: _FakeRoadRoutingService(),
      );

      await expectLater(
        planner.plan(query: 'Matlock Bath'),
        throwsA(isA<FormatException>()),
      );
    },
  );

  test(
    'destination review preserves ordered stops and reports ambiguity',
    () async {
      final search = _FakeDestinationSearchService({
        'Start': const [
          DestinationMatch(
            label: 'Start one',
            point: GeoPoint(latitude: 53, longitude: -1),
          ),
        ],
        'Stop': const [
          DestinationMatch(
            label: 'Stop one',
            point: GeoPoint(latitude: 53.1, longitude: -1.1),
          ),
          DestinationMatch(
            label: 'Stop two',
            point: GeoPoint(latitude: 54, longitude: -2),
          ),
        ],
        'Finish': const [
          DestinationMatch(
            label: 'Finish one',
            point: GeoPoint(latitude: 53.2, longitude: -1.2),
          ),
        ],
      });
      final routing = _FakeRoadRoutingService();
      final planner = DestinationRoutePlanner(
        searchService: search,
        routingService: routing,
      );

      final plan = await planner.planForReview(
        originQuery: 'Start',
        stopQueries: const ['Stop'],
        query: 'Finish',
      );

      expect(plan.route.waypoints, hasLength(3));
      expect(plan.route.waypoints[1].name, 'Stop one');
      expect(routing.requests.single[1].latitude, 53.1);
      expect(plan.warnings.single, contains('Stop 1 had 2 possible matches'));
    },
  );

  test('destination review keeps the exact submitted search result', () async {
    const selected = DestinationMatch(
      label: 'Chippenham, Wiltshire',
      point: GeoPoint(latitude: 51.46, longitude: -2.12),
    );
    final routing = _FakeRoadRoutingService();
    final planner = DestinationRoutePlanner(
      // A repeated text search would pick the wrong same-named place. The
      // CarPlay row carries its coordinates so selection remains exact.
      searchService: const _FakeDestinationSearchService({
        'Chippenham, Wiltshire': [
          DestinationMatch(
            label: 'Chippenham, Cambridgeshire',
            point: GeoPoint(latitude: 52.2, longitude: 0.1),
          ),
        ],
      }),
      routingService: routing,
    );

    final plan = await planner.planForReview(
      origin: const GeoPoint(latitude: 51.45, longitude: -2.58),
      query: selected.label,
      selectedDestination: selected,
    );

    expect(routing.requests.single.last.latitude, 51.46);
    expect(routing.requests.single.last.longitude, -2.12);
    expect(plan.route.name, 'To Chippenham');
    expect(plan.warnings, isEmpty);
  });

  test('routing failure preserves the original sparse GPX route', () async {
    final route = ImportedRoute(
      id: 'route',
      name: 'Offline route',
      importedAt: DateTime.utc(2026),
      sourceFileName: 'offline.gpx',
      paths: const [
        RoutePath(
          kind: RoutePathKind.route,
          points: [
            GeoPoint(latitude: 53, longitude: -1),
            GeoPoint(latitude: 53.1, longitude: -1.1),
          ],
        ),
      ],
      waypoints: const [],
    );

    final result = await RouteGeometryEnricher(
      routingService: _FailingRoadRoutingService(),
    ).enrich(route);

    expect(result.changed, isFalse);
    expect(result.route, same(route));
    expect(result.warning, contains('Could not match'));
  });

  group('route preferences reach the provider (#182)', () {
    test('the quickest style asks for no alternatives', () async {
      Uri? requested;
      final service = OsrmRoadRoutingService(
        client: MockClient((request) async {
          requested = request.url;
          return http.Response(_osrmResponse(), 200);
        }),
        baseUrl: Uri.parse('https://routing.example.test'),
      );

      final result = await service.routeThrough(
        _twoPoints,
        preferences: RoutePreferences.defaults,
      );

      expect(requested!.queryParameters.containsKey('alternatives'), isFalse);
      expect(result.preferences, RoutePreferences.defaults);
      expect(result.twistinessScore, isNotNull);
    });

    test('a bendier style asks OSRM for three alternatives and picks the '
        'bendiest inside the allowance', () async {
      Uri? requested;
      final service = OsrmRoadRoutingService(
        client: MockClient((request) async {
          requested = request.url;
          return http.Response(_osrmAlternativesResponse(), 200);
        }),
        baseUrl: Uri.parse('https://routing.example.test'),
      );

      final flowing = await service.routeThrough(
        _twoPoints,
        preferences: const RoutePreferences(style: RouteStyle.flowing),
      );
      final veryTwisty = await service.routeThrough(
        _twoPoints,
        preferences: const RoutePreferences(style: RouteStyle.veryTwisty),
      );

      expect(requested!.queryParameters['alternatives'], '3');
      // Quickest is 1000 s. Flowing allows 1250 s, so only the 1200 s
      // alternative qualifies; very twisty allows 1750 s and reaches the
      // bendiest 1700 s one.
      expect(flowing.duration, const Duration(seconds: 1200));
      expect(veryTwisty.duration, const Duration(seconds: 1700));
      expect(veryTwisty.twistinessScore, greaterThan(flowing.twistinessScore!));
    });

    test('avoiding motorways sends the documented motorcycle costing to '
        'Valhalla', () async {
      Map<String, Object?>? costing;
      final service = ValhallaMotorcycleRoutingService(
        client: MockClient((request) async {
          final json = jsonDecode(request.url.queryParameters['json']!) as Map;
          costing = Map<String, Object?>.from(
            (json['costing_options'] as Map)['motorcycle'] as Map,
          );
          expect(json['costing'], 'motorcycle');
          expect(json['units'], 'kilometers');
          expect((json['locations'] as List), hasLength(2));
          return http.Response(_valhallaResponse(), 200);
        }),
        routeUrl: Uri.parse('https://valhalla.example.test/route'),
      );

      final result = await service.routeThrough(
        _twoPoints,
        preferences: const RoutePreferences(
          style: RouteStyle.twisty,
          avoidMotorways: true,
        ),
      );

      expect(costing, {
        'use_highways': 0.35,
        'use_tolls': 0.5,
        'use_ferry': 0.5,
        'use_trails': 0,
        'exclude_highways': true,
        'exclude_tolls': false,
        'exclude_ferries': false,
        'exclude_unpaved': true,
      });
      expect(result.points, hasLength(3));
      expect(result.points.last.latitude, closeTo(53.01, 1e-9));
      expect(result.points.last.longitude, closeTo(-1.01, 1e-9));
      expect(result.distanceMeters, 12500);
      expect(result.duration, const Duration(seconds: 900));
      // This response carries no manoeuvres of its own, and none are invented
      // for it. What changed in #303 is that a response which *does* carry them
      // no longer has them discarded — see the group below.
      expect(result.maneuvers, isEmpty);
    });

    group('the motorcycle router keeps its turn instructions (#303)', () {
      // `maneuvers: const []`. Every route planned with a motorcycle
      // preference — avoid motorways, prefer twisty roads (#182) — arrived with
      // no turn instructions at all, so whether a rider got guidance depended
      // on whether they had set a preference. "Sometimes the navigation worked
      // well and sometimes it didn't."

      /// Fifty metres north, then east: an approach road, a junction at index
      /// 5, and an exit road, at roughly 10 m spacing.
      List<GeoPoint> lRoute() => [
        for (var i = 0; i <= 5; i += 1)
          GeoPoint(latitude: 53 + i * 0.00009, longitude: -1),
        for (var i = 1; i <= 5; i += 1)
          GeoPoint(latitude: 53 + 5 * 0.00009, longitude: -1 + i * 0.000148),
      ];

      test('an ordinary turn keeps its direction and its road name', () {
        final maneuvers = ValhallaMotorcycleRoutingService.parseManeuvers(
          route: lRoute(),
          legShapeOffsets: const [0],
          legManeuvers: const [
            [
              {'type': 1, 'begin_shape_index': 0},
              {
                'type': 10,
                'begin_shape_index': 5,
                'street_names': ['Bath Road'],
              },
              {'type': 4, 'begin_shape_index': 10},
            ],
          ],
        );

        expect(maneuvers.map((m) => m.type), ['depart', 'turn', 'arrive']);
        expect(maneuvers[1].modifier, 'right');
        expect(maneuvers[1].name, 'Bath Road');
        expect(maneuvers[1].position.latitude, closeTo(53.00045, 1e-9));
      });

      test('every turn severity maps to the vocabulary the app speaks', () {
        // These strings are the OSRM vocabulary `navigation_guidance.dart`
        // already parses, so both engines converge before anything downstream
        // sees them. A mapping that drifted would silently produce `unstated`
        // and the rider would be told a junction is coming with no direction.
        const expected = <int, String>{
          9: 'slight right',
          10: 'right',
          11: 'sharp right',
          14: 'sharp left',
          15: 'left',
          16: 'slight left',
          12: 'uturn',
          13: 'uturn',
        };

        final maneuvers = ValhallaMotorcycleRoutingService.parseManeuvers(
          route: lRoute(),
          legShapeOffsets: const [0],
          legManeuvers: [
            [
              for (final type in expected.keys)
                {'type': type, 'begin_shape_index': 5},
            ],
          ],
        );

        expect(
          maneuvers.map((m) => m.modifier).toList(),
          expected.values.toList(),
        );
        expect(maneuvers.every((m) => m.type == 'turn'), isTrue);
      });

      test('a roundabout keeps its exit count and gets usable bearings', () {
        // Neither of a roundabout's own modifiers describes the direction
        // through the junction, so the instruction is derived from the heading
        // on the way in against the heading on the way out. Those are the only
        // manoeuvres given bearings.
        final maneuvers = ValhallaMotorcycleRoutingService.parseManeuvers(
          route: lRoute(),
          legShapeOffsets: const [0],
          legManeuvers: const [
            [
              {'type': 26, 'begin_shape_index': 5, 'roundabout_exit_count': 3},
              {
                'type': 27,
                'begin_shape_index': 6,
                'street_names': ['Bridgeyate Road'],
              },
            ],
          ],
        );

        expect(maneuvers[0].type, 'roundabout');
        expect(maneuvers[0].exitNumber, 3);
        expect(
          maneuvers[0].bearingBeforeDegrees,
          closeTo(0, 1),
          reason: 'the approach road runs due north',
        );
        expect(maneuvers[1].type, 'exit roundabout');
        expect(
          maneuvers[1].bearingAfterDegrees,
          closeTo(90, 1),
          reason: 'the exit road runs due east',
        );
        expect(
          maneuvers[1].exitNumber,
          isNull,
          reason: 'the count belongs to the manoeuvre that enters the ring',
        );
      });

      test('a second leg indexes into the joined line, not its own', () {
        // Each leg's shape repeats the previous leg's last point, so a leg's
        // own index is not the combined one. Getting this wrong would place
        // every manoeuvre after the first stop at the wrong junction.
        final route = lRoute();
        final maneuvers = ValhallaMotorcycleRoutingService.parseManeuvers(
          route: route,
          legShapeOffsets: const [0, 5],
          legManeuvers: const [
            [
              {'type': 10, 'begin_shape_index': 2},
            ],
            [
              {'type': 15, 'begin_shape_index': 2},
            ],
          ],
        );

        expect(maneuvers[0].position, route[2]);
        expect(maneuvers[1].position, route[7]);
      });

      test('a manoeuvre the app cannot act on is left out, not guessed at', () {
        // Ferries, transit and building entrances. Inventing a direction for
        // one would be worse than omitting it.
        final maneuvers = ValhallaMotorcycleRoutingService.parseManeuvers(
          route: lRoute(),
          legShapeOffsets: const [0],
          legManeuvers: const [
            [
              {'type': 28, 'begin_shape_index': 1},
              {'type': 30, 'begin_shape_index': 2},
              {'type': 10, 'begin_shape_index': 5},
              {'type': 999, 'begin_shape_index': 6},
            ],
          ],
        );

        expect(maneuvers, hasLength(1));
        expect(maneuvers.single.modifier, 'right');
      });

      test(
        'a routed response reaches the caller with its manoeuvres',
        () async {
          final service = ValhallaMotorcycleRoutingService(
            client: MockClient(
              (_) async => http.Response(
                _valhallaResponse(
                  maneuvers: const [
                    {'type': 1, 'begin_shape_index': 0},
                    {
                      'type': 11,
                      'begin_shape_index': 1,
                      'street_names': ['Cloud Hill'],
                    },
                    {'type': 4, 'begin_shape_index': 2},
                  ],
                ),
                200,
              ),
            ),
            routeUrl: Uri.parse('https://valhalla.example.test/route'),
          );

          final result = await service.routeThrough(
            _twoPoints,
            preferences: const RoutePreferences(avoidMotorways: true),
          );

          expect(result.maneuvers, hasLength(3));
          expect(result.maneuvers[1].modifier, 'sharp right');
          expect(result.maneuvers[1].name, 'Cloud Hill');
        },
      );
    });

    test('allowing unsurfaced byways relaxes both surface levers', () async {
      Map<String, Object?>? costing;
      final service = ValhallaMotorcycleRoutingService(
        client: MockClient((request) async {
          costing = Map<String, Object?>.from(
            ((jsonDecode(request.url.queryParameters['json']!)
                        as Map)['costing_options']
                    as Map)['motorcycle']
                as Map,
          );
          return http.Response(_valhallaResponse(), 200);
        }),
        routeUrl: Uri.parse('https://valhalla.example.test/route'),
      );

      await service.routeThrough(
        _twoPoints,
        preferences: const RoutePreferences(
          bywaySurface: BywaySurfacePreference.allowUnsurfaced,
        ),
      );

      expect(costing!['use_trails'], 0.5);
      expect(costing!['exclude_unpaved'], isFalse);
    });

    test('the dispatcher chooses the engine the preferences need', () async {
      final osrm = _FakeRoadRoutingService();
      final motorcycle = _FakeRoadRoutingService();
      final dispatcher = PreferenceAwareRoadRoutingService(
        osrm: osrm,
        motorcycle: motorcycle,
      );

      await dispatcher.routeThrough(_twoPoints);
      await dispatcher.routeThrough(
        _twoPoints,
        preferences: RoutePreferences.defaults,
      );
      await dispatcher.routeThrough(
        _twoPoints,
        preferences: const RoutePreferences(style: RouteStyle.veryTwisty),
      );
      await dispatcher.routeThrough(
        _twoPoints,
        preferences: const RoutePreferences(avoidMotorways: true),
      );
      await dispatcher.routeThrough(
        _twoPoints,
        preferences: const RoutePreferences(
          bywaySurface: BywaySurfacePreference.allowUnsurfaced,
        ),
      );

      expect(
        osrm.requests,
        hasLength(3),
        reason: 'no preference, the defaults, and a style-only change',
      );
      expect(
        motorcycle.requests,
        hasLength(2),
        reason: 'a hard exclusion, and seeking byways',
      );
    });

    test('a planned route carries its preferences and warns when turn '
        'instructions are unavailable', () async {
      final plan =
          await DestinationRoutePlanner(
            searchService: const _FakeDestinationSearchService({
              'Start': [
                DestinationMatch(
                  label: 'Start',
                  point: GeoPoint(latitude: 53, longitude: -1),
                ),
              ],
              'Finish': [
                DestinationMatch(
                  label: 'Finish',
                  point: GeoPoint(latitude: 53.2, longitude: -1.2),
                ),
              ],
            }),
            routingService: PreferenceAwareRoadRoutingService(
              osrm: _FakeRoadRoutingService(),
              motorcycle: _ManeuverlessRoadRoutingService(),
            ),
          ).planForReview(
            originQuery: 'Start',
            query: 'Finish',
            preferences: const RoutePreferences(
              style: RouteStyle.twisty,
              avoidMotorways: true,
            ),
          );

      expect(
        plan.route.preferences,
        const RoutePreferences(style: RouteStyle.twisty, avoidMotorways: true),
      );
      expect(plan.route.description, contains('motorways excluded'));
      expect(plan.route.description, contains('unsurfaced byways avoided'));
      expect(plan.route.plannedDuration, plan.duration);
      expect(
        plan.warnings,
        contains(PreferenceAwareRoadRoutingService.motorcycleManeuverWarning),
      );
    });

    test('a preference-routed plan that has turn instructions is not warned '
        'about (#303)', () async {
      // The warning used to be raised on the engine, so every preference-routed
      // plan carried it whether or not it had turns — which is precisely how a
      // real absence of turn guidance stayed invisible. It is now raised on
      // what came back.
      final plan =
          await DestinationRoutePlanner(
            searchService: const _FakeDestinationSearchService({
              'Start': [
                DestinationMatch(
                  label: 'Start',
                  point: GeoPoint(latitude: 53, longitude: -1),
                ),
              ],
              'Finish': [
                DestinationMatch(
                  label: 'Finish',
                  point: GeoPoint(latitude: 53.2, longitude: -1.2),
                ),
              ],
            }),
            routingService: PreferenceAwareRoadRoutingService(
              osrm: _FakeRoadRoutingService(),
              // The same motorcycle engine, now returning what Valhalla
              // actually sends.
              motorcycle: _FakeRoadRoutingService(),
            ),
          ).planForReview(
            originQuery: 'Start',
            query: 'Finish',
            preferences: const RoutePreferences(avoidMotorways: true),
          );

      expect(plan.route.maneuvers, isNotEmpty);
      expect(
        plan.warnings,
        isNot(
          contains(PreferenceAwareRoadRoutingService.motorcycleManeuverWarning),
        ),
      );
    });

    test('re-snapping a shared route reuses its own preferences', () async {
      final routing = _FakeRoadRoutingService();
      final route = ImportedRoute(
        id: 'shared',
        name: 'Shared twisty route',
        importedAt: DateTime.utc(2026),
        sourceFileName: 'shared.gpx',
        paths: const [
          RoutePath(
            kind: RoutePathKind.route,
            points: [
              GeoPoint(latitude: 53, longitude: -1),
              GeoPoint(latitude: 53.1, longitude: -1.1),
            ],
          ),
        ],
        waypoints: const [],
        preferences: const RoutePreferences(
          style: RouteStyle.twisty,
          avoidMotorways: true,
        ),
      );

      final result = await RouteGeometryEnricher(
        routingService: routing,
      ).enrich(route);

      expect(routing.requestedPreferences.single, route.preferences);
      expect(result.route.preferences, route.preferences);
    });
  });
}

const _twoPoints = [
  GeoPoint(latitude: 53, longitude: -1),
  GeoPoint(latitude: 53.01, longitude: -1.01),
];

String _osrmResponse() => jsonEncode({
  'code': 'Ok',
  'routes': [
    {
      'distance': 1250.5,
      'duration': 92.4,
      'geometry': {
        'coordinates': [
          [-1.0, 53.0],
          [-1.005, 53.005],
          [-1.01, 53.01],
        ],
      },
    },
  ],
});

/// Three alternatives: straight and quickest first, then a bendier one inside
/// the flowing allowance, then the bendiest and slowest.
String _osrmAlternativesResponse() {
  List<List<double>> sinusoid(double amplitude) => [
    for (var index = 0; index < 40; index += 1)
      [-1.0 + index * 0.004, 53.0 + math.sin(index / 2.5) * amplitude],
  ];
  return jsonEncode({
    'code': 'Ok',
    'routes': [
      {
        'distance': 20000,
        'duration': 1000,
        'geometry': {'coordinates': sinusoid(0)},
      },
      {
        'distance': 22000,
        'duration': 1200,
        'geometry': {'coordinates': sinusoid(0.006)},
      },
      {
        'distance': 26000,
        'duration': 1700,
        'geometry': {'coordinates': sinusoid(0.012)},
      },
    ],
  });
}

String _valhallaResponse({List<Map<String, Object?>>? maneuvers}) =>
    jsonEncode({
      'trip': {
        'legs': [
          // Precision-6 encoded polyline for three points near 53.0, -1.0.
          {'shape': _encodedShape, 'maneuvers': ?maneuvers},
        ],
        'summary': {'length': 12.5, 'time': 900},
      },
    });

/// `(53.0, -1.0), (53.005, -1.005), (53.01, -1.01)` at precision 6.
const _encodedShape = '_szadB~b`|@owHnwHowHnwH';

class _ManeuverlessRoadRoutingService implements RoadRoutingService {
  @override
  Future<RoadRouteResult> routeThrough(
    List<GeoPoint> waypoints, {
    RoutePreferences? preferences,
    double? originBearingDegrees,
  }) async => RoadRouteResult(
    points: const [
      GeoPoint(latitude: 53, longitude: -1),
      GeoPoint(latitude: 53.1, longitude: -1.1),
    ],
    distanceMeters: 12500,
    duration: const Duration(minutes: 15),
    preferences: preferences,
  );
}

class _FakeRoadRoutingService implements RoadRoutingService {
  final List<List<GeoPoint>> requests = [];
  final List<RoutePreferences?> requestedPreferences = [];

  @override
  Future<RoadRouteResult> routeThrough(
    List<GeoPoint> waypoints, {
    RoutePreferences? preferences,
    double? originBearingDegrees,
  }) async {
    requests.add(waypoints);
    requestedPreferences.add(preferences);
    return const RoadRouteResult(
      points: [
        GeoPoint(latitude: 53, longitude: -1),
        GeoPoint(latitude: 53.05, longitude: -1.05),
        GeoPoint(latitude: 53.1, longitude: -1.1),
      ],
      distanceMeters: 10000,
      duration: Duration(minutes: 12),
      maneuvers: [
        RoadRouteManeuver(
          position: GeoPoint(latitude: 53.05, longitude: -1.05),
          type: 'turn',
          modifier: 'left',
          name: 'High Street',
        ),
      ],
    );
  }
}

class _FailingRoadRoutingService implements RoadRoutingService {
  @override
  Future<RoadRouteResult> routeThrough(
    List<GeoPoint> waypoints, {
    RoutePreferences? preferences,
    double? originBearingDegrees,
  }) {
    throw const FormatException('offline');
  }
}

class _FakeDestinationSearchService implements DestinationSearchService {
  const _FakeDestinationSearchService(this.results);

  final Map<String, List<DestinationMatch>> results;

  @override
  Future<List<DestinationMatch>> search(String query) async =>
      results[query] ?? const [];
}
