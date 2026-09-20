import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart' as vmt;
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/services/basemap_configuration.dart';
import 'package:ride_relay/services/flutter_vector_offline_manager.dart';
import 'package:ride_relay/services/flutter_vector_resource_cache.dart';
import 'package:ride_relay/services/flutter_vector_style.dart';
import 'package:ride_relay/services/map_style_repository.dart';
import 'package:ride_relay/services/offline_tile_cache.dart';

const configuration = BasemapConfiguration(
  styleUrl: 'https://maps.test/style.json',
  darkStyleUrl: 'https://maps.test/dark.json',
  attribution: 'Test maps',
  maximumNativeZoom: 3,
);
final route = ImportedRoute(
  id: 'route',
  name: 'Route',
  importedAt: DateTime.utc(2026),
  sourceFileName: 'test.gpx',
  paths: const [
    RoutePath(
      kind: RoutePathKind.route,
      points: [
        GeoPoint(latitude: 51.4, longitude: -2.5),
        GeoPoint(latitude: 51.6, longitude: -2.3),
      ],
    ),
  ],
  waypoints: const [],
);
final styleDocument = jsonEncode({
  'version': 8,
  'sprite': 'https://maps.test/sprite',
  'sources': {
    'test': {'type': 'vector', 'url': 'https://maps.test/tiles.json'},
  },
  'layers': [
    {
      'id': 'background',
      'type': 'background',
      'paint': {'background-color': '#ffffff'},
    },
  ],
});
final tileBytes = Uint8List.fromList([
  26,
  11,
  10,
  4,
  116,
  101,
  115,
  116,
  40,
  128,
  32,
  120,
  2,
]);

void main() {
  late Directory directory;
  late FlutterVectorResourceCache cache;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('vector-offline');
    cache = FlutterVectorResourceCache(directory);
  });
  tearDown(() async => directory.delete(recursive: true));

  Future<vmt.Style> loader(
    BasemapConfiguration config,
    FlutterVectorResourceCache store,
    Set<String> resources,
  ) => readFlutterVectorStyle(
    config,
    resolution: MapStyleResolution(styleDocument, MapStyleOutcome.live),
    resourceCache: store,
    resources: resources,
    requireWrite: true,
    clientFactory: () => MockClient((request) async {
      if (request.url.path == '/tiles.json') {
        return http.Response(
          jsonEncode({
            'tiles': ['https://maps.test/{z}/{x}/{y}.pbf'],
            'minzoom': 0,
            'maxzoom': 3,
          }),
          200,
        );
      }
      if (request.url.path.endsWith('.json')) return http.Response('{}', 200);
      if (request.url.path.endsWith('.png')) {
        return http.Response.bytes(
          base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aD1sAAAAASUVORK5CYII=',
          ),
          200,
        );
      }
      return http.Response.bytes(tileBytes, 200);
    }),
  );

  test(
    'downloaded iOS corridor reopens through the real Flutter providers with networking disabled',
    () async {
      final manager = FlutterVectorOfflineManager(
        configuration: configuration,
        cache: cache,
        loadStyle: loader,
      );
      expect(await manager.isRouteReady(route), false);
      final result = await manager.downloadRouteRegion(route);
      expect(result.cancelled, false);
      expect(result.totalTiles, greaterThan(2));
      final reopened = FlutterVectorResourceCache(directory);
      final restarted = FlutterVectorOfflineManager(
        configuration: configuration,
        cache: reopened,
      );
      expect(await restarted.isRouteReady(route), true);
      var networkRequests = 0;
      for (final dark in [false, true]) {
        final loaded = await readFlutterVectorStyle(
          configuration.forBrightness(dark: dark),
          resourceCache: reopened,
          clientFactory: () => MockClient((_) async {
            networkRequests++;
            throw const SocketException('Airplane mode');
          }),
        );
        expect(
          await loaded.providers.get('test').provide(vmt.TileIdentity(3, 3, 2)),
          tileBytes,
        );
        expect(await loaded.sprites!.atlasProvider(), isNotEmpty);
      }
      expect(
        networkRequests,
        0,
        reason:
            'Style, TileJSON, tile and sprite must all come from the downloaded pack.',
      );
      final tileKey = FlutterVectorResourceCache.key(
        'https://maps.test/3/3/2.pbf',
      );
      await reopened.file(tileKey).delete();
      expect(
        await restarted.isRouteReady(route),
        false,
        reason: 'A manifest alone cannot establish coverage.',
      );
    },
  );

  test('cancelled pack is not marked ready and retry completes it', () async {
    final manager = FlutterVectorOfflineManager(
      configuration: configuration,
      cache: cache,
      loadStyle: loader,
    );
    final token = TileDownloadCancellationToken();
    final result = await manager.downloadRouteRegion(
      route,
      cancellationToken: token,
      onProgress: (_) => token.cancel(),
    );
    expect(result.cancelled, true);
    expect(await manager.isRouteReady(route), false);
    await manager.downloadRouteRegion(route);
    expect(await manager.isRouteReady(route), true);
    await manager.clear();
    expect(await manager.isRouteReady(route), false);
  });

  test(
    'failed resources and exceeded disk budget cannot produce a ready pack',
    () async {
      final tiny = FlutterVectorResourceCache(directory, maximumBytes: 20);
      final manager = FlutterVectorOfflineManager(
        configuration: configuration,
        cache: tiny,
        loadStyle: loader,
      );
      await expectLater(manager.downloadRouteRegion(route), throwsA(anything));
      expect(await manager.isRouteReady(route), false);
      final client = CachedVectorHttpClient(
        MockClient((_) async => http.Response('failure', 500)),
        cache,
      );
      final response = await client.get(Uri.parse('https://maps.test/error'));
      expect(response.statusCode, 500);
      expect(
        await cache.read(
          FlutterVectorResourceCache.key('https://maps.test/error'),
        ),
        isNull,
      );
      client.close();
    },
  );
}
