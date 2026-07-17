import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as ml;

import '../../data/json_file_route_store.dart';
import '../../domain/distance_unit.dart';
import '../../domain/imported_route.dart';
import '../../domain/route_store.dart';
import '../../services/basemap_configuration.dart';
import '../../services/demo_route_loader.dart';
import '../../services/gpx_import_source.dart';
import '../../services/leader_ride_status.dart';
import '../../services/map_geojson.dart';
import '../../services/map_style_repository.dart';
import '../../services/maplibre_offline_manager.dart';
import '../../services/measurement_formatter.dart';
import '../../services/navigation_export.dart';
import '../../services/offline_tile_cache.dart';
import '../../services/road_routing.dart';
import '../../services/route_geometry_enricher.dart';
import '../../services/route_importer.dart';
import '../../services/route_progress.dart';
import 'destination_route_sheet.dart';
import 'navigation_export_sheet.dart';

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
    this.navigationPosition,
    this.overlayMarkers,
    this.offRouteTraces,
    this.leaderStatus,
    this.onRouteChanged,
    this.acquireCurrentPosition,
    this.navigationExportCoordinator,
    this.routeStore,
    this.distanceUnit = DistanceUnit.kilometres,
    this.basemapConfiguration = const BasemapConfiguration(),
  });

  factory RideMapFeature.fromEnvironment({
    Key? key,
    ValueListenable<GeoPoint?>? currentPosition,
    ValueListenable<MapNavigationPosition?>? navigationPosition,
    ValueListenable<List<MapOverlayMarker>>? overlayMarkers,
    ValueListenable<List<MapOverlayTrace>>? offRouteTraces,
    ValueListenable<LeaderRideStatus?>? leaderStatus,
    ValueChanged<ImportedRoute?>? onRouteChanged,
    Future<GeoPoint?> Function()? acquireCurrentPosition,
    RouteStore? routeStore,
    DistanceUnit distanceUnit = DistanceUnit.kilometres,
  }) => RideMapFeature(
    key: key,
    currentPosition: currentPosition,
    navigationPosition: navigationPosition,
    overlayMarkers: overlayMarkers,
    offRouteTraces: offRouteTraces,
    leaderStatus: leaderStatus,
    onRouteChanged: onRouteChanged,
    acquireCurrentPosition: acquireCurrentPosition,
    routeStore: routeStore,
    distanceUnit: distanceUnit,
    basemapConfiguration: BasemapConfiguration.fromEnvironment(),
  );

  final ValueListenable<GeoPoint?>? currentPosition;
  final ValueListenable<MapNavigationPosition?>? navigationPosition;
  final ValueListenable<List<MapOverlayMarker>>? overlayMarkers;
  final ValueListenable<List<MapOverlayTrace>>? offRouteTraces;
  final ValueListenable<LeaderRideStatus?>? leaderStatus;
  final ValueChanged<ImportedRoute?>? onRouteChanged;
  final Future<GeoPoint?> Function()? acquireCurrentPosition;
  final NavigationExportCoordinator? navigationExportCoordinator;
  final RouteStore? routeStore;
  final DistanceUnit distanceUnit;
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

  Future<_MapDependencies> _openDependencies() async {
    final styleRepository = await MapStyleRepository.openDefault(
      widget.basemapConfiguration,
    );
    try {
      return _MapDependencies(
        store: widget.routeStore ?? await JsonFileRouteStore.openDefault(),
        cache: await OfflineTileCache.openDefault(widget.basemapConfiguration),
        mapLibreOfflineManager: MapLibreOfflineManager(
          configuration: widget.basemapConfiguration,
        ),
        mapStyleString: await styleRepository.resolve(),
      );
    } finally {
      styleRepository.dispose();
    }
  }

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
        mapLibreOfflineManager: dependencies.mapLibreOfflineManager,
        mapStyleString: dependencies.mapStyleString,
        disposeOfflineTileCache: true,
        currentPosition: widget.currentPosition,
        navigationPosition: widget.navigationPosition,
        overlayMarkers: widget.overlayMarkers,
        offRouteTraces: widget.offRouteTraces,
        leaderStatus: widget.leaderStatus,
        onRouteChanged: widget.onRouteChanged,
        acquireCurrentPosition: widget.acquireCurrentPosition,
        navigationExportCoordinator: widget.navigationExportCoordinator,
        distanceUnit: widget.distanceUnit,
      );
    },
  );
}

class _MapDependencies {
  const _MapDependencies({
    required this.store,
    required this.cache,
    required this.mapLibreOfflineManager,
    required this.mapStyleString,
  });

  final RouteStore store;
  final OfflineTileCache cache;
  final MapLibreOfflineManager mapLibreOfflineManager;
  final String mapStyleString;
}

/// Injectable map screen used by app integration and focused tests.
class RideMapScreen extends StatefulWidget {
  const RideMapScreen({
    super.key,
    required this.routeStore,
    required this.routeImporter,
    required this.offlineTileCache,
    this.mapLibreOfflineManager,
    this.mapStyleString = MapStyleRepository.fallbackStyle,
    this.currentPosition,
    this.navigationPosition,
    this.overlayMarkers,
    this.offRouteTraces,
    this.leaderStatus,
    this.onRouteChanged,
    this.acquireCurrentPosition,
    this.navigationExportCoordinator,
    this.destinationRoutePlanner,
    this.routeGeometryEnricher,
    this.demoRouteLoader,
    this.distanceUnit = DistanceUnit.kilometres,
    this.disposeOfflineTileCache = false,
  });

  final RouteStore routeStore;
  final RouteImporter routeImporter;
  final OfflineTileCache offlineTileCache;
  final MapLibreOfflineManager? mapLibreOfflineManager;
  final String mapStyleString;
  final ValueListenable<GeoPoint?>? currentPosition;
  final ValueListenable<MapNavigationPosition?>? navigationPosition;
  final ValueListenable<List<MapOverlayMarker>>? overlayMarkers;
  final ValueListenable<List<MapOverlayTrace>>? offRouteTraces;
  final ValueListenable<LeaderRideStatus?>? leaderStatus;
  final ValueChanged<ImportedRoute?>? onRouteChanged;
  final Future<GeoPoint?> Function()? acquireCurrentPosition;
  final NavigationExportCoordinator? navigationExportCoordinator;
  final DestinationRoutePlanner? destinationRoutePlanner;
  final RouteGeometryEnricher? routeGeometryEnricher;
  final Future<ImportedRoute> Function()? demoRouteLoader;
  final DistanceUnit distanceUnit;
  final bool disposeOfflineTileCache;

  @override
  State<RideMapScreen> createState() => _RideMapScreenState();
}

class _RideMapScreenState extends State<RideMapScreen> {
  static const _remainingRouteSource = 'ride-relay-route-remaining';
  static const _riddenRouteSource = 'ride-relay-route-ridden';
  static const _offRouteTraceSource = 'ride-relay-off-route-traces';
  static const _waypointSource = 'ride-relay-waypoints';
  static const _positionSource = 'ride-relay-position';
  static const _overlaySource = 'ride-relay-overlays';

  final MapControllerImpl _mapController = MapControllerImpl();
  final RouteProgressTracker _routeProgressTracker = RouteProgressTracker();
  final Map<int, Offset> _mapPointerOrigins = {};
  late final http.Client _routingClient;
  late final DestinationRoutePlanner _defaultDestinationRoutePlanner;
  late final RouteGeometryEnricher _defaultRouteGeometryEnricher;
  ml.MapLibreMapController? _mapLibreController;
  late final MapLibreOfflineManager _mapLibreOfflineManager;
  bool _mapLibreStyleReady = false;
  ImportedRoute? _route;
  Object? _loadError;
  bool _loading = true;
  bool _importing = false;
  bool _exporting = false;
  bool _routing = false;
  bool _navigationMode = false;
  bool _autoFollowSuppressed = false;
  double _lastHeadingDegrees = 0;
  GeoPoint? _previousNavigationPoint;
  MapNavigationPosition? _lastHandledNavigationFix;
  GeoPoint? _lastHandledCurrentPosition;
  DateTime? _lastCameraUpdateAt;
  DateTime? _lastProgressUpdateAt;
  Duration _cameraTransitionDuration = const Duration(milliseconds: 450);
  bool _mapLibreSyncScheduled = false;
  bool _mapLibreSyncRunning = false;
  bool _mapLibreProgressDirty = false;
  bool _mapLibrePositionDirty = false;
  bool _mapLibreOverlaysDirty = false;
  RouteProgressGeometry _progressGeometry = const RouteProgressGeometry.empty();
  TileDownloadProgress? _downloadProgress;
  TileDownloadCancellationToken? _downloadCancellation;

