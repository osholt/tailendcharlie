import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as ml;

import '../domain/imported_route.dart';
import 'basemap_configuration.dart';
import 'map_style_repository.dart';
import 'offline_tile_cache.dart';
import 'offline_tile_planner.dart';

abstract interface class MapLibreOfflineApi {
  Future<void> setTileCountLimit(int limit);

  Future<ml.OfflineRegion> download(
    ml.OfflineRegionDefinition definition, {
    required Map<String, dynamic> metadata,
    required void Function(ml.DownloadRegionStatus status) onEvent,
  });

  Future<List<ml.OfflineRegion>> regions();

  Future<ml.OfflineRegionStatus> status(int regionId);

  Future<void> pause(int regionId);

  Future<void> delete(int regionId);

  Future<void> clearAmbient();
}

class NativeMapLibreOfflineApi implements MapLibreOfflineApi {
  const NativeMapLibreOfflineApi();

  @override
  Future<void> setTileCountLimit(int limit) async {
    await ml.setOfflineTileCountLimit(limit);
  }

  @override
  Future<ml.OfflineRegion> download(
    ml.OfflineRegionDefinition definition, {
    required Map<String, dynamic> metadata,
    required void Function(ml.DownloadRegionStatus status) onEvent,
  }) => ml.downloadOfflineRegion(
    definition,
    metadata: metadata,
    onEvent: onEvent,
  );

  @override
  Future<List<ml.OfflineRegion>> regions() => ml.getListOfRegions();

  @override
  Future<ml.OfflineRegionStatus> status(int regionId) =>
      ml.getOfflineRegionStatus(regionId);

  @override
  Future<void> pause(int regionId) => ml.pauseOfflineRegionDownload(regionId);

  @override
  Future<void> delete(int regionId) async {
    await ml.deleteOfflineRegion(regionId);
  }

  @override
  Future<void> clearAmbient() => ml.clearAmbientCache();
}

class MapLibreOfflinePlan {
  const MapLibreOfflinePlan({required this.bounds, required this.tileCount});

  final ml.LatLngBounds bounds;
  final int tileCount;
}

class MapLibreOfflinePlanner {
  const MapLibreOfflinePlanner();

  /// Short, overlapping rectangles follow the route instead of downloading
  /// the empty interior of a long tour's bounding box. Sparse GPX segments are
  /// subdivided, so neither their middle nor the off-route buffer has gaps.
  List<MapLibreOfflinePlan> corridor(
    ImportedRoute route, {
    int minimumZoom = 0,
    int maximumZoom = 14,
    int maximumTiles = 20000,
    double bufferMeters = 2000,
  }) {
    if (minimumZoom < 0 ||
        maximumZoom > 22 ||
        minimumZoom > maximumZoom ||
        maximumTiles < 1 ||
        !bufferMeters.isFinite ||
        bufferMeters < 0) {
      throw ArgumentError('Invalid offline corridor limits.');
    }
    final result = <MapLibreOfflinePlan>[];
    final tiles = <(int, int, int)>{};
    var chunk = <GeoPoint>[];
    var length = 0.0;
    void flush() {
      if (chunk.isEmpty) return;
      var south = chunk.first.latitude;
      var north = south;
      var west = chunk.first.longitude;
      var east = west;
      for (final point in chunk) {
        south = math.min(south, point.latitude);
        north = math.max(north, point.latitude);
        west = math.min(west, point.longitude);
        east = math.max(east, point.longitude);
      }
      final latPadding = bufferMeters / 110000;
      final lonPadding =
          latPadding /
          math.cos(math.max(south.abs(), north.abs()) * math.pi / 180);
      south = (south - latPadding).clamp(-85.05112878, 85.05112878);
      north = (north + latPadding).clamp(-85.05112878, 85.05112878);
      west = (west - lonPadding).clamp(-180.0, 180.0);
      east = (east + lonPadding).clamp(-180.0, 180.0);
      var count = 0;
      for (var zoom = minimumZoom; zoom <= maximumZoom; zoom++) {
        final nw = _project(north, west, zoom);
        final se = _project(south, east, zoom);
        for (var x = nw.$1; x <= se.$1; x++) {
          for (var y = nw.$2; y <= se.$2; y++) {
            tiles.add((zoom, x, y));
            count++;
            if (tiles.length > maximumTiles) {
              throw OfflineTileLimitException(maximumTiles);
            }
          }
        }
      }
      result.add(
        MapLibreOfflinePlan(
          bounds: ml.LatLngBounds(
            southwest: ml.LatLng(south, west),
            northeast: ml.LatLng(north, east),
          ),
          tileCount: count,
        ),
      );
      if (result.length > 200) {
        throw const OfflineTileConfigurationException(
          'Split this tour into daily routes before downloading maps.',
        );
      }
      chunk = [];
      length = 0;
    }

    for (final path in route.paths) {
      GeoPoint? previous;
      for (final point in path.points) {
        if (!point.latitude.isFinite ||
            !point.longitude.isFinite ||
            point.latitude.abs() > 85.05112878 ||
            point.longitude.abs() > 180) {
          throw const OfflineTileConfigurationException(
            'The route has invalid map coordinates.',
          );
        }
        if (previous == null) {
          chunk.add(point);
        } else {
          if ((point.longitude - previous.longitude).abs() > 180) {
            throw const OfflineTileConfigurationException(
              'Split routes at the antimeridian before downloading maps.',
            );
          }
          final dLat = (point.latitude - previous.latitude) * 111320;
          final dLon =
              (point.longitude - previous.longitude) *
              111320 *
              math.cos((point.latitude + previous.latitude) * math.pi / 360);
          final distance = math.sqrt(dLat * dLat + dLon * dLon);
          final steps = math.max(1, (distance / 2000).ceil());
          for (var step = 1; step <= steps; step++) {
            final next = GeoPoint(
              latitude:
                  previous.latitude +
                  (point.latitude - previous.latitude) * step / steps,
              longitude:
                  previous.longitude +
                  (point.longitude - previous.longitude) * step / steps,
            );
            chunk.add(next);
            length += distance / steps;
            if (length >= 15000) {
              flush();
              chunk.add(next);
            }
          }
        }
        previous = point;
      }
      flush();
    }
    if (result.isEmpty) {
      throw const OfflineTileConfigurationException(
        'The route has no map points to download.',
      );
    }
    return result;
  }

