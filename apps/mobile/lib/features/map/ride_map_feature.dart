import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as ml;
import 'package:url_launcher/url_launcher.dart';

import '../../data/json_file_recorded_route_store.dart';
import '../../data/json_file_route_store.dart';
import '../../domain/distance_unit.dart';
import '../../domain/imported_route.dart';
import '../../domain/quick_message.dart';
import '../../domain/recorded_route_store.dart';
import '../../domain/ride_role.dart';
import '../../domain/route_store.dart';
import '../../internet/plan_directory.dart';
import '../../services/basemap_configuration.dart';
import '../../services/demo_route_loader.dart';
import '../../services/discovery_suggestion_queue.dart';
import '../../services/gpx_import_source.dart';
import '../../services/leader_ride_status.dart';
import '../../services/map_geojson.dart';
import '../../services/map_style_repository.dart';
import '../../services/maplibre_offline_manager.dart';
import '../../services/measurement_formatter.dart';
import '../../services/navigation_guidance.dart';
import '../../services/motorcycle_discovery.dart';
import '../../services/navigation_export.dart';
import '../../services/navigation_camera.dart';
import '../../services/offline_tile_cache.dart';
import '../../services/road_routing.dart';
import '../../services/route_geometry_enricher.dart';
import '../../services/route_importer.dart';
import '../../services/route_progress.dart';
import '../../services/trail_direction_arrows.dart';
import 'destination_route_sheet.dart';
import 'motorcycle_icon.dart';
import 'navigation_export_sheet.dart';
import 'route_review_screen.dart';

@visibleForTesting
bool shouldUseTiledGroupMiniMap({
  required bool mapLibreEnabled,
  required TargetPlatform platform,
}) => mapLibreEnabled && platform != TargetPlatform.android;

@visibleForTesting
Color groupMiniMapBackgroundColor(Brightness brightness) =>
    brightness == Brightness.dark
    ? const Color(0xFF151E28)
    : const Color(0xFFE9EEF3);

@visibleForTesting
Color groupMiniMapGridColor(Brightness brightness) =>
    brightness == Brightness.dark
    ? const Color(0xFF263443)
    : const Color(0xFFB8C4D0);

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
    this.groupRiderCount,
    this.onOpenRoster,
    this.junctionMarkerOverlay,
    this.emergencyContacts = const [],
    this.onEmergencyAlert,
    this.onEmergencyIssue,
    this.ridePaused = false,
    this.onLeaveRide,
    this.onOpenRideMenu,
    this.onRouteChanged,
    this.changeRouteRequestToken,
    this.onChangeRouteRequestHandled,
    this.pendingSharedGpxFile,
    this.acquireCurrentPosition,
    this.navigationExportCoordinator,
    this.routeStore,
    this.canEditRoute = true,
    this.offlineTileCache,
    this.mapLibreOfflineManager,
    this.mapStyleString,
    this.distanceUnit = DistanceUnit.kilometres,
    this.basemapConfiguration = const BasemapConfiguration(),
    this.localMotorcycleStyle = motorcycleIconStyleDefault,
    this.localBadgeColor = const Color(0xFF2F80ED),
  });

  factory RideMapFeature.fromEnvironment({
    Key? key,
    ValueListenable<GeoPoint?>? currentPosition,
    ValueListenable<MapNavigationPosition?>? navigationPosition,
    ValueListenable<List<MapOverlayMarker>>? overlayMarkers,
    ValueListenable<List<MapOverlayTrace>>? offRouteTraces,
    ValueListenable<LeaderRideStatus?>? leaderStatus,
    int? groupRiderCount,
    VoidCallback? onOpenRoster,
    ValueListenable<MapJunctionMarkerOverlay?>? junctionMarkerOverlay,
    List<MapEmergencyContact> emergencyContacts = const [],
    Future<void> Function()? onEmergencyAlert,
    Future<void> Function(QuickMessage message)? onEmergencyIssue,
    bool ridePaused = false,
    Future<void> Function()? onLeaveRide,
    Future<void> Function()? onOpenRideMenu,
    ValueChanged<ImportedRoute?>? onRouteChanged,
    Object? changeRouteRequestToken,
    VoidCallback? onChangeRouteRequestHandled,
    PickedGpxFile? pendingSharedGpxFile,
    Future<GeoPoint?> Function()? acquireCurrentPosition,
    RouteStore? routeStore,
    bool canEditRoute = true,
    DistanceUnit distanceUnit = DistanceUnit.kilometres,
    bool darkMapStyle = false,
    MotorcycleIconStyle localMotorcycleStyle = motorcycleIconStyleDefault,
    Color localBadgeColor = const Color(0xFF2F80ED),
  }) => RideMapFeature(
    key: key,
    currentPosition: currentPosition,
    navigationPosition: navigationPosition,
    overlayMarkers: overlayMarkers,
    offRouteTraces: offRouteTraces,
    leaderStatus: leaderStatus,
    groupRiderCount: groupRiderCount,
    onOpenRoster: onOpenRoster,
    junctionMarkerOverlay: junctionMarkerOverlay,
    emergencyContacts: emergencyContacts,
    onEmergencyAlert: onEmergencyAlert,
    onEmergencyIssue: onEmergencyIssue,
    ridePaused: ridePaused,
    onLeaveRide: onLeaveRide,
    onOpenRideMenu: onOpenRideMenu,
    onRouteChanged: onRouteChanged,
    changeRouteRequestToken: changeRouteRequestToken,
    onChangeRouteRequestHandled: onChangeRouteRequestHandled,
    pendingSharedGpxFile: pendingSharedGpxFile,
    acquireCurrentPosition: acquireCurrentPosition,
    routeStore: routeStore,
    canEditRoute: canEditRoute,
    distanceUnit: distanceUnit,
    basemapConfiguration: BasemapConfiguration.fromEnvironment().forBrightness(
      dark: darkMapStyle,
    ),
    localMotorcycleStyle: localMotorcycleStyle,
    localBadgeColor: localBadgeColor,
  );

  final ValueListenable<GeoPoint?>? currentPosition;
  final ValueListenable<MapNavigationPosition?>? navigationPosition;
  final ValueListenable<List<MapOverlayMarker>>? overlayMarkers;
  final ValueListenable<List<MapOverlayTrace>>? offRouteTraces;
  final ValueListenable<LeaderRideStatus?>? leaderStatus;
  final int? groupRiderCount;
  final VoidCallback? onOpenRoster;
  final ValueListenable<MapJunctionMarkerOverlay?>? junctionMarkerOverlay;
  final List<MapEmergencyContact> emergencyContacts;
  final Future<void> Function()? onEmergencyAlert;
  final Future<void> Function(QuickMessage message)? onEmergencyIssue;
  final bool ridePaused;
  final Future<void> Function()? onLeaveRide;
  final Future<void> Function()? onOpenRideMenu;
  final ValueChanged<ImportedRoute?>? onRouteChanged;
  final Object? changeRouteRequestToken;
  final VoidCallback? onChangeRouteRequestHandled;
  final PickedGpxFile? pendingSharedGpxFile;
  final Future<GeoPoint?> Function()? acquireCurrentPosition;
  final NavigationExportCoordinator? navigationExportCoordinator;
  final RouteStore? routeStore;
  final bool canEditRoute;
  final OfflineTileCache? offlineTileCache;
  final MapLibreOfflineManager? mapLibreOfflineManager;
  final String? mapStyleString;
  final DistanceUnit distanceUnit;
  final BasemapConfiguration basemapConfiguration;
  final MotorcycleIconStyle localMotorcycleStyle;
  final Color localBadgeColor;

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
    // Supplying all three map dependencies keeps integration tests and
    // embedders independent of platform storage while production continues to
    // use the default persistent stores below.
    final suppliedStore = widget.routeStore;
    final suppliedCache = widget.offlineTileCache;
    final suppliedStyle = widget.mapStyleString;
    if (suppliedStore != null &&
        suppliedCache != null &&
        suppliedStyle != null) {
      return _MapDependencies(
        store: suppliedStore,
        cache: suppliedCache,
        mapLibreOfflineManager:
            widget.mapLibreOfflineManager ??
            MapLibreOfflineManager(configuration: widget.basemapConfiguration),
        mapStyleString: suppliedStyle,
      );
    }
    final styleRepository = await MapStyleRepository.openDefault(
      widget.basemapConfiguration,
    );
    try {
      return _MapDependencies(
        store: suppliedStore ?? await JsonFileRouteStore.openDefault(),
        cache:
            suppliedCache ??
            await OfflineTileCache.openDefault(widget.basemapConfiguration),
        mapLibreOfflineManager:
            widget.mapLibreOfflineManager ??
            MapLibreOfflineManager(configuration: widget.basemapConfiguration),
        mapStyleString: suppliedStyle ?? await styleRepository.resolve(),
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
        disposeOfflineTileCache: widget.offlineTileCache == null,
        currentPosition: widget.currentPosition,
        navigationPosition: widget.navigationPosition,
        overlayMarkers: widget.overlayMarkers,
        offRouteTraces: widget.offRouteTraces,
        leaderStatus: widget.leaderStatus,
        groupRiderCount: widget.groupRiderCount,
        onOpenRoster: widget.onOpenRoster,
        junctionMarkerOverlay: widget.junctionMarkerOverlay,
        emergencyContacts: widget.emergencyContacts,
        onEmergencyAlert: widget.onEmergencyAlert,
        onEmergencyIssue: widget.onEmergencyIssue,
        ridePaused: widget.ridePaused,
        onLeaveRide: widget.onLeaveRide,
        onOpenRideMenu: widget.onOpenRideMenu,
        canEditRoute: widget.canEditRoute,
        onRouteChanged: widget.onRouteChanged,
        changeRouteRequestToken: widget.changeRouteRequestToken,
        onChangeRouteRequestHandled: widget.onChangeRouteRequestHandled,
        pendingSharedGpxFile: widget.pendingSharedGpxFile,
        acquireCurrentPosition: widget.acquireCurrentPosition,
        navigationExportCoordinator: widget.navigationExportCoordinator,
        distanceUnit: widget.distanceUnit,
        localMotorcycleStyle: widget.localMotorcycleStyle,
        localBadgeColor: widget.localBadgeColor,
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
    this.planDirectory,
    required this.offlineTileCache,
    this.mapLibreOfflineManager,
    this.mapStyleString = MapStyleRepository.fallbackStyle,
    this.currentPosition,
    this.navigationPosition,
    this.overlayMarkers,
    this.offRouteTraces,
    this.leaderStatus,
    this.groupRiderCount,
    this.onOpenRoster,
    this.junctionMarkerOverlay,
    this.emergencyContacts = const [],
    this.onEmergencyAlert,
    this.onEmergencyIssue,
    this.ridePaused = false,
    this.onLeaveRide,
    this.onOpenRideMenu,
    this.canEditRoute = true,
    this.onRouteChanged,
    this.changeRouteRequestToken,
    this.onChangeRouteRequestHandled,
    this.pendingSharedGpxFile,
    this.acquireCurrentPosition,
    this.navigationExportCoordinator,
    this.destinationRoutePlanner,
    this.routeGeometryEnricher,
    this.demoRouteLoader,
    this.recordedRouteStore,
    this.distanceUnit = DistanceUnit.kilometres,
    this.disposeOfflineTileCache = false,
    this.localMotorcycleStyle = motorcycleIconStyleDefault,
    this.localBadgeColor = const Color(0xFF2F80ED),
  });

  final RouteStore routeStore;
  final RouteImporter routeImporter;
  final PlanDirectory? planDirectory;
  final OfflineTileCache offlineTileCache;
  final MapLibreOfflineManager? mapLibreOfflineManager;
  final String mapStyleString;
  final ValueListenable<GeoPoint?>? currentPosition;
  final ValueListenable<MapNavigationPosition?>? navigationPosition;
  final ValueListenable<List<MapOverlayMarker>>? overlayMarkers;
  final ValueListenable<List<MapOverlayTrace>>? offRouteTraces;
  final ValueListenable<LeaderRideStatus?>? leaderStatus;
  final int? groupRiderCount;
  final VoidCallback? onOpenRoster;
  final ValueListenable<MapJunctionMarkerOverlay?>? junctionMarkerOverlay;
  final List<MapEmergencyContact> emergencyContacts;
  final Future<void> Function()? onEmergencyAlert;
  final Future<void> Function(QuickMessage message)? onEmergencyIssue;
  final bool ridePaused;
  final Future<void> Function()? onLeaveRide;
  final Future<void> Function()? onOpenRideMenu;
  final bool canEditRoute;
  final ValueChanged<ImportedRoute?>? onRouteChanged;
  final Object? changeRouteRequestToken;
  final VoidCallback? onChangeRouteRequestHandled;
  final PickedGpxFile? pendingSharedGpxFile;
  final Future<GeoPoint?> Function()? acquireCurrentPosition;
  final NavigationExportCoordinator? navigationExportCoordinator;
  final DestinationRoutePlanner? destinationRoutePlanner;
  final RouteGeometryEnricher? routeGeometryEnricher;
  final Future<ImportedRoute> Function()? demoRouteLoader;
  final RecordedRouteStore? recordedRouteStore;
  final DistanceUnit distanceUnit;
  final bool disposeOfflineTileCache;
  final MotorcycleIconStyle localMotorcycleStyle;
  final Color localBadgeColor;

  @override
  State<RideMapScreen> createState() => _RideMapScreenState();
}

