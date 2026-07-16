import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:uuid/uuid.dart';

import '../../data/json_file_route_store.dart';
import '../../domain/imported_route.dart';
import '../../domain/route_store.dart';
import '../../services/basemap_configuration.dart';
import '../../services/gpx_import_source.dart';
import '../../services/gpx_parser.dart';
import '../../services/offline_tile_cache.dart';
import '../../services/route_importer.dart';

/// Self-contained production entry point for the map/GPX feature.
///
/// Route geometry is local and always renders without a network. Basemap tiles
/// are only enabled when [BasemapConfiguration] contains a provider URL and
/// attribution. Offline tile downloads additionally require explicit provider
/// cache permission.
class RideMapFeature extends StatefulWidget {
  const RideMapFeature({
    super.key,
    this.currentPosition,
    this.overlayMarkers,
    this.basemapConfiguration = const BasemapConfiguration(),
  });

  factory RideMapFeature.fromEnvironment({
    Key? key,
    ValueListenable<GeoPoint?>? currentPosition,
    ValueListenable<List<MapOverlayMarker>>? overlayMarkers,
  }) => RideMapFeature(
    key: key,
    currentPosition: currentPosition,
    overlayMarkers: overlayMarkers,
    basemapConfiguration: BasemapConfiguration.fromEnvironment(),
  );

  final ValueListenable<GeoPoint?>? currentPosition;
  final ValueListenable<List<MapOverlayMarker>>? overlayMarkers;
  final BasemapConfiguration basemapConfiguration;

  @override
  State<RideMapFeature> createState() => _RideMapFeatureState();
}

class _RideMapFeatureState extends State<RideMapFeature> {
  late Future<_MapDependencies> _dependencies;

  @override
  void initState() {
    super.initState();
    _dependencies = _openDependencies();
  }

  Future<_MapDependencies> _openDependencies() async => _MapDependencies(
    store: await JsonFileRouteStore.openDefault(),
    cache: await OfflineTileCache.openDefault(widget.basemapConfiguration),
  );

  @override
  Widget build(BuildContext context) => FutureBuilder<_MapDependencies>(
    future: _dependencies,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return Scaffold(
          appBar: AppBar(title: const Text('Route map')),
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text('Could not open route storage: ${snapshot.error}'),
            ),
          ),
        );
      }
      final dependencies = snapshot.data;
      if (dependencies == null) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      return RideMapScreen(
        routeStore: dependencies.store,
        routeImporter: RouteImporter(source: const SystemGpxImportSource()),
        offlineTileCache: dependencies.cache,
        disposeOfflineTileCache: true,
        currentPosition: widget.currentPosition,
        overlayMarkers: widget.overlayMarkers,
      );
    },
  );
}

class _MapDependencies {
  const _MapDependencies({required this.store, required this.cache});

  final RouteStore store;
  final OfflineTileCache cache;
}

/// Injectable map screen used by app integration and focused tests.
class RideMapScreen extends StatefulWidget {
  const RideMapScreen({
    super.key,
    required this.routeStore,
    required this.routeImporter,
    required this.offlineTileCache,
    this.currentPosition,
    this.overlayMarkers,
    this.demoRouteLoader,
    this.disposeOfflineTileCache = false,
  });

  final RouteStore routeStore;
  final RouteImporter routeImporter;
  final OfflineTileCache offlineTileCache;
  final ValueListenable<GeoPoint?>? currentPosition;
  final ValueListenable<List<MapOverlayMarker>>? overlayMarkers;
  final Future<ImportedRoute> Function()? demoRouteLoader;
  final bool disposeOfflineTileCache;

  @override
  State<RideMapScreen> createState() => _RideMapScreenState();
}

class _RideMapScreenState extends State<RideMapScreen> {
  final MapController _mapController = MapController();
  ImportedRoute? _route;
  Object? _loadError;
  bool _loading = true;
  bool _importing = false;
  TileDownloadProgress? _downloadProgress;
  TileDownloadCancellationToken? _downloadCancellation;

  BasemapConfiguration get _basemap => widget.offlineTileCache.configuration;

  @override
  void initState() {
    super.initState();
    _loadPersistedRoute();
  }

  @override
  void dispose() {
    _downloadCancellation?.cancel();
    _mapController.dispose();
    if (widget.disposeOfflineTileCache) widget.offlineTileCache.dispose();
    super.dispose();
  }