  MapLibreOfflinePlan plan(
    ImportedRoute route, {
    required int minimumZoom,
    required int maximumZoom,
    required int maximumTiles,
  }) {
    if (minimumZoom < 0 || maximumZoom > 22 || minimumZoom > maximumZoom) {
      throw ArgumentError('Zoom range must be ordered and within 0..22.');
    }
    final points = route.allPoints.toList(growable: false);
    if (points.isEmpty) {
      throw const OfflineTileConfigurationException(
        'The route has no map points to download.',
      );
    }
    var south = points.first.latitude;
    var north = points.first.latitude;
    var west = points.first.longitude;
    var east = points.first.longitude;
    for (final point in points.skip(1)) {
      south = math.min(south, point.latitude);
      north = math.max(north, point.latitude);
      west = math.min(west, point.longitude);
      east = math.max(east, point.longitude);
    }
    if (east - west > 180) {
      throw const OfflineTileConfigurationException(
        'Routes crossing the antimeridian must be split before download.',
      );
    }
    final latitudePadding = math.max(0.002, (north - south) * 0.08);
    final longitudePadding = math.max(0.002, (east - west) * 0.08);
    south = (south - latitudePadding).clamp(-85.05112878, 85.05112878);
    north = (north + latitudePadding).clamp(-85.05112878, 85.05112878);
    west = (west - longitudePadding).clamp(-180.0, 180.0);
    east = (east + longitudePadding).clamp(-180.0, 180.0);

    var tileCount = 0;
    for (var zoom = minimumZoom; zoom <= maximumZoom; zoom += 1) {
      final northwest = _project(north, west, zoom);
      final southeast = _project(south, east, zoom);
      tileCount +=
          (southeast.$1 - northwest.$1 + 1).abs() *
          (southeast.$2 - northwest.$2 + 1).abs();
      if (tileCount > maximumTiles) {
        throw OfflineTileLimitException(maximumTiles);
      }
    }
    return MapLibreOfflinePlan(
      bounds: ml.LatLngBounds(
        southwest: ml.LatLng(south, west),
        northeast: ml.LatLng(north, east),
      ),
      tileCount: tileCount,
    );
  }

