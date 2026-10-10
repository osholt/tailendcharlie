// The Flutter vector renderer exposes no way to keep what it has drawn, so this
// layer assembles its raster pipeline from the package's own parts. The version
// is pinned exactly in pubspec.yaml for that reason.
// ignore_for_file: implementation_imports
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:executor_lib/executor_lib.dart'
    show CancellationException, Executor;
import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:vector_map_tiles/src/cache/byte_storage.dart';
import 'package:vector_map_tiles/src/cache/caches.dart';
import 'package:vector_map_tiles/src/executors/shared_executor.dart';
import 'package:vector_map_tiles/src/raster/future_tile_provider.dart';
import 'package:vector_map_tiles/src/raster/storage_image_cache.dart';
import 'package:vector_map_tiles/src/raster/tile_loader.dart';
import 'package:vector_map_tiles/src/stream/caches_tile_provider.dart';
import 'package:vector_map_tiles/src/stream/tile_processor.dart';
import 'package:vector_map_tiles/src/stream/tile_supplier_raster.dart';
import 'package:vector_map_tiles/src/stream/tileset_executor_preprocessor.dart';
import 'package:vector_map_tiles/src/stream/tileset_ui_preprocessor.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart' as vmt;
import 'package:vector_tile_renderer/vector_tile_renderer.dart' as vtr;

import '../../services/rendered_tile_scheduler.dart';

/// How many background isolates decode and clip tiles on this device.
///
/// The ride map used a fixed two. Phones have six cores, and the UI and raster
/// threads need two of them, so a third decoder fits; more would start to
/// compete with drawing.
int defaultTileIsolates({int? processors}) =>
    math.max(2, math.min(3, (processors ?? Platform.numberOfProcessors) - 3));

/// Pixels of finished tile images kept for revisiting a zoom level (1 MiB each).
const defaultRenderedTileBytes = 64 * 1024 * 1024;

/// A drop-in replacement for the raster-mode [vmt.VectorTileLayer] that keeps
/// rendered tiles and spends effort only on the zoom level the rider settles at.
///
/// What it changes, against the package layer the ride map used before (#953):
///
/// * Finished tile images are kept in memory ([defaultRenderedTileBytes]). The
///   package's own store for them was switched off by `fileCacheMaximumSizeInBytes:
///   0`, which this app sets so the package cannot keep a second, ungoverned
///   copy of the provider's tiles on disk. Switching it off did not stop the work:
///   every tile was still PNG-encoded and written, then deleted, and nothing was
///   ever reused, so each zoom back to a level drew every tile again.
/// * A render starts only once the zoom level has been steady for a moment, so
///   levels a pinch only passes through cost nothing.
/// * Tiles near the centre of the screen are drawn before the margin.
/// * Nothing is written to disk. Raw tile bytes stay in the app's own governed
///   cache; this layer's store is memory only.
class RideVectorTileLayer extends StatefulWidget {
  const RideVectorTileLayer({
    super.key,
    required this.style,
    required this.maximumZoom,
    this.isolates,
    this.renderedTileBytes = defaultRenderedTileBytes,
    this.settleDelay = const Duration(milliseconds: 90),
  });

  final vmt.Style style;
  final double maximumZoom;

  /// Overrides [defaultTileIsolates].
  final int? isolates;
  final int renderedTileBytes;
  final Duration settleDelay;

  @override
  State<RideVectorTileLayer> createState() => _RideVectorTileLayerState();
}