class _RideMapScreenState extends State<RideMapScreen> {
  static const _remainingRouteSource = 'ride-relay-route-remaining';
  static const _riddenRouteSource = 'ride-relay-route-ridden';
  static const _offRouteTraceSource = 'ride-relay-off-route-traces';
  static const _trailDirectionArrowSource = 'ride-relay-trail-direction-arrows';
  static const _waypointSource = 'ride-relay-waypoints';
  static const _positionSource = 'ride-relay-position';
  static const _overlaySource = 'ride-relay-overlays';
  static const _trailDirectionArrowImage = 'ride-relay-trail-direction-arrow';
  static const _trailDirectionArrowSampler = TrailDirectionArrowSampler();
  static const _navigationGuidancePlanner = NavigationGuidancePlanner();
  static const _discoveryLineSource = 'ride-relay-discovery-lines';
  static const _discoveryPointSource = 'ride-relay-discovery-points';

  final MapControllerImpl _mapController = MapControllerImpl();
  final RouteProgressTracker _routeProgressTracker = RouteProgressTracker();
  final ValueNotifier<NavigationGuidance?> _navigationGuidance = ValueNotifier(
    null,
  );
  final Map<int, Offset> _mapPointerOrigins = {};
  late final http.Client _routingClient;
  late final RoadRoutingService _roadRoutingService;
  late final Future<DiscoverySuggestionQueue> _suggestionQueue;
  late final DiscoverySuggestionConfiguration _suggestionConfiguration;
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
  bool _navigationCanvasActive = false;
  bool _markerOverviewVisible = false;
  bool _autoFollowSuppressed = false;
  bool _emergencyAlertSending = false;
  bool _emergencyAlertSent = false;
  bool _emergencyActionsOpen = false;
  bool _emergencyActionsDismissed = false;
  Object? _handledChangeRouteRequestToken;
  double _lastHeadingDegrees = 0;
  double? _smoothedNavigationSpeedMetersPerSecond;
  GeoPoint? _previousNavigationPoint;
  MapNavigationPosition? _lastHandledNavigationFix;
  GeoPoint? _lastHandledCurrentPosition;
  DateTime? _lastCameraUpdateAt;
  DateTime? _lastProgressUpdateAt;
  DateTime? _lastMapLibrePositionSyncAt;
  Duration _cameraTransitionDuration = const Duration(milliseconds: 450);
  bool _cameraUpdateInFlight = false;
  bool _cameraUpdateQueued = false;
  bool _initialCameraPositioned = false;
  bool _mapLibreSyncScheduled = false;
  bool _mapLibreSyncRunning = false;
  bool _mapLibreProgressDirty = false;
  bool _mapLibrePositionDirty = false;
  bool _mapLibreOverlaysDirty = false;
  RouteProgressGeometry _progressGeometry = const RouteProgressGeometry.empty();
  TileDownloadProgress? _downloadProgress;
  TileDownloadCancellationToken? _downloadCancellation;
  MotorcycleDiscoveryCatalogue _discoveryCatalogue =
      const MotorcycleDiscoveryCatalogue([]);
  final Set<MotorcycleDiscoveryCategory> _enabledDiscoveryCategories = {};

  BasemapConfiguration get _basemap => widget.offlineTileCache.configuration;

  DestinationRoutePlanner get _destinationRoutePlanner =>
      widget.destinationRoutePlanner ?? _defaultDestinationRoutePlanner;

  RouteGeometryEnricher get _routeGeometryEnricher =>
      widget.routeGeometryEnricher ?? _defaultRouteGeometryEnricher;

  @override
  void initState() {
    super.initState();
    _routingClient = http.Client();
    _suggestionQueue = DiscoverySuggestionQueue.openDefault();
    _suggestionConfiguration =
        DiscoverySuggestionConfiguration.fromEnvironment();
    final routingConfiguration = RoutingConfiguration.fromEnvironment();
    _roadRoutingService = OsrmRoadRoutingService(
      client: _routingClient,
      baseUrl: routingConfiguration.routingBaseUrl,
    );
    _defaultDestinationRoutePlanner = DestinationRoutePlanner(
      searchService: NominatimDestinationSearchService(
        client: _routingClient,
        baseUrl: routingConfiguration.geocodingBaseUrl,
      ),
      routingService: _roadRoutingService,
    );
    _defaultRouteGeometryEnricher = RouteGeometryEnricher(
      routingService: _roadRoutingService,
    );
    _mapLibreOfflineManager =
        widget.mapLibreOfflineManager ??
        MapLibreOfflineManager(configuration: _basemap);
    widget.currentPosition?.addListener(_onPositionChanged);
    widget.navigationPosition?.addListener(_onPositionChanged);
    widget.overlayMarkers?.addListener(_onOverlayDataChanged);
    widget.offRouteTraces?.addListener(_onOverlayDataChanged);
    widget.junctionMarkerOverlay?.addListener(_onJunctionMarkerChanged);
    _markerOverviewVisible =
        widget.junctionMarkerOverlay?.value?.isLocalMarker ?? false;
    _loadPersistedRoute();
    unawaited(_loadDiscoveryCatalogue());
    _maybeHandleChangeRouteRequest();
  }

