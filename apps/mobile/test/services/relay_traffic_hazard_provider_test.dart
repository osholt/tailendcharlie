import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:ride_relay/domain/geo_point.dart';
import 'package:ride_relay/domain/hazard.dart';
import 'package:ride_relay/internet/internet_relay_client.dart';
import 'package:ride_relay/services/external_hazard_provider.dart';
import 'package:ride_relay/services/relay_traffic_hazard_provider.dart';

void main() {
  final configuration = InternetRelayConfiguration(
    baseUri: Uri.parse('https://relay.tailendcharlie.app/api'),
  );
  final now = DateTime.utc(2026, 7, 24, 20);

  test(
    'loads and retains only incidents intersecting the route corridor',
    () async {
      final requests = <Uri>[];
      final provider = RelayTrafficHazardProvider(
        configuration: configuration,
        clock: () => now,
        httpGet: (uri, {headers}) async {
          requests.add(uri);
          expect(headers?['x-tailendcharlie-protocol'], '1');
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'provider': 'tomtom-orbis',
                'fetchedAt': '2026-07-24T19:59:00Z',
                'trafficModelId': '99123',
                'incidents': [
                  {
                    'id': 'near-route',
                    'type': 'roadworks',
                    'severity': 'critical',
                    'description': 'A48 closed',
                    'geometry': [
                      {'latitude': 51.5003, 'longitude': -3.1500},
                      {'latitude': 51.5004, 'longitude': -3.1400},
                    ],
                    'observedAt': '2026-07-24T19:58:00Z',
                    'expiresAt': '2026-07-24T22:00:00Z',
                    'reportCount': 4,
                  },
                  {
                    'id': 'unrelated',
                    'type': 'collision',
                    'severity': 'serious',
                    'description': 'Unrelated collision',
                    'geometry': [
                      {'latitude': 51.5600, 'longitude': -3.1500},
                    ],
                    'observedAt': '2026-07-24T19:57:00Z',
                    'expiresAt': '2026-07-24T21:00:00Z',
                    'reportCount': 2,
                  },
                ],
              }),
            ),
            200,
            headers: {'content-type': 'application/json'},
          );
        },
      );

      final result = await provider.fetch(
        ExternalHazardQuery(
          rideId: 'ride-1',
          route: const [
            GeoPoint(latitude: 51.5, longitude: -3.16),
            GeoPoint(latitude: 51.5, longitude: -3.13),
          ],
          requestedAt: now,
          corridorMeters: 1000,
        ),
      );

      expect(requests, hasLength(1));
      expect(requests.single.path, '/api/v1/traffic/incidents');
      expect(requests.single.queryParameters['west'], isNotNull);
      expect(result.status.state, ExternalHazardProviderState.ready);
      expect(result.hazards, hasLength(1));
      final hazard = result.hazards.single;
      expect(hazard.id, 'tomtom-near-route');
      expect(hazard.rideId, 'ride-1');
      expect(hazard.type, HazardType.roadworks);
      expect(hazard.severity, HazardSeverity.critical);
      expect(hazard.source, HazardSource.externalProvider);
      expect(hazard.providerId, 'tomtom-traffic');
      expect(hazard.confirmations, 4);
      expect(hazard.details, contains('TomTom'));
      expect(result.status.message, '1 route-relevant incident · TomTom');
    },
  );

  test('reports relay configuration without attempting a request', () async {
    var requested = false;
    final provider = RelayTrafficHazardProvider(
      configuration: const InternetRelayConfiguration(baseUri: null),
      httpGet: (uri, {headers}) async {
        requested = true;
        return http.Response('{}', 200);
      },
    );

    final result = await provider.fetch(
      ExternalHazardQuery(
        rideId: 'ride-1',
        route: const [
          GeoPoint(latitude: 51.5, longitude: -3.16),
          GeoPoint(latitude: 51.5, longitude: -3.13),
        ],
        requestedAt: now,
      ),
    );

    expect(requested, isFalse);
    expect(result.status.state, ExternalHazardProviderState.needsConfiguration);
  });

  test('explains when the server-held provider key is absent', () async {
    final provider = RelayTrafficHazardProvider(
      configuration: configuration,
      httpGet: (uri, {headers}) async => http.Response(
        jsonEncode({
          'code': 'traffic_provider_unconfigured',
          'message': 'Live UK traffic incidents are not configured.',
        }),
        503,
        headers: {'content-type': 'application/json'},
      ),
    );

    final result = await provider.fetch(
      ExternalHazardQuery(
        rideId: 'ride-1',
        route: const [
          GeoPoint(latitude: 51.5, longitude: -3.16),
          GeoPoint(latitude: 51.5, longitude: -3.13),
        ],
        requestedAt: now,
      ),
    );

    expect(result.status.state, ExternalHazardProviderState.needsConfiguration);
    expect(
      result.status.message,
      'Live UK traffic incidents are not configured.',
    );
  });

  test('a transient failure remains eligible for the next refresh', () async {
    var requests = 0;
    final provider = RelayTrafficHazardProvider(
      configuration: configuration,
      clock: () => now,
      httpGet: (uri, {headers}) async {
        requests += 1;
        if (requests == 1) {
          return http.Response('temporarily unavailable', 502);
        }
        return http.Response(
          jsonEncode({
            'provider': 'tomtom-orbis',
            'fetchedAt': '2026-07-24T20:00:00Z',
            'incidents': <Object?>[],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      },
    );
    final query = ExternalHazardQuery(
      rideId: 'ride-1',
      route: const [
        GeoPoint(latitude: 51.5, longitude: -3.16),
        GeoPoint(latitude: 51.5, longitude: -3.13),
      ],
      requestedAt: now,
    );

    final failed = await provider.fetch(query);
    final recovered = await provider.fetch(query);

    expect(failed.status.state, ExternalHazardProviderState.failed);
    expect(failed.status.canFetch, isTrue);
    expect(recovered.status.state, ExternalHazardProviderState.ready);
    expect(requests, 2);
  });
}
