import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as ml;
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/services/basemap_configuration.dart';
import 'package:ride_relay/services/maplibre_offline_manager.dart';
import 'package:ride_relay/services/offline_tile_cache.dart';

void main() {
  const configuration = BasemapConfiguration(
    styleUrl: 'https://maps.example.test/styles/ride-relay/style.json',
    attribution: '© OpenStreetMap contributors',
    cacheNamespace: 'open-map-v1',
    persistentCachingAllowed: true,
  );

  test('plans bounded native regions and completes a download', () async {
    final api = _FakeOfflineApi();
    final manager = MapLibreOfflineManager(
      configuration: configuration,
      api: api,
      prepareStyle: (_) async {},
    );

    final summary = await manager.downloadRouteRegion(_route());

    expect(summary.cancelled, isFalse);
    expect(summary.downloadedTiles, 12);
    expect(summary.totalTiles, 12);
    expect(api.tileLimit, 20000);
    expect(api.lastDefinition?.mapStyleUrl, configuration.styleUrl);
  });

  test(
    'full sparse tour has continuous 2 km cover and country-to-riding zoom in both themes',
    () {
      final route = _longRoute();
      final manager = MapLibreOfflineManager(
        configuration: BasemapConfiguration.fromEnvironment(),
      );
      final definitions = manager.definitions(route);
      expect(definitions.length, greaterThan(20));
      expect(definitions.map((d) => d.mapStyleUrl).toSet(), {
        BasemapConfiguration.defaultLightStyleUrl,
        BasemapConfiguration.defaultDarkStyleUrl,
      });
      for (final definition in definitions) {
        expect(definition.minZoom, 0);
        expect(definition.maxZoom, 18);
        expect(
          definition.bounds.northeast.latitude -
              definition.bounds.southwest.latitude,
          lessThan(.3),
        );
      }
      final day = definitions.where(
        (d) => d.mapStyleUrl == BasemapConfiguration.defaultLightStyleUrl,
      );
      for (var i = 0; i <= 1000; i++) {
        final lat = 43 + 7 * i / 1000;
        final lon = 1 + i / 1000;
        // Test the edges of the deviation corridor, not just the GPX vertices.
        for (final offset in [-.0179, 0, .0179]) {
          expect(
            day.any((d) => d.bounds.contains(ml.LatLng(lat + offset, lon))),
            isTrue,
            reason: 'latitude coverage at $i',
          );
          expect(
            day.any(
              (d) => d.bounds.contains(
                ml.LatLng(lat, lon + offset / math.cos(lat * math.pi / 180)),
              ),
            ),
            isTrue,
            reason: 'longitude coverage at $i',
          );
        }
      }
    },
  );

  test(
    'ready status survives manager recreation and complete regions are reused',
    () async {
      final api = _FakeOfflineApi();
      final manager = MapLibreOfflineManager(
        configuration: configuration,
        api: api,
        prepareStyle: (_) async {},
      );
      expect(await manager.isRouteReady(_route()), isFalse);
      await manager.downloadRouteRegion(_route());
      final reopened = MapLibreOfflineManager(
        configuration: configuration,
        api: api,
        prepareStyle: (_) async {},
      );
      expect(await reopened.isRouteReady(_route()), isTrue);
      final count = api.downloadCalls;
      final summary = await reopened.downloadRouteRegion(_route());
      expect(api.downloadCalls, count);
      expect(summary.reusedTiles, 12);
      expect(summary.downloadedTiles, 0);
      api.complete = false;
      expect(await reopened.isRouteReady(_route()), isFalse);
    },
  );

  test('failed download is removed and never advertised as ready', () async {
    final api = _FakeOfflineApi()..fail = true;
    final manager = MapLibreOfflineManager(
      configuration: configuration,
      api: api,
      prepareStyle: (_) async {},
    );
    await expectLater(
      manager.downloadRouteRegion(_route()),
      throwsA(isA<OfflineTileDownloadException>()),
    );
    expect(api.deleted, [3]);
    expect(await manager.isRouteReady(_route()), isFalse);
  });

  test(
    'cancelling an unfinished region removes it and does not claim completion',
    () async {
      final api = _FakeOfflineApi()..wait = true;
      final manager = MapLibreOfflineManager(
        configuration: configuration,
        api: api,
        prepareStyle: (_) async {},
      );
      final cancellation = TileDownloadCancellationToken();
      final download = manager.downloadRouteRegion(
        _route(),
        cancellationToken: cancellation,
      );
      await api.started.future;
      cancellation.cancel();
      expect((await download).cancelled, isTrue);
      expect(api.deleted, [3]);
      expect(await manager.isRouteReady(_route()), isFalse);
    },
  );

  test('clear removes only this provider namespace', () async {
    final api = _FakeOfflineApi()
      ..storedRegions.addAll([
        _region(1, 'open-map-v1'),
        _region(2, 'other-map'),
      ]);
    final manager = MapLibreOfflineManager(
      configuration: configuration,
      api: api,
      prepareStyle: (_) async {},
    );

    await manager.clear();

    expect(api.deleted, [1]);
    expect(api.ambientCleared, isTrue);
  });

  test('clear is still allowed after download permission is revoked', () async {
    final api = _FakeOfflineApi()..storedRegions.add(_region(1, 'open-map-v1'));
    final manager = MapLibreOfflineManager(
      configuration: const BasemapConfiguration(
        styleUrl: 'https://maps.example.test/styles/ride-relay/style.json',
        attribution: '© OpenStreetMap contributors',
        cacheNamespace: 'open-map-v1',
        persistentCachingAllowed: false,
      ),
      api: api,
      prepareStyle: (_) async {},
    );

    await manager.clear();

    expect(api.deleted, [1]);
  });

  test('rejects a region that exceeds its tile safety cap', () {
    expect(
      () => const MapLibreOfflinePlanner().plan(
        _route(),
        minimumZoom: 10,
        maximumZoom: 15,
        maximumTiles: 1,
      ),
      throwsA(isA<Exception>()),
    );
  });
}

