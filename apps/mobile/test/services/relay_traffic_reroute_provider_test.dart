import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:ride_relay/domain/geo_point.dart' as awareness;
import 'package:ride_relay/domain/hazard.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/internet/internet_relay_client.dart';
import 'package:ride_relay/services/relay_traffic_reroute_provider.dart';

void main() {
  final configuration = InternetRelayConfiguration(
    baseUri: Uri.parse('https://relay.tailendcharlie.app/api'),
  );
  final now = DateTime.utc(2026, 7, 24, 20);
  final route = ImportedRoute(
    id: 'route-1',
    name: 'Friday route',
    importedAt: now.subtract(const Duration(hours: 2)),
    sourceFileName: 'friday.gpx',
    paths: const [
      RoutePath(
        kind: RoutePathKind.track,
        points: [
          GeoPoint(latitude: 51.48, longitude: -3.18),
          GeoPoint(latitude: 51.485, longitude: -3.17),
          GeoPoint(latitude: 51.49, longitude: -3.16),
        ],
      ),
    ],
    waypoints: const [
      RouteWaypoint(
        point: GeoPoint(latitude: 51.49, longitude: -3.16),
        name: 'Ferry',
      ),
    ],
  );
  final closure = HazardReport(
    id: 'tomtom-closure-1',
    rideId: 'ride-1',
    type: HazardType.roadworks,
    severity: HazardSeverity.critical,
    position: const awareness.GeoPoint(latitude: 51.485, longitude: -3.17),
    reportedAt: now.subtract(const Duration(minutes: 2)),
    updatedAt: now,
    expiresAt: now.add(const Duration(minutes: 15)),
    reporterId: 'tomtom-traffic',
    source: HazardSource.externalProvider,
    providerId: 'tomtom-traffic',
  );

  test(
    'requests a bounded alternative and retains guidance for review',
    () async {
      Map<String, Object?>? requestBody;
      final provider = RelayTrafficRerouteProvider(
        configuration: configuration,
        clock: () => now,
        idFactory: () => 'alternative-id',
        httpPost: (uri, {headers, body, encoding}) async {
          expect(uri.path, '/api/v1/traffic/reroutes');
          expect(
            headers?['x-tailendcharlie-capabilities'],
            contains('traffic-reroutes-v1'),
          );
          requestBody = Map<String, Object?>.from(
            jsonDecode(body! as String) as Map,
          );
          return http.Response(
            jsonEncode({
              'provider': 'tomtom-orbis',
              'calculatedAt': '2026-07-24T20:00:00Z',
              'incidentIds': ['tomtom-closure-1'],
              'reference': {
                'distanceMeters': 1000,
                'travelDurationSeconds': 180,
                'trafficDelaySeconds': 90,
                'points': [
                  {'latitude': 51.48, 'longitude': -3.18},
                  {'latitude': 51.49, 'longitude': -3.16},
                ],
                'maneuvers': <Object?>[],
              },
              'alternative': {
                'distanceMeters': 1200,
                'travelDurationSeconds': 140,
                'trafficDelaySeconds': 0,
                'points': [
                  {'latitude': 51.48, 'longitude': -3.18},
                  {'latitude': 51.486, 'longitude': -3.15},
                  {'latitude': 51.49, 'longitude': -3.16},
                ],
                'maneuvers': [
                  {
                    'latitude': 51.486,
                    'longitude': -3.15,
                    'type': 'turn',
                    'modifier': 'right',
                    'name': 'Newport Road',
                    'ref': 'A4161',
                    'drivingSide': 'left',
                  },
                ],
              },
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        },
      );

      final preview = await provider.preview(
        route: route,
        currentPosition: const GeoPoint(latitude: 51.48, longitude: -3.18),
        hazards: [closure],
      );

      expect(requestBody?['incidentIds'], ['tomtom-closure-1']);
      expect(requestBody?['avoidAreas'], hasLength(1));
      expect(preview.provider, 'tomtom-orbis');
      expect(preview.referenceDuration, const Duration(minutes: 3));
      expect(preview.alternativeDuration, const Duration(seconds: 140));
      expect(preview.durationDelta, const Duration(seconds: -40));
      expect(preview.trafficDelaySaved, const Duration(seconds: 90));
      expect(preview.route.name, contains('traffic alternative'));
      expect(preview.route.paths.single.points, hasLength(3));
      expect(preview.route.waypoints.last.name, 'Ferry');
      expect(preview.route.maneuvers.single.type, 'turn');
      expect(preview.route.maneuvers.single.drivingSide, 'left');
    },
  );

  test('does not request a reroute for an advisory incident', () async {
    var requested = false;
    final provider = RelayTrafficRerouteProvider(
      configuration: configuration,
      clock: () => now,
      httpPost: (uri, {headers, body, encoding}) async {
        requested = true;
        return http.Response('{}', 200);
      },
    );

    await expectLater(
      provider.preview(
        route: route,
        currentPosition: null,
        hazards: [closure.copyWith(severity: HazardSeverity.advisory)],
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('No current serious'),
        ),
      ),
    );
    expect(requested, isFalse);
  });

  test('surfaces the server-held provider configuration state', () async {
    final provider = RelayTrafficRerouteProvider(
      configuration: configuration,
      clock: () => now,
      httpPost: (uri, {headers, body, encoding}) async => http.Response(
        jsonEncode({
          'code': 'traffic_provider_unconfigured',
          'message': 'Live UK traffic rerouting is not configured.',
        }),
        503,
      ),
    );

    await expectLater(
      provider.preview(route: route, currentPosition: null, hazards: [closure]),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          'Live UK traffic rerouting is not configured.',
        ),
      ),
    );
  });

  test('suppresses the same incident only until its provider expiry', () {
    final suppression = TrafficRerouteSuppression.forHazards([closure]);
    final restored = TrafficRerouteSuppression.tryDecode(suppression.encode());

    expect(restored, isNotNull);
    expect(restored!.suppresses([closure], now), isTrue);
    expect(
      restored.suppresses([
        HazardReport(
          id: 'tomtom-new-closure',
          rideId: closure.rideId,
          type: closure.type,
          severity: closure.severity,
          position: closure.position,
          reportedAt: closure.reportedAt,
          updatedAt: closure.updatedAt,
          expiresAt: closure.expiresAt,
          reporterId: closure.reporterId,
          source: closure.source,
          providerId: closure.providerId,
        ),
      ], now),
      isFalse,
    );
    expect(
      restored.suppresses([
        closure,
      ], closure.expiresAt.add(const Duration(seconds: 1))),
      isFalse,
    );
    expect(TrafficRerouteSuppression.tryDecode('not-json'), isNull);
  });
}
