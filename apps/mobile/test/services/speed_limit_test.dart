import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/services/speed_limit.dart';

void main() {
  const endpoint = 'https://speed-limit.example/trace_attributes';
  final recordedAt = DateTime.utc(2026, 7, 26, 10);

  SpeedLimitLocation location(
    double latitude, {
    double longitude = -0.12,
    double? headingDegrees = 0,
    double? accuracyMeters = 5,
  }) => SpeedLimitLocation(
    point: GeoPoint(latitude: latitude, longitude: longitude),
    recordedAt: recordedAt,
    accuracyMeters: accuracyMeters,
    headingDegrees: headingDegrees,
  );

  /// A `trace_attributes` response in the shape the live FOSSGIS instance
  /// returns, including `speed_type: classified` alongside a real posted limit.
  String traceBody({
    Object? speedLimitKph = 48,
    String countryCode = 'GB',
    double matchDistanceMeters = 0,
    List<String> names = const [],
    num heading = 0,
    int shapePoints = 2,
  }) => jsonEncode({
    'units': 'kilometers',
    'admins': [
      {'country_code': countryCode},
    ],
    'edges': [
      {
        if (names.isNotEmpty) 'names': names,
        // Absent, exactly as the live service omits it for an untagged road.
        'speed_limit': ?speedLimitKph,
        'speed_type': 'classified',
        'begin_heading': heading,
        'end_heading': heading,
        'end_node': {'admin_index': 0},
      },
    ],
    'matched_points': List.generate(
      shapePoints,
      (_) => {
        'type': 'matched',
        'edge_index': 0,
        'distance_from_trace_point': matchDistanceMeters,
      },
    ),
    'alternate_paths': const [],
  });

  /// One `locate` candidate edge, in the shape the live instance returns.
  Map<String, Object?> candidate({
    required double distanceMeters,
    required String roadClass,
    String use = 'road',
    Object? speedLimitKph = 0,
    List<String> names = const [],
    double correlatedLatitude = 51.5,
    double correlatedLongitude = -0.12,
  }) => {
    'correlated_lat': correlatedLatitude,
    'correlated_lon': correlatedLongitude,
    'distance': distanceMeters,
    'heading': 90.0,
    'percent_along': 0.5,
    'side_of_street': 'neither',
    'edge_info': {'way_id': 1, 'names': names, 'speed_limit': ?speedLimitKph},
    'edge': {
      'speeds': {'default': 30, 'type': 'classified'},
      'classification': {
        'classification': roadClass,
        'use': use,
        'surface': 'paved_smooth',
        'link': false,
        'internal': false,
      },
    },
  };

  String locateBody(List<Map<String, Object?>> edges) => jsonEncode([
    {'input_lat': 51.5, 'input_lon': -0.12, 'edges': edges, 'nodes': const []},
  ]);

  /// Builds a provider whose mock service answers each endpoint separately and
  /// records what was asked of it.
  ({
    ValhallaSpeedLimitProvider provider,
    List<Map<String, Object?>> traceRequests,
    List<Map<String, Object?>> locateRequests,
  })
  build({String? locate, String trace = '', int traceStatus = 200}) {
    final traceRequests = <Map<String, Object?>>[];
    final locateRequests = <Map<String, Object?>>[];
    final provider = ValhallaSpeedLimitProvider(
      configuration: ValhallaSpeedLimitConfiguration(
        lookupUri: Uri.parse(endpoint),
      ),
      client: MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, Object?>;
        expect(request.headers['x-client-id'], 'tailendcharlie.app');
        if (request.url.path.endsWith('locate')) {
          locateRequests.add(body);
          return http.Response(locate ?? '[]', 200);
        }
        traceRequests.add(body);
        return http.Response(trace, traceStatus);
      }),
      clock: () => recordedAt,
    );
    return (
      provider: provider,
      traceRequests: traceRequests,
      locateRequests: locateRequests,
    );
  }

  group('stationary resolution', () {
    test('never asks the service to match a single-point shape', () async {
      // The live instance rejects a one-point shape with `error_code` 123,
      // "Insufficient shape provided", which is why every ride-start lookup
      // showed nothing (#145). Every trace the app sends now carries two points,
      // and for a stationary fix both are that fix.
      final harness = build(
        locate: locateBody([
          candidate(
            distanceMeters: 0,
            roadClass: 'residential',
            speedLimitKph: 48,
            correlatedLatitude: 51.5,
            correlatedLongitude: -0.12,
          ),
        ]),
        trace: traceBody(),
      );

      final result = await harness.provider.lookup(current: location(51.5));

      expect(result.outcome, SpeedLimitLookupOutcome.known);
      expect(harness.traceRequests, hasLength(1));
      final shape = harness.traceRequests.single['shape'] as List;
      expect(shape, hasLength(2));
      expect(shape.first, shape.last);
    });

    test('shows a limit the service reports with a classified base speed', () async {
      // Valhalla documents `speed_limit` as the posted limit and `speed_type` as
      // the provenance of the *base routing speed*. The live instance reports
      // `classified` on roads that carry an explicit OpenStreetMap `maxspeed`, so
      // gating the display on `speed_type` withheld every genuine limit (#145).
      final harness = build(
        locate: locateBody([
          candidate(
            distanceMeters: 0,
            roadClass: 'trunk',
            speedLimitKph: 80,
            names: const ['A4174'],
          ),
        ]),
        trace: traceBody(speedLimitKph: 80),
      );

      final result = await harness.provider.lookup(current: location(51.5));

      expect(result.outcome, SpeedLimitLookupOutcome.known);
      expect(result.limit?.milesPerHour, 50);
      expect(result.limit?.roadName, 'A4174');
    });

    test('keeps an unrestricted road distinct from an untagged road', () async {
      // Captured from the live FOSSGIS trace_attributes service on OSM way
      // 271008234 (A 555): maxspeed=none is the string "unlimited". At the
      // bundled demo start, untagged way 844320294 omits speed_limit entirely.
      final unlimited = build(
        locate: locateBody([
          candidate(
            distanceMeters: 0,
            roadClass: 'trunk',
            speedLimitKph: 'unlimited',
            names: const ['Unrestricted road'],
          ),
        ]),
        trace: traceBody(speedLimitKph: 'unlimited'),
      );

      final unlimitedResult = await unlimited.provider.lookup(
        current: location(51.5),
      );

      expect(unlimitedResult.outcome, SpeedLimitLookupOutcome.known);
      expect(unlimitedResult.limit?.unlimited, isTrue);
      expect(unlimitedResult.limit?.milesPerHour, isNull);

      final untagged = build(
        locate: locateBody([
          candidate(distanceMeters: 0, roadClass: 'trunk', speedLimitKph: null),
        ]),
        trace: traceBody(speedLimitKph: null),
      );

      final untaggedResult = await untagged.provider.lookup(
        current: location(51.5),
      );

      expect(untaggedResult.outcome, SpeedLimitLookupOutcome.noTaggedLimit);
      expect(untaggedResult.limit, isNull);
    });

    test(
      'resolves the road under a bike standing on the carriageway',
      () async {
        final harness = build(
          locate: locateBody([
            candidate(
              distanceMeters: 0,
              roadClass: 'primary',
              speedLimitKph: 48,
              names: const ['London Road', 'A420'],
            ),
          ]),
          trace: traceBody(),
        );

        final result = await harness.provider.lookup(current: location(51.5));

        expect(result.outcome, SpeedLimitLookupOutcome.known);
        expect(result.limit?.milesPerHour, 30);
        expect(result.limit?.roadName, 'London Road');
        expect(result.limit?.matchDistanceMeters, 0);
      },
    );

    test('tolerates a fix 10 m off the carriageway', () async {
      final harness = build(
        locate: locateBody([
          candidate(distanceMeters: 9.9, roadClass: 'trunk', speedLimitKph: 80),
        ]),
        trace: traceBody(speedLimitKph: 80),
      );

      final result = await harness.provider.lookup(
        current: location(51.5, accuracyMeters: 12),
      );

      expect(result.outcome, SpeedLimitLookupOutcome.known);
      expect(result.limit?.milesPerHour, 50);
      expect(result.limit?.matchDistanceMeters, closeTo(9.9, 0.01));
    });

    test('tolerates a fix 25 m off the carriageway', () async {
      // The stated tolerance, and the reason for it: a phone at a standstill
      // beside buildings is routinely displaced this far, and the rider is
      // plainly on the road they are parked beside.
      final harness = build(
        locate: locateBody([
          candidate(
            distanceMeters: 24.8,
            roadClass: 'trunk',
            speedLimitKph: 80,
          ),
        ]),
        trace: traceBody(speedLimitKph: 80),
      );

      final result = await harness.provider.lookup(
        current: location(51.5, accuracyMeters: 20),
      );

      expect(result.outcome, SpeedLimitLookupOutcome.known);
      expect(result.limit?.milesPerHour, 50);
    });

    test('will not name a road 26 m from a stationary fix', () async {
      final harness = build(
        locate: locateBody([
          candidate(distanceMeters: 26, roadClass: 'trunk', speedLimitKph: 80),
        ]),
        trace: traceBody(speedLimitKph: 80),
      );

      final result = await harness.provider.lookup(current: location(51.5));

      expect(result.outcome, SpeedLimitLookupOutcome.poorMatch);
      expect(result.limit, isNull);
      // Nothing is being displayed, so no request was spent confirming a country.
      expect(harness.traceRequests, isEmpty);
    });
  });

  group('choosing between nearby roads', () {
    test(
      'prefers the road beside a car park over the aisle beneath the bike',
      () async {
        // Captured from the live instance at a Bristol car park aisle: the aisle is
        // under the wheels, Brendon Road is 13.6 m away and posts 20 mph.
        final harness = build(
          locate: locateBody([
            candidate(
              distanceMeters: 0,
              roadClass: 'service_other',
              use: 'parking_aisle',
            ),
            candidate(
              distanceMeters: 1.4,
              roadClass: 'service_other',
              use: 'parking_aisle',
            ),
            candidate(
              distanceMeters: 13.6,
              roadClass: 'residential',
              speedLimitKph: 32,
              names: const ['Brendon Road'],
            ),
            candidate(
              distanceMeters: 22.8,
              roadClass: 'service_other',
              use: 'service_road',
            ),
          ]),
          trace: traceBody(speedLimitKph: 32),
        );

        final result = await harness.provider.lookup(current: location(51.5));

        expect(result.outcome, SpeedLimitLookupOutcome.known);
        expect(result.limit?.milesPerHour, 20);
        expect(result.limit?.roadName, 'Brendon Road');
      },
    );

    test('reports an ambiguous junction rather than choosing a limit', () async {
      // Captured at the point on the A4174 where 30 becomes 50: two trunk edges
      // are both under the bike and post different limits. A wrong limit is worse
      // than an absent one, so this stays unconfirmed and resolves on movement.
      final harness = build(
        locate: locateBody([
          candidate(
            distanceMeters: 0,
            roadClass: 'trunk',
            speedLimitKph: 80,
            names: const ['A4174'],
          ),
          candidate(
            distanceMeters: 0,
            roadClass: 'trunk',
            speedLimitKph: 48,
            names: const ['A4174'],
          ),
        ]),
        trace: traceBody(speedLimitKph: 80),
      );

      final result = await harness.provider.lookup(current: location(51.5));

      expect(result.outcome, SpeedLimitLookupOutcome.poorMatch);
      expect(result.limit, isNull);
      expect(harness.traceRequests, isEmpty);
    });

    test(
      'accepts a junction whose candidates all post the same limit',
      () async {
        // Captured at Deanery Road Roundabout: five trunk edges and one primary
        // edge within 25 m, all posting 30.
        final harness = build(
          locate: locateBody([
            for (final distance in const [0.0, 12.8, 16.9, 20.6, 23.3])
              candidate(
                distanceMeters: distance,
                roadClass: 'trunk',
                speedLimitKph: 48,
                names: const ['A4174'],
              ),
            candidate(
              distanceMeters: 23.3,
              roadClass: 'primary',
              speedLimitKph: 48,
              names: const ['Deanery Road', 'A420'],
            ),
          ]),
          trace: traceBody(),
        );

        final result = await harness.provider.lookup(current: location(51.5));

        expect(result.outcome, SpeedLimitLookupOutcome.known);
        expect(result.limit?.milesPerHour, 30);
        expect(result.limit?.roadName, 'A4174');
      },
    );

    test('prefers the higher road class when carriageways disagree', () async {
      // Judgement, not a fact: a rider setting off is on the main road rather than
      // the side street touching it.
      final harness = build(
        locate: locateBody([
          candidate(
            distanceMeters: 4,
            roadClass: 'residential',
            speedLimitKph: 32,
            names: const ['Side Street'],
          ),
          candidate(
            distanceMeters: 18,
            roadClass: 'primary',
            speedLimitKph: 48,
            names: const ['Main Road'],
          ),
        ]),
        trace: traceBody(),
      );

      final result = await harness.provider.lookup(current: location(51.5));

      expect(result.outcome, SpeedLimitLookupOutcome.known);
      expect(result.limit?.milesPerHour, 30);
      expect(result.limit?.roadName, 'Main Road');
    });

    test(
      'the demo route start point has no mapped limit within tolerance',
      () async {
        // Captured at the bundled demo route's first track point, the King's Oak
        // Academy car park in Kingswood. The aisle underneath is untagged and the
        // nearest road, Brook Road, is 42.7 m away and untagged too, so no
        // tolerance can honestly produce a number here.
        final harness = build(
          locate: locateBody([
            candidate(
              distanceMeters: 0,
              roadClass: 'service_other',
              use: 'service_road',
            ),
            candidate(
              distanceMeters: 42.7,
              roadClass: 'unclassified',
              names: const ['Brook Road'],
            ),
          ]),
          trace: traceBody(speedLimitKph: null),
        );

        final result = await harness.provider.lookup(
          current: location(51.462671, longitude: -2.484517),
        );

        expect(result.outcome, SpeedLimitLookupOutcome.noTaggedLimit);
        expect(result.limit, isNull);
        expect(harness.traceRequests, isEmpty);
      },
    );

    test(
      'falls back to the aisle limit when only service ways are near',
      () async {
        final harness = build(
          locate: locateBody([
            candidate(
              distanceMeters: 2,
              roadClass: 'service_other',
              use: 'parking_aisle',
              speedLimitKph: 32,
              names: const ['Estate Road'],
            ),
          ]),
          trace: traceBody(speedLimitKph: 32),
        );

        final result = await harness.provider.lookup(current: location(51.5));

        expect(result.outcome, SpeedLimitLookupOutcome.known);
        expect(result.limit?.milesPerHour, 20);
      },
    );
  });

  group('honesty rules', () {
    test('refuses a limit outside Great Britain and the Isle of Man', () async {
      // The chosen road's own snapped position is what gets confirmed, so an
      // Irish road inside the UK bounding box cannot reach an mph sign.
      final harness = build(
        locate: locateBody([
          candidate(distanceMeters: 3, roadClass: 'primary', speedLimitKph: 80),
        ]),
        trace: traceBody(speedLimitKph: 80, countryCode: 'IE'),
      );

      final result = await harness.provider.lookup(
        current: location(53.34, longitude: -6.27),
      );

      expect(result.outcome, SpeedLimitLookupOutcome.unsupportedRegion);
      expect(result.limit, isNull);
    });

    test('does not display a value that is not a UK sign limit', () async {
      // 100 km/h is 62 mph, which no UK sign carries, so it is not a posted UK
      // limit however confidently it was matched.
      final harness = build(
        locate: locateBody([
          candidate(
            distanceMeters: 2,
            roadClass: 'primary',
            speedLimitKph: 100,
          ),
        ]),
        trace: traceBody(),
      );

      final result = await harness.provider.lookup(current: location(51.5));

      expect(result.outcome, SpeedLimitLookupOutcome.noTaggedLimit);
      expect(result.limit, isNull);
    });

    test('reports poor GPS and non-UK positions before any request', () async {
      final harness = build(trace: traceBody());

      final poorAccuracy = await harness.provider.lookup(
        current: location(51.5, accuracyMeters: 45),
      );
      final movingPoorAccuracy = await harness.provider.lookup(
        previous: location(51.5000),
        current: location(51.5004, accuracyMeters: 70),
      );
      final outsideUk = await harness.provider.lookup(
        current: location(48.8566, longitude: 2.3522),
      );

      expect(poorAccuracy.outcome, SpeedLimitLookupOutcome.poorAccuracy);
      expect(movingPoorAccuracy.outcome, SpeedLimitLookupOutcome.poorAccuracy);
      expect(outsideUk.outcome, SpeedLimitLookupOutcome.unsupportedRegion);
      expect(harness.traceRequests, isEmpty);
      expect(harness.locateRequests, isEmpty);
    });

    test('accepts the accuracy a phone reports at a standstill', () async {
      // 40 m is the ceiling: common between buildings, and the snap distance
      // rather than the accuracy reading is what decides whether to display.
      final harness = build(
        locate: locateBody([
          candidate(distanceMeters: 8, roadClass: 'primary', speedLimitKph: 48),
        ]),
        trace: traceBody(),
      );

      final result = await harness.provider.lookup(
        current: location(51.5, accuracyMeters: 38),
      );

      expect(result.outcome, SpeedLimitLookupOutcome.known);
      expect(result.limit?.milesPerHour, 30);
    });

    test('reports the service being unreachable as unavailable', () async {
      final harness = build(locate: 'not json', trace: traceBody());

      final result = await harness.provider.lookup(current: location(51.5));

      expect(result.outcome, SpeedLimitLookupOutcome.unavailable);
    });
  });

  group('once the bike is moving', () {
    test('sends the travelled pair and reports the matched limit', () async {
      final harness = build(
        trace: traceBody(names: const ['A Road'], matchDistanceMeters: 3),
      );

      final result = await harness.provider.lookup(
        previous: location(51.5000),
        current: location(51.5004),
      );

      expect(result.outcome, SpeedLimitLookupOutcome.known);
      expect(result.limit?.milesPerHour, 30);
      expect(result.limit?.roadName, 'A Road');
      expect(harness.locateRequests, isEmpty);
      final shape = harness.traceRequests.single['shape'] as List;
      expect(shape, hasLength(2));
      expect(shape.first, isNot(shape.last));
      expect(harness.traceRequests.single['costing'], 'motorcycle');
    });

    test('parses the live unlimited trace sentinel', () async {
      final harness = build(
        trace: traceBody(
          speedLimitKph: 'unlimited',
          countryCode: 'IM',
          names: const ['Unrestricted road'],
          heading: 150,
        ),
      );

      final result = await harness.provider.lookup(
        previous: location(
          54.1853058,
          longitude: -4.4982317,
          headingDegrees: 150,
        ),
        current: location(
          54.1845085,
          longitude: -4.4974432,
          headingDegrees: 150,
        ),
      );

      expect(result.outcome, SpeedLimitLookupOutcome.known);
      expect(result.limit?.unlimited, isTrue);
      expect(result.limit?.milesPerHour, isNull);
    });

    test(
      'rejects a road facing the opposite way to the travel heading',
      () async {
        final harness = build(trace: traceBody(heading: 180));

        final result = await harness.provider.lookup(
          previous: location(51.5000),
          current: location(51.5004),
        );

        expect(result.outcome, SpeedLimitLookupOutcome.poorMatch);
        expect(result.limit, isNull);
      },
    );

    test(
      'rejects a matched road whose Valhalla admin is outside the UK',
      () async {
        final harness = build(trace: traceBody(countryCode: 'IE'));

        final result = await harness.provider.lookup(
          previous: location(53.34, longitude: -6.27),
          current: location(53.3404, longitude: -6.27),
        );

        expect(result.outcome, SpeedLimitLookupOutcome.unsupportedRegion);
      },
    );

    test('accepts a snap 25 m out once a heading corroborates it', () async {
      // A moving rider used to be held to a tighter bound than a stationary one,
      // which was the wrong way round.
      final harness = build(trace: traceBody(matchDistanceMeters: 24));

      final result = await harness.provider.lookup(
        previous: location(51.5000),
        current: location(51.5004, accuracyMeters: 5),
      );

      expect(result.outcome, SpeedLimitLookupOutcome.known);
    });

    test('treats a jittering pair as a standstill', () async {
      // Under 4 m apart the two fixes are noise, not travel, so this resolves
      // through the stationary path and never claims a heading.
      final harness = build(
        locate: locateBody([
          candidate(distanceMeters: 1, roadClass: 'primary', speedLimitKph: 48),
        ]),
        trace: traceBody(),
      );

      final result = await harness.provider.lookup(
        previous: location(51.50000),
        current: location(51.50001),
      );

      expect(result.outcome, SpeedLimitLookupOutcome.known);
      expect(harness.locateRequests, hasLength(1));
    });
  });

  test('prefetch resolves several roads in one trace request', () async {
    final harness = build(
      trace: jsonEncode({
        'units': 'kilometers',
        'admins': [
          {'country_code': 'GB'},
        ],
        'edges': [
          {
            'way_id': 101,
            'names': ['First road'],
            'speed_limit': 48,
            'begin_heading': 0,
            'end_heading': 0,
            'end_node': {'admin_index': 0},
          },
          {
            'way_id': 202,
            'names': ['Unmapped road'],
            'begin_heading': 0,
            'end_heading': 0,
            'end_node': {'admin_index': 0},
          },
          {
            'way_id': 303,
            'names': ['Unrestricted road'],
            'speed_limit': 'unlimited',
            'begin_heading': 0,
            'end_heading': 0,
            'end_node': {'admin_index': 0},
          },
        ],
        'matched_points': [
          for (final edgeIndex in const [0, 1, 2])
            {
              'type': 'matched',
              'edge_index': edgeIndex,
              'distance_from_trace_point': 2,
            },
        ],
      }),
    );

    final results = await harness.provider.prefetch(
      locations: [location(51.5000), location(51.5007), location(51.5014)],
    );

    expect(harness.traceRequests, hasLength(1));
    expect(harness.traceRequests.single['shape'], hasLength(3));
    expect(results, hasLength(3));
    expect(results[0].result.limit?.milesPerHour, 30);
    expect(results[1].result.outcome, SpeedLimitLookupOutcome.noTaggedLimit);
    expect(results[2].result.limit?.unlimited, isTrue);
    expect(results.map((result) => result.roadId).toSet(), hasLength(3));
  });

  test('derives the candidate endpoint from the configured lookup URL', () {
    expect(
      const ValhallaSpeedLimitConfiguration(lookupUri: null).candidateUri,
      isNull,
    );
    expect(
      ValhallaSpeedLimitConfiguration(
        lookupUri: Uri.parse('https://routing.example.com/trace_attributes'),
      ).candidateUri,
      Uri.parse('https://routing.example.com/locate'),
    );
    expect(
      ValhallaSpeedLimitConfiguration(
        lookupUri: Uri.parse('https://host.example/valhalla/trace_attributes'),
      ).candidateUri,
      Uri.parse('https://host.example/valhalla/locate'),
    );
  });
}