  @override
  void didUpdateWidget(RideMapScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.changeRouteRequestToken != widget.changeRouteRequestToken) {
      _maybeHandleChangeRouteRequest();
    }
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
    if (oldWidget.junctionMarkerOverlay != widget.junctionMarkerOverlay) {
      oldWidget.junctionMarkerOverlay?.removeListener(_onJunctionMarkerChanged);
      widget.junctionMarkerOverlay?.addListener(_onJunctionMarkerChanged);
      _onJunctionMarkerChanged();
    }
  }

  @override
  void dispose() {
    _downloadCancellation?.cancel();
    widget.currentPosition?.removeListener(_onPositionChanged);
    widget.navigationPosition?.removeListener(_onPositionChanged);
    widget.overlayMarkers?.removeListener(_onOverlayDataChanged);
    widget.offRouteTraces?.removeListener(_onOverlayDataChanged);
    widget.junctionMarkerOverlay?.removeListener(_onJunctionMarkerChanged);
    _mapLibreController?.onFeatureTapped.remove(_onMapLibreFeatureTapped);
    _mapController.dispose();
    _navigationGuidance.dispose();
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
        _navigationMode = route != null && _isMoving && !_markerOverviewVisible;
        // Once we have a route and a position, keep the map canvas at its
        // navigation size. Tying this to the instantaneous speed made the
        // AppBar appear briefly whenever a GPS update arrived while stopped.
        _navigationCanvasActive = route != null && _effectivePosition != null;
        _initialCameraPositioned = false;
        _loading = false;
      });
      _updateNavigationGuidance(_effectivePosition);
      widget.onRouteChanged?.call(route);
      if (_navigationMode) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(_followNavigationCamera());
        });
      }
      if (_markerOverviewVisible) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(_showMarkerOverview());
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

  Future<void> _loadDiscoveryCatalogue() async {
    try {
      final catalogue = await MotorcycleDiscoveryCatalogue.loadAsset();
      if (!mounted) return;
      setState(() => _discoveryCatalogue = catalogue);
      _scheduleMapLibreSync(overlays: true);
    } on Object catch (error) {
      if (kDebugMode) debugPrint('Could not load discovery catalogue: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final markerOverlay = widget.junctionMarkerOverlay?.value;
    final localMarkerOverlay = markerOverlay?.isLocalMarker == true
        ? markerOverlay
        : null;
    final markerOverviewActive = localMarkerOverlay != null;
    // Once navigation has started, retain the full map canvas through brief
    // traffic-light or GPS speed dips. Switching the AppBar in and out changes
    // the platform map's size and was the main source of visible flashing.
    final hideChrome =
        _route != null && (_navigationCanvasActive || markerOverviewActive);
    final safeInsets = MediaQuery.paddingOf(context);
    final overlayTop = hideChrome ? safeInsets.top : 0.0;
    final overlayLeft = hideChrome ? safeInsets.left : 0.0;
    final overlayRight = hideChrome ? safeInsets.right : 0.0;
    final overlayBottom = hideChrome ? safeInsets.bottom : 0.0;
    final compactDensity = landscape ? VisualDensity.compact : null;
    // The group mini-map owns its own ValueListenableBuilder below. This
    // avoids relying on a parent platform-map rebuild to notice rider updates,
    // which left the portrait mini-map absent in the live simulator.
    final canShowGroupMiniMap =
        _route != null &&
        widget.overlayMarkers != null &&
        !markerOverviewActive;
    final groupMiniMapWidth = landscape ? 196.0 : 150.0;
    final groupMiniMapHeight = landscape ? 116.0 : 104.0;
    final showRideMenu = hideChrome && widget.onOpenRideMenu != null;
    final statusLeft =
        overlayLeft +
        (showRideMenu
            ? 60
            : landscape
            ? 8
            : 12);
    final statusRight = landscape && canShowGroupMiniMap
        ? overlayRight + groupMiniMapWidth + 16
        : overlayRight + (landscape ? 68 : 12);
    final statusTop = overlayTop + (_downloadProgress == null ? 8 : 72);
    final hasGuidance = _route?.maneuvers.isNotEmpty ?? false;
    final guidanceOffset = hasGuidance ? (landscape ? 62.0 : 74.0) : 0.0;
    final leaderStatusTop = statusTop + guidanceOffset;
    final emergencyBottom =
        overlayBottom + (markerOverviewActive && !landscape ? 254.0 : 54.0);
    final showLeaveRide = _route != null && widget.onLeaveRide != null;
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
                if (widget.canEditRoute)
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
                if (widget.canEditRoute && _route == null)
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
                    if (widget.canEditRoute) ...[
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
                    ],
                    const PopupMenuItem(
                      value: _MapAction.discoveryLayers,
                      child: Text('Motorcycle discovery layers'),
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
                    if (widget.canEditRoute && _route != null)
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
                if (showRideMenu)
                  Positioned(
                    left: overlayLeft + 10,
                    top: overlayTop + 8,
                    child: FloatingActionButton.small(
                      key: const Key('ride-menu-button'),
                      heroTag: 'ride-relay-menu',
                      tooltip: 'Ride menu',
                      onPressed: widget.onOpenRideMenu,
                      backgroundColor: const Color(0xE6252E39),
                      foregroundColor: Colors.white,
                      child: const Icon(Icons.menu),
                    ),
                  ),
                if (widget.leaderStatus != null)
                  Positioned(
                    left: statusLeft,
                    right: statusRight,
                    top: leaderStatusTop,
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
                if (hasGuidance)
                  Positioned(
                    left: statusLeft,
                    right: statusRight,
                    top: statusTop,
                    child: ValueListenableBuilder<NavigationGuidance?>(
                      valueListenable: _navigationGuidance,
                      builder: (context, guidance, _) => guidance == null
                          ? const SizedBox.shrink()
                          : _NavigationGuidanceBanner(
                              guidance: guidance,
                              distanceUnit: widget.distanceUnit,
                              compact: landscape,
                            ),
                    ),
                  ),
                if (canShowGroupMiniMap)
                  Positioned(
                    key: const Key('group-mini-map-position'),
                    right: overlayRight + 8,
                    // In portrait the overview sits beneath the TEC card so
                    // it does not compress the status text into an unusable
                    // narrow strip.
                    top: landscape
                        ? statusTop
                        : leaderStatusTop +
                              (widget.leaderStatus == null ? 24 : 96),
                    child: ValueListenableBuilder<List<MapOverlayMarker>>(
                      valueListenable: widget.overlayMarkers!,
                      builder: (context, overlays, _) {
                        final groupRiders = overlays
                            .where((marker) => marker.id.startsWith('rider-'))
                            .toList(growable: false);
                        final groupSize =
                            widget.groupRiderCount ??
                            groupRiders.length +
                                (_effectivePosition == null ? 0 : 1);
                        if (groupSize <= 1) return const SizedBox.shrink();
                        return _GroupMiniMap(
                          width: groupMiniMapWidth,
                          height: groupMiniMapHeight,
                          routePaths: _route!.paths
                              .map((path) => path.points)
                              .where((points) => points.length >= 2)
                              .toList(growable: false),
                          currentPosition: _effectivePosition,
                          riders: groupRiders,
                          riderCount: groupSize,
                          onTap: widget.onOpenRoster,
                          showTiles: shouldUseTiledGroupMiniMap(
                            mapLibreEnabled: _basemap.usesMapLibre,
                            platform: defaultTargetPlatform,
                          ),
                          mapStyleString: widget.mapStyleString,
                        );
                      },
                    ),
                  ),
                if (localMarkerOverlay != null)
                  Positioned(
                    key: const Key('junction-marker-overlay-position'),
                    left: overlayLeft + 12,
                    right: overlayRight + 12,
                    bottom: overlayBottom + 12,
                    child: ValueListenableBuilder<MapJunctionMarkerOverlay?>(
                      valueListenable: widget.junctionMarkerOverlay!,
                      builder: (context, overlay, _) {
                        if (overlay == null || !overlay.isLocalMarker) {
                          return const SizedBox.shrink();
                        }
                        return LayoutBuilder(
                          builder: (context, constraints) => Align(
                            alignment: Alignment.bottomRight,
                            child: _JunctionMarkerOverlay(
                              overlay: overlay,
                              compact: landscape,
                              maxWidth: landscape
                                  ? math.min(312.0, constraints.maxWidth)
                                  : constraints.maxWidth,
                              distanceUnit: widget.distanceUnit,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                if (_route != null && !_navigationMode && !markerOverviewActive)
                  Positioned(
                    right: overlayRight + 12,
                    bottom: overlayBottom + 12,
                    child: FloatingActionButton.extended(
                      key: const Key('navigation-follow-button'),
                      tooltip: 'Follow my location',
                      onPressed: _toggleNavigationMode,
                      backgroundColor: const Color(0xE6252E39),
                      foregroundColor: Colors.white,
                      icon: const Icon(Icons.navigation_outlined),
                      label: const Text('Follow me'),
                    ),
                  ),
                if (_route != null && widget.onEmergencyAlert != null)
                  Positioned(
                    left: overlayLeft + 12,
                    bottom: emergencyBottom,
                    child: FloatingActionButton.extended(
                      key: const Key('emergency-alert-button'),
                      heroTag: 'ride-relay-emergency-alert',
                      tooltip: 'Alert leader and TEC',
                      onPressed: _emergencyAlertSending
                          ? null
                          : _triggerEmergencyAlert,
                      backgroundColor: const Color(0xFFD9304F),
                      foregroundColor: Colors.white,
                      icon: _emergencyAlertSending
                          ? const SizedBox.square(
                              dimension: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : Icon(
                              _emergencyAlertSent
                                  ? Icons.check_circle
                                  : Icons.sos,
                            ),
                      label: Text(_emergencyAlertSent ? 'ALERT SENT' : 'ALERT'),
                    ),
                  ),
                if (showLeaveRide)
                  Positioned(
                    left: overlayLeft + 12,
                    bottom: emergencyBottom + 62,
                    child: FloatingActionButton.extended(
                      key: const Key('leave-ride-button'),
                      heroTag: 'ride-relay-leave',
                      tooltip: 'Stop sharing and leave this ride',
                      onPressed: widget.onLeaveRide,
                      backgroundColor: const Color(0xFF545F6E),
                      foregroundColor: Colors.white,
                      icon: const Icon(Icons.exit_to_app),
                      label: const Text('LEAVE'),
                    ),
                  ),
                if (_route != null && widget.ridePaused)
                  Positioned(
                    left: overlayLeft + 12,
                    right: overlayRight + 12,
                    top: statusTop + (showRideMenu ? 48 : 0),
                    child: const _RidePausedBanner(),
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
        if (_visibleDiscoveryFeatures.any((feature) => !feature.isPoint))
          PolylineLayer(
            polylines: _visibleDiscoveryFeatures
                .where((feature) => !feature.isPoint)
                .map(
                  (feature) => Polyline(
                    points: feature.points.map(_latLng).toList(growable: false),
                    color: _discoveryColour(feature.category),
                    strokeWidth: 4,
                    borderColor: const Color(0xCC10151C),
                    borderStrokeWidth: 2,
                    pattern:
                        feature.category ==
                            MotorcycleDiscoveryCategory.twistyHighlight
                        ? StrokePattern.dashed(segments: const [8, 6])
                        : const StrokePattern.solid(),
                  ),
                )
                .toList(growable: false),
          ),
        if (_visibleDiscoveryFeatures.isNotEmpty)
          MarkerLayer(
            markers: _visibleDiscoveryFeatures
                .map(
                  (feature) => Marker(
                    point: _latLng(feature.anchor),
                    width: 40,
                    height: 40,
                    child: Semantics(
                      button: true,
                      label: '${feature.category.label}: ${feature.name}',
                      child: GestureDetector(
                        onTap: () => _showDiscoveryFeature(feature),
                        child: Icon(
                          feature.category ==
                                  MotorcycleDiscoveryCategory.mountainPass
                              ? Icons.terrain
                              : Icons.route,
                          color: _discoveryColour(feature.category),
                          size: 30,
                          shadows: const [
                            Shadow(color: Color(0xFF10151C), blurRadius: 4),
                          ],
                        ),
                      ),
                    ),
                  ),
                )
                .toList(growable: false),
          ),
        if (route != null)
          PolylineLayer(
            polylines: [
              ..._progressGeometry.remainingPaths.map(
                (path) => Polyline(
                  points: path.map(_latLng).toList(growable: false),
                  color: const Color(0xE63478F6),
                  strokeWidth: 5,
                  borderColor: const Color(0xFF10151C),
                  borderStrokeWidth: 2,
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
        if (route != null)
          MarkerLayer(
            key: const Key('trail-direction-arrow-layer'),
            markers: _trailDirectionArrows()
                .map(
                  (item) => Marker(
                    point: _latLng(item.arrow.point),
                    width: 24,
                    height: 24,
                    child: Semantics(
                      label: item.semanticLabel,
                      child: Transform.rotate(
                        angle: item.arrow.bearingDegrees * math.pi / 180,
                        child: Icon(
                          Icons.navigation_rounded,
                          color: item.color,
                          size: 18,
                          shadows: const [
                            Shadow(color: Color(0xFF10151C), blurRadius: 4),
                            Shadow(color: Color(0xFF10151C), blurRadius: 4),
                          ],
                        ),
                      ),
                    ),
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
                  style: widget.localMotorcycleStyle,
                  badgeColor: widget.localBadgeColor,
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
                        child: overlay.motorcycleStyle == null
                            ? _IconBadge(
                                icon: overlay.icon,
                                badgeColor: overlay.color,
                                size: 34,
                              )
                            : RiderMarkerBadge(
                                style: overlay.motorcycleStyle!,
                                badgeColor: overlay.color,
                                size: 34,
                              ),
                      ),
                    ),
                  )
                  .toList(growable: false),
            ),
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
    if (navigationFix?.speedMetersPerSecond case final speed?
        when speed.isFinite) {
      final boundedSpeed = speed.clamp(0.0, 50.0);
      final previousSpeed = _smoothedNavigationSpeedMetersPerSecond;
      _smoothedNavigationSpeedMetersPerSecond = previousSpeed == null
          ? boundedSpeed
          : previousSpeed * 0.72 + boundedSpeed * 0.28;
    }

    final progressNow = navigationFix?.recordedAt ?? DateTime.now();
    final refreshProgress =
        _lastProgressUpdateAt == null ||
        progressNow.difference(_lastProgressUpdateAt!) >=
            const Duration(milliseconds: 400);
    if (refreshProgress) _lastProgressUpdateAt = progressNow;
    final refreshMapLibrePosition =
        !_basemap.usesMapLibre ||
        _lastMapLibrePositionSyncAt == null ||
        progressNow.difference(_lastMapLibrePositionSyncAt!) >=
            const Duration(milliseconds: 250);
    if (refreshMapLibrePosition) _lastMapLibrePositionSyncAt = progressNow;

    if (!_isMoving) _autoFollowSuppressed = false;
    final offerEmergencyActions =
        _emergencyAlertSent &&
        !_isMoving &&
        !_emergencyActionsOpen &&
        !_emergencyActionsDismissed;
    final autoFollow = _route != null && _isMoving && !_autoFollowSuppressed;
    final enableNavigationMode = autoFollow && !_navigationMode;
    final activateNavigationCanvas =
        _route != null && position != null && !_navigationCanvasActive;
    if (refreshProgress) {
      _progressGeometry = _routeProgressTracker.update(_route, position);
      _updateNavigationGuidance(position);
    }
    // MapLibre receives sources directly. Keep its platform view mounted while
    // the simulation is running; only FlutterMap needs a widget rebuild for
    // fresh route-progress geometry.
    if (!_basemap.usesMapLibre ||
        enableNavigationMode ||
        activateNavigationCanvas) {
      setState(() {
        if (activateNavigationCanvas) _navigationCanvasActive = true;
        if (autoFollow) {
          _navigationMode = true;
          _navigationCanvasActive = true;
        }
      });
    }
    _scheduleMapLibreSync(
      progress: refreshProgress,
      position: refreshMapLibrePosition,
    );
    if (_navigationMode && position != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_followNavigationCamera());
      });
    }
    if (offerEmergencyActions) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_showEmergencyActions());
      });
    }
  }

  void _updateNavigationGuidance(GeoPoint? position) {
    final next = _navigationGuidancePlanner.plan(
      route: _route,
      position: position,
      progressMeters: _progressGeometry.progressMeters,
    );
    final current = _navigationGuidance.value;
    final unchanged =
        current?.maneuver == next?.maneuver &&
        current != null &&
        next != null &&
        (current.distanceMeters - next.distanceMeters).abs() < 5;
    if (!unchanged) _navigationGuidance.value = next;
  }

  void _onOverlayDataChanged() {
    if (!mounted) return;
    // The mini-map listens to rider updates itself. Rebuilding the parent
    // platform map here can resize it and briefly bring the top chrome back.
    if (!_basemap.usesMapLibre) setState(() {});
    _scheduleMapLibreSync(overlays: true);
  }

  void _onJunctionMarkerChanged() {
    if (!mounted) return;
    final visible = widget.junctionMarkerOverlay?.value?.isLocalMarker ?? false;
    if (visible == _markerOverviewVisible) return;
    setState(() {
      _markerOverviewVisible = visible;
      if (visible) {
        _navigationMode = false;
        _autoFollowSuppressed = false;
      } else if (_route != null && _effectivePosition != null) {
        _navigationMode = true;
        _navigationCanvasActive = true;
        _autoFollowSuppressed = false;
      }
    });
    if (visible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_showMarkerOverview());
      });
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(
            _followNavigationCamera(
              force: true,
              transitionDuration: const Duration(milliseconds: 700),
            ),
          );
        }
      });
    }
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
      _navigationCanvasActive = true;
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

  Future<void> _triggerEmergencyAlert() async {
    final send = widget.onEmergencyAlert;
    if (send == null || _emergencyAlertSending) return;
    setState(() => _emergencyAlertSending = true);
    try {
      await send();
      if (!mounted) return;
      setState(() {
        _emergencyAlertSending = false;
        _emergencyAlertSent = true;
        _emergencyActionsDismissed = false;
      });
      _showMessage('Emergency alert sent to ${_emergencyContactLabel()}.');
      if (!_isMoving) unawaited(_showEmergencyActions());
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _emergencyAlertSending = false);
      _showMessage('Could not send emergency alert: $error');
    }
  }

  String _emergencyContactLabel() {
    final contacts = widget.emergencyContacts;
    if (contacts.isEmpty) return 'the ride group';
    return contacts.map((contact) => contact.shortRoleLabel).join(' and ');
  }

  Future<void> _showEmergencyActions() async {
    if (!_emergencyAlertSent || _isMoving || _emergencyActionsOpen) return;
    _emergencyActionsOpen = true;
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (context) => _EmergencyActionsSheet(
          contacts: widget.emergencyContacts,
          onIssueSelected: _sendEmergencyIssue,
          onOpenMessages: _openEmergencyMessages,
        ),
      );
    } finally {
      _emergencyActionsOpen = false;
      _emergencyActionsDismissed = true;
    }
  }

  Future<void> _sendEmergencyIssue(QuickMessage message) async {
    final send = widget.onEmergencyIssue;
    if (send == null) return;
    await send(message);
    if (!mounted) return;
    _showMessage('${message.label} sent to ${_emergencyContactLabel()}.');
  }

  Future<void> _openEmergencyMessages() async {
    final opened = await launchUrl(
      Uri(
        scheme: 'sms',
        queryParameters: {
          'body': 'Tail End Charlie: I have stopped and need assistance.',
        },
      ),
      mode: LaunchMode.externalApplication,
    );
    if (!opened && mounted) {
      _showMessage('Could not open Messages on this device.');
    }
  }

  void _showWholeRoute() {
    _stopFollowing(suppressAutomatic: _isMoving);
    _fitRoute();
  }

  Future<void> _showMarkerOverview() async {
    final overlay = widget.junctionMarkerOverlay?.value;
    if (overlay == null || !overlay.isLocalMarker) return;
    final points = <GeoPoint>[overlay.markerPoint];
    final localPosition = _effectivePosition;
    if (localPosition != null) points.add(localPosition);
    for (final rider in widget.overlayMarkers?.value ?? const []) {
      if (!rider.id.startsWith('rider-')) continue;
      if (_mapDistanceMeters(overlay.markerPoint, rider.point) <= 1600) {
        points.add(rider.point);
      }
    }
    final distinctPoints = <GeoPoint>[];
    for (final point in points) {
      if (distinctPoints.every((existing) => _pointsDiffer(existing, point))) {
        distinctPoints.add(point);
      }
    }
    final landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final screenWidth = MediaQuery.sizeOf(context).width;
    final safeInsets = MediaQuery.paddingOf(context);
    final overlayWidth = landscape
        ? math.min(312.0, screenWidth - safeInsets.horizontal - 24)
        : screenWidth - safeInsets.horizontal - 24;
    // The card lives in the lower-right corner. Reserve that area when fitting
    // riders so no rider or route decision is hidden underneath it.
    final rightPadding = landscape ? overlayWidth + 36.0 : 32.0;
    final bottomPadding = landscape ? 228.0 : 276.0;
    // A stationary marker view should be a genuine overview even when every
    // rider is briefly at the same junction. These anchors prevent a close
    // single-point camera from ignoring the reserved card area.
    final cameraPoints = <GeoPoint>[
      ...distinctPoints,
      _pointAhead(overlay.markerPoint, 0, 360),
      _pointAhead(overlay.markerPoint, 180, 360),
    ];
    if (_basemap.usesMapLibre) {
      final controller = _mapLibreController;
      if (controller == null) return;
      await controller.animateCamera(
        ml.CameraUpdate.newLatLngBounds(
          _mapLibreBounds(cameraPoints),
          left: 36,
          top: 36,
          right: rightPadding,
          bottom: bottomPadding,
        ),
        duration: const Duration(milliseconds: 700),
      );
      return;
    }
    try {
      final fitted = CameraFit.bounds(
        bounds: LatLngBounds.fromPoints(
          cameraPoints.map(_latLng).toList(growable: false),
        ),
        padding: EdgeInsets.fromLTRB(36, 36, rightPadding, bottomPadding),
        maxZoom: 14.2,
      ).fit(_mapController.camera);
      _mapController.moveAndRotateAnimatedRaw(
        fitted.center,
        fitted.zoom,
        0,
        offset: Offset.zero,
        duration: const Duration(milliseconds: 700),
        curve: Curves.easeInOutCubic,
        hasGesture: false,
        source: MapEventSource.mapController,
      );
    } on StateError {
      // The marker can activate before FlutterMap finishes attaching.
    }
  }

  Future<void> _followNavigationCamera({
    bool force = false,
    Duration? transitionDuration,
  }) async {
    if (!_navigationMode) return;
    final position = _effectivePosition;
    if (position == null) return;
    if (_cameraUpdateInFlight) {
      _cameraUpdateQueued = true;
      return;
    }
    final now = DateTime.now();
    final previousCameraUpdate = _lastCameraUpdateAt;
    if (!force &&
        previousCameraUpdate != null &&
        now.difference(previousCameraUpdate) <
            const Duration(milliseconds: 400)) {
      return;
    }
    if (previousCameraUpdate != null && transitionDuration == null) {
      final elapsed = now.difference(previousCameraUpdate).inMilliseconds;
      _cameraTransitionDuration = Duration(
        milliseconds: (elapsed * 1.1).round().clamp(360, 560),
      );
    }
    _lastCameraUpdateAt = now;
    _cameraUpdateInFlight = true;
    final landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    // The camera centers on the rider's own live position, full stop - it
    // previously aimed hundreds of metres ahead along the route (or, once
    // more than 150m off-route, along route progress that had stopped
    // advancing), which could push the rider's own marker off the visible
    // viewport entirely, worst-case in landscape's steeper tilt/lower zoom.
    // The tilt below still gives a forward-looking navigation feel through
    // perspective, without moving the geometric centre away from the rider.
    final target = position;
    final cameraPlan = NavigationCameraPlanner.plan(
      speedMetersPerSecond:
          _smoothedNavigationSpeedMetersPerSecond ??
          _navigationFix?.speedMetersPerSecond,
      landscape: landscape,
    );
    final cameraDuration = transitionDuration ?? _cameraTransitionDuration;
    try {
      if (_basemap.usesMapLibre) {
        final controller = _mapLibreController;
        if (controller == null) return;
        await controller.easeCamera(
          ml.CameraUpdate.newCameraPosition(
            ml.CameraPosition(
              target: ml.LatLng(target.latitude, target.longitude),
              zoom: cameraPlan.zoom,
              tilt: cameraPlan.tilt,
              bearing: _lastHeadingDegrees,
            ),
          ),
          duration: cameraDuration,
          interpolation: transitionDuration == null
              ? ml.CameraAnimationInterpolation.linear
              : null,
        );
        return;
      }
      _mapController.moveAndRotateAnimatedRaw(
        _latLng(target),
        cameraPlan.zoom,
        _lastHeadingDegrees,
        offset: Offset.zero,
        duration: cameraDuration,
        curve: transitionDuration == null
            ? Curves.linear
            : Curves.easeInOutCubic,
        hasGesture: false,
        source: MapEventSource.mapController,
      );
    } on StateError {
      // The first position may arrive before FlutterMap has attached.
    } finally {
      _cameraUpdateInFlight = false;
      if (_cameraUpdateQueued) {
        _cameraUpdateQueued = false;
        if (mounted) unawaited(_followNavigationCamera(force: true));
      }
    }
  }

  static const _hazardIconImage = 'ride-relay-hazard-warning';
  bool _markerImagesRegistered = false;

  Future<void> _registerMarkerImages(
    ml.MapLibreMapController controller,
  ) async {
    if (_markerImagesRegistered) return;
    for (final style in MotorcycleIconStyle.values) {
      await controller.addImage(
        style.name,
        await loadMotorcycleIconPng(style),
        true,
      );
    }
    await controller.addImage(
      _hazardIconImage,
      await rasterizeIconGlyphPng(Icons.warning_amber_rounded),
      true,
    );
    await controller.addImage(
      _trailDirectionArrowImage,
      await rasterizeIconGlyphPng(Icons.navigation_rounded),
      true,
    );
    _markerImagesRegistered = true;
  }

  Future<void> _prepareMapLibreStyle() async {
    final controller = _mapLibreController;
    if (controller == null) return;
    _mapLibreStyleReady = false;
    try {
      await _registerMarkerImages(controller);
      await controller.addGeoJsonSource(
        _discoveryLineSource,
        _discoveryLineGeoJson(),
      );
      await controller.addLineLayer(
        _discoveryLineSource,
        'ride-relay-discovery-line-casing',
        const ml.LineLayerProperties(
          lineColor: '#10151C',
          lineOpacity: 0.75,
          lineWidth: 7,
          lineCap: 'round',
          lineJoin: 'round',
        ),
        enableInteraction: false,
      );
      await controller.addLineLayer(
        _discoveryLineSource,
        'ride-relay-discovery-lines',
        const ml.LineLayerProperties(
          lineColor: ['get', 'color'],
          lineOpacity: 0.9,
          lineWidth: 4,
          lineCap: 'round',
          lineJoin: 'round',
        ),
      );
      await controller.addGeoJsonSource(
        _discoveryPointSource,
        _discoveryPointGeoJson(),
      );
      await controller.addCircleLayer(
        _discoveryPointSource,
        'ride-relay-discovery-points',
        const ml.CircleLayerProperties(
          circleRadius: 7,
          circleColor: ['get', 'color'],
          circleStrokeWidth: 3,
          circleStrokeColor: '#10151C',
        ),
      );
      await controller.addGeoJsonSource(
        _remainingRouteSource,
        _remainingRouteGeoJson(),
      );
      await controller.addLineLayer(
        _remainingRouteSource,
        'ride-relay-route-remaining-border',
        const ml.LineLayerProperties(
          lineColor: '#10151C',
          lineOpacity: 0.7,
          lineWidth: 8,
          lineDasharray: [0.1, 1.8],
          lineCap: 'round',
          lineJoin: 'round',
        ),
        enableInteraction: false,
      );
      await controller.addLineLayer(
        _remainingRouteSource,
        'ride-relay-route-remaining',
        const ml.LineLayerProperties(
          lineColor: '#3478F6',
          lineOpacity: 0.9,
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
          lineColor: ['get', 'color'],
          lineWidth: 5,
          lineCap: 'round',
          lineJoin: 'round',
        ),
        enableInteraction: false,
      );
      await controller.addGeoJsonSource(
        _trailDirectionArrowSource,
        _trailDirectionArrowGeoJson(),
      );
      await controller.addSymbolLayer(
        _trailDirectionArrowSource,
        'ride-relay-trail-direction-arrows',
        const ml.SymbolLayerProperties(
          iconImage: _trailDirectionArrowImage,
          iconColor: ['get', 'color'],
          iconHaloColor: '#10151C',
          iconHaloWidth: 2,
          iconSize: 0.15,
          iconRotate: ['get', 'bearing'],
          iconRotationAlignment: 'map',
          iconPitchAlignment: 'map',
          iconAllowOverlap: true,
          iconIgnorePlacement: true,
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
        'ride-relay-position-badge',
        ml.CircleLayerProperties(
          circleRadius: 16,
          circleColor: _hexColor(widget.localBadgeColor),
          circleStrokeWidth: 3,
          circleStrokeColor: '#FFFFFF',
        ),
        enableInteraction: false,
      );
      await controller.addSymbolLayer(
        _positionSource,
        'ride-relay-position-icon',
        ml.SymbolLayerProperties(
          iconImage: widget.localMotorcycleStyle.name,
          iconColor: '#FFFFFF',
          iconSize: 0.2,
          iconAllowOverlap: true,
          iconIgnorePlacement: true,
        ),
        enableInteraction: false,
      );
      await controller.addGeoJsonSource(_overlaySource, _overlayGeoJson());
      // A colour alone was hard to pick out against some basemaps. A solid
      // badge behind a fixed-white glyph reads clearly regardless of what's
      // underneath, and matches the "you are here" marker's badge look.
      await controller.addCircleLayer(
        _overlaySource,
        'ride-relay-overlay-badges',
        const ml.CircleLayerProperties(
          circleRadius: 15,
          circleColor: ['get', 'color'],
          circleStrokeWidth: 2,
          circleStrokeColor: '#10151C',
        ),
        enableInteraction: false,
      );
      await controller.addSymbolLayer(
        _overlaySource,
        'ride-relay-overlay-icons',
        const ml.SymbolLayerProperties(
          iconImage: ['get', 'iconImage'],
          iconColor: '#FFFFFF',
          iconSize: 0.19,
          iconAllowOverlap: true,
          iconIgnorePlacement: true,
        ),
      );
      _mapLibreStyleReady = true;
      await _syncMapLibreSources();
      if (_navigationMode) {
        await _followNavigationCamera();
      } else if (!_initialCameraPositioned) {
        _fitRoute();
      }
    } on Object catch (error, stackTrace) {
      if (kDebugMode) {
        debugPrint(
          'Could not prepare MapLibre ride layers: $error\n$stackTrace',
        );
      }
    }
  }

  Future<void> _syncMapLibreSources() async {
    final controller = _mapLibreController;
    if (!_mapLibreStyleReady || controller == null) return;
    try {
      await controller.setGeoJsonSource(
        _discoveryLineSource,
        _discoveryLineGeoJson(),
      );
      await controller.setGeoJsonSource(
        _discoveryPointSource,
        _discoveryPointGeoJson(),
      );
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
      await controller.setGeoJsonSource(
        _trailDirectionArrowSource,
        _trailDirectionArrowGeoJson(),
      );
      await controller.setGeoJsonSource(_waypointSource, _waypointGeoJson());
      await controller.setGeoJsonSource(_positionSource, _positionGeoJson());
      await controller.setGeoJsonSource(_overlaySource, _overlayGeoJson());
    } on Object catch (error) {
      if (kDebugMode) {
        debugPrint('Could not refresh MapLibre ride layers: $error');
      }
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
          _discoveryLineSource,
          _discoveryLineGeoJson(),
        );
        await controller.setGeoJsonSource(
          _discoveryPointSource,
          _discoveryPointGeoJson(),
        );
        await controller.setGeoJsonSource(
          _offRouteTraceSource,
          _offRouteTraceGeoJson(),
        );
        await controller.setGeoJsonSource(_overlaySource, _overlayGeoJson());
      }
      if (progress || overlays) {
        await controller.setGeoJsonSource(
          _trailDirectionArrowSource,
          _trailDirectionArrowGeoJson(),
        );
      }
    } on Object catch (error) {
      if (kDebugMode) {
        debugPrint('Could not refresh scheduled MapLibre layers: $error');
      }
    } finally {
      _mapLibreSyncRunning = false;
    }
    if (_mapLibreProgressDirty ||
        _mapLibrePositionDirty ||
        _mapLibreOverlaysDirty) {
      _scheduleMapLibreSync();
    }
  }

  Map<String, dynamic> _remainingRouteGeoJson() => MapGeoJson.lines(
    _progressGeometry.remainingPaths,
    idPrefix: 'remaining-route',
  );

  List<_StyledTrailDirectionArrow> _trailDirectionArrows() {
    const maximumVisibleArrows = 240;
    final items = <_StyledTrailDirectionArrow>[];

    void addArrows({
      required Iterable<List<GeoPoint>> paths,
      required Color color,
      required String idPrefix,
      required String semanticLabel,
    }) {
      for (final arrow in _trailDirectionArrowSampler.sample(paths)) {
        if (items.length >= maximumVisibleArrows) return;
        items.add(
          _StyledTrailDirectionArrow(
            id: '$idPrefix-${items.length}',
            arrow: arrow,
            color: color,
            semanticLabel: semanticLabel,
          ),
        );
      }
    }

    addArrows(
      paths: _progressGeometry.riddenPaths,
      color: const Color(0xFFFF7A1A),
      idPrefix: 'ridden',
      semanticLabel: 'Travel direction',
    );
    for (final trace
        in widget.offRouteTraces?.value ?? const <MapOverlayTrace>[]) {
      addArrows(
        paths: [trace.points],
        color: trace.color,
        idPrefix: trace.id,
        semanticLabel: '${trace.label} direction',
      );
      if (items.length >= maximumVisibleArrows) break;
    }
    return items;
  }

  Map<String, dynamic> _trailDirectionArrowGeoJson() => MapGeoJson.points(
    _trailDirectionArrows().map(
      (item) => MapGeoJsonPoint(
        id: item.id,
        point: item.arrow.point,
        properties: {
          'bearing': item.arrow.bearingDegrees,
          'color': _hexColor(item.color),
        },
      ),
    ),
  );

  Map<String, dynamic> _riddenRouteGeoJson() =>
      MapGeoJson.lines(_progressGeometry.riddenPaths, idPrefix: 'ridden-route');

  List<MotorcycleDiscoveryFeature> get _visibleDiscoveryFeatures =>
      _discoveryCatalogue.visible(categories: _enabledDiscoveryCategories);

  Map<String, dynamic> _discoveryLineGeoJson() => {
    'type': 'FeatureCollection',
    'features': [
      for (final feature in _visibleDiscoveryFeatures.where(
        (feature) => !feature.isPoint,
      ))
        {
          'type': 'Feature',
          'id': feature.id,
          'properties': {
            'name': feature.name,
            'category': feature.category.apiValue,
            'color': _hexColor(_discoveryColour(feature.category)),
          },
          'geometry': {
            'type': 'LineString',
            'coordinates': [
              for (final point in feature.points)
                [point.longitude, point.latitude],
            ],
          },
        },
    ],
  };

  Map<String, dynamic> _discoveryPointGeoJson() => MapGeoJson.points(
    _visibleDiscoveryFeatures.map(
      (feature) => MapGeoJsonPoint(
        id: feature.id,
        point: feature.anchor,
        properties: {
          'name': feature.name,
          'category': feature.category.apiValue,
          'color': _hexColor(_discoveryColour(feature.category)),
        },
      ),
    ),
  );

  Map<String, dynamic> _offRouteTraceGeoJson() {
    final traces = widget.offRouteTraces?.value ?? const <MapOverlayTrace>[];
    return {
      'type': 'FeatureCollection',
      'features': [
        for (final trace in traces.where((trace) => trace.points.length >= 2))
          {
            'type': 'Feature',
            'id': trace.id,
            'properties': {'color': _hexColor(trace.color)},
            'geometry': {
              'type': 'LineString',
              'coordinates': [
                for (final point in trace.points)
                  [point.longitude, point.latitude],
              ],
            },
          },
      ],
    };
  }

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
              'iconImage': overlay.motorcycleStyle?.name ?? _hazardIconImage,
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
    if (layerId == 'ride-relay-discovery-lines' ||
        layerId == 'ride-relay-discovery-points') {
      final feature = _discoveryCatalogue.features
          .where((feature) => feature.id == id)
          .firstOrNull;
      if (feature != null) _showDiscoveryFeature(feature);
      return;
    }
    if (layerId != 'ride-relay-overlay-icons' &&
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
      await _reviewAndActivateRoute(route);
    } on FormatException catch (error) {
      _showMessage(error.message);
    } catch (error) {
      _showMessage('Could not import GPX: $error');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  /// Loads a route prepared on the web planner. The plan code has no
  /// relationship to a live ride or its credentials - this only fetches a
  /// GPX file through the same parse-and-activate pipeline as a manual
  /// import, exactly like [_importGpx] and [_importSharedGpx] above.
  Future<void> _loadPlannedRoute() async {
    if (_importing) return;
    final code = await _promptForPlanCode();
    if (code == null || code.trim().isEmpty || !mounted) return;
    setState(() => _importing = true);
    try {
      final directory =
          widget.planDirectory ?? HttpPlanDirectory.fromEnvironment();
      final plan = await directory.fetch(code);
      final route = widget.routeImporter.importFromFile(
        PickedGpxFile(
          name: '${plan.name ?? 'planned-route'}.gpx',
          bytes: Uint8List.fromList(utf8.encode(plan.gpx)),
        ),
      );
      await _reviewAndActivateRoute(route);
    } on PlanDirectoryException catch (error) {
      _showMessage(error.message);
    } on FormatException catch (error) {
      _showMessage(error.message);
    } on Object catch (error) {
      _showMessage('Could not load planned route: $error');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<String?> _promptForPlanCode() {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Load a planned route'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          maxLength: 16,
          decoration: const InputDecoration(
            labelText: 'Plan code',
            hintText: 'e.g. 7F3K9QRT',
          ),
          onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('Load'),
          ),
        ],
      ),
    );
  }

  Future<void> _planDestination() async {
    if (_routing) return;
    DestinationPlanRequest? request;
    ImportedRoute? previousCandidate;
    while (mounted) {
      if (!mounted) return;
      request = await DestinationRouteSheet.show(
        context,
        initialRequest: request,
      );
      if (request == null || !mounted) return;
      setState(() => _routing = true);
      try {
        final hasStartQuery = (request.startQuery ?? '').trim().isNotEmpty;
        GeoPoint? origin;
        if (!hasStartQuery) {
          origin = _effectivePosition;
          origin ??= await widget.acquireCurrentPosition?.call();
          origin ??= _effectivePosition;
          if (origin == null) {
            throw const FormatException(
              'A current location is required. Allow location access, or give '
              'a start location instead, and try again.',
            );
          }
        }
        final planned = await _destinationRoutePlanner.planForReview(
          origin: origin,
          originQuery: request.startQuery,
          stopQueries: request.stopQueries,
          query: request.query,
          distanceUnit: widget.distanceUnit,
        );
        final review = await _reviewRoute(
          planned.route,
          distanceMeters: planned.distanceMeters,
          duration: planned.duration,
          warnings: planned.warnings,
          canEditStops: true,
          previousRoute: previousCandidate,
        );
        if (review.action == RouteReviewAction.edit) {
          previousCandidate = review.route;
          continue;
        }
        if (review.action != RouteReviewAction.confirm) return;
        final route = await _commitRoute(review.route);
        if (mounted) {
          final target = request.handoffTarget;
          if (target != null) await _exportRoute(target, route);
        }
        return;
      } on FormatException catch (error) {
        _showMessage(error.message);
        return;
      } on Object catch (error) {
        _showMessage('Could not plan destination: $error');
        return;
      } finally {
        if (mounted) setState(() => _routing = false);
      }
    }
  }

  Future<void> _loadDemoRoute() async {
    try {
      final loader = widget.demoRouteLoader ?? _loadBundledDemoRoute;
      await _reviewAndActivateRoute(await loader());
    } catch (error) {
      _showMessage('Could not load demo route: $error');
    }
  }

  Future<ImportedRoute> _loadBundledDemoRoute() async {
    return const BundledDemoRouteLoader().load();
  }

  Future<void> _useRecordedRoute() async {
    try {
      final store =
          widget.recordedRouteStore ??
          await JsonFileRecordedRouteStore.openDefault();
      final routes = await store.list();
      if (!mounted) return;
      if (routes.isEmpty) {
        _showMessage(
          'No recorded routes yet. Record one from the home screen first.',
        );
        return;
      }
      final selected = await showModalBottomSheet<ImportedRoute>(
        context: context,
        showDragHandle: true,
        builder: (sheetContext) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final route in routes)
                ListTile(
                  leading: const Icon(Icons.route_outlined),
                  title: Text(route.name),
                  subtitle: Text(
                    '${route.pathPointCount} points · recorded '
                    '${route.importedAt.toLocal().toString().split('.').first}',
                  ),
                  onTap: () => Navigator.of(sheetContext).pop(route),
                ),
            ],
          ),
        ),
      );
      if (selected == null || !mounted) return;
      await _reviewAndActivateRoute(selected);
    } catch (error) {
      _showMessage('Could not load recorded routes: $error');
    }
  }

  Future<ImportedRoute?> _reviewAndActivateRoute(
    ImportedRoute route, {
    double? distanceMeters,
    Duration? duration,
    List<String> warnings = const [],
  }) async {
    final review = await _reviewRoute(
      route,
      distanceMeters: distanceMeters,
      duration: duration,
      warnings: warnings,
    );
    if (review.action != RouteReviewAction.confirm) return null;
    return _commitRoute(review.route);
  }

  Future<({RouteReviewAction action, ImportedRoute route})> _reviewRoute(
    ImportedRoute route, {
    double? distanceMeters,
    Duration? duration,
    List<String> warnings = const [],
    bool canEditStops = false,
    ImportedRoute? previousRoute,
  }) async {
    if (!widget.canEditRoute) {
      throw const FormatException(
        'Only the ride leader can replace the group route.',
      );
    }
    final enrichment = await _routeGeometryEnricher.enrich(route);
    final activeRoute = enrichment.route;
    if (!mounted) {
      return (action: RouteReviewAction.cancel, route: activeRoute);
    }
    final reviewWarnings = [
      ...warnings,
      ?enrichment.warning,
      if (enrichment.attempted &&
          !enrichment.changed &&
          enrichment.warning != null)
        'Online road recalculation was unavailable. The original geometry is '
            'shown and remains usable offline.',
    ];
    final action = await RouteReviewScreen.show(
      context,
      route: activeRoute,
      distanceUnit: widget.distanceUnit,
      basemapConfiguration: _basemap,
      distanceMeters: distanceMeters,
      duration: duration,
      warnings: reviewWarnings,
      previousRoute: previousRoute ?? _route,
      canEditStops: canEditStops,
    );
    return (action: action, route: activeRoute);
  }

  Future<ImportedRoute> _commitRoute(ImportedRoute activeRoute) async {
    await widget.routeStore.saveActiveRoute(activeRoute);
    if (!mounted) return activeRoute;
    _routeProgressTracker.reset();
    setState(() {
      _route = activeRoute;
      _progressGeometry = _routeProgressTracker.update(
        activeRoute,
        _effectivePosition,
      );
      _initialCameraPositioned = false;
      if (_isMoving && !_autoFollowSuppressed) {
        _navigationMode = true;
        _navigationCanvasActive = true;
      }
    });
    _updateNavigationGuidance(_effectivePosition);
    await _syncMapLibreSources();
    _fitRoute();
    if (_navigationMode) unawaited(_followNavigationCamera());
    widget.onRouteChanged?.call(activeRoute);
    _showMessage(
      '${activeRoute.name}: confirmed and stored offline '
      '(${activeRoute.pathPointCount} points).',
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
      _initialCameraPositioned = true;
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
    _initialCameraPositioned = true;
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

  Color _discoveryColour(MotorcycleDiscoveryCategory category) =>
      switch (category) {
        MotorcycleDiscoveryCategory.twistyHighlight => const Color(0xFFF97316),
        MotorcycleDiscoveryCategory.mountainPass => const Color(0xFF0F9D8A),
        MotorcycleDiscoveryCategory.goodBikingRoad => const Color(0xFF2583E9),
      };

  Future<void> _showDiscoveryLayersSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Motorcycle discovery layers',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 4),
                const Text(
                  'Optional reviewed highlights. Off by default and never a safety endorsement.',
                ),
                const SizedBox(height: 8),
                for (final category in MotorcycleDiscoveryCategory.values)
                  CheckboxListTile(
                    value: _enabledDiscoveryCategories.contains(category),
                    secondary: Icon(
                      category == MotorcycleDiscoveryCategory.mountainPass
                          ? Icons.terrain
                          : Icons.route,
                      color: _discoveryColour(category),
                    ),
                    title: Text(category.label),
                    contentPadding: EdgeInsets.zero,
                    onChanged: (enabled) {
                      setState(() {
                        if (enabled ?? false) {
                          _enabledDiscoveryCategories.add(category);
                        } else {
                          _enabledDiscoveryCategories.remove(category);
                        }
                      });
                      setSheetState(() {});
                      _scheduleMapLibreSync(overlays: true);
                    },
                  ),
                OutlinedButton.icon(
                  onPressed: () {
                    Navigator.of(sheetContext).pop();
                    unawaited(_showDiscoverySuggestionForm());
                  },
                  icon: const Icon(Icons.add_location_alt_outlined),
                  label: const Text('Suggest an addition'),
                ),
                if (_suggestionConfiguration.apiOrigin != null)
                  FutureBuilder<DiscoverySuggestionQueue>(
                    future: _suggestionQueue,
                    builder: (context, snapshot) {
                      final count = snapshot.data?.drafts.length ?? 0;
                      return TextButton.icon(
                        onPressed: count == 0
                            ? null
                            : () {
                                Navigator.of(sheetContext).pop();
                                unawaited(_confirmSendDiscoverySuggestions());
                              },
                        icon: const Icon(Icons.outbox_outlined),
                        label: Text(
                          'Send $count queued suggestion${count == 1 ? '' : 's'}',
                        ),
                      );
                    },
                  ),
                const Text(
                  'Proof-of-concept data © OpenStreetMap contributors, ODbL. Check access, closures, weather and road conditions.',
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showDiscoveryFeature(MotorcycleDiscoveryFeature feature) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                feature.category.label,
                style: Theme.of(context).textTheme.labelLarge,
              ),
              Text(
                feature.name,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              Text(
                [
                  if (feature.score case final score?) 'Score $score/100',
                  '${feature.confidence} confidence',
                  'checked ${feature.lastVerified}',
                ].join(' · '),
              ),
              const SizedBox(height: 8),
              Text(feature.warning),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => launchUrl(
                    Uri.parse(feature.sourceUrl),
                    mode: LaunchMode.externalApplication,
                  ),
                  icon: const Icon(Icons.open_in_new),
                  label: Text('Source: ${feature.sourceName}'),
                ),
              ),
              FilledButton.icon(
                onPressed: _routing
                    ? null
                    : () {
                        Navigator.of(sheetContext).pop();
                        unawaited(_addDiscoveryFeatureToRoute(feature));
                      },
                icon: const Icon(Icons.add_road),
                label: const Text('Add to route via here'),
              ),
              TextButton.icon(
                onPressed: () {
                  Navigator.of(sheetContext).pop();
                  unawaited(
                    _showDiscoverySuggestionForm(
                      feature: feature,
                      action: 'correct',
                    ),
                  );
                },
                icon: const Icon(Icons.edit_location_alt_outlined),
                label: const Text('Suggest a correction or removal'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _addDiscoveryFeatureToRoute(
    MotorcycleDiscoveryFeature feature,
  ) async {
    if (_routing) return;
    final existing = _route;
    final start =
        existing?.paths.lastOrNull?.points.lastOrNull ?? _effectivePosition;
    if (start == null) {
      _showMessage(
        'Load a route or enable location before adding this highlight.',
      );
      return;
    }
    setState(() => _routing = true);
    try {
      final extension = await _roadRoutingService.routeThrough([
        start,
        feature.anchor,
      ]);
      final route = ImportedRoute(
        id:
            existing?.id ??
            'discovery-${DateTime.now().microsecondsSinceEpoch}',
        name: existing?.name ?? 'Route via ${feature.name}',
        description: existing?.description,
        importedAt: existing?.importedAt ?? DateTime.now().toUtc(),
        sourceFileName: existing?.sourceFileName ?? 'motorcycle-discovery',
        paths: [
          ...?existing?.paths,
          RoutePath(
            kind: RoutePathKind.route,
            name: feature.name,
            points: extension.points,
          ),
        ],
        waypoints: [
          ...?existing?.waypoints,
          RouteWaypoint(
            point: feature.anchor,
            name: feature.name,
            description: '${feature.category.label}; ${feature.warning}',
            symbol: 'Scenic Area',
          ),
        ],
      );
      await _reviewAndActivateRoute(route);
    } on Object catch (error) {
      _showMessage('Could not route via ${feature.name}: $error');
    } finally {
      if (mounted) setState(() => _routing = false);
    }
  }

  Future<void> _showDiscoverySuggestionForm({
    MotorcycleDiscoveryFeature? feature,
    String action = 'add',
  }) async {
    final point =
        feature?.anchor ??
        _effectivePosition ??
        _route?.paths.lastOrNull?.points.lastOrNull;
    if (point == null) {
      _showMessage(
        'Enable location or load a route before placing a suggestion.',
      );
      return;
    }
    var category =
        feature?.category ?? MotorcycleDiscoveryCategory.goodBikingRoad;
    var selectedAction = action;
    final name = TextEditingController(text: feature?.name ?? '');
    final reason = TextEditingController();
    final evidence = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(
            feature == null ? 'Suggest an addition' : 'Suggest a map update',
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (feature != null)
                  DropdownButtonFormField<String>(
                    initialValue: selectedAction,
                    decoration: const InputDecoration(labelText: 'Change'),
                    items: const [
                      DropdownMenuItem(
                        value: 'correct',
                        child: Text('Correct entry'),
                      ),
                      DropdownMenuItem(
                        value: 'remove',
                        child: Text('Report closed, restricted or unsafe'),
                      ),
                    ],
                    onChanged: (value) => setDialogState(
                      () => selectedAction = value ?? selectedAction,
                    ),
                  ),
                DropdownButtonFormField<MotorcycleDiscoveryCategory>(
                  initialValue: category,
                  decoration: const InputDecoration(labelText: 'Category'),
                  items: [
                    for (final item in MotorcycleDiscoveryCategory.values)
                      DropdownMenuItem(value: item, child: Text(item.label)),
                  ],
                  onChanged: (value) =>
                      setDialogState(() => category = value ?? category),
                ),
                TextField(
                  controller: name,
                  maxLength: 120,
                  decoration: const InputDecoration(labelText: 'Name'),
                ),
                TextField(
                  controller: reason,
                  maxLength: 500,
                  minLines: 3,
                  maxLines: 5,
                  decoration: const InputDecoration(
                    labelText: 'Reason or current condition',
                  ),
                ),
                TextField(
                  controller: evidence,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: 'Evidence link (optional)',
                  ),
                ),
                Text(
                  'Location: ${point.latitude.toStringAsFixed(5)}, ${point.longitude.toStringAsFixed(5)}\n'
                  'Saved privately on this device until you explicitly send it. Not a safety endorsement.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (name.text.trim().isEmpty || reason.text.trim().length < 5) {
                  _showMessage('Enter a name and a short reason.');
                  return;
                }
                Navigator.of(dialogContext).pop(true);
              },
              child: const Text('Save offline draft'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) return;
    final queue = await _suggestionQueue;
    await queue.enqueue(
      category: category,
      action: selectedAction,
      targetFeatureId: feature?.id,
      name: name.text,
      reason: reason.text,
      evidenceUrl: evidence.text,
      point: point,
      geometryPoints: feature?.points,
    );
    _showMessage(
      'Suggestion saved offline. It will only be sent when you choose Send queued suggestions.',
    );
  }

  Future<void> _confirmSendDiscoverySuggestions() async {
    final apiOrigin = _suggestionConfiguration.apiOrigin;
    if (apiOrigin == null) return;
    final queue = await _suggestionQueue;
    if (queue.drafts.isEmpty || !mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Send suggestions for review?'),
        content: Text(
          '${queue.drafts.length} private draft${queue.drafts.length == 1 ? '' : 's'} will be sent to the administrator queue. Nothing becomes public automatically.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep offline'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Send now'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final sent = await queue.sendAfterConfirmation(
        client: _routingClient,
        apiOrigin: apiOrigin,
      );
      _showMessage(
        sent == 0
            ? 'Suggestions could not be sent and remain saved offline.'
            : '$sent suggestion${sent == 1 ? '' : 's'} sent for administrator review.',
      );
    } on Object {
      _showMessage('Suggestions could not be sent and remain saved offline.');
    }
  }

  Future<void> _handleMenuAction(_MapAction action) async {
    switch (action) {
      case _MapAction.importGpx:
        await _importGpx();
      case _MapAction.loadDemo:
        await _loadDemoRoute();
      case _MapAction.discoveryLayers:
        await _showDiscoveryLayersSheet();
      case _MapAction.downloadOffline:
        await _downloadOfflineMap();
      case _MapAction.removeRoute:
        if (!widget.canEditRoute || !await _confirmRemoveRoute()) return;
        await widget.routeStore.clearActiveRoute();
        if (mounted) {
          _routeProgressTracker.reset();
          setState(() {
            _route = null;
            _progressGeometry = const RouteProgressGeometry.empty();
            _navigationMode = false;
            _navigationCanvasActive = false;
            _initialCameraPositioned = false;
          });
          _navigationGuidance.value = null;
          await _syncMapLibreSources();
          widget.onRouteChanged?.call(null);
        }
      case _MapAction.clearOfflineTiles:
        await _mapLibreOfflineManager.clearAll();
        await widget.offlineTileCache.clearAll();
        _showMessage('Offline map data cleared.');
    }
  }

  Future<bool> _confirmRemoveRoute() async =>
      await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Clear the group route?'),
          content: const Text(
            'The route will be removed for every rider after this signed '
            'change is relayed. This cannot be undone offline.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const Key('confirm-clear-group-route'),
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Clear route'),
            ),
          ],
        ),
      ) ??
      false;

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // A fresh token (any non-null Object, compared by identity) means an
  // ancestor - the ride's main menu - wants this screen to open its route
  // picker. Consumed once per token, after the first post-mount frame so a
  // BuildContext with a Navigator is always available.
  //
  // This State is rebuilt from scratch every time the tab switch leaves and
  // returns to the map (there is no keep-alive), so _handledChangeRouteRequestToken
  // resets to null on every remount while the ancestor's token does not. Only
  // the ancestor survives that round trip, so onChangeRouteRequestHandled asks
  // it to null the token back out - otherwise every later visit to this tab
  // would see a "new" token and reopen the sheet unprompted.
  void _maybeHandleChangeRouteRequest() {
    final token = widget.changeRouteRequestToken;
    if (token == null || identical(token, _handledChangeRouteRequestToken)) {
      return;
    }
    _handledChangeRouteRequestToken = token;
    final sharedFile = widget.pendingSharedGpxFile;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.onChangeRouteRequestHandled?.call();
      if (!mounted) return;
      if (!widget.canEditRoute) {
        _showMessage('Only the ride leader can replace the group route.');
        return;
      }
      if (sharedFile != null) {
        unawaited(_importSharedGpx(sharedFile));
      } else {
        _showChangeRouteSheet();
      }
    });
  }

  /// A file the platform already handed us (Open in..., a share sheet)
  /// skips the picker sheet entirely and goes straight through the same
  /// parse-and-activate pipeline a manual import uses.
  Future<void> _importSharedGpx(PickedGpxFile file) async {
    try {
      final route = widget.routeImporter.importFromFile(file);
      await _reviewAndActivateRoute(route);
    } on FormatException catch (error) {
      _showMessage(error.message);
    } on Object catch (error) {
      _showMessage('Could not import GPX: $error');
    }
  }

  Future<void> _showChangeRouteSheet() async {
    if (!widget.canEditRoute) {
      _showMessage('Only the ride leader can replace the group route.');
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.add_road),
                title: const Text('Plan a destination'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _planDestination();
                },
              ),
              ListTile(
                leading: const Icon(Icons.upload_file),
                title: Text(
                  _route == null ? 'Import GPX route' : 'Replace GPX route',
                ),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _importGpx();
                },
              ),
              ListTile(
                leading: const Icon(Icons.qr_code),
                title: const Text('Load a planned route'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _loadPlannedRoute();
                },
              ),
              ListTile(
                leading: const Icon(Icons.route_outlined),
                title: const Text('Load demo route'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _loadDemoRoute();
                },
              ),
              ListTile(
                leading: const Icon(Icons.fiber_manual_record_outlined),
                title: const Text('Use a recorded route'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _useRecordedRoute();
                },
              ),
              if (_route != null)
                ListTile(
                  leading: const Icon(Icons.delete_outline),
                  title: const Text('Remove route'),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _handleMenuAction(_MapAction.removeRoute);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}