ImportedRoute _route() => ImportedRoute(
  id: 'route-1',
  name: 'Test route',
  importedAt: DateTime.utc(2026, 7, 16),
  sourceFileName: 'route.gpx',
  paths: const [
    RoutePath(
      kind: RoutePathKind.track,
      points: [
        GeoPoint(latitude: 51, longitude: -1),
        GeoPoint(latitude: 51.002, longitude: -0.998),
      ],
    ),
  ],
  waypoints: const [],
);

ml.OfflineRegion _region(int id, String namespace) => ml.OfflineRegion(
  id: id,
  definition: ml.OfflineRegionDefinition(
    bounds: ml.LatLngBounds(
      southwest: const ml.LatLng(51, -1),
      northeast: const ml.LatLng(51.1, -0.9),
    ),
    mapStyleUrl: 'https://maps.example.test/style.json',
    minZoom: 10,
    maxZoom: 15,
  ),
  metadata: {'rideRelayNamespace': namespace},
);

class _FakeOfflineApi implements MapLibreOfflineApi {
  int? tileLimit;
  int downloadCalls = 0;
  bool complete = true;
  bool fail = false;
  bool wait = false;
  final started = Completer<void>();
  ml.OfflineRegionDefinition? lastDefinition;
  final storedRegions = <ml.OfflineRegion>[];
  final deleted = <int>[];
  bool ambientCleared = false;

  @override
  Future<void> setTileCountLimit(int limit) async => tileLimit = limit;

  @override
  Future<ml.OfflineRegion> download(
    ml.OfflineRegionDefinition definition, {
    required Map<String, dynamic> metadata,
    required void Function(ml.DownloadRegionStatus status) onEvent,
  }) async {
    lastDefinition = definition;
    downloadCalls++;
    onEvent(
      ml.InProgress(
        1,
        completedResourceCount: 12,
        requiredResourceCount: 12,
        completedResourceSize: 2048,
      ),
    );
    final region = ml.OfflineRegion(
      id: downloadCalls + 2,
      definition: definition,
      metadata: metadata,
    );
    storedRegions.add(region);
    if (!started.isCompleted) started.complete();
    if (fail) {
      onEvent(ml.Error(PlatformException(code: 'offline')));
    } else if (!wait) {
      onEvent(ml.Success());
    }
    return region;
  }

  @override
  Future<List<ml.OfflineRegion>> regions() async => List.of(storedRegions);

  @override
  Future<void> pause(int regionId) async {}

  @override
  Future<void> delete(int regionId) async {
    deleted.add(regionId);
    storedRegions.removeWhere((r) => r.id == regionId);
  }

  @override
  Future<ml.OfflineRegionStatus> status(int regionId) async =>
      ml.OfflineRegionStatus(
        completedResourceCount: 12,
        requiredResourceCount: 12,
        completedResourceSize: 2048,
        isComplete: complete && !fail && !wait,
        downloadProgress: complete ? 1 : .5,
      );

  @override
  Future<void> clearAmbient() async => ambientCleared = true;
}

ImportedRoute _longRoute() => ImportedRoute(
  id: 'tour',
  name: 'Sparse touring track',
  importedAt: DateTime.utc(2026),
  sourceFileName: 'tour.gpx',
  waypoints: const [],
  paths: const [
    RoutePath(
      kind: RoutePathKind.track,
      points: [
        GeoPoint(latitude: 43, longitude: 1),
        GeoPoint(latitude: 50, longitude: 2),
      ],
    ),
  ],
);
