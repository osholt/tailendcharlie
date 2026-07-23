import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/services/road_routing.dart';
import 'package:ride_relay/services/route_geometry_enricher.dart';

void main() {
  test('OSRM client requests and parses full road geometry', () async {
    final client = MockClient((request) async {
      expect(request.url.path, contains('/route/v1/driving/'));
      expect(request.url.queryParameters['geometries'], 'geojson');
      expect(request.url.queryParameters['overview'], 'full');
      expect(request.url.queryParameters['steps'], 'true');
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
                      'maneuver': {
                        'type': 'turn',
                        'modifier': 'left',
                        'location': [-2.386091, 51.452344],
                      },
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
    expect(result.maneuvers.last.requiresSecondBikeDrop, isFalse);
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
}

class _FakeRoadRoutingService implements RoadRoutingService {
  final List<List<GeoPoint>> requests = [];

  @override
  Future<RoadRouteResult> routeThrough(List<GeoPoint> waypoints) async {
    requests.add(waypoints);
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
  Future<RoadRouteResult> routeThrough(List<GeoPoint> waypoints) {
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