enum _MapAction {
  importGpx,
  loadDemo,
  discoveryLayers,
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

enum MapJunctionMarkerStage { waitingForRiders, tecApproaching, readyToRideOff }

/// Presentation data for the automatic second-bike-drop view. It lives beside
/// the map so a marker stop does not have to interrupt navigation with a tab
/// change.
class MapJunctionMarkerOverlay {
  const MapJunctionMarkerOverlay({
    required this.markerPoint,
    required this.markerRiderName,
    required this.isLocalMarker,
    required this.ridersPassed,
    required this.ridersExpected,
    required this.instruction,
    required this.stage,
    this.tecDistanceMeters,
  });

  final GeoPoint markerPoint;
  final String markerRiderName;
  final bool isLocalMarker;
  final int ridersPassed;
  final int ridersExpected;
  final double? tecDistanceMeters;
  final String instruction;
  final MapJunctionMarkerStage stage;
}

/// A ride role that should receive urgent assistance requests.
///
/// Phone numbers are deliberately optional here: this general roster does
/// not carry personal contact details, so the UI can safely offer Messages
/// without exposing anyone's number by default. Actual ICE contact numbers
/// only ever travel through the separate, opt-in sharing flow in
/// RideController (IceShareInboxSheet / shareEmergencyInfo), never through
/// this class.
class MapEmergencyContact {
  const MapEmergencyContact({
    required this.riderId,
    required this.displayName,
    required this.role,
    this.phoneNumber,
  });

