import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:vector_map_tiles/vector_map_tiles.dart' as vmt;
import 'package:vector_tile_renderer/vector_tile_renderer.dart' as vtr;

import '../domain/imported_route.dart';
import 'basemap_configuration.dart';
import 'flutter_vector_resource_cache.dart';
import 'flutter_vector_style.dart';
import 'maplibre_offline_manager.dart';
import 'offline_tile_cache.dart';
import 'offline_tile_planner.dart';

typedef OfflineVectorStyleLoader =
    Future<vmt.Style> Function(
      BasemapConfiguration configuration,
      FlutterVectorResourceCache cache,
      Set<String> resources,
    );

Future<vmt.Style> _load(
  BasemapConfiguration configuration,
  FlutterVectorResourceCache cache,
  Set<String> resources,
) => readFlutterVectorStyle(
  configuration,
  resourceCache: cache,
  resources: resources,
  requireWrite: true,
);

/// iOS live navigation uses Flutter, not MapLibre. Its completed packs must be
/// consumed by that renderer after a process restart, not just by native maps.
class FlutterVectorOfflineManager extends MapLibreOfflineManager {
  const FlutterVectorOfflineManager({
    required super.configuration,
    this.cache,
    this.loadStyle = _load,
  });
  final FlutterVectorResourceCache? cache;
  final OfflineVectorStyleLoader loadStyle;

  Future<FlutterVectorResourceCache> _open() async =>
      cache ??
      await FlutterVectorResourceCache.open(configuration.cacheNamespace);

  String _manifestKey(ImportedRoute route) => FlutterVectorResourceCache.key(
    jsonEncode({
      'flutterCorridor': 1,
      'style': configuration.lightStyleUrl,
      'dark': configuration.darkStyleUrl,
      'restrained': configuration.restrainedLightStyle,
      'paths': [
        for (final path in route.paths)
          [
            for (final p in path.points) [p.latitude, p.longitude],
          ],
      ],
    }),
  );

  @override
  Future<bool> isRouteReady(ImportedRoute route) async {
    final store = await _open();
    final data = await store.read(_manifestKey(route));
    if (data == null) return false;
    try {
      final keys = (jsonDecode(utf8.decode(data)) as List).cast<String>();
      if (keys.isEmpty) return false;
      for (final key in keys) {
        if (await store.read(key) == null) return false;
      }
      return true;
    } on Object {
      return false;
    }
  }

  @override
  Future<TileDownloadSummary> downloadRouteRegion(
    ImportedRoute route, {
    int minimumZoom = 0,
    int maximumZoom = 18,
    int maximumTiles = 20000,
    int maximumBytes = 500 * 1024 * 1024,
    TileDownloadProgressCallback? onProgress,
    TileDownloadCancellationToken? cancellationToken,
  }) async {
    if (!configuration.canDownloadOffline) {
      throw const OfflineTileConfigurationException(
        'Offline caching is not enabled for this provider.',
      );
    }
    final store = await _open();
    final resources = <String>{};
    final styles = <vmt.Style>[];
    for (final dark in [false, true]) {
      if (cancellationToken?.isCancelled ?? false) break;
      final style = await loadStyle(
        configuration.forBrightness(
          dark: dark,
          restrainedLightStyle: configuration.restrainedLightStyle,
        ),
        store,
        resources,
      );
      if (style.sprites != null) await style.sprites!.atlasProvider();
      styles.add(style);
    }
    final tasks = <(vmt.VectorTileProvider, vmt.TileIdentity)>[];
    for (final style in styles) {
      for (final provider in style.providers.tileProviderBySource.values) {
        final maxZoom = math.min(
          math.min(maximumZoom, configuration.maximumNativeZoom),
          provider.maximumZoom,
        );
        final minZoom = math.max(minimumZoom, provider.minimumZoom);
        final regions = planner.corridor(
          route,
          minimumZoom: minZoom,
          maximumZoom: maxZoom,
          maximumTiles: maximumTiles,
        );
        final tiles = <vmt.TileIdentity>{};
        for (final region in regions) {
          for (var z = minZoom; z <= maxZoom; z++) {
            final nw = _tile(
              region.bounds.northeast.latitude,
              region.bounds.southwest.longitude,
              z,
            );
            final se = _tile(
              region.bounds.southwest.latitude,
              region.bounds.northeast.longitude,
              z,
            );
            for (var x = nw.x; x <= se.x; x++) {
              for (var y = nw.y; y <= se.y; y++) {
                tiles.add(vmt.TileIdentity(z, x, y));
              }
            }
          }
        }
        tasks.addAll(tiles.map((tile) => (provider, tile)));
      }
    }
    // Both appearances may reference identical URLs; the resource cache reuses
    // those bytes. Bound task work as well as unique tiles for custom styles.
    if (tasks.length > maximumTiles * 2) {
      throw OfflineTileLimitException(maximumTiles);
    }
    var completed = 0, bytes = 0;
    var next = 0;
    Object? failure;
    Future<void> worker() async {
      while (next < tasks.length &&
          failure == null &&
          !(cancellationToken?.isCancelled ?? false)) {
        final task = tasks[next++];
        try {
          final data = await task.$1
              .provide(task.$2)
              .timeout(const Duration(seconds: 30));
          if (task.$1.type == vmt.TileProviderType.vector) {
            vtr.VectorTileReader().read(data);
          }
          bytes += data.length;
          if (bytes > maximumBytes) {
            throw const OfflineTileDownloadException(
              'Offline download reached its 500 MB limit.',
            );
          }
          completed++;
          onProgress?.call(
            TileDownloadProgress(
              completedTiles: completed,
              totalTiles: tasks.length,
              downloadedBytes: bytes,
            ),
          );
        } on Object catch (error) {
          failure = error;
        }
      }
    }

    await Future.wait(List.generate(4, (_) => worker()));
    if (failure != null) throw failure!;
    final cancelled = cancellationToken?.isCancelled ?? false;
    if (!cancelled) {
      if (tasks.isEmpty || resources.isEmpty) {
        throw const OfflineTileDownloadException(
          'No offline map resources were saved.',
        );
      }
      await store.write(
        _manifestKey(route),
        Uint8List.fromList(utf8.encode(jsonEncode(resources.toList()))),
      );
    }
    return TileDownloadSummary(
      totalTiles: tasks.length,
      downloadedTiles: completed,
      reusedTiles: 0,
      downloadedBytes: bytes,
      cancelled: cancelled,
    );
  }

  @override
  Future<void> clear() async => (await _open()).clear();
  @override
  Future<void> clearAll() => clear();
}

vmt.TileIdentity _tile(double latitude, double longitude, int z) {
  final count = 1 << z;
  final r = latitude * math.pi / 180;
  return vmt.TileIdentity(
    z,
    ((longitude + 180) / 360 * count).floor().clamp(0, count - 1),
    ((1 - math.log(math.tan(r) + 1 / math.cos(r)) / math.pi) / 2 * count)
        .floor()
        .clamp(0, count - 1),
  );
}
