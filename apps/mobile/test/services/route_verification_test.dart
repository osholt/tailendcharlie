import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ride_relay/domain/distance_unit.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/services/road_routing.dart';
import 'package:ride_relay/services/route_attribute_provider.dart';
import 'package:ride_relay/services/route_verification.dart';

import 'route_verification_fixtures.dart';

/// What a planned route is made of, and what is said about it (#840, #858).
///
/// The traces are `trace_attributes` answers recorded on 4 October 2026; see
/// `route_verification_fixtures.dart`.
void main() {
  RouteTrace trace(String name) =>
      ValhallaRouteAttributeProvider.parseRouteTrace(
        routeVerificationFixture(name),
        submittedMeters: 1000,
        routeMeters: 1000,
      );

  List<RouteConcern> classify(String name, RoutePreferences preferences) {
    final recorded = trace(name);
    return classifyRouteEdges(recorded.edges, recorded.shape, preferences);
  }

  group('what a recorded trace says', () {
    test('the approach to the wharf is a track for its last 576 m', () {
      final recorded = trace('trace_track_approach.json');

      expect(recorded.edges, hasLength(12));
      expect(recorded.coveredMeters, closeTo(1268, 1));
      final tracks = recorded.edges.where((edge) => edge.use == 'track');
      expect(tracks, hasLength(7));
      expect(tracks.every((edge) => edge.unpaved), isTrue);
      expect(tracks.map((edge) => edge.surface).toSet(), {'dirt'});
      expect(
        tracks.map((edge) => edge.wayId).toSet(),
        hasLength(3),
        reason: 'the track is three ways',
      );
      expect(
        tracks.fold<double>(0, (total, edge) => total + edge.lengthMeters),
        closeTo(576, 0.5),
      );
      // The wharf's own road is paved, and the road before the track is too.
      expect(recorded.edges.first.use, 'road');
      expect(recorded.edges.last.use, 'service_road');
      expect(recorded.edges.last.unpaved, isFalse);
    });

    test('lengths are read in the units the service answers in', () {
      final kilometres = routeVerificationFixture('trace_track_approach.json');
      final miles = {...kilometres, 'units': 'miles'};

      double total(Map<String, Object?> body) =>
          ValhallaRouteAttributeProvider.parseRouteTrace(
            body,
            submittedMeters: 1,
            routeMeters: 1,
          ).coveredMeters;

      expect(total(miles) / total(kilometres), closeTo(1.609344, 1e-6));
      expect(
        () => total({...kilometres, 'units': 'furlongs'}),
        throwsA(isA<RouteAttributeException>()),
      );
    });

    test('an answer that is not a trace is refused, not guessed at', () {
      for (final body in <Object?>[
        null,
        'oops',
        {'error': 'Path distance exceeds the max distance limit'},
        {'edges': 'not a list'},
        {
          ...routeVerificationFixture('trace_track_approach.json'),
          'shape': 'a',
        },
      ]) {
        expect(
          () => ValhallaRouteAttributeProvider.parseRouteTrace(
            body,
            submittedMeters: 1,
            routeMeters: 1,
          ),
          throwsA(isA<RouteAttributeException>()),
          reason: '$body',
        );
      }
    });
  });

  group('classifying a route against the preferences', () {
    test('a track is an unsurfaced concern under the default preference', () {
      final concerns = classify(
        'trace_track_approach.json',
        RoutePreferences.defaults,
      );

      expect(concerns, hasLength(1));
      final concern = concerns.single;
      expect(concern.kind, RouteConcernKind.unsurfaced);
      expect(concern.lengthMeters, closeTo(576, 0.5));
      expect(concern.stretches, 1);
      expect(concern.labels, ['track']);
      // One point in the middle of each of its seven edges, to exclude them.
      expect(concern.locations, hasLength(7));
    });

    test('every location to exclude lies on the matched road', () {
      final recorded = trace('trace_track_approach.json');
      final concern = classifyRouteEdges(
        recorded.edges,
        recorded.shape,
        RoutePreferences.defaults,
      ).single;

      for (final location in concern.locations) {
        expect(
          _distanceToPolyline(location, recorded.shape),
          lessThan(0.5),
          reason: '$location is not on the road it is meant to exclude',
        );
      }
    });

    test('a route that avoids the track has nothing to report', () {
      expect(
        classify('trace_track_avoided.json', RoutePreferences.defaults),
        isEmpty,
      );
    });

    test('allowing unsurfaced byways makes a track acceptable', () {
      expect(
        classify(
          'trace_track_approach.json',
          const RoutePreferences(
            bywaySurface: BywaySurfacePreference.allowUnsurfaced,
          ),
        ),
        isEmpty,
      );
    });

    test('a car park aisle or a drive is not a byway', () {
      final recorded = trace('trace_track_approach.json');
      final accessOnly = [
        for (final edge in recorded.edges)
          edge.use == 'track'
              ? RouteEdge(
                  lengthMeters: edge.lengthMeters,
                  beginShapeIndex: edge.beginShapeIndex,
                  endShapeIndex: edge.endShapeIndex,
                  use: edge.use == 'track' ? 'parking_aisle' : edge.use,
                  unpaved: true,
                  surface: 'gravel',
                )
              : edge,
      ];

      expect(
        classifyRouteEdges(
          accessOnly,
          recorded.shape,
          RoutePreferences.defaults,
        ),
        isEmpty,
      );
    });

    test('an unpaved road with no track tag is an unsurfaced road', () {
      final concern = classifyRouteEdges(
        const [
          RouteEdge(
            lengthMeters: 300,
            beginShapeIndex: 0,
            endShapeIndex: 1,
            use: 'road',
            unpaved: true,
            surface: 'gravel',
          ),
        ],
        const [
          GeoPoint(latitude: 51, longitude: -2),
          GeoPoint(latitude: 51.002, longitude: -2),
        ],
        RoutePreferences.defaults,
      ).single;

      expect(concern.kind, RouteConcernKind.unsurfaced);
      expect(concern.labels, ['road']);
    });

    test('a footpath or cycleway is never acceptable, whatever was asked', () {
      final recorded = trace('trace_track_approach.json');
      var swapped = 0;
      final edges = [
        for (final edge in recorded.edges)
          if (edge.use == 'track' && swapped++ < 2)
            RouteEdge(
              lengthMeters: edge.lengthMeters,
              beginShapeIndex: edge.beginShapeIndex,
              endShapeIndex: edge.endShapeIndex,
              use: swapped == 1 ? 'cycleway' : 'footway',
            )
          else
            edge,
      ];

      for (final preferences in const [
        RoutePreferences.defaults,
        RoutePreferences(bywaySurface: BywaySurfacePreference.allowUnsurfaced),
      ]) {
        final concerns = classifyRouteEdges(
          edges,
          recorded.shape,
          preferences,
        ).where((concern) => concern.kind == RouteConcernKind.nonRoad);
        expect(concerns, hasLength(1), reason: preferences.summary);
        expect(concerns.single.labels, ['cycle path', 'footpath']);
      }
    });

    test('a few metres of anything is not worth a notice', () {
      final recorded = trace('trace_track_approach.json');
      // The two shortest track edges are 6 m and 11 m: 17 m between them.
      final shortest =
          (recorded.edges.where((edge) => edge.use == 'track').toList()
                ..sort((a, b) => a.lengthMeters.compareTo(b.lengthMeters)))
              .take(2)
              .toSet();
      final edges = [
        for (final edge in recorded.edges)
          if (edge.use == 'track' && !shortest.contains(edge))
            RouteEdge(
              lengthMeters: edge.lengthMeters,
              beginShapeIndex: edge.beginShapeIndex,
              endShapeIndex: edge.endShapeIndex,
              use: 'road',
            )
          else
            edge,
      ];

      expect(
        classifyRouteEdges(edges, recorded.shape, RoutePreferences.defaults),
        isEmpty,
      );
    });

    test('separate runs of the same offence are counted as places', () {
      final concern = classifyRouteEdges(
        const [
          RouteEdge(
            lengthMeters: 400,
            beginShapeIndex: 0,
            endShapeIndex: 0,
            use: 'track',
            unpaved: true,
          ),
          RouteEdge(
            lengthMeters: 900,
            beginShapeIndex: 0,
            endShapeIndex: 0,
            use: 'road',
          ),
          RouteEdge(
            lengthMeters: 250,
            beginShapeIndex: 0,
            endShapeIndex: 0,
            use: 'track',
            unpaved: true,
          ),
        ],
        const [GeoPoint(latitude: 51, longitude: -2)],
        RoutePreferences.defaults,
      ).single;

      expect(concern.lengthMeters, 650);
      expect(concern.stretches, 2);
    });
  });

  group('choosing what a re-plan excludes', () {
    RouteConcern concern(RouteConcernKind kind, int count, [double lat = 51]) =>
        RouteConcern(
          kind: kind,
          lengthMeters: 100.0 * count,
          locations: [
            for (var index = 0; index < count; index += 1)
              GeoPoint(latitude: lat + index / 1000, longitude: -2),
          ],
        );

    test('a short list is taken whole, in route order', () {
      final selected = selectExclusionLocations([
        concern(RouteConcernKind.unsurfaced, 7),
      ], 32);

      expect(selected, hasLength(7));
      expect(selected.first.latitude, 51);
      expect(selected.last.latitude, closeTo(51.006, 1e-9));
    });

    test('a long list is thinned evenly and keeps both ends', () {
      final selected = selectExclusionLocations([
        concern(RouteConcernKind.unsurfaced, 50),
      ], 5);

      expect(selected, hasLength(5));
      expect(selected.first.latitude, 51);
      expect(selected.last.latitude, closeTo(51.049, 1e-9));
    });

    test('a small concern is not crowded out by a large one', () {
      final selected = selectExclusionLocations([
        concern(RouteConcernKind.nonRoad, 40, 52),
        concern(RouteConcernKind.unsurfaced, 3, 51),
      ], 10);

      expect(selected, hasLength(10));
      expect(
        selected.where((point) => point.latitude < 52),
        hasLength(3),
        reason: 'every edge of the short concern is excluded',
      );
    });
  });

  group('what the rider is told', () {
    RouteVerification verification(
      List<RouteConcern> concerns, {
      RoutePreferences preferences = RoutePreferences.defaults,
      double routeMeters = 1268,
      double? coveredMeters,
      RouteReplanOutcome replan = RouteReplanOutcome.notAttempted,
    }) => RouteVerification(
      preferences: preferences,
      checked: true,
      concerns: concerns,
      routeMeters: routeMeters,
      coveredMeters: coveredMeters ?? routeMeters,
      replan: replan,
    );

    const track = RouteConcern(
      kind: RouteConcernKind.unsurfaced,
      lengthMeters: 576,
      labels: ['track'],
    );

    test('a clean route says nothing', () {
      final clean = verification(const []);

      expect(clean.isClean, isTrue);
      expect(clean.notices(DistanceUnit.miles), isEmpty);
    });

    test('a track is named with its length in the rider\'s unit', () {
      final found = verification(const [track]);

      expect(found.notices(DistanceUnit.miles), [
        'Uses 0.4 mi of unsurfaced track, although Avoid unsurfaced byways is '
            'on.',
      ]);
      expect(found.notices(DistanceUnit.kilometres), [
        'Uses 580 m of unsurfaced track, although Avoid unsurfaced byways is '
            'on.',
      ]);
    });

    test('a re-plan that found nothing better is said out loud', () {
      final found = verification(const [
        track,
      ], replan: RouteReplanOutcome.failed);

      expect(
        found.notices(DistanceUnit.miles).single,
        endsWith('No road route that avoids it was found.'),
      );
    });

    test('a footpath is called a footpath', () {
      final found = verification(const [
        RouteConcern(
          kind: RouteConcernKind.nonRoad,
          lengthMeters: 80,
          labels: ['footpath', 'cycle path'],
        ),
      ]);

      expect(found.notices(DistanceUnit.kilometres), [
        'Uses 80 m of footpath or cycle path, which is not a road.',
      ]);
    });

    test('a route that could not be checked says so, naming what it asked', () {
      const unchecked = RouteVerification.unchecked(RoutePreferences.defaults);

      expect(unchecked.isClean, isFalse);
      expect(unchecked.notices(DistanceUnit.miles), [
        'Could not check this route against your road preferences (avoid '
            'unsurfaced byways), so it may use roads you asked to avoid.',
      ]);
    });

    test('a rider who allows byways is not told what was not asked', () {
      const unchecked = RouteVerification.unchecked(
        RoutePreferences(bywaySurface: BywaySurfacePreference.allowUnsurfaced),
      );

      expect(unchecked.notices(DistanceUnit.miles), [
        'Could not check this route against the road data, so it may include '
            'ways a motorcycle cannot ride.',
      ]);
    });

    test('a route only partly checked says how much was', () {
      final partial = verification(
        const [],
        routeMeters: 300000,
        coveredMeters: 190000,
      );

      expect(partial.isPartial, isTrue);
      expect(partial.isClean, isFalse);
      expect(partial.notices(DistanceUnit.miles), [
        'Only 118.1 mi of this 186.4 mi route could be checked against your '
            'road preferences.',
      ]);
    });

    test('the unmatched ends of a route are not worth mentioning', () {
      final nearly = verification(
        const [],
        routeMeters: 20000,
        coveredMeters: 19200,
      );

      expect(nearly.isPartial, isFalse);
      expect(nearly.notices(DistanceUnit.miles), isEmpty);
    });

    test('checked paths of one route are reported as one', () {
      final merged = RouteVerification.merge([
        verification(const [track], routeMeters: 1000),
        verification(const [track], routeMeters: 2000),
      ])!;

      expect(merged.concerns.single.lengthMeters, 1152);
      expect(merged.concerns.single.stretches, 2);
      expect(merged.routeMeters, 3000);
      expect(RouteVerification.merge(const []), isNull);
      expect(
        RouteVerification.merge([
          verification(const []),
          const RouteVerification.unchecked(RoutePreferences.defaults),
        ])!.checked,
        isFalse,
        reason: 'one unchecked path means the route is not known to be clean',
      );
    });
  });

  group('the shape that is sent to be checked', () {
    // A straight line due north from 51 N, 500 m between points.
    List<GeoPoint> northbound(double kilometres) => [
      for (var index = 0; index <= kilometres * 2; index += 1)
        GeoPoint(latitude: 51 + index * 0.5 / 111.195, longitude: -2),
    ];

    test('a short route is sent whole, with its ends exactly as planned', () {
      final route = osrmFixturePoints('osrm_track_approach.json');

      final prepared = prepareRouteTraceShape(
        route,
        maximumMeters: 190000,
        maximumPoints: 1500,
      );

      expect(prepared.sentMeters, closeTo(prepared.routeMeters, 0.001));
      expect(prepared.routeMeters, closeTo(1267, 5));
      expect(prepared.points.first, route.first);
      expect(prepared.points.last, route.last);
    });

    test('a route over the service limit is cut exactly at it', () {
      final prepared = prepareRouteTraceShape(
        northbound(300),
        maximumMeters: 190000,
        maximumPoints: 1500,
      );

      expect(prepared.routeMeters, closeTo(300000, 300));
      expect(prepared.sentMeters, closeTo(190000, 0.001));
      expect(
        prepared.points.last.latitude,
        closeTo(51 + 190 / 111.195, 1e-4),
        reason: 'the part sent is a true prefix of the route',
      );
    });

    test('a straight road is given points so a matcher cannot wander', () {
      final prepared = prepareRouteTraceShape(
        [
          const GeoPoint(latitude: 51, longitude: -2),
          const GeoPoint(latitude: 51.1, longitude: -2),
        ],
        maximumMeters: 190000,
        maximumPoints: 1500,
      );

      expect(prepared.points.length, greaterThan(40));
      for (var index = 1; index < prepared.points.length; index += 1) {
        expect(
          routeDistanceMeters(
            prepared.points[index - 1],
            prepared.points[index],
          ),
          lessThanOrEqualTo(250.5),
        );
      }
    });

    test('a bend survives simplification', () {
      final bend = [
        for (var index = 0; index <= 100; index += 1)
          GeoPoint(latitude: 51 + index * 0.00001, longitude: -2),
        for (var index = 1; index <= 100; index += 1)
          GeoPoint(latitude: 51.001, longitude: -2 + index * 0.00001),
      ];

      final prepared = prepareRouteTraceShape(
        bend,
        maximumMeters: 190000,
        maximumPoints: 1500,
      );

      expect(
        prepared.points.any(
          (point) =>
              (point.latitude - 51.001).abs() < 1e-9 &&
              (point.longitude + 2).abs() < 1e-9,
        ),
        isTrue,
        reason: 'the corner is kept',
      );
    });

    test('a route is never sent as more points than the limit', () {
      final wiggle = [
        for (var index = 0; index < 6000; index += 1)
          GeoPoint(
            latitude: 51 + index * 0.00002,
            longitude: -2 + math.sin(index / 7) * 0.0004,
          ),
      ];

      final prepared = prepareRouteTraceShape(
        wiggle,
        maximumMeters: 190000,
        maximumPoints: 400,
      );

      expect(prepared.points.length, lessThanOrEqualTo(400));
      expect(prepared.points.first, wiggle.first);
      expect(prepared.points.last, wiggle.last);
    });
  });

  group('asking Valhalla trace_attributes', () {
    final route = osrmFixturePoints('osrm_track_approach.json');

    ValhallaRouteAttributeProvider provider(
      http.Client client, {
      Uri? endpoint,
    }) => ValhallaRouteAttributeProvider(
      client: client,
      endpoint:
          endpoint ??
          Uri.parse('https://valhalla.example.test/trace_attributes'),
    );

    test('asks to match the line to the graph and for nothing else', () async {
      http.Request? sent;
      final recorded = await provider(
        MockClient((request) async {
          sent = request;
          return fixtureResponse('trace_track_approach.json');
        }),
      ).trace(route);

      expect(sent!.method, 'POST');
      expect(sent!.headers['user-agent'], contains('TailEndCharlie'));
      final body = jsonDecode(sent!.body) as Map<String, Object?>;
      expect(body['shape_match'], 'map_snap');
      expect(body['costing'], 'motorcycle');
      expect(body.containsKey('costing_options'), isFalse);
      expect(
        (body['filters']! as Map)['attributes'],
        ValhallaRouteAttributeProvider.requestedAttributes,
      );
      expect((body['shape']! as List).length, lessThanOrEqualTo(1500));
      expect(recorded.edges, hasLength(12));
      expect(recorded.routeMeters, closeTo(1267, 5));
    });

    test('a refusal, an outage and a bad answer are all reported', () async {
      for (final handler in <Future<http.Response> Function(http.Request)>[
        (_) async => http.Response('{"error":"too long"}', 400),
        (_) async => http.Response('busy', 503),
        (_) async => http.Response('not json', 200),
        (_) async => throw http.ClientException('offline'),
        (_) async => http.Response('{"edges":[]', 200),
      ]) {
        await expectLater(
          provider(MockClient(handler)).trace(route),
          throwsA(isA<RouteAttributeException>()),
        );
      }
    });

    test('is never asked of a service that is not HTTPS', () async {
      await expectLater(
        provider(
          MockClient((_) async => fixtureResponse('trace_track_approach.json')),
          endpoint: Uri.parse('http://valhalla.example.test/trace_attributes'),
        ).trace(route),
        throwsA(isA<RouteAttributeException>()),
      );
    });
  });

  group('where the check is made', () {
    test('beside the motorcycle router, derived from its URL', () {
      expect(
        RoutingConfiguration.fromEnvironment().routeAttributesUrl.toString(),
        'https://valhalla1.openstreetmap.de/trace_attributes',
      );
      RoutingConfiguration configuration(String route) => RoutingConfiguration(
        routingBaseUrl: Uri.parse('https://osrm.example.test'),
        geocodingBaseUrl: Uri.parse('https://geocoder.example.test'),
        motorcycleRoutingUrl: Uri.parse(route),
        trackMatchingUrl: Uri.parse(
          'https://valhalla.example.test/trace_route',
        ),
      );

      expect(
        configuration(
          'https://own.example.test/valhalla/route/',
        ).routeAttributesUrl.toString(),
        'https://own.example.test/valhalla/trace_attributes',
      );
    });
  });
}

/// Distance in metres from [point] to the nearest part of [line], on a local
/// flat projection - exact enough to tell on the line from beside it.
double _distanceToPolyline(GeoPoint point, List<GeoPoint> line) {
  const metresPerDegree = 111195.0;
  final scale = math.cos(point.latitude * math.pi / 180);
  double x(GeoPoint p) =>
      (p.longitude - point.longitude) * scale * metresPerDegree;
  double y(GeoPoint p) => (p.latitude - point.latitude) * metresPerDegree;
  var nearest = double.infinity;
  for (var index = 1; index < line.length; index += 1) {
    final ax = x(line[index - 1]);
    final ay = y(line[index - 1]);
    final bx = x(line[index]);
    final by = y(line[index]);
    final dx = bx - ax;
    final dy = by - ay;
    final lengthSquared = dx * dx + dy * dy;
    final t = lengthSquared == 0
        ? 0.0
        : ((-ax * dx - ay * dy) / lengthSquared).clamp(0.0, 1.0);
    nearest = math.min(
      nearest,
      math.sqrt(math.pow(ax + dx * t, 2) + math.pow(ay + dy * t, 2)),
    );
  }
  return nearest;
}