  final String riderId;
  final String displayName;
  final RideRole role;
  final String? phoneNumber;

  String get shortRoleLabel => switch (role) {
    RideRole.lead => 'the leader',
    RideRole.tailEndCharlie => 'the TEC',
    _ => displayName,
  };
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

class _StyledTrailDirectionArrow {
  const _StyledTrailDirectionArrow({
    required this.id,
    required this.arrow,
    required this.color,
    required this.semanticLabel,
  });

  final String id;
  final TrailDirectionArrow arrow;
  final Color color;
  final String semanticLabel;
}

class MapOverlayMarker {
  const MapOverlayMarker({
    required this.id,
    required this.point,
    required this.label,
    this.icon = Icons.warning_amber_rounded,
    this.color = const Color(0xFFFFC857),
    this.motorcycleStyle,
  });

  final String id;
  final GeoPoint point;
  final String label;

  /// Used for non-rider markers (hazards). Ignored when [motorcycleStyle] is
  /// set, which riders always provide.
  final IconData icon;
  final Color color;
  final MotorcycleIconStyle? motorcycleStyle;
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

class _EmergencyActionsSheet extends StatefulWidget {
  const _EmergencyActionsSheet({
    required this.contacts,
    required this.onIssueSelected,
    required this.onOpenMessages,
  });