  BasemapConfiguration get _basemap => widget.offlineTileCache.configuration;

  DestinationRoutePlanner get _destinationRoutePlanner =>
      widget.destinationRoutePlanner ?? _defaultDestinationRoutePlanner;

  RouteGeometryEnricher get _routeGeometryEnricher =>
      widget.routeGeometryEnricher ?? _defaultRouteGeometryEnricher;

  @override
  void initState() {
    super.initState();
    _routingClient = http.Client();
    final routingConfiguration = RoutingConfiguration.fromEnvironment();
    final routingService = OsrmRoadRoutingService(
      client: _routingClient,
      baseUrl: routingConfiguration.routingBaseUrl,
    );
    _defaultDestinationRoutePlanner = DestinationRoutePlanner(
      searchService: NominatimDestinationSearchService(
        client: _routingClient,
        baseUrl: routingConfiguration.geocodingBaseUrl,
      ),
      routingService: routingService,
    );
    _defaultRouteGeometryEnricher = RouteGeometryEnricher(
      routingService: routingService,
    );
    _mapLibreOfflineManager =
        widget.mapLibreOfflineManager ??
        MapLibreOfflineManager(configuration: _basemap);
    widget.currentPosition?.addListener(_onPositionChanged);
    widget.navigationPosition?.addListener(_onPositionChanged);
    widget.overlayMarkers?.addListener(_onOverlayDataChanged);
    widget.offRouteTraces?.addListener(_onOverlayDataChanged);
    _loadPersistedRoute();
  }

