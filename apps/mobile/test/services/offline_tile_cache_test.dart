import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/services/basemap_configuration.dart';
import 'package:ride_relay/services/offline_tile_cache.dart';

void main() {
  test('an unconfigured basemap still cannot download', () {
    // Caching permission is no longer the thing that stops this - that is now on
    // by default (#274) - but a basemap with no style or template at all still has
    // nothing to fetch.
    expect(const BasemapConfiguration().isConfigured, isFalse);
    expect(const BasemapConfiguration().canDownloadOffline, isFalse);
  });

  test('caching permission still gates downloads when withheld', () {
    // The guard itself is unchanged; only its default flipped. A build that turns
    // caching off must still be refused.
    const withheld = BasemapConfiguration(
      urlTemplate: 'https://tiles.example/{z}/{x}/{y}.png',
      attribution: 'Example Maps',
      persistentCachingAllowed: false,
    );
    expect(withheld.isConfigured, isTrue);
    expect(withheld.canDownloadOffline, isFalse);
  });

  test('a blank cache namespace still gates downloads', () {
    // The namespace exists so a provider change cannot serve the previous
    // provider's tiles out of the old cache, so an empty one is not usable.
    const noNamespace = BasemapConfiguration(
      urlTemplate: 'https://tiles.example/{z}/{x}/{y}.png',
      attribution: 'Example Maps',
      cacheNamespace: '',
    );
    expect(noNamespace.canDownloadOffline, isFalse);
  });

  test('app environment defaults to an online MapLibre basemap', () {
    final configuration = BasemapConfiguration.fromEnvironment();

    expect(configuration.usesMapLibre, isTrue);
    expect(configuration.styleUrl, contains('openfreemap.org'));
    // On by default since the owner approved caching for this provider (#274).
    // The previous default of off was itself a bug on an offline-first app: with
    // nothing cached, a rural signal gap leaves no basemap and nothing to fall
    // back on, which is what a tester reported as a dot and a trail on blank
    // background (#281).
    expect(
      configuration.canDownloadOffline,
      isTrue,
      reason: 'an offline-first app must be able to keep the tiles it fetched',
    );
    expect(configuration.cacheNamespace, isNotEmpty);
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

  test('refuses downloads without explicit provider cache permission', () async {
    final directory = await Directory.systemTemp.createTemp('tile-gate-test');
    addTearDown(() => directory.delete(recursive: true));
    final cache = OfflineTileCache(
      rootDirectory: directory,
      configuration: const BasemapConfiguration(
        urlTemplate: 'https://tiles.example/{z}/{x}/{y}.png',
        attribution: 'Example Maps',
        // Withheld explicitly. This used to be the default; the guard is what is
        // being tested, not the default (#274).
        persistentCachingAllowed: false,
      ),
    );

    expect(
      () => cache.downloadRouteCorridor(_route()),
      throwsA(isA<OfflineTileConfigurationException>()),
    );
    cache.dispose();
  });
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
