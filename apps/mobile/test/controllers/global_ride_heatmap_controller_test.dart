import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ride_relay/controllers/global_ride_heatmap_controller.dart';
import 'package:ride_relay/domain/completed_ride.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/services/global_ride_heatmap.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(const {}));

  test('viewing is off and contribution is on by default', () async {
    final controller = await GlobalRideHeatmapController.load(
      client: _client((_) async => http.Response('{}', 500)),
      credentials: _MemoryCredentials(),
    );
    addTearDown(controller.dispose);

    expect(controller.visible, isFalse);
    expect(controller.consent, HeatmapContributionConsent.always);
    await controller.setVisible(true);
    expect(controller.consent, HeatmapContributionConsent.always);
  });

  test(
    'keeps cached public coverage visible when refresh is offline',
    () async {
      SharedPreferences.setMockInitialValues({
        GlobalRideHeatmapController.cacheKey: jsonEncode({
          'type': 'FeatureCollection',
          'snapshotVersion': 'one',
          'snapshotDate': '2026-08-16',
          'features': [
            {
              'type': 'Feature',
              'properties': {'weight': 0.5},
              'geometry': {
                'type': 'Point',
                'coordinates': [-2.5, 51.4],
              },
            },
          ],
        }),
      });
      final controller = await GlobalRideHeatmapController.load(
        client: _client((_) async => throw Exception('offline')),
        credentials: _MemoryCredentials(),
      );
      addTearDown(controller.dispose);

      await controller.refresh(
        west: -3,
        south: 51,
        east: -2,
        north: 52,
        zoom: 12,
      );

      expect(controller.status, GlobalHeatmapStatus.offline);
      expect(controller.snapshot.cells, hasLength(1));
    },
  );

  test(
    'contribution is once per saved ride and revocation clears consent',
    () async {
      var registrations = 0;
      var contributions = 0;
      var revocations = 0;
      final credentials = _MemoryCredentials();
      final controller = await GlobalRideHeatmapController.load(
        client: _client((request) async {
          if (request.method == 'DELETE') {
            revocations += 1;
            return http.Response('{"removed":true}', 200);
          }
          if (request.url.path.endsWith('/contributors')) {
            registrations += 1;
            return http.Response('{}', 201);
          }
          contributions += 1;
          return http.Response('{"accepted":true}', 200);
        }),
        credentials: credentials,
      );
      addTearDown(controller.dispose);
      await controller.setConsent(HeatmapContributionConsent.always);
      await controller.setTrimMeters(0);

      expect(await controller.contribute(_ride()), isTrue);
      expect(await controller.contribute(_ride()), isTrue);
      expect(registrations, 1);
      expect(contributions, 1);

      await controller.stopAndRemoveContributions();
      expect(revocations, 1);
      expect(credentials.value, isNull);
      expect(controller.consent, HeatmapContributionConsent.never);

      await controller.setConsent(HeatmapContributionConsent.always);
      expect(await controller.contribute(_ride()), isTrue);
      expect(contributions, 2);
    },
  );

  test('saved history is combined into one contribution', () async {
    var registrations = 0;
    var contributions = 0;
    late Map<String, Object?> upload;
    final controller = await GlobalRideHeatmapController.load(
      client: _client((request) async {
        if (request.url.path.endsWith('/contributors')) {
          registrations += 1;
          return http.Response('{}', 201);
        }
        contributions += 1;
        upload = Map<String, Object?>.from(jsonDecode(request.body) as Map);
        return http.Response('{"accepted":true}', 200);
      }),
      credentials: _MemoryCredentials(),
    );
    addTearDown(controller.dispose);
    await controller.setTrimMeters(0);

    final result = await controller.contributeHistory([
      _ride(),
      _ride(rideId: 'ride-two', longitudeOffset: 0.02),
      _ride(
        rideId: 'deleted-ride',
        longitudeOffset: 0.04,
      ).copyWith(libraryStatus: RideLibraryStatus.deleted),
    ]);

    expect(result.rideCount, 2);
    expect(result.cellCount, greaterThan(0));
    expect(registrations, 1);
    expect(contributions, 1);
    expect(upload.keys, {
      'schemaVersion',
      'uploadId',
      'trimMetersAtEachEnd',
      'cells',
    });
    expect((upload['cells']! as List).length, result.cellCount);

    final repeated = await controller.contributeHistory([
      _ride(),
      _ride(rideId: 'ride-two', longitudeOffset: 0.02),
    ]);
    expect(repeated.shared, isFalse);
    expect(contributions, 1);
  });
}

GlobalHeatmapClient _client(
  Future<http.Response> Function(http.Request request) handler,
) => GlobalHeatmapClient(
  baseUri: Uri.parse('https://relay.example/api/'),
  client: MockClient(handler),
);

class _MemoryCredentials implements HeatmapCredentialStore {
  HeatmapCredential? value;

  @override
  Future<void> delete() async => value = null;

  @override
  Future<HeatmapCredential?> read() async => value;

  @override
  Future<void> write(HeatmapCredential credential) async => value = credential;
}

CompletedRide _ride({String rideId = 'ride-one', double longitudeOffset = 0}) =>
    CompletedRide(
      rideId: rideId,
      rideCode: '123456',
      rideName: null,
      localDisplayName: 'Oliver',
      localRole: RideRole.rider,
      startedAt: DateTime.utc(2026, 8, 16, 10),
      endedAt: DateTime.utc(2026, 8, 16, 11),
      archivedAt: DateTime.utc(2026, 8, 16, 11),
      riderCount: 1,
      eventCount: 10,
      totalDistanceMeters: 5000,
      markerSessions: const [],
      plannedRoute: null,
      traveledRoute: ImportedRoute(
        id: 'track',
        name: 'Track',
        importedAt: DateTime.utc(2026, 8, 16),
        sourceFileName: 'track.gpx',
        paths: [
          RoutePath(
            kind: RoutePathKind.track,
            points: [
              for (var sample = 0; sample <= 10; sample += 1)
                GeoPoint(
                  latitude: 51.45 + sample * 0.001,
                  longitude: -2.59 + longitudeOffset + sample * 0.001,
                ),
            ],
          ),
        ],
        waypoints: const [],
      ),
    );