  final List<MapEmergencyContact> contacts;
  final Future<void> Function(QuickMessage message) onIssueSelected;
  final Future<void> Function() onOpenMessages;

  @override
  State<_EmergencyActionsSheet> createState() => _EmergencyActionsSheetState();
}

class _EmergencyActionsSheetState extends State<_EmergencyActionsSheet> {
  bool _sending = false;

  Future<void> _selectIssue(QuickMessage message) async {
    if (_sending) return;
    setState(() => _sending = true);
    try {
      await widget.onIssueSelected(message);
      if (mounted) Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _openMessages() async {
    if (_sending) return;
    setState(() => _sending = true);
    try {
      await widget.onOpenMessages();
      if (mounted) Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final contacts = widget.contacts;
    final recipientLabel = contacts.isEmpty
        ? 'the ride group'
        : contacts.map((contact) => contact.shortRoleLabel).join(' and ');
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'You are stopped',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 6),
            Text('The emergency alert has been sent to $recipientLabel.'),
            const SizedBox(height: 20),
            Text(
              'What do you need?',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final message in const [
                  QuickMessage.mechanical,
                  QuickMessage.assistance,
                  QuickMessage.routeBlocked,
                  QuickMessage.fuel,
                ])
                  OutlinedButton.icon(
                    onPressed: _sending
                        ? null
                        : () => unawaited(_selectIssue(message)),
                    icon: Icon(_iconForIssue(message), size: 18),
                    label: Text(message.label),
                  ),
              ],
            ),
            const SizedBox(height: 18),
            OutlinedButton.icon(
              key: const Key('emergency-open-messages-button'),
              onPressed: _sending ? null : () => unawaited(_openMessages()),
              icon: const Icon(Icons.sms_outlined),
              label: const Text('Open Messages'),
            ),
            const SizedBox(height: 6),
            const Text(
              'Contact numbers are not shared by the ride invite. Choose the '
              'leader or TEC from your phone contacts if you need to call.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Color(0xFF98A3B1), fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  IconData _iconForIssue(QuickMessage message) => switch (message) {
    QuickMessage.mechanical => Icons.build_outlined,
    QuickMessage.assistance => Icons.volunteer_activism_outlined,
    QuickMessage.routeBlocked => Icons.block_outlined,
    QuickMessage.fuel => Icons.local_gas_station_outlined,
    _ => Icons.info_outline,
  };
}

class _GroupMiniMap extends StatefulWidget {
  const _GroupMiniMap({
    required this.width,
    required this.height,
    required this.routePaths,
    required this.currentPosition,
    required this.riders,
    required this.riderCount,
    required this.onTap,
    required this.showTiles,
    required this.mapStyleString,
  });

