import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/services/speed_limit.dart';

void main() {
  const endpoint = 'https://speed-limit.example/trace_attributes';
  final recordedAt = DateTime.utc(2026, 7, 24, 10);

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

  test('returns a familiar UK mph limit only for a tagged road', () async {
    late Map<String, Object?> requestBody;
    final provider = ValhallaSpeedLimitProvider(
      configuration: ValhallaSpeedLimitConfiguration(
        lookupUri: Uri.parse(endpoint),
      ),
      client: MockClient((request) async {
        requestBody = jsonDecode(request.body) as Map<String, Object?>;
        expect(request.headers['x-client-id'], 'tailendcharlie.app');
        return http.Response(
          jsonEncode({
            'units': 'kilometers',
            'admins': [
              {'country_code': 'GB'},
            ],
            'edges': [
              {
                'names': ['A Road'],
                'speed_limit': 48,
                'speed_type': 'tagged',
                'begin_heading': 0,
                'end_heading': 0,
                'end_node': {'admin_index': 0},
              },
            ],
            'matched_points': [
              {
                'type': 'matched',
                'edge_index': 0,
                'distance_from_trace_point': 2.5,
              },
              {
                'type': 'matched',
                'edge_index': 0,
                'distance_from_trace_point': 3.0,
              },
            ],
          }),
          200,
          headers: const {'content-type': 'application/json'},
        );
      }),
      clock: () => recordedAt,
    );

    final result = await provider.lookup(
      previous: location(51.5000),
      current: location(51.5004),
    );

    expect(result.outcome, SpeedLimitLookupOutcome.known);
    expect(result.limit?.milesPerHour, 30);
    expect(result.limit?.roadName, 'A Road');
    expect(result.limit?.source, ValhallaSpeedLimitProvider.sourceLabel);
    expect(requestBody['costing'], 'motorcycle');
    expect(requestBody['shape'], hasLength(2));
  });

  test('does not display a speed inferred from road classification', () async {
    final provider = ValhallaSpeedLimitProvider(
      configuration: ValhallaSpeedLimitConfiguration(
        lookupUri: Uri.parse(endpoint),
      ),
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'units': 'kilometers',
            'admins': [
              {'country_code': 'GB'},
            ],
            'edges': [
              {
                'names': ['A Road'],
                'speed_limit': 48,
                'speed_type': 'classified',
                'begin_heading': 0,
                'end_heading': 0,
                'end_node': {'admin_index': 0},
              },
            ],
            'matched_points': [
              {
                'type': 'matched',
                'edge_index': 0,
                'distance_from_trace_point': 3.0,
              },
            ],
          }),
          200,
        ),
      ),
    );

    final result = await provider.lookup(
      previous: location(51.5000),
      current: location(51.5004),
    );

    expect(result.outcome, SpeedLimitLookupOutcome.noTaggedLimit);
    expect(result.limit, isNull);
  });

  test(
    'rejects poor GPS and locations outside the UK before a request',
    () async {
      var requests = 0;
      final provider = ValhallaSpeedLimitProvider(
        configuration: ValhallaSpeedLimitConfiguration(
          lookupUri: Uri.parse(endpoint),
        ),
        client: MockClient((_) async {
          requests += 1;
          return http.Response('{}', 200);
        }),
      );

      final poorAccuracy = await provider.lookup(
        previous: location(51.5000),
        current: location(51.5004, accuracyMeters: 70),
      );
      final outsideUk = await provider.lookup(
        previous: location(48.8566, longitude: 2.3522),
        current: location(48.8570, longitude: 2.3522),
      );

      expect(poorAccuracy.outcome, SpeedLimitLookupOutcome.poorAccuracy);
      expect(outsideUk.outcome, SpeedLimitLookupOutcome.unsupportedRegion);
      expect(requests, 0);
    },
  );

  test('rejects a road match facing the opposite direction', () async {
    final provider = ValhallaSpeedLimitProvider(
      configuration: ValhallaSpeedLimitConfiguration(
        lookupUri: Uri.parse(endpoint),
      ),
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'units': 'kilometers',
            'admins': [
              {'country_code': 'GB'},
            ],
            'edges': [
              {
                'speed_limit': 48,
                'speed_type': 'tagged',
                'begin_heading': 180,
                'end_heading': 180,
                'end_node': {'admin_index': 0},
              },
            ],
            'matched_points': [
              {
                'type': 'matched',
                'edge_index': 0,
                'distance_from_trace_point': 3.0,
              },
            ],
          }),
          200,
        ),
      ),
    );

    final result = await provider.lookup(
      previous: location(51.5000),
      current: location(51.5004),
    );

    expect(result.outcome, SpeedLimitLookupOutcome.poorMatch);
    expect(result.limit, isNull);
  });

  test(
    'rejects a matched road whose Valhalla admin is outside the UK',
    () async {
      final provider = ValhallaSpeedLimitProvider(
        configuration: ValhallaSpeedLimitConfiguration(
          lookupUri: Uri.parse(endpoint),
        ),
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'units': 'kilometers',
              'admins': [
                {'country_code': 'IE'},
              ],
              'edges': [
                {
                  'speed_limit': 50,
                  'speed_type': 'tagged',
                  'begin_heading': 0,
                  'end_heading': 0,
                  'end_node': {'admin_index': 0},
                },
              ],
              'matched_points': [
                {
                  'type': 'matched',
                  'edge_index': 0,
                  'distance_from_trace_point': 3.0,
                },
              ],
            }),
            200,
          ),
        ),
      );

      final result = await provider.lookup(
        previous: location(53.34, longitude: -6.27),
        current: location(53.3404, longitude: -6.27),
      );

      expect(result.outcome, SpeedLimitLookupOutcome.unsupportedRegion);
      expect(result.limit, isNull);
    },
  );
}
