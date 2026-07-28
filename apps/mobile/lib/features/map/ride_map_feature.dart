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

import '../../controllers/speed_limit_display_controller.dart';
import '../../data/json_file_completed_ride_store.dart';
import '../../data/json_file_recorded_route_store.dart';
import '../../data/json_file_route_store.dart';
import '../../domain/completed_ride_store.dart';
import '../../domain/distance_unit.dart';
import '../../domain/hazard.dart';
import '../../domain/imported_route.dart';
import '../../domain/quick_message.dart';
import '../../domain/recorded_route_store.dart';
import '../../domain/ride_role.dart';
import '../../domain/route_store.dart';
import '../../internet/plan_directory.dart';
import '../../services/basemap_configuration.dart';
import '../../services/demo_route_loader.dart';
import '../../services/discovery_suggestion_queue.dart';
import '../../services/enforcement_alert_detector.dart';
import '../../services/gpx_import_source.dart';
import '../../services/group_pip_bridge.dart';
import '../../services/leader_ride_status.dart';
import '../../services/tec_gap_trend.dart';
import '../../services/map_geojson.dart';
import '../../services/map_style_repository.dart';
import '../../services/maplibre_offline_manager.dart';
import '../../services/measurement_formatter.dart';
import '../../services/navigation_guidance.dart';
import '../../services/motorcycle_discovery.dart';
import '../../services/navigation_export.dart';
import '../../services/navigation_camera.dart';
import '../../services/navigation_heading.dart';
import '../../services/offline_tile_cache.dart';
import '../../services/received_quick_message.dart';
import '../../services/rider_trail_recorder.dart';
import '../../services/road_routing.dart';
import '../../services/route_geometry_enricher.dart';
import '../../services/route_importer.dart';
import '../../services/route_marker_plan.dart';
import '../../services/route_progress.dart';
import '../../services/speed_limit.dart';
import '../../services/stored_route_library.dart';
import '../../services/trail_direction_arrows.dart';
import 'destination_route_sheet.dart';
import 'maneuver_list_screen.dart';
import 'maneuver_symbol.dart';
import 'group_mini_map_framing.dart';
import 'motorcycle_icon.dart';
import 'navigation_export_sheet.dart';
import 'route_review_screen.dart';
import 'route_trail_style.dart';
import 'stored_route_picker.dart';

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

/// The portrait bottom-anchored chrome band, as one measurable subtree.
///
/// #105's camera bias consumes the height of this band as a fraction of the map
/// viewport, so the band is the thing a test has to measure. Exposed here so
/// that fraction is asserted against the real layout instead of a sum of assumed
/// overlay heights.
@visibleForTesting
const Key portraitBottomChromeKey = Key('map-portrait-bottom-chrome');

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
    this.riderTrails,
    this.leaderStatus,
    this.tecGapTrend,
    this.groupRiderCount,
    this.onOpenRoster,
    this.junctionMarkerOverlay,
    this.enforcementAlert,
    this.quickMessageAlerts,
    this.onAcknowledgeQuickMessage,
    this.onReportHazard,
    this.emergencyContacts = const [],
    this.onEmergencyAlert,
    this.onEmergencyIssue,
    this.ridePaused = false,
    this.rideHasNoLeader = false,
    this.onLeaveRide,
    this.onOpenRideMenu,
    this.onRouteChanged,
    this.onRouteCommitted,
    this.onNavigationGuidanceChanged,
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
    this.speedLimitDisplay,
    this.basemapConfiguration = const BasemapConfiguration(),
    this.localMotorcycleStyle = motorcycleIconStyleDefault,
    this.localBadgeColor = const Color(0xFF2F80ED),
  });

  factory RideMapFeature.fromEnvironment({
    Key? key,
    ValueListenable<GeoPoint?>? currentPosition,
    ValueListenable<MapNavigationPosition?>? navigationPosition,
    ValueListenable<List<MapOverlayMarker>>? overlayMarkers,
    ValueListenable<List<MapOverlayTrace>>? riderTrails,
    ValueListenable<LeaderRideStatus?>? leaderStatus,
    ValueListenable<TecGapTrend>? tecGapTrend,
    int? groupRiderCount,
    VoidCallback? onOpenRoster,
    ValueListenable<MapJunctionMarkerOverlay?>? junctionMarkerOverlay,
    ValueListenable<EnforcementAlert?>? enforcementAlert,
    ValueListenable<List<RideQuickMessageAlert>>? quickMessageAlerts,
    Future<void> Function(ReceivedQuickMessage message)?
    onAcknowledgeQuickMessage,
    Future<void> Function(HazardType type)? onReportHazard,
    List<MapEmergencyContact> emergencyContacts = const [],
    Future<void> Function()? onEmergencyAlert,
    Future<void> Function(QuickMessage message)? onEmergencyIssue,
    bool ridePaused = false,
    bool rideHasNoLeader = false,
    Future<void> Function()? onLeaveRide,
    Future<void> Function()? onOpenRideMenu,
    ValueChanged<ImportedRoute?>? onRouteChanged,
    ValueChanged<ImportedRoute?>? onRouteCommitted,
    ValueChanged<NavigationGuidance?>? onNavigationGuidanceChanged,
    Object? changeRouteRequestToken,
    VoidCallback? onChangeRouteRequestHandled,
    PickedGpxFile? pendingSharedGpxFile,
    Future<GeoPoint?> Function()? acquireCurrentPosition,
    RouteStore? routeStore,
    bool canEditRoute = true,
    DistanceUnit distanceUnit = DistanceUnit.kilometres,
    SpeedLimitDisplayController? speedLimitDisplay,
    bool darkMapStyle = false,
    MotorcycleIconStyle localMotorcycleStyle = motorcycleIconStyleDefault,
    Color localBadgeColor = const Color(0xFF2F80ED),
  }) => RideMapFeature(
    key: key,
    currentPosition: currentPosition,
    navigationPosition: navigationPosition,
    overlayMarkers: overlayMarkers,
    riderTrails: riderTrails,
    leaderStatus: leaderStatus,
    tecGapTrend: tecGapTrend,
    groupRiderCount: groupRiderCount,
    onOpenRoster: onOpenRoster,
    junctionMarkerOverlay: junctionMarkerOverlay,
    enforcementAlert: enforcementAlert,
    quickMessageAlerts: quickMessageAlerts,
    onAcknowledgeQuickMessage: onAcknowledgeQuickMessage,
    onReportHazard: onReportHazard,
    emergencyContacts: emergencyContacts,
    onEmergencyAlert: onEmergencyAlert,
    onEmergencyIssue: onEmergencyIssue,
    ridePaused: ridePaused,
    rideHasNoLeader: rideHasNoLeader,
    onLeaveRide: onLeaveRide,
    onOpenRideMenu: onOpenRideMenu,
    onRouteChanged: onRouteChanged,
    onRouteCommitted: onRouteCommitted,
    onNavigationGuidanceChanged: onNavigationGuidanceChanged,
    changeRouteRequestToken: changeRouteRequestToken,
    onChangeRouteRequestHandled: onChangeRouteRequestHandled,
    pendingSharedGpxFile: pendingSharedGpxFile,
    acquireCurrentPosition: acquireCurrentPosition,
    routeStore: routeStore,
    canEditRoute: canEditRoute,
    distanceUnit: distanceUnit,
    speedLimitDisplay: speedLimitDisplay,
    basemapConfiguration: BasemapConfiguration.fromEnvironment().forBrightness(
      dark: darkMapStyle,
    ),
    localMotorcycleStyle: localMotorcycleStyle,
    localBadgeColor: localBadgeColor,
  );

  final ValueListenable<GeoPoint?>? currentPosition;
  final ValueListenable<MapNavigationPosition?>? navigationPosition;
  final ValueListenable<List<MapOverlayMarker>>? overlayMarkers;
  final ValueListenable<List<MapOverlayTrace>>? riderTrails;
  final ValueListenable<LeaderRideStatus?>? leaderStatus;

  /// Which way the gap to the TEC is going (#181). Null where no trend is
  /// tracked, in which case the gap card shows the distance alone.
  final ValueListenable<TecGapTrend>? tecGapTrend;
  final int? groupRiderCount;
  final VoidCallback? onOpenRoster;
  final ValueListenable<MapJunctionMarkerOverlay?>? junctionMarkerOverlay;
  final ValueListenable<EnforcementAlert?>? enforcementAlert;

  /// Quick messages other riders have raised, most urgent first, together with
  /// where each sender is (#151). Null when the embedder has no ride behind it.
  final ValueListenable<List<RideQuickMessageAlert>>? quickMessageAlerts;

  /// Records that this rider has seen a quick message, so its sender is told.
  final Future<void> Function(ReceivedQuickMessage message)?
  onAcknowledgeQuickMessage;
  final Future<void> Function(HazardType type)? onReportHazard;
  final List<MapEmergencyContact> emergencyContacts;
  final Future<void> Function()? onEmergencyAlert;
  final Future<void> Function(QuickMessage message)? onEmergencyIssue;
  final bool ridePaused;
  final bool rideHasNoLeader;
  final Future<void> Function()? onLeaveRide;
  final Future<void> Function()? onOpenRideMenu;
  final ValueChanged<ImportedRoute?>? onRouteChanged;
  final ValueChanged<ImportedRoute?>? onRouteCommitted;
  final ValueChanged<NavigationGuidance?>? onNavigationGuidanceChanged;
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
  final SpeedLimitDisplayController? speedLimitDisplay;
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

  @override
  void didUpdateWidget(RideMapFeature oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.routeStore, widget.routeStore) ||
        !identical(oldWidget.offlineTileCache, widget.offlineTileCache) ||
        oldWidget.mapStyleString != widget.mapStyleString ||
        !identical(
          oldWidget.mapLibreOfflineManager,
          widget.mapLibreOfflineManager,
        )) {
      setState(() {
        _dependencies = _openDependencies();
      });
    }
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
        key: ObjectKey(dependencies),
        routeStore: dependencies.store,
        routeImporter: RouteImporter(source: const SystemGpxImportSource()),
        offlineTileCache: dependencies.cache,
        mapLibreOfflineManager: dependencies.mapLibreOfflineManager,
        mapStyleString: dependencies.mapStyleString,
        disposeOfflineTileCache: widget.offlineTileCache == null,
        currentPosition: widget.currentPosition,
        navigationPosition: widget.navigationPosition,
        overlayMarkers: widget.overlayMarkers,
        riderTrails: widget.riderTrails,
        leaderStatus: widget.leaderStatus,
        tecGapTrend: widget.tecGapTrend,
        groupRiderCount: widget.groupRiderCount,
        onOpenRoster: widget.onOpenRoster,
        junctionMarkerOverlay: widget.junctionMarkerOverlay,
        enforcementAlert: widget.enforcementAlert,
        quickMessageAlerts: widget.quickMessageAlerts,
        onAcknowledgeQuickMessage: widget.onAcknowledgeQuickMessage,
        onReportHazard: widget.onReportHazard,
        emergencyContacts: widget.emergencyContacts,
        onEmergencyAlert: widget.onEmergencyAlert,
        onEmergencyIssue: widget.onEmergencyIssue,
        ridePaused: widget.ridePaused,
        rideHasNoLeader: widget.rideHasNoLeader,
        onLeaveRide: widget.onLeaveRide,
        onOpenRideMenu: widget.onOpenRideMenu,
        canEditRoute: widget.canEditRoute,
        onRouteChanged: widget.onRouteChanged,
        onRouteCommitted: widget.onRouteCommitted,
        onNavigationGuidanceChanged: widget.onNavigationGuidanceChanged,
        changeRouteRequestToken: widget.changeRouteRequestToken,
        onChangeRouteRequestHandled: widget.onChangeRouteRequestHandled,
        pendingSharedGpxFile: widget.pendingSharedGpxFile,
        acquireCurrentPosition: widget.acquireCurrentPosition,
        navigationExportCoordinator: widget.navigationExportCoordinator,
        distanceUnit: widget.distanceUnit,
        speedLimitDisplay: widget.speedLimitDisplay,
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
    this.riderTrails,
    this.leaderStatus,
    this.tecGapTrend,
    this.groupRiderCount,
    this.onOpenRoster,
    this.junctionMarkerOverlay,
    this.enforcementAlert,
    this.quickMessageAlerts,
    this.onAcknowledgeQuickMessage,
    this.onReportHazard,
    this.emergencyContacts = const [],
    this.onEmergencyAlert,
    this.onEmergencyIssue,
    this.ridePaused = false,
    this.rideHasNoLeader = false,
    this.onLeaveRide,
    this.onOpenRideMenu,
    this.canEditRoute = true,
    this.onRouteChanged,
    this.onRouteCommitted,
    this.onNavigationGuidanceChanged,
    this.changeRouteRequestToken,
    this.onChangeRouteRequestHandled,
    this.pendingSharedGpxFile,
    this.acquireCurrentPosition,
    this.navigationExportCoordinator,
    this.destinationRoutePlanner,
    this.routeGeometryEnricher,
    this.demoRouteLoader,
    this.recordedRouteStore,
    this.completedRideStore,
    this.storedRouteLibrary,
    this.distanceUnit = DistanceUnit.kilometres,
    this.speedLimitDisplay,
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
  final ValueListenable<List<MapOverlayTrace>>? riderTrails;
  final ValueListenable<LeaderRideStatus?>? leaderStatus;

  /// Which way the gap to the TEC is going (#181). Null where no trend is
  /// tracked, in which case the gap card shows the distance alone.
  final ValueListenable<TecGapTrend>? tecGapTrend;
  final int? groupRiderCount;
  final VoidCallback? onOpenRoster;
  final ValueListenable<MapJunctionMarkerOverlay?>? junctionMarkerOverlay;
  final ValueListenable<EnforcementAlert?>? enforcementAlert;

  /// Quick messages other riders have raised, most urgent first, together with
  /// where each sender is (#151). Null when the embedder has no ride behind it.
  final ValueListenable<List<RideQuickMessageAlert>>? quickMessageAlerts;

  /// Records that this rider has seen a quick message, so its sender is told.
  final Future<void> Function(ReceivedQuickMessage message)?
  onAcknowledgeQuickMessage;
  final Future<void> Function(HazardType type)? onReportHazard;
  final List<MapEmergencyContact> emergencyContacts;
  final Future<void> Function()? onEmergencyAlert;
  final Future<void> Function(QuickMessage message)? onEmergencyIssue;
  final bool ridePaused;
  final bool rideHasNoLeader;
  final Future<void> Function()? onLeaveRide;
  final Future<void> Function()? onOpenRideMenu;
  final bool canEditRoute;
  final ValueChanged<ImportedRoute?>? onRouteChanged;
  final ValueChanged<ImportedRoute?>? onRouteCommitted;
  final ValueChanged<NavigationGuidance?>? onNavigationGuidanceChanged;
  final Object? changeRouteRequestToken;
  final VoidCallback? onChangeRouteRequestHandled;
  final PickedGpxFile? pendingSharedGpxFile;
  final Future<GeoPoint?> Function()? acquireCurrentPosition;
  final NavigationExportCoordinator? navigationExportCoordinator;
  final DestinationRoutePlanner? destinationRoutePlanner;
  final RouteGeometryEnricher? routeGeometryEnricher;
  final Future<ImportedRoute> Function()? demoRouteLoader;

  /// Stored geometry, resolved from the app's own on-disk stores when these are
  /// null.
  ///
  /// The map opens these itself rather than having them threaded through the
  /// ride shell, for the same reason it owns the route file: the ride screen
  /// must not acquire a second opinion about which routes exist. Both stores
  /// are read fresh each time the picker opens, so a ride deleted from the
  /// archive stops being offered immediately.
  final RecordedRouteStore? recordedRouteStore;
  final CompletedRideStore? completedRideStore;

  /// A fully assembled library, for tests that want to fix the identity and
  /// timestamp of the route it produces.
  final StoredRouteLibrary? storedRouteLibrary;

  final DistanceUnit distanceUnit;
  final SpeedLimitDisplayController? speedLimitDisplay;
  final bool disposeOfflineTileCache;
  final MotorcycleIconStyle localMotorcycleStyle;
  final Color localBadgeColor;

  @override
  State<RideMapScreen> createState() => _RideMapScreenState();
}

class _RideMapScreenState extends State<RideMapScreen> {
  static const _remainingRouteSource = 'ride-relay-route-remaining';
  static const _riddenRouteSource = 'ride-relay-route-ridden';
  static const _riderTrailSource = 'ride-relay-rider-trails';
  static const _casingHex = RouteTrailStyle.casingHex;
  static const _trailDirectionArrowSource = 'ride-relay-trail-direction-arrows';
  static const _waypointSource = 'ride-relay-waypoints';
  static const _positionSource = 'ride-relay-position';
  static const _overlaySource = 'ride-relay-overlays';
  static const _markerPlanSource = 'ride-relay-marker-plan';
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
  late SpeedLimitDisplayController _speedLimitDisplay;
  late bool _ownsSpeedLimitDisplay;
  late final GroupPipBridge _groupPipBridge;
  ml.MapLibreMapController? _mapLibreController;
  late final MapLibreOfflineManager _mapLibreOfflineManager;
  bool _mapLibreStyleReady = false;