  @override
  void didUpdateWidget(RideMapScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentPosition != widget.currentPosition) {
      oldWidget.currentPosition?.removeListener(_onPositionChanged);
      widget.currentPosition?.addListener(_onPositionChanged);
    }
    if (oldWidget.navigationPosition != widget.navigationPosition) {
      oldWidget.navigationPosition?.removeListener(_onPositionChanged);
      widget.navigationPosition?.addListener(_onPositionChanged);
    }
    if (oldWidget.overlayMarkers != widget.overlayMarkers) {
      oldWidget.overlayMarkers?.removeListener(_onOverlayDataChanged);
      widget.overlayMarkers?.addListener(_onOverlayDataChanged);
    }
    if (oldWidget.offRouteTraces != widget.offRouteTraces) {
      oldWidget.offRouteTraces?.removeListener(_onOverlayDataChanged);
      widget.offRouteTraces?.addListener(_onOverlayDataChanged);
    }
  }

  @override
  void dispose() {
    _downloadCancellation?.cancel();
    widget.currentPosition?.removeListener(_onPositionChanged);
    widget.navigationPosition?.removeListener(_onPositionChanged);
    widget.overlayMarkers?.removeListener(_onOverlayDataChanged);
    widget.offRouteTraces?.removeListener(_onOverlayDataChanged);
    _mapLibreController?.onFeatureTapped.remove(_onMapLibreFeatureTapped);
    _mapController.dispose();
    _routingClient.close();
    if (widget.disposeOfflineTileCache) widget.offlineTileCache.dispose();
    super.dispose();
  }

  Future<void> _loadPersistedRoute() async {
    try {
      final route = await widget.routeStore.loadActiveRoute();
      if (!mounted) return;
      setState(() {
        _route = route;
        _progressGeometry = _routeProgressTracker.update(
          route,
          _effectivePosition,
        );
        _navigationMode = route != null && _isMoving;
        _loading = false;
      });
      widget.onRouteChanged?.call(route);
      if (_navigationMode) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(_followNavigationCamera());
        });
      }
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
    final landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final hideChrome = _route != null && _isMoving;
    final safeInsets = MediaQuery.paddingOf(context);
    final overlayTop = hideChrome ? safeInsets.top : 0.0;
    final overlayLeft = hideChrome ? safeInsets.left : 0.0;
    final overlayRight = hideChrome ? safeInsets.right : 0.0;
    final overlayBottom = hideChrome ? safeInsets.bottom : 0.0;
    final compactDensity = landscape ? VisualDensity.compact : null;
    final groupRiders = (widget.overlayMarkers?.value ?? const [])
        .where((marker) => marker.id.startsWith('rider-'))
        .toList(growable: false);
    final groupSize = groupRiders.length + (_effectivePosition == null ? 0 : 1);
    final showGroupMiniMap = landscape && _route != null && groupSize > 1;
    const groupMiniMapWidth = 196.0;
    final statusRight = showGroupMiniMap
        ? overlayRight + groupMiniMapWidth + 16
        : overlayRight + (landscape ? 68 : 12);
    final statusTop = overlayTop + (_downloadProgress == null ? 8 : 72);
    return Scaffold(
      appBar: hideChrome
          ? null
          : AppBar(
              toolbarHeight: landscape ? 42 : 52,
              titleSpacing: 12,
              title: Text(
                _route?.name ?? 'Navigation',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: landscape
                    ? Theme.of(context).textTheme.titleMedium
                    : null,
              ),
              actions: [
                IconButton(
                  tooltip: 'Plan a destination',
                  visualDensity: compactDensity,
                  onPressed: _routing ? null : _planDestination,
                  icon: _routing
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.add_road),
                ),
                if (_route == null)
                  IconButton(
                    tooltip: 'Import GPX route',
                    visualDensity: compactDensity,
                    onPressed: _importing ? null : _importGpx,
                    icon: _importing
                        ? const SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.upload_file),
                  ),
                if (_route != null)
                  IconButton(
                    tooltip: 'Navigate or export route',
                    visualDensity: compactDensity,
                    onPressed: _exporting ? null : _openNavigationExport,
                    icon: _exporting
                        ? const SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.alt_route),
                  ),
                IconButton(
                  tooltip: 'Fit route',
                  visualDensity: compactDensity,
                  onPressed: _route == null ? null : _showWholeRoute,
                  icon: const Icon(Icons.fit_screen),
                ),
                PopupMenuButton<_MapAction>(
                  iconSize: landscape ? 22 : 24,
                  padding: landscape
                      ? EdgeInsets.zero
                      : const EdgeInsets.all(8),
                  onSelected: _handleMenuAction,
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: _MapAction.importGpx,
                      child: Text(
                        _route == null
                            ? 'Import GPX route'
                            : 'Replace GPX route',
                      ),
                    ),
                    const PopupMenuItem(
                      value: _MapAction.loadDemo,
                      child: Text('Load demo route'),
                    ),
                    if (_route != null)
                      PopupMenuItem(
                        value: _MapAction.downloadOffline,
                        enabled:
                            _basemap.canDownloadOffline &&
                            _downloadProgress == null,
                        child: Text(
                          _basemap.canDownloadOffline
                              ? 'Download map for offline use'
                              : 'Offline map download unavailable',
                        ),
                      ),
                    const PopupMenuItem(
                      value: _MapAction.clearOfflineTiles,
                      child: Text('Clear downloaded map data'),
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
          : Stack(
              children: [
                Positioned.fill(
                  child: Listener(
                    behavior: HitTestBehavior.opaque,
                    onPointerDown: _onMapPointerDown,
                    onPointerMove: _onMapPointerMove,
                    onPointerUp: _onMapPointerUp,
                    onPointerCancel: _onMapPointerCancel,
                    onPointerSignal: (_) => _suppressFollowForMapGesture(),
                    child: _buildMap(),
                  ),
                ),
                if (_downloadProgress case final progress?)
                  Positioned(
                    left: overlayLeft + 12,
                    right: overlayRight + 12,
                    top: overlayTop + 12,
                    child: Card(
                      child: _DownloadProgress(
                        progress: progress,
                        onCancel: _downloadCancellation?.cancel,
                      ),
                    ),
                  ),
                if (widget.leaderStatus != null)
                  Positioned(
                    left: overlayLeft + (landscape ? 8 : 12),
                    right: statusRight,
                    top: statusTop,
                    child: ValueListenableBuilder<LeaderRideStatus?>(
                      valueListenable: widget.leaderStatus!,
                      builder: (context, status, _) => status == null
                          ? const SizedBox.shrink()
                          : _LeaderMapStatus(
                              status: status,
                              compact: landscape || hideChrome,
                              distanceUnit: widget.distanceUnit,
                            ),
                    ),
                  ),
                if (showGroupMiniMap)
                  Positioned(
                    key: const Key('group-mini-map-position'),
                    right: overlayRight + 8,
                    top: statusTop,
                    child: _GroupMiniMap(
                      width: groupMiniMapWidth,
                      route: _route!.allPoints.toList(growable: false),
                      currentPosition: _effectivePosition,
                      riders: groupRiders,
                      showTiles: _basemap.usesMapLibre,
                      mapStyleString: widget.mapStyleString,
                    ),
                  ),
                if (_route != null && !_navigationMode)
                  Positioned(
                    right: overlayRight + 12,
                    bottom: overlayBottom + 12,
                    child: FloatingActionButton.extended(
                      key: const Key('navigation-follow-button'),
                      tooltip: 'Re-centre navigation',
                      onPressed: _toggleNavigationMode,
                      backgroundColor: const Color(0xE6252E39),
                      foregroundColor: Colors.white,
                      icon: const Icon(Icons.my_location),
                      label: const Text('Re-centre'),
                    ),
                  ),
                if (_route == null)
                  Positioned.fill(
                    child: _EmptyRoutePrompt(
                      importing: _importing,
                      routing: _routing,
                      onPlanDestination: _planDestination,
                      onImport: _importGpx,
                      onLoadDemo: _loadDemoRoute,
                    ),
                  ),
              ],
            ),
    );
  }

  Widget _buildMap() {
    if (_basemap.usesMapLibre) return _buildMapLibreMap();

    final route = _route;
    final points = route?.allPoints.map(_latLng).toList(growable: false) ?? [];
    final options = points.length > 1
        ? MapOptions(
            initialCameraFit: CameraFit.bounds(
              bounds: LatLngBounds.fromPoints(points),
              padding: const EdgeInsets.all(42),
            ),
            initialZoom: 13,
            onMapEvent: _onFlutterMapEvent,
          )
        : MapOptions(
            initialCenter: points.firstOrNull ?? const LatLng(54.5, -3.2),
            initialZoom: points.isEmpty ? 5 : 14,
            onMapEvent: _onFlutterMapEvent,
          );

    final map = FlutterMap(
      key: ValueKey(route?.id ?? 'empty-map'),
      mapController: _mapController,
      options: options,
      children: [
        if (_basemap.usesLegacyRaster)
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
            polylines: [
              ..._progressGeometry.remainingPaths.map(
                (path) => Polyline(
                  points: path.map(_latLng).toList(growable: false),
                  color: const Color(0x99FFB15C),
                  strokeWidth: 5,
                  pattern: const StrokePattern.dotted(spacingFactor: 1.8),
                ),
              ),
              ..._progressGeometry.riddenPaths.map(
                (path) => Polyline(
                  points: path.map(_latLng).toList(growable: false),
                  color: const Color(0xFFFF7A1A),
                  strokeWidth: 5,
                  borderColor: const Color(0xFF10151C),
                  borderStrokeWidth: 2,
                ),
              ),
              ...(widget.offRouteTraces?.value ?? const <MapOverlayTrace>[])
                  .where((trace) => trace.points.length >= 2)
                  .map(
                    (trace) => Polyline(
                      points: trace.points.map(_latLng).toList(growable: false),
                      color: trace.color,
                      strokeWidth: 5,
                      borderColor: const Color(0xFF10151C),
                      borderStrokeWidth: 2,
                    ),
                  ),
            ],
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
        if (_effectivePosition case final currentPosition?)
          MarkerLayer(
            rotate: true,
            markers: [
              Marker(
                point: _latLng(currentPosition),
                width: 38,
                height: 38,
                child: _CurrentPositionMarker(
                  navigationMode: _route != null && _isMoving,
                  headingDegrees: _lastHeadingDegrees,
                ),
              ),
            ],
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
        if (_basemap.usesLegacyRaster)
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
      ],
    );
  }

  Widget _buildMapLibreMap() {
    final routePoints = _route?.allPoints.toList(growable: false) ?? const [];
    final initial = routePoints.isEmpty
        ? const ml.CameraPosition(target: ml.LatLng(54.5, -3.2), zoom: 5)
        : ml.CameraPosition(
            target: ml.LatLng(
              routePoints.first.latitude,
              routePoints.first.longitude,
            ),
            zoom: routePoints.length == 1 ? 14 : 11,
          );
    return Stack(
      children: [
        Positioned.fill(
          child: ml.MapLibreMap(
            styleString: widget.mapStyleString,
            initialCameraPosition: initial,
            onMapCreated: _onMapLibreCreated,
            onStyleLoadedCallback: () => unawaited(_prepareMapLibreStyle()),
            logoEnabled: false,
            compassEnabled: true,
            minMaxZoomPreference: ml.MinMaxZoomPreference(
              3,
              _basemap.maximumNativeZoom.toDouble(),
            ),
          ),
        ),
        Positioned(
          left: 8,
          bottom: 8,
          child: _MapAttributionBadge(text: _basemap.attribution),
        ),
      ],
    );
  }

  void _onMapLibreCreated(ml.MapLibreMapController controller) {
    _mapLibreController?.onFeatureTapped.remove(_onMapLibreFeatureTapped);
    _mapLibreController = controller;
    controller.onFeatureTapped.add(_onMapLibreFeatureTapped);
  }

  MapNavigationPosition? get _navigationFix => widget.navigationPosition?.value;

  GeoPoint? get _effectivePosition =>
      _navigationFix?.point ?? widget.currentPosition?.value;

  bool get _isMoving => _navigationFix?.isMoving ?? false;

  void _onPositionChanged() {
    if (!mounted) return;
    final position = _effectivePosition;
    final navigationFix = _navigationFix;
    if (navigationFix != null) {
      if (navigationFix == _lastHandledNavigationFix) return;
      _lastHandledNavigationFix = navigationFix;
      _lastHandledCurrentPosition = null;
    } else {
      if (_sameMapPoint(position, _lastHandledCurrentPosition)) return;
      _lastHandledCurrentPosition = position;
      _lastHandledNavigationFix = null;
    }
    final suppliedHeading = _navigationFix?.headingDegrees;
    if (suppliedHeading != null && suppliedHeading.isFinite) {
      _lastHeadingDegrees = suppliedHeading;
    } else if (position != null &&
        _previousNavigationPoint != null &&
        _pointsDiffer(position, _previousNavigationPoint!)) {
      _lastHeadingDegrees = _bearingDegrees(
        _previousNavigationPoint!,
        position,
      );
    }
    _previousNavigationPoint = position;

    final progressNow = navigationFix?.recordedAt ?? DateTime.now();
    final refreshProgress =
        _lastProgressUpdateAt == null ||
        progressNow.difference(_lastProgressUpdateAt!) >=
            const Duration(milliseconds: 400);
    if (refreshProgress) _lastProgressUpdateAt = progressNow;

    if (!_isMoving) _autoFollowSuppressed = false;
    final autoFollow = _route != null && _isMoving && !_autoFollowSuppressed;
    setState(() {
      if (refreshProgress) {
        _progressGeometry = _routeProgressTracker.update(_route, position);
      }
      if (autoFollow) _navigationMode = true;
    });
    _scheduleMapLibreSync(progress: refreshProgress, position: true);
    if (_navigationMode && position != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_followNavigationCamera());
      });
    }
  }

  void _onOverlayDataChanged() {
    if (!mounted) return;
    setState(() {});
    _scheduleMapLibreSync(overlays: true);
  }

  void _onFlutterMapEvent(MapEvent event) {
    if (!_navigationMode ||
        event.source == MapEventSource.mapController ||
        event.source == MapEventSource.nonRotatedSizeChange) {
      return;
    }
    if (event.source == MapEventSource.dragStart ||
        event.source == MapEventSource.multiFingerGestureStart ||
        event.source == MapEventSource.doubleTap ||
        event.source == MapEventSource.scrollWheel) {
      _stopFollowing(suppressAutomatic: _isMoving);
    }
  }

  void _onMapPointerDown(PointerDownEvent event) {
    _mapPointerOrigins[event.pointer] = event.localPosition;
    if (_mapPointerOrigins.length > 1) _suppressFollowForMapGesture();
  }

  void _onMapPointerMove(PointerMoveEvent event) {
    final origin = _mapPointerOrigins[event.pointer];
    if (origin != null && (event.localPosition - origin).distance >= 8) {
      _suppressFollowForMapGesture();
    }
  }

  void _onMapPointerUp(PointerUpEvent event) {
    _mapPointerOrigins.remove(event.pointer);
  }

  void _onMapPointerCancel(PointerCancelEvent event) {
    _mapPointerOrigins.remove(event.pointer);
  }

  void _suppressFollowForMapGesture() {
    if (_navigationMode) {
      _stopFollowing(suppressAutomatic: _isMoving);
    }
  }

  Future<void> _toggleNavigationMode() async {
    if (_navigationMode) {
      _stopFollowing(suppressAutomatic: _isMoving);
      return;
    }
    if (_effectivePosition == null) {
      final acquired = await widget.acquireCurrentPosition?.call();
      if (!mounted) return;
      if (acquired == null && _effectivePosition == null) {
        _showMessage('Allow location access to use the close navigation view.');
        return;
      }
    }
    setState(() {
      _navigationMode = true;
      _autoFollowSuppressed = false;
    });
    unawaited(_followNavigationCamera(force: true));
  }

  void _stopFollowing({required bool suppressAutomatic}) {
    if (!mounted) return;
    setState(() {
      _navigationMode = false;
      _autoFollowSuppressed = suppressAutomatic;
    });
  }

  void _showWholeRoute() {
    _stopFollowing(suppressAutomatic: _isMoving);
    _fitRoute();
  }

  Future<void> _followNavigationCamera({bool force = false}) async {
    if (!_navigationMode) return;
    final position = _effectivePosition;
    if (position == null) return;
    final now = DateTime.now();
    final previousCameraUpdate = _lastCameraUpdateAt;
    if (!force &&
        previousCameraUpdate != null &&
        now.difference(previousCameraUpdate) <
            const Duration(milliseconds: 180)) {
      return;
    }
    if (previousCameraUpdate != null) {
      final elapsed = now.difference(previousCameraUpdate).inMilliseconds;
      _cameraTransitionDuration = Duration(
        milliseconds: (elapsed * 1.08).round().clamp(180, 320),
      );
    }
    _lastCameraUpdateAt = now;
    final landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final speed = _navigationFix?.speedMetersPerSecond ?? 0;
    final lookAheadMeters = landscape
        ? (speed * 20).clamp(220, 500).toDouble()
        : (speed * 14).clamp(140, 360).toDouble();
    final target =
        _pointAlongRemainingRoute(position, lookAheadMeters) ??
        _pointAhead(position, _lastHeadingDegrees, lookAheadMeters);
    final navigationZoom = landscape ? 14.65 : 15.2;
    if (_basemap.usesMapLibre) {
      final controller = _mapLibreController;
      if (controller == null) return;
      await controller.easeCamera(
        ml.CameraUpdate.newCameraPosition(
          ml.CameraPosition(
            target: ml.LatLng(target.latitude, target.longitude),
            zoom: navigationZoom,
            tilt: landscape ? 38 : 43,
            bearing: _lastHeadingDegrees,
          ),
        ),
        duration: _cameraTransitionDuration,
        interpolation: ml.CameraAnimationInterpolation.linear,
      );
      return;
    }
    try {
      _mapController.moveAndRotateAnimatedRaw(
        _latLng(target),
        navigationZoom,
        _lastHeadingDegrees,
        offset: Offset.zero,
        duration: _cameraTransitionDuration,
        curve: Curves.linear,
        hasGesture: false,
        source: MapEventSource.mapController,
      );
    } on StateError {
      // The first position may arrive before FlutterMap has attached.
    }
  }

  Future<void> _prepareMapLibreStyle() async {
    final controller = _mapLibreController;
    if (controller == null) return;
    _mapLibreStyleReady = false;
    try {
      await controller.addGeoJsonSource(
        _remainingRouteSource,
        _remainingRouteGeoJson(),
      );
      await controller.addLineLayer(
        _remainingRouteSource,
        'ride-relay-route-remaining',
        const ml.LineLayerProperties(
          lineColor: '#FFB15C',
          lineOpacity: 0.6,
          lineWidth: 5,
          lineDasharray: [0.1, 1.8],
          lineCap: 'round',
          lineJoin: 'round',
        ),
        enableInteraction: false,
      );
      await controller.addGeoJsonSource(
        _riddenRouteSource,
        _riddenRouteGeoJson(),
      );
      await controller.addLineLayer(
        _riddenRouteSource,
        'ride-relay-route-ridden-border',
        const ml.LineLayerProperties(
          lineColor: '#10151C',
          lineWidth: 9,
          lineCap: 'round',
          lineJoin: 'round',
        ),
        enableInteraction: false,
      );
      await controller.addLineLayer(
        _riddenRouteSource,
        'ride-relay-route-ridden',
        const ml.LineLayerProperties(
          lineColor: '#FF7A1A',
          lineWidth: 5,
          lineCap: 'round',
          lineJoin: 'round',
        ),
        enableInteraction: false,
      );
      await controller.addGeoJsonSource(
        _offRouteTraceSource,
        _offRouteTraceGeoJson(),
      );
      await controller.addLineLayer(
        _offRouteTraceSource,
        'ride-relay-off-route-border',
        const ml.LineLayerProperties(
          lineColor: '#10151C',
          lineWidth: 9,
          lineCap: 'round',
          lineJoin: 'round',
        ),
        enableInteraction: false,
      );
      await controller.addLineLayer(
        _offRouteTraceSource,
        'ride-relay-off-route-line',
        const ml.LineLayerProperties(
          lineColor: '#E244C7',
          lineWidth: 5,
          lineCap: 'round',
          lineJoin: 'round',
        ),
        enableInteraction: false,
      );
      await controller.addGeoJsonSource(_waypointSource, _waypointGeoJson());
      await controller.addCircleLayer(
        _waypointSource,
        'ride-relay-waypoint-circles',
        const ml.CircleLayerProperties(
          circleRadius: 7,
          circleColor: '#FFC857',
          circleStrokeWidth: 2,
          circleStrokeColor: '#10151C',
        ),
      );
      await controller.addGeoJsonSource(_positionSource, _positionGeoJson());
      await controller.addCircleLayer(
        _positionSource,
        'ride-relay-position-circle',
        const ml.CircleLayerProperties(
          circleRadius: 8,
          circleColor: '#FFFFFF',
          circleStrokeWidth: 4,
          circleStrokeColor: '#2F80ED',
        ),
        enableInteraction: false,
      );
      await controller.addGeoJsonSource(_overlaySource, _overlayGeoJson());
      await controller.addCircleLayer(
        _overlaySource,
        'ride-relay-overlay-circles',
        const ml.CircleLayerProperties(
          circleRadius: 9,
          circleColor: ['get', 'color'],
          circleStrokeWidth: 2,
          circleStrokeColor: '#10151C',
        ),
      );
      _mapLibreStyleReady = true;
      await _syncMapLibreSources();
      if (_navigationMode) {
        await _followNavigationCamera();
      } else {
        _fitRoute();
      }
    } on Object catch (error, stackTrace) {
      debugPrint('Could not prepare MapLibre ride layers: $error\n$stackTrace');
    }
  }

  Future<void> _syncMapLibreSources() async {
    final controller = _mapLibreController;
    if (!_mapLibreStyleReady || controller == null) return;
    try {
      await controller.setGeoJsonSource(
        _remainingRouteSource,
        _remainingRouteGeoJson(),
      );
      await controller.setGeoJsonSource(
        _riddenRouteSource,
        _riddenRouteGeoJson(),
      );
      await controller.setGeoJsonSource(
        _offRouteTraceSource,
        _offRouteTraceGeoJson(),
      );
      await controller.setGeoJsonSource(_waypointSource, _waypointGeoJson());
      await controller.setGeoJsonSource(_positionSource, _positionGeoJson());
      await controller.setGeoJsonSource(_overlaySource, _overlayGeoJson());
    } on Object catch (error) {
      debugPrint('Could not refresh MapLibre ride layers: $error');
    }
  }

  void _scheduleMapLibreSync({
    bool progress = false,
    bool position = false,
    bool overlays = false,
  }) {
    _mapLibreProgressDirty |= progress;
    _mapLibrePositionDirty |= position;
    _mapLibreOverlaysDirty |= overlays;
    if (_mapLibreSyncScheduled || !mounted) return;
    _mapLibreSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _mapLibreSyncScheduled = false;
      if (mounted) unawaited(_flushScheduledMapLibreSync());
    });
  }

  Future<void> _flushScheduledMapLibreSync() async {
    if (_mapLibreSyncRunning) {
      _scheduleMapLibreSync();
      return;
    }
    final controller = _mapLibreController;
    if (!_mapLibreStyleReady || controller == null) return;
    final progress = _mapLibreProgressDirty;
    final position = _mapLibrePositionDirty;
    final overlays = _mapLibreOverlaysDirty;
    _mapLibreProgressDirty = false;
    _mapLibrePositionDirty = false;
    _mapLibreOverlaysDirty = false;
    _mapLibreSyncRunning = true;
    try {
      if (progress) {
        await controller.setGeoJsonSource(
          _remainingRouteSource,
          _remainingRouteGeoJson(),
        );
        await controller.setGeoJsonSource(
          _riddenRouteSource,
          _riddenRouteGeoJson(),
        );
      }
      if (position) {
        await controller.setGeoJsonSource(_positionSource, _positionGeoJson());
      }
      if (overlays) {
        await controller.setGeoJsonSource(
          _offRouteTraceSource,
          _offRouteTraceGeoJson(),
        );
        await controller.setGeoJsonSource(_overlaySource, _overlayGeoJson());
      }
    } on Object catch (error) {
      debugPrint('Could not refresh scheduled MapLibre layers: $error');
    } finally {
      _mapLibreSyncRunning = false;
    }
    if (_mapLibreProgressDirty ||
        _mapLibrePositionDirty ||
        _mapLibreOverlaysDirty) {
      _scheduleMapLibreSync();
    }
  }

  GeoPoint? _pointAlongRemainingRoute(
    GeoPoint currentPosition,
    double distanceAheadMeters,
  ) {
    final paths = _progressGeometry.remainingPaths
        .where((path) => path.length >= 2)
        .toList(growable: false);
    if (paths.isEmpty) return null;
    final path = paths.reduce(
      (current, candidate) =>
          _mapDistanceMeters(currentPosition, current.first) <=
              _mapDistanceMeters(currentPosition, candidate.first)
          ? current
          : candidate,
    );
    var remaining = distanceAheadMeters;
    for (var index = 0; index < path.length - 1; index += 1) {
      final start = path[index];
      final end = path[index + 1];
      final segmentLength = _mapDistanceMeters(start, end);
      if (segmentLength <= 0) continue;
      if (remaining <= segmentLength) {
        final fraction = remaining / segmentLength;
        return GeoPoint(
          latitude: start.latitude + (end.latitude - start.latitude) * fraction,
          longitude:
              start.longitude + (end.longitude - start.longitude) * fraction,
        );
      }
      remaining -= segmentLength;
    }
    return path.last;
  }

  Map<String, dynamic> _remainingRouteGeoJson() => MapGeoJson.lines(
    _progressGeometry.remainingPaths,
    idPrefix: 'remaining-route',
  );

  Map<String, dynamic> _riddenRouteGeoJson() =>
      MapGeoJson.lines(_progressGeometry.riddenPaths, idPrefix: 'ridden-route');

  Map<String, dynamic> _offRouteTraceGeoJson() => MapGeoJson.lines(
    (widget.offRouteTraces?.value ?? const <MapOverlayTrace>[]).map(
      (trace) => trace.points,
    ),
    idPrefix: 'off-route-trace',
  );

  Map<String, dynamic> _waypointGeoJson() => MapGeoJson.points(
    _route?.waypoints
            .take(500)
            .indexed
            .map(
              (entry) => MapGeoJsonPoint(
                id: 'waypoint-${entry.$1}',
                point: entry.$2.point,
                properties: {'label': entry.$2.name ?? 'GPX waypoint'},
              ),
            ) ??
        const <MapGeoJsonPoint>[],
  );

  Map<String, dynamic> _positionGeoJson() {
    final point = _effectivePosition;
    return MapGeoJson.points(
      point == null
          ? const <MapGeoJsonPoint>[]
          : [MapGeoJsonPoint(id: 'current-position', point: point)],
    );
  }

  Map<String, dynamic> _overlayGeoJson() => MapGeoJson.points(
    (widget.overlayMarkers?.value ?? const <MapOverlayMarker>[])
        .take(1000)
        .map(
          (overlay) => MapGeoJsonPoint(
            id: overlay.id,
            point: overlay.point,
            properties: {
              'label': overlay.label,
              'color': _hexColor(overlay.color),
            },
          ),
        ),
  );

  void _onMapLibreFeatureTapped(
    math.Point<double> point,
    ml.LatLng coordinates,
    String id,
    String layerId,
    ml.Annotation? annotation,
  ) {
    if (layerId != 'ride-relay-overlay-circles' &&
        layerId != 'ride-relay-waypoint-circles') {
      return;
    }
    final overlay = (widget.overlayMarkers?.value ?? const <MapOverlayMarker>[])
        .where((item) => item.id == id)
        .firstOrNull;
    final waypoint = _route?.waypoints.indexed
        .where((entry) => 'waypoint-${entry.$1}' == id)
        .map((entry) => entry.$2)
        .firstOrNull;
    final label = overlay?.label ?? waypoint?.name ?? 'GPX waypoint';
    _showMessage(label);
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

  Future<void> _planDestination() async {
    if (_routing) return;
    final request = await DestinationRouteSheet.show(context);
    if (request == null || !mounted) return;
    setState(() => _routing = true);
    try {
      var origin = _effectivePosition;
      origin ??= await widget.acquireCurrentPosition?.call();
      origin ??= _effectivePosition;
      if (origin == null) {
        throw const FormatException(
          'A current location is required. Allow location access and try again.',
        );
      }
      final planned = await _destinationRoutePlanner.plan(
        origin: origin,
        query: request.query,
        distanceUnit: widget.distanceUnit,
      );
      final route = await _activateRoute(planned);
      if (mounted) {
        final target = request.handoffTarget;
        if (target != null) await _exportRoute(target, route);
      }
    } on FormatException catch (error) {
      _showMessage(error.message);
    } on Object catch (error) {
      _showMessage('Could not plan destination: $error');
    } finally {
      if (mounted) setState(() => _routing = false);
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
    return const BundledDemoRouteLoader().load();
  }

  Future<ImportedRoute> _activateRoute(ImportedRoute route) async {
    final enrichment = await _routeGeometryEnricher.enrich(route);
    final activeRoute = enrichment.route;
    await widget.routeStore.saveActiveRoute(activeRoute);
    if (!mounted) return activeRoute;
    _routeProgressTracker.reset();
    setState(() {
      _route = activeRoute;
      _progressGeometry = _routeProgressTracker.update(
        activeRoute,
        _effectivePosition,
      );
      if (_isMoving && !_autoFollowSuppressed) _navigationMode = true;
    });
    await _syncMapLibreSources();
    _fitRoute();
    if (_navigationMode) unawaited(_followNavigationCamera());
    widget.onRouteChanged?.call(activeRoute);
    final routeMessage = enrichment.changed
        ? '${activeRoute.name}: matched to roads and stored offline '
              '(${activeRoute.pathPointCount} points).'
        : '${activeRoute.name}: ${activeRoute.pathPointCount} route points stored offline.';
    _showMessage(
      enrichment.warning == null
          ? routeMessage
          : '$routeMessage ${enrichment.warning}',
    );
    return activeRoute;
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
      final summary = _basemap.usesMapLibre
          ? await _mapLibreOfflineManager.downloadRouteRegion(
              route,
              cancellationToken: cancellation,
              onProgress: (progress) {
                if (mounted) setState(() => _downloadProgress = progress);
              },
            )
          : await widget.offlineTileCache.downloadRouteCorridor(
              route,
              cancellationToken: cancellation,
              onProgress: (progress) {
                if (mounted) setState(() => _downloadProgress = progress);
              },
            );
      _showMessage(
        summary.cancelled
            ? 'Offline map download cancelled.'
            : _basemap.usesMapLibre
            ? '${summary.totalTiles} offline map resources ready.'
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

  Future<void> _openNavigationExport() async {
    final route = _route;
    if (route == null) return;
    final target = await NavigationExportSheet.show(context);
    if (target == null || !mounted) return;
    await _exportRoute(target, route);
  }

  Future<void> _exportRoute(
    NavigationTarget target,
    ImportedRoute route,
  ) async {
    setState(() => _exporting = true);
    try {
      final renderObject = context.findRenderObject();
      final origin = renderObject is RenderBox && renderObject.hasSize
          ? renderObject.localToGlobal(Offset.zero) & renderObject.size
          : null;
      final result =
          await (widget.navigationExportCoordinator ??
                  const NavigationExportCoordinator())
              .export(target, route, sharePositionOrigin: origin);
      _showMessage(result.message);
    } catch (error) {
      _showMessage('Could not export route: $error');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  void _fitRoute() {
    final routePoints = _route?.allPoints.toList(growable: false) ?? [];
    if (_basemap.usesMapLibre) {
      final controller = _mapLibreController;
      if (controller == null || routePoints.isEmpty) return;
      if (routePoints.length == 1) {
        unawaited(
          controller.animateCamera(
            ml.CameraUpdate.newLatLngZoom(
              ml.LatLng(
                routePoints.single.latitude,
                routePoints.single.longitude,
              ),
              14,
            ),
          ),
        );
        return;
      }
      final bounds = _mapLibreBounds(routePoints);
      unawaited(
        controller.animateCamera(
          ml.CameraUpdate.newLatLngBounds(
            bounds,
            left: 42,
            top: 42,
            right: 42,
            bottom: 42,
          ),
        ),
      );
      return;
    }
    final points = routePoints.map(_latLng).toList(growable: false);
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
      case _MapAction.importGpx:
        await _importGpx();
      case _MapAction.loadDemo:
        await _loadDemoRoute();
      case _MapAction.downloadOffline:
        await _downloadOfflineMap();
      case _MapAction.removeRoute:
        await widget.routeStore.clearActiveRoute();
        if (mounted) {
          _routeProgressTracker.reset();
          setState(() {
            _route = null;
            _progressGeometry = const RouteProgressGeometry.empty();
            _navigationMode = false;
          });
          await _syncMapLibreSources();
          widget.onRouteChanged?.call(null);
        }
      case _MapAction.clearOfflineTiles:
        await _mapLibreOfflineManager.clearAll();
        await widget.offlineTileCache.clearAll();
        _showMessage('Offline map data cleared.');
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

enum _MapAction {
  importGpx,
  loadDemo,
  downloadOffline,
  removeRoute,
  clearOfflineTiles,
}

/// Neutral presentation model for hazards, group riders, markers, or other
/// feature-owned map overlays. Callers retain ownership of their domain models.
class MapNavigationPosition {
  const MapNavigationPosition({
    required this.point,
    required this.recordedAt,
    this.speedMetersPerSecond,
    this.headingDegrees,
  });

  final GeoPoint point;
  final DateTime recordedAt;
  final double? speedMetersPerSecond;
  final double? headingDegrees;

  bool get isMoving => (speedMetersPerSecond ?? 0) >= 2.5;

  @override
  bool operator ==(Object other) =>
      other is MapNavigationPosition &&
      point.latitude == other.point.latitude &&
      point.longitude == other.point.longitude &&
      recordedAt == other.recordedAt &&
      speedMetersPerSecond == other.speedMetersPerSecond &&
      headingDegrees == other.headingDegrees;

  @override
  int get hashCode => Object.hash(
    point.latitude,
    point.longitude,
    recordedAt,
    speedMetersPerSecond,
    headingDegrees,
  );
}

class MapOverlayTrace {
  const MapOverlayTrace({
    required this.id,
    required this.points,
    required this.label,
    this.color = const Color(0xFFE244C7),
  });

  final String id;
  final List<GeoPoint> points;
  final String label;
  final Color color;
}

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

bool _pointsDiffer(GeoPoint first, GeoPoint second) =>
    (first.latitude - second.latitude).abs() > 1e-7 ||
    (first.longitude - second.longitude).abs() > 1e-7;

bool _sameMapPoint(GeoPoint? first, GeoPoint? second) =>
    identical(first, second) ||
    (first != null &&
        second != null &&
        first.latitude == second.latitude &&
        first.longitude == second.longitude &&
        first.recordedAt == second.recordedAt);

double _bearingDegrees(GeoPoint from, GeoPoint to) {
  final fromLatitude = from.latitude * math.pi / 180;
  final toLatitude = to.latitude * math.pi / 180;
  final longitudeDelta = (to.longitude - from.longitude) * math.pi / 180;
  final y = math.sin(longitudeDelta) * math.cos(toLatitude);
  final x =
      math.cos(fromLatitude) * math.sin(toLatitude) -
      math.sin(fromLatitude) * math.cos(toLatitude) * math.cos(longitudeDelta);
  return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
}

double _mapDistanceMeters(GeoPoint first, GeoPoint second) {
  const earthRadiusMeters = 6371008.8;
  final latitude1 = first.latitude * math.pi / 180;
  final latitude2 = second.latitude * math.pi / 180;
  final latitudeDelta = latitude2 - latitude1;
  final longitudeDelta = (second.longitude - first.longitude) * math.pi / 180;
  final a =
      math.pow(math.sin(latitudeDelta / 2), 2) +
      math.cos(latitude1) *
          math.cos(latitude2) *
          math.pow(math.sin(longitudeDelta / 2), 2);
  return earthRadiusMeters * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}

GeoPoint _pointAhead(GeoPoint from, double bearingDegrees, double meters) {
  const earthRadiusMeters = 6371008.8;
  final angularDistance = meters / earthRadiusMeters;
  final bearing = bearingDegrees * math.pi / 180;
  final latitude = from.latitude * math.pi / 180;
  final longitude = from.longitude * math.pi / 180;
  final targetLatitude = math.asin(
    math.sin(latitude) * math.cos(angularDistance) +
        math.cos(latitude) * math.sin(angularDistance) * math.cos(bearing),
  );
  final targetLongitude =
      longitude +
      math.atan2(
        math.sin(bearing) * math.sin(angularDistance) * math.cos(latitude),
        math.cos(angularDistance) -
            math.sin(latitude) * math.sin(targetLatitude),
      );
  return GeoPoint(
    latitude: targetLatitude * 180 / math.pi,
    longitude: ((targetLongitude * 180 / math.pi + 540) % 360) - 180,
  );
}

ml.LatLngBounds _mapLibreBounds(List<GeoPoint> points) {
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
  return ml.LatLngBounds(
    southwest: ml.LatLng(south, west),
    northeast: ml.LatLng(north, east),
  );
}

String _hexColor(Color color) =>
    '#${color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}';

class _EmptyRoutePrompt extends StatelessWidget {
  const _EmptyRoutePrompt({
    required this.importing,
    required this.routing,
    required this.onPlanDestination,
    required this.onImport,
    required this.onLoadDemo,
  });

  final bool importing;
  final bool routing;
  final VoidCallback onPlanDestination;
  final VoidCallback onImport;
  final VoidCallback onLoadDemo;

  @override
  Widget build(BuildContext context) => Center(
    child: Card(
      margin: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Choose a route',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              const Text(
                'Enter a destination, import a GPX file, or use the demo route.',
                style: TextStyle(color: Color(0xFF98A3B1)),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                key: const Key('plan-destination-empty-button'),
                onPressed: routing ? null : onPlanDestination,
                icon: routing
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.add_road),
                label: const Text('Enter destination'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: importing ? null : onImport,
                icon: importing
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.upload_file),
                label: const Text('Import GPX'),
              ),
              TextButton(
                onPressed: onLoadDemo,
                child: const Text('Use demo route'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _GroupMiniMap extends StatefulWidget {
  const _GroupMiniMap({
    required this.width,
    required this.route,
    required this.currentPosition,
    required this.riders,
    required this.showTiles,
    required this.mapStyleString,
  });

  final double width;
  final List<GeoPoint> route;
  final GeoPoint? currentPosition;
  final List<MapOverlayMarker> riders;
  final bool showTiles;
  final String mapStyleString;

  @override
  State<_GroupMiniMap> createState() => _GroupMiniMapState();
}

class _GroupMiniMapState extends State<_GroupMiniMap> {
  static const _routeSource = 'ride-relay-mini-route';
  static const _riderSource = 'ride-relay-mini-riders';
  ml.MapLibreMapController? _controller;
  Timer? _refreshTimer;
  DateTime? _lastRefreshAt;
  bool _styleReady = false;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    _scheduleFit();
  }

  @override
  void didUpdateWidget(_GroupMiniMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    _scheduleRefresh();
  }

  void _scheduleFit() {
    if (!widget.showTiles) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_fitGroup());
    });
  }

  void _scheduleRefresh() {
    if (!widget.showTiles) return;
    final previous = _lastRefreshAt;
    final elapsed = previous == null
        ? const Duration(seconds: 1)
        : DateTime.now().difference(previous);
    if (elapsed >= const Duration(milliseconds: 500)) {
      _lastRefreshAt = DateTime.now();
      unawaited(_refreshMap());
      return;
    }
    _refreshTimer ??= Timer(const Duration(milliseconds: 500) - elapsed, () {
      _refreshTimer = null;
      if (!mounted) return;
      _lastRefreshAt = DateTime.now();
      unawaited(_refreshMap());
    });
  }

  @override
  Widget build(BuildContext context) {
    final riderCount =
        widget.riders.length + (widget.currentPosition == null ? 0 : 1);
    return Container(
      key: const Key('group-mini-map'),
      width: widget.width,
      height: 116,
      decoration: BoxDecoration(
        color: const Color(0xF2111820),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF566273), width: 1.5),
        boxShadow: const [
          BoxShadow(color: Colors.black54, blurRadius: 8, offset: Offset(0, 2)),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          children: [
            Positioned.fill(
              child: widget.showTiles
                  ? _buildTileMap()
                  : CustomPaint(
                      painter: _GroupMiniMapPainter(
                        route: widget.route,
                        currentPosition: widget.currentPosition,
                        riders: widget.riders,
                      ),
                    ),
            ),
            Positioned(
              left: 7,
              top: 6,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: const Color(0xD90D1117),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 3,
                  ),
                  child: Text(
                    'GROUP $riderCount',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.8,
                    ),
                  ),
                ),
              ),
            ),
            if (widget.showTiles)
              const Positioned(
                right: 3,
                bottom: 2,
                child: DecoratedBox(
                  decoration: BoxDecoration(color: Color(0xB3000000)),
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                    child: Text(
                      'OpenFreeMap · © OSM',
                      style: TextStyle(color: Colors.white, fontSize: 6),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildTileMap() {
    final groupPoints = <GeoPoint?>[
      widget.currentPosition,
      ...widget.riders.map((rider) => rider.point),
    ].nonNulls.toList(growable: false);
    final initial =
        groupPoints.firstOrNull ??
        const GeoPoint(latitude: 54.5, longitude: -3.2);
    return ml.MapLibreMap(
      key: const Key('group-mini-map-tiles'),
      styleString: widget.mapStyleString,
      initialCameraPosition: ml.CameraPosition(
        target: ml.LatLng(initial.latitude, initial.longitude),
        zoom: 13,
      ),
      onMapCreated: (controller) {
        _controller = controller;
        _scheduleFit();
      },
      onStyleLoadedCallback: () => unawaited(_prepareStyle()),
      logoEnabled: false,
      compassEnabled: false,
      rotateGesturesEnabled: false,
      scrollGesturesEnabled: false,
      tiltGesturesEnabled: false,
      zoomGesturesEnabled: false,
      doubleClickZoomEnabled: false,
      minMaxZoomPreference: const ml.MinMaxZoomPreference(5, 16),
    );
  }

  Future<void> _prepareStyle() async {
    final controller = _controller;
    if (controller == null) return;
    _styleReady = false;
    try {
      await controller.addGeoJsonSource(_routeSource, _routeGeoJson());
      await controller.addLineLayer(
        _routeSource,
        'ride-relay-mini-route-border',
        const ml.LineLayerProperties(
          lineColor: '#10151C',
          lineWidth: 5,
          lineCap: 'round',
          lineJoin: 'round',
        ),
        enableInteraction: false,
      );
      await controller.addLineLayer(
        _routeSource,
        'ride-relay-mini-route-line',
        const ml.LineLayerProperties(
          lineColor: '#FF7A1A',
          lineWidth: 3,
          lineCap: 'round',
          lineJoin: 'round',
        ),
        enableInteraction: false,
      );
      await controller.addGeoJsonSource(_riderSource, _riderGeoJson());
      await controller.addCircleLayer(
        _riderSource,
        'ride-relay-mini-rider-circles',
        const ml.CircleLayerProperties(
          circleRadius: 5,
          circleColor: ['get', 'color'],
          circleStrokeWidth: 1.5,
          circleStrokeColor: '#FFFFFF',
        ),
        enableInteraction: false,
      );
      _styleReady = true;
      await _refreshMap();
    } on Object catch (error) {
      debugPrint('Could not prepare group mini-map: $error');
    }
  }

  Future<void> _refreshMap() async {
    final controller = _controller;
    if (!_styleReady || controller == null || _refreshing) return;
    _refreshing = true;
    try {
      await controller.setGeoJsonSource(_routeSource, _routeGeoJson());
      await controller.setGeoJsonSource(_riderSource, _riderGeoJson());
      await _fitGroup();
    } on Object catch (error) {
      debugPrint('Could not refresh group mini-map: $error');
    } finally {
      _refreshing = false;
    }
  }

  Future<void> _fitGroup() async {
    final controller = _controller;
    if (controller == null) return;
    final points = <GeoPoint?>[
      widget.currentPosition,
      ...widget.riders.map((rider) => rider.point),
    ].nonNulls.toList(growable: false);
    if (points.isEmpty) return;
    if (points.length == 1) {
      await controller.animateCamera(
        ml.CameraUpdate.newLatLngZoom(
          ml.LatLng(points.single.latitude, points.single.longitude),
          14.5,
        ),
      );
      return;
    }
    await controller.animateCamera(
      ml.CameraUpdate.newLatLngBounds(
        _mapLibreBounds(points),
        left: 20,
        top: 24,
        right: 20,
        bottom: 16,
      ),
    );
  }

  Map<String, dynamic> _routeGeoJson() => MapGeoJson.lines(
    widget.route.length >= 2 ? [widget.route] : const [],
    idPrefix: 'mini-route',
  );

  Map<String, dynamic> _riderGeoJson() => MapGeoJson.points([
    for (final rider in widget.riders)
      MapGeoJsonPoint(
        id: rider.id,
        point: rider.point,
        properties: {'color': _hexColor(rider.color)},
      ),
    if (widget.currentPosition case final point?)
      MapGeoJsonPoint(
        id: 'mini-local-rider',
        point: point,
        properties: const {'color': '#FF7A1A'},
      ),
  ]);

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }
}

class _GroupMiniMapPainter extends CustomPainter {
  const _GroupMiniMapPainter({
    required this.route,
    required this.currentPosition,
    required this.riders,
  });

  final List<GeoPoint> route;
  final GeoPoint? currentPosition;
  final List<MapOverlayMarker> riders;

  @override
  void paint(Canvas canvas, Size size) {
    final groupPoints = <GeoPoint?>[
      currentPosition,
      ...riders.map((rider) => rider.point),
    ].nonNulls.toList(growable: false);
    if (groupPoints.isEmpty) return;

    var south = groupPoints.first.latitude;
    var north = groupPoints.first.latitude;
    var west = groupPoints.first.longitude;
    var east = groupPoints.first.longitude;
    for (final point in groupPoints.skip(1)) {
      south = math.min(south, point.latitude);
      north = math.max(north, point.latitude);
      west = math.min(west, point.longitude);
      east = math.max(east, point.longitude);
    }
    final latitudeCenter = (north + south) / 2;
    final longitudeCenter = (east + west) / 2;
    final latitudeSpan = math.max(north - south, 0.0024) * 1.45;
    final longitudeSpan = math.max(east - west, 0.0032) * 1.45;
    south = latitudeCenter - latitudeSpan / 2;
    north = latitudeCenter + latitudeSpan / 2;
    west = longitudeCenter - longitudeSpan / 2;
    east = longitudeCenter + longitudeSpan / 2;

    Offset project(GeoPoint point) => Offset(
      (point.longitude - west) / (east - west) * size.width,
      (north - point.latitude) / (north - south) * size.height,
    );

    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFF151E28),
    );
    final gridPaint = Paint()
      ..color = const Color(0xFF263443)
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(0, size.height * 0.5),
      Offset(size.width, size.height * 0.5),
      gridPaint,
    );
    canvas.drawLine(
      Offset(size.width * 0.5, 0),
      Offset(size.width * 0.5, size.height),
      gridPaint,
    );

    if (route.length >= 2) {
      final path = ui.Path()
        ..moveTo(project(route.first).dx, project(route.first).dy);
      final stride = math.max(1, route.length ~/ 1200);
      for (var index = stride; index < route.length; index += stride) {
        final offset = project(route[index]);
        path.lineTo(offset.dx, offset.dy);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = const Color(0xB3FFB15C)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }

    void drawRider(GeoPoint point, Color color, double radius) {
      final offset = project(point);
      canvas.drawCircle(offset, radius + 2, Paint()..color = Colors.black87);
      canvas.drawCircle(offset, radius, Paint()..color = color);
      canvas.drawCircle(
        offset,
        radius,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }

    for (final rider in riders) {
      drawRider(rider.point, rider.color, 5);
    }
    if (currentPosition case final point?) {
      drawRider(point, const Color(0xFFFF7A1A), 6);
    }
  }

  @override
  bool shouldRepaint(_GroupMiniMapPainter oldDelegate) => true;
}

class _LeaderMapStatus extends StatelessWidget {
  const _LeaderMapStatus({
    required this.status,
    required this.compact,
    required this.distanceUnit,
  });

  final LeaderRideStatus status;
  final bool compact;
  final DistanceUnit distanceUnit;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (status.offCourseAlerts.isNotEmpty) ...[
            _OffCourseBanner(
              alerts: status.offCourseAlerts,
              compact: compact,
              distanceUnit: distanceUnit,
            ),
            SizedBox(height: compact ? 4 : 8),
          ],
          _TecGapCard(
            status: status,
            compact: compact,
            distanceUnit: distanceUnit,
          ),
        ],
      ),
    ),
  );
}

class _OffCourseBanner extends StatelessWidget {
  const _OffCourseBanner({
    required this.alerts,
    required this.compact,
    required this.distanceUnit,
  });

  final List<LeaderOffCourseAlert> alerts;
  final bool compact;
  final DistanceUnit distanceUnit;

  @override
  Widget build(BuildContext context) {
    final first = alerts.first;
    final distance = first.distanceFromRouteMeters;
    final message = alerts.length == 1
        ? '${first.displayName} is clearly off course'
        : '${alerts.length} riders are clearly off course';
    return Card(
      key: const Key('leader-off-course-alert'),
      color: const Color(0xFFE2445C),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 10 : 14,
          vertical: compact ? 6 : 11,
        ),
        child: Row(
          children: [
            const Icon(Icons.warning_rounded, color: Colors.white),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    message,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  if (alerts.length == 1 && distance != null)
                    Text(
                      '${MeasurementFormatter(distanceUnit).distance(distance)} from the planned route',
                      style: const TextStyle(color: Colors.white),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TecGapCard extends StatelessWidget {
  const _TecGapCard({
    required this.status,
    required this.compact,
    required this.distanceUnit,
  });

  final LeaderRideStatus status;
  final bool compact;
  final DistanceUnit distanceUnit;

  @override
  Widget build(BuildContext context) {
    final name = status.tecName;
    final distance = status.distanceToTecMeters;
    final eta = status.estimatedTimeToTec;
    final age = status.tecLocationAge;
    final detail = name == null
        ? 'Waiting for a Tail End Charlie location'
        : distance == null || eta == null
        ? '$name · last update ${_ageLabel(age)}'
        : '$name · ${MeasurementFormatter(distanceUnit).distance(distance)} · about ${_durationLabel(eta)}';
    return Card(
      key: const Key('leader-tec-gap'),
      margin: EdgeInsets.zero,
      color: const Color(0xE6252E39),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 10 : 14,
          vertical: compact ? 5 : 10,
        ),
        child: Row(
          children: [
            const Icon(Icons.two_wheeler, color: Color(0xFF6ED89A)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'TEC GAP',
                    style: TextStyle(
                      color: Color(0xFFB7C2CF),
                      fontWeight: FontWeight.w800,
                      fontSize: 11,
                      letterSpacing: 1.1,
                    ),
                  ),
                  Text(detail, maxLines: 1, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _durationLabel(Duration duration) {
  final minutes = (duration.inSeconds / 60).ceil();
  if (minutes <= 1) return '<1 min';
  if (minutes < 60) return '$minutes min';
  final hours = minutes ~/ 60;
  final remainder = minutes % 60;
  return remainder == 0 ? '$hours hr' : '$hours hr $remainder min';
}

String _ageLabel(Duration? age) {
  if (age == null || age.inSeconds < 30) return 'just now';
  if (age.inMinutes < 1) return '${age.inSeconds}s ago';
  return '${age.inMinutes} min ago';
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
  const _CurrentPositionMarker({
    required this.navigationMode,
    required this.headingDegrees,
  });

  final bool navigationMode;
  final double headingDegrees;

  @override
  Widget build(BuildContext context) => Transform.rotate(
    angle: navigationMode ? 0 : headingDegrees * math.pi / 180,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF2F80ED),
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 3),
        boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 5)],
      ),
      child: const Icon(Icons.navigation, color: Colors.white, size: 22),
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

class _MapAttributionBadge extends StatelessWidget {
  const _MapAttributionBadge({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(maxWidth: 260),
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
    decoration: BoxDecoration(
      color: const Color(0xCC171D25),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(text, style: const TextStyle(fontSize: 9)),
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