  (int, int) _project(double latitude, double longitude, int zoom) {
    final count = 1 << zoom;
    final x = ((longitude + 180) / 360 * count).floor().clamp(0, count - 1);
    final radians = latitude * math.pi / 180;
    final y =
        ((1 - math.log(math.tan(radians) + (1 / math.cos(radians))) / math.pi) /
                2 *
                count)
            .floor()
            .clamp(0, count - 1);
    return (x, y);
  }
}

class MapLibreOfflineManager {
  const MapLibreOfflineManager({
    required this.configuration,
    this.api = const NativeMapLibreOfflineApi(),
    this.planner = const MapLibreOfflinePlanner(),
    this.prepareStyle = cacheOfflineMapStyle,
  });

  final BasemapConfiguration configuration;
  final MapLibreOfflineApi api;
  final MapLibreOfflinePlanner planner;
  final Future<void> Function(BasemapConfiguration) prepareStyle;

  // The default OpenFreeMap vector source ends at z14; MapLibre overzooms
  // those vectors at riding zoom. Still request z18 from the SDK, which reads
  // the actual source maxzoom. Custom providers retain the conservative cap.
  int get _sourceZoom =>
      configuration.styleUrl == BasemapConfiguration.defaultLightStyleUrl ||
          configuration.styleUrl == BasemapConfiguration.defaultDarkStyleUrl
      ? math.min(14, configuration.maximumNativeZoom)
      : configuration.maximumNativeZoom;

  List<ml.OfflineRegionDefinition> definitions(
    ImportedRoute route, {
    int minimumZoom = 0,
    int maximumZoom = 18,
    int maximumTiles = 20000,
  }) {
    final maxZoom = math.min(maximumZoom, configuration.maximumNativeZoom);
    final plans = planner.corridor(
      route,
      minimumZoom: minimumZoom,
      maximumZoom: math.min(maxZoom, _sourceZoom),
      maximumTiles: maximumTiles,
    );
    final styles = {
      configuration.styleUrl,
      configuration.lightStyleUrl,
      if (configuration.darkStyleUrl.isNotEmpty) configuration.darkStyleUrl,
    };
    return [
      for (final style in styles)
        for (final plan in plans)
          ml.OfflineRegionDefinition(
            bounds: plan.bounds,
            mapStyleUrl: style,
            minZoom: minimumZoom.toDouble(),
            maxZoom: maxZoom.toDouble(),
          ),
    ];
  }

  String _key(ml.OfflineRegionDefinition definition) => sha256
      .convert(
        utf8.encode(
          jsonEncode({
            'version': 1,
            'namespace': configuration.cacheNamespace,
            ...definition.toMap(),
          }),
        ),
      )
      .toString();

  Future<bool> isRouteReady(ImportedRoute route) async {
    final existing = {
      for (final region in await api.regions())
        if (region.metadata['rideRelayNamespace'] ==
            configuration.cacheNamespace)
          region.metadata['corridorKey']: region,
    };
    for (final definition in definitions(route)) {
      final region = existing[_key(definition)];
      if (region == null || !(await api.status(region.id)).isComplete) {
        return false;
      }
    }
    return true;
  }