  Future<void> _loadPersistedRoute() async {
    try {
      final route = await widget.routeStore.loadActiveRoute();
      if (!mounted) return;
      setState(() {
        _route = route;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = error;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Route map'),
        actions: [
          IconButton(
            tooltip: 'Fit route',
            onPressed: _route == null ? null : _fitRoute,
            icon: const Icon(Icons.fit_screen),
          ),
          PopupMenuButton<_MapAction>(
            onSelected: _handleMenuAction,
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: _MapAction.loadDemo,
                child: Text('Load demo route'),
              ),
              if (_basemap.canDownloadOffline)
                const PopupMenuItem(
                  value: _MapAction.clearOfflineTiles,
                  child: Text('Clear offline map tiles'),
                ),
              if (_route != null)
                const PopupMenuItem(
                  value: _MapAction.removeRoute,
                  child: Text('Remove route'),
                ),
            ],
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _loadError != null
          ? _ErrorState(error: _loadError!, onRetry: _loadPersistedRoute)
          : Column(
              children: [
                _RouteToolbar(
                  route: _route,
                  importing: _importing,
                  onImport: _importGpx,
                  onLoadDemo: _loadDemoRoute,
                ),
                _BasemapStatus(configuration: _basemap),
                if (_downloadProgress case final progress?)
                  _DownloadProgress(
                    progress: progress,
                    onCancel: _downloadCancellation?.cancel,
                  ),
                Expanded(child: _buildMap()),
                if (_route != null)
                  _OfflineDownloadBar(
                    enabled:
                        _basemap.canDownloadOffline &&
                        _downloadProgress == null,
                    statusMessage: _basemap.statusMessage,
                    onDownload: _downloadOfflineMap,
                  ),
              ],
            ),
    );
  }

  Widget _buildMap() {
    final route = _route;
    final points = route?.allPoints.map(_latLng).toList(growable: false) ?? [];
    final options = points.length > 1
        ? MapOptions(
            initialCameraFit: CameraFit.bounds(
              bounds: LatLngBounds.fromPoints(points),
              padding: const EdgeInsets.all(42),
            ),
            initialZoom: 13,
          )
        : MapOptions(
            initialCenter: points.firstOrNull ?? const LatLng(54.5, -3.2),
            initialZoom: points.isEmpty ? 5 : 14,
          );

    final map = FlutterMap(
      key: ValueKey(route?.id ?? 'empty-map'),
      mapController: _mapController,
      options: options,
      children: [
        if (_basemap.isConfigured)
          TileLayer(
            urlTemplate: _basemap.urlTemplate,
            userAgentPackageName: 'me.osholt.ride_relay',
            maxNativeZoom: _basemap.maximumNativeZoom,
            tileProvider: LicensedCachingTileProvider(
              cache: widget.offlineTileCache,
            ),
          ),
        if (route != null)
          PolylineLayer(
            polylines: route.paths
                .map(
                  (path) => Polyline(
                    points: path.points.map(_latLng).toList(growable: false),
                    color: const Color(0xFFFF7A1A),
                    strokeWidth: 5,
                    borderColor: const Color(0xFF10151C),
                    borderStrokeWidth: 2,
                  ),
                )
                .toList(growable: false),
          ),
        if (route != null && route.waypoints.isNotEmpty)
          MarkerLayer(
            markers: route.waypoints
                .take(500)
                .map(
                  (waypoint) => Marker(
                    point: _latLng(waypoint.point),
                    width: 42,
                    height: 42,
                    child: Tooltip(
                      message: waypoint.name ?? 'GPX waypoint',
                      child: const Icon(
                        Icons.location_on,
                        color: Color(0xFFFFC857),
                        size: 36,
                      ),
                    ),
                  ),
                )
                .toList(growable: false),
          ),
        if (widget.currentPosition != null)
          ValueListenableBuilder<GeoPoint?>(
            valueListenable: widget.currentPosition!,
            builder: (context, currentPosition, _) => currentPosition == null
                ? const SizedBox.shrink()
                : MarkerLayer(
                    markers: [
                      Marker(
                        point: _latLng(currentPosition),
                        width: 34,
                        height: 34,
                        child: const _CurrentPositionMarker(),
                      ),
                    ],
                  ),
          ),
        if (widget.overlayMarkers != null)
          ValueListenableBuilder<List<MapOverlayMarker>>(
            valueListenable: widget.overlayMarkers!,
            builder: (context, overlays, _) => MarkerLayer(
              markers: overlays
                  .take(1000)
                  .map(
                    (overlay) => Marker(
                      key: ValueKey(overlay.id),
                      point: _latLng(overlay.point),
                      width: 42,
                      height: 42,
                      child: Tooltip(
                        message: overlay.label,
                        child: Icon(
                          overlay.icon,
                          color: overlay.color,
                          size: 34,
                        ),
                      ),
                    ),
                  )
                  .toList(growable: false),
            ),
          ),
        if (_basemap.isConfigured)
          SimpleAttributionWidget(
            source: Text(
              _basemap.attribution,
              style: const TextStyle(fontSize: 10),
            ),
            backgroundColor: const Color(0xCC171D25),
          ),
      ],
    );

    return Stack(
      children: [
        Positioned.fill(
          child: ColoredBox(color: const Color(0xFF111820), child: map),
        ),
        if (!_basemap.isConfigured)
          const Positioned(left: 12, bottom: 12, child: _RouteOnlyBadge()),
        if (route == null)
          Positioned.fill(
            child: IgnorePointer(
              child: Center(
                child: Container(
                  margin: const EdgeInsets.all(24),
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: const Color(0xE8171D25),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Text(
                    'Import a GPX file or load the demo route.\nRoute lines are stored and shown offline.',
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _importGpx() async {
    if (_importing) return;
    setState(() => _importing = true);
    try {
      final route = await widget.routeImporter.importFromPicker();
      if (route == null) return;
      await _activateRoute(route);
    } on FormatException catch (error) {
      _showMessage(error.message);
    } catch (error) {
      _showMessage('Could not import GPX: $error');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _loadDemoRoute() async {
    try {
      final loader = widget.demoRouteLoader ?? _loadBundledDemoRoute;
      await _activateRoute(await loader());
    } catch (error) {
      _showMessage('Could not load demo route: $error');
    }
  }

  Future<ImportedRoute> _loadBundledDemoRoute() async {
    final data = await rootBundle.load('assets/demo_route.gpx');
    return const GpxParser().parse(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      routeId: const Uuid().v4(),
      sourceFileName: 'demo_route.gpx',
      importedAt: DateTime.now(),
    );
  }

  Future<void> _activateRoute(ImportedRoute route) async {
    await widget.routeStore.saveActiveRoute(route);
    if (!mounted) return;
    setState(() => _route = route);
    _showMessage(
      '${route.name}: ${route.pathPointCount} route points stored offline.',
    );
  }

  Future<void> _downloadOfflineMap() async {
    final route = _route;
    if (route == null || !_basemap.canDownloadOffline) return;
    final cancellation = TileDownloadCancellationToken();
    setState(() {
      _downloadCancellation = cancellation;
      _downloadProgress = const TileDownloadProgress(
        completedTiles: 0,
        totalTiles: 1,
        downloadedBytes: 0,
      );
    });
    try {
      final summary = await widget.offlineTileCache.downloadRouteCorridor(
        route,
        cancellationToken: cancellation,
        onProgress: (progress) {
          if (mounted) setState(() => _downloadProgress = progress);
        },
      );
      _showMessage(
        summary.cancelled
            ? 'Offline map download cancelled; completed tiles were kept.'
            : '${summary.totalTiles} offline tiles ready (${summary.reusedTiles} already cached).',
      );
      if (mounted) setState(() {});
    } catch (error) {
      _showMessage('Offline map download stopped: $error');
    } finally {
      if (mounted) {
        setState(() {
          _downloadCancellation = null;
          _downloadProgress = null;
        });
      }
    }
  }

  void _fitRoute() {
    final points = _route?.allPoints.map(_latLng).toList(growable: false) ?? [];
    if (points.isEmpty) return;
    if (points.length == 1) {
      _mapController.move(points.single, 14);
    } else {
      _mapController.fitCamera(
        CameraFit.bounds(
          bounds: LatLngBounds.fromPoints(points),
          padding: const EdgeInsets.all(42),
        ),
      );
    }
  }

  Future<void> _handleMenuAction(_MapAction action) async {
    switch (action) {
      case _MapAction.loadDemo:
        await _loadDemoRoute();
      case _MapAction.removeRoute:
        await widget.routeStore.clearActiveRoute();
        if (mounted) setState(() => _route = null);
      case _MapAction.clearOfflineTiles:
        await widget.offlineTileCache.clear();
        _showMessage('Offline map tiles cleared.');
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

enum _MapAction { loadDemo, removeRoute, clearOfflineTiles }

/// Neutral presentation model for hazards, group riders, markers, or other
/// feature-owned map overlays. Callers retain ownership of their domain models.
class MapOverlayMarker {
  const MapOverlayMarker({
    required this.id,
    required this.point,
    required this.label,
    this.icon = Icons.warning_amber_rounded,
    this.color = const Color(0xFFFFC857),
  });

  final String id;
  final GeoPoint point;
  final String label;
  final IconData icon;
  final Color color;
}

LatLng _latLng(GeoPoint point) => LatLng(point.latitude, point.longitude);

class _RouteToolbar extends StatelessWidget {
  const _RouteToolbar({
    required this.route,
    required this.importing,
    required this.onImport,
    required this.onLoadDemo,
  });

  final ImportedRoute? route;
  final bool importing;
  final VoidCallback onImport;
  final VoidCallback onLoadDemo;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                route?.name ?? 'No route loaded',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              Text(
                route == null
                    ? 'GPX 1.1 tracks, routes and waypoints'
                    : '${route!.pathPointCount} route points · ${route!.waypoints.length} waypoints',
                style: const TextStyle(color: Color(0xFF98A3B1), fontSize: 12),
              ),
            ],
          ),
        ),
        TextButton(onPressed: onLoadDemo, child: const Text('Demo')),
        const SizedBox(width: 4),
        FilledButton.tonalIcon(
          onPressed: importing ? null : onImport,
          icon: importing
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.upload_file),
          label: Text(route == null ? 'Import GPX' : 'Replace'),
        ),
      ],
    ),
  );
}

class _BasemapStatus extends StatelessWidget {
  const _BasemapStatus({required this.configuration});

  final BasemapConfiguration configuration;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    color: configuration.canDownloadOffline
        ? const Color(0xFF173124)
        : const Color(0xFF28251C),
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
    child: Row(
      children: [
        Icon(
          configuration.canDownloadOffline
              ? Icons.offline_pin
              : Icons.info_outline,
          size: 16,
          color: configuration.canDownloadOffline
              ? const Color(0xFF6ED89A)
              : const Color(0xFFFFC857),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            configuration.statusMessage,
            style: const TextStyle(fontSize: 11),
          ),
        ),
      ],
    ),
  );
}

class _OfflineDownloadBar extends StatelessWidget {
  const _OfflineDownloadBar({
    required this.enabled,
    required this.statusMessage,
    required this.onDownload,
  });

  final bool enabled;
  final String statusMessage;
  final VoidCallback onDownload;

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
      child: SizedBox(
        width: double.infinity,
        child: Tooltip(
          message: statusMessage,
          child: FilledButton.icon(
            onPressed: enabled ? onDownload : null,
            icon: const Icon(Icons.download_for_offline),
            label: const Text('Download route corridor for offline use'),
          ),
        ),
      ),
    ),
  );
}

class _DownloadProgress extends StatelessWidget {
  const _DownloadProgress({required this.progress, required this.onCancel});

  final TileDownloadProgress progress;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
    child: Row(
      children: [
        Expanded(child: LinearProgressIndicator(value: progress.fraction)),
        const SizedBox(width: 10),
        Text('${progress.completedTiles}/${progress.totalTiles}'),
        TextButton(onPressed: onCancel, child: const Text('Cancel')),
      ],
    ),
  );
}

class _CurrentPositionMarker extends StatelessWidget {
  const _CurrentPositionMarker();

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: const Color(0xFF4AA3FF),
      shape: BoxShape.circle,
      border: Border.all(color: Colors.white, width: 3),
      boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 5)],
    ),
  );
}

class _RouteOnlyBadge extends StatelessWidget {
  const _RouteOnlyBadge();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
    decoration: BoxDecoration(
      color: const Color(0xDD171D25),
      borderRadius: BorderRadius.circular(9),
    ),
    child: const Text('ROUTE-ONLY OFFLINE MAP', style: TextStyle(fontSize: 10)),
  );
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Could not read the saved route: $error'),
          const SizedBox(height: 12),
          FilledButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    ),
  );
}
