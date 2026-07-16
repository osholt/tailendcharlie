import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/services/basemap_configuration.dart';
import 'package:ride_relay/services/offline_tile_cache.dart';

void main() {
  test('provider gating defaults to route-only mode', () {
    expect(const BasemapConfiguration().isConfigured, isFalse);
    expect(const BasemapConfiguration().canDownloadOffline, isFalse);

    const onlineOnly = BasemapConfiguration(
      urlTemplate: 'https://tiles.example/{z}/{x}/{y}.png',
      attribution: 'Example Maps',
    );
    expect(onlineOnly.isConfigured, isTrue);
    expect(onlineOnly.canDownloadOffline, isFalse);
  });

  test('downloads a licensed route corridor and reuses stored tiles', () async {
    final directory = await Directory.systemTemp.createTemp('tile-cache-test');
    addTearDown(() => directory.delete(recursive: true));
    var requests = 0;
    final client = MockClient((request) async {
      requests += 1;
      return http.Response.bytes(
        const [0x89, 0x50, 0x4E, 0x47],
        200,
        headers: {
          'content-type': 'image/png',
          'cache-control': 'max-age=86400',
        },
      );
    });
    final cache = OfflineTileCache(
      rootDirectory: directory,
      configuration: const BasemapConfiguration(
        urlTemplate: 'https://tiles.example/{z}/{x}/{y}.png',
        attribution: 'Example Maps',
        cacheNamespace: 'example-v1',
        persistentCachingAllowed: true,
      ),
      httpClient: client,
    );
    final route = _route();

    final first = await cache.downloadRouteCorridor(
      route,
      minimumZoom: 3,
      maximumZoom: 3,
      corridorTileRadius: 0,
      maximumTiles: 5,
    );
    final second = await cache.downloadRouteCorridor(
      route,
      minimumZoom: 3,
      maximumZoom: 3,
      corridorTileRadius: 0,
      maximumTiles: 5,
    );

    expect(first.downloadedTiles, 1);
    expect(second.reusedTiles, 1);
    expect(requests, 1);
    cache.dispose();
  });

  test(
    'refuses downloads without explicit provider cache permission',
    () async {
      final directory = await Directory.systemTemp.createTemp('tile-gate-test');
      addTearDown(() => directory.delete(recursive: true));
      final cache = OfflineTileCache(
        rootDirectory: directory,
        configuration: const BasemapConfiguration(
          urlTemplate: 'https://tiles.example/{z}/{x}/{y}.png',
          attribution: 'Example Maps',
        ),
      );

      expect(
        () => cache.downloadRouteCorridor(_route()),
        throwsA(isA<OfflineTileConfigurationException>()),
      );
      cache.dispose();
    },
  );
}

ImportedRoute _route() => ImportedRoute(
  id: 'route',
  name: 'Route',
  importedAt: DateTime.utc(2026),
  sourceFileName: 'route.gpx',
  paths: const [
    RoutePath(
      kind: RoutePathKind.track,
      points: [GeoPoint(latitude: 53.3431, longitude: -1.7769)],
    ),
  ],
  waypoints: const [],
);