class _RideVectorTileLayerState extends State<RideVectorTileLayer>
    with WidgetsBindingObserver {
  late final int _isolates = widget.isolates ?? defaultTileIsolates();
  late final Executor _executor = acquireSharedExecutor(concurrency: _isolates);
  Caches? _caches;
  FutureTileProvider? _provider;
  TileRenderScheduler<ImageInfo>? _scheduler;
  MapCamera? _camera;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _create();
  }

  @override
  void didUpdateWidget(RideVectorTileLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    final a = oldWidget.style, b = widget.style;
    if (a.theme.id != b.theme.id ||
        a.theme.version != b.theme.version ||
        a.sprites != b.sprites ||
        !identical(a.providers, b.providers) ||
        oldWidget.maximumZoom != widget.maximumZoom ||
        oldWidget.renderedTileBytes != widget.renderedTileBytes ||
        oldWidget.settleDelay != widget.settleDelay) {
      _destroy();
      _create();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _destroy();
    releaseSharedExecutor();
    super.dispose();
  }

  @override
  void didHaveMemoryPressure() {
    _scheduler?.cache.clear();
    _caches?.didHaveMemoryPressure();
  }

  void _create() {
    final style = widget.style;
    final theme = style.theme;
    final caches = Caches(
      executor: _executor,
      providers: style.providers,
      theme: theme,
      sprites: style.sprites,
      ttl: Duration.zero,
      memoryTileCacheMaxSize: vmt.VectorTileLayer.defaultTileCacheMaxSize,
      memoryTileDataCacheMaxSize:
          vmt.VectorTileLayer.defaultTileDataCacheMaxSize,
      maxSizeInBytes: 0,
      maxTextCacheSize: vmt.VectorTileLayer.defaultTextCacheMaxSize,
      cacheStorage: DiscardingByteStorage(),
    );
    final loader = TileLoader(
      theme,
      style.sprites,
      caches.atlasImageCache?.retrieve,
      CachesTileProvider(
        caches,
        TileProcessor(_executor),
        TilesetExecutorPreprocessor(vtr.TilesetPreprocessor(theme), _executor),
        TilesetUiPreprocessor(
          vtr.TilesetPreprocessor(theme, initializeGeometry: true),
        ),
      ),
      RasterTileProvider(
        providers: style.providers,
        cache: caches.imageLoadingCache,
      ),
      vmt.TileOffset.DEFAULT,
      UnstoredImageCache(theme, caches.storageCache),
      _isolates,
    );
    final scheduler = TileRenderScheduler<ImageInfo>(
      cache: RenderedTileCache<ImageInfo>(
        maximumBytes: widget.renderedTileBytes,
        sizeOf: (info) => info.image.width * info.image.height * 4,
        release: (info) => info.dispose(),
      ),
      share: (info) => info.clone(),
      // The loader runs this many at once; more would only queue behind it.
      concurrency: _isolates * 2,
      settleDelay: widget.settleDelay,
    );
    _caches = caches;
    _scheduler = scheduler;
    _provider = FutureTileProvider(
      loader: (coords, options, cancelled) async {
        try {
          return await scheduler.load(
            key: '${coords.z}/${coords.x}/${coords.y}',
            zoom: coords.z,
            urgency: () => _urgency(coords, options.tileDimension),
            cancelled: cancelled,
            render: () => loader.loadTile(coords, options, cancelled),
          );
        } on TileRequestCancelled {
          throw CancellationException();
        }
      },
    );
  }

  void _destroy() {
    _scheduler?.dispose();
    _scheduler = null;
    _provider?.dispose();
    _provider = null;
    _caches?.dispose();
    _caches = null;
  }

  /// How far a tile is from what the rider is looking at, in tiles. A tile at
  /// another zoom level than the camera's only matters as a fallback.
  double _urgency(TileCoordinates coords, int tileDimension) {
    final camera = _camera;
    if (camera == null) return 0;
    final centre = camera.projectAtZoom(camera.center, coords.z.toDouble());
    final dx = (coords.x + 0.5) * tileDimension - centre.dx;
    final dy = (coords.y + 0.5) * tileDimension - centre.dy;
    final levels = (coords.z - camera.zoom.round()).abs();
    return math.sqrt(dx * dx + dy * dy) / tileDimension + levels * 1000;
  }

  @override
  Widget build(BuildContext context) {
    _camera = MapCamera.maybeOf(context);
    final theme = widget.style.theme;
    return TileLayer(
      key: Key('${theme.id}_v${theme.version}_RideVectorTileLayer'),
      maxZoom: widget.maximumZoom,
      maxNativeZoom: widget.maximumZoom.ceil(),
      evictErrorTileStrategy: EvictErrorTileStrategy.notVisible,
      tileProvider: _provider!,
      tileDisplay: const TileDisplay.instantaneous(),
    );
  }
}

/// Takes the package's disk store out of the picture: nothing it would have
/// written is ever read again, and the app keeps tile bytes in its own cache.
@visibleForTesting
class DiscardingByteStorage extends ByteStorage {
  @override
  Future<void> write(String path, Uint8List bytes) async {}
  @override
  Future<Uint8List?> read(String path) async => null;
  @override
  Future<void> delete(String path) async {}
  @override
  Future<bool> exists(String key) async => false;
  @override
  Future<List<ByteStorageEntry>> list() async => const [];
}

/// The package's rendered-tile store, minus the part that PNG-encodes every
/// tile before handing it to a disk that discards it. Encoding cost about a
/// third of the time to draw a tile.
@visibleForTesting
class UnstoredImageCache extends StorageImageCache {
  UnstoredImageCache(super.theme, super.delegate);

  @override
  Future<ui.Image?> retrieve(vmt.TileIdentity tile) async => null;

  @override
  Future<void> put(vmt.TileIdentity tile, ui.Image image) async {}
}