  /// The imported or leader-published route, when there is one.
  ///
  /// Riding without a GPX is a first-class mode, so **nothing** reads this to
  /// decide whether a safety, ride-lifecycle, camera or presence surface exists
  /// (#124). Every remaining `_route` test in this file is either null-safe data
  /// access or one of these genuinely route-derived surfaces, and each is
  /// annotated where it appears:
  ///
  /// - the app-bar title, and the plan/import/replace, navigate-or-export, fit,
  ///   offline-download and remove-route route actions;
  /// - "All turns" and the marker plan, which need manoeuvres;
  /// - the empty-route prompt, which exists to acquire a route;
  /// - the planned-route geometry, its ridden/remaining split, waypoints, and
  ///   the guidance banner and off-course alerting derived from it.
  ///
  /// Trails, the group overview, presence, SOS, Leave, Report, pause, the ride
  /// menu, the follow camera and the speed limit are all independent of it. Add
  /// a justification here and at the site before adding another test, or the
  /// route-less ride quietly loses another control.
  ImportedRoute? _route;
  Object? _loadError;
  bool _loading = true;
  bool _importing = false;
  bool _exporting = false;
  bool _routing = false;
  bool _navigationMode = false;
  bool _navigationCanvasActive = false;
  bool _markerOverviewVisible = false;
  bool _markerPlanVisible = false;
  bool _autoFollowSuppressed = false;
  bool _cameraFramingRefreshScheduled = false;
  bool _emergencyAlertSending = false;
  bool _emergencyAlertSent = false;
  bool _emergencyActionsOpen = false;
  bool _emergencyActionsDismissed = false;
  Object? _handledChangeRouteRequestToken;
  double _lastHeadingDegrees = 0;
  // Dismissal is per hazard, so passing this one and approaching the next
  // still raises a fresh warning.
  String? _dismissedEnforcementAlertId;
  // Quick messages whose full-screen interrupt this rider has already closed,
  // and receipts of their own messages they have already read (#151). Per event
  // id in both cases: closing one interrupt must not suppress the next rider's
  // emergency, and the persistent row survives the interrupt either way, so
  // nothing is lost by dismissing.
  final Set<String> _dismissedQuickMessageInterrupts = {};
  final Set<String> _dismissedQuickMessageReceipts = {};
  String? _acknowledgingQuickMessageId;
  double _cameraBearingDegrees = 0;
  final NavigationHeadingSmoother _headingSmoother =
      NavigationHeadingSmoother();
  // The map viewport and the bottom chrome band are measured from the last laid
  // out frame so the camera's forward bias is derived from the real geometry
  // rather than from assumed overlay heights.
  final GlobalKey _mapViewportKey = GlobalKey();
  final GlobalKey _bottomChromeKey = GlobalKey();
  double? _smoothedNavigationSpeedMetersPerSecond;
  // The speed readout is its own notifier so a new fix repaints the badge
  // without rebuilding the map: MapLibre keeps its platform view mounted and
  // only calls setState when navigation mode changes.
  final ValueNotifier<double?> _riderSpeedMetersPerSecond = ValueNotifier(null);
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

