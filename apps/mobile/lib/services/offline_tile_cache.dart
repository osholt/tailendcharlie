import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../domain/imported_route.dart';
import 'basemap_configuration.dart';
import 'offline_tile_planner.dart';

typedef TileDownloadProgressCallback =
    void Function(TileDownloadProgress value);

class TileDownloadCancellationToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;
}

class TileDownloadProgress {
  const TileDownloadProgress({
    required this.completedTiles,
    required this.totalTiles,
    required this.downloadedBytes,
  });

  final int completedTiles;
  final int totalTiles;
  final int downloadedBytes;

  double get fraction => totalTiles == 0 ? 1 : completedTiles / totalTiles;
}

class TileDownloadSummary {
  const TileDownloadSummary({
    required this.totalTiles,
    required this.downloadedTiles,
    required this.reusedTiles,
    required this.downloadedBytes,
    required this.cancelled,
  });

  final int totalTiles;
  final int downloadedTiles;
  final int reusedTiles;
  final int downloadedBytes;
  final bool cancelled;
}

class OfflineTileCache {
  OfflineTileCache({
    required this.rootDirectory,
    required this.configuration,
    http.Client? httpClient,
    this.maximumStoredBytes = 250 * 1024 * 1024,
    this.maximumTileBytes = 3 * 1024 * 1024,
    this.planner = const OfflineTilePlanner(),
  }) : _httpClient = httpClient ?? http.Client(),
       _ownsHttpClient = httpClient == null;

  final Directory rootDirectory;
  final BasemapConfiguration configuration;
  final int maximumStoredBytes;
  final int maximumTileBytes;
  final OfflineTilePlanner planner;
  final http.Client _httpClient;
  final bool _ownsHttpClient;

  static Future<OfflineTileCache> openDefault(
    BasemapConfiguration configuration,
  ) async {
    final support = await getApplicationSupportDirectory();
    return OfflineTileCache(
      rootDirectory: Directory(path.join(support.path, 'offline_tiles')),
      configuration: configuration,
    );
  }

  File tileFile(OfflineTileCoordinate tile) => File(
    path.join(
      rootDirectory.path,
      configuration.cacheNamespace,
      '${tile.zoom}',
      '${tile.x}',
      '${tile.y}.tile',
    ),
  );

  String tileUrl(OfflineTileCoordinate tile) => configuration.urlTemplate
      .replaceAll('{z}', '${tile.zoom}')
      .replaceAll('{x}', '${tile.x}')
      .replaceAll('{y}', '${tile.y}');