  Future<TileDownloadSummary> downloadRouteRegion(
    ImportedRoute route, {
    int minimumZoom = 0,
    int maximumZoom = 18,
    int maximumTiles = 20000,
    int maximumBytes = 500 * 1024 * 1024,
    TileDownloadProgressCallback? onProgress,
    TileDownloadCancellationToken? cancellationToken,
  }) async {
    if (!configuration.usesMapLibre || !configuration.canDownloadOffline) {
      throw const OfflineTileConfigurationException(
        'A licensed MapLibre style with offline permission is required.',
      );
    }
    var downloaded = 0;
    var reused = 0;
    var bytes = 0;
    TileDownloadSummary summary(bool cancelled) => TileDownloadSummary(
      totalTiles: downloaded + reused,
      downloadedTiles: downloaded,
      reusedTiles: reused,
      downloadedBytes: bytes,
      cancelled: cancelled,
    );
    if (cancellationToken?.isCancelled ?? false) return summary(true);
    final plans = definitions(
      route,
      minimumZoom: minimumZoom,
      maximumZoom: maximumZoom,
      maximumTiles: maximumTiles,
    );
    // MapLibre pins source tiles/glyphs; the app also needs its repainted style
    // documents on disk before either appearance can open without a network.
    for (final dark in [false, true]) {
      if (cancellationToken?.isCancelled ?? false) return summary(true);
      await prepareStyle(
        configuration.forBrightness(
          dark: dark,
          restrainedLightStyle: configuration.restrainedLightStyle,
        ),
      );
    }
    final existing = {
      for (final region in await api.regions())
        if (region.metadata['rideRelayNamespace'] ==
            configuration.cacheNamespace)
          region.metadata['corridorKey']: region,
    };
    await api.setTileCountLimit(maximumTiles);
    for (var index = 0; index < plans.length; index++) {
      if (cancellationToken?.isCancelled ?? false) return summary(true);
      final definition = plans[index];
      final key = _key(definition);
      final previous = existing[key];
      if (previous != null) {
        final status = await api.status(previous.id);
        if (status.isComplete) {
          reused += status.completedResourceCount;
          onProgress?.call(
            TileDownloadProgress(
              completedTiles: index + 1,
              totalTiles: plans.length,
              downloadedBytes: bytes,
            ),
          );
          continue;
        }
        // Interrupted packs must never count as ready. Completed sections stay
        // pinned and are reused on retry; only the unfinished section restarts.
        await api.pause(previous.id);
        await api.delete(previous.id);
      }
      final terminal = Completer<void>();
      var completedResources = 0;
      var sectionBytes = 0;
      Object? downloadError;
      void onEvent(ml.DownloadRegionStatus status) {
        if (terminal.isCompleted) return;
        if (status is ml.InProgress) {
          completedResources = status.completedResourceCount;
          sectionBytes = status.completedResourceSize;
          onProgress?.call(
            TileDownloadProgress(
              completedTiles:
                  index * 1000 +
                  (status.requiredResourceCount > 0
                          ? (status.completedResourceCount /
                                        status.requiredResourceCount)
                                    .clamp(0.0, 1.0) *
                                1000
                          : 0)
                      .round(),
              totalTiles: plans.length * 1000,
              downloadedBytes: bytes + sectionBytes,
            ),
          );
          if (bytes + sectionBytes > maximumBytes) {
            downloadError =
                'The offline map reached its 500 MB download limit.';
            terminal.complete();
          }
        } else if (status is ml.Success) {
          terminal.complete();
        } else if (status is ml.Error) {
          downloadError = status.cause;
          terminal.complete();
        }
      }

      final region = await api.download(
        definition,
        metadata: {
          'rideRelayNamespace': configuration.cacheNamespace,
          'routeId': route.id,
          'corridorKey': key,
        },
        onEvent: onEvent,
      );
      var cancelled = false;
      try {
        cancelled = await Future.any<bool>([
          terminal.future.then((_) => false),
          if (cancellationToken != null)
            cancellationToken.whenCancelled.then((_) => true),
        ]).timeout(const Duration(minutes: 3));
        if (downloadError != null) {
          throw OfflineTileDownloadException(
            'Map download failed: $downloadError',
          );
        }
        if (!cancelled && !(await api.status(region.id)).isComplete) {
          throw const OfflineTileDownloadException(
            'Map download finished without complete resources.',
          );
        }
      } on Object {
        await api.pause(region.id);
        await api.delete(region.id);
        rethrow;
      }
      if (cancelled) {
        await api.pause(region.id);
        await api.delete(region.id);
        return summary(true);
      }
      downloaded += completedResources;
      bytes += sectionBytes;
    }
    return summary(false);
  }

  Future<void> clear() async {
    final regions = await api.regions();
    for (final region in regions) {
      if (region.metadata['rideRelayNamespace'] ==
          configuration.cacheNamespace) {
        await api.delete(region.id);
      }
    }
    await api.clearAmbient();
  }

  Future<void> clearAll() async {
    final regions = await api.regions();
    for (final region in regions) {
      await api.delete(region.id);
    }
    await api.clearAmbient();
  }
}

Future<void> cacheOfflineMapStyle(BasemapConfiguration configuration) async {
  final repository = await MapStyleRepository.openDefault(configuration);
  try {
    if (!(await repository.resolve()).hasBasemap) {
      throw const OfflineTileDownloadException(
        'Could not save the map style. Connect and retry.',
      );
    }
  } finally {
    repository.dispose();
  }
}