  final double width;
  final double height;
  final List<List<GeoPoint>> routePaths;
  final GeoPoint? currentPosition;
  final List<MapOverlayMarker> riders;
  final int riderCount;
  final VoidCallback? onTap;
  final bool showTiles;
  final String mapStyleString;

  @override
  State<_GroupMiniMap> createState() => _GroupMiniMapState();
}

typedef _MiniMapSnapshot = ({
  List<List<GeoPoint>> routePaths,
  GeoPoint? currentPosition,
  List<MapOverlayMarker> riders,
});

class _GroupMiniMapState extends State<_GroupMiniMap> {
  static const _routeSource = 'ride-relay-mini-route';
  static const _riderSource = 'ride-relay-mini-riders';
  ml.MapLibreMapController? _controller;
  Timer? _refreshTimer;
  DateTime? _lastRefreshAt;
  bool _styleReady = false;
  bool _refreshing = false;

  /// Captured once per refresh so the windowed route, rider dots, and camera
  /// fit all agree on the same instant - reading `widget.riders` again after
  /// each awaited platform call let a mid-flight rebuild (new positions
  /// arriving between calls) hand later steps newer data than earlier ones,
  /// which could visually detach a rider's dot from its trimmed route line.
  _MiniMapSnapshot _snapshot() => (
    routePaths: widget.routePaths,
    currentPosition: widget.currentPosition,
    riders: widget.riders,
  );

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
    if (elapsed >= const Duration(milliseconds: 750)) {
      _lastRefreshAt = DateTime.now();
      unawaited(_refreshMap());
      return;
    }
    _refreshTimer ??= Timer(const Duration(milliseconds: 750) - elapsed, () {
      _refreshTimer = null;
      if (!mounted) return;
      _lastRefreshAt = DateTime.now();
      unawaited(_refreshMap());
    });
  }

  @override
  Widget build(BuildContext context) {
    final riderCount = widget.riderCount;
    final visibleRoutePaths = _visibleRoutePaths(_snapshot());
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          key: const Key('group-mini-map'),
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            color: const Color(0xF2111820),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFF566273), width: 1.5),
            boxShadow: const [
              BoxShadow(
                color: Colors.black54,
                blurRadius: 8,
                offset: Offset(0, 2),
              ),
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
                            routePaths: visibleRoutePaths,
                            currentPosition: widget.currentPosition,
                            riders: widget.riders,
                            brightness: Theme.of(context).brightness,
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
                        padding: EdgeInsets.symmetric(
                          horizontal: 3,
                          vertical: 1,
                        ),
                        child: Text(
                          'OpenFreeMap · © OSM',
                          style: TextStyle(color: Colors.white, fontSize: 6),
                        ),
                      ),
                    ),
                  ),
                if (widget.currentPosition != null)
                  const Positioned(
                    left: 6,
                    top: 6,
                    child: _MiniMapBadge(
                      key: Key('mini-map-you-legend'),
                      label: 'YOU',
                      dotColor: Color(0xFFFF7A1A),
                    ),
                  ),
                if (!widget.showTiles)
                  const Positioned(
                    right: 6,
                    top: 6,
                    child: _MiniMapBadge(
                      key: Key('mini-map-north-indicator'),
                      label: 'N ↑',
                    ),
                  ),
                if (!widget.showTiles)
                  Positioned(
                    left: 7,
                    bottom: 6,
                    child: _MiniMapScaleBar(
                      width: widget.width,
                      points: [
                        ?widget.currentPosition,
                        ...widget.riders.map((rider) => rider.point),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        Positioned(
          left: 7,
          bottom: -22,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xD90D1117),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              child: Text(
                '$riderCount RIDERS',
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
        if (widget.onTap != null)
          Positioned.fill(
            bottom: -22,
            child: Semantics(
              button: true,
              label: 'Open ride roster, $riderCount riders',
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: widget.onTap,
              ),
            ),
          ),
      ],
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
    final snapshot = _snapshot();
    try {
      await controller.addGeoJsonSource(_routeSource, _routeGeoJson(snapshot));
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
      await controller.addGeoJsonSource(_riderSource, _riderGeoJson(snapshot));
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
      await _fitGroup(snapshot);
    } on Object catch (error) {
      if (kDebugMode) {
        debugPrint('Could not prepare group mini-map: $error');
      }
    }
  }

  Future<void> _refreshMap() async {
    final controller = _controller;
    if (!_styleReady || controller == null || _refreshing) return;
    _refreshing = true;
    try {
      final snapshot = _snapshot();
      await controller.setGeoJsonSource(_routeSource, _routeGeoJson(snapshot));
      await controller.setGeoJsonSource(_riderSource, _riderGeoJson(snapshot));
      await _fitGroup(snapshot);
    } on Object catch (error) {
      if (kDebugMode) {
        debugPrint('Could not refresh group mini-map: $error');
      }
    } finally {
      _refreshing = false;
    }
  }

  Future<void> _fitGroup([_MiniMapSnapshot? snapshot]) async {
    final controller = _controller;
    if (controller == null) return;
    final effective = snapshot ?? _snapshot();
    final points = <GeoPoint?>[
      effective.currentPosition,
      ...effective.riders.map((rider) => rider.point),
    ].nonNulls.toList(growable: false);
    if (points.isEmpty) return;
    if (points.length == 1) {
      await controller.animateCamera(
        ml.CameraUpdate.newLatLngZoom(
          ml.LatLng(points.single.latitude, points.single.longitude),
          14.5,
        ),
        duration: const Duration(milliseconds: 500),
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
      duration: const Duration(milliseconds: 500),
    );
  }

  Map<String, dynamic> _routeGeoJson(_MiniMapSnapshot snapshot) =>
      MapGeoJson.lines(_visibleRoutePaths(snapshot), idPrefix: 'mini-route');

  /// The mini-map follows the group, not the entire ride. Rendering a long
  /// route in a tight group viewport creates clipped, disconnected-looking
  /// lines which can be mistaken for an invalid route. Keep only contiguous
  /// route segments near the currently visible riders.
  List<List<GeoPoint>> _visibleRoutePaths(_MiniMapSnapshot snapshot) {
    final groupPoints = <GeoPoint?>[
      snapshot.currentPosition,
      ...snapshot.riders.map((rider) => rider.point),
    ].nonNulls.toList(growable: false);
    if (groupPoints.isEmpty) return const [];

    var south = groupPoints.first.latitude;
    var north = south;
    var west = groupPoints.first.longitude;
    var east = west;
    for (final point in groupPoints.skip(1)) {
      south = math.min(south, point.latitude);
      north = math.max(north, point.latitude);
      west = math.min(west, point.longitude);
      east = math.max(east, point.longitude);
    }

    // Match the min-size and breathing room of the mini-map camera, with a
    // little extra room so the local route does not terminate at an edge.
    final latitudePadding = math.max((north - south) * 0.35, 0.0018);
    final longitudePadding = math.max((east - west) * 0.35, 0.0024);
    south -= latitudePadding;
    north += latitudePadding;
    west -= longitudePadding;
    east += longitudePadding;

    final visiblePaths = <List<GeoPoint>>[];
    for (final path in snapshot.routePaths) {
      var segment = <GeoPoint>[];
      for (final point in path) {
        final isVisible =
            point.latitude >= south &&
            point.latitude <= north &&
            point.longitude >= west &&
            point.longitude <= east;
        if (isVisible) {
          segment.add(point);
        } else if (segment.length >= 2) {
          visiblePaths.add(segment);
          segment = <GeoPoint>[];
        } else {
          segment = <GeoPoint>[];
        }
      }
      if (segment.length >= 2) visiblePaths.add(segment);
    }
    return visiblePaths;
  }

  Map<String, dynamic> _riderGeoJson(_MiniMapSnapshot snapshot) =>
      MapGeoJson.points([
        for (final rider in snapshot.riders)
          MapGeoJsonPoint(
            id: rider.id,
            point: rider.point,
            properties: {'color': _hexColor(rider.color)},
          ),
        if (snapshot.currentPosition case final point?)
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

class _MiniMapBadge extends StatelessWidget {
  const _MiniMapBadge({super.key, required this.label, this.dotColor});

  final String label;
  final Color? dotColor;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: const Color(0xD90D1117),
      borderRadius: BorderRadius.circular(7),
      border: Border.all(color: const Color(0x80566273)),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dotColor case final color?) ...[
            DecoratedBox(
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 0.8),
              ),
              child: const SizedBox.square(dimension: 7),
            ),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 8,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    ),
  );
}

class _MiniMapScaleBar extends StatelessWidget {
  const _MiniMapScaleBar({required this.width, required this.points});

