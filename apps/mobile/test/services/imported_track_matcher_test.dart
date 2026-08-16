import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/services/imported_track_matcher.dart';

/// #575. This suite was written against OSRM's `/match`, which the app can
/// never reach: the configured demo server accepts ten trace coordinates and
/// the app sent ninety, so every import returned `400 TooBig`. Nothing here
/// caught it, because every test supplied a canned response through a fake
/// client and so never met the real limit. The matcher is now Valhalla's
/// `trace_route`, whose limit is 200 km of path rather than a point count, and
/// the chunking that follows from that is the thing most worth testing.
void main() {
  test('matches an imported track and returns review evidence', () async {
    late Uri requestedUri;
    late Map<String, Object?> body;
    final matcher = ValhallaImportedTrackMatcher(
      client: MockClient((request) async {
        requestedUri = request.url;
        body = jsonDecode(request.body) as Map<String, Object?>;
        expect(request.headers['User-Agent'], contains('TailEndCharlie'));
        return http.Response(jsonEncode(_traceResponse()), 200);
      }),
      traceUrl: Uri.parse('https://valhalla.example.test/trace_route'),
    );

    final result = await matcher.match(_track());

    expect(requestedUri.path, '/trace_route');
    expect(body['costing'], 'motorcycle');
    expect(body['shape_match'], 'map_snap');
    expect((body['shape']! as List), hasLength(3));
    expect(result.route.id, isNot('source-track'));
    expect(result.route.name, 'Imported run (navigable)');
    expect(result.route.sourceFileName, 'matched-run.gpx');
    expect(result.route.paths.single.kind, RoutePathKind.track);
    expect(result.route.maneuvers, isNotEmpty);
    expect(result.route.waypoints.single.name, 'Start');
    expect(result.lengthRatio, closeTo(1, 0.2));
    expect(result.meanDeviationMeters, lessThan(35));
    expect(result.reviewWarnings.join(' '), contains('imported length'));
    expect(result.reviewWarnings.join(' '), contains('shown in grey'));
  });

  test('a long track is split by distance, not by a point budget', () {
    // The measured service limit is path distance. A 90-point cap was the old
    // constraint and it was the wrong one: it left 2.8 km between samples.
    final points = _straightTrack(kilometres: 400, spacingMeters: 100);
    final chunks = chunkTrace(
      points,
      maximumMeters: 150000,
      maximumPoints: 5000,
    );

    expect(chunks.length, greaterThan(1));
    for (final chunk in chunks) {
      expect(polylineLengthMeters(chunk), lessThanOrEqualTo(150000));
    }
    // Consecutive chunks share a point, so the matched geometry joins with no
    // gap and no duplicate once the caller skips the repeated head.
    for (var index = 1; index < chunks.length; index += 1) {
      expect(chunks[index].first, chunks[index - 1].last);
    }
    final rejoined = [
      for (final (index, chunk) in chunks.indexed)
        ...index == 0 ? chunk : chunk.skip(1),
    ];
    expect(rejoined, hasLength(points.length));
  });

  test('a short track is one request', () async {
    var requests = 0;
    final matcher = ValhallaImportedTrackMatcher(
      client: MockClient((_) async {
        requests += 1;
        return http.Response(jsonEncode(_traceResponse()), 200);
      }),
      traceUrl: Uri.parse('https://valhalla.example.test/trace_route'),
    );

    await matcher.match(_track());

    expect(requests, 1);
  });

  test('the service says why it refused, and the rider is told', () async {
    // The reported symptom was a bare "Road matching failed (400)". The
    // service's own words are the actionable part.
    final matcher = ValhallaImportedTrackMatcher(
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'error':
                'Path distance exceeds the max distance limit: '
                '200000 meters',
            'error_code': 154,
          }),
          400,
        ),
      ),
      traceUrl: Uri.parse('https://valhalla.example.test/trace_route'),
    );

    await expectLater(
      matcher.match(_track()),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          allOf(contains('max distance limit'), isNot(contains('(400)'))),
        ),
      ),
    );
  });

  test('rejects a match that is not the length of the imported line', () async {
    final matcher = _matcher(_traceResponse(lengthKm: 40));

    await expectLater(
      matcher.match(_track()),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('too far from it to trust'),
        ),
      ),
    );
  });

  test('rejects geometry that moves too far from the imported line', () async {
    final matcher = _matcher(
      _traceResponse(
        shape: const [
          [51.1, -2.1],
          [51.1005, -2.1005],
          [51.101, -2.101],
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

  test('refuses a route with no track to match', () async {
    final matcher = _matcher(_traceResponse());

    await expectLater(
      matcher.match(
        ImportedRoute(
          id: 'no-track',
          name: 'Planned only',
          importedAt: DateTime.utc(2026, 8, 16),
          sourceFileName: 'plan.gpx',
          paths: const [
            RoutePath(
              kind: RoutePathKind.route,
              points: [
                GeoPoint(latitude: 51, longitude: -2),
                GeoPoint(latitude: 51.001, longitude: -2.001),
              ],
            ),
          ],
          waypoints: const [],
        ),
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('does not contain a track'),
        ),
      ),
    );
  });

  test('ignores a one-fix fragment beside a drawable recorded track', () async {
    var requests = 0;
    final matcher = ValhallaImportedTrackMatcher(
      client: MockClient((_) async {
        requests += 1;
        return http.Response(jsonEncode(_traceResponse()), 200);
      }),
      traceUrl: Uri.parse('https://valhalla.example.test/trace_route'),
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
  });

  test('resumes where a truncated match stopped, rather than losing the '
      'rest of the track', () async {
    // The behaviour the live service forced. `map_snap` returns only the part
    // it managed and does not say it stopped early: on the Scenic day run a
    // 150 km window came back as 47.3 km, and the same 47.3 km whether 50, 75
    // or 150 km was sent. Pre-chunking by distance alone silently loses
    // everything past the first such stop in each chunk.
    final track = _straightTrack(kilometres: 30, spacingMeters: 1000);
    final sent = <int>[];
    var call = 0;
    final matcher = ValhallaImportedTrackMatcher(
      client: MockClient((request) async {
        final shape =
            (jsonDecode(request.body) as Map<String, Object?>)['shape']!
                as List;
        sent.add(shape.length);
        // Answer with only the first third of what was asked, as the real
        // service does at a break.
        final answered = [
          for (final point in shape.take(
            math.max(2, (shape.length / 3).ceil()),
          ))
            [
              (point! as Map)['lat']! as double,
              (point as Map)['lon']! as double,
            ],
        ];
        call += 1;
        return http.Response(
          jsonEncode(
            _traceResponse(shape: answered, lengthKm: _polylineKm(answered)),
          ),
          200,
        );
      }),
      traceUrl: Uri.parse('https://valhalla.example.test/trace_route'),
      // Generous, so the split is caused by the truncation and nothing else.
      maximumChunkMeters: 150000,
    );

    final result = await matcher.match(
      ImportedRoute(
        id: 'long',
        name: 'Long run',
        importedAt: DateTime.utc(2026, 8, 16),
        sourceFileName: 'long.gpx',
        paths: [RoutePath(kind: RoutePathKind.track, points: track)],
        waypoints: const [],
      ),
    );

    expect(
      call,
      greaterThan(1),
      reason: 'one truncated answer must not be the whole match',
    );
    // Each request asks about less than the last, because the walk advances.
    expect(sent.first, greaterThan(sent.last));
    expect(result.lengthRatio, greaterThan(0.9));
  });

  test('gives up on a track it cannot advance through', () async {
    // The other side of the resume: a service that matches nothing must not
    // make one request per point for the length of the file.
    var calls = 0;
    final matcher = ValhallaImportedTrackMatcher(
      client: MockClient((_) async {
        calls += 1;
        // Geometry nowhere near the trace, so no point is ever "reached".
        return http.Response(
          jsonEncode(
            _traceResponse(
              shape: const [
                [40.0, 10.0],
                [40.001, 10.001],
              ],
            ),
          ),
          200,
        );
      }),
      traceUrl: Uri.parse('https://valhalla.example.test/trace_route'),
      maximumConsecutiveStalls: 3,
    );

    await expectLater(
      matcher.match(
        ImportedRoute(
          id: 'stuck',
          name: 'Stuck',
          importedAt: DateTime.utc(2026, 8, 16),
          sourceFileName: 'stuck.gpx',
          paths: [
            RoutePath(
              kind: RoutePathKind.track,
              points: _straightTrack(kilometres: 40, spacingMeters: 1000),
            ),
          ],
          waypoints: const [],
        ),
      ),
      throwsA(isA<FormatException>()),
    );
    expect(calls, lessThanOrEqualTo(5), reason: 'bounded by the stall limit');
  });

  test('insists on HTTPS', () async {
    final matcher = ValhallaImportedTrackMatcher(
      client: MockClient((_) async => http.Response('{}', 200)),
      traceUrl: Uri.parse('http://valhalla.example.test/trace_route'),
    );

    await expectLater(
      matcher.match(_track()),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('HTTPS'),
        ),
      ),
    );
  });
}

ValhallaImportedTrackMatcher _matcher(Map<String, Object?> response) =>
    ValhallaImportedTrackMatcher(
      client: MockClient((_) async => http.Response(jsonEncode(response), 200)),
      traceUrl: Uri.parse('https://valhalla.example.test/trace_route'),
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

/// A due-north line, so its length is arithmetic a reader can check.
List<GeoPoint> _straightTrack({
  required double kilometres,
  required double spacingMeters,
}) {
  const metersPerDegreeLatitude = 111132.0;
  final count = (kilometres * 1000 / spacingMeters).round() + 1;
  return [
    for (var index = 0; index < count; index += 1)
      GeoPoint(
        latitude: 51 + index * spacingMeters / metersPerDegreeLatitude,
        longitude: -2,
      ),
  ];
}

/// Valhalla's `trace_route` reply: the same `trip.legs[]` shape `/route`
/// returns, which is why the existing decoder and manoeuvre parser are reused.
Map<String, Object?> _traceResponse({
  List<List<double>>? shape,
  double lengthKm = 0.13,
}) {
  final points =
      shape ??
      const [
        [51.0, -2.0],
        [51.0005, -2.0005],
        [51.001, -2.001],
      ];
  return {
    'trip': {
      'legs': [
        {
          'shape': _encodeValhallaShape(points),
          'maneuvers': [
            {
              'type': 10,
              'begin_shape_index': 1,
              'end_shape_index': 2,
              'street_names': ['Test Road'],
            },
          ],
        },
      ],
      'summary': {'length': lengthKm, 'time': 300},
    },
  };
}

/// Valhalla's polyline6 encoding, so the fixture exercises the real decoder
/// rather than a shape the production path would never see.
String _encodeValhallaShape(List<List<double>> points) {
  final buffer = StringBuffer();
  var previousLat = 0;
  var previousLon = 0;
  for (final point in points) {
    final lat = (point[0] * 1e6).round();
    final lon = (point[1] * 1e6).round();
    _encodeValue(buffer, lat - previousLat);
    _encodeValue(buffer, lon - previousLon);
    previousLat = lat;
    previousLon = lon;
  }
  return buffer.toString();
}

void _encodeValue(StringBuffer buffer, int value) {
  var shifted = value < 0 ? ~(value << 1) : value << 1;
  while (shifted >= 0x20) {
    buffer.writeCharCode((0x20 | (shifted & 0x1f)) + 63);
    shifted >>= 5;
  }
  buffer.writeCharCode(shifted + 63);
}

/// Straight-line length in kilometres, for a fixture's summary.
double _polylineKm(List<List<double>> points) {
  const metersPerDegreeLatitude = 111132.0;
  var total = 0.0;
  for (var index = 1; index < points.length; index += 1) {
    final dLat = (points[index][0] - points[index - 1][0]).abs();
    final dLon = (points[index][1] - points[index - 1][1]).abs();
    total += metersPerDegreeLatitude * math.sqrt(dLat * dLat + dLon * dLon);
  }
  return total / 1000;
}