  /// Route-derived: the marker plan is an analysis of the planned route.
  RouteMarkerPlan get _markerPlan => _route == null
      ? const RouteMarkerPlan(points: [])
      : const RouteMarkerPlanAnalyzer().analyze(_route!);

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
    _ownsSpeedLimitDisplay = widget.speedLimitDisplay == null;
    _speedLimitDisplay =
        widget.speedLimitDisplay ?? SpeedLimitDisplayController.inMemory();
    _groupPipBridge = GroupPipBridge();
    _mapLibreOfflineManager =
        widget.mapLibreOfflineManager ??
        MapLibreOfflineManager(configuration: _basemap);
    widget.currentPosition?.addListener(_onPositionChanged);
    widget.navigationPosition?.addListener(_onPositionChanged);
    widget.overlayMarkers?.addListener(_onOverlayDataChanged);
    widget.riderTrails?.addListener(_onOverlayDataChanged);
    widget.leaderStatus?.addListener(_onGroupPipDataChanged);
    widget.junctionMarkerOverlay?.addListener(_onJunctionMarkerChanged);
    _observeSpeedLimit(_navigationFix);
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
    if (oldWidget.riderTrails != widget.riderTrails) {
      oldWidget.riderTrails?.removeListener(_onOverlayDataChanged);
      widget.riderTrails?.addListener(_onOverlayDataChanged);
    }
    if (oldWidget.leaderStatus != widget.leaderStatus) {
      oldWidget.leaderStatus?.removeListener(_onGroupPipDataChanged);
      widget.leaderStatus?.addListener(_onGroupPipDataChanged);
      _onGroupPipDataChanged();
    }
    if (oldWidget.junctionMarkerOverlay != widget.junctionMarkerOverlay) {
      oldWidget.junctionMarkerOverlay?.removeListener(_onJunctionMarkerChanged);
      widget.junctionMarkerOverlay?.addListener(_onJunctionMarkerChanged);
      _onJunctionMarkerChanged();
    }
    if (oldWidget.speedLimitDisplay != widget.speedLimitDisplay) {
      if (_ownsSpeedLimitDisplay) _speedLimitDisplay.dispose();
      _ownsSpeedLimitDisplay = widget.speedLimitDisplay == null;
      _speedLimitDisplay =
          widget.speedLimitDisplay ?? SpeedLimitDisplayController.inMemory();
      _observeSpeedLimit(_navigationFix);
    }
  }

  @override
  void dispose() {
    _downloadCancellation?.cancel();
    widget.currentPosition?.removeListener(_onPositionChanged);
    widget.navigationPosition?.removeListener(_onPositionChanged);
    widget.overlayMarkers?.removeListener(_onOverlayDataChanged);
    widget.riderTrails?.removeListener(_onOverlayDataChanged);
    widget.leaderStatus?.removeListener(_onGroupPipDataChanged);
    widget.junctionMarkerOverlay?.removeListener(_onJunctionMarkerChanged);
    _mapLibreController?.onFeatureTapped.remove(_onMapLibreFeatureTapped);
    _mapLibreController?.removeListener(_scheduleCameraFramingRefresh);
    _mapController.dispose();
    _navigationGuidance.dispose();
    _riderSpeedMetersPerSecond.dispose();
    if (_ownsSpeedLimitDisplay) _speedLimitDisplay.dispose();
    unawaited(_groupPipBridge.dispose());
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
        // Riding without a GPX is a first-class mode (#124), so following the
        // rider is driven by position and heading alone. A route changes what is
        // drawn, never whether the camera tracks the bike.
        _navigationMode = _isMoving && !_markerOverviewVisible;
        // A route load reframes the map, so any viewport follow mode had is gone.
        _releaseNavigationViewport();
        // Once we have a position, keep the map canvas at its navigation size.
        // Tying this to the instantaneous speed made the AppBar appear briefly
        // whenever a GPS update arrived while stopped.
        _navigationCanvasActive = _effectivePosition != null;
        _initialCameraPositioned = false;
        _loading = false;
      });
      _updateNavigationGuidance(_effectivePosition);
      widget.onRouteChanged?.call(route);
      unawaited(_publishGroupPipSnapshot());
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
      // A route loaded on a standing bike frames the whole route, not the rider,
      // so the way back has to be offered from the first frame (#133).
      _scheduleCameraFramingRefresh();
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
    _recordBottomChromeHeight();
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
    // Not route-gated (#124): a ride with no GPX gets the same riding canvas.
    final hideChrome = _navigationCanvasActive || markerOverviewActive;
    // Notches, rounded corners and the home indicator are respected in every
    // orientation, with or without the AppBar. Scaffold already removes the
    // padding it consumed itself, so what is left is what the overlays owe.
    final safeInsets = MediaQuery.paddingOf(context);
    final overlayLeft = safeInsets.left;
    final overlayRight = safeInsets.right;
    final overlayBottom = safeInsets.bottom;
    // Only the ride menu reaches the upper band (#125), and it still owes the
    // notch and the status bar their space.
    final overlayTop = safeInsets.top;
    final compactDensity = landscape ? VisualDensity.compact : null;
    // The group mini-map owns its own ValueListenableBuilder below. This
    // avoids relying on a parent platform-map rebuild to notice rider updates,
    // which left the portrait mini-map absent in the live simulator.
    final canShowGroupMiniMap =
        widget.overlayMarkers != null && !markerOverviewActive;
    final groupMiniMapWidth = landscape ? 196.0 : 150.0;
    final groupMiniMapHeight = landscape ? 116.0 : 104.0;
    final showRideMenu = hideChrome && widget.onOpenRideMenu != null;
    // A route can contain manoeuvres before the device has a usable location.
    // The guidance banner is only composed into the band while guidance is
    // actually visible, so nothing reserves space for a banner that is absent.
    final hasGuidance = _navigationGuidance.value != null;
    // Leaving a ride is a ride-lifecycle action, not a route action (#124).
    final showLeaveRide = widget.onLeaveRide != null;
    // "Follow me" is the way into the navigation viewport, and it is on screen
    // whenever the camera is not locked into it (#141). The junction overview owns
    // the whole screen while it is up, so nothing is offered underneath it.
    final showFollowMe = !markerOverviewActive && !_navigationViewportLocked;
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
                // Route-derived: importing is the action that creates a
                // route, so it is offered only while there is none.
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
                // Route-derived: there is nothing to hand to another
                // navigation app or write to a GPX without one.
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
                  // Route-derived: fitting the whole plan needs a plan. The
                  // rider's own framing is the follow camera's job.
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
                        // Route-derived wording only: the action itself is
                        // always offered.
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
                    PopupMenuItem(
                      value: _MapAction.speedLimitDisplay,
                      child: Row(
                        children: [
                          Icon(
                            _speedLimitDisplay.enabled
                                ? Icons.check_box
                                : Icons.check_box_outline_blank,
                          ),
                          const SizedBox(width: 10),
                          // A popup menu constrains its items, and this label
                          // was wide enough to be clipped without flexing.
                          const Expanded(
                            child: Text('Show mapped speed limit'),
                          ),
                        ],
                      ),
                    ),
                    // Route-derived: both read manoeuvres off the plan.
                    if (_route?.maneuvers.isNotEmpty ?? false) ...[
                      const PopupMenuItem(
                        value: _MapAction.maneuverList,
                        child: Text('All turns for this route'),
                      ),
                      PopupMenuItem(
                        value: _MapAction.markerPlan,
                        child: Text(
                          _markerPlanVisible
                              ? 'Hide marker plan'
                              : 'Show marker plan',
                        ),
                      ),
                    ],
                    if (!kIsWeb &&
                        defaultTargetPlatform == TargetPlatform.android)
                      const PopupMenuItem(
                        value: _MapAction.groupPip,
                        child: Text('Show mini-map over another app'),
                      ),
                    // Route-derived: the offline region is the route corridor,
                    // so there is no bounded area to download without one.
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
                    // Route-derived: nothing to remove without one.
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
                    key: _mapViewportKey,
                    behavior: HitTestBehavior.opaque,
                    onPointerDown: _onMapPointerDown,
                    onPointerMove: _onMapPointerMove,
                    onPointerUp: _onMapPointerUp,
                    onPointerCancel: _onMapPointerCancel,
                    onPointerSignal: (_) => _suppressFollowForMapGesture(),
                    child: _buildMap(),
                  ),
                ),
                Positioned.fill(
                  child: _buildRideChrome(
                    landscape: landscape,
                    hideChrome: hideChrome,
                    markerOverviewActive: markerOverviewActive,
                    hasGuidance: hasGuidance,
                    showRideMenu: showRideMenu,
                    showLeaveRide: showLeaveRide,
                    showFollowMe: showFollowMe,
                    canShowGroupMiniMap: canShowGroupMiniMap,
                    groupMiniMapWidth: groupMiniMapWidth,
                    groupMiniMapHeight: groupMiniMapHeight,
                    safeLeft: overlayLeft,
                    safeRight: overlayRight,
                    safeTop: overlayTop,
                    safeBottom: overlayBottom,
                  ),
                ),
                // Route entry, and only while the map is still a planning
                // surface. Once the riding canvas is up there is a rider on a
                // moving bike behind this card, and a ride with no GPX is a
                // first-class mode rather than a state to nag about (#124), so
                // it gives way. Route entry stays reachable from the ride
                // menu's "Change route" and from the app bar whenever this card
                // is showing.
                if (_route == null && !hideChrome)
                  Positioned.fill(
                    child: widget.canEditRoute
                        ? _EmptyRoutePrompt(
                            importing: _importing,
                            routing: _routing,
                            onPlanDestination: _planDestination,
                            onImport: _importGpx,
                            onUseStoredRoute: _useStoredRoute,
                            onLoadDemo: _loadDemoRoute,
                          )
                        : const _WaitingForLeaderRoutePrompt(),
                  ),
                // Last in the stack: an approaching camera or police report
                // takes the screen over everything else on it.
                if (widget.enforcementAlert != null)
                  Positioned.fill(
                    child: ValueListenableBuilder<EnforcementAlert?>(
                      valueListenable: widget.enforcementAlert!,
                      builder: (context, alert, _) {
                        if (alert == null ||
                            alert.hazard.id == _dismissedEnforcementAlertId) {
                          return const SizedBox.shrink();
                        }
                        return _EnforcementAlertOverlay(
                          alert: alert,
                          distanceUnit: widget.distanceUnit,
                          onDismiss: () => setState(
                            () =>
                                _dismissedEnforcementAlertId = alert.hazard.id,
                          ),
                        );
                      },
                    ),
                  ),
                // Above even that: a rider asking the group for help outranks a
                // speed camera. Critical only - "Need fuel" must not blank the
                // map at 60 mph (#151) - and transient, so it never becomes a
                // permanent surface anywhere, let alone in the upper band
                // (#104). The persistent row in the bottom band is what survives
                // it being closed.
                if (widget.quickMessageAlerts != null)
                  // Stops short of the action band rather than filling the
                  // screen. Opaque and full-bleed, it covered SOS and LEAVE and
                  // absorbed every tap, so a rider could neither leave nor call
                  // for help until they had cleared each interrupting message -
                  // one tap per message (#177).
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    bottom: _safetyBandReservedHeight(landscape),
                    child: ValueListenableBuilder<List<RideQuickMessageAlert>>(
                      valueListenable: widget.quickMessageAlerts!,
                      builder: (context, alerts, _) {
                        final alert = _interruptingQuickMessage(alerts);
                        if (alert == null) return const SizedBox.shrink();
                        return _QuickMessageInterruptOverlay(
                          alert: alert,
                          distanceUnit: widget.distanceUnit,
                          acknowledging:
                              _acknowledgingQuickMessageId ==
                              alert.message.eventId,
                          onAcknowledge:
                              widget.onAcknowledgeQuickMessage == null
                              ? null
                              : () => unawaited(
                                  _acknowledgeQuickMessage(alert.message),
                                ),
                          onDismiss: () => setState(
                            () => _dismissedQuickMessageInterrupts.add(
                              alert.message.eventId,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
    );
  }

  /// Every persistent map overlay, anchored clear of the road ahead.
  ///
  /// #104's rule is that the band a rider reads the road in must stay clear of
  /// persistent *status surfaces and popups*. What that leaves free is the
  /// corners, and the corners now carry three small things - the ride menu
  /// (#125), and, from #133, the group overview and, in landscape, the speed
  /// sign. Each is hard against a screen edge, none is wider than a fifth of the
  /// viewport, and the centre and upper-middle stay empty.
  ///
  /// Everything else is bottom-anchored: portrait into one band, landscape into a
  /// left rail (guidance, status, actions) and a right rail (recovery, group
  /// overview) so the centre column stays clear. Because each rail is a single
  /// [Column], the anchoring stays deterministic - the property #89 introduced -
  /// and no surface can cover another at any simultaneous overlay count.
  ///
  /// Order within a rail runs from least urgent at the top to the targets a
  /// gloved hand reaches for at the bottom, with the turn banner immediately
  /// above them: the rider's eye leaves the road for the banner and comes
  /// straight back, so every pixel above it is map (#133).
  Widget _buildRideChrome({
    required bool landscape,
    required bool hideChrome,
    required bool markerOverviewActive,
    required bool hasGuidance,
    required bool showRideMenu,
    required bool showLeaveRide,
    required bool showFollowMe,
    required bool canShowGroupMiniMap,
    required double groupMiniMapWidth,
    required double groupMiniMapHeight,
    required double safeLeft,
    required double safeRight,
    required double safeTop,
    required double safeBottom,
  }) {
    // Landscape rails stay narrow enough that a centred rider marker is never
    // behind one, which is what lets the camera keep its full forward bias.
    final railWidth = math.min(
      360.0,
      (MediaQuery.sizeOf(context).width - safeLeft - safeRight) * 0.42,
    );
    final compactStatus = landscape || hideChrome;

    Widget compose(
      LeaderRideStatus? leaderStatus,
      List<MapOverlayMarker> overlays,
      List<RideQuickMessageAlert> quickMessages,
    ) {
      final downloadProgress = _downloadProgress;
      // At most one quick-message row, ever (#151). A group can raise several at
      // once, and three stacked rows would undo the band #125 and #133 spent the
      // day emptying - so the most urgent one is on screen with a count of what
      // is behind it, and acknowledging it reveals the next. The band therefore
      // grows by one row at its worst, not by one row per rider.
      final quickMessage = _presentedQuickMessage(quickMessages);
      final urgent = <Widget>[
        // A paused ride is a ride-lifecycle state, not a route state (#124).
        if (widget.ridePaused) const _RidePausedBanner(),
        if (widget.rideHasNoLeader) const _NoLeaderBanner(),
        if (leaderStatus != null && leaderStatus.offCourseAlerts.isNotEmpty)
          _OffCourseBanner(
            alerts: leaderStatus.offCourseAlerts,
            compact: compactStatus,
            distanceUnit: widget.distanceUnit,
          ),
        // Last in the urgent run, so it is the urgent surface nearest the
        // rider's gaze and the targets their hand is already going to (#104's
        // ordering). It is also the one urgent surface carrying a target of its
        // own, and at the maximum overlay count in landscape - where #139
        // recorded the rail already overflowing the top of a 390 px screen -
        // being last means the paused banner and the off-course card give way
        // before the alert does.
        //
        // It stays until acknowledged, so a rider who glances away does not lose
        // it: the persistence the transient interrupt cannot provide.
        if (quickMessage != null)
          _QuickMessageAlertCard(
            alert: quickMessage,
            compact: compactStatus,
            distanceUnit: widget.distanceUnit,
            outstandingCount: _outstandingQuickMessageCount(quickMessages),
            acknowledging:
                _acknowledgingQuickMessageId == quickMessage.message.eventId,
            onAcknowledge: widget.onAcknowledgeQuickMessage == null
                ? null
                : () =>
                      unawaited(_acknowledgeQuickMessage(quickMessage.message)),
            onDismissReceipt: () => setState(
              () => _dismissedQuickMessageReceipts.add(
                quickMessage.message.eventId,
              ),
            ),
          ),
      ];
      final guidance = hasGuidance
          ? ValueListenableBuilder<NavigationGuidance?>(
              valueListenable: _navigationGuidance,
              builder: (context, guidance, _) => guidance == null
                  ? const SizedBox.shrink()
                  : _NavigationGuidanceBanner(
                      guidance: guidance,
                      distanceUnit: widget.distanceUnit,
                      compact: landscape,
                    ),
            )
          : null;
      // With nobody holding the TEC role there is nothing honest to show, so
      // the surface is hidden entirely and its space reclaimed rather than
      // presenting an empty or zero gap. A registered TEC keeps the surface
      // through its waiting, stale and tracking states.
      final tecGap = leaderStatus != null && leaderStatus.hasRegisteredTec
          ? _TecGapCard(
              status: leaderStatus,
              compact: compactStatus,
              distanceUnit: widget.distanceUnit,
              trend: widget.tecGapTrend?.value ?? TecGapTrend.unknown,
            )
          : null;
      final miniMap = canShowGroupMiniMap
          ? _buildGroupMiniMap(
              overlays: overlays,
              width: groupMiniMapWidth,
              height: groupMiniMapHeight,
            )
          : null;
      final junctionCard = markerOverviewActive
          ? ValueListenableBuilder<MapJunctionMarkerOverlay?>(
              key: const Key('junction-marker-overlay-position'),
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
            )
          : null;
      // The ride menu is the one control #125 puts back in the upper band, and
      // deliberately: a single small corner button is where a rider reaches for
      // it and does not obstruct the road ahead. #104's rule against persistent
      // *status* surfaces up there is untouched.
      final rideMenu = showRideMenu
          ? FloatingActionButton.small(
              key: const Key('ride-menu-button'),
              heroTag: 'ride-relay-menu',
              tooltip: 'Ride menu',
              onPressed: widget.onOpenRideMenu,
              backgroundColor: const Color(0xE6252E39),
              foregroundColor: Colors.white,
              child: const Icon(Icons.menu),
            )
          : null;
      // Landscape rails are narrow by design, and the maintainer's instruction
      // for #142 is that landscape holds the three targets in **two rows at
      // most**, making SOS and LEAVE smaller if that is what it takes. One row is
      // what actually fits, and it is also what keeps the rail short enough for an
      // urgent banner to stay out of the upper band on a 390 pixel screen: the
      // stacked portrait arrangement added 58 px of rail and pushed the TEC gap
      // into the band #104 reserves for the road ahead.
      //
      // So landscape tightens the label padding and the reserved label slots
      // rather than the targets. Every landscape target stays at least 48 px in
      // both dimensions, which is the smallest a gloved hand can be asked to hit.
      final actionPadding = landscape
          ? const EdgeInsets.symmetric(horizontal: 8)
          : null;
      // Fixed, so the row's width is the same in every state and in every font:
      // the label scales down inside its slot rather than widening it. Sized so
      // the three targets and their two gaps come to 270 px, inside the 280 px
      // rail of the narrower evaluation phone in landscape. The width comes out of
      // the two labels the maintainer offered - SOS and LEAVE - and never out of
      // REPORT, whose 62 px square is a deliberate glove size.
      final sosLabelSlot = landscape ? 62.0 : null;
      final leaveLabelSlot = landscape ? 34.0 : null;
      final actionTargetHeight = landscape ? 48.0 : null;
      // Safety and ride-lifecycle targets, all glove-sized: none of them is
      // derived from a planned route (#124), and REPORT belongs beside them
      // rather than on a row of its own (#125).
      //
      // Every one of them reserves the space its widest state needs up front
      // (#142): the label slot is sized for the longest string the control can
      // ever show and the icon slot is a fixed square, so sending an alert
      // changes what the control says without changing what it occupies. #139
      // let the label drive the width, and "ALERT SENT" widened SOS enough to
      // push REPORT out of the run.
      //
      // "ALERT SEEN" is #151's other half, and it costs no footprint: the point
      // of raising an alert is that somebody sees it, and the control the rider
      // already pressed is the cheapest place to tell them so. It is the state
      // #142 calls "alert acknowledged", and it shares the reserved slot.
      final emergencyAcknowledged =
          _emergencyAlertSent &&
          quickMessages.any(
            (alert) =>
                alert.message.raisedFromLocalRider &&
                alert.message.isAcknowledged &&
                alert.message.message == QuickMessage.emergencyStop,
          );
      final sosButton = widget.onEmergencyAlert == null
          ? null
          : FloatingActionButton.extended(
              key: const Key('emergency-alert-button'),
              extendedPadding: actionPadding,
              heroTag: 'ride-relay-emergency-alert',
              tooltip: 'Alert leader and TEC',
              onPressed: _emergencyAlertSending ? null : _triggerEmergencyAlert,
              backgroundColor: const Color(0xFFD9304F),
              foregroundColor: Colors.white,
              icon: _ActionIconSlot(
                child: _emergencyAlertSending
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : Icon(
                        emergencyAcknowledged
                            ? Icons.visibility
                            : _emergencyAlertSent
                            ? Icons.check_circle
                            : Icons.sos,
                      ),
              ),
              label: _ActionLabel(
                emergencyAcknowledged
                    ? 'ALERT SEEN'
                    : _emergencyAlertSent
                    ? 'ALERT SENT'
                    : 'ALERT',
                widest: 'ALERT SENT',
                slotWidth: sosLabelSlot,
              ),
            );
      final leaveButton = showLeaveRide
          ? FloatingActionButton.extended(
              key: const Key('leave-ride-button'),
              extendedPadding: actionPadding,
              heroTag: 'ride-relay-leave',
              tooltip: 'Stop sharing and leave this ride',
              onPressed: widget.onLeaveRide,
              backgroundColor: const Color(0xFF545F6E),
              foregroundColor: Colors.white,
              icon: const _ActionIconSlot(child: Icon(Icons.exit_to_app)),
              // Portrait matches SOS's slot so the stacked pair reads as one
              // column of equal targets. Landscape gives LEAVE only the width its
              // own word needs, because the row has to fit three across.
              label: _ActionLabel(
                'LEAVE',
                widest: landscape ? 'LEAVE' : 'ALERT SENT',
                slotWidth: leaveLabelSlot,
              ),
            )
          : null;
      // Reporting a camera or a patrol car is a ride action, not a route action,
      // and it earns a place beside them (#125).
      final reportButton = widget.onReportHazard == null
          ? null
          : _ReportSightingButton(onPressed: _reportEnforcementSighting);
      final hasActions =
          sosButton != null || leaveButton != null || reportButton != null;
      // One arrangement per orientation, fixed for every state (#142). #139 used
      // a `Wrap` in landscape, and a `Wrap` decides its runs from its children's
      // measured widths - so the moment SOS said "ALERT SENT" the rail could no
      // longer hold the row and REPORT reflowed onto a run of its own, at the
      // exact moment the rider had just raised an alert. Neither arrangement here
      // is a `Wrap`, so no label can change the shape of the cluster.
      //
      // Portrait stacks SOS over LEAVE with REPORT alongside (#133): the band has
      // the height, and two targets that no longer sit shoulder to shoulder means
      // a mis-hit next to SOS is no longer LEAVE. Landscape puts all three across
      // one row, which is the arrangement that fits a rail 280 px wide and keeps
      // the rail short enough to leave the upper band clear.
      final sosSubtree = sosButton == null || actionTargetHeight == null
          ? sosButton
          : SizedBox(height: actionTargetHeight, child: sosButton);
      final leaveSubtree = leaveButton == null || actionTargetHeight == null
          ? leaveButton
          : SizedBox(height: actionTargetHeight, child: leaveButton);
      final reportSubtree = reportButton;
      final safetyCluster = !hasActions
          ? null
          : landscape
          ? Row(
              key: const Key('map-action-cluster'),
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                ?sosSubtree,
                if (sosSubtree != null && leaveSubtree != null)
                  const SizedBox(width: 8),
                ?leaveSubtree,
                if (reportSubtree != null) ...[
                  const SizedBox(width: 8),
                  reportSubtree,
                ],
              ],
            )
          : Row(
              key: const Key('map-action-cluster'),
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (sosSubtree != null || leaveSubtree != null)
                  Column(
                    key: const Key('map-portrait-safety-stack'),
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ?sosSubtree,
                      if (sosSubtree != null && leaveSubtree != null)
                        const SizedBox(height: 8),
                      ?leaveSubtree,
                    ],
                  ),
                if (reportSubtree != null) ...[
                  const SizedBox(width: 10),
                  reportSubtree,
                ],
              ],
            );
      // The speed sign owns its own slot at the edge of the band, clear of the
      // action row: portrait puts it under the actions and hard right, landscape
      // in the right-hand rail away from the centre column (#125).
      final speedLimit = markerOverviewActive
          ? null
          : KeyedSubtree(
              key: const Key('posted-speed-limit-position'),
              child: AnimatedBuilder(
                animation: _speedLimitDisplay,
                builder: (context, _) => _speedLimitDisplay.enabled
                    ? ValueListenableBuilder<double?>(
                        valueListenable: _riderSpeedMetersPerSecond,
                        builder: (context, riderSpeed, _) =>
                            _PostedSpeedLimitBadge(
                              status: _speedLimitDisplay.status,
                              outcome: _speedLimitDisplay.lastOutcome,
                              limit: _speedLimitDisplay.limit,
                              riderSpeedMetersPerSecond: riderSpeed,
                            ),
                      )
                    : _SpeedLimitOptInChip(
                        onPressed: _confirmEnableSpeedLimitDisplay,
                      ),
              ),
            );
      final followMe = showFollowMe
          ? FloatingActionButton.extended(
              key: const Key('navigation-follow-button'),
              // Its own tag, like every other action here. Sharing the default
              // with them put two heroes of the same tag on screen whenever this
              // control was up, which is most of a ride now that it is the way
              // into the navigation viewport (#141).
              heroTag: 'ride-relay-follow-me',
              tooltip: 'Follow my location',
              onPressed: _toggleNavigationMode,
              backgroundColor: const Color(0xE6252E39),
              foregroundColor: Colors.white,
              icon: const Icon(Icons.navigation_outlined),
              label: const Text('Follow me'),
            )
          : null;

      if (landscape) {
        return Stack(
          children: [
            if (rideMenu != null)
              Positioned(
                left: safeLeft + 10,
                top: safeTop + 10,
                child: rideMenu,
              ),
            // The speed sign is the third corner element (#133). It is the one
            // surface a rider glances at repeatedly without acting on it, so it
            // belongs where the eye already is rather than at the bottom of a
            // rail beside the targets - and hard against the trailing edge, well
            // clear of the centre column.
            if (speedLimit != null)
              Positioned(
                right: safeRight + 10,
                top: safeTop + 10,
                child: speedLimit,
              ),
            Positioned(
              left: safeLeft + 10,
              bottom: safeBottom + 10,
              width: railWidth,
              child: _chromeRail(
                key: const Key('map-landscape-left-rail'),
                alignment: CrossAxisAlignment.start,
                children: [
                  if (downloadProgress != null)
                    Card(
                      child: _DownloadProgress(
                        progress: downloadProgress,
                        onCancel: _downloadCancellation?.cancel,
                      ),
                    ),
                  if (!_basemap.isConfigured) const _RouteOnlyBadge(),
                  ...urgent,
                  ?tecGap,
                  // Last before the targets: see [_buildRideChrome] (#133).
                  ?guidance,
                  ?safetyCluster,
                ],
              ),
            ),
            Positioned(
              right: safeRight + 10,
              bottom: safeBottom + 10,
              width: railWidth,
              child: _chromeRail(
                key: const Key('map-landscape-right-rail'),
                alignment: CrossAxisAlignment.end,
                // The group overview sits at the very bottom right (#133): it is
                // a glance, not a target, and the corner furthest from the road
                // ahead is the cheapest place on the screen to put one.
                children: [?followMe, ?junctionCard, ?miniMap],
              ),
            ),
          ],
        );
      }

      // SOS above LEAVE rather than beside it (#133), with REPORT alongside the
      // pair and the speed sign opposite. Stacking them costs no height: the
      // two-high column and the 62 pixel REPORT square both fit inside the height
      // the speed sign already needed, so a row that used to be an action run
      // *plus* a sign run is now one run of the taller of the two. The rider gets
      // targets that no longer sit shoulder to shoulder - a mis-hit next to SOS
      // used to be LEAVE - and the band gets shorter.
      //
      // The same cluster landscape uses, so the arrangement is a function of
      // orientation and nothing else (#142). The `Spacer` between it and the
      // speed sign absorbs the sign's own width, so the targets keep their place
      // whatever the sign says.
      final actionCluster = !hasActions && speedLimit == null
          ? null
          : Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                ?safetyCluster,
                const Spacer(),
                // Hard right, out of the way of the thumb reaching the stack.
                ?speedLimit,
              ],
            );
      return Stack(
        children: [
          if (rideMenu != null)
            Positioned(left: safeLeft + 12, top: safeTop + 12, child: rideMenu),
          // The group overview is the second corner element (#133), opposite the
          // ride menu. It is a glance rather than a target, so the top trailing
          // corner costs the rider nothing - and out of the bottom band it stops
          // charging the camera's forward bias for a surface nobody acts on.
          if (miniMap != null)
            Positioned(
              right: safeRight + 12,
              top: safeTop + 12,
              child: miniMap,
            ),
          Positioned(
            left: safeLeft + 12,
            right: safeRight + 12,
            bottom: safeBottom + 12,
            // The band the camera measures is also the band a test measures: the
            // GlobalKey below is per-instance and cannot be reached from a test,
            // so the same subtree carries a stable public key for #105's
            // `bottomChromeFraction` to be asserted rather than estimated.
            child: KeyedSubtree(
              key: portraitBottomChromeKey,
              child: _chromeRail(
                key: _bottomChromeKey,
                alignment: CrossAxisAlignment.stretch,
                children: [
                  if (downloadProgress != null)
                    Card(
                      child: _DownloadProgress(
                        progress: downloadProgress,
                        onCancel: _downloadCancellation?.cancel,
                      ),
                    ),
                  // In the rail, not free-floating on the map: anchoring this
                  // independently at the same corner put it underneath the map
                  // controls.
                  if (!_basemap.isConfigured)
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: _RouteOnlyBadge(),
                    ),
                  ...urgent,
                  ?tecGap,
                  // The turn banner is the last thing above the targets, so
                  // everything above it is map (#133). It used to have the TEC
                  // gap and the group overview between it and them.
                  ?guidance,
                  // Rare, and its own run: it appears only when the map is off
                  // the rider, and the alternative was shrinking a target to fit
                  // it beside three others.
                  if (followMe != null)
                    Align(alignment: Alignment.centerLeft, child: followMe),
                  ?actionCluster,
                  ?junctionCard,
                ],
              ),
            ),
          ),
        ],
      );
    }

    Widget withQuickMessages(
      LeaderRideStatus? leaderStatus,
      List<MapOverlayMarker> overlays,
    ) => widget.quickMessageAlerts == null
        ? compose(leaderStatus, overlays, const [])
        : ValueListenableBuilder<List<RideQuickMessageAlert>>(
            valueListenable: widget.quickMessageAlerts!,
            builder: (context, quickMessages, _) =>
                compose(leaderStatus, overlays, quickMessages),
          );

    Widget withOverlays(LeaderRideStatus? leaderStatus) =>
        widget.overlayMarkers == null
        ? withQuickMessages(leaderStatus, const [])
        : ValueListenableBuilder<List<MapOverlayMarker>>(
            valueListenable: widget.overlayMarkers!,
            builder: (context, overlays, _) =>
                withQuickMessages(leaderStatus, overlays),
          );

    // The leader status and rider overlays only reach the tree through their
    // own listenables: rebuilding the parent platform map on every rider update
    // resizes the native view and was a source of visible flashing.
    return widget.leaderStatus == null
        ? withOverlays(null)
        : ValueListenableBuilder<LeaderRideStatus?>(
            valueListenable: widget.leaderStatus!,
            builder: (context, status, _) => withOverlays(status),
          );
  }

  /// One bottom-anchored rail. Gaps only ever appear between surfaces that are
  /// actually present, so a hidden surface reclaims its space.
  static Widget _chromeRail({
    required Key key,
    required CrossAxisAlignment alignment,
    required List<Widget> children,
  }) => Column(
    key: key,
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: alignment,
    children: [
      for (var index = 0; index < children.length; index += 1) ...[
        if (index > 0) const SizedBox(height: 8),
        children[index],
      ],
    ],
  );

  Widget _buildGroupMiniMap({
    required List<MapOverlayMarker> overlays,
    required double width,
    required double height,
  }) {
    final groupRiders = overlays
        .where((marker) => marker.id.startsWith('rider-'))
        .toList(growable: false);
    final inferredGroupSize =
        groupRiders.length + (_effectivePosition == null ? 0 : 1);
    // The participant count is a snapshot supplied by the ride shell, while
    // rider overlays are live. Taking only the snapshot left the iOS mini-map
    // hidden when it still said "1" after remote positions arrived.
    final groupSize = math.max(widget.groupRiderCount ?? 0, inferredGroupSize);
    if (groupSize <= 1) return const SizedBox.shrink();
    return _GroupMiniMap(
      width: width,
      height: height,
      routePaths:
          _route?.paths
              .map((path) => path.points)
              .where((points) => points.length >= 2)
              .toList(growable: false) ??
          const [],
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
  }

  Widget _buildMap() {
    if (_basemap.usesMapLibre) return _buildMapLibreMap();

    final route = _route;
    final points = route?.allPoints.map(_latLng).toList(growable: false) ?? [];
    // With no route the rider's own position is the framing (#124); the UK-wide
    // overview is only for a map that has neither.
    final rider = _effectivePosition;
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
            initialCenter:
                points.firstOrNull ??
                (rider == null ? const LatLng(54.5, -3.2) : _latLng(rider)),
            initialZoom: points.isEmpty && rider == null ? 5 : 14,
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
                    // Opaque, to match the MapLibre casing (#133).
                    borderColor: RouteTrailStyle.casing,
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
        // Travelled trails are drawn whether or not a route is loaded, and the
        // leader's trail sits under the planned route so both stay readable
        // where they coincide.
        if (route != null || _visibleRiderTrails.isNotEmpty)
          PolylineLayer(
            polylines: [
              ..._trailPolylines(dashed: false),
              ..._progressGeometry.remainingPaths.map(
                (path) => _routePolyline(path, RouteTrailStyle.routeAhead),
              ),
              ..._progressGeometry.riddenPaths.map(
                (path) => _routePolyline(path, RouteTrailStyle.travelled),
              ),
              ..._trailPolylines(dashed: true),
            ],
          ),
        if (route != null || _visibleRiderTrails.isNotEmpty)
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
        if (_markerPlanVisible && _markerPlan.points.isNotEmpty)
          MarkerLayer(
            key: const Key('ride-marker-plan-layer'),
            markers: _markerPlan.points
                .take(500)
                .map(
                  (point) => Marker(
                    point: _latLng(point.position),
                    width: 38,
                    height: 38,
                    child: Tooltip(
                      message: point.label,
                      child: Icon(
                        switch (point.kind) {
                          MarkerPlanPointKind.likelyMarker =>
                            Icons.person_pin_circle_outlined,
                          MarkerPlanPointKind.safetyReview =>
                            Icons.warning_amber_rounded,
                          MarkerPlanPointKind.musterPoint =>
                            Icons.groups_2_outlined,
                        },
                        color: switch (point.kind) {
                          MarkerPlanPointKind.likelyMarker => const Color(
                            0xFF6ED89A,
                          ),
                          MarkerPlanPointKind.safetyReview => const Color(
                            0xFFFF8A4C,
                          ),
                          MarkerPlanPointKind.musterPoint => const Color(
                            0xFF68A9FF,
                          ),
                        },
                        size: 32,
                        shadows: const [
                          Shadow(color: Color(0xFF10151C), blurRadius: 4),
                        ],
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
                  // The marker follows the bike, not the plan (#124).
                  navigationMode: _isMoving,
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
      ],
    );
  }

  Widget _buildMapLibreMap() {
    final planned = _route?.allPoints.toList(growable: false) ?? const [];
    // As above: no route still frames the rider rather than the whole country.
    final routePoints = planned.isNotEmpty ? planned : [?_effectivePosition];
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
            // Without this the platform never reports its camera, and
            // `MapLibreMapController.cameraPosition` keeps the value it was
            // constructed with for the whole ride: iOS returns early from
            // `mapViewRegionIsChanging` on `if !trackCameraPosition`, sends
            // `camera#onIdle` with an empty payload, and answers `getCamera`
            // with nil; Android gates all three the same way. That is what beat
            // both previous attempts at "Follow me" (#141). Read off an SE on
            // 26 July 2026: through 79 pan events and both orientations the map
            // reported exactly one camera, `51.467612,-2.506995 z=11.000`, so
            // the framing was measured against where the map *opened* and the
            // tolerance was derived from the opening zoom - 1333 m of ground at
            // z=11. `framed` could not become false, and the button could not
            // appear. The listener and the pan gestures were both arriving; only
            // the camera value was frozen.
            trackCameraPosition: true,
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
    final previous = _mapLibreController;
    previous?.onFeatureTapped.remove(_onMapLibreFeatureTapped);
    previous?.removeListener(_scheduleCameraFramingRefresh);
    _mapLibreController = controller;
    controller.onFeatureTapped.add(_onMapLibreFeatureTapped);
    // The controller notifies on every camera move, which is how the map's own
    // camera reaches the arrival test (#141). It only ever *reports* that camera
    // when `trackCameraPosition` is set - see [_buildMapLibreMap]. The
    // measurement is deferred and only rebuilds when its answer changes, so the
    // platform view is not resized mid-gesture.
    controller.addListener(_scheduleCameraFramingRefresh);
  }

  MapNavigationPosition? get _navigationFix => widget.navigationPosition?.value;

  GeoPoint? get _effectivePosition =>
      _navigationFix?.point ?? widget.currentPosition?.value;

  bool get _isMoving => _navigationFix?.isMoving ?? false;

  /// Speed used to decide whether the reported course can be trusted. A fix
  /// without a speed still counts as moving when the position source says so;
  /// otherwise a device that reports heading but no speed would never rotate.
  double get _bearingSpeedMetersPerSecond {
    final speed =
        _smoothedNavigationSpeedMetersPerSecond ??
        _navigationFix?.speedMetersPerSecond;
    if (speed != null && speed.isFinite) return speed;
    return _isMoving ? _headingSmoother.freezeBelowMetersPerSecond : 0;
  }

  /// The rotation deadband tightens inside this distance so the map bearing
  /// cannot lag at the junction the rider is being told about.
  static const _maneuverDeadbandTightenMeters = 150.0;

  bool get _maneuverImminent {
    final guidance = _navigationGuidance.value;
    return guidance != null &&
        guidance.distanceMeters <= _maneuverDeadbandTightenMeters;
  }

  /// Height of the map viewport as laid out, falling back to the screen height
  /// before the first frame.
  double get _mapViewportHeightPixels {
    final height = _mapViewportKey.currentContext?.size?.height;
    return height != null && height > 0
        ? height
        : MediaQuery.sizeOf(context).height;
  }

  /// How much of the bottom of the screen an interrupting alert must leave
  /// alone, so SOS and LEAVE stay visible and hittable behind it (#177).
  ///
  /// Portrait reserves the measured bottom band - the same band the navigation
  /// camera biases against - so there is one measurement rather than a constant
  /// that drifts from the layout. Landscape lays the actions out differently, so
  /// a floor clears them.
  double _safetyBandReservedHeight(bool landscape) {
    if (landscape) return _landscapeSafetyBandFloor;
    final measured = _measuredBottomChromeHeight;
    return measured > 0 ? measured : _portraitSafetyBandFallback;
  }

  /// Two stacked extended FABs plus their gap and the margin below - what
  /// portrait lays out when SOS sits above LEAVE. Only used before the first
  /// frame has been measured, where covering the controls would be worse than
  /// reserving slightly too much.
  static const _portraitSafetyBandFallback = 132.0;

  /// One row of extended FABs plus its margin.
  static const _landscapeSafetyBandFloor = 72.0;

  /// The bottom band's height as last laid out.
  ///
  /// Recorded after a frame rather than read during one: a render object's size
  /// is not available while building. The band is on screen continuously, so by
  /// the time an alert interrupts this is already the real measurement.
  double _measuredBottomChromeHeight = 0;

  void _recordBottomChromeHeight() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final measured = _bottomChromeHeightPixels;
      if (measured == _measuredBottomChromeHeight) return;
      setState(() => _measuredBottomChromeHeight = measured);
    });
  }

  /// Height of the portrait bottom chrome band as laid out, including the
  /// margin below it. Zero in landscape, where the band is replaced by side
  /// rails a centred marker never reaches.
  double get _bottomChromeHeightPixels {
    final height = _bottomChromeKey.currentContext?.size?.height;
    return height == null ? 0 : height + 12;
  }

  /// The camera framing following the rider would produce right now.
  ///
  /// Shared by [_followNavigationCamera], which drives the map to it, and by
  /// [_measureMapFramedOnRider], which measures the map against it, so the
  /// framing the camera aims for and the framing the map is judged by cannot
  /// drift apart.
  ({GeoPoint target, NavigationCameraPlan plan}) _followCameraFraming(
    GeoPoint position,
  ) {
    final landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final viewportHeight = _mapViewportHeightPixels;
    final plan = NavigationCameraPlanner.plan(
      speedMetersPerSecond:
          _smoothedNavigationSpeedMetersPerSecond ??
          _navigationFix?.speedMetersPerSecond,
      landscape: landscape,
      viewportHeightPixels: viewportHeight,
      latitudeDegrees: position.latitude,
      bottomChromeFraction: landscape || viewportHeight <= 0
          ? 0
          : _bottomChromeHeightPixels / viewportHeight,
    );
    // MapLibre is tilted, so the bias is the perspective look-ahead the plan
    // solved. FlutterMap is flat, so it is a straight ground offset at that
    // renderer's own scale.
    final lookAhead = _basemap.usesMapLibre
        ? plan.lookAheadMeters
        : NavigationCameraPlanner.flatLookAheadMetersFor(
            zoom: plan.zoom,
            forwardBiasPixels: plan.forwardBiasPixels,
            latitudeDegrees: position.latitude,
          );
    return (
      target: lookAhead == 0
          ? position
          : _pointAhead(position, _cameraBearingDegrees, lookAhead),
      plan: plan,
    );
  }

  /// Whether the camera **is** the navigation viewport right now: follow mode
  /// owns it, and the map has reported arriving at the framing follow commanded.
  ///
  /// This is the condition "Follow me" answers, and it is deliberately not "is
  /// the rider roughly in frame". The maintainer's contract (#141) is that the
  /// control is there whenever the camera has moved away from the navigation
  /// viewport *at all*, that tapping it goes to that viewport - following the
  /// rider icon, heading up, road ahead - and that it hides only once the camera
  /// is genuinely locked into it.
  ///
  /// Three attempts got here:
  ///
  /// - #125 asked whether a pan had interrupted an *active* follow. Follow mode
  ///   needs movement, so a phone on a desk was never following, a pan suppressed
  ///   nothing, and the button never appeared.
  /// - #133 asked whether the rider was roughly in frame, against a freshly
  ///   planned framing with a 56 px tolerance. Two things beat it on a phone, both
  ///   measured on an SE on 26 July 2026: the MapLibre camera was frozen (see
  ///   `trackCameraPosition` in [_buildMapLibreMap]), and once unfrozen that
  ///   tolerance was 1363 m of ground at the zoom the map sat at, so a map panned
  ///   468 m off the rider still reported itself framed.
  /// - This one asks whether follow mode owns the camera and has arrived. Losing
  ///   the viewport is not a distance judgement at all: a pan hands the camera
  ///   over ([_stopFollowing]), and the control returns on the first 8 px of
  ///   movement. Distance is only used to decide whether a camera follow mode is
  ///   still easing has got there yet.
  bool get _navigationViewportLocked {
    if (_effectivePosition == null) return false;
    if (!_navigationMode) return false;
    return _cameraArrivedAtCommandedViewport;
  }

  /// The framing [_followNavigationCamera] last drove the camera to.
  ///
  /// Compared against what the map reports, this answers "did the camera get
  /// where we sent it". Comparing against a freshly *planned* framing instead is
  /// what let a camera the app had never driven pass the test (#141).
  ({GeoPoint target, double zoom})? _commandedViewport;

  /// Sticky once the camera has arrived: while follow mode still owns the camera,
  /// the only things that can take the viewport away are a gesture and another
  /// surface claiming the camera, and both clear [_navigationMode]. Re-testing
  /// the distance every frame would flicker the control on and off as the camera
  /// chases a moving rider between commands.
  bool _cameraArrivedAtCommandedViewport = false;

  /// Forgets both the commanded viewport and the arrival, so nothing can report a
  /// lock the camera no longer has. Called from every site that takes the camera
  /// away from follow mode.
  void _releaseNavigationViewport() {
    _commandedViewport = null;
    _cameraArrivedAtCommandedViewport = false;
  }

  bool _measureCameraArrival() {
    final rider = _effectivePosition;
    if (rider == null) return false;
    if (!_navigationMode) return false;
    // Already locked, and follow mode still owns the camera.
    if (_cameraArrivedAtCommandedViewport) return true;
    final commanded = _commandedViewport;
    // Follow mode has not driven the camera anywhere yet, so there is no
    // viewport to be locked into.
    if (commanded == null) return false;
    if (_basemap.usesMapLibre) {
      final camera = _mapLibreController?.cameraPosition;
      // A camera the platform has not reported is not an arrival. #133 read the
      // unknown case as "framed" and hid the control on the strength of it.
      if (camera == null) return false;
      return NavigationCameraPlanner.settledOnViewport(
        driftMeters: _mapDistanceMeters(
          GeoPoint(
            latitude: camera.target.latitude,
            longitude: camera.target.longitude,
          ),
          commanded.target,
        ),
        zoomDelta: camera.zoom - commanded.zoom,
        zoom: camera.zoom,
        latitudeDegrees: rider.latitude,
        tileSize: 512,
      );
    }
    try {
      final camera = _mapController.camera;
      return NavigationCameraPlanner.settledOnViewport(
        driftMeters: _mapDistanceMeters(
          GeoPoint(
            latitude: camera.center.latitude,
            longitude: camera.center.longitude,
          ),
          commanded.target,
        ),
        zoomDelta: camera.zoom - commanded.zoom,
        zoom: camera.zoom,
        latitudeDegrees: rider.latitude,
        tileSize: 256,
      );
    } on Object {
      // FlutterMap throws until it has been laid out once, and an unattached map
      // has not arrived anywhere.
      return false;
    }
  }

  /// Re-tests the arrival after the frame currently being built.
  ///
  /// Always deferred: the measurement reads laid-out sizes, and camera events
  /// can arrive from inside a build or layout pass, where `BuildContext.size`
  /// throws.
  void _scheduleCameraFramingRefresh() {
    if (_cameraFramingRefreshScheduled) return;
    _cameraFramingRefreshScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _cameraFramingRefreshScheduled = false;
      if (!mounted) return;
      final arrived = _measureCameraArrival();
      if (arrived == _cameraArrivedAtCommandedViewport) return;
      setState(() => _cameraArrivedAtCommandedViewport = arrived);
    });
  }

  void _onPositionChanged() {
    if (!mounted) return;
    final position = _effectivePosition;
    final navigationFix = _navigationFix;
    _observeSpeedLimit(navigationFix);
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
    double? observedHeading;
    if (suppliedHeading != null && suppliedHeading.isFinite) {
      observedHeading = suppliedHeading;
    } else if (position != null &&
        _previousNavigationPoint != null &&
        _pointsDiffer(position, _previousNavigationPoint!)) {
      observedHeading = _bearingDegrees(_previousNavigationPoint!, position);
    }
    if (observedHeading != null) _lastHeadingDegrees = observedHeading;
    _previousNavigationPoint = position;
    if (navigationFix?.speedMetersPerSecond case final speed?
        when speed.isFinite) {
      final boundedSpeed = speed.clamp(0.0, 50.0);
      final previousSpeed = _smoothedNavigationSpeedMetersPerSecond;
      _smoothedNavigationSpeedMetersPerSecond = previousSpeed == null
          ? boundedSpeed
          : previousSpeed * 0.72 + boundedSpeed * 0.28;
      _riderSpeedMetersPerSecond.value =
          _smoothedNavigationSpeedMetersPerSecond;
    } else if (navigationFix != null) {
      // A fix without a usable speed must not leave a stale number on screen.
      _riderSpeedMetersPerSecond.value = null;
    }
    // The camera follows a smoothed bearing, never the raw per-fix course. The
    // marker keeps the raw heading: it is only drawn rotated while the map is
    // north-up, where an honest arrow matters more than a stable one.
    final smoothedBearing = _headingSmoother.update(
      headingDegrees: observedHeading,
      speedMetersPerSecond: _bearingSpeedMetersPerSecond,
      at: navigationFix?.recordedAt ?? DateTime.now(),
      maneuverImminent: _maneuverImminent,
    );
    if (smoothedBearing != null) _cameraBearingDegrees = smoothedBearing;

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
    // Both are driven by the bike, not by whether a route was imported (#124).
    final autoFollow = _isMoving && !_autoFollowSuppressed;
    final enableNavigationMode = autoFollow && !_navigationMode;
    final activateNavigationCanvas =
        position != null && !_navigationCanvasActive;
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
    // A rider standing still with the map panned away gets no camera events at
    // all, so the fix that arrives while they stand there is the one chance to
    // notice the framing was lost (#133).
    _scheduleCameraFramingRefresh();
    if (offerEmergencyActions) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_showEmergencyActions());
      });
    }
    unawaited(_publishGroupPipSnapshot());
  }

  /// Feeds the speed-limit controller, which resolves the road from one fix.
  ///
  /// Deliberately the navigation fix rather than the bare current position: the
  /// confidence test that replaced the wait-for-movement delay is built on
  /// reported accuracy and heading, and a position without them cannot be tested
  /// for confidence at all (#126).
  void _observeSpeedLimit(MapNavigationPosition? fix) {
    if (fix == null) return;
    _speedLimitDisplay.observe(
      SpeedLimitLocation(
        point: fix.point,
        recordedAt: fix.recordedAt,
        accuracyMeters: fix.accuracyMeters,
        headingDegrees: fix.headingDegrees,
      ),
    );
  }

  void _updateNavigationGuidance(GeoPoint? position) {
    final next = _navigationGuidancePlanner.plan(
      route: _route,
      position: position,
      progressMeters: _progressGeometry.progressMeters,
    );
    final current = _navigationGuidance.value;
    final visibilityChanged = (current == null) != (next == null);
    final unchanged =
        current?.maneuver == next?.maneuver &&
        current != null &&
        next != null &&
        (current.distanceMeters - next.distanceMeters).abs() < 5;
    if (!unchanged) {
      _navigationGuidance.value = next;
      widget.onNavigationGuidanceChanged?.call(next);
      if (visibilityChanged && mounted) setState(() {});
    }
  }

  void _onOverlayDataChanged() {
    if (!mounted) return;
    // The mini-map listens to rider updates itself. Rebuilding the parent
    // platform map here can resize it and briefly bring the top chrome back.
    if (!_basemap.usesMapLibre) setState(() {});
    _scheduleMapLibreSync(overlays: true);
    unawaited(_publishGroupPipSnapshot());
  }

  void _onGroupPipDataChanged() {
    unawaited(_publishGroupPipSnapshot());
  }

  void _onJunctionMarkerChanged() {
    if (!mounted) return;
    final visible = widget.junctionMarkerOverlay?.value?.isLocalMarker ?? false;
    if (visible == _markerOverviewVisible) return;
    setState(() {
      _markerOverviewVisible = visible;
      if (visible) {
        // The junction overview owns the camera while it is up, and takes the
        // whole screen with it: nothing is offered underneath it (#125).
        _navigationMode = false;
        _autoFollowSuppressed = false;
        _releaseNavigationViewport();
      } else if (_effectivePosition != null) {
        // Resuming needs a position, not a route (#124).
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
    unawaited(_publishGroupPipSnapshot());
  }

  void _onFlutterMapEvent(MapEvent event) {
    if (event.source == MapEventSource.nonRotatedSizeChange) return;
    if (_navigationMode &&
        event.source != MapEventSource.mapController &&
        (event.source == MapEventSource.dragStart ||
            event.source == MapEventSource.multiFingerGestureStart ||
            event.source == MapEventSource.doubleTap ||
            event.source == MapEventSource.scrollWheel)) {
      _stopFollowing(suppressAutomatic: _isMoving);
    }
    // Every camera change, including the ones this app asked for: the framing is
    // measured, so the button appears and disappears from where the map actually
    // is rather than from which gesture moved it (#133).
    _scheduleCameraFramingRefresh();
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
        _showMessage(
          'Could not get your position. Check Location Services and '
          'Tail End Charlie location access.',
        );
        return;
      }
    }
    setState(() {
      _navigationMode = true;
      _navigationCanvasActive = true;
      _autoFollowSuppressed = false;
      // Taking the camera is not arriving at the viewport. The control stays on
      // screen until the map reports it got there (#141), because a rider
      // watching the map ease across has not been given the viewport yet.
      _releaseNavigationViewport();
    });
    // Going to the navigation viewport is a change of framing, not a tracking
    // update, so it is eased rather than run at the linear rate the per-fix
    // updates use.
    unawaited(
      _followNavigationCamera(
        force: true,
        transitionDuration: const Duration(milliseconds: 700),
      ),
    );
  }

  /// Hands the camera back to the rider.
  ///
  /// Every caller is a deliberate act - a pan, a pinch, a scroll, or fitting the
  /// whole route. Giving the camera up is what puts "Follow me" back on screen
  /// (#141): the control returns on the first 8 px of a pan, with no distance
  /// judgement that could swallow it.
  void _stopFollowing({required bool suppressAutomatic}) {
    if (!mounted) return;
    setState(() {
      _navigationMode = false;
      _autoFollowSuppressed = suppressAutomatic;
      _releaseNavigationViewport();
    });
    // FlutterMap does not cancel a controller-driven animation when a gesture
    // starts, and each tick of that animation sets the camera outright - so a pan
    // begun during a follow transition was silently dragged back onto the rider.
    // Handing the camera over means letting go of it.
    if (!_basemap.usesMapLibre) {
      try {
        _mapController.stopAnimationRaw();
      } on Object {
        // Nothing is attached yet, so nothing is animating.
      }
    }
    _scheduleCameraFramingRefresh();
  }

  /// The one quick message on screen, or null.
  ///
  /// Another rider's outstanding message always wins over this rider's own
  /// receipt: somebody waiting for help outranks being told that somebody saw
  /// you. The list arrives most-urgent-first, so this is a scan for the first
  /// row that is still worth showing rather than a re-sort.
  RideQuickMessageAlert? _presentedQuickMessage(
    List<RideQuickMessageAlert> alerts,
  ) {
    for (final alert in alerts) {
      if (!alert.message.raisedFromLocalRider) return alert;
    }
    for (final alert in alerts) {
      if (alert.message.isAcknowledged &&
          !_dismissedQuickMessageReceipts.contains(alert.message.eventId)) {
        return alert;
      }
    }
    return null;
  }

  /// How many other riders' messages are still waiting, so the row can say what
  /// is behind it rather than hiding it.
  int _outstandingQuickMessageCount(List<RideQuickMessageAlert> alerts) =>
      alerts.where((alert) => !alert.message.raisedFromLocalRider).length;

  /// The quick message that may take the screen over right now, if any.
  ///
  /// Critical only, never this rider's own, and never one whose interrupt has
  /// already been closed. Closing it loses nothing: the persistent row in the
  /// band stays until the message is acknowledged.
  RideQuickMessageAlert? _interruptingQuickMessage(
    List<RideQuickMessageAlert> alerts,
  ) {
    for (final alert in alerts) {
      if (alert.message.interrupts &&
          !alert.message.raisedFromLocalRider &&
          !_dismissedQuickMessageInterrupts.contains(alert.message.eventId)) {
        return alert;
      }
    }
    return null;
  }

  Future<void> _acknowledgeQuickMessage(ReceivedQuickMessage message) async {
    final acknowledge = widget.onAcknowledgeQuickMessage;
    if (acknowledge == null || _acknowledgingQuickMessageId != null) return;
    setState(() => _acknowledgingQuickMessageId = message.eventId);
    try {
      await acknowledge(message);
      if (!mounted) return;
      setState(() {
        _acknowledgingQuickMessageId = null;
        _dismissedQuickMessageInterrupts.add(message.eventId);
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _acknowledgingQuickMessageId = null);
      _showMessage('Could not acknowledge ${message.label}: $error');
    }
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

  /// Opens the phone's messaging app with a body ready, and **no recipient**.
  ///
  /// Deliberately no recipient: a ride invite carries a code, never a phone
  /// number, so the app has none for the leader, the TEC or anyone else. They
  /// have already been told in-app by the alert that opened this sheet; this is
  /// the rider's route to somebody outside the ride, and they choose who.
  ///
  /// It read as broken because nothing said so at the point of use. On iOS an
  /// empty To: field looks like a bug, and on Android an empty `sms:` is offered
  /// to every messaging app, so picking WhatsApp produced "that phone number is
  /// not registered with WhatsApp" (#173). The control now says what it does,
  /// and the body carries where the rider is, which is the thing worth sending.
  Future<void> _openEmergencyMessages() async {
    final opened = await launchUrl(
      Uri(
        scheme: 'sms',
        queryParameters: {'body': emergencyMessageBody(_effectivePosition)},
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
    // The rider is anchored low in the frame so most of the screen is road
    // ahead. The anchor is a documented fraction of the measured viewport
    // height, pulled back far enough to keep the marker clear of the bottom
    // chrome band, so a look-ahead can never push the rider's own marker off
    // screen or under an overlay the way a fixed distance up the route once
    // did. The same framing is what "Follow me" is measured against (#133).
    final framing = _followCameraFraming(position);
    final cameraPlan = framing.plan;
    final cameraDuration = transitionDuration ?? _cameraTransitionDuration;
    // Recorded before the camera is driven, so the arrival test compares the map
    // against what this app actually asked for rather than against a framing
    // planned afresh from whatever the state happens to be (#141).
    _commandedViewport = (target: framing.target, zoom: cameraPlan.zoom);
    try {
      if (_basemap.usesMapLibre) {
        final controller = _mapLibreController;
        if (controller == null) return;
        // maplibre_gl exposes no camera padding, so the anchor is applied by
        // aiming at the ground point that renders where the rider should not
        // be. The distance comes from the tilt and viewport geometry, so the
        // rider still lands at the planned viewport fraction.
        await controller.easeCamera(
          ml.CameraUpdate.newCameraPosition(
            ml.CameraPosition(
              target: ml.LatLng(
                framing.target.latitude,
                framing.target.longitude,
              ),
              zoom: cameraPlan.zoom,
              tilt: cameraPlan.tilt,
              bearing: _cameraBearingDegrees,
            ),
          ),
          duration: cameraDuration,
          interpolation: transitionDuration == null
              ? ml.CameraAnimationInterpolation.linear
              : null,
        );
        return;
      }
      // FlutterMap has no tilt, so the bias is a flat ground offset at its own
      // scale. It goes into the target rather than into the call's screen-space
      // `offset`, which is silently dropped whenever the bearing has not
      // changed - the common case once the rotation deadband is holding.
      _mapController.moveAndRotateAnimatedRaw(
        _latLng(framing.target),
        cameraPlan.zoom,
        _cameraBearingDegrees,
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
      // The command has been issued; whether the map got there is a separate
      // question, re-asked from the camera the map reports (#141).
      _scheduleCameraFramingRefresh();
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
      // Opaque, both of them. These were the only geometry on the map whose
      // casing was translucent and whose line was drawn at 90%, which left them
      // the only lines with nothing solid behind them: 1.80:1 for the good-biking
      // blue over the dark motorway fill, against 4.12:1 once the casing is
      // opaque (#133). #107 already ruled that route geometry uses opaque colour
      // over a casing rather than translucency; this is the last place that had
      // not caught up.
      await controller.addLineLayer(
        _discoveryLineSource,
        'ride-relay-discovery-line-casing',
        const ml.LineLayerProperties(
          lineColor: RouteTrailStyle.casingHex,
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
      // Solid trails are drawn before the planned route so the leader's wider
      // trail reads as a corridor beneath it rather than hiding it.
      await controller.addGeoJsonSource(
        _riderTrailSource,
        _riderTrailGeoJson(),
      );
      await _addTrailLayers(controller, RiderTrailKind.leader);
      await _addTrailLayers(controller, RiderTrailKind.rider);
      await controller.addGeoJsonSource(
        _remainingRouteSource,
        _remainingRouteGeoJson(),
      );
      await controller.addLineLayer(
        _remainingRouteSource,
        'ride-relay-route-remaining-border',
        ml.LineLayerProperties(
          lineColor: _casingHex,
          lineWidth: RouteTrailStyle.routeAhead.casingWidthPixels,
          lineDasharray: RouteTrailStyle.routeAhead.maplibreCasingDashArray,
          lineCap: 'round',
          lineJoin: 'round',
        ),
        enableInteraction: false,
      );
      await controller.addLineLayer(
        _remainingRouteSource,
        'ride-relay-route-remaining',
        ml.LineLayerProperties(
          lineColor: _hexColor(RouteTrailStyle.routeAhead.color),
          lineWidth: RouteTrailStyle.routeAhead.widthPixels,
          lineDasharray: RouteTrailStyle.routeAhead.maplibreDashArray,
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
        ml.LineLayerProperties(
          lineColor: _casingHex,
          lineWidth: RouteTrailStyle.travelled.casingWidthPixels,
          lineCap: 'round',
          lineJoin: 'round',
        ),
        enableInteraction: false,
      );
      await controller.addLineLayer(
        _riddenRouteSource,
        'ride-relay-route-ridden',
        ml.LineLayerProperties(
          lineColor: _hexColor(RouteTrailStyle.travelled.color),
          lineWidth: RouteTrailStyle.travelled.widthPixels,
          lineCap: 'round',
          lineJoin: 'round',
        ),
        enableInteraction: false,
      );
      // An off-route trail belongs on top of the plan: it is the deviation from
      // it.
      await _addTrailLayers(controller, RiderTrailKind.offRoute);
      // The advisory rejoin route (#102) goes above everything else: it is the
      // one line the affected rider is being asked to follow right now.
      await _addTrailLayers(controller, RiderTrailKind.rejoin);
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
      await controller.addGeoJsonSource(
        _markerPlanSource,
        _markerPlanGeoJson(),
      );
      await controller.addCircleLayer(
        _markerPlanSource,
        'ride-relay-marker-plan-points',
        const ml.CircleLayerProperties(
          circleRadius: [
            'case',
            [
              '==',
              ['get', 'kind'],
              'safety',
            ],
            9,
            7,
          ],
          circleColor: ['get', 'color'],
          circleStrokeWidth: 3,
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
          // Dark on a light badge: see [RouteTrailStyle.markerGlyph] (#133).
          iconColor: RouteTrailStyle.markerGlyphHex,
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
          // As above: the badge carries the colour, the glyph carries the shape,
          // and a dark glyph is the only way the shape survives on a light badge.
          iconColor: RouteTrailStyle.markerGlyphHex,
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

  /// Adds one trail kind's casing and line layers.
  ///
  /// Every paint value is a constant per layer, filtered by kind, because
  /// MapLibre cannot data-drive `line-dasharray` and a wrongly typed
  /// data-driven paint value would fail the whole style set-up, not just one
  /// layer. A new kind therefore means one more call here.
  Future<void> _addTrailLayers(
    ml.MapLibreMapController controller,
    RiderTrailKind kind,
  ) async {
    final style = RouteTrailStyle.forTrail(kind);
    final filter = <Object>[
      '==',
      ['get', 'kind'],
      kind.name,
    ];
    await controller.addLineLayer(
      _riderTrailSource,
      'ride-relay-trail-${kind.name}-casing',
      ml.LineLayerProperties(
        lineColor: _casingHex,
        lineWidth: style.casingWidthPixels,
        lineDasharray: style.maplibreCasingDashArray,
        lineCap: 'round',
        lineJoin: 'round',
      ),
      filter: filter,
      enableInteraction: false,
    );
    await controller.addLineLayer(
      _riderTrailSource,
      'ride-relay-trail-${kind.name}-line',
      ml.LineLayerProperties(
        lineColor: _hexColor(style.color),
        lineWidth: style.widthPixels,
        lineDasharray: style.maplibreDashArray,
        lineCap: 'round',
        lineJoin: 'round',
      ),
      filter: filter,
      enableInteraction: false,
    );
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
        _riderTrailSource,
        _riderTrailGeoJson(),
      );
      await controller.setGeoJsonSource(
        _trailDirectionArrowSource,
        _trailDirectionArrowGeoJson(),
      );
      await controller.setGeoJsonSource(_waypointSource, _waypointGeoJson());
      await controller.setGeoJsonSource(
        _markerPlanSource,
        _markerPlanGeoJson(),
      );
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
          _riderTrailSource,
          _riderTrailGeoJson(),
        );
        await controller.setGeoJsonSource(
          _markerPlanSource,
          _markerPlanGeoJson(),
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

  /// Every rider's travelled trail with enough geometry to draw. Rendering is
  /// deliberately independent of whether a route is loaded or matched (#100).
  List<MapOverlayTrace> get _visibleRiderTrails =>
      (widget.riderTrails?.value ?? const <MapOverlayTrace>[])
          .where((trace) => trace.points.length >= 2)
          .toList(growable: false);

  Polyline _routePolyline(List<GeoPoint> path, RouteLineStyle style) =>
      Polyline(
        points: path.map(_latLng).toList(growable: false),
        color: style.color,
        strokeWidth: style.widthPixels,
        borderColor: RouteTrailStyle.casing,
        borderStrokeWidth: style.fallbackBorderWidthPixels,
        pattern: style.dashPixels == null
            ? const StrokePattern.solid()
            : StrokePattern.dashed(segments: style.dashPixels!),
      );

  /// Trail polylines of one pattern, widest first so a wider trail never hides
  /// a narrower one. MapLibre gets the same ordering from its per-kind layers.
  Iterable<Polyline> _trailPolylines({required bool dashed}) =>
      (_visibleRiderTrails
              .where((trace) => trace.style.isDashed == dashed)
              .toList()
            ..sort(
              (first, second) =>
                  second.style.widthPixels.compareTo(first.style.widthPixels),
            ))
          .map((trace) => _routePolyline(trace.points, trace.style));

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
      color: RouteTrailStyle.travelled.color,
      idPrefix: 'ridden',
      semanticLabel: 'Travel direction',
    );
    // Whole-group rides can hold more trail than the arrow budget allows, so
    // the cues a rider needs to interpret someone else's path come first.
    final byImportance = _visibleRiderTrails.toList()
      ..sort(
        (first, second) =>
            _arrowPriority(first.kind).compareTo(_arrowPriority(second.kind)),
      );
    for (final trace in byImportance) {
      addArrows(
        paths: [trace.points],
        color: trace.style.color,
        idPrefix: trace.id,
        semanticLabel: '${trace.label} direction',
      );
      if (items.length >= maximumVisibleArrows) break;
    }
    return items;
  }

  static int _arrowPriority(RiderTrailKind kind) => switch (kind) {
    // The rejoin route is the local rider's own live instruction, so its
    // direction arrows are the last thing the budget may drop.
    RiderTrailKind.rejoin => 0,
    RiderTrailKind.leader => 1,
    RiderTrailKind.offRoute => 2,
    RiderTrailKind.rider => 3,
  };

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

  Map<String, dynamic> _riderTrailGeoJson() => {
    'type': 'FeatureCollection',
    'features': [
      for (final trace in _visibleRiderTrails)
        {
          'type': 'Feature',
          'id': trace.id,
          // The kind selects the layer, which carries the whole style.
          'properties': {'kind': trace.kind.name, 'label': trace.label},
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

  Map<String, dynamic> _markerPlanGeoJson() => MapGeoJson.points(
    _markerPlanVisible
        ? _markerPlan.points.map(
            (point) => MapGeoJsonPoint(
              id: point.id,
              point: point.position,
              properties: {
                'label': point.label,
                'kind': switch (point.kind) {
                  MarkerPlanPointKind.likelyMarker => 'marker',
                  MarkerPlanPointKind.safetyReview => 'safety',
                  MarkerPlanPointKind.musterPoint => 'muster',
                },
                'color': switch (point.kind) {
                  MarkerPlanPointKind.likelyMarker => '#6ED89A',
                  MarkerPlanPointKind.safetyReview => '#FF8A4C',
                  MarkerPlanPointKind.musterPoint => '#68A9FF',
                },
              },
            ),
          )
        : const <MapGeoJsonPoint>[],
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
    if (layerId == 'ride-relay-marker-plan-points') {
      final point = _markerPlan.points
          .where((item) => item.id == id)
          .firstOrNull;
      if (point != null) {
        _showMessage(
          point.detail == null
              ? point.label
              : '${point.label}: ${point.detail}',
        );
      }
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

  /// Picks a route out of the geometry already on this phone - a recorded
  /// route, or a previous ride's plan or track - and feeds it through exactly
  /// the same pipeline a GPX import uses (#155).
  ///
  /// The only difference between this and [_importGpx] is where the
  /// [ImportedRoute] comes from. Everything after it - road matching, the
  /// review screen, `RouteStore`, `RouteProgressTracker`, breadcrumbs,
  /// manoeuvres - is the shared path, so a route from history and a route from
  /// a file are indistinguishable once selected.
  Future<void> _useStoredRoute() async {
    if (_importing) return;
    setState(() => _importing = true);
    try {
      final library = widget.storedRouteLibrary ?? await _openStoredRoutes();
      if (!mounted) return;
      final selection = await StoredRoutePickerScreen.show(
        context,
        library: library,
        distanceUnit: widget.distanceUnit,
      );
      if (selection == null || !mounted) return;
      final prepared = library.prepare(selection);
      await _reviewAndActivateRoute(prepared.route, warnings: prepared.notes);
    } on FormatException catch (error) {
      _showMessage(error.message);
    } on Object catch (error) {
      _showMessage('Could not read saved routes: $error');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<StoredRouteLibrary> _openStoredRoutes() async => StoredRouteLibrary(
    recordedRoutes:
        widget.recordedRouteStore ??
        await JsonFileRecordedRouteStore.openDefault(),
    completedRides:
        widget.completedRideStore ??
        await JsonFileCompletedRideStore.openDefault(),
  );

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
    widget.onRouteCommitted?.call(activeRoute);
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

  /// Frames the whole route, or the rider when there is no route.
  ///
  /// This is also the initial framing once the map is ready. Without the
  /// fallback a route-less ride opened on a UK-wide overview and stayed there
  /// until the bike moved fast enough to arm the follow camera (#124).
  void _fitRoute() {
    final planned = _route?.allPoints.toList(growable: false) ?? const [];
    final routePoints = planned.isNotEmpty ? planned : [?_effectivePosition];
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
      case _MapAction.speedLimitDisplay:
        if (_speedLimitDisplay.enabled) {
          await _speedLimitDisplay.setEnabled(false);
        } else {
          await _confirmEnableSpeedLimitDisplay();
        }
      case _MapAction.maneuverList:
        await _showManeuverList();
      case _MapAction.markerPlan:
        setState(() => _markerPlanVisible = !_markerPlanVisible);
        _scheduleMapLibreSync(overlays: true);
      case _MapAction.groupPip:
        await _openGroupPip();
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
            _markerPlanVisible = false;
            _initialCameraPositioned = false;
            _releaseNavigationViewport();
          });
          _navigationGuidance.value = null;
          widget.onNavigationGuidanceChanged?.call(null);
          await _syncMapLibreSources();
          widget.onRouteChanged?.call(null);
          widget.onRouteCommitted?.call(null);
        }
      case _MapAction.clearOfflineTiles:
        await _mapLibreOfflineManager.clearAll();
        await widget.offlineTileCache.clearAll();
        _showMessage('Offline map data cleared.');
    }
  }

  /// Lists every manoeuvre for the loaded route.
  ///
  /// Distances come from the persisted route and the map's own progress tracker,
  /// so the list works with no network and no fresh routing call.
  Future<void> _showManeuverList() async {
    final route = _route;
    if (route == null) return;
    await ManeuverListScreen.show(
      context,
      route: route,
      distanceUnit: widget.distanceUnit,
      progressMeters: _effectivePosition == null
          ? null
          : _progressGeometry.progressMeters,
    );
  }

  Future<void> _openGroupPip() async {
    if (!await _groupPipBridge.isSupported()) {
      _showMessage(
        'Picture-in-Picture is not supported on this Android device.',
      );
      return;
    }
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Show the group over another app?'),
        content: const Text(
          'Android will pin a small, non-interactive route and rider view. '
          'It uses no map tiles and can remain visible while you open your '
          'navigation app. Close it with Android’s Picture-in-Picture control.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('confirm-group-pip'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Show mini-map'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final entered = await _groupPipBridge.enter(_groupPipSnapshot());
    if (!entered) {
      _showMessage('The Android mini-map could not be opened.');
    }
  }

  Future<void> _publishGroupPipSnapshot() =>
      _groupPipBridge.publish(_groupPipSnapshot());

  GroupPipSnapshot _groupPipSnapshot() {
    final overlays = widget.overlayMarkers?.value ?? const <MapOverlayMarker>[];
    final currentPosition = _effectivePosition;
    final leaderStatus = widget.leaderStatus?.value;
    final markerStatus = widget.junctionMarkerOverlay?.value;
    final offCourseCount = leaderStatus?.offCourseAlerts.length ?? 0;
    String? status;
    if (markerStatus?.isLocalMarker == true) {
      status = markerStatus!.instruction;
    } else if (offCourseCount > 0) {
      status =
          '$offCourseCount rider${offCourseCount == 1 ? '' : 's'} '
          'need attention';
    } else if (leaderStatus?.distanceToTecMeters case final distance?) {
      status =
          'TEC '
          '${MeasurementFormatter(widget.distanceUnit).distance(distance)} '
          'behind';
    } else if (widget.groupRiderCount case final count?) {
      status = '$count rider${count == 1 ? '' : 's'}';
    }
    return GroupPipSnapshot(
      routePaths:
          _route?.paths.map((path) => path.points).toList(growable: false) ??
          const [],
      markers: [
        if (currentPosition != null)
          GroupPipMarker(
            point: currentPosition,
            label: 'You',
            colourArgb: widget.localBadgeColor.toARGB32(),
            kind: GroupPipMarkerKind.rider,
            isLocal: true,
          ),
        for (final marker in overlays)
          GroupPipMarker(
            point: marker.point,
            label: marker.label,
            colourArgb: marker.color.toARGB32(),
            kind: marker.motorcycleStyle == null
                ? GroupPipMarkerKind.hazard
                : GroupPipMarkerKind.rider,
          ),
      ],
      status: status,
      alert:
          offCourseCount > 0 ||
          overlays.any((marker) => marker.motorcycleStyle == null),
    );
  }

  Future<void> _reportEnforcementSighting() async {
    final report = widget.onReportHazard;
    if (report == null) return;
    final type = await showModalBottomSheet<HazardType>(
      context: context,
      backgroundColor: const Color(0xFF161D26),
      showDragHandle: true,
      // Without this the sheet is capped at nine sixteenths of the screen - 219
      // pixels on a 390 pixel landscape phone - and two glove-sized targets plus
      // a title and a cancel do not fit, so the second one fell below the fold
      // and selecting police needed a scroll (#133). The sheet takes the height
      // it needs instead of the targets being shrunk to fit a cap.
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.only(bottom: 14),
                child: Text(
                  'Tell the group',
                  style: TextStyle(
                    color: Color(0xFFE4E9EF),
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              _ReportSightingOptions(
                onSpeedCamera: () =>
                    Navigator.of(sheetContext).pop(HazardType.speedCamera),
                onPolice: () =>
                    Navigator.of(sheetContext).pop(HazardType.policeActivity),
              ),
              TextButton(
                onPressed: () => Navigator.of(sheetContext).pop(),
                child: const Text('Cancel'),
              ),
            ],
          ),
        ),
      ),
    );
    if (type == null || !mounted) return;
    try {
      await report(type);
      _showMessage('${type.label} reported to the group.');
    } on FormatException catch (error) {
      _showMessage('Report not sent. ${error.message}');
    } on Object {
      _showMessage('Report not sent. Try again in a moment.');
    }
  }

  Future<void> _confirmEnableSpeedLimitDisplay() async {
    if (_speedLimitDisplay.enabled) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Show mapped speed limits?'),
        content: const Text(
          'When this is on, the app sends your current and recent foreground '
          'GPS positions to a Valhalla road-matching service to identify the '
          'road you are on. It works in the UK and uses mapped OpenStreetMap '
          'limits, which may be missing or out of date. Roadside signs always '
          'apply.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Not now'),
          ),
          FilledButton(
            key: const Key('confirm-speed-limit-opt-in'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Turn on'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    await _speedLimitDisplay.setEnabled(true);
    _observeSpeedLimit(_navigationFix);
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
              // Stored geometry sits beside "choose a file", not behind it: a
              // rider picking a route should not have to know which one the
              // app wants (#155).
              ListTile(
                key: const Key('use-stored-route-sheet-item'),
                leading: const Icon(Icons.history),
                title: const Text('Use a saved route'),
                subtitle: const Text('A recorded route or a previous ride'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _useStoredRoute();
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
              // Route-derived: nothing to remove without one.
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
  speedLimitDisplay,
  maneuverList,
  markerPlan,
  groupPip,
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
    this.accuracyMeters,
  });

  final GeoPoint point;
  final DateTime recordedAt;
  final double? speedMetersPerSecond;
  final double? headingDegrees;
  final double? accuracyMeters;

  bool get isMoving => (speedMetersPerSecond ?? 0) >= 2.5;

  @override
  bool operator ==(Object other) =>
      other is MapNavigationPosition &&
      point.latitude == other.point.latitude &&
      point.longitude == other.point.longitude &&
      recordedAt == other.recordedAt &&
      speedMetersPerSecond == other.speedMetersPerSecond &&
      headingDegrees == other.headingDegrees &&
      accuracyMeters == other.accuracyMeters;

  @override
  int get hashCode => Object.hash(
    point.latitude,
    point.longitude,
    recordedAt,
    speedMetersPerSecond,
    headingDegrees,
    accuracyMeters,
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
  });

  final String riderId;
  final String displayName;
  final RideRole role;

  String get shortRoleLabel => switch (role) {
    RideRole.lead => 'the leader',
    RideRole.tailEndCharlie => 'the TEC',
    _ => displayName,
  };
}

/// One rider's travelled trail, drawn from recorded position history rather
/// than from any match against the planned route (#100).
class MapOverlayTrace {
  const MapOverlayTrace({
    required this.id,
    required this.points,
    required this.label,
    this.kind = RiderTrailKind.rider,
  });

  final String id;
  final List<GeoPoint> points;
  final String label;
  final RiderTrailKind kind;

  RouteLineStyle get style => RouteTrailStyle.forTrail(kind);
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
    required this.onUseStoredRoute,
    required this.onLoadDemo,
  });

  final bool importing;
  final bool routing;
  final VoidCallback onPlanDestination;
  final VoidCallback onImport;
  final VoidCallback onUseStoredRoute;
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
                'Enter a destination, reuse a recorded route or a previous '
                'ride, import a GPX file, or use the demo route.',
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
              // Stored geometry is a route source in its own right, offered
              // here beside the file picker rather than buried behind it
              // (#155).
              OutlinedButton.icon(
                key: const Key('use-stored-route-empty-button'),
                onPressed: importing ? null : onUseStoredRoute,
                icon: const Icon(Icons.history),
                label: const Text('Use a saved route'),
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

class _WaitingForLeaderRoutePrompt extends StatelessWidget {
  const _WaitingForLeaderRoutePrompt();

  @override
  Widget build(BuildContext context) => Center(
    child: Card(
      margin: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: const Padding(
          padding: EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Waiting for the leader’s route',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
              ),
              SizedBox(height: 8),
              Text(
                'This ride has no group route yet. It will appear here when '
                'the leader shares one.',
                style: TextStyle(color: Color(0xFF98A3B1)),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// The body a rider sends when they have stopped and need help.
///
/// Top-level and testable because it is the part that matters: the words go to
/// somebody outside the ride who has none of its context, and a position is the
/// one thing they cannot work out for themselves. Six decimal places is about
/// 0.1 m - finer than any phone fix justifies, and short enough to read aloud
/// over a bad line.
///
/// A missing fix says so rather than sending a message that looks complete and
/// locates nobody (#173).
@visibleForTesting
String emergencyMessageBody(GeoPoint? position) {
  const opening = 'Tail End Charlie: I have stopped and need assistance.';
  if (position == null) {
    return '$opening I do not have a GPS position to send.';
  }
  final latitude = position.latitude.toStringAsFixed(6);
  final longitude = position.longitude.toStringAsFixed(6);
  return '$opening I am at $latitude, $longitude '
      '(https://www.openstreetmap.org/?mlat=$latitude&mlon=$longitude).';
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
      // Scrolls rather than scales. A rider reads and taps this sheet, so
      // shrinking the type is the wrong give: at 390 px of landscape height -
      // any current iPhone held sideways - the fixed content overran the bottom
      // by 58 px and the framework clipped whatever was last (#193).
      //
      // The order already puts what matters first: the four issue buttons, then
      // the messaging control, then the explanatory note. So the note is what
      // goes below the fold, which is the right thing to lose.
      child: SingleChildScrollView(
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
                      icon: Icon(quickMessageIcon(message), size: 18),
                      label: Text(message.label),
                    ),
                ],
              ),
              const SizedBox(height: 18),
              OutlinedButton.icon(
                key: const Key('emergency-open-messages-button'),
                onPressed: _sending ? null : () => unawaited(_openMessages()),
                icon: const Icon(Icons.sms_outlined),
                // Names the recipient problem in the label, not only in the note
                // below it: a rider who has stopped and needs help does not read
                // 12 px of grey text, and an empty To: field looked like a fault
                // rather than a choice (#173).
                label: const Text('Text someone from your contacts'),
              ),
              const SizedBox(height: 6),
              const Text(
                'Your position is filled in ready to send. A ride invite carries '
                'no phone numbers, so pick who to text - the leader and TEC have '
                'already had the alert in the app.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Color(0xFF98A3B1), fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
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

  /// Left plus right, and top plus bottom, of the fit padding the old bounds
  /// call used. Subtracted before framing so padding can never exceed the box.
  static const _fitHorizontalPadding = 40.0;
  static const _fitVerticalPadding = 40.0;

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
    // The rider count is in the layout rather than hung 22 pixels below the box
    // by a negative offset. That trick assumed the overview always had rail
    // beneath it to hang into; #133 puts it in a screen corner, where the caption
    // fell off the edge. The key is on the whole footprint so an overlap test
    // measures what is actually on screen, caption included.
    return Semantics(
      key: const Key('group-mini-map'),
      button: widget.onTap != null,
      label: widget.onTap == null
          ? null
          : 'Open ride roster, $riderCount riders',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildMiniMapCanvas(visibleRoutePaths),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(left: 7),
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
          ],
        ),
      ),
    );
  }

  Widget _buildMiniMapCanvas(List<List<GeoPoint>> visibleRoutePaths) => Stack(
    children: [
      Container(
        key: const Key('group-mini-map-canvas'),
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
                      padding: EdgeInsets.symmetric(horizontal: 3, vertical: 1),
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
              // Both variants, not only the untiled one. The tiled iOS mini-map
              // drew no scale at all while Android drew "10 km", and a tester
              // asked for exactly this: something that says at a glance whether
              // the group is spread over half a mile or 195 miles (#172).
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
    ],
  );

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
        ml.LineLayerProperties(
          lineColor: RouteTrailStyle.casingHex,
          lineWidth: RouteTrailStyle.miniMapRoute.casingWidthPixels,
          lineCap: 'round',
          lineJoin: 'round',
        ),
        enableInteraction: false,
      );
      await controller.addLineLayer(
        _routeSource,
        'ride-relay-mini-route-line',
        ml.LineLayerProperties(
          lineColor: _hexColor(RouteTrailStyle.miniMapRoute.color),
          lineWidth: RouteTrailStyle.miniMapRoute.widthPixels,
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
    // The camera is computed rather than handed to `newLatLngBounds`, so the
    // outcome is testable and does not depend on how a bounds fit behaves in a
    // 150 x 104 box. A rider on the Isle of Man and the rest near Bristol used
    // to leave the mini-map framed on open sea with nobody in it (#172).
    final framing = GroupMiniMapFraming.forPoints(
      points,
      width: widget.width - _fitHorizontalPadding,
      height: widget.height - _fitVerticalPadding,
    );
    await controller.animateCamera(
      ml.CameraUpdate.newLatLngZoom(
        ml.LatLng(framing.centre.latitude, framing.centre.longitude),
        framing.zoom,
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
      // Opaque colour over a casing rather than a translucent line, matching
      // the tiled mini-map and the main map's route ahead.
      canvas.drawPath(
        path,
        Paint()
          ..color = RouteTrailStyle.casing
          ..style = PaintingStyle.stroke
          ..strokeWidth = RouteTrailStyle.miniMapRoute.casingWidthPixels
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
      canvas.drawPath(
        path,
        Paint()
          ..color = RouteTrailStyle.miniMapRoute.color
          ..style = PaintingStyle.stroke
          ..strokeWidth = RouteTrailStyle.miniMapRoute.widthPixels
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

class _SpeedLimitOptInChip extends StatelessWidget {
  const _SpeedLimitOptInChip({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: 'Mapped speed limits are off',
    child: FilledButton.tonalIcon(
      key: const Key('speed-limit-opt-in-chip'),
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: const Color(0xE6252E39),
        foregroundColor: const Color(0xFFE4E9EF),
        padding: const EdgeInsets.fromLTRB(7, 5, 11, 5),
        minimumSize: const Size(0, 40),
        side: const BorderSide(color: Color(0xFF445262)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      icon: Container(
        width: 30,
        height: 30,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
          border: Border.all(color: const Color(0xFF8993A0), width: 3),
        ),
        child: const Text(
          '–',
          style: TextStyle(
            color: Color(0xFF30343B),
            fontSize: 18,
            height: 1,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
      label: const Text(
        'Limits off',
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800),
      ),
    ),
  );
}

/// The fixed square every action target's leading glyph sits in.
///
/// A `CircularProgressIndicator` sized for a button is 20 pixels where a
/// Material icon is 24, so sending an alert used to narrow SOS by four pixels
/// before the label had even changed. The slot is the icon's own size, so no
/// state can alter it (#142).
class _ActionIconSlot extends StatelessWidget {
  const _ActionIconSlot({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      SizedBox.square(dimension: 24, child: Center(child: child));
}

/// An action label in a slot sized for the widest string the control can show.
///
/// The width is measured from [widest] in the text style, font, locale and text
/// scale actually in effect - the style a `FloatingActionButton` puts on its
/// label reaches this widget through the enclosing `DefaultTextStyle` - so it is
/// right on a device and in a test without a hard-coded pixel count, which would
/// be wrong in one of the two. #139 let the current label drive the width, and
/// SOS turning into "ALERT SENT" widened the control enough to push REPORT onto
/// a run of its own (#142).
///
/// Beyond [_maximumSlotWidth] the text scales down inside the slot rather than
/// widening it, which is the contract REPORT's caption already keeps: at the
/// largest accessibility text sizes a rider keeps a full-size target and a
/// smaller word, not a target that has shoved its neighbours off the rail.
class _ActionLabel extends StatelessWidget {
  const _ActionLabel(this.text, {required this.widest, this.slotWidth});

  final String text;

  /// The longest string this control can ever show, including the current one.
  final String widest;

  /// A slot width to use instead of measuring [widest]. Landscape sets one so the
  /// three-across row's width is fixed in every font and at every text size; the
  /// label scales down inside it rather than widening it, which is the contract
  /// REPORT's caption already keeps.
  final double? slotWidth;

  /// The widest a measured slot may become before the label gives way instead.
  /// Portrait has the room; this only guards the largest accessibility sizes.
  static const double _maximumSlotWidth = 150;

  @override
  Widget build(BuildContext context) {
    final fixed = slotWidth;
    double width;
    if (fixed != null) {
      width = fixed;
    } else {
      final painter = TextPainter(
        text: TextSpan(text: widest, style: DefaultTextStyle.of(context).style),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout();
      width = math.min(painter.width, _maximumSlotWidth);
      painter.dispose();
    }
    return SizedBox(
      width: width,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(text, maxLines: 1, softWrap: false),
      ),
    );
  }
}

/// Compact map control that opens the enforcement sighting picker.
///
/// Deliberately small: it sits over the map for a whole ride, so it earns only
/// as much space as a gloved thumb needs. The targets it opens are the large
/// ones.
class _ReportSightingButton extends StatelessWidget {
  const _ReportSightingButton({required this.onPressed});

  final VoidCallback onPressed;

  /// The square the target occupies, in every state and both orientations. #142
  /// takes the width a narrow landscape rail needs out of the two labels, never
  /// out of this: 62 px is a deliberate glove size, well past the 48 px minimum.
  static const double side = 62;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: 'Report a camera or police to the group',
    child: Material(
      color: const Color(0xF21C2530),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: Color(0xFF5A6878)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: const Key('report-sighting-button'),
        onTap: onPressed,
        child: SizedBox(
          width: side,
          height: side,
          child: const Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.add_alert_rounded, size: 26, color: Color(0xFFFFD24A)),
              SizedBox(height: 2),
              // The target keeps its 62 pixels at every text size, so the caption
              // is what gives way rather than the box overflowing: the icon is
              // what a rider aims at, and the word underneath only names it.
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    'REPORT',
                    style: TextStyle(
                      color: Color(0xFFE4E9EF),
                      fontSize: 9,
                      height: 1,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.6,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// The two report targets, side by side wherever both fit.
///
/// Stacked, they needed 176 pixels of a sheet the framework caps at 219 on a
/// landscape phone, so police fell below the fold and could only be reached by
/// scrolling - unusable on a bike, and it defeated the two-tap design, which
/// exists so a stray map tap cannot broadcast a warning to the whole group
/// (#133). Neither target is shrunk to achieve it: the pair goes side by side
/// when each half can still hold a full-size target, and stacks otherwise, which
/// is what keeps the largest accessibility text sizes honest.
class _ReportSightingOptions extends StatelessWidget {
  const _ReportSightingOptions({
    required this.onSpeedCamera,
    required this.onPolice,
  });

  final VoidCallback onSpeedCamera;
  final VoidCallback onPolice;

  /// Width one option needs for its icon, its label at the current text scale,
  /// and the padding a gloved hand needs around them.
  static double _minimumOptionWidth(BuildContext context) =>
      34 + 24 + MediaQuery.textScalerOf(context).scale(22) * 7.2;

  @override
  Widget build(BuildContext context) {
    final camera = _ReportSightingOption(
      optionKey: const Key('report-speed-camera-option'),
      label: 'SPEED CAMERA',
      icon: Icons.speed_rounded,
      color: const Color(0xFF9B1B23),
      onPressed: onSpeedCamera,
    );
    final police = _ReportSightingOption(
      optionKey: const Key('report-police-option'),
      label: 'POLICE',
      icon: Icons.local_police_rounded,
      color: const Color(0xFF17497F),
      onPressed: onPolice,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth;
        final sideBySide =
            available.isFinite &&
            (available - 12) / 2 >= _minimumOptionWidth(context);
        if (!sideBySide) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [camera, police],
          );
        }
        return Row(
          key: const Key('report-options-side-by-side'),
          // Each option carries its own height, so the row must not try to
          // stretch to a parent that has none to give.
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: camera),
            const SizedBox(width: 12),
            Expanded(child: police),
          ],
        );
      },
    );
  }
}

/// One report target, sized for a rider wearing gloves, on a moving bike.
class _ReportSightingOption extends StatelessWidget {
  const _ReportSightingOption({
    required this.optionKey,
    required this.label,
    required this.icon,
    required this.color,
    required this.onPressed,
  });

  final Key optionKey;
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: SizedBox(
      // Both options must be reachable on a landscape phone without scrolling;
      // the sheet scrolls as a backstop, but a rider should never have to reach
      // for it. This height is never traded away to make them fit - see
      // [_ReportSightingOptions], which changes the arrangement instead.
      height: 76,
      child: FilledButton.icon(
        key: optionKey,
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
        ),
        icon: Icon(icon, size: 34),
        label: Text(
          label,
          style: const TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w900,
            letterSpacing: 0.5,
          ),
        ),
      ),
    ),
  );
}

class _EnforcementAlertOverlay extends StatelessWidget {
  const _EnforcementAlertOverlay({
    required this.alert,
    required this.distanceUnit,
    required this.onDismiss,
  });

  final EnforcementAlert alert;
  final DistanceUnit distanceUnit;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final camera = alert.hazard.type == HazardType.speedCamera;
    final title = camera ? 'SPEED CAMERA' : 'POLICE';
    final distance = MeasurementFormatter(
      distanceUnit,
    ).distance(alert.distanceMeters);
    final details = alert.hazard.details;
    return Semantics(
      key: const Key('enforcement-alert-overlay'),
      container: true,
      liveRegion: true,
      label: '$title ahead in $distance.',
      button: true,
      onTapHint: 'Dismiss',
      child: GestureDetector(
        onTap: onDismiss,
        behavior: HitTestBehavior.opaque,
        child: ColoredBox(
          // Fully opaque: anything showing through competes with the warning
          // at exactly the moment the rider has least attention to spare.
          color: camera ? const Color(0xFF6E1015) : const Color(0xFF0F3560),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    camera ? Icons.speed_rounded : Icons.local_police_rounded,
                    size: 76,
                    color: Colors.white,
                  ),
                  const SizedBox(height: 12),
                  FittedBox(
                    child: Text(
                      title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 44,
                        height: 1,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.5,
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  FittedBox(
                    child: Text(
                      key: const Key('enforcement-alert-distance'),
                      distance,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 68,
                        height: 1,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'AHEAD',
                    style: TextStyle(
                      color: Color(0xCCFFFFFF),
                      fontSize: 15,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 3,
                    ),
                  ),
                  if (details != null && details.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    Text(
                      details,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Color(0xE6FFFFFF),
                        fontSize: 14,
                        height: 1.3,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                  const SizedBox(height: 18),
                  const Text(
                    'TAP TO DISMISS',
                    style: TextStyle(
                      color: Color(0x99FFFFFF),
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 2,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// The badge sits directly on the map without a panel behind it, so every label
// outside the white sign face carries its own shadow for legibility.
const _mapOverlayTextShadows = [
  Shadow(color: Color(0xCC0B0F14), blurRadius: 6),
  Shadow(color: Color(0x990B0F14), blurRadius: 2, offset: Offset(0, 1)),
];

/// Light text drawn over an unknown map background.
///
/// A shadow alone washes out over a light daytime basemap, so the glyphs are
/// painted twice: a dark stroke first, then the fill.
class _MapOverlayLabel extends StatelessWidget {
  const _MapOverlayLabel(
    this.text, {
    required this.style,
    required this.strokeWidth,
    this.fillKey,
  });

  final String text;
  final TextStyle style;
  final double strokeWidth;
  final Key? fillKey;

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      Text(
        text,
        style: style.copyWith(
          shadows: const [],
          foreground: Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = strokeWidth
            ..strokeJoin = StrokeJoin.round
            ..color = const Color(0xE60B0F14),
        ),
      ),
      Text(text, key: fillKey, style: style),
    ],
  );
}

class _PostedSpeedLimitBadge extends StatelessWidget {
  const _PostedSpeedLimitBadge({
    required this.status,
    required this.outcome,
    required this.limit,
    required this.riderSpeedMetersPerSecond,
  });

  final SpeedLimitDisplayStatus status;
  final SpeedLimitLookupOutcome? outcome;
  final PostedSpeedLimit? limit;
  final double? riderSpeedMetersPerSecond;

  @override
  Widget build(BuildContext context) {
    final reading = limit;
    final known = status == SpeedLimitDisplayStatus.known && reading != null;
    final value = known ? '${reading.milesPerHour}' : '–';
    // The readout sits under a UK mph sign, so it stays in mph whatever the
    // rider's distance-unit preference is. Two units under one sign would
    // invite a dangerous misread.
    final speed = riderSpeedMetersPerSecond;
    final riderMilesPerHour = speed != null && speed.isFinite && speed >= 0
        ? (speed * 2.236936).round()
        : null;
    final speedValue = riderMilesPerHour == null ? '–' : '$riderMilesPerHour';
    final checkedAt = known
        ? MaterialLocalizations.of(
            context,
          ).formatTimeOfDay(TimeOfDay.fromDateTime(reading.checkedAt.toLocal()))
        : null;
    final detail = known
        ? reading.roadName == null
              ? 'Checked $checkedAt · mapped · not live'
              : '${reading.roadName} · checked $checkedAt · mapped · not live'
        : switch (status) {
            SpeedLimitDisplayStatus.checking => 'Checking mapped road',
            // Named for the condition, and stated rather than left blank (#126).
            SpeedLimitDisplayStatus.unconfirmedRoad => switch (outcome) {
              SpeedLimitLookupOutcome.poorAccuracy => 'GPS accuracy too low',
              SpeedLimitLookupOutcome.poorMatch => 'Road not confirmed',
              // Enabled, first fix not answered yet.
              _ => 'Finding your road',
            },
            _ => switch (outcome) {
              SpeedLimitLookupOutcome.unsupportedRegion => 'UK only',
              SpeedLimitLookupOutcome.noTaggedLimit => 'No mapped limit',
              _ => 'Limit unavailable',
            },
          };
    final riderSpeedLabel = riderMilesPerHour == null
        ? 'Your speed is unavailable.'
        : 'You are riding at $riderMilesPerHour miles per hour by GPS.';
    // Carries what the deleted caption used to say (#125): which number is the
    // sign and which is the rider, that the limit is mapped rather than live,
    // and how stale it is. Removing the caption moved this wording, it did not
    // lose it.
    final semanticLabel = known
        ? 'Mapped speed limit ${reading.milesPerHour} miles per hour'
              '${reading.roadName == null ? '' : ' on ${reading.roadName}'}. '
              'Looked up at $checkedAt. Mapped, not live. $riderSpeedLabel '
              'Roadside signs apply.'
        : 'Mapped speed limit unavailable: $detail. $riderSpeedLabel '
              'Roadside signs apply.';
    return Semantics(
      key: const Key('posted-speed-limit-badge'),
      container: true,
      liveRegion: true,
      label: semanticLabel,
      excludeSemantics: true,
      child: Tooltip(
        message:
            '$detail\n$riderSpeedLabel\n© OpenStreetMap contributors via Valhalla; temporary and variable limits may differ. Roadside signs apply.',
        // Exactly the sign's own width, in every state (#142): the readout under
        // it carries one to three digits or a dash, and at large text sizes a
        // three-digit speed was wide enough to widen the whole surface and move
        // its left edge across the map. The number gives way inside the sign's
        // width instead, which is the contract every other variable-length
        // surface in this band keeps.
        child: SizedBox(
          width: 58,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 58,
                height: 58,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: known
                        ? const Color(0xFFD71920)
                        : const Color(0xFF8993A0),
                    width: 6,
                  ),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x66000000),
                      blurRadius: 8,
                      offset: Offset(0, 2),
                    ),
                  ],
                ),
                child: status == SpeedLimitDisplayStatus.checking
                    ? const SizedBox.square(
                        dimension: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 3,
                          color: Color(0xFF30343B),
                        ),
                      )
                    : Text(
                        value,
                        style: const TextStyle(
                          color: Color(0xFF111111),
                          fontSize: 26,
                          height: 1,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
              ),
              const SizedBox(height: 4),
              _MapOverlayLabel(
                speedValue,
                fillKey: const Key('posted-speed-limit-rider-speed'),
                strokeWidth: 4,
                style: const TextStyle(
                  color: Color(0xFFFFFFFF),
                  fontSize: 26,
                  height: 1,
                  fontWeight: FontWeight.w900,
                  shadows: _mapOverlayTextShadows,
                ),
              ),
              // No caption (#125). A red-ringed UK sign over a plain number is
              // already unambiguous, and nine-point text on a moving bike cost
              // glance time without adding meaning. The wording it carried is
              // not lost: [semanticLabel] and the tooltip above still say which
              // number is which, where the limit came from, and how stale it is.
            ],
          ),
        ),
      ),
    );
  }
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
    final formatter = MeasurementFormatter(distanceUnit);
    final distance = formatter.distance(guidance.distanceMeters);
    final instruction = guidance.instruction;
    final following = guidance.followingInstruction;
    final showLanes = maneuverLanesAreShowable(instruction.lanes);
    final followingDistance = guidance.followingDistanceMeters == null
        ? null
        : formatter.distance(guidance.followingDistanceMeters!);
    // Spoken rather than seen, so the wording names the junction the symbol
    // shows: standaloneText, not the text drawn beside the symbol.
    final semanticLabel = [
      '${instruction.standaloneText} in $distance.',
      if (showLanes) maneuverLaneSummary(instruction.lanes),
      if (following != null)
        'Then ${following.standaloneText}'
            '${followingDistance == null ? '' : ' after $followingDistance'}.',
      guidance.roadLabel,
    ].join(' ');
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
                ManeuverSymbolView(
                  instruction: instruction,
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
                        '$distance · ${instruction.text}',
                        maxLines: 2,
                        softWrap: true,
                        style: TextStyle(
                          fontSize: compact ? 14 : 16,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      if (showLanes) ...[
                        const SizedBox(height: 5),
                        ManeuverLaneStrip(
                          lanes: instruction.lanes,
                          compact: compact,
                        ),
                      ],
                      if (following != null) ...[
                        const SizedBox(height: 5),
                        Row(
                          key: const Key('following-maneuver'),
                          children: [
                            ManeuverSymbolView(
                              instruction: following,
                              size: compact ? 17 : 19,
                              color: const Color(0xFFFFC857),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                'Then'
                                '${followingDistance == null ? '' : ' in $followingDistance'} · '
                                '${following.text}',
                                maxLines: 2,
                                softWrap: true,
                                style: TextStyle(
                                  fontSize: compact ? 12 : 13,
                                  fontWeight: FontWeight.w800,
                                  color: const Color(0xFFFFD77D),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
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

/// The icon for a received quick message.
///
/// Shared with `_EmergencyActionsSheet`'s picker so the kind a rider chose to
/// send and the kind another rider is shown are the same symbol on both phones.
IconData quickMessageIcon(QuickMessage? message) => switch (message) {
  QuickMessage.mechanical => Icons.build_outlined,
  QuickMessage.assistance => Icons.volunteer_activism_outlined,
  QuickMessage.routeBlocked => Icons.block_outlined,
  QuickMessage.fuel => Icons.local_gas_station_outlined,
  QuickMessage.stopped => Icons.pan_tool_outlined,
  QuickMessage.emergencyStop => Icons.emergency_outlined,
  QuickMessage.allPassed => Icons.done_all_rounded,
  QuickMessage.resolved => Icons.task_alt_rounded,
  // A kind only a newer build knows. The sender's own label still reads, so the
  // row says what they said with a neutral symbol rather than nothing at all.
  null => Icons.campaign_outlined,
};

/// How long ago a message was raised, in the shortest honest form.
String _quickMessageAge(DateTime raisedAt, DateTime now) {
  final age = now.difference(raisedAt);
  if (age.inSeconds < 45) return 'just now';
  if (age.inMinutes < 60) return '${age.inMinutes} min ago';
  return '${age.inHours} h ago';
}

/// Where the sender is, as a rider on a mount can read it in one glance.
///
/// Two forms, and never a third: "1.2 mi back" along the route, or "400 m NE"
/// when a route distance would be a number that means nothing. Says so plainly
/// when the sender has never reported a position, rather than showing a zero.
String describeQuickMessageOrigin(
  QuickMessageOrigin? origin,
  DistanceUnit unit,
) {
  if (origin == null) return 'position not reported';
  final distance = MeasurementFormatter(unit).distance(origin.distanceMeters);
  if (origin.alongRoute) {
    if (origin.distanceMeters < 40) return 'right here';
    return origin.senderIsBehind == true ? '$distance back' : '$distance ahead';
  }
  final compass = origin.compassLabel;
  return compass == null ? distance : '$distance $compass';
}

/// One received quick message, in the bottom band, until it is acknowledged.
///
/// The row a rider who glances away must not lose. It is the whole reason a
/// transient interrupt is not enough on its own: the interrupt says something
/// happened, this says what, who, when, where, and gives the rider the one
/// action that ends it.
///
/// Its footprint is a function of the rail it sits in, never of its own text, so
/// it cannot resize or reflow the targets below it (#142) - the rail is a
/// bottom-anchored [Column] of fixed width, so this grows the band upwards and
/// the action row does not move at all.
class _QuickMessageAlertCard extends StatelessWidget {
  const _QuickMessageAlertCard({
    required this.alert,
    required this.compact,
    required this.distanceUnit,
    required this.outstandingCount,
    required this.acknowledging,
    required this.onAcknowledge,
    required this.onDismissReceipt,
  });

  final RideQuickMessageAlert alert;
  final bool compact;
  final DistanceUnit distanceUnit;

  /// How many other riders' messages are outstanding, including this one.
  final int outstandingCount;
  final bool acknowledging;
  final VoidCallback? onAcknowledge;
  final VoidCallback onDismissReceipt;

  @override
  Widget build(BuildContext context) {
    final message = alert.message;
    final receipt = message.raisedFromLocalRider;
    // Critical takes the off-course banner's red, which #133 measured at 5.65:1
    // for white body text - the same ink on the same fill, so no new colour has
    // to be argued for. Everything else takes the panel the paused banner and
    // REPORT already use, with the accent carrying the urgency instead of the
    // fill: a routine "Need fuel" must read as information, not as an emergency.
    final critical = message.interrupts && !receipt;
    final fill = critical ? const Color(0xFFC42741) : const Color(0xF21C2530);
    final accent = critical
        ? Colors.white
        : receipt
        ? const Color(0xFF6ED89A)
        : message.isPressing
        ? const Color(0xFFFFC857)
        : const Color(0xFF8FC4F5);
    final headline = receipt
        // Reads correctly whatever the label says: "saw your need fuel alert"
        // does not, and a label can come from a build this one does not know.
        ? '${message.firstAcknowledgement?.displayName ?? 'A rider'} saw: '
              '${message.label}'
        : message.headline;
    final detail = receipt
        ? _quickMessageAge(
            message.firstAcknowledgement?.acknowledgedAt ?? message.raisedAt,
            DateTime.now(),
          )
        : '${describeQuickMessageOrigin(alert.origin, distanceUnit)} · '
              '${_quickMessageAge(message.raisedAt, DateTime.now())}';
    final action = receipt
        ? _QuickMessageActionButton(
            key: const Key('quick-message-receipt-dismiss'),
            label: 'OK',
            onPressed: onDismissReceipt,
            emphasised: false,
          )
        // An embedder with nowhere to record an acknowledgement gets no target
        // rather than a dead one, and the row still says who needs what.
        : onAcknowledge == null
        ? null
        : _QuickMessageActionButton(
            key: const Key('quick-message-acknowledge'),
            label: 'SEEN',
            busy: acknowledging,
            onPressed: acknowledging ? null : onAcknowledge,
            emphasised: critical,
          );
    return Semantics(
      container: true,
      liveRegion: true,
      label: '$headline. $detail.',
      child: Card(
        key: const Key('quick-message-alert'),
        color: fill,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: critical
              ? BorderSide.none
              : BorderSide(color: accent.withValues(alpha: 0.6)),
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 8 : 12,
            vertical: compact ? 6 : 8,
          ),
          child: Row(
            children: [
              Icon(
                receipt
                    ? Icons.visibility_rounded
                    : quickMessageIcon(message.message),
                color: accent,
                size: compact ? 22 : 26,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      headline,
                      key: const Key('quick-message-headline'),
                      // Two lines are free: the row's height is set by the
                      // glove-sized target beside it, not by the sentence.
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: compact ? 14 : 16,
                        height: 1.15,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    Text(
                      outstandingCount > 1 && !receipt
                          ? '$detail · +${outstandingCount - 1} more'
                          : detail,
                      key: const Key('quick-message-detail'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: const Color(0xFFE4E9EF),
                        fontSize: compact ? 12 : 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              if (action != null) ...[const SizedBox(width: 10), action],
            ],
          ),
        ),
      ),
    );
  }
}

/// A glove-sized target on a status card.
///
/// Fixed width in every state so a busy spinner replacing the word cannot change
/// what the card occupies, the same contract `_ActionLabel` keeps for the action
/// row (#142).
class _QuickMessageActionButton extends StatelessWidget {
  const _QuickMessageActionButton({
    super.key,
    required this.label,
    required this.onPressed,
    required this.emphasised,
    this.busy = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool emphasised;
  final bool busy;

  @override
  Widget build(BuildContext context) => Material(
    color: emphasised ? Colors.white : const Color(0xFF3B4757),
    borderRadius: BorderRadius.circular(12),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onPressed,
      child: SizedBox(
        width: 72,
        height: 48,
        child: Center(
          child: busy
              ? SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: emphasised ? const Color(0xFFC42741) : Colors.white,
                  ),
                )
              : Text(
                  label,
                  style: TextStyle(
                    color: emphasised
                        ? const Color(0xFFC42741)
                        : const Color(0xFFF2F5F8),
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.8,
                  ),
                ),
        ),
      ),
    ),
  );
}

/// The transient interrupt for a critical quick message.
///
/// Reserved for the critical band - an emergency stop or a rider asking for help
/// - because #104 allows a genuinely urgent alert to interrupt provided it is
/// transient and dismissible without fine interaction. Closing it leaves the
/// persistent row in the band, so nothing is lost either way, and acknowledging
/// from here is one large target: the rider who has just been interrupted should
/// not have to find a second control to answer.
class _QuickMessageInterruptOverlay extends StatelessWidget {
  const _QuickMessageInterruptOverlay({
    required this.alert,
    required this.distanceUnit,
    required this.acknowledging,
    required this.onAcknowledge,
    required this.onDismiss,
  });

  final RideQuickMessageAlert alert;
  final DistanceUnit distanceUnit;
  final bool acknowledging;
  final VoidCallback? onAcknowledge;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final message = alert.message;
    final origin = describeQuickMessageOrigin(alert.origin, distanceUnit);
    return Semantics(
      key: const Key('quick-message-interrupt'),
      container: true,
      liveRegion: true,
      label: '${message.headline}, $origin.',
      child: GestureDetector(
        onTap: onDismiss,
        behavior: HitTestBehavior.opaque,
        child: ColoredBox(
          // Fully opaque, like the enforcement warning: anything showing through
          // competes with the alert at the moment the rider has least attention
          // to spare.
          color: const Color(0xFF7A0E1E),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              // Reserving the action band (#177) took height away, and in
              // landscape the fixed icon and type overran what was left. The
              // alert scales into the space it has rather than overflowing it.
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      quickMessageIcon(message.message),
                      size: 64,
                      color: Colors.white,
                    ),
                    const SizedBox(height: 10),
                    FittedBox(
                      child: Text(
                        message.headline.toUpperCase(),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 40,
                          height: 1.05,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.8,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    FittedBox(
                      child: Text(
                        origin.toUpperCase(),
                        key: const Key('quick-message-interrupt-origin'),
                        style: const TextStyle(
                          // Secondary to the headline, unlike the enforcement
                          // warning where the distance *is* the actionable number.
                          // Here who and what outrank how far.
                          color: Color(0xF2FFFFFF),
                          fontSize: 30,
                          height: 1,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    if (onAcknowledge != null)
                      SizedBox(
                        height: 62,
                        width: 240,
                        child: FilledButton(
                          key: const Key('quick-message-interrupt-acknowledge'),
                          onPressed: acknowledging ? null : onAcknowledge,
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.white,
                            foregroundColor: const Color(0xFF7A0E1E),
                          ),
                          child: acknowledging
                              ? const SizedBox.square(
                                  dimension: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Color(0xFF7A0E1E),
                                  ),
                                )
                              : const Text(
                                  'I HAVE SEEN THIS',
                                  style: TextStyle(
                                    fontSize: 17,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 1,
                                  ),
                                ),
                        ),
                      ),
                    const SizedBox(height: 12),
                    const Text(
                      'TAP ANYWHERE TO DISMISS',
                      style: TextStyle(
                        color: Color(0x99FFFFFF),
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 2,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
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
      // Darker than the #E2445C it replaces, which left its own white text at
      // 4.03:1 - short of WCAG AA for body text, on the most urgent status
      // surface on the map. #C42741 takes that to 5.65:1 without touching the
      // hue, so the banner still reads as the same alert (#133).
      color: const Color(0xFFC42741),
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

/// The trend, as a shape and a word rather than a colour.
///
/// Never colour alone: riders wear tinted visors in direct sunlight - the
/// condition #107 and #143 exist for - and some riders cannot distinguish the
/// colours at all. Empty while the trend is unknown, so a leader is not told
/// something the app does not know (#181).
String _trendSuffix(TecGapTrend trend) =>
    trend == TecGapTrend.unknown ? '' : ' · ${trend.arrow} ${trend.label}';

class _TecGapCard extends StatelessWidget {
  const _TecGapCard({
    required this.status,
    required this.compact,
    required this.distanceUnit,
    this.trend = TecGapTrend.unknown,
  });

  final LeaderRideStatus status;
  final bool compact;
  final DistanceUnit distanceUnit;

  /// Which way the gap is going. A distance alone told a leader almost nothing
  /// - on a fast road 1.2 miles is normal, in town it means the group has split
  /// (#181).
  final TecGapTrend trend;

  @override
  Widget build(BuildContext context) {
    // Only reached once a TEC is registered: the map hides this surface for
    // TecAvailability.none. One branch per remaining state, so a TEC that has
    // never reported a position is never dressed up as a fresh or merely stale
    // one, and no state borrows an age it does not have.
    final formatter = MeasurementFormatter(distanceUnit);
    final name = status.tecName ?? 'Tail End Charlie';
    final distance = status.distanceToTecMeters;
    final eta = status.estimatedTimeToTec;
    final age = status.tecLocationAge;
    final detail = switch (status.tecAvailability) {
      TecAvailability.tracking when distance != null && eta != null =>
        '$name · ${formatter.distance(distance)} · about ${_durationLabel(eta)}'
            '${_trendSuffix(trend)}',
      TecAvailability.stale when age != null =>
        '$name · last update ${_ageLabel(age)}',
      _ => '$name · waiting for location',
    };
    if (compact) {
      final compactDetail = switch (status.tecAvailability) {
        TecAvailability.tracking when distance != null && eta != null =>
          '$name · ${formatter.distance(distance)} · ~${_durationLabel(eta)}'
              '${_trendSuffix(trend)}',
        TecAvailability.stale when age != null => '$name · ${_ageLabel(age)}',
        _ => '$name · waiting for location',
      };
      return Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Card(
            key: const Key('leader-tec-gap'),
            margin: EdgeInsets.zero,
            color: const Color(0xE6252E39),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                children: [
                  const Icon(
                    Icons.two_wheeler,
                    size: 18,
                    color: Color(0xFF6ED89A),
                  ),
                  const SizedBox(width: 7),
                  const Text(
                    'TEC',
                    style: TextStyle(
                      color: Color(0xFFB7C2CF),
                      fontWeight: FontWeight.w800,
                      fontSize: 11,
                      letterSpacing: 0.8,
                    ),
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      compactDetail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
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
      border: Border.all(color: RouteTrailStyle.casing, width: 2),
    ),
    // Dark, not white: see [RouteTrailStyle.markerGlyph]. Every hazard badge
    // fill is light, and the caution yellow measured 1.54:1 behind a white
    // glyph (#133).
    child: Icon(icon, color: RouteTrailStyle.markerGlyph, size: size * 0.56),
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

/// Shown on the map when a running ride has nobody holding the lead role (#176).
///
/// In the urgent run beside the paused banner rather than only in the roster: a
/// rider does not open the roster to discover a fact nobody told them, and a
/// leader leaving is a ride-wide event. The roster is where the role is taken.
class _NoLeaderBanner extends StatelessWidget {
  const _NoLeaderBanner();

  @override
  Widget build(BuildContext context) => Center(
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xE6252E39),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: const Color(0xFFFF8A6B)),
      ),
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.flag_outlined, color: Color(0xFFFF8A6B)),
            SizedBox(width: 8),
            Text(
              'NO RIDE LEADER',
              key: Key('no-leader-banner'),
              style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 0.7),
            ),
          ],
        ),
      ),
    ),
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