  Future<TileDownloadSummary> downloadRouteCorridor(
    ImportedRoute route, {
    int minimumZoom = 11,
    int maximumZoom = 15,
    int corridorTileRadius = 1,
    int maximumTiles = 2500,
    TileDownloadProgressCallback? onProgress,
    TileDownloadCancellationToken? cancellationToken,
  }) async {
    if (!configuration.canDownloadOffline) {
      throw const OfflineTileConfigurationException(
        'A licensed provider with explicit cache permission is required.',
      );
    }
    if (configuration.maximumNativeZoom < minimumZoom) {
      throw OfflineTileConfigurationException(
        'The provider maximum zoom is below the requested zoom $minimumZoom.',
      );
    }
    final tiles = planner.planRouteCorridor(
      route,
      minimumZoom: minimumZoom,
      maximumZoom: maximumZoom.clamp(
        minimumZoom,
        configuration.maximumNativeZoom,
      ),
      corridorTileRadius: corridorTileRadius,
      maximumTiles: maximumTiles,
    );
    var storedBytes = await _storedBytes();
    var downloadedBytes = 0;
    var downloadedTiles = 0;
    var reusedTiles = 0;
    var completedTiles = 0;

    for (final tile in tiles) {
      if (cancellationToken?.isCancelled ?? false) {
        return TileDownloadSummary(
          totalTiles: tiles.length,
          downloadedTiles: downloadedTiles,
          reusedTiles: reusedTiles,
          downloadedBytes: downloadedBytes,
          cancelled: true,
        );
      }
      final destination = tileFile(tile);
      if (await destination.exists() && await destination.length() > 0) {
        reusedTiles += 1;
      } else {
        final response = await _httpClient.get(
          Uri.parse(tileUrl(tile)),
          headers: const {'User-Agent': 'me.osholt.ride_relay'},
        );
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw OfflineTileDownloadException(
            'Tile server returned HTTP ${response.statusCode}.',
          );
        }
        final contentType = response.headers['content-type'] ?? '';
        if (!contentType.toLowerCase().startsWith('image/')) {
          throw const OfflineTileDownloadException(
            'Tile server response was not an image.',
          );
        }
        final cacheControl = response.headers['cache-control']?.toLowerCase();
        if (cacheControl != null &&
            (cacheControl.contains('no-store') ||
                cacheControl.contains('no-cache') ||
                cacheControl.contains('must-revalidate'))) {
          throw const OfflineTileDownloadException(
            'The tile response forbids reliable offline storage.',
          );
        }
        if (response.bodyBytes.isEmpty ||
            response.bodyBytes.length > maximumTileBytes) {
          throw OfflineTileDownloadException(
            'A tile exceeded the $maximumTileBytes byte safety limit.',
          );
        }
        if (storedBytes + response.bodyBytes.length > maximumStoredBytes) {
          throw OfflineTileStorageLimitException(maximumStoredBytes);
        }
        await destination.parent.create(recursive: true);
        final temporary = File('${destination.path}.tmp');
        await temporary.writeAsBytes(response.bodyBytes, flush: true);
        if (await destination.exists()) await destination.delete();
        await temporary.rename(destination.path);
        storedBytes += response.bodyBytes.length;
        downloadedBytes += response.bodyBytes.length;
        downloadedTiles += 1;
      }
      completedTiles += 1;
      onProgress?.call(
        TileDownloadProgress(
          completedTiles: completedTiles,
          totalTiles: tiles.length,
          downloadedBytes: downloadedBytes,
        ),
      );
    }

    return TileDownloadSummary(
      totalTiles: tiles.length,
      downloadedTiles: downloadedTiles,
      reusedTiles: reusedTiles,
      downloadedBytes: downloadedBytes,
      cancelled: false,
    );
  }

  Future<int> _storedBytes() async {
    final providerDirectory = Directory(
      path.join(rootDirectory.path, configuration.cacheNamespace),
    );
    if (!await providerDirectory.exists()) return 0;
    var total = 0;
    await for (final entity in providerDirectory.list(recursive: true)) {
      if (entity is File && !entity.path.endsWith('.tmp')) {
        total += await entity.length();
      }
    }
    return total;
  }

  Future<void> clear() async {
    if (!configuration.canDownloadOffline) return;
    final providerDirectory = Directory(
      path.join(rootDirectory.path, configuration.cacheNamespace),
    );
    if (await providerDirectory.exists()) {
      await providerDirectory.delete(recursive: true);
    }
  }

  void dispose() {
    if (_ownsHttpClient) _httpClient.close();
  }
}

class LicensedCachingTileProvider extends TileProvider {
  LicensedCachingTileProvider({required this.cache, super.headers});

  final OfflineTileCache cache;

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    final tile = OfflineTileCoordinate(
      zoom: coordinates.z,
      x: coordinates.x,
      y: coordinates.y,
    );
    final file = cache.tileFile(tile);
    if (cache.configuration.canDownloadOffline && file.existsSync()) {
      return FileImage(file);
    }
    return NetworkImage(getTileUrl(coordinates, options), headers: headers);
  }
}

class OfflineTileConfigurationException implements Exception {
  const OfflineTileConfigurationException(this.message);

  final String message;

  @override
  String toString() => message;
}

class OfflineTileDownloadException implements Exception {
  const OfflineTileDownloadException(this.message);

  final String message;

  @override
  String toString() => message;
}

class OfflineTileStorageLimitException implements Exception {
  const OfflineTileStorageLimitException(this.maximumBytes);

  final int maximumBytes;

  @override
  String toString() =>
      'The offline map cache reached its $maximumBytes byte safety cap.';
}