  final double width;
  final List<GeoPoint> points;

  @override
  Widget build(BuildContext context) {
    final scale = _scale();
    return Semantics(
      key: const Key('mini-map-scale'),
      label: 'Map scale ${scale.label}',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xD90D1117),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(5, 2, 5, 3),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                scale.label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 7,
                  fontWeight: FontWeight.w800,
                ),
              ),
              Container(
                width: scale.width,
                height: 2,
                decoration: const BoxDecoration(
                  color: Colors.white,
                  border: Border.symmetric(
                    vertical: BorderSide(color: Colors.white, width: 1),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  ({String label, double width}) _scale() {
    if (points.isEmpty) return (label: '50 m', width: 32);
    var south = points.first.latitude;
    var north = south;
    var west = points.first.longitude;
    var east = west;
    for (final point in points.skip(1)) {
      south = math.min(south, point.latitude);
      north = math.max(north, point.latitude);
      west = math.min(west, point.longitude);
      east = math.max(east, point.longitude);
    }
    final latitudeCenter = (north + south) / 2;
    final longitudeCenter = (east + west) / 2;
    final longitudeSpan = math.max(east - west, 0.0032) * 1.45;
    west = longitudeCenter - longitudeSpan / 2;
    east = longitudeCenter + longitudeSpan / 2;
    final mapWidthMeters = _mapDistanceMeters(
      GeoPoint(latitude: latitudeCenter, longitude: west),
      GeoPoint(latitude: latitudeCenter, longitude: east),
    );
    const candidates = <double>[
      10,
      20,
      50,
      100,
      200,
      500,
      1000,
      2000,
      5000,
      10000,
    ];
    final maximumScaleMeters = mapWidthMeters * 0.32;
    final scaleMeters = candidates.lastWhere(
      (candidate) => candidate <= maximumScaleMeters,
      orElse: () => candidates.first,
    );
    final barWidth = (width * scaleMeters / mapWidthMeters).clamp(18.0, 58.0);
    final label = scaleMeters >= 1000
        ? '${(scaleMeters / 1000).toStringAsFixed(scaleMeters % 1000 == 0 ? 0 : 1)} km'
        : '${scaleMeters.round()} m';
    return (label: label, width: barWidth);
  }
}

class _GroupMiniMapPainter extends CustomPainter {
  const _GroupMiniMapPainter({
    required this.routePaths,
    required this.currentPosition,
    required this.riders,
    required this.brightness,
  });

  final List<List<GeoPoint>> routePaths;
  final GeoPoint? currentPosition;
  final List<MapOverlayMarker> riders;
  final Brightness brightness;

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
      Paint()..color = groupMiniMapBackgroundColor(brightness),
    );
    final gridPaint = Paint()
      ..color = groupMiniMapGridColor(brightness)
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

    for (final route in routePaths.where((path) => path.length >= 2)) {
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
          ..color = const Color(0xE63478F6)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }

    void drawRider(Offset offset, Color color, double radius) {
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

    final dots = <({GeoPoint point, Color color, double radius})>[
      for (final rider in riders)
        (point: rider.point, color: rider.color, radius: 5),
      if (currentPosition case final point?)
        (point: point, color: const Color(0xFFFF7A1A), radius: 6),
    ];
    final placedOffsets = <Offset>[];
    for (var index = 0; index < dots.length; index++) {
      final dot = dots[index];
      var offset = project(dot.point);
      // Riders can briefly share a synthetic GPS fix at a junction. Separate
      // only overlapping dots in this compact overview so the group count is
      // visible at a glance without changing their actual map positions.
      final overlaps = placedOffsets
          .where((placed) => (placed - offset).distance < 13)
          .length;
      if (overlaps > 0) {
        final angle = (index * 2.4) + (overlaps * 0.8);
        final spread = 10.0 + (overlaps * 3.0);
        offset += Offset(math.cos(angle) * spread, math.sin(angle) * spread);
      }
      offset = Offset(
        offset.dx.clamp(7.0, size.width - 7.0),
        offset.dy.clamp(7.0, size.height - 7.0),
      );
      placedOffsets.add(offset);
      drawRider(offset, dot.color, dot.radius);
    }
  }

  @override
  bool shouldRepaint(_GroupMiniMapPainter oldDelegate) => true;
}

class _JunctionMarkerOverlay extends StatelessWidget {
  const _JunctionMarkerOverlay({
    required this.overlay,
    required this.compact,
    required this.maxWidth,
    required this.distanceUnit,
  });

  final MapJunctionMarkerOverlay overlay;
  final bool compact;
  final double maxWidth;
  final DistanceUnit distanceUnit;

  @override
  Widget build(BuildContext context) {
    final color = switch (overlay.stage) {
      MapJunctionMarkerStage.waitingForRiders => const Color(0xFFFFC857),
      MapJunctionMarkerStage.tecApproaching => const Color(0xFFFFA24C),
      MapJunctionMarkerStage.readyToRideOff => const Color(0xFF6ED89A),
    };
    final padding = compact
        ? const EdgeInsets.symmetric(horizontal: 14, vertical: 10)
        : const EdgeInsets.fromLTRB(16, 13, 16, 12);
    final tecDistance = overlay.tecDistanceMeters;
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Card(
        key: const Key('junction-marker-overlay'),
        margin: EdgeInsets.zero,
        color: const Color(0xEE121820),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: color.withValues(alpha: 0.9), width: 1.5),
        ),
        child: Padding(
          padding: padding,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.alt_route, color: color),
                  const SizedBox(width: 9),
                  const Expanded(
                    child: Text(
                      'JUNCTION MARKER',
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.7,
                      ),
                    ),
                  ),
                  _MarkerStatusPill(label: 'AUTO', color: color),
                ],
              ),
              const SizedBox(height: 7),
              Text(
                overlay.isLocalMarker
                    ? 'You are holding this junction.'
                    : '${overlay.markerRiderName} is holding this junction.',
                style: const TextStyle(
                  color: Color(0xFFD8E0EA),
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 9),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  _MarkerMetric(
                    icon: Icons.groups_outlined,
                    label:
                        '${overlay.ridersPassed}/${overlay.ridersExpected} passed',
                  ),
                  if (tecDistance != null)
                    _MarkerMetric(
                      icon: Icons.shield_outlined,
                      label:
                          'TEC ${MeasurementFormatter(distanceUnit).distance(tecDistance)} away',
                      color: const Color(0xFF68A9FF),
                    ),
                ],
              ),
              const SizedBox(height: 9),
              Text(
                overlay.instruction,
                style: TextStyle(color: color, fontWeight: FontWeight.w800),
              ),
              if (overlay.stage == MapJunctionMarkerStage.tecApproaching) ...[
                const SizedBox(height: 7),
                const Text(
                  'GET READY TO RIDE OFF',
                  key: Key('junction-marker-get-ready'),
                  style: TextStyle(
                    color: Color(0xFFFFC857),
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.8,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _MarkerMetric extends StatelessWidget {
  const _MarkerMetric({required this.icon, required this.label, this.color});

  final IconData icon;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
    decoration: BoxDecoration(
      color: const Color(0xFF202A35),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: color ?? const Color(0xFFB7C2CF)),
        const SizedBox(width: 5),
        Text(
          label,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
        ),
      ],
    ),
  );
}

class _MarkerStatusPill extends StatelessWidget {
  const _MarkerStatusPill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.17),
      borderRadius: BorderRadius.circular(99),
      border: Border.all(color: color.withValues(alpha: 0.7)),
    ),
    child: Text(
      label,
      style: TextStyle(
        color: color,
        fontWeight: FontWeight.w900,
        fontSize: 10,
        letterSpacing: 0.8,
      ),
    ),
  );
}

class _NavigationGuidanceBanner extends StatelessWidget {
  const _NavigationGuidanceBanner({
    required this.guidance,
    required this.distanceUnit,
    required this.compact,
  });

  final NavigationGuidance guidance;
  final DistanceUnit distanceUnit;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final distance = MeasurementFormatter(
      distanceUnit,
    ).distance(guidance.distanceMeters);
    final instruction = _maneuverInstruction(guidance.maneuver);
    final semanticLabel = '$instruction in $distance. ${guidance.roadLabel}';
    return Semantics(
      key: const Key('navigation-guidance-banner'),
      container: true,
      liveRegion: true,
      label: semanticLabel,
      excludeSemantics: true,
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Container(
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 10 : 12,
              vertical: compact ? 7 : 9,
            ),
            decoration: BoxDecoration(
              color: const Color(0xF2252E39),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFF445262)),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x55000000),
                  blurRadius: 10,
                  offset: Offset(0, 3),
                ),
              ],
            ),
            child: Row(
              children: [
                Icon(
                  _maneuverIcon(guidance.maneuver),
                  size: compact ? 30 : 38,
                  color: const Color(0xFF68A9FF),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '$distance · $instruction',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: compact ? 14 : 16,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      Text(
                        guidance.roadLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Color(0xFFB7C2CF)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

IconData _maneuverIcon(RouteManeuver maneuver) {
  final type = maneuver.type.toLowerCase();
  final modifier = maneuver.modifier?.toLowerCase() ?? '';
  if (type == 'arrive') return Icons.flag;
  if (type == 'roundabout' || type == 'rotary') {
    return modifier.contains('right')
        ? Icons.roundabout_right
        : Icons.roundabout_left;
  }
  if (type == 'merge') return Icons.merge;
  if (type == 'fork') return Icons.call_split;
  if (modifier.contains('u-turn') || modifier.contains('uturn')) {
    return modifier.contains('right') ? Icons.u_turn_right : Icons.u_turn_left;
  }
  if (modifier.contains('slight left')) return Icons.turn_slight_left;
  if (modifier.contains('slight right')) return Icons.turn_slight_right;
  if (modifier.contains('left')) return Icons.turn_left;
  if (modifier.contains('right')) return Icons.turn_right;
  return Icons.straight;
}

String _maneuverInstruction(RouteManeuver maneuver) {
  final type = maneuver.type.toLowerCase();
  final modifier = maneuver.modifier?.toLowerCase() ?? '';
  if (type == 'arrive') return 'Arrive';
  if (type == 'roundabout' || type == 'rotary') {
    return modifier.isEmpty || modifier == 'straight'
        ? 'Continue at roundabout'
        : 'At roundabout, bear $modifier';
  }
  if (type == 'merge') {
    return modifier.isEmpty ? 'Merge' : 'Merge $modifier';
  }
  if (type == 'fork') {
    return modifier.isEmpty ? 'Keep at fork' : 'Keep $modifier';
  }
  if (modifier.contains('u-turn') || modifier.contains('uturn')) {
    return 'Make a U-turn';
  }
  if (modifier == 'straight' || modifier.isEmpty) return 'Continue straight';
  return 'Turn $modifier';
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
    required this.style,
    required this.badgeColor,
  });

  final bool navigationMode;
  final double headingDegrees;
  final MotorcycleIconStyle style;
  final Color badgeColor;

  @override
  Widget build(BuildContext context) => Transform.rotate(
    // The badge circle is rotation-symmetric, so only the bike glyph inside
    // visibly turns - this keeps showing heading without the odd look a
    // rotating non-circular marker would have.
    angle: navigationMode ? 0 : headingDegrees * math.pi / 180,
    child: DecoratedBox(
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [BoxShadow(color: Colors.black45, blurRadius: 5)],
      ),
      child: RiderMarkerBadge(
        style: style,
        badgeColor: badgeColor,
        size: 38,
        borderColor: Colors.white,
        borderWidth: 3,
      ),
    ),
  );
}

/// A white Material icon on a filled colour circle - the non-bike equivalent
/// of [RiderMarkerBadge], used for hazard markers so both marker families
/// read the same way against any basemap.
class _IconBadge extends StatelessWidget {
  const _IconBadge({
    required this.icon,
    required this.badgeColor,
    this.size = 34,
  });

  final IconData icon;
  final Color badgeColor;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: badgeColor,
      shape: BoxShape.circle,
      border: Border.all(color: const Color(0xFF10151C), width: 2),
    ),
    child: Icon(icon, color: Colors.white, size: size * 0.56),
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

class _RidePausedBanner extends StatelessWidget {
  const _RidePausedBanner();

  @override
  Widget build(BuildContext context) => Center(
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xE6252E39),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: const Color(0xFFFFC857)),
      ),
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.pause_circle_filled, color: Color(0xFFFFC857)),
            SizedBox(width: 8),
            Text(
              'GROUP RIDE PAUSED',
              style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 0.7),
            ),
          ],
        ),
      ),
    ),
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
