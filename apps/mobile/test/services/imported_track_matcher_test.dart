import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/services/imported_track_matcher.dart';

void main() {
  test('matches an imported track and returns review evidence', () async {
    late Uri requestedUri;
    final matcher = OsrmImportedTrackMatcher(
      client: MockClient((request) async {
        requestedUri = request.url;
        expect(request.headers['User-Agent'], contains('TailEndCharlie'));
        return http.Response(jsonEncode(_matchResponse()), 200);
      }),
      baseUrl: Uri.parse('https://routing.example.test/prefix'),
    );

    final result = await matcher.match(_track());

    expect(requestedUri.path, contains('/prefix/match/v1/driving/'));
    expect(requestedUri.queryParameters['steps'], 'true');
    expect(requestedUri.queryParameters['geometries'], 'geojson');
    expect(requestedUri.queryParameters['overview'], 'full');
    expect(requestedUri.queryParameters['gaps'], 'split');
    expect(requestedUri.queryParameters['tidy'], 'true');
    expect(requestedUri.queryParameters['waypoints'], '0;2');
    expect(result.route.id, isNot('source-track'));
    expect(result.route.name, 'Imported run (navigable)');
    expect(result.route.sourceFileName, 'matched-run.gpx');
    expect(result.route.paths.single.kind, RoutePathKind.track);
    expect(result.route.paths.single.points, hasLength(3));
    expect(result.route.maneuvers, hasLength(1));
    expect(result.route.maneuvers.single.type, 'turn');
    expect(result.route.waypoints.single.name, 'Start');
    expect(result.confidence, 0.94);
    expect(result.traceCoverage, 1);
    expect(result.meanDeviationMeters, lessThan(2));
    expect(result.maximumDeviationMeters, lessThan(2));
    expect(result.reviewWarnings.join(' '), contains('94% confidence'));
    expect(result.reviewWarnings.join(' '), contains('shown in grey'));
  });

  test('rejects a low-confidence match', () async {
    final matcher = _matcher(_matchResponse(confidence: 0.4));

    await expectLater(
      matcher.match(_track()),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('not confident enough'),
        ),
      ),
    );
  });

  test('rejects a match with missing tracepoints', () async {
    final matcher = _matcher(
      _matchResponse(tracepoints: [const <String, Object?>{}, null, null]),
    );

    await expectLater(
      matcher.match(_track()),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('Too little'),
        ),
      ),
    );
  });

  test('rejects a match split into separate routes', () async {
    final response = _matchResponse();
    response['matchings'] = [
      ...(response['matchings']! as List),
      (response['matchings']! as List).single,
    ];
    final matcher = _matcher(response);

    await expectLater(
      matcher.match(_track()),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('split into separate routes'),
        ),
      ),
    );
  });

  test('rejects geometry that moves too far from the imported line', () async {
    final matcher = _matcher(
      _matchResponse(
        coordinates: const [
          [-2.1, 51.1],
          [-2.1005, 51.1005],
          [-2.101, 51.101],
        ],
      ),
    );

    await expectLater(
      matcher.match(_track()),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('moved too far'),
        ),
      ),
    );
  });

  test('ignores a one-fix fragment beside a drawable recorded track', () async {
    var requests = 0;
    final matcher = OsrmImportedTrackMatcher(
      client: MockClient((_) async {
        requests += 1;
        return http.Response(jsonEncode(_matchResponse()), 200);
      }),
      baseUrl: Uri.parse('https://routing.example.test'),
    );
    final main = _track();
    final result = await matcher.match(
      ImportedRoute(
        id: main.id,
        name: main.name,
        importedAt: main.importedAt,
        sourceFileName: main.sourceFileName,
        paths: [
          const RoutePath(
            kind: RoutePathKind.track,
            points: [GeoPoint(latitude: 51.002, longitude: -2.002)],
          ),
          ...main.paths,
        ],
        waypoints: main.waypoints,
      ),
    );

    expect(requests, 1);
    expect(result.route.paths, hasLength(1));
    expect(result.traceCoverage, 1);
  });
}

OsrmImportedTrackMatcher _matcher(Map<String, Object?> response) =>
    OsrmImportedTrackMatcher(
      client: MockClient((_) async => http.Response(jsonEncode(response), 200)),
      baseUrl: Uri.parse('https://routing.example.test'),
    );

ImportedRoute _track() => ImportedRoute(
  id: 'source-track',
  name: 'Imported run',
  description: 'Keep this exact line.',
  importedAt: DateTime.utc(2026, 8, 3),
  sourceFileName: 'run.gpx',
  paths: const [
    RoutePath(
      kind: RoutePathKind.track,
      points: [
        GeoPoint(latitude: 51, longitude: -2),
        GeoPoint(latitude: 51.0005, longitude: -2.0005),
        GeoPoint(latitude: 51.001, longitude: -2.001),
      ],
    ),
  ],
  waypoints: const [
    RouteWaypoint(point: GeoPoint(latitude: 51, longitude: -2), name: 'Start'),
  ],
);

Map<String, Object?> _matchResponse({
  double confidence = 0.94,
  List<Object?>? tracepoints,
  List<List<double>> coordinates = const [
    [-2, 51],
    [-2.0005, 51.0005],
    [-2.001, 51.001],
  ],
}) => {
  'code': 'Ok',
  'tracepoints':
      tracepoints ??
      [
        const <String, Object?>{'matchings_index': 0},
        const <String, Object?>{'matchings_index': 0},
        const <String, Object?>{'matchings_index': 0},
      ],
  'matchings': [
    {
      'confidence': confidence,
      'distance': 140.0,
      'duration': 30.0,
      'geometry': {'coordinates': coordinates},
      'legs': [
        {
          'steps': [
            {
              'name': 'High Street',
              'driving_side': 'left',
              'maneuver': {
                'type': 'turn',
                'modifier': 'left',
                'location': coordinates[1],
              },
            },
          ],
        },
      ],
    },
  ],
};
