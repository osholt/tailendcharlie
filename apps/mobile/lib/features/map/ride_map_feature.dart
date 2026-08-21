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
import 'package:vector_map_tiles/vector_map_tiles.dart' as vmt;

import '../../controllers/speed_limit_display_controller.dart';
import '../../controllers/shared_route_controller.dart';
import '../../controllers/personal_ride_heatmap_controller.dart';
import '../../controllers/global_ride_heatmap_controller.dart';
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
import '../../domain/rider_color.dart';
import '../../domain/route_authority.dart';
import '../../domain/route_store.dart';
import '../../internet/plan_directory.dart';
import '../../services/basemap_configuration.dart';
import '../../services/basemap_status.dart';
import '../../services/biker_place_catalogue.dart';
import '../../services/circular_ride_planner.dart';
import '../../services/demo_route_loader.dart';
import '../../services/discovery_layer_preferences.dart';
import '../../services/discovery_suggestion_queue.dart';
import '../../services/enforcement_alert_detector.dart';
import 'destination_search_field.dart';
import 'sheet_close_button.dart';
import 'ride_clock.dart';
import '../../services/enforcement_alert_presentation.dart';
import '../../services/fixed_speed_camera_catalogue.dart';
import '../../services/ride_completion_detector.dart';
import '../../services/gpx_import_source.dart';
import '../../services/global_ride_heatmap.dart';
import '../../services/group_pip_bridge.dart';
import '../../services/imported_track_matcher.dart';
import '../../services/leader_ride_status.dart';
import '../../services/tec_gap_trend.dart';
import '../../services/map_geojson.dart';
import '../../services/map_style_repository.dart';
import '../../services/maplibre_offline_manager.dart';
import '../../services/map_camera_command.dart';
import '../../services/measurement_formatter.dart';
import '../../services/navigation_guidance.dart';
import '../../services/stopped_speed_reading.dart';
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
import '../../services/route_journey_progress.dart';
import '../../services/route_progress.dart';
import '../../services/route_reshape_planner.dart';
import '../../services/speed_limit.dart';
import '../../services/stored_route_library.dart';
import '../../services/trail_direction_arrows.dart';
import 'destination_route_sheet.dart';
import 'circular_ride_sheet.dart';
import 'discovery_road_sheet.dart';
import 'hazard_map_symbol.dart';
import 'map_camera_guard.dart';
import 'maneuver_list_screen.dart';
import 'maneuver_symbol.dart';
import 'group_mini_map_framing.dart';
import 'motorcycle_icon.dart';
import 'navigation_export_sheet.dart';
import 'route_review_screen.dart';
import 'route_progress_panel.dart';
import 'route_trail_style.dart';
import 'smooth_countdown.dart';
import 'stored_route_picker.dart';

@visibleForTesting
GroupMiniMapRenderer groupMiniMapRenderer({
  required bool mapLibreEnabled,
  required TargetPlatform platform,
}) {
  if (!mapLibreEnabled) return GroupMiniMapRenderer.local;
  return platform == TargetPlatform.android
      ? GroupMiniMapRenderer.flutterVector
      : GroupMiniMapRenderer.mapLibre;
}

@visibleForTesting
enum GroupMiniMapRenderer {
  /// Route and riders on the deliberately simple offline overview.
  local,

  /// The existing native MapLibre mini-map used on iOS.
  mapLibre,

  /// A Flutter-rendered copy of the configured vector style on Android.
  ///
  /// Android cannot reliably composite two MapLibre platform views on one
  /// screen (#29). Rendering the same vector source through Flutter keeps the
  /// mini-map inside the Flutter layer tree instead of mounting a second native
  /// surface.
  flutterVector,
}

enum _ImportedTrackChoice { cancel, followOriginal, generateNavigable }

/// Whether to offer to turn an import into a navigable route.
///
/// This required **every** drawable path to be a track, so a file carrying a
/// `<trk>` alongside a `<rte>` was silently offered nothing at all — no dialog,
/// no explanation, just a raw line. That is the quiet half of #575, and #574
/// only fixed it for the one export whose duplicate `<rte>` is now dropped; a
/// file with a genuinely different route beside its track still hit it.
///
/// The matcher matches track paths and leaves the rest alone, so the honest
/// question is whether there is a track to match, not whether the file contains
/// nothing else.
///
/// Top-level so the decision can be asserted without standing up the map — the
/// widget-test route into this screen cannot reach the import dialog.
@visibleForTesting
bool canGenerateNavigableRoute(ImportedRoute route) =>
    route.maneuvers.isEmpty &&
    route.paths.any(
      (path) => path.kind == RoutePathKind.track && path.points.length >= 2,
    );

/// Discovery roads and cafés are useful at local riding scale and turn into a
/// dense national overlay when the map is zoomed out. Hide them below this
/// threshold while preserving every saved layer choice.
@visibleForTesting
const motorcycleDiscoveryMinimumZoom = 12.5;

@visibleForTesting
bool motorcycleDiscoveryVisibleAtZoom(double zoom) =>
    zoom >= motorcycleDiscoveryMinimumZoom;

/// Top-band chrome a host screen hands to the map instead of drawing itself.
///
/// The free-roam home screen used to paint its own search field and its own
/// action row *on top of* this map's `AppBar`, in the same corner of the same
/// safe area, from a different widget tree. Both were rendered and only the
/// later one could be tapped, so the discovery-layer menu sat under the
/// settings button and was reachable by an uncovered sliver or not at all
/// (#572), and the icons read as overlapping junk (#573).
///
/// Supplying them here gives the top band exactly one owner. Nothing about the
/// host's arrangement is inferred: it says what it wants shown, and the map
/// composes it with its own actions in one row.
class HostMapChrome {
  const HostMapChrome({
    required this.title,
    this.actions = const [],
    this.bottomInset = 0,
    this.onMore,
  });

  /// Height the host's own chrome occupies at the bottom of this map.
  ///
  /// Home leaves this at zero. Other hosts can reserve space here so the map
  /// keeps its compass and controls clear of their bottom chrome.
  final double bottomInset;

  /// Stands in for the map's own title — a search field, in free roam.
  ///
  /// A host that supplies this is also supplying the rider's way to a
  /// destination, so the map drops its own `Plan a destination` and
  /// `Import GPX` buttons rather than crowding a second entry in beside it.
  /// Both remain in the overflow menu.
  final Widget title;

  /// Appended after the map's own actions, in the order given.
  final List<Widget> actions;

  /// Opens host-owned secondary actions from the map's existing overflow.
  final VoidCallback? onMore;
}

/// Height of the map's own toolbar, by orientation.
///
/// Public because a host that stands content clear of the AppBar has to
/// measure the band the map actually drew. Two copies of `52` in two files
/// is how content ends up half under a toolbar.
double rideMapToolbarHeight({required bool landscape}) => landscape ? 42 : 52;

/// Above this many waypoints on one route, they are the shape of the line
/// rather than a list of places somebody chose.
@visibleForTesting
const denseWaypointThreshold = 60;

/// How a route's waypoints are drawn, given how many of them there are.
///
/// A handful of chosen stops are places, and a place deserves a badge big
/// enough to read and to hit. Several hundred are geometry, and at badge size
/// they cover the very road they describe — which is how a 296 km import
/// became an unreadable carpet of yellow when zoomed out (#574).
///
/// This is the general case, and it holds for a file from any tool. The
/// specific fault behind that import — Garmin leg geometry read as waypoints —
/// is fixed in `GpxParser`; a file that genuinely carries hundreds of chosen
/// stops still has to stay legible, and this is what keeps it so.
@visibleForTesting
({double radius, double opacity}) waypointCircleStyle(int count) =>
    count > denseWaypointThreshold
    ? (radius: 3.5, opacity: 0.7)
    : (radius: 7, opacity: 1);

/// Hard ceiling on waypoints handed to either renderer in one frame.
///
/// Not a judgement about legibility — [waypointCircleStyle] makes that one —
/// but a bound on how much geometry a single frame pushes. It was already here
/// as a bare `.take(500)` in two places; naming it keeps the two renderers
/// agreeing about what they dropped.
const _renderedWaypointLimit = 500;

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

/// The moving portrait menu belongs in the top-leading corner.
///
/// Shared with [ActiveRideShell], which owns this button during a real ride.
/// Keeping it in the first row makes the way to Settings visible in both an
/// active ride and free-roam navigation; placing it below the ETA card made it
/// look like part of the trip summary and left some navigation states with no
/// discoverable escape at all.
const double portraitRideMenuTopOffset = 12;

/// ETA and the group overview start below the persistent top navigation row.
///
/// The row above them carries menu, clock and speed/compass. A fixed offset
/// keeps those three controls at the top without allowing either header card to
/// slide underneath them as its contents change.
@visibleForTesting
const double portraitNavigationHeaderTopOffset = 154;

/// Turn and TEC panes retain strong contrast while allowing some map context
/// through them. Progress, actions and the mini-map keep their denser fills.
@visibleForTesting
const Color rideMapPrimaryPanelFill = Color(0xD9252E39);

/// Width available to the bottom-trailing landscape guidance card.
///
/// The card sits below the rider badge, so it may extend a little past the
/// rider's horizontal anchor without covering either the badge or the road
/// ahead. This keeps full road names readable on notched phones (#533).
@visibleForTesting
double landscapeGuidancePanelWidth({
  required double viewportWidth,
  required double safeRight,
  required bool leftHandTraffic,
}) {
  final riderFraction = leftHandTraffic
      ? navigationCameraLandscapeRiderFractionLeftTraffic
      : navigationCameraLandscapeRiderFractionRightTraffic;
  final riderX = viewportWidth * riderFraction;
  final trailingEdge = viewportWidth - safeRight - 10;
  final available = trailingEdge - riderX + 64;
  return available.clamp(220.0, 320.0).toDouble();
}

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
    this.rejoinNavigationRoute,
    this.leaderStatus,
    this.tecGapTrend,
    this.groupRiderCount,
    this.onOpenRoster,
    this.junctionMarkerOverlay,
    this.enforcementAlert,
    this.rideCompletionSuggestion,
    this.onEndRideForEveryone,
    this.onDismissRideCompletion,
    this.quickMessageAlerts,
    this.onAcknowledgeQuickMessage,
    this.dismissedQuickMessageInterruptIds = const {},
    this.dismissedQuickMessageReceiptIds = const {},
    this.onDismissQuickMessageInterrupt,
    this.onDismissQuickMessageReceipt,
    this.dismissedEnforcementAlertId,
    this.onDismissEnforcementAlert,
    this.initialRouteStartConnector,
    this.onRouteStartConnectorChanged,
    this.onReportHazard,
    this.emergencyContacts = const [],
    this.onEmergencyAlert,
    this.onEmergencyIssue,
    this.onEmergencyContactUsed,
    this.ridePaused = false,
    this.rideHasNoLeader = false,
    this.rideStarted = false,
    this.markerFeaturesEnabled = true,
    this.onLeaveRide,
    this.onOpenRideMenu,
    this.onRouteChanged,
    this.onRouteCommitted,
    this.onNavigationGuidanceChanged,
    this.onNavigationViewportChanged,
    this.onMapStyleResolved,
    this.changeRouteRequestToken,
    this.onChangeRouteRequestHandled,
    this.circularRideRequestToken,
    this.onCircularRideRequestHandled,
    this.pendingSharedGpxFile,
    this.pendingInAppRoute,
    this.acquireCurrentPosition,
    this.navigationExportCoordinator,
    this.routeStore,
    this.routeAuthority = RouteAuthority.leader,
    this.navigating,
    this.hostChrome,
    this.offlineTileCache,
    this.mapLibreOfflineManager,
    this.mapStyleString,
    this.completedRideStore,
    this.personalRideHeatmap,
    this.globalRideHeatmap,
    this.distanceUnit = DistanceUnit.kilometres,
    this.speedLimitDisplay,
    this.showRouteProgress = true,
    this.basemapConfiguration = const BasemapConfiguration(),
    this.localMotorcycleStyle = motorcycleIconStyleDefault,
    this.localRiderSymbol = riderSymbolDefault,
    this.localDisplayName = 'You',
    this.localBadgeColor = const Color(0xFF2F80ED),
  });

  factory RideMapFeature.fromEnvironment({
    Key? key,
    ValueListenable<GeoPoint?>? currentPosition,
    ValueListenable<MapNavigationPosition?>? navigationPosition,
    ValueListenable<List<MapOverlayMarker>>? overlayMarkers,
    ValueListenable<List<MapOverlayTrace>>? riderTrails,
    ValueListenable<ImportedRoute?>? rejoinNavigationRoute,
    ValueListenable<LeaderRideStatus?>? leaderStatus,
    ValueListenable<TecGapTrend>? tecGapTrend,
    int? groupRiderCount,
    VoidCallback? onOpenRoster,
    ValueListenable<MapJunctionMarkerOverlay?>? junctionMarkerOverlay,
    ValueListenable<EnforcementAlert?>? enforcementAlert,
    ValueListenable<RideCompletionAssessment?>? rideCompletionSuggestion,
    VoidCallback? onEndRideForEveryone,
    VoidCallback? onDismissRideCompletion,
    ValueListenable<List<RideQuickMessageAlert>>? quickMessageAlerts,
    Future<void> Function(ReceivedQuickMessage message)?
    onAcknowledgeQuickMessage,
    Set<String> dismissedQuickMessageInterruptIds = const {},
    Set<String> dismissedQuickMessageReceiptIds = const {},
    ValueChanged<String>? onDismissQuickMessageInterrupt,
    ValueChanged<String>? onDismissQuickMessageReceipt,
    String? dismissedEnforcementAlertId,
    ValueChanged<String>? onDismissEnforcementAlert,
    ImportedRoute? initialRouteStartConnector,
    ValueChanged<ImportedRoute?>? onRouteStartConnectorChanged,
    Future<void> Function(HazardType type)? onReportHazard,
    List<MapEmergencyContact> emergencyContacts = const [],
    Future<void> Function()? onEmergencyAlert,
    Future<void> Function(QuickMessage message)? onEmergencyIssue,
    void Function(MapEmergencyContact contact)? onEmergencyContactUsed,
    bool ridePaused = false,
    bool rideHasNoLeader = false,
    bool rideStarted = false,
    bool markerFeaturesEnabled = true,
    Future<void> Function()? onLeaveRide,
    Future<void> Function()? onOpenRideMenu,
    ValueChanged<ImportedRoute?>? onRouteChanged,
    ValueChanged<ImportedRoute?>? onRouteCommitted,
    ValueChanged<NavigationGuidance?>? onNavigationGuidanceChanged,
    ValueChanged<NavigationCameraViewport>? onNavigationViewportChanged,
    ValueChanged<String>? onMapStyleResolved,
    Object? changeRouteRequestToken,
    VoidCallback? onChangeRouteRequestHandled,
    Object? circularRideRequestToken,
    VoidCallback? onCircularRideRequestHandled,
    PickedGpxFile? pendingSharedGpxFile,
    PendingInAppRoute? pendingInAppRoute,
    Future<GeoPoint?> Function()? acquireCurrentPosition,
    RouteStore? routeStore,
    CompletedRideStore? completedRideStore,
    PersonalRideHeatmapController? personalRideHeatmap,
    GlobalRideHeatmapController? globalRideHeatmap,
    RouteAuthority routeAuthority = RouteAuthority.leader,
    bool? navigating,
    HostMapChrome? hostChrome,
    DistanceUnit distanceUnit = DistanceUnit.kilometres,
    SpeedLimitDisplayController? speedLimitDisplay,
    bool showRouteProgress = true,
    bool darkMapStyle = false,
    bool restrainedLightMapStyle = true,
    MotorcycleIconStyle localMotorcycleStyle = motorcycleIconStyleDefault,
    RiderSymbol localRiderSymbol = riderSymbolDefault,
    String localDisplayName = 'You',
    Color localBadgeColor = const Color(0xFF2F80ED),
  }) => RideMapFeature(
    key: key,
    currentPosition: currentPosition,
    navigationPosition: navigationPosition,
    overlayMarkers: overlayMarkers,
    riderTrails: riderTrails,
    rejoinNavigationRoute: rejoinNavigationRoute,
    leaderStatus: leaderStatus,
    tecGapTrend: tecGapTrend,
    groupRiderCount: groupRiderCount,
    onOpenRoster: onOpenRoster,
    junctionMarkerOverlay: junctionMarkerOverlay,
    enforcementAlert: enforcementAlert,
    rideCompletionSuggestion: rideCompletionSuggestion,
    onEndRideForEveryone: onEndRideForEveryone,
    onDismissRideCompletion: onDismissRideCompletion,
    quickMessageAlerts: quickMessageAlerts,
    onAcknowledgeQuickMessage: onAcknowledgeQuickMessage,
    dismissedQuickMessageInterruptIds: dismissedQuickMessageInterruptIds,
    dismissedQuickMessageReceiptIds: dismissedQuickMessageReceiptIds,
    dismissedEnforcementAlertId: dismissedEnforcementAlertId,
    onDismissEnforcementAlert: onDismissEnforcementAlert,
    initialRouteStartConnector: initialRouteStartConnector,
    onRouteStartConnectorChanged: onRouteStartConnectorChanged,
    onDismissQuickMessageInterrupt: onDismissQuickMessageInterrupt,
    onDismissQuickMessageReceipt: onDismissQuickMessageReceipt,
    onReportHazard: onReportHazard,
    emergencyContacts: emergencyContacts,
    onEmergencyAlert: onEmergencyAlert,
    onEmergencyIssue: onEmergencyIssue,
    onEmergencyContactUsed: onEmergencyContactUsed,
    ridePaused: ridePaused,
    rideHasNoLeader: rideHasNoLeader,
    rideStarted: rideStarted,
    markerFeaturesEnabled: markerFeaturesEnabled,
    onLeaveRide: onLeaveRide,
    onOpenRideMenu: onOpenRideMenu,
    onRouteChanged: onRouteChanged,
    onRouteCommitted: onRouteCommitted,
    onNavigationGuidanceChanged: onNavigationGuidanceChanged,
    onNavigationViewportChanged: onNavigationViewportChanged,
    onMapStyleResolved: onMapStyleResolved,
    changeRouteRequestToken: changeRouteRequestToken,
    onChangeRouteRequestHandled: onChangeRouteRequestHandled,
    circularRideRequestToken: circularRideRequestToken,
    onCircularRideRequestHandled: onCircularRideRequestHandled,
    pendingSharedGpxFile: pendingSharedGpxFile,
    pendingInAppRoute: pendingInAppRoute,
    acquireCurrentPosition: acquireCurrentPosition,
    routeStore: routeStore,
    completedRideStore: completedRideStore,
    personalRideHeatmap: personalRideHeatmap,
    globalRideHeatmap: globalRideHeatmap,
    routeAuthority: routeAuthority,
    navigating: navigating,
    hostChrome: hostChrome,
    distanceUnit: distanceUnit,
    speedLimitDisplay: speedLimitDisplay,
    showRouteProgress: showRouteProgress,
    basemapConfiguration: BasemapConfiguration.fromEnvironment().forBrightness(
      dark: darkMapStyle,
      restrainedLightStyle: restrainedLightMapStyle,
    ),
    localMotorcycleStyle: localMotorcycleStyle,
    localRiderSymbol: localRiderSymbol,
    localDisplayName: localDisplayName,
    localBadgeColor: localBadgeColor,
  );

  final ValueListenable<GeoPoint?>? currentPosition;
  final ValueListenable<MapNavigationPosition?>? navigationPosition;
  final ValueListenable<List<MapOverlayMarker>>? overlayMarkers;
  final ValueListenable<List<MapOverlayTrace>>? riderTrails;
  final ValueListenable<ImportedRoute?>? rejoinNavigationRoute;
  final ValueListenable<LeaderRideStatus?>? leaderStatus;

  /// Which way the gap to the TEC is going (#181). Null where no trend is
  /// tracked, in which case the gap card shows the distance alone.
  final ValueListenable<TecGapTrend>? tecGapTrend;
  final int? groupRiderCount;
  final VoidCallback? onOpenRoster;
  final ValueListenable<MapJunctionMarkerOverlay?>? junctionMarkerOverlay;
  final ValueListenable<EnforcementAlert?>? enforcementAlert;

  /// The arrival the group has reached, offered rather than imposed (#380).
  ///
  /// Null whenever there is nothing to suggest, which includes a suggestion the
  /// rider has already waved away.
  final ValueListenable<RideCompletionAssessment?>? rideCompletionSuggestion;

  /// Ending for everyone is irreversible for the group, so this raises the
  /// confirmation carrying `endRideConsequence` rather than ending outright.
  final VoidCallback? onEndRideForEveryone;

  final VoidCallback? onDismissRideCompletion;

  /// Quick messages other riders have raised, most urgent first, together with
  /// where each sender is (#151). Null when the embedder has no ride behind it.
  final ValueListenable<List<RideQuickMessageAlert>>? quickMessageAlerts;

  /// Records that this rider has seen a quick message, so its sender is told.
  final Future<void> Function(ReceivedQuickMessage message)?
  onAcknowledgeQuickMessage;
  final Set<String> dismissedQuickMessageInterruptIds;
  final Set<String> dismissedQuickMessageReceiptIds;
  final ValueChanged<String>? onDismissQuickMessageInterrupt;
  final ValueChanged<String>? onDismissQuickMessageReceipt;

  /// Held by the ride shell, not by this widget, because the shell outlives a
  /// tab change and this widget does not (#282).
  ///
  /// The active-ride tabs are a `switch` on the selected index rather than an
  /// IndexedStack - deliberately, so a MapLibre view is not left composing
  /// behind another tab - so moving to Ride details and back **disposes and
  /// rebuilds this widget**. Anything a rider has decided that lives in local
  /// `State` is therefore silently undone by a tab change, which is what a
  /// tester hit: cleared alerts returning, and an accepted route-start leg
  /// having to be accepted again.
  final String? dismissedEnforcementAlertId;
  final ValueChanged<String>? onDismissEnforcementAlert;

  /// The routed "navigate to start" leg the rider has already accepted (#262),
  /// seeded from the shell so accepting it survives a tab change.
  final ImportedRoute? initialRouteStartConnector;
  final ValueChanged<ImportedRoute?>? onRouteStartConnectorChanged;
  final Future<void> Function(HazardType type)? onReportHazard;
  final List<MapEmergencyContact> emergencyContacts;
  final Future<void> Function()? onEmergencyAlert;
  final Future<void> Function(QuickMessage message)? onEmergencyIssue;

  /// Called when the rider dials or texts a shared number (#188).
  final void Function(MapEmergencyContact contact)? onEmergencyContactUsed;
  final bool ridePaused;
  final bool rideHasNoLeader;
  final bool rideStarted;
  final bool markerFeaturesEnabled;
  final Future<void> Function()? onLeaveRide;
  final Future<void> Function()? onOpenRideMenu;
  final ValueChanged<ImportedRoute?>? onRouteChanged;
  final ValueChanged<ImportedRoute?>? onRouteCommitted;
  final ValueChanged<NavigationGuidance?>? onNavigationGuidanceChanged;
  final ValueChanged<NavigationCameraViewport>? onNavigationViewportChanged;
  final ValueChanged<String>? onMapStyleResolved;
  final Object? changeRouteRequestToken;
  final VoidCallback? onChangeRouteRequestHandled;
  final Object? circularRideRequestToken;
  final VoidCallback? onCircularRideRequestHandled;
  final PickedGpxFile? pendingSharedGpxFile;
  final PendingInAppRoute? pendingInAppRoute;
  final Future<GeoPoint?> Function()? acquireCurrentPosition;
  final NavigationExportCoordinator? navigationExportCoordinator;
  final RouteStore? routeStore;

  /// Whose route this surface is showing. See [RouteAuthority] — free roam is
  /// [RouteAuthority.personal] and has no leader to defer to (#576).
  final RouteAuthority routeAuthority;

  /// Whether this surface may build or replace the route it shows.
  bool get canEditRoute => routeAuthority.canEditRoute;

  /// Whether the rider is following a route right now. See the field of the
  /// same name on [RideMapScreen] — null means "whatever the ride is doing".
  final bool? navigating;

  /// Top-band chrome the host draws through this map rather than over it.
  /// See [HostMapChrome] — null means the map owns its own title and actions.
  final HostMapChrome? hostChrome;
  final OfflineTileCache? offlineTileCache;
  final MapLibreOfflineManager? mapLibreOfflineManager;
  final String? mapStyleString;
  final CompletedRideStore? completedRideStore;
  final PersonalRideHeatmapController? personalRideHeatmap;
  final GlobalRideHeatmapController? globalRideHeatmap;
  final DistanceUnit distanceUnit;
  final SpeedLimitDisplayController? speedLimitDisplay;
  final bool showRouteProgress;
  final BasemapConfiguration basemapConfiguration;
  final MotorcycleIconStyle localMotorcycleStyle;
  final RiderSymbol localRiderSymbol;
  final String localDisplayName;
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
      widget.onMapStyleResolved?.call(suppliedStyle);
      return _MapDependencies(
        store: suppliedStore,
        cache: suppliedCache,
        mapLibreOfflineManager:
            widget.mapLibreOfflineManager ??
            MapLibreOfflineManager(configuration: widget.basemapConfiguration),
        mapStyleString: suppliedStyle,
        // An embedder handing over a style vouches for it; there is no fetch
        // here whose outcome could be reported.
        mapStyleOutcome: MapStyleOutcome.live,
      );
    }
    final styleRepository = await MapStyleRepository.openDefault(
      widget.basemapConfiguration,
    );
    try {
      final resolution = suppliedStyle == null
          ? await styleRepository.resolve()
          : MapStyleResolution(suppliedStyle, MapStyleOutcome.live);
      widget.onMapStyleResolved?.call(resolution.style);
      return _MapDependencies(
        store: suppliedStore ?? await JsonFileRouteStore.openDefault(),
        cache:
            suppliedCache ??
            await OfflineTileCache.openDefault(widget.basemapConfiguration),
        mapLibreOfflineManager:
            widget.mapLibreOfflineManager ??
            MapLibreOfflineManager(configuration: widget.basemapConfiguration),
        mapStyleString: resolution.style,
        mapStyleOutcome: resolution.outcome,
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
        mapStyleOutcome: dependencies.mapStyleOutcome,
        completedRideStore: widget.completedRideStore,
        personalRideHeatmap: widget.personalRideHeatmap,
        globalRideHeatmap: widget.globalRideHeatmap,
        disposeOfflineTileCache: widget.offlineTileCache == null,
        currentPosition: widget.currentPosition,
        navigationPosition: widget.navigationPosition,
        overlayMarkers: widget.overlayMarkers,
        riderTrails: widget.riderTrails,
        rejoinNavigationRoute: widget.rejoinNavigationRoute,
        leaderStatus: widget.leaderStatus,
        tecGapTrend: widget.tecGapTrend,
        groupRiderCount: widget.groupRiderCount,
        onOpenRoster: widget.onOpenRoster,
        junctionMarkerOverlay: widget.junctionMarkerOverlay,
        enforcementAlert: widget.enforcementAlert,
        rideCompletionSuggestion: widget.rideCompletionSuggestion,
        onEndRideForEveryone: widget.onEndRideForEveryone,
        onDismissRideCompletion: widget.onDismissRideCompletion,
        quickMessageAlerts: widget.quickMessageAlerts,
        onAcknowledgeQuickMessage: widget.onAcknowledgeQuickMessage,
        dismissedQuickMessageInterruptIds:
            widget.dismissedQuickMessageInterruptIds,
        dismissedQuickMessageReceiptIds: widget.dismissedQuickMessageReceiptIds,
        dismissedEnforcementAlertId: widget.dismissedEnforcementAlertId,
        onDismissEnforcementAlert: widget.onDismissEnforcementAlert,
        initialRouteStartConnector: widget.initialRouteStartConnector,
        onRouteStartConnectorChanged: widget.onRouteStartConnectorChanged,
        onDismissQuickMessageInterrupt: widget.onDismissQuickMessageInterrupt,
        onDismissQuickMessageReceipt: widget.onDismissQuickMessageReceipt,
        onReportHazard: widget.onReportHazard,
        emergencyContacts: widget.emergencyContacts,
        onEmergencyAlert: widget.onEmergencyAlert,
        onEmergencyIssue: widget.onEmergencyIssue,
        onEmergencyContactUsed: widget.onEmergencyContactUsed,
        ridePaused: widget.ridePaused,
        rideHasNoLeader: widget.rideHasNoLeader,
        rideStarted: widget.rideStarted,
        markerFeaturesEnabled: widget.markerFeaturesEnabled,
        onLeaveRide: widget.onLeaveRide,
        onOpenRideMenu: widget.onOpenRideMenu,
        routeAuthority: widget.routeAuthority,
        navigating: widget.navigating,
        hostChrome: widget.hostChrome,
        onRouteChanged: widget.onRouteChanged,
        onRouteCommitted: widget.onRouteCommitted,
        onNavigationGuidanceChanged: widget.onNavigationGuidanceChanged,
        onNavigationViewportChanged: widget.onNavigationViewportChanged,
        changeRouteRequestToken: widget.changeRouteRequestToken,
        onChangeRouteRequestHandled: widget.onChangeRouteRequestHandled,
        circularRideRequestToken: widget.circularRideRequestToken,
        onCircularRideRequestHandled: widget.onCircularRideRequestHandled,
        pendingSharedGpxFile: widget.pendingSharedGpxFile,
        pendingInAppRoute: widget.pendingInAppRoute,
        acquireCurrentPosition: widget.acquireCurrentPosition,
        navigationExportCoordinator: widget.navigationExportCoordinator,
        distanceUnit: widget.distanceUnit,
        speedLimitDisplay: widget.speedLimitDisplay,
        showRouteProgress: widget.showRouteProgress,
        localMotorcycleStyle: widget.localMotorcycleStyle,
        localRiderSymbol: widget.localRiderSymbol,
        localDisplayName: widget.localDisplayName,
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
    required this.mapStyleOutcome,
  });

  final RouteStore store;
  final OfflineTileCache cache;
  final MapLibreOfflineManager mapLibreOfflineManager;
  final String mapStyleString;
  final MapStyleOutcome mapStyleOutcome;
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
    this.mapStyleOutcome = MapStyleOutcome.live,
    this.basemapTileProbe = const BasemapTileProbe(),
    this.currentPosition,
    this.navigationPosition,
    this.overlayMarkers,
    this.riderTrails,
    this.rejoinNavigationRoute,
    this.leaderStatus,
    this.tecGapTrend,
    this.groupRiderCount,
    this.onOpenRoster,
    this.junctionMarkerOverlay,
    this.enforcementAlert,
    this.rideCompletionSuggestion,
    this.onEndRideForEveryone,
    this.onDismissRideCompletion,
    this.quickMessageAlerts,
    this.onAcknowledgeQuickMessage,
    this.dismissedQuickMessageInterruptIds = const {},
    this.dismissedQuickMessageReceiptIds = const {},
    this.dismissedEnforcementAlertId,
    this.onDismissEnforcementAlert,
    this.initialRouteStartConnector,
    this.onRouteStartConnectorChanged,
    this.onDismissQuickMessageInterrupt,
    this.onDismissQuickMessageReceipt,
    this.onReportHazard,
    this.emergencyContacts = const [],
    this.onEmergencyAlert,
    this.onEmergencyIssue,
    this.onEmergencyContactUsed,
    this.ridePaused = false,
    this.rideHasNoLeader = false,
    // This injectable screen represents an active map unless a focused test or
    // embedder says otherwise. RideMapFeature always passes the real lifecycle
    // value, including false during assembly.
    this.rideStarted = true,
    this.markerFeaturesEnabled = true,
    this.onLeaveRide,
    this.onOpenRideMenu,
    this.routeAuthority = RouteAuthority.leader,
    this.navigating,
    this.hostChrome,
    this.onRouteChanged,
    this.onRouteCommitted,
    this.onNavigationGuidanceChanged,
    this.onNavigationViewportChanged,
    this.changeRouteRequestToken,
    this.onChangeRouteRequestHandled,
    this.circularRideRequestToken,
    this.onCircularRideRequestHandled,
    this.pendingSharedGpxFile,
    this.pendingInAppRoute,
    this.acquireCurrentPosition,
    this.navigationExportCoordinator,
    this.destinationRoutePlanner,
    this.roadRoutingService,
    this.routeGeometryEnricher,
    this.importedTrackMatcher,
    this.demoRouteLoader,
    this.recordedRouteStore,
    this.completedRideStore,
    this.personalRideHeatmap,
    this.globalRideHeatmap,
    this.storedRouteLibrary,
    this.discoveryCatalogueLoader,
    this.bikerPlaceCatalogueLoader,
    this.distanceUnit = DistanceUnit.kilometres,
    this.speedLimitDisplay,
    this.showRouteProgress = true,
    this.disposeOfflineTileCache = false,
    this.localMotorcycleStyle = motorcycleIconStyleDefault,
    this.localRiderSymbol = riderSymbolDefault,
    this.localDisplayName = 'You',
    this.localBadgeColor = const Color(0xFF2F80ED),
  });

  final RouteStore routeStore;
  final RouteImporter routeImporter;
  final PlanDirectory? planDirectory;
  final OfflineTileCache offlineTileCache;
  final MapLibreOfflineManager? mapLibreOfflineManager;
  final String mapStyleString;

  /// Where [mapStyleString] came from, so the map can tell a rider that its
  /// background is missing instead of presenting an empty one as the map
  /// (#281).
  final MapStyleOutcome mapStyleOutcome;

  /// Checks the tile endpoint once the view reports the style loaded, which is
  /// the only way this app learns that tiles are not arriving — the native
  /// engine fetches them and reports nothing back.
  final BasemapTileProbe basemapTileProbe;

  final ValueListenable<GeoPoint?>? currentPosition;
  final ValueListenable<MapNavigationPosition?>? navigationPosition;
  final ValueListenable<List<MapOverlayMarker>>? overlayMarkers;
  final ValueListenable<List<MapOverlayTrace>>? riderTrails;
  final ValueListenable<ImportedRoute?>? rejoinNavigationRoute;
  final ValueListenable<LeaderRideStatus?>? leaderStatus;

  /// Which way the gap to the TEC is going (#181). Null where no trend is
  /// tracked, in which case the gap card shows the distance alone.
  final ValueListenable<TecGapTrend>? tecGapTrend;
  final int? groupRiderCount;
  final VoidCallback? onOpenRoster;
  final ValueListenable<MapJunctionMarkerOverlay?>? junctionMarkerOverlay;
  final ValueListenable<EnforcementAlert?>? enforcementAlert;

  /// The arrival the group has reached, offered rather than imposed (#380).
  ///
  /// Null whenever there is nothing to suggest, which includes a suggestion the
  /// rider has already waved away.
  final ValueListenable<RideCompletionAssessment?>? rideCompletionSuggestion;

  /// Ending for everyone is irreversible for the group, so this raises the
  /// confirmation carrying `endRideConsequence` rather than ending outright.
  final VoidCallback? onEndRideForEveryone;

  final VoidCallback? onDismissRideCompletion;

  /// Quick messages other riders have raised, most urgent first, together with
  /// where each sender is (#151). Null when the embedder has no ride behind it.
  final ValueListenable<List<RideQuickMessageAlert>>? quickMessageAlerts;

  /// Records that this rider has seen a quick message, so its sender is told.
  final Future<void> Function(ReceivedQuickMessage message)?
  onAcknowledgeQuickMessage;
  final Set<String> dismissedQuickMessageInterruptIds;
  final Set<String> dismissedQuickMessageReceiptIds;

  /// Held by the ride shell rather than by this widget, because a tab change
  /// disposes this widget and the shell survives it (#282).
  final String? dismissedEnforcementAlertId;
  final ValueChanged<String>? onDismissEnforcementAlert;
  final ImportedRoute? initialRouteStartConnector;
  final ValueChanged<ImportedRoute?>? onRouteStartConnectorChanged;
  final ValueChanged<String>? onDismissQuickMessageInterrupt;
  final ValueChanged<String>? onDismissQuickMessageReceipt;
  final Future<void> Function(HazardType type)? onReportHazard;
  final List<MapEmergencyContact> emergencyContacts;
  final Future<void> Function()? onEmergencyAlert;
  final Future<void> Function(QuickMessage message)? onEmergencyIssue;

  /// Called when the rider dials or texts a shared number, so the embedder can
  /// mark that share as used and keep it past the ride-end purge (#188).
  final void Function(MapEmergencyContact contact)? onEmergencyContactUsed;
  final bool ridePaused;
  final bool rideHasNoLeader;
  final bool rideStarted;
  final bool markerFeaturesEnabled;
  final Future<void> Function()? onLeaveRide;
  final Future<void> Function()? onOpenRideMenu;

  /// Whose route this surface is showing. See [RouteAuthority].
  final RouteAuthority routeAuthority;

  /// Whether this surface may build or replace the route it shows.
  bool get canEditRoute => routeAuthority.canEditRoute;

  /// Whether the rider is following a route right now.
  ///
  /// **Distinct from [rideStarted], and that distinction is the point (#600).**
  /// The two were one flag, so everything a navigating rider needs — turn
  /// guidance, the follow camera, the posted speed limit, the clock, directions
  /// to a distant route start — was reachable only inside a ride. Free roam
  /// could hold a route and draw it, and do nothing else with it. That is why
  /// searching a destination had to create a ride first: the ride was carrying
  /// the navigation, not the route.
  ///
  /// What stays on [rideStarted] is what genuinely needs a group: SOS and
  /// hazard reporting both relay to other riders, and mean nothing alone.
  ///
  /// Null means "whatever the ride is doing", which is what every caller meant
  /// before free roam could navigate at all — so this changes nothing until a
  /// surface opts in.
  final bool? navigating;

  /// Resolved: following a route, whether or not a ride is running.
  bool get isNavigating => navigating ?? rideStarted;

  /// Top-band chrome the host draws through this map. See [HostMapChrome].
  final HostMapChrome? hostChrome;
  final ValueChanged<ImportedRoute?>? onRouteChanged;
  final ValueChanged<ImportedRoute?>? onRouteCommitted;
  final ValueChanged<NavigationGuidance?>? onNavigationGuidanceChanged;
  final ValueChanged<NavigationCameraViewport>? onNavigationViewportChanged;
  final Object? changeRouteRequestToken;
  final VoidCallback? onChangeRouteRequestHandled;
  final Object? circularRideRequestToken;
  final VoidCallback? onCircularRideRequestHandled;
  final PickedGpxFile? pendingSharedGpxFile;
  final PendingInAppRoute? pendingInAppRoute;
  final Future<GeoPoint?> Function()? acquireCurrentPosition;
  final NavigationExportCoordinator? navigationExportCoordinator;
  final DestinationRoutePlanner? destinationRoutePlanner;
  final RoadRoutingService? roadRoutingService;
  final RouteGeometryEnricher? routeGeometryEnricher;
  final ImportedTrackMatcher? importedTrackMatcher;
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
  final PersonalRideHeatmapController? personalRideHeatmap;
  final GlobalRideHeatmapController? globalRideHeatmap;

  /// A fully assembled library, for tests that want to fix the identity and
  /// timestamp of the route it produces.
  final StoredRouteLibrary? storedRouteLibrary;
  final Future<MotorcycleDiscoveryCatalogue> Function()?
  discoveryCatalogueLoader;
  final Future<BikerPlaceCatalogue> Function()? bikerPlaceCatalogueLoader;

  final DistanceUnit distanceUnit;
  final SpeedLimitDisplayController? speedLimitDisplay;
  final bool showRouteProgress;
  final bool disposeOfflineTileCache;
  final MotorcycleIconStyle localMotorcycleStyle;
  final RiderSymbol localRiderSymbol;
  final String localDisplayName;
  final Color localBadgeColor;

  @override
  State<RideMapScreen> createState() => _RideMapScreenState();
}

class _RideMapScreenState extends State<RideMapScreen> {
  static const _personalHeatmapSource = 'ride-relay-personal-heatmap';
  static const _personalHeatmapLayer = 'ride-relay-personal-heatmap-layer';
  static const _globalHeatmapSource = 'ride-relay-global-heatmap';
  static const _globalHeatmapLayer = 'ride-relay-global-heatmap-layer';
  static const _remainingRouteSource = 'ride-relay-route-remaining';
  static const _riderTrailSource = 'ride-relay-rider-trails';
  static const _casingHex = RouteTrailStyle.casingHex;
  static const _trailDirectionArrowSource = 'ride-relay-trail-direction-arrows';
  static const _waypointSource = 'ride-relay-waypoints';
  static const _positionSource = 'ride-relay-position';
  static const _overlaySource = 'ride-relay-overlays';
  static const _markerPlanSource = 'ride-relay-marker-plan';
  static const _trailDirectionArrowImage = 'ride-relay-trail-direction-arrow';

  /// How many of the direction arrows the planned route may claim before the
  /// live cues take the rest. Half the budget: enough to read the route's
  /// direction along its whole length, while leaving the rejoin instruction and
  /// the group's trails the same room they had.
  static const _plannedRouteArrowReserve = 120;
  static const _trailDirectionArrowSampler = TrailDirectionArrowSampler();
  static const _navigationGuidancePlanner = NavigationGuidancePlanner();
  static const _discoveryLineSource = 'ride-relay-discovery-lines';
  static const _discoveryPointSource = 'ride-relay-discovery-points';

  final MapControllerImpl _mapController = MapControllerImpl();
  final RouteProgressTracker _routeProgressTracker = RouteProgressTracker();
  final RouteJourneyProgressTracker _routeJourneyProgressTracker =
      RouteJourneyProgressTracker();
  final RouteProgressTracker _rejoinProgressTracker = RouteProgressTracker();
  final ValueNotifier<NavigationGuidanceAssessment> _navigationGuidance =
      ValueNotifier(const NavigationGuidanceAssessment.noRoute());
  final Map<int, Offset> _mapPointerOrigins = {};
  late final http.Client _routingClient;
  late final RoadRoutingService _roadRoutingService;
  late final Future<DiscoverySuggestionQueue> _suggestionQueue;
  late final DiscoverySuggestionConfiguration _suggestionConfiguration;
  late final DestinationRoutePlanner _defaultDestinationRoutePlanner;
  late final RouteGeometryEnricher _defaultRouteGeometryEnricher;
  late final ImportedTrackMatcher _defaultImportedTrackMatcher;
  late SpeedLimitDisplayController _speedLimitDisplay;
  late bool _ownsSpeedLimitDisplay;
  PersonalRideHeatmapController? _personalRideHeatmap;
  bool _ownsPersonalRideHeatmap = false;
  Timer? _globalHeatmapDebounce;
  // The tracked rider camera starts at street level. MapLibre reports the real
  // value on its first camera callback; beginning here keeps plugin-less/test
  // maps faithful to that initial view without weakening the wide-area cutoff.
  double _lastViewportZoom = 14;
  late final GroupPipBridge _groupPipBridge;
  ml.MapLibreMapController? _mapLibreController;
  late final MapLibreOfflineManager _mapLibreOfflineManager;
  bool _mapLibreStyleReady = false;

  // Everything the map knows about its own background (#281). Until this
  // existed, a failed style, an unreachable tile endpoint and a working map of
  // an empty area were the same picture, and the rider was left to guess.
  //
  /// Set when the platform view calls back to say it loaded the style. Not the
  /// same as [_mapLibreStyleReady], which is set after the app's own layers go
  /// on afterwards and would be false for an unrelated reason.
  bool _basemapViewLoadedStyle = false;

  /// Set when [_basemapViewLoadWindow] elapses with no such callback.
  bool _basemapViewLoadTimedOut = false;

  /// Null until the probe has answered, and null forever if there was nothing
  /// it could sensibly ask for.
  bool? _basemapTilesReachable;

  Timer? _basemapViewLoadWatchdog;

  /// Which style string the observations above belong to, so a style change
  /// starts them over rather than reporting the previous one's verdict.
  String? _observedBasemapStyle;

  /// How long the platform view gets to report a style load before the map
  /// says it did not. Generous on purpose: a slow, cold device that gets there
  /// eventually must not be accused of failing, because a badge that cries
  /// wolf is the same fault as no badge at all.
  static const _basemapViewLoadWindow = Duration(seconds: 20);

  BasemapStatus get _basemapStatus {
    if (!_basemap.isConfigured) return BasemapStatus.routeOnly;
    // The legacy raster path draws through flutter_map's own tile layer, which
    // has no style document, no platform view and none of the observations
    // below. It keeps the behaviour it had.
    if (!_basemap.usesMapLibre) return BasemapStatus.drawing;
    return resolveBasemapStatus(
      styleOutcome: widget.mapStyleOutcome,
      viewLoadedStyle: _basemapViewLoadedStyle,
      viewLoadTimedOut: _basemapViewLoadTimedOut,
      tilesReachable: _basemapTilesReachable,
    );
  }

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
  /// - the remaining planned-route geometry, waypoints, and
  ///   the guidance banner and off-course alerting derived from it.
  ///
  /// Trails, the group overview, presence, SOS, Leave, Report, pause, the ride
  /// menu, the follow camera and the speed limit are all independent of it. Add
  /// a justification here and at the site before adding another test, or the
  /// route-less ride quietly loses another control.
  ImportedRoute? _route;
  ImportedRoute? _routeStartConnector;
  Object? _loadError;
  bool _loading = true;
  bool _importing = false;
  bool _exporting = false;
  bool _routing = false;
  bool _routingToStart = false;
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
  Object? _handledCircularRideRequestToken;
  double _lastHeadingDegrees = 0;
  // Dismissal is per hazard, so passing this one and approaching the next
  // still raises a fresh warning.
  String? _dismissedEnforcementAlertId;

  /// Assigns the accepted route-start leg **and** tells the shell, so the two
  /// cannot drift. Every assignment goes through here for that reason.
  void _setRouteStartConnector(ImportedRoute? connector) {
    _routeStartConnector = connector;
    widget.onRouteStartConnectorChanged?.call(connector);
  }

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
  final GlobalKey _landscapeGuidanceKey = GlobalKey();
  double? _smoothedNavigationSpeedMetersPerSecond;
  // The speed readout is its own notifier so a new fix repaints the badge
  // without rebuilding the map: MapLibre keeps its platform view mounted and
  // only calls setState when navigation mode changes.
  /// The readout, and whether it is still current. Carrying both in one value
  /// keeps the badge from having to guess: a held number is shown differently
  /// from a fresh one rather than being indistinguishable from it.
  final ValueNotifier<({double value, bool ageing})?> _riderSpeed =
      ValueNotifier(null);
  final ValueNotifier<double> _mapBearing = ValueNotifier(0);

  /// Retires the speed readout when fixes stop arriving.
  ///
  /// A stationary rider produces no fixes at all — the platform stream carries a
  /// `distanceFilter`, so standing still is silence, not a stream of zeroes. The
  /// readout therefore cannot be driven by arriving fixes alone: it held 18 mph
  /// while a tester sat in a lay-by (#210). Ageing it is the only way to tell the
  /// truth without waiting for movement to prove the rider has stopped.
  ///
  /// Restarted by every speed-bearing fix, so the timer firing is itself the
  /// proof that none arrived inside the window.
  Timer? _riderSpeedStalenessTimer;

  /// Separate from the staleness timer: that one retires the number, this one
  /// decides whether the silence means the bike stopped (#445).
  Timer? _riderStoppedTimer;

  /// The last speed the platform actually reported, kept after the readout has
  /// been retired — it is what tells a stop apart from a lost signal.
  double? _lastObservedRiderSpeed;

  /// How long the readout survives **without a fix of any kind**, and how long a
  /// speed reads as current.
  ///
  /// Two issues meet here and the distinction between them is the whole fix.
  ///
  /// #210: a stationary rider produces no fixes at all, because the platform
  /// stream carries a `distanceFilter` - standing still is silence, not a stream
  /// of zeroes. So silence has to retire the number, and quickly, or a bike in a
  /// lay-by keeps reading 18 mph.
  ///
  /// #285: the readout flickered on a real ride, "on for 2-3 secs then off for
  /// 4-5 seconds". That was **not** this window expiring. A fix arriving without
  /// a usable speed cleared the readout outright, and on Android plenty of fixes
  /// carry no speed - so the number was being wiped several times a minute while
  /// the rider was moving normally.
  ///
  /// The signal that separates them is not elapsed time, it is whether a fix
  /// arrived at all. A fix without a speed is evidence the platform is still
  /// tracking and simply did not report one; only silence is evidence of having
  /// stopped. So **any** fix restarts this window, while only a speed-bearing fix
  /// replaces the value - and a value older than this window is marked as held
  /// rather than presented as current.
  static const _riderSpeedFreshness = Duration(seconds: 3);

  /// When the displayed speed was last actually observed, as opposed to when a
  /// fix last arrived.
  DateTime? _riderSpeedObservedAt;
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
  bool _waitingRoutePromptDismissed = false;
  RouteProgressGeometry _progressGeometry = const RouteProgressGeometry.empty();
  RouteProgressGeometry _rejoinProgressGeometry =
      const RouteProgressGeometry.empty();
  TileDownloadProgress? _downloadProgress;
  TileDownloadCancellationToken? _downloadCancellation;
  MotorcycleDiscoveryCatalogue _discoveryCatalogue =
      const MotorcycleDiscoveryCatalogue([]);
  final Set<MotorcycleDiscoveryCategory> _enabledDiscoveryCategories = {
    MotorcycleDiscoveryCategory.twistyHighlight,
  };
  BikerPlaceCatalogue _bikerPlaceCatalogue = BikerPlaceCatalogue.empty;
  DiscoveryLayerPreferences? _discoveryLayerPreferences;

  /// What could not be loaded, named. Empty when everything came up.
  List<String> _discoveryLayerFailures = const [];
  bool _bikerCafesVisible = true;
  List<GeoPoint>? _discoveryViewportCorners;

  BasemapConfiguration get _basemap => widget.offlineTileCache.configuration;

  ImportedRoute? get _externalRejoinRoute =>
      widget.rejoinNavigationRoute?.value;

  ImportedRoute? get _rejoinRoute =>
      _externalRejoinRoute ?? _routeStartConnector;

  GeoPoint? get _plannedRouteStart => _route?.paths
      .where((path) => path.points.isNotEmpty)
      .firstOrNull
      ?.points
      .first;

  double? get _routeStartOfferDistance {
    if (!widget.isNavigating ||
        _routeStartConnector != null ||
        _externalRejoinRoute != null) {
      return null;
    }
    final position = _effectivePosition;
    final start = _plannedRouteStart;
    final route = _route;
    if (position == null || start == null || route == null) return null;
    if (_progressGeometry.progressMeters > 50 ||
        distanceToRouteMeters(route, position) <= 250) {
      return null;
    }
    final distance = _mapDistanceMeters(position, start);
    return distance > 250 ? distance : null;
  }

  RouteProgressGeometry get _navigationProgressGeometry =>
      _rejoinRoute == null ? _progressGeometry : _rejoinProgressGeometry;

  /// Route-derived: the marker plan is an analysis of the planned route.
  RouteMarkerPlan get _markerPlan =>
      !widget.markerFeaturesEnabled || _route == null
      ? const RouteMarkerPlan(points: [])
      : const RouteMarkerPlanAnalyzer().analyze(_route!);

  /// The review action on the day: a green dot the group turns out not to need
  /// is rejected here rather than argued with at the roadside (#179).
  ///
  /// Reviewing the whole plan at leisure belongs on the route review screen and,
  /// in time, the web planner; this surface is for the one that is wrong now.
  Future<void> _showMarkerPlanPoint(MarkerPlanPoint point) async {
    final manual = point.source == MarkerPlanPointSource.manual;
    final reject = await showModalBottomSheet<bool>(
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
                point.label,
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
              if (point.detail case final detail?) ...[
                const SizedBox(height: 6),
                Text(detail, style: const TextStyle(color: Color(0xFF98A3B1))),
              ],
              if (widget.canEditRoute) ...[
                const SizedBox(height: 14),
                OutlinedButton.icon(
                  key: const Key('reject-marker-plan-point'),
                  onPressed: () => Navigator.of(sheetContext).pop(true),
                  icon: const Icon(Icons.block_outlined),
                  label: Text(
                    manual
                        ? 'Remove this added position'
                        : 'Not needed — reject for this route',
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
    if (reject != true || !mounted) return;
    await _rejectMarkerPlanPoint(point);
  }

  Future<void> _rejectMarkerPlanPoint(MarkerPlanPoint point) async {
    final route = _route;
    if (route == null || !widget.canEditRoute) return;
    final updated = route.withMarkerReview(
      point.source == MarkerPlanPointSource.manual
          ? route.markerReview.restoring(point.id)
          : route.markerReview.rejecting(point.toReviewPoint()),
    );
    await widget.routeStore.saveActiveRoute(updated);
    if (!mounted) return;
    setState(() => _route = updated);
    await _syncMapLibreSources();
    widget.onRouteChanged?.call(updated);
    widget.onRouteCommitted?.call(updated);
    _showMessage(
      point.source == MarkerPlanPointSource.manual
          ? '${point.label}: removed from the marker plan.'
          : '${point.label}: rejected for this route.',
    );
  }

  DestinationRoutePlanner get _destinationRoutePlanner =>
      widget.destinationRoutePlanner ?? _defaultDestinationRoutePlanner;

  RouteGeometryEnricher get _routeGeometryEnricher =>
      widget.routeGeometryEnricher ?? _defaultRouteGeometryEnricher;

  ImportedTrackMatcher get _importedTrackMatcher =>
      widget.importedTrackMatcher ?? _defaultImportedTrackMatcher;

  @override
  void initState() {
    super.initState();
    // Restored from the shell, which outlives a tab change: see the field
    // comments on RideMapFeature (#282).
    _dismissedEnforcementAlertId = widget.dismissedEnforcementAlertId;
    _routeStartConnector = widget.initialRouteStartConnector;
    _routingClient = http.Client();
    _suggestionQueue = DiscoverySuggestionQueue.openDefault();
    _suggestionConfiguration =
        DiscoverySuggestionConfiguration.fromEnvironment();
    final routingConfiguration = RoutingConfiguration.fromEnvironment();
    // Preferences the OSRM driving profile cannot express are sent to the same
    // Valhalla motorcycle service the web planner uses, by the same rule, so the
    // two surfaces agree about what a preference means (#182).
    _roadRoutingService =
        widget.roadRoutingService ??
        PreferenceAwareRoadRoutingService(
          osrm: OsrmRoadRoutingService(
            client: _routingClient,
            baseUrl: routingConfiguration.routingBaseUrl,
          ),
          motorcycle: ValhallaMotorcycleRoutingService(
            client: _routingClient,
            routeUrl: routingConfiguration.motorcycleRoutingUrl,
          ),
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
    // Valhalla, not OSRM: the configured OSRM demo server caps `/match` at ten
    // trace coordinates, so this path returned 400 for every import ever
    // attempted (#575). Valhalla's limit is 200 km of path, which a long track
    // is split to fit, and it already serves speed limits and motorcycle
    // routing here.
    _defaultImportedTrackMatcher = ValhallaImportedTrackMatcher(
      client: _routingClient,
      traceUrl: routingConfiguration.trackMatchingUrl,
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
    widget.rejoinNavigationRoute?.addListener(_onRejoinNavigationRouteChanged);
    widget.leaderStatus?.addListener(_onGroupPipDataChanged);
    widget.junctionMarkerOverlay?.addListener(_onJunctionMarkerChanged);
    widget.enforcementAlert?.addListener(_onEnforcementAlertChanged);
    widget.globalRideHeatmap?.addListener(_onGlobalRideHeatmapChanged);
    _rejoinProgressGeometry = _rejoinProgressTracker.update(
      _rejoinRoute,
      _effectivePosition,
    );
    // The app-level AnimatedBuilder already listens to this shared controller.
    // Starting the lookup here used to notify that ancestor while its
    // FutureBuilder was still constructing this map (#485).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _observeSpeedLimit(_navigationFix);
    });
    _watchBasemapViewLoad();
    _markerOverviewVisible =
        widget.junctionMarkerOverlay?.value?.isLocalMarker ?? false;
    _loadPersistedRoute();
    unawaited(_openPersonalRideHeatmap());
    unawaited(_loadDiscoveryCatalogue());
    _maybeHandleChangeRouteRequest();
    _maybeHandleCircularRideRequest();
  }

  @override
  void didUpdateWidget(RideMapScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.changeRouteRequestToken != widget.changeRouteRequestToken) {
      _maybeHandleChangeRouteRequest();
    }
    if (oldWidget.circularRideRequestToken != widget.circularRideRequestToken) {
      _maybeHandleCircularRideRequest();
    }
    if (oldWidget.globalRideHeatmap != widget.globalRideHeatmap) {
      oldWidget.globalRideHeatmap?.removeListener(_onGlobalRideHeatmapChanged);
      widget.globalRideHeatmap?.addListener(_onGlobalRideHeatmapChanged);
      _scheduleGlobalHeatmapRefresh();
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
    if (oldWidget.rejoinNavigationRoute != widget.rejoinNavigationRoute) {
      oldWidget.rejoinNavigationRoute?.removeListener(
        _onRejoinNavigationRouteChanged,
      );
      widget.rejoinNavigationRoute?.addListener(
        _onRejoinNavigationRouteChanged,
      );
      _onRejoinNavigationRouteChanged();
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
    if (oldWidget.enforcementAlert != widget.enforcementAlert) {
      oldWidget.enforcementAlert?.removeListener(_onEnforcementAlertChanged);
      widget.enforcementAlert?.addListener(_onEnforcementAlertChanged);
      _onEnforcementAlertChanged();
    }
    if (oldWidget.speedLimitDisplay != widget.speedLimitDisplay) {
      if (_ownsSpeedLimitDisplay) _speedLimitDisplay.dispose();
      _ownsSpeedLimitDisplay = widget.speedLimitDisplay == null;
      _speedLimitDisplay =
          widget.speedLimitDisplay ?? SpeedLimitDisplayController.inMemory();
      _observeSpeedLimit(_navigationFix);
    }
    _watchBasemapViewLoad();
  }

  /// Starts the clock on the platform view for a style it has not been given
  /// before.
  ///
  /// Guarded on the style string so a rebuild does not restart the window, and
  /// so a style change starts over rather than inheriting the previous style's
  /// verdict.
  void _watchBasemapViewLoad() {
    if (_observedBasemapStyle == widget.mapStyleString) return;
    _observedBasemapStyle = widget.mapStyleString;
    _basemapViewLoadWatchdog?.cancel();
    _basemapViewLoadWatchdog = null;
    _basemapViewLoadedStyle = false;
    _basemapViewLoadTimedOut = false;
    _basemapTilesReachable = null;
    // Nothing to wait for. Either there is no platform view on this path, or
    // the style never arrived and the badge already says which.
    if (!_basemap.usesMapLibre ||
        widget.mapStyleOutcome == MapStyleOutcome.unavailable ||
        widget.mapStyleOutcome == MapStyleOutcome.unconfigured) {
      return;
    }
    _basemapViewLoadWatchdog = Timer(_basemapViewLoadWindow, () {
      if (!mounted || _basemapViewLoadedStyle) return;
      setState(() => _basemapViewLoadTimedOut = true);
    });
  }

  @override
  void dispose() {
    _downloadCancellation?.cancel();
    widget.currentPosition?.removeListener(_onPositionChanged);
    widget.navigationPosition?.removeListener(_onPositionChanged);
    widget.overlayMarkers?.removeListener(_onOverlayDataChanged);
    widget.riderTrails?.removeListener(_onOverlayDataChanged);
    widget.rejoinNavigationRoute?.removeListener(
      _onRejoinNavigationRouteChanged,
    );
    widget.leaderStatus?.removeListener(_onGroupPipDataChanged);
    widget.junctionMarkerOverlay?.removeListener(_onJunctionMarkerChanged);
    widget.enforcementAlert?.removeListener(_onEnforcementAlertChanged);
    _mapLibreController?.onFeatureTapped.remove(_onMapLibreFeatureTapped);
    _mapLibreController?.removeListener(_scheduleCameraFramingRefresh);
    _mapController.dispose();
    _navigationGuidance.dispose();
    _riderSpeedStalenessTimer?.cancel();
    _riderSpeedStalenessTimer = null;
    _riderStoppedTimer?.cancel();
    _riderStoppedTimer = null;
    _basemapViewLoadWatchdog?.cancel();
    _basemapViewLoadWatchdog = null;
    _riderSpeed.dispose();
    _mapBearing.dispose();
    if (_ownsSpeedLimitDisplay) _speedLimitDisplay.dispose();
    _personalRideHeatmap?.removeListener(_onPersonalRideHeatmapChanged);
    if (_ownsPersonalRideHeatmap) _personalRideHeatmap?.dispose();
    widget.globalRideHeatmap?.removeListener(_onGlobalRideHeatmapChanged);
    _globalHeatmapDebounce?.cancel();
    unawaited(_groupPipBridge.dispose());
    _routingClient.close();
    if (widget.disposeOfflineTileCache) widget.offlineTileCache.dispose();
    super.dispose();
  }

  void _onEnforcementAlertChanged() {
    // A dismissal lasts only for this uninterrupted approach. GPS/provider
    // updates can briefly clear a camera and later arm the same catalogue ID;
    // retaining the old dismissal hid the popup while the independent speech
    // edge announced it again.
    if (widget.enforcementAlert?.value == null &&
        _dismissedEnforcementAlertId != null &&
        mounted) {
      setState(() => _dismissedEnforcementAlertId = null);
    }
  }

  Future<void> _loadPersistedRoute() async {
    try {
      final route = await widget.routeStore.loadActiveRoute();
      if (!mounted) return;
      setState(() {
        _route = route;
        _setRouteStartConnector(null);
        _rejoinProgressTracker.reset();
        _rejoinProgressGeometry = _rejoinProgressTracker.update(
          _externalRejoinRoute,
          _effectivePosition,
        );
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
        //
        // Only for a rider who is actually going somewhere, though. This
        // canvas takes the whole screen and the AppBar with it — the search
        // field, the layer menu, Settings — and it used to do that anywhere the
        // app knew where the rider was. Free roam therefore lost its entire top
        // band the moment location was granted, which is why the
        // discovery-layer menu "does not appear most of the time" (#572, #593)
        // and why there was no way to anything else from there (#600). A rider
        // standing still on a map with no route is not navigating.
        _navigationCanvasActive =
            _effectivePosition != null && (widget.isNavigating || _isMoving);
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

  /// Loads the three things the map's optional layers need.
  ///
  /// **Each independently.** This was one `Future.wait` behind a swallowing
  /// `catch`, and `Future.wait` fails the moment any single future does — so a
  /// failed discovery-catalogue read applied *none* of the three results. The
  /// cafés vanished, the discovery layers vanished, and
  /// `_discoveryLayerPreferences` stayed null, which turned every toggle in the
  /// layer sheet into a `?.` no-op that neither persisted nor redrew. Nothing
  /// was logged and nothing was said, so it read as "the menu does nothing"
  /// (#596, and half of #593).
  ///
  /// They have no dependency on one another. A discovery read that fails must
  /// not cost a rider their cafés, and must certainly not cost them the layer
  /// preferences they already set.
  Future<void> _loadDiscoveryCatalogue() async {
    final failures = <String>[];

    Future<void> load(String what, Future<void> Function() body) async {
      try {
        await body();
      } on Object catch (error) {
        failures.add(what);
        if (kDebugMode) debugPrint('Could not load $what: $error');
      }
    }

    await Future.wait([
      load('the discovery layers', () async {
        final catalogue =
            await (widget.discoveryCatalogueLoader ??
                MotorcycleDiscoveryCatalogue.loadAsset)();
        if (!mounted) return;
        setState(() => _discoveryCatalogue = catalogue);
      }),
      load('the biker café layer', () async {
        final catalogue =
            await (widget.bikerPlaceCatalogueLoader ??
                BikerPlaceCatalogue.loadAsset)();
        if (!mounted) return;
        setState(() => _bikerPlaceCatalogue = catalogue);
      }),
      load('the saved layer choices', () async {
        final preferences = await DiscoveryLayerPreferences.load();
        if (!mounted) return;
        setState(() {
          _discoveryLayerPreferences = preferences;
          _enabledDiscoveryCategories
            ..clear()
            ..addAll(preferences.categories);
          _bikerCafesVisible = preferences.bikerCafesVisible;
        });
      }),
    ]);

    if (!mounted) return;
    // Said rather than swallowed. A layer that cannot be drawn, or a choice
    // that cannot be saved, is something the rider is entitled to know about
    // rather than discover by a toggle doing nothing.
    if (failures.isNotEmpty) {
      setState(() => _discoveryLayerFailures = List.unmodifiable(failures));
    }
    _scheduleMapLibreSync(overlays: true);
  }

  Future<void> _openPersonalRideHeatmap() async {
    try {
      final supplied = widget.personalRideHeatmap;
      final store = widget.completedRideStore;
      // Direct RideMapScreen embedders and focused tests do not implicitly open
      // platform storage. Production supplies the app's archive explicitly.
      if (supplied == null && store == null) return;
      final controller =
          supplied ?? await PersonalRideHeatmapController.load(store: store!);
      if (!mounted) {
        if (supplied == null) controller.dispose();
        return;
      }
      _ownsPersonalRideHeatmap = supplied == null;
      _personalRideHeatmap = controller;
      controller.addListener(_onPersonalRideHeatmapChanged);
      setState(() {});
      _scheduleMapLibreSync(overlays: true);
    } on Object catch (error) {
      if (kDebugMode) {
        debugPrint('Could not read personal ride heatmap: $error');
      }
    }
  }

  void _onPersonalRideHeatmapChanged() {
    if (!mounted) return;
    setState(() {});
    _scheduleMapLibreSync(overlays: true);
  }

  PersonalRideHeatmap get _visiblePersonalHeatmap {
    final controller = _personalRideHeatmap;
    return controller?.visible == true
        ? controller!.heatmap
        : PersonalRideHeatmap.empty;
  }

  GlobalHeatmapSnapshot get _visibleGlobalHeatmap {
    final controller = widget.globalRideHeatmap;
    return controller?.visible == true
        ? controller!.snapshot
        : GlobalHeatmapSnapshot.empty;
  }

  List<CircularRideHeatCell> get _personalCircularHeatCells => [
    for (final cell in _personalRideHeatmap?.heatmap.cells ?? const [])
      CircularRideHeatCell(point: cell.centre, weight: cell.weight),
  ];

  List<CircularRideHeatCell> get _globalCircularHeatCells => [
    for (final cell in widget.globalRideHeatmap?.snapshot.cells ?? const [])
      CircularRideHeatCell(point: cell.point, weight: cell.weight),
  ];

  Future<void> _togglePersonalRideHeatmap() async {
    final controller = _personalRideHeatmap;
    if (controller == null) {
      _showMessage('The saved-ride layer is still loading.');
      return;
    }
    try {
      await controller.setVisible(!controller.visible);
    } on Object catch (error) {
      _showMessage('Could not read saved ride coverage: $error');
      return;
    }
    if (!mounted || !controller.visible) return;
    final cells = controller.heatmap.cells.length;
    _showMessage(
      cells == 0
          ? 'Personal rides is on. No travelled tracks are saved yet.'
          : 'Personal rides is on · $cells covered area${cells == 1 ? '' : 's'}.'
                '${controller.heatmap.truncated ? ' The oldest coverage was capped for performance.' : ''}',
    );
  }

  void _onGlobalRideHeatmapChanged() {
    if (!mounted) return;
    setState(() {});
    _scheduleMapLibreSync(overlays: true);
  }

  Future<void> _toggleGlobalRideHeatmap() async {
    final controller = widget.globalRideHeatmap;
    if (controller == null) {
      _showMessage('The global rides service is not configured in this build.');
      return;
    }
    await controller.setVisible(!controller.visible);
    if (!controller.visible) return;
    _showMessage(
      'Global rides shows thresholded public coverage. Viewing it does not share your rides.',
    );
    _scheduleGlobalHeatmapRefresh(immediate: true);
  }

  void _scheduleGlobalHeatmapRefresh({bool immediate = false}) {
    _globalHeatmapDebounce?.cancel();
    final controller = widget.globalRideHeatmap;
    final corners = _discoveryViewportCorners;
    if (controller?.visible != true || corners == null || corners.length < 2) {
      return;
    }
    _globalHeatmapDebounce = Timer(
      immediate ? Duration.zero : const Duration(milliseconds: 450),
      () {
        final west = math.min(corners[0].longitude, corners[1].longitude);
        final east = math.max(corners[0].longitude, corners[1].longitude);
        final south = math.min(corners[0].latitude, corners[1].latitude);
        final north = math.max(corners[0].latitude, corners[1].latitude);
        if (east - west > 8 || north - south > 8) return;
        unawaited(
          controller!.refresh(
            west: west,
            south: south,
            east: east,
            north: north,
            zoom: _lastViewportZoom.round().clamp(6, 18),
          ),
        );
      },
    );
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
    // Read once: it decides the title, three of the actions, the tail of the
    // row and the bottom band, and reading it in five places invites them to
    // disagree.
    final hostChrome = widget.hostChrome;
    final overlayLeft = safeInsets.left;
    final overlayRight = safeInsets.right;
    // The host's own bar, if it stands on this map, is not the map's space. Free
    // roam keeps a bar of actions at the bottom (#426); the map's bottom rail
    // was anchored to the system inset alone and so drew its compass and its
    // controls underneath it (#573, #600). One inset rather than a per-control
    // offset, because the camera's bottom-chrome fraction (#105) measures this
    // band too and has to agree with what is drawn in it.
    final overlayBottom = safeInsets.bottom + (hostChrome?.bottomInset ?? 0);
    // Only the ride menu reaches the upper band (#125), and it still owes the
    // notch and the status bar their space.
    final overlayTop = safeInsets.top;
    final compactDensity = landscape ? VisualDensity.compact : null;
    // Only before the ride starts, only where a route may be built, only when
    // the host has not brought its own — and only while there is no route yet.
    //
    // That last one matters: once a route is loaded its name is the more
    // useful thing to show, and it is the only place the name appears on this
    // surface. Free roam is the exception and keeps its field either way,
    // because the home search does something a loaded route does not make
    // redundant: it creates or plans a ride around a destination.
    final showDestinationSearch =
        hostChrome == null &&
        !widget.isNavigating &&
        widget.canEditRoute &&
        _route == null;
    // The group mini-map owns its own ValueListenableBuilder below. This
    // avoids relying on a parent platform-map rebuild to notice rider updates,
    // which left the portrait mini-map absent in the live simulator.
    final canShowGroupMiniMap =
        widget.overlayMarkers != null && !markerOverviewActive;
    final groupMiniMapWidth = landscape ? 196.0 : 150.0;
    final groupMiniMapHeight = landscape ? 116.0 : 104.0;
    // An active ride supplies its own named destination menu. Free roam has no
    // ride menu, but its host supplies More — including Settings and the ride
    // library. The AppBar disappears on the navigation canvas, so one of these
    // must remain in the same top-leading position or the map becomes a dead end.
    final showRideMenu =
        hideChrome &&
        (widget.onOpenRideMenu != null || hostChrome?.onMore != null);
    // A route can contain manoeuvres before the device has a usable location.
    // The guidance banner is only composed into the band while guidance is
    // actually visible, so nothing reserves space for a banner that is absent.
    final routeStartOfferDistance = _routeStartOfferDistance;
    final hasGuidance =
        routeStartOfferDistance == null &&
        widget.isNavigating &&
        _navigationGuidance.value.isVisible;
    // Leaving a ride is a ride-lifecycle action, not a route action (#124).
    // Not gated on the ride having started (#579). Creating a ride by mistake,
    // or changing your mind about a solo one, is an ordinary thing to do, and
    // it used to cost a dig through the ride menu because LEAVE only appeared
    // once the ride was under way. Free roam is unaffected: there is no ride
    // there, so `onLeaveRide` is null and nothing is offered.
    final showLeaveRide = widget.onLeaveRide != null;
    // "Follow me" is the way into the navigation viewport, and it is on screen
    // whenever the camera is not locked into it (#141). The junction overview owns
    // the whole screen while it is up, so nothing is offered underneath it.
    final showFollowMe =
        widget.isNavigating &&
        !markerOverviewActive &&
        !_navigationViewportLocked;
    return Scaffold(
      appBar: hideChrome
          ? null
          : AppBar(
              toolbarHeight: rideMapToolbarHeight(landscape: landscape),
              titleSpacing: 12,
              // Free roam supplies its own search field through `hostChrome`.
              // A created ride that has not started supplies none, and used to
              // get a plain title plus an `add_road` icon button — the same
              // intent as free roam's field, in a different place and a
              // different shape (#579). It renders the same field here, in the
              // same slot. What the two do still differs, deliberately: this
              // one adds a destination to the route in hand, free roam's
              // creates or plans a ride around one.
              //
              // Once the ride starts this reverts to the route name. A search
              // field is not something to put in front of a moving rider, and
              // the riding chrome is settled (#533, #125, #133).
              title:
                  hostChrome?.title ??
                  (showDestinationSearch
                      ? DestinationSearchField(
                          key: const Key('map-destination-search'),
                          onTap: _routing ? () {} : _planDestination,
                        )
                      : Text(
                          _route?.name ?? 'Navigation',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: landscape
                              ? Theme.of(context).textTheme.titleMedium
                              : null,
                        )),
              actions: [
                // A host that brought its own title brought its own way to a
                // destination with it — free roam's search field. A second
                // entry beside it would crowd the field down to nothing on a
                // phone and say the same thing twice. Both actions stay in the
                // overflow menu below.
                if (widget.canEditRoute &&
                    hostChrome == null &&
                    !showDestinationSearch)
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
                if (widget.canEditRoute && _route == null && hostChrome == null)
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
                // navigation app or write to a GPX without one. Dropped when a
                // host is sharing the row, on the same reasoning as Fit route
                // below — it moves into the overflow menu instead.
                if (_route != null && hostChrome == null)
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
                // Route-derived: fitting the whole plan needs a plan. The
                // rider's own framing is the follow camera's job. A host
                // sharing this row gets the button dropped rather than
                // greyed — a permanently disabled control is width the
                // search field needs (#573).
                //
                // Dropped outright when a host shares the row, rather than only
                // while there is no route. Free roam can hold a route of its own
                // now (#600), and this button plus the export one beside it
                // pushed the row past the width of a phone — the host's search
                // field and labelled Join have already spent it. Both are in
                // the overflow menu below.
                if (hostChrome == null)
                  IconButton(
                    tooltip: 'Fit route',
                    visualDensity: compactDensity,
                    onPressed: _route == null ? null : _showWholeRoute,
                    icon: const Icon(Icons.fit_screen),
                  ),
                // The host's actions before the overflow menu, so the map's
                // own controls keep their position as the host's set changes.
                // One row, one widget tree, one hit test.
                ...?hostChrome?.actions,
                // The overflow menu last, which on a host-chromed map means
                // after the host's actions too. It used to come first, and on
                // Home — where every icon above it is gated off — that left it a
                // bare `...` between the search field and Join. Nothing covered
                // it and it worked; it was simply not where a menu is looked for,
                // which is #306's complaint arriving by a new route (#606).
                PopupMenuButton<_MapAction>(
                  key: const Key('map-layer-actions'),
                  iconSize: landscape ? 22 : 24,
                  padding: landscape
                      ? EdgeInsets.zero
                      : const EdgeInsets.all(8),
                  onSelected: _handleMenuAction,
                  itemBuilder: (context) => [
                    if (hostChrome?.onMore != null) ...[
                      const PopupMenuItem(
                        key: Key('home-more-actions'),
                        value: _MapAction.hostMore,
                        child: Text('More actions'),
                      ),
                      const PopupMenuDivider(),
                    ],
                    if (widget.canEditRoute) ...[
                      const PopupMenuItem(
                        value: _MapAction.circularRide,
                        child: Text('Create a circular ride'),
                      ),
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
                      key: const Key('personal-rides-heatmap-toggle'),
                      value: _MapAction.personalRideHeatmap,
                      child: Row(
                        children: [
                          Icon(
                            _personalRideHeatmap?.visible == true
                                ? Icons.check_box
                                : Icons.check_box_outline_blank,
                          ),
                          const SizedBox(width: 10),
                          const Expanded(child: Text('Personal rides heatmap')),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      key: const Key('global-rides-heatmap-toggle'),
                      value: _MapAction.globalRideHeatmap,
                      child: Row(
                        children: [
                          Icon(
                            widget.globalRideHeatmap?.visible == true
                                ? Icons.check_box
                                : Icons.check_box_outline_blank,
                          ),
                          const SizedBox(width: 10),
                          const Expanded(child: Text('Global rides heatmap')),
                        ],
                      ),
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
                    // What the app bar dropped to make room for a host's own
                    // controls. Offered here rather than nowhere (#600).
                    if (_route != null && hostChrome != null) ...[
                      const PopupMenuItem(
                        key: Key('fit-route-menu-item'),
                        value: _MapAction.fitRoute,
                        child: Text('Fit route on screen'),
                      ),
                      const PopupMenuItem(
                        key: Key('export-route-menu-item'),
                        value: _MapAction.exportRoute,
                        child: Text('Navigate or export route'),
                      ),
                    ],
                    // Route-derived: both read manoeuvres off the plan.
                    if (_route?.maneuvers.isNotEmpty ?? false) ...[
                      const PopupMenuItem(
                        value: _MapAction.maneuverList,
                        child: Text('All turns for this route'),
                      ),
                      if (widget.markerFeaturesEnabled)
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
                    routeStartOfferDistance: routeStartOfferDistance,
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
                //
                // Never in free roam. This card was written for a ride that has
                // been created and has no route yet — it says so, offering to
                // "continue to the live group map" — and free roam has no group
                // and no ride to continue to. It also covers the map, which is
                // the one thing free roam is: opening the app to a card asking
                // for a route is the ceremony #600 is about, and the search
                // field the host brought is directly above it.
                if (_route == null &&
                    hostChrome == null &&
                    !hideChrome &&
                    !widget.isNavigating &&
                    !_waitingRoutePromptDismissed)
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    bottom: _safetyBandReservedHeight(landscape),
                    child: widget.canEditRoute
                        ? _EmptyRoutePrompt(
                            importing: _importing,
                            routing: _routing,
                            onPlanDestination: _planDestination,
                            onImport: _importGpx,
                            onUseStoredRoute: _useStoredRoute,
                            onLoadDemo: _loadDemoRoute,
                            onDismiss: _continueWithoutRoute,
                          )
                        : _WaitingForLeaderRoutePrompt(
                            onDismiss: _continueWithoutRoute,
                          ),
                  ),
                // An approaching camera or police report, in two parts: a bubble
                // that announces it and a border that holds for the rest of the
                // approach (#446). The announcement sits at the top-centre,
                // clear of the rider marker and the bottom navigation rails.
                if (widget.enforcementAlert != null)
                  Positioned.fill(
                    child: ValueListenableBuilder<EnforcementAlert?>(
                      valueListenable: widget.enforcementAlert!,
                      builder: (context, alert, _) {
                        if (alert == null ||
                            alert.hazard.id == _dismissedEnforcementAlertId) {
                          return const SizedBox.shrink();
                        }
                        return _EnforcementAlertLayer(
                          // A new hazard gets a new State, so its ten seconds
                          // start again rather than inheriting the last one's.
                          key: ValueKey(alert.hazard.id),
                          alert: alert,
                          distanceUnit: widget.distanceUnit,
                          topInset: overlayTop,
                          onDismiss: () {
                            setState(
                              () => _dismissedEnforcementAlertId =
                                  alert.hazard.id,
                            );
                            // Reported up so the decision survives this widget
                            // being rebuilt by a tab change (#282).
                            widget.onDismissEnforcementAlert?.call(
                              alert.hazard.id,
                            );
                          },
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
                    bottom: _safetyBandReservedHeight(
                      landscape,
                      reserveLandscapeStack: true,
                    ),
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
                          onDismiss: () {
                            final id = alert.message.eventId;
                            setState(
                              () => _dismissedQuickMessageInterrupts.add(id),
                            );
                            widget.onDismissQuickMessageInterrupt?.call(id);
                          },
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
    required double? routeStartOfferDistance,
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
    final viewportWidth = MediaQuery.sizeOf(context).width;
    final railWidth = math.min(
      360.0,
      (viewportWidth - safeLeft - safeRight) * 0.42,
    );
    final landscapeGuidanceWidth = landscapeGuidancePanelWidth(
      viewportWidth: viewportWidth,
      safeRight: safeRight,
      leftHandTraffic: _routeUsesLeftHandTraffic,
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
            onDismissReceipt: () {
              final id = quickMessage.message.eventId;
              setState(() => _dismissedQuickMessageReceipts.add(id));
              widget.onDismissQuickMessageReceipt?.call(id);
            },
          ),
      ];
      final guidance = routeStartOfferDistance != null
          ? _RouteStartBanner(
              distanceMeters: routeStartOfferDistance,
              distanceUnit: widget.distanceUnit,
              compact: landscape,
              routing: _routingToStart,
              onNavigate: _routingToStart ? null : _navigateToRouteStart,
            )
          : hasGuidance
          ? ValueListenableBuilder<NavigationGuidanceAssessment>(
              valueListenable: _navigationGuidance,
              builder: (context, assessment, _) {
                final guidance = assessment.guidance;
                return guidance == null
                    ? _NavigationGuidanceStatusBanner(
                        assessment: assessment,
                        compact: landscape,
                      )
                    : _NavigationGuidanceBanner(
                        guidance: guidance,
                        distanceUnit: widget.distanceUnit,
                        compact: landscape,
                      );
              },
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
      final routeProgressPanel =
          !widget.showRouteProgress ||
              markerOverviewActive ||
              _route == null ||
              _progressGeometry.totalMeters <= 0
          ? null
          : ValueListenableBuilder<({double value, bool ageing})?>(
              valueListenable: _riderSpeed,
              builder: (context, riderSpeed, _) {
                final progress = _routeJourneyProgressTracker.update(
                  route: _route,
                  geometry: _progressGeometry,
                  speedMetersPerSecond: riderSpeed?.ageing == false
                      ? riderSpeed!.value
                      : null,
                  now: DateTime.now(),
                );
                return progress == null
                    ? const SizedBox.shrink()
                    : RouteProgressPanel(
                        progress: progress,
                        distanceUnit: widget.distanceUnit,
                        // The time is now a consistent map label in both
                        // orientations rather than changing hierarchy with the
                        // ETA card.
                        showClock: false,
                        // Free roam only. A ride's route belongs to the group
                        // and leaves through LEAVE / the ride menu; out here
                        // the route is the rider's own and the card that says
                        // "you are navigating" carries the way to stop (#615).
                        onStop: widget.hostChrome != null && widget.canEditRoute
                            ? () => unawaited(_stopFreeRoamNavigation())
                            : null,
                      );
              },
            );
      // Arriving and approaching a junction are mutually exclusive: the
      // suggestion only appears once the whole group is inside the destination
      // radius with the route run, so there is no next junction to draw. Taking
      // that slot rather than adding a row is what keeps the measured band
      // under its cap, which #380 required be measured rather than assumed.
      // A paused ride never reaches arrival - `_maybeAutomaticallyEndRide`
      // returns early on it, as it does on an active marker - so the suggestion
      // cannot share the band with the paused banner or the junction card. The
      // guard is repeated here because this is the layer whose height is
      // measured, and a caller that passed both would silently blow the cap.
      final completionSuggestion =
          widget.rideCompletionSuggestion == null || widget.ridePaused
          ? null
          : ValueListenableBuilder<RideCompletionAssessment?>(
              valueListenable: widget.rideCompletionSuggestion!,
              builder: (context, assessment, _) => assessment == null
                  ? const SizedBox.shrink()
                  : _RideCompletionSuggestion(
                      assessment: assessment,
                      compact: compactStatus,
                      onEndForEveryone: widget.onEndRideForEveryone,
                      onDismiss: widget.onDismissRideCompletion,
                    ),
            );
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
                          ? math.min(250.0, constraints.maxWidth)
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
      final navigationMenuAction = widget.onOpenRideMenu == null
          ? widget.hostChrome?.onMore
          : () => unawaited(widget.onOpenRideMenu!());
      final rideMenu = showRideMenu
          ? FloatingActionButton.small(
              key: const Key('ride-menu-button'),
              heroTag: 'ride-relay-menu',
              tooltip: widget.onOpenRideMenu == null ? 'More' : 'Ride actions',
              onPressed: navigationMenuAction,
              backgroundColor: const Color(0xE6252E39),
              foregroundColor: Colors.white,
              child: const Icon(Icons.menu),
            )
          : null;
      // Landscape uses a compact vertical action stack. It keeps three adjacent
      // glove targets from stretching across the lower map and leaves the rider
      // and road ahead visually isolated (#533).
      // Compact padding keeps the portrait safety stack plus the paired
      // compass/sign inside narrow phones without shrinking any glove target.
      final actionPadding = const EdgeInsets.symmetric(horizontal: 8);
      // Fixed label slots keep the vertical stack the same width through ALERT,
      // ALERT SENT and ALERT SEEN states.
      final sosLabelSlot = 62.0;
      final leaveLabelSlot = 62.0;
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
      final sosButton = !widget.rideStarted || widget.onEmergencyAlert == null
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
              // Portrait and landscape both keep SOS and LEAVE aligned as one
              // stable column.
              label: _ActionLabel(
                'LEAVE',
                widest: 'ALERT SENT',
                slotWidth: leaveLabelSlot,
              ),
            )
          : null;
      // Reporting a camera or a patrol car is a ride action, not a route action,
      // and it earns a place beside them (#125).
      final reportButton = !widget.rideStarted || widget.onReportHazard == null
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
      // Portrait stacks SOS over LEAVE with REPORT alongside (#133). Landscape
      // stacks all three vertically so the controls do not form a wide barrier
      // across the map (#533).
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
          ? Column(
              key: const Key('map-action-cluster'),
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ?sosSubtree,
                if (sosSubtree != null && leaveSubtree != null)
                  const SizedBox(height: 8),
                ?leaveSubtree,
                if (reportSubtree != null) ...[
                  const SizedBox(height: 8),
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
      final speedLimit = markerOverviewActive || !widget.isNavigating
          ? null
          : KeyedSubtree(
              key: const Key('posted-speed-limit-position'),
              child: AnimatedBuilder(
                animation: _speedLimitDisplay,
                builder: (context, _) => _speedLimitDisplay.enabled
                    ? ValueListenableBuilder<({double value, bool ageing})?>(
                        valueListenable: _riderSpeed,
                        builder: (context, riderSpeed, _) =>
                            _EnforcementEmphasis(
                              alert: widget.enforcementAlert,
                              dismissedHazardId: _dismissedEnforcementAlertId,
                              builder: (emphasised) => _PostedSpeedLimitBadge(
                                status: _speedLimitDisplay.status,
                                outcome: _speedLimitDisplay.lastOutcome,
                                limit: _speedLimitDisplay.limit,
                                riderSpeedMetersPerSecond: riderSpeed?.value,
                                riderSpeedIsAgeing: riderSpeed?.ageing ?? false,
                                emphasised: emphasised,
                              ),
                            ),
                      )
                    : _SpeedLimitOptInChip(
                        onPressed: _confirmEnableSpeedLimitDisplay,
                      ),
              ),
            );
      final compass = speedLimit == null
          ? null
          : ValueListenableBuilder<double>(
              valueListenable: _mapBearing,
              builder: (context, bearing, _) => _RideCompass(
                bearingDegrees: bearing,
                diameter: 58,
                darkMap: _basemap.dark,
              ),
            );
      final speedCluster = speedLimit == null
          ? null
          : Row(
              key: const Key('speed-compass-cluster'),
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ?compass,
                if (compass != null) const SizedBox(width: 8),
                speedLimit,
              ],
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
        final actionLeft =
            safeLeft +
            10 +
            (miniMap == null ? 0 : math.max(groupMiniMapWidth, 230) + 10);
        final leftRailBottom =
            safeBottom +
            10 +
            (miniMap == null && safetyCluster != null ? 184 : 0);
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
            if (speedCluster != null)
              Positioned(
                right: safeRight + 10,
                top: safeTop + 10,
                child: speedCluster,
              ),
            // The clock (#452), landscape only, drawn by the app rather than by
            // Apple's widget. Top-centre because that is the one part of this
            // band with nothing in it — the ride menu holds the leading corner
            // and the speed sign the trailing one — and because it is where a car
            // puts its clock. A helmet and gloves make a wrist watch useless and
            // the phone is already in front of the rider.
            if (widget.isNavigating)
              Positioned(
                key: const Key('ride-clock-position'),
                left: safeLeft,
                right: safeRight,
                top: safeTop + 12,
                child: IgnorePointer(
                  child: Center(child: RideClock(darkMap: _basemap.dark)),
                ),
              ),
            Positioned(
              left: safeLeft + 10,
              bottom: leftRailBottom,
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
                  if (_basemapStatus.isFault)
                    _BasemapStatusBadge(
                      status: _basemapStatus,
                      onTap: () => _showMessage(_basemapStatus.explanation),
                    ),
                  for (final alert in urgent)
                    Align(
                      alignment: Alignment.centerRight,
                      child: SizedBox(
                        width: math.max(140, railWidth - 48),
                        child: alert,
                      ),
                    ),
                  if (tecGap != null)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: SizedBox(
                        width: math.min(230, railWidth),
                        child: tecGap,
                      ),
                    ),
                  if (routeProgressPanel != null)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: SizedBox(
                        key: const Key('route-progress-panel-position'),
                        width: math.min(230, railWidth),
                        child: routeProgressPanel,
                      ),
                    ),
                  // The group overview finishes the left status column. It is
                  // deliberately no longer in the rider's traffic-side half.
                  ?miniMap,
                ],
              ),
            ),
            if (safetyCluster != null)
              Positioned(
                key: const Key('map-landscape-action-position'),
                left: actionLeft,
                bottom: safeBottom + 10,
                child: safetyCluster,
              ),
            Positioned(
              right: safeRight + 10,
              bottom: safeBottom + 10,
              width: landscapeGuidanceWidth,
              child: KeyedSubtree(
                key: _landscapeGuidanceKey,
                child: _chromeRail(
                  key: const Key('map-landscape-right-rail'),
                  alignment: CrossAxisAlignment.end,
                  // The card may now extend beneath the rider's horizontal
                  // anchor. Its measured height is fed back into the camera so
                  // the marker remains above it with the normal clearance.
                  children: [?followMe, ?junctionCard, ?guidance],
                ),
              ),
            ),
          ],
        );
      }

      // Portrait keeps only glove targets in the bottom action run. Speed and
      // compass are glance surfaces, so they live at the requested top-right
      // rather than charging the navigation camera for permanent bottom chrome.
      final actionCluster = hasActions ? safetyCluster : null;
      return Stack(
        children: [
          if (rideMenu != null)
            Positioned(
              left: safeLeft + 12,
              top: safeTop + portraitRideMenuTopOffset,
              child: rideMenu,
            ),
          if (routeProgressPanel != null)
            Positioned(
              key: const Key('route-progress-panel-position'),
              left: safeLeft + 12,
              // ETA and the group overview form one aligned header below the
              // persistent menu/clock/speed row.
              top: safeTop + portraitNavigationHeaderTopOffset,
              width: math.min(
                210,
                (MediaQuery.sizeOf(context).width - safeLeft - safeRight) *
                    0.54,
              ),
              child: routeProgressPanel,
            ),
          // The group overview stays paired with ETA below the persistent top
          // controls. It is a glance rather than a target, and keeping it out of
          // the bottom band stops charging the camera's forward bias for a
          // surface nobody acts on.
          if (miniMap != null)
            Positioned(
              right: safeRight + 12,
              top: safeTop + portraitNavigationHeaderTopOffset,
              child: miniMap,
            ),
          if (widget.isNavigating)
            Positioned(
              key: const Key('ride-clock-position'),
              left: safeLeft,
              right: safeRight,
              top: safeTop + 12,
              child: IgnorePointer(
                child: Center(child: RideClock(darkMap: _basemap.dark)),
              ),
            ),
          if (speedCluster != null)
            Positioned(
              right: safeRight + 12,
              top: safeTop + 12,
              child: speedCluster,
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
                  if (_basemapStatus.isFault)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: _BasemapStatusBadge(status: _basemapStatus),
                    ),
                  ...urgent,
                  ?tecGap,
                  // Rare, and its own run: it appears only when the map is off
                  // the rider. It belongs immediately above the turn pane so
                  // returning to follow mode is next to the viewport it affects.
                  if (followMe != null)
                    Align(alignment: Alignment.centerLeft, child: followMe),
                  // The turn banner is the last pane above the permanent
                  // targets, keeping the road ahead clear (#133).
                  ?guidance,
                  ?actionCluster,
                  ?completionSuggestion,
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

  /// Null when there is nothing to draw — a solo ride, or no riders yet.
  ///
  /// Null and not `SizedBox.shrink()`: the landscape layout decides where the
  /// SOS/LEAVE/REPORT cluster goes by asking whether a mini-map exists, and an
  /// invisible widget answers yes. On every solo ride that reserved 240pt of
  /// corner for nothing and exiled the safety cluster to the middle of the
  /// screen (#619) — reported from ride 723888 as "the sos and other buttons
  /// somehow end up aligned to the middle".
  Widget? _buildGroupMiniMap({
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
    if (groupSize <= 1) return null;
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
      localMotorcycleStyle: widget.localMotorcycleStyle,
      localRiderSymbol: widget.localRiderSymbol,
      localDisplayName: widget.localDisplayName,
      onTap: widget.onOpenRoster,
      renderer: groupMiniMapRenderer(
        mapLibreEnabled: _basemap.usesMapLibre,
        platform: defaultTargetPlatform,
      ),
      mapStyleUrl: _basemap.styleUrl,
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
        if (_visiblePersonalHeatmap.cells.isNotEmpty)
          CircleLayer(
            key: const Key('personal-rides-heatmap-layer'),
            circles: [
              for (final cell in _visiblePersonalHeatmap.cells)
                CircleMarker(
                  point: _latLng(cell.centre),
                  radius: 7 + 5 * cell.weight,
                  color: Color.lerp(
                    const Color(0xFF7C3AED),
                    const Color(0xFFF97316),
                    cell.weight,
                  )!.withValues(alpha: 0.16 + 0.24 * cell.weight),
                ),
            ],
          ),
        if (_visibleGlobalHeatmap.cells.isNotEmpty)
          CircleLayer(
            key: const Key('global-rides-heatmap-layer'),
            circles: [
              for (final cell in _visibleGlobalHeatmap.cells)
                CircleMarker(
                  point: _latLng(cell.point),
                  radius: 7 + 5 * cell.weight,
                  color: Color.lerp(
                    const Color(0xFF0EA5E9),
                    const Color(0xFFF59E0B),
                    cell.weight,
                  )!.withValues(alpha: 0.14 + 0.22 * cell.weight),
                ),
            ],
          ),
        if (_visibleDiscoveryFeatures.any((feature) => !feature.isPoint))
          PolylineLayer(
            key: const Key('free-roam-discovery-lines-layer'),
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
        if (_visibleBikerCafes.isNotEmpty)
          MarkerLayer(
            key: const Key('free-roam-biker-cafes-layer'),
            markers: _visibleBikerCafes
                .map(
                  (place) => Marker(
                    point: _latLng(place.point),
                    width: 42,
                    height: 42,
                    child: Semantics(
                      button: true,
                      label: 'Biker café: ${place.name}',
                      child: GestureDetector(
                        onTap: () => _showBikerPlace(place),
                        child: const Icon(
                          Icons.local_cafe,
                          color: Color(0xFFFFC857),
                          size: 30,
                          shadows: [
                            Shadow(color: Color(0xFF10151C), blurRadius: 4),
                          ],
                        ),
                      ),
                    ),
                  ),
                )
                .toList(growable: false),
          ),
        // Actual travelled trails are drawn whether or not a route is loaded,
        // and the leader's trail sits under the remaining planned route so both
        // stay readable where they coincide. Completed *planned* geometry is
        // intentionally absent: the map behind the rider is basemap unless a
        // real rider/group trail records where somebody actually went.
        if (route != null || _visibleRiderTrails.isNotEmpty)
          PolylineLayer(
            polylines: [
              ..._trailPolylines(dashed: false),
              ..._progressGeometry.remainingPaths.map(
                (path) => _routePolyline(path, RouteTrailStyle.routeAhead),
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
            key: const Key('ride-route-waypoint-layer'),
            markers: () {
              // The same decision the MapLibre layer makes, from the same
              // function, so the two renderers cannot drift apart (#574).
              final style = waypointCircleStyle(route.waypoints.length);
              final dense = style.radius < 7;
              return route.waypoints
                  .take(_renderedWaypointLimit)
                  .map(
                    (waypoint) => Marker(
                      point: _latLng(waypoint.point),
                      width: dense ? 14 : 42,
                      height: dense ? 14 : 42,
                      child: dense
                          // A dot, not a pin with a tooltip: at this density
                          // the pins overlap into a solid band and the label
                          // belongs to whichever happens to be on top.
                          ? Opacity(
                              opacity: style.opacity,
                              child: const DecoratedBox(
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: Color(0xFFFFC857),
                                  border: Border.fromBorderSide(
                                    BorderSide(color: Color(0xFF10151C)),
                                  ),
                                ),
                              ),
                            )
                          : Tooltip(
                              message: waypoint.name ?? 'GPX waypoint',
                              child: const Icon(
                                Icons.location_on,
                                color: Color(0xFFFFC857),
                                size: 36,
                              ),
                            ),
                    ),
                  )
                  .toList(growable: false);
            }(),
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
                    child: GestureDetector(
                      key: Key('ride-marker-plan-${point.id}'),
                      onTap: () => unawaited(_showMarkerPlanPoint(point)),
                      child: Tooltip(
                        message: point.label,
                        child: Icon(
                          point.source == MarkerPlanPointSource.manual
                              ? Icons.add_location_alt_outlined
                              : switch (point.kind) {
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
                  symbol: widget.localRiderSymbol,
                  displayName: widget.localDisplayName,
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
                      // A reported hazard gets a larger box than a rider so its
                      // badge is not clipped and so a gloved tap lands: the issue
                      // asks for the tap to work without fine interaction while
                      // moving.
                      width: overlay.hazardSymbol == null ? 42 : 52,
                      height: overlay.hazardSymbol == null ? 42 : 52,
                      child: Tooltip(
                        message: overlay.label,
                        child: _overlayMarkerChild(overlay),
                      ),
                    ),
                  )
                  .toList(growable: false),
            ),
          ),
      ],
    );

    return Stack(
      key: const Key('enforcement-alert-layer'),
      children: [
        Positioned.fill(
          child: ColoredBox(color: const Color(0xFF111820), child: map),
        ),
      ],
    );
  }

  /// Records that the view got as far as loading the style, and asks the tile
  /// endpoint whether it is answering.
  ///
  /// The engine fetches tiles itself and tells the Flutter side nothing, so
  /// without this one request a style that loads over a dead tile endpoint is
  /// a silent blank map — the exact report in #281, and the one case the style
  /// outcome above cannot see.
  Future<void> _onBasemapStyleLoaded() async {
    _basemapViewLoadWatchdog?.cancel();
    _basemapViewLoadWatchdog = null;
    if (mounted && (!_basemapViewLoadedStyle || _basemapViewLoadTimedOut)) {
      setState(() {
        _basemapViewLoadedStyle = true;
        _basemapViewLoadTimedOut = false;
      });
    }
    final style = widget.mapStyleString;
    final reachable = await widget.basemapTileProbe.reachable(
      style,
      client: _routingClient,
    );
    // A style change during the probe makes its answer about the wrong map.
    if (!mounted || style != widget.mapStyleString) return;
    if (reachable == _basemapTilesReachable) return;
    setState(() => _basemapTilesReachable = reachable);
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
            onStyleLoadedCallback: () {
              // Recorded before the app's own layers go on: this callback is
              // the platform's only signal that it read the style at all, and
              // it must not be conditional on the layer set-up below
              // succeeding (#281).
              unawaited(_onBasemapStyleLoaded());
              unawaited(_prepareMapLibreStyle());
            },
            onCameraMove: _onMapLibreCameraMove,
            onCameraIdle: () => unawaited(_updateMapLibreDiscoveryViewport()),
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
            // The platform compass has a fixed diameter and cannot be aligned
            // with TEC's speed sign on every viewport. Ride chrome draws one
            // from the same camera bearing instead.
            compassEnabled: false,
            // Stated rather than inherited: these are ride-map capabilities,
            // and Android field testing specifically depends on both remaining
            // enabled while live overlays and follow mode are active (#248).
            scrollGesturesEnabled: true,
            zoomGesturesEnabled: true,
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

  void _onMapLibreCameraMove(ml.CameraPosition camera) {
    _updateViewportZoom(camera.zoom);
    if ((camera.bearing - _mapBearing.value).abs() >= 0.25) {
      _mapBearing.value = camera.bearing;
    }
    if (kDebugMode) {
      final commanded = _commandedViewport;
      final drift = commanded == null
          ? null
          : _mapDistanceMeters(
              GeoPoint(
                latitude: camera.target.latitude,
                longitude: camera.target.longitude,
              ),
              commanded.target,
            );
      debugPrint(
        'Ride map camera: centre=${camera.target.latitude.toStringAsFixed(6)},'
        '${camera.target.longitude.toStringAsFixed(6)} '
        'zoom=${camera.zoom.toStringAsFixed(2)} '
        'follow=$_navigationMode '
        'commanded=${commanded != null} '
        'drift=${drift?.toStringAsFixed(1) ?? 'n/a'}m '
        'locked=$_cameraArrivedAtCommandedViewport',
      );
    }
    _scheduleCameraFramingRefresh();
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

  /// Restarts the silence window. Called for **every** fix, with or without a
  /// speed, because a fix arriving is evidence the platform is still tracking.
  void _markRiderTrackingObserved() {
    _riderSpeedStalenessTimer?.cancel();
    _riderSpeedStalenessTimer = Timer(_riderSpeedFreshness, _clearRiderSpeed);
    // A second, longer timer that decides what silence *means* (#445).
    //
    // The window above retires the number; this one asks whether the rider
    // stopped. It cannot be the same timer because they answer different
    // questions and a stopped rider must be able to read zero rather than a
    // blank where their speed used to be.
    _riderStoppedTimer?.cancel();
    _riderStoppedTimer = Timer(stoppedSpeedSilence, _resolveSilentSpeed);
  }

  /// Decides whether continued silence means the bike stopped, or that tracking
  /// was lost (#445).
  void _resolveSilentSpeed() {
    if (!mounted) return;
    final reading = stoppedSpeedReading(
      lastObservedSpeedMetersPerSecond: _lastObservedRiderSpeed,
      silence: stoppedSpeedSilence,
    );
    if (reading != StoppedSpeedReading.stopped) return;
    // Not `ageing`: this is a current, believed reading rather than a held one.
    _riderSpeed.value = (value: 0, ageing: false);
  }

  /// Marks a held value as no longer current once it is older than the freshness
  /// window, while fixes are still arriving.
  void _ageRiderSpeedIfStale(DateTime at) {
    final observedAt = _riderSpeedObservedAt;
    if (observedAt == null) return;
    if (at.difference(observedAt) < _riderSpeedFreshness) return;
    if (_riderSpeed.value case final current? when !current.ageing) {
      _riderSpeed.value = (value: current.value, ageing: true);
    }
  }

  /// Clears the readout and the smoother together.
  ///
  /// Leaving the smoother primed with the last moving value would blend it back
  /// in on the first fix after a stop, so a rider pulling away would watch the
  /// number climb out of a stale one instead of reading their real speed.
  void _clearRiderSpeed() {
    _riderSpeedStalenessTimer?.cancel();
    _riderSpeedStalenessTimer = null;
    _riderSpeedObservedAt = null;
    _smoothedNavigationSpeedMetersPerSecond = null;
    _riderSpeed.value = null;
  }

  /// The rotation deadband tightens inside this distance so the map bearing
  /// cannot lag at the junction the rider is being told about.
  static const _maneuverDeadbandTightenMeters = 150.0;

  bool get _maneuverImminent {
    final guidance = _navigationGuidance.value.guidance;
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

  /// Width of the laid-out map, with the screen as the first-frame fallback.
  double get _mapViewportWidthPixels {
    final width = _mapViewportKey.currentContext?.size?.width;
    return width != null && width > 0
        ? width
        : MediaQuery.sizeOf(context).width;
  }

  /// Whether this route is ridden on the left.
  ///
  /// Landscape places the rider two thirds across the frame on the left and one
  /// third across on the right, so getting this wrong does not degrade the view
  /// — it mirrors it. Ride 723888, 17 miles around Bristol, came back with 46
  /// manoeuvres annotated `right` and 23 `left`, so the majority vote this used
  /// to take concluded right-hand traffic and put the bike in the left third of
  /// the screen (#613).
  ///
  /// The asymmetry below is deliberate, and reads the field as the engine seems
  /// to mean it: `left` is only ever emitted where the data says so, while
  /// `right` also arrives where the engine simply has nothing — which is why two
  /// thirds of a British ride came back `right`. So one explicit `left`
  /// outweighs any number of `right`s, and only a route with no `left` anywhere
  /// is treated as right-hand traffic. An unannotated route keeps the product's
  /// UK default, as before.
  ///
  /// The cost of this asymmetry is a genuinely right-hand-traffic route carrying
  /// one spurious `left` step, which would be framed for the UK. That is the
  /// same failure as having no annotation at all, and a mirrored ride is worse.
  bool get _routeUsesLeftHandTraffic {
    var right = 0;
    for (final maneuver in _route?.maneuvers ?? const <RouteManeuver>[]) {
      switch (maneuver.drivingSide?.trim().toLowerCase()) {
        case 'left':
          return true;
        case 'right':
          right += 1;
      }
    }
    return right == 0;
  }

  /// How much of the bottom of the screen an interrupting alert must leave
  /// alone, so SOS and LEAVE stay visible and hittable behind it (#177).
  ///
  /// Portrait reserves the measured bottom band - the same band the navigation
  /// camera biases against - so there is one measurement rather than a constant
  /// that drifts from the layout. Landscape lays the actions out differently, so
  /// a floor clears them.
  double _safetyBandReservedHeight(
    bool landscape, {
    bool reserveLandscapeStack = false,
  }) {
    if (landscape) {
      return reserveLandscapeStack
          ? _landscapeActionStackReservedHeight
          : _landscapeSafetyBandFloor;
    }
    final measured = _measuredBottomChromeHeight;
    return measured > 0 ? measured : _portraitSafetyBandFallback;
  }

  /// Two stacked extended FABs plus their gap and the margin below - what
  /// portrait lays out when SOS sits above LEAVE. Only used before the first
  /// frame has been measured, where covering the controls would be worse than
  /// reserving slightly too much.
  static const _portraitSafetyBandFallback = 132.0;

  /// One extended FAB plus its map-edge clearance. This is enough before a
  /// ride, when the route prompt and LEAVE are the only competing surfaces.
  static const _landscapeSafetyBandFloor = 72.0;

  /// Three 48 px targets, two 8 px gaps, and the map-edge clearance.
  ///
  /// Landscape now stacks ALERT, LEAVE and REPORT vertically (#533). Keeping
  /// the old one-row reserve let an interrupt cover the lower two controls and
  /// absorb their taps.
  static const _landscapeActionStackReservedHeight = 184.0;

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
  /// margin below it. Landscape measures its guidance rail separately.
  double get _bottomChromeHeightPixels {
    final height = _bottomChromeKey.currentContext?.size?.height;
    return height == null ? 0 : height + 12;
  }

  /// The offset the bottom rail is drawn at, which the rail's own height is
  /// measured on top of.
  ///
  /// This is `overlayBottom` in [build], and deliberately the same expression:
  /// the system inset plus the host's bar, if a host stands one on this map.
  /// The comment there says the camera's bottom-chrome fraction "measures this
  /// band too and has to agree with what is drawn in it" — and it did not. The
  /// two measurements below report only how tall the rail is, so the camera was
  /// told a band that started at the bottom of the display while the rail
  /// actually starts this far above it (#608).
  ///
  /// Counted in both orientations, unlike the two below: the system inset and a
  /// host's bar are both full width, so there is no orientation in which the
  /// marker escapes them.
  double get _overlayBottomInsetPixels =>
      MediaQuery.paddingOf(context).bottom +
      (widget.hostChrome?.bottomInset ?? 0);

  /// Height of the wider bottom-right landscape guidance rail, including its
  /// margin from the display edge. The camera uses this exactly as portrait
  /// uses its bottom band whenever the card extends beneath the rider anchor.
  double get _landscapeGuidanceHeightPixels {
    final height = _landscapeGuidanceKey.currentContext?.size?.height;
    return height == null ? 0 : height + 10;
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
    final viewportWidth = _mapViewportWidthPixels;
    final plan = NavigationCameraPlanner.plan(
      speedMetersPerSecond:
          _smoothedNavigationSpeedMetersPerSecond ??
          _navigationFix?.speedMetersPerSecond,
      landscape: landscape,
      viewportHeightPixels: viewportHeight,
      viewportWidthPixels: viewportWidth,
      latitudeDegrees: position.latitude,
      bottomChromeFraction: viewportHeight <= 0
          ? 0
          : ((landscape
                        ? _landscapeGuidanceHeightPixels
                        : _bottomChromeHeightPixels) +
                    _overlayBottomInsetPixels) /
                viewportHeight,
      leftHandTraffic: _routeUsesLeftHandTraffic,
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
    final lateralOffset = NavigationCameraPlanner.lateralTargetOffsetMetersFor(
      zoom: plan.zoom,
      lateralBiasPixels: plan.lateralBiasPixels,
      latitudeDegrees: position.latitude,
      tileSize: _basemap.usesMapLibre ? 512 : 256,
    );
    var target = lookAhead == 0
        ? position
        : _pointAhead(position, _cameraBearingDegrees, lookAhead);
    if (lateralOffset != 0) {
      target = _pointAhead(
        target,
        _cameraBearingDegrees + (lateralOffset > 0 ? 90 : -90),
        lateralOffset.abs(),
      );
    }
    return (target: target, plan: plan);
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
    if (navigationFix != null) {
      if (navigationFix == _lastHandledNavigationFix) return;
      _lastHandledNavigationFix = navigationFix;
      _lastHandledCurrentPosition = null;
    } else {
      if (_sameMapPoint(position, _lastHandledCurrentPosition)) return;
      _lastHandledCurrentPosition = position;
      _lastHandledNavigationFix = null;
    }
    _finishRouteStartConnectorIfReached(position);
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
    if (navigationFix != null) {
      // Any fix, with or without a speed, proves the platform is still tracking,
      // so it restarts the silence window that #210 relies on.
      final at = navigationFix.recordedAt;
      _markRiderTrackingObserved();
      if (navigationFix.speedMetersPerSecond case final speed?
          when speed.isFinite) {
        final boundedSpeed = speed.clamp(0.0, 50.0);
        final previousSpeed = _smoothedNavigationSpeedMetersPerSecond;
        _smoothedNavigationSpeedMetersPerSecond = previousSpeed == null
            ? boundedSpeed
            : previousSpeed * 0.72 + boundedSpeed * 0.28;
        _riderSpeedObservedAt = at;
        // Kept past the readout being retired: it is what tells a stop apart
        // from a lost signal when the fixes go quiet (#445).
        _lastObservedRiderSpeed = _smoothedNavigationSpeedMetersPerSecond;
        _riderSpeed.value = (
          value: _smoothedNavigationSpeedMetersPerSecond!,
          ageing: false,
        );
      } else {
        // Deliberately does not clear. Clearing here is what made the readout
        // flicker on a real ride (#285): on Android plenty of fixes carry no
        // speed, so the number was wiped several times a minute while the rider
        // was moving normally. The held value is marked as no longer current
        // instead, and genuine silence still retires it above.
        _ageRiderSpeedIfStale(at);
      }
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
    // As in `_loadPersistedRoute`: a position is not a reason to take the whole
    // screen away from the chrome. Navigating or moving is (#600).
    final activateNavigationCanvas =
        position != null &&
        (widget.isNavigating || _isMoving) &&
        !_navigationCanvasActive;
    if (refreshProgress) {
      _progressGeometry = _routeProgressTracker.update(_route, position);
      _rejoinProgressGeometry = _rejoinProgressTracker.update(
        _rejoinRoute,
        position,
      );
      _updateNavigationGuidance(position);
    }
    _observeSpeedLimit(navigationFix);
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
    final location = SpeedLimitLocation(
      point: fix.point,
      recordedAt: fix.recordedAt,
      accuracyMeters: fix.accuracyMeters,
      headingDegrees: fix.headingDegrees,
    );
    _speedLimitDisplay.observe(location);
    _speedLimitDisplay.prefetchAhead(
      current: location,
      routeAhead:
          _navigationProgressGeometry.remainingPaths.firstOrNull ??
          const <GeoPoint>[],
    );
  }

  void _updateNavigationGuidance(GeoPoint? position) {
    final navigationRoute = _rejoinRoute ?? _route;
    final next = _navigationGuidancePlanner.assess(
      route: navigationRoute,
      position: position,
      progressMeters: _navigationProgressGeometry.progressMeters,
    );
    final current = _navigationGuidance.value;
    final visibilityChanged = current.isVisible != next.isVisible;
    final stateChanged = current.state != next.state;
    final unchanged =
        current.guidance?.maneuver == next.guidance?.maneuver &&
        current.guidance != null &&
        next.guidance != null &&
        (current.guidance!.distanceMeters - next.guidance!.distanceMeters)
                .abs() <
            5;
    if (!unchanged) {
      _navigationGuidance.value = next;
      widget.onNavigationGuidanceChanged?.call(next.guidance);
      if (stateChanged && kDebugMode) {
        debugPrint('Navigation guidance: ${next.state.name} — ${next.message}');
      }
      if ((visibilityChanged || stateChanged) && mounted) setState(() {});
    }
  }

  void _onRejoinNavigationRouteChanged() {
    if (_externalRejoinRoute != null && _routeStartConnector != null) {
      setState(() {
        _setRouteStartConnector(null);
        _rejoinProgressTracker.reset();
      });
    }
    _rejoinProgressGeometry = _rejoinProgressTracker.update(
      _rejoinRoute,
      _effectivePosition,
    );
    _updateNavigationGuidance(_effectivePosition);
    _observeSpeedLimit(_navigationFix);
    _scheduleMapLibreSync(progress: true, overlays: true);
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
    _updateViewportZoom(event.camera.zoom);
    if ((event.camera.rotation - _mapBearing.value).abs() >= 0.25) {
      _mapBearing.value = event.camera.rotation;
    }
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
    if (event is MapEventMoveEnd ||
        event is MapEventFlingAnimationEnd ||
        event is MapEventDoubleTapZoomEnd ||
        event is MapEventScrollWheelZoom) {
      final bounds = event.camera.visibleBounds;
      _setDiscoveryViewportCorners([
        GeoPoint(latitude: bounds.south, longitude: bounds.west),
        GeoPoint(latitude: bounds.north, longitude: bounds.east),
      ]);
    }
  }

  Future<void> _updateMapLibreDiscoveryViewport() async {
    final controller = _mapLibreController;
    if (controller == null) return;
    try {
      final bounds = await controller.getVisibleRegion();
      _setDiscoveryViewportCorners([
        GeoPoint(
          latitude: bounds.southwest.latitude,
          longitude: bounds.southwest.longitude,
        ),
        GeoPoint(
          latitude: bounds.northeast.latitude,
          longitude: bounds.northeast.longitude,
        ),
      ]);
    } on Object catch (error) {
      if (kDebugMode) {
        debugPrint('Could not update discovery viewport: $error');
      }
    }
  }

  void _setDiscoveryViewportCorners(List<GeoPoint> corners) {
    final previous = _discoveryViewportCorners;
    if (previous != null &&
        previous.length == corners.length &&
        List.generate(
          corners.length,
          (index) =>
              (previous[index].latitude - corners[index].latitude).abs() <
                  0.001 &&
              (previous[index].longitude - corners[index].longitude).abs() <
                  0.001,
        ).every((same) => same)) {
      _scheduleGlobalHeatmapRefresh();
      return;
    }
    if (!mounted) return;
    setState(() => _discoveryViewportCorners = corners);
    _scheduleMapLibreSync(overlays: true);
    _scheduleGlobalHeatmapRefresh();
  }

  void _updateViewportZoom(double zoom) {
    final wasVisible = motorcycleDiscoveryVisibleAtZoom(_lastViewportZoom);
    _lastViewportZoom = zoom;
    final isVisible = motorcycleDiscoveryVisibleAtZoom(zoom);
    if (!mounted || wasVisible == isVisible) return;
    setState(() {});
    _scheduleMapLibreSync(overlays: true);
  }

  void _onMapPointerDown(PointerDownEvent event) {
    _mapPointerOrigins[event.pointer] = event.localPosition;
    if (_mapPointerOrigins.length > 1) {
      if (kDebugMode) {
        debugPrint('Ride map gesture: pinch started; handing camera to rider.');
      }
      _suppressFollowForMapGesture();
    }
  }

  void _onMapPointerMove(PointerMoveEvent event) {
    final origin = _mapPointerOrigins[event.pointer];
    if (origin != null && (event.localPosition - origin).distance >= 8) {
      if (kDebugMode) {
        debugPrint(
          'Ride map gesture: pan threshold crossed; handing camera to rider.',
        );
      }
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
          !_dismissedQuickMessageReceipts.contains(alert.message.eventId) &&
          !widget.dismissedQuickMessageReceiptIds.contains(
            alert.message.eventId,
          )) {
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
          !_dismissedQuickMessageInterrupts.contains(alert.message.eventId) &&
          !widget.dismissedQuickMessageInterruptIds.contains(
            alert.message.eventId,
          )) {
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
          onCallContact: _callEmergencyContact,
          onMessageContact: _messageEmergencyContact,
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

  /// Rings a coordination role on the number they themselves shared (#188).
  ///
  /// Only ever reached from a row whose contact carries a number, so there is no
  /// path that dials an ICE contact by mistake: an ICE number never populates
  /// [MapEmergencyContact].
  Future<void> _callEmergencyContact(MapEmergencyContact contact) =>
      _launchEmergencyContact(contact, scheme: 'tel');

  /// Texts a coordination role, with the rider's position already in the body —
  /// the same body #173 put in the contacts-book fallback, because "I have
  /// stopped" is not actionable without where.
  Future<void> _messageEmergencyContact(MapEmergencyContact contact) =>
      _launchEmergencyContact(contact, scheme: 'sms');

  Future<void> _launchEmergencyContact(
    MapEmergencyContact contact, {
    required String scheme,
  }) async {
    final number = contact.phoneNumber;
    if (number == null || number.isEmpty) return;
    widget.onEmergencyContactUsed?.call(contact);
    final opened = await launchUrl(
      Uri(
        scheme: scheme,
        path: number,
        queryParameters: scheme == 'sms'
            ? {'body': emergencyMessageBody(_effectivePosition)}
            : null,
      ),
      mode: LaunchMode.externalApplication,
    );
    if (!opened && mounted) {
      _showMessage('Could not reach ${contact.displayName} from this device.');
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
      final markerBounds = _mapLibreBounds(cameraPoints);
      if (!_boundsAreUsable(markerBounds)) return;
      await controller.animateCamera(
        ml.CameraUpdate.newLatLngBounds(
          markerBounds,
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
    widget.onNavigationViewportChanged?.call(
      NavigationCameraViewport(
        latitude: framing.target.latitude,
        longitude: framing.target.longitude,
        zoom: cameraPlan.zoom,
        tilt: _basemap.usesMapLibre ? cameraPlan.tilt : 0,
        bearing: _cameraBearingDegrees,
        sourceViewportHeightPixels: _mapViewportHeightPixels,
        sourceViewportWidthPixels: _mapViewportWidthPixels,
        riderViewportFraction: cameraPlan.riderViewportFraction,
        riderHorizontalViewportFraction:
            cameraPlan.riderHorizontalViewportFraction,
        leftHandTraffic: _routeUsesLeftHandTraffic,
        mapStyleUrl: _basemap.styleUrl,
        mapStyleJson: widget.mapStyleString,
      ),
    );
    // MapLibre throws out of a C++ constructor on a coordinate that is not
    // finite, and the throw takes the app with it (#359). The follow target is
    // a ground point projected from the tilt, zoom and measured viewport
    // height, so a viewport that has not been laid out - zero height - divides
    // through that geometry and produces one. Dropping the command costs
    // nothing visible: the next position fix issues another.
    if (!MapCameraCommand.isUsable(
      latitude: framing.target.latitude,
      longitude: framing.target.longitude,
      zoom: cameraPlan.zoom,
      tilt: cameraPlan.tilt,
      bearing: _cameraBearingDegrees,
    )) {
      return;
    }
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

  /// The badge for one overlay marker in the flutter_map fallback.
  ///
  /// A reported hazard draws [HazardMapSymbolPainter] - the same painter the
  /// MapLibre images are baked from - and answers a tap the way the native
  /// renderer does, so the two behave the same rather than one of them needing a
  /// long press to reveal a tooltip (#141).
  Widget _overlayMarkerChild(MapOverlayMarker overlay) {
    final hazard = overlay.hazardSymbol;
    if (hazard != null) {
      return GestureDetector(
        onTap: () => _showMessage(overlay.label),
        child: HazardMapSymbolBadge(symbol: hazard),
      );
    }
    final style = overlay.motorcycleStyle;
    return style == null
        ? _IconBadge(icon: overlay.icon, badgeColor: overlay.color, size: 34)
        : RiderMarkerBadge(
            style: style,
            symbol: overlay.riderSymbol,
            displayName: overlay.riderDisplayName ?? overlay.label,
            badgeColor: overlay.color,
            size: 34,
          );
  }

  static const _hazardIconImage = 'ride-relay-hazard-warning';
  bool _markerImagesRegistered = false;
  final Set<String> _registeredRiderSymbolImages = {};

  Future<void> _registerMarkerImages(
    ml.MapLibreMapController controller,
  ) async {
    if (_markerImagesRegistered) {
      await _ensureRiderSymbolImages(controller);
      return;
    }
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
    // Every hazard badge the map can draw, baked from the shared painter. Full
    // colour, so registered with `sdf: false` and drawn by its own layer, which
    // applies no `icon-color`: the fill and the ring are artwork rather than
    // layer paint, because the flutter_map fallback has no layer paint to match
    // them with.
    for (final symbol in HazardMapSymbols.catalogue) {
      await controller.addImage(
        symbol.imageName,
        await rasterizeHazardMapSymbolPng(symbol),
        false,
      );
    }
    await controller.addImage(
      _trailDirectionArrowImage,
      await rasterizeIconGlyphPng(Icons.navigation_rounded),
      true,
    );
    _markerImagesRegistered = true;
    await _ensureRiderSymbolImages(controller);
  }

  Future<void> _ensureRiderSymbolImages(
    ml.MapLibreMapController controller,
  ) async {
    final riders =
        <({RiderSymbol symbol, String displayName, MotorcycleIconStyle style})>[
          (
            symbol: widget.localRiderSymbol,
            displayName: widget.localDisplayName,
            style: widget.localMotorcycleStyle,
          ),
          for (final overlay
              in widget.overlayMarkers?.value ?? const <MapOverlayMarker>[])
            if (overlay.motorcycleStyle case final style?)
              (
                symbol: overlay.riderSymbol,
                displayName: overlay.riderDisplayName ?? overlay.label,
                style: style,
              ),
        ];
    for (final rider in riders) {
      if (rider.symbol.kind == RiderSymbolKind.motorcycle) continue;
      final imageName = rider.symbol.imageName(rider.displayName, rider.style);
      if (!_registeredRiderSymbolImages.add(imageName)) continue;
      final raster = await rasterizeRiderSymbolPng(
        symbol: rider.symbol,
        displayName: rider.displayName,
        motorcycleStyle: rider.style,
      );
      await controller.addImage(imageName, raster.bytes, raster.sdf);
    }
  }

  Future<void> _prepareMapLibreStyle() async {
    final controller = _mapLibreController;
    if (controller == null) return;
    _mapLibreStyleReady = false;
    try {
      await _registerMarkerImages(controller);
      await controller.addGeoJsonSource(
        _globalHeatmapSource,
        _visibleGlobalHeatmap.toGeoJson(),
      );
      await controller.addHeatmapLayer(
        _globalHeatmapSource,
        _globalHeatmapLayer,
        const ml.HeatmapLayerProperties(
          heatmapRadius: [
            'interpolate',
            ['linear'],
            ['zoom'],
            5,
            4,
            12,
            10,
            17,
            18,
          ],
          heatmapWeight: ['get', 'weight'],
          heatmapIntensity: 0.8,
          heatmapColor: [
            'interpolate',
            ['linear'],
            ['heatmap-density'],
            0,
            'rgba(14,165,233,0)',
            0.25,
            '#0EA5E9',
            0.7,
            '#F59E0B',
            1,
            '#EF4444',
          ],
          heatmapOpacity: 0.42,
        ),
      );
      await controller.addGeoJsonSource(
        _personalHeatmapSource,
        _visiblePersonalHeatmap.toGeoJson(),
      );
      await controller.addHeatmapLayer(
        _personalHeatmapSource,
        _personalHeatmapLayer,
        const ml.HeatmapLayerProperties(
          heatmapRadius: [
            'interpolate',
            ['linear'],
            ['zoom'],
            5,
            4,
            12,
            10,
            17,
            18,
          ],
          heatmapWeight: ['get', 'weight'],
          heatmapIntensity: 0.85,
          heatmapColor: [
            'interpolate',
            ['linear'],
            ['heatmap-density'],
            0,
            'rgba(124,58,237,0)',
            0.25,
            '#7C3AED',
            0.65,
            '#C2410C',
            1,
            '#F97316',
          ],
          heatmapOpacity: 0.48,
        ),
      );
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
          // Read off each feature so a route that gains or loses waypoints
          // restyles with its source, without rebuilding the layer (#574).
          circleRadius: ['get', 'radius'],
          circleOpacity: ['get', 'opacity'],
          circleColor: '#FFC857',
          circleStrokeWidth: 2,
          circleStrokeColor: '#10151C',
          circleStrokeOpacity: ['get', 'opacity'],
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
          circleRadius: _localBadgeRadius,
          circleColor: _hexColor(widget.localBadgeColor),
          circleStrokeWidth: 3,
          circleStrokeColor: _hexColor(
            riderBadgeStrokeColor(widget.localBadgeColor),
          ),
        ),
        enableInteraction: false,
      );
      await controller.addSymbolLayer(
        _positionSource,
        'ride-relay-position-icon',
        ml.SymbolLayerProperties(
          iconImage: widget.localRiderSymbol.imageName(
            widget.localDisplayName,
            widget.localMotorcycleStyle,
          ),
          // Dark on a light badge: see [RouteTrailStyle.markerGlyph] (#133).
          iconColor: RouteTrailStyle.markerGlyphHex,
          // One image, so the size is settled here rather than per feature —
          // but by the same rule the other rider layers use (#259).
          iconSize: widget.localRiderSymbol.kind == RiderSymbolKind.initials
              ? riderInitialsIconSize(badgeDiameter: _localBadgeRadius * 2)
              : 0.2,
          iconAllowOverlap: true,
          iconIgnorePlacement: true,
        ),
        enableInteraction: false,
      );
      await controller.addGeoJsonSource(_overlaySource, _overlayGeoJson());
      // A colour alone was hard to pick out against some basemaps. A solid
      // badge behind a fixed-white glyph reads clearly regardless of what's
      // underneath, and matches the "you are here" marker's badge look.
      //
      // Riders only. A reported hazard brings its own complete badge as one
      // image, so a circle drawn under it would show through the corners of the
      // enforcement plate.
      await controller.addCircleLayer(
        _overlaySource,
        'ride-relay-overlay-badges',
        ml.CircleLayerProperties(
          circleRadius: _riderBadgeRadius,
          circleColor: ['get', 'color'],
          circleStrokeWidth: 2,
          circleStrokeColor: '#10151C',
        ),
        filter: _riderOverlayFilter,
        enableInteraction: false,
      );
      await controller.addSymbolLayer(
        _overlaySource,
        'ride-relay-overlay-icons',
        ml.SymbolLayerProperties(
          iconImage: ['get', 'iconImage'],
          // As above: the badge carries the colour, the glyph carries the shape,
          // and a dark glyph is the only way the shape survives on a light badge.
          iconColor: RouteTrailStyle.markerGlyphHex,
          iconSize: _riderIconSize(_riderBadgeRadius * 2, 0.19),
          iconAllowOverlap: true,
          iconIgnorePlacement: true,
        ),
        filter: _riderOverlayFilter,
      );
      // Reported cameras, police sightings and road defects (#135). One layer,
      // one constant size, no paint properties: everything that distinguishes a
      // fresh camera from a fading police sighting is in the image, drawn by the
      // painter the fallback renderer also uses.
      await controller.addSymbolLayer(
        _overlaySource,
        _hazardSymbolLayer,
        const ml.SymbolLayerProperties(
          iconImage: ['get', 'iconImage'],
          iconSize: 1 / hazardMapSymbolRasterScale,
          iconAllowOverlap: true,
          iconIgnorePlacement: true,
        ),
        filter: _hazardOverlayFilter,
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
      await _ensureRiderSymbolImages(controller);
      await controller.setGeoJsonSource(
        _globalHeatmapSource,
        _visibleGlobalHeatmap.toGeoJson(),
      );
      await controller.setGeoJsonSource(
        _personalHeatmapSource,
        _visiblePersonalHeatmap.toGeoJson(),
      );
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
      if (position || overlays) {
        await _ensureRiderSymbolImages(controller);
      }
      if (progress) {
        await controller.setGeoJsonSource(
          _remainingRouteSource,
          _remainingRouteGeoJson(),
        );
      }
      if (position) {
        await controller.setGeoJsonSource(_positionSource, _positionGeoJson());
      }
      if (overlays) {
        await controller.setGeoJsonSource(
          _globalHeatmapSource,
          _visibleGlobalHeatmap.toGeoJson(),
        );
        await controller.setGeoJsonSource(
          _personalHeatmapSource,
          _visiblePersonalHeatmap.toGeoJson(),
        );
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
  List<MapOverlayTrace> get _visibleRiderTrails {
    final connector = _externalRejoinRoute == null
        ? _routeStartConnector
        : null;
    return [
      ...(widget.riderTrails?.value ?? const <MapOverlayTrace>[]),
      if (connector != null)
        MapOverlayTrace(
          id: 'route-start-connector',
          points: connector.paths
              .expand((path) => path.points)
              .toList(growable: false),
          label: 'Route to planned start',
          kind: RiderTrailKind.rejoin,
        ),
    ].where((trace) => trace.points.length >= 2).toList(growable: false);
  }

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

  /// Which lines carry direction arrows, in priority order.
  ///
  /// The planned route comes first and against its own reserve. It is the base
  /// line of the map and the one a rider reads *before* setting off, when there
  /// is no ridden path and no trail — which is how it came to have no arrows at
  /// all (#363): every source of them was something that only exists once the
  /// ride is already moving.
  ///
  /// The selection itself lives in `selectTrailDirectionArrows` so it can be
  /// asserted. Nothing here decides how many arrows anything gets.
  List<_StyledTrailDirectionArrow> _trailDirectionArrows() {
    // Whole-group rides can hold more trail than the arrow budget allows, so
    // the cues a rider needs to interpret someone else's path come before the
    // ordinary ones.
    final byImportance = _visibleRiderTrails.toList()
      ..sort(
        (first, second) =>
            _arrowPriority(first.kind).compareTo(_arrowPriority(second.kind)),
      );
    final selected = selectTrailDirectionArrows<_TrailArrowStyle>(
      sampler: _trailDirectionArrowSampler,
      sources: [
        TrailDirectionArrowSource(
          paths: _progressGeometry.remainingPaths,
          reserve: _plannedRouteArrowReserve,
          style: _TrailArrowStyle(
            color: RouteTrailStyle.routeAhead.color,
            idPrefix: 'route-ahead',
            semanticLabel: 'Route direction',
          ),
        ),
        for (final trace in byImportance)
          TrailDirectionArrowSource(
            paths: [trace.points],
            style: _TrailArrowStyle(
              color: trace.style.color,
              idPrefix: trace.id,
              semanticLabel: '${trace.label} direction',
            ),
          ),
      ],
    );
    return [
      for (final (index, item) in selected.indexed)
        _StyledTrailDirectionArrow(
          id: '${item.style.idPrefix}-$index',
          arrow: item.arrow,
          color: item.style.color,
          semanticLabel: item.style.semanticLabel,
        ),
    ];
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

  /// Discovery data is a national catalogue. Feeding every road and café into
  /// Flutter's fallback renderer made opening the free-roam map build thousands
  /// of off-screen widgets. Keep the layer local to the route/rider; MapLibre
  /// receives the same bounded set, so both renderers behave consistently.
  List<GeoPoint> get _discoveryAnchorPoints {
    if (_discoveryViewportCorners case final viewport?) return viewport;
    final routePoints = _route?.allPoints.toList(growable: false) ?? const [];
    if (routePoints.isNotEmpty) return routePoints;
    return [?_effectivePosition];
  }

  List<MotorcycleDiscoveryFeature> get _visibleDiscoveryFeatures {
    if (!motorcycleDiscoveryVisibleAtZoom(_lastViewportZoom)) return const [];
    final anchors = _discoveryAnchorPoints;
    if (anchors.isEmpty || _enabledDiscoveryCategories.isEmpty) return const [];
    var west = anchors.first.longitude;
    var east = west;
    var south = anchors.first.latitude;
    var north = south;
    for (final point in anchors.skip(1)) {
      west = math.min(west, point.longitude);
      east = math.max(east, point.longitude);
      south = math.min(south, point.latitude);
      north = math.max(north, point.latitude);
    }
    const paddingDegrees = 0.6;
    return _discoveryCatalogue.visible(
      categories: _enabledDiscoveryCategories,
      west: west - paddingDegrees,
      south: south - paddingDegrees,
      east: east + paddingDegrees,
      north: north + paddingDegrees,
    );
  }

  List<BikerPlace> get _visibleBikerCafes =>
      _bikerCafesVisible && motorcycleDiscoveryVisibleAtZoom(_lastViewportZoom)
      ? _bikerPlaceCatalogue
            .nearRoute(_discoveryAnchorPoints)
            .where((place) => place.isCafe)
            .toList(growable: false)
      : const [];

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

  Map<String, dynamic> _discoveryPointGeoJson() => MapGeoJson.points([
    for (final feature in _visibleDiscoveryFeatures)
      MapGeoJsonPoint(
        id: feature.id,
        point: feature.anchor,
        properties: {
          'name': feature.name,
          'category': feature.category.apiValue,
          'color': _hexColor(_discoveryColour(feature.category)),
        },
      ),
    for (final place in _visibleBikerCafes)
      MapGeoJsonPoint(
        id: 'biker-cafe-${place.id}',
        point: place.point,
        properties: {
          'name': place.name,
          'category': 'biker_cafe',
          'color': '#FFC857',
        },
      ),
  ]);

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

  Map<String, dynamic> _waypointGeoJson() {
    final waypoints = _route?.waypoints ?? const <RouteWaypoint>[];
    final style = waypointCircleStyle(waypoints.length);
    return MapGeoJson.points(
      waypoints
          .take(_renderedWaypointLimit)
          .indexed
          .map(
            (entry) => MapGeoJsonPoint(
              id: 'waypoint-${entry.$1}',
              point: entry.$2.point,
              properties: {
                'label': entry.$2.name ?? 'GPX waypoint',
                'radius': style.radius,
                'opacity': style.opacity,
              },
            ),
          ),
    );
  }

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

  /// Layer holding the reported-hazard badges (#135).
  static const _hazardSymbolLayer = 'ride-relay-hazard-symbols';

  /// Which overlay features each of the two badge families draws.
  ///
  /// A single flag on the feature rather than a test on its icon name, so the
  /// filters and the GeoJSON writer below cannot drift apart.
  static const _hazardOverlayFilter = [
    '==',
    ['get', 'hazardSymbol'],
    true,
  ];
  static const _riderOverlayFilter = [
    '!=',
    ['get', 'hazardSymbol'],
    true,
  ];

  /// Radius of the coloured badge behind another rider's glyph.
  static const _riderBadgeRadius = 15.0;

  /// Radius of the local rider's own badge, which is drawn a little larger.
  static const _localBadgeRadius = 16.0;

  /// `icon-size` for a rider glyph, as an expression that gives initials their
  /// own size.
  ///
  /// A bike or an emoji is a pictogram: it sits *inside* the badge, and
  /// [pictogramIconSize] is the value each layer already had for one, passed
  /// through untouched so no bike or emoji moves by a pixel. Initials are not a
  /// pictogram — they are meant to fill the circle — and inheriting the
  /// pictogram's size is what left them at about three quarters of what the
  /// symbol picker's preview promised (#259). Theirs is derived from the badge
  /// instead, by the one rule in `motorcycle_icon.dart`, so the three rider
  /// layers and the picker cannot answer differently again.
  static Object _riderIconSize(
    double badgeDiameter,
    double pictogramIconSize,
  ) => <Object>[
    'case',
    <Object>['get', 'initialsSymbol'],
    riderInitialsIconSize(badgeDiameter: badgeDiameter),
    pictogramIconSize,
  ];

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
              'hazardSymbol': overlay.hazardSymbol != null,
              'iconImage': _overlayIconImage(overlay),
              'initialsSymbol':
                  overlay.hazardSymbol == null &&
                  overlay.riderSymbol.kind == RiderSymbolKind.initials,
            },
          ),
        ),
  );

  String _overlayIconImage(MapOverlayMarker overlay) {
    final hazardImage = overlay.hazardSymbol?.imageName;
    if (hazardImage != null) return hazardImage;
    final style = overlay.motorcycleStyle;
    if (style == null) return _hazardIconImage;
    return overlay.riderSymbol.imageName(
      overlay.riderDisplayName ?? overlay.label,
      style,
    );
  }

  void _onMapLibreFeatureTapped(
    math.Point<double> point,
    ml.LatLng coordinates,
    String id,
    String layerId,
    ml.Annotation? annotation,
  ) {
    if (layerId == 'ride-relay-discovery-lines' ||
        layerId == 'ride-relay-discovery-points') {
      if (id.startsWith('biker-cafe-')) {
        final placeId = id.substring('biker-cafe-'.length);
        final place = _bikerPlaceCatalogue.places
            .where((place) => place.id == placeId)
            .firstOrNull;
        if (place != null) unawaited(_showBikerPlace(place));
        return;
      }
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
      if (point != null) unawaited(_showMarkerPlanPoint(point));
      return;
    }
    if (layerId != 'ride-relay-overlay-icons' &&
        layerId != _hazardSymbolLayer &&
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
          preferences: request.preferences,
        );
        final review = await _reviewRoute(
          planned.route,
          distanceMeters: planned.distanceMeters,
          duration: planned.duration,
          twistinessScore: planned.twistinessScore,
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

  Future<void> _planCircularRide() async {
    if (_routing) return;
    var origin = _effectivePosition;
    origin ??= await widget.acquireCurrentPosition?.call();
    origin ??= _effectivePosition;
    if (origin == null || !mounted) {
      _showMessage(
        'Enable location so the circular ride can start and finish here.',
      );
      return;
    }
    var request = await CircularRideSheet.show(
      context,
      start: origin,
      distanceUnit: widget.distanceUnit,
      personalHeatmapCells: _personalCircularHeatCells,
      globalHeatmapCells: _globalCircularHeatCells,
    );
    while (request != null && mounted) {
      final requestedRide = request;
      setState(() => _routing = true);
      try {
        final preparedRequest = await _withSuggestedDayRideStops(requestedRide);
        final planner = CircularRidePlanner(
          routingService: _roadRoutingService,
        );
        var plan = await planner.generate(preparedRequest);
        if (!mounted) return;
        final review = await _reviewRoute(
          plan.route,
          distanceMeters: plan.actualDistanceMeters,
          duration: plan.duration,
          twistinessScore: plan.twistinessScore,
          warnings: _circularRideReviewWarnings(plan),
          canEditStops: true,
          canGenerateAlternative: true,
          onGenerateAlternative: () async {
            final alternativeRequest = await _withSuggestedDayRideStops(
              plan.request.another(),
            );
            plan = await planner.generate(alternativeRequest);
            return RouteReviewAlternative(
              route: plan.route,
              distanceMeters: plan.actualDistanceMeters,
              duration: plan.duration,
              twistinessScore: plan.twistinessScore,
              warnings: _circularRideReviewWarnings(plan),
            );
          },
        );
        if (!mounted) return;
        if (review.action == RouteReviewAction.another) {
          request = plan.request.another();
          continue;
        }
        if (review.action == RouteReviewAction.edit) {
          request = await CircularRideSheet.show(
            context,
            start: origin,
            distanceUnit: widget.distanceUnit,
            personalHeatmapCells: _personalCircularHeatCells,
            globalHeatmapCells: _globalCircularHeatCells,
          );
          continue;
        }
        if (review.action == RouteReviewAction.confirm) {
          final library =
              widget.recordedRouteStore ??
              await JsonFileRecordedRouteStore.openDefault();
          await saveCircularRideToLibrary(review.route, library);
          final route = await _commitRoute(review.route);
          _showMessage('${route.name} saved to the Ride Library.');
        }
        return;
      } on FormatException catch (error) {
        _showMessage(error.message);
        return;
      } on Object catch (error) {
        _showMessage('Could not generate the circular ride: $error');
        return;
      } finally {
        if (mounted) setState(() => _routing = false);
      }
    }
  }

  List<String> _circularRideReviewWarnings(CircularRidePlan plan) {
    final request = plan.request;
    return [
      'The distance is approximate because the road network decides the final loop.',
      ...plan.warnings,
      if (request.dayLength != RideDayLength.custom)
        'Fuel, bathroom/comfort and meal stops are suggestions. Edit each one and verify opening hours and facilities before accepting.',
      if (request.heatmapPreference != CircularRideHeatmapPreference.none &&
          circularRideHeatmapBiasAvailable(
            request.heatmapCells,
            start: request.start,
          ))
        '${request.heatmapPreference.label} gently influenced the shaping controls; it did not require the route to use those roads.',
    ];
  }

  Future<CircularRideRequest> _withSuggestedDayRideStops(
    CircularRideRequest request,
  ) async {
    final rideDuration = request.dayLength.duration;
    if (rideDuration == null) return request.withPlannedStops(const []);
    var catalogue = _bikerPlaceCatalogue;
    if (catalogue.places.isEmpty) {
      catalogue = await BikerPlaceCatalogue.loadAsset();
    }
    final schedule = circularRideItinerary(request);
    final shapes = circularRideShapingPoints(request);
    final used = <String>{};
    final planned = <CircularRideStop>[];
    for (final scheduled in schedule) {
      final fraction = scheduled.after.inMinutes / rideDuration.inMinutes;
      final target = shapes[math.min(2, (fraction * 3).floor())];
      final needsMeal = scheduled.kinds.contains(CircularRideStopKind.meal);
      BikerPlace? nearest;
      if (needsMeal) {
        final candidates =
            catalogue.places
                .where((place) => place.isCafe && !used.contains(place.id))
                .map(
                  (place) => (
                    place: place,
                    distance: _mapDistanceMeters(target, place.point),
                  ),
                )
                .where((candidate) => candidate.distance <= 50000)
                .toList()
              ..sort(
                (first, second) => first.distance.compareTo(second.distance),
              );
        nearest = candidates.firstOrNull?.place;
        if (nearest != null) used.add(nearest.id);
      }
      final needs = _circularStopNeedsLabel(scheduled.kinds);
      planned.add(
        CircularRideStop(
          fraction: fraction,
          kinds: scheduled.kinds,
          scheduledAfter: scheduled.after,
          waypoint: RouteWaypoint(
            point: nearest?.point ?? target,
            name: nearest == null
                ? 'Suggested $needs stop area'
                : 'Suggested $needs · ${nearest.name}',
            description:
                nearest?.address ??
                'No verified nearby facility was available. Choose a suitable open stop near this point before accepting the route.',
            symbol: needsMeal
                ? 'Restaurant'
                : scheduled.kinds.contains(CircularRideStopKind.fuel)
                ? 'Gas Station'
                : 'Restroom',
          ),
        ),
      );
    }
    return request.withPlannedStops(planned);
  }

  static String _circularStopNeedsLabel(Set<CircularRideStopKind> kinds) => [
    if (kinds.contains(CircularRideStopKind.fuel)) 'fuel',
    if (kinds.contains(CircularRideStopKind.comfort)) 'comfort',
    if (kinds.contains(CircularRideStopKind.meal)) 'meal',
  ].join(' + ');

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
        basemapConfiguration: _basemap,
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
    // A backstop, not the rider-facing path: every caller that a rider can
    // reach checks the authority first and says so plainly. Reaching this
    // means a caller was added without that check.
    if (widget.routeAuthority.routeChangeRefusal case final refusal?) {
      throw FormatException(refusal);
    }
    ImportedRoute? comparisonRoute;
    if (_canGenerateNavigableRoute(route)) {
      final choice = await _chooseImportedTrackTreatment(route);
      if (choice == _ImportedTrackChoice.cancel || !mounted) return null;
      final savedRoutes =
          widget.recordedRouteStore ??
          await JsonFileRecordedRouteStore.openDefault();
      await savedRoutes.save(route);
      if (choice == _ImportedTrackChoice.generateNavigable) {
        _showMessage('Matching the imported line to roads…');
        if (mounted) setState(() => _routing = true);
        late final ImportedTrackMatch match;
        try {
          match = await _importedTrackMatcher.match(route);
        } finally {
          if (mounted) setState(() => _routing = false);
        }
        comparisonRoute = route;
        route = match.route;
        distanceMeters = routeLengthMeters(route);
        duration = null;
        warnings = [...warnings, ...match.reviewWarnings];
      }
    }
    final review = await _reviewRoute(
      route,
      distanceMeters: distanceMeters,
      duration: duration,
      warnings: warnings,
      previousRoute: comparisonRoute,
      comparisonRoute: comparisonRoute,
    );
    if (review.action != RouteReviewAction.confirm) return null;
    return _commitRoute(review.route);
  }

  Future<({RouteReviewAction action, ImportedRoute route})> _reviewRoute(
    ImportedRoute route, {
    double? distanceMeters,
    Duration? duration,
    double? twistinessScore,
    List<String> warnings = const [],
    bool canEditStops = false,
    bool canGenerateAlternative = false,
    RouteAlternativeCallback? onGenerateAlternative,
    ImportedRoute? previousRoute,
    ImportedRoute? comparisonRoute,
  }) async {
    // As above: a backstop behind the rider-facing checks, not one of them.
    if (widget.routeAuthority.routeChangeRefusal case final refusal?) {
      throw FormatException(refusal);
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
    // The review screen is where suggested marking positions are accepted or
    // rejected, so its decisions have to come back out with the route (#179).
    var reviewedRoute = activeRoute;
    var markerReview = activeRoute.markerReview;
    final action = await RouteReviewScreen.show(
      context,
      route: activeRoute,
      distanceUnit: widget.distanceUnit,
      basemapConfiguration: _basemap,
      distanceMeters: distanceMeters,
      duration: duration,
      twistinessScore: twistinessScore,
      warnings: reviewWarnings,
      previousRoute: previousRoute ?? _route,
      comparisonRoute: comparisonRoute,
      canEditStops: canEditStops,
      canGenerateAlternative: canGenerateAlternative,
      onGenerateAlternative: onGenerateAlternative,
      showMarkerPlan: widget.markerFeaturesEnabled,
      onMarkerReviewChanged: (review) => markerReview = review,
      onReshapeRoute: (candidate, shapingPoints) => RouteReshapePlanner(
        routingService: _roadRoutingService,
      ).reshape(candidate, shapingPoints),
      onRouteChanged: (candidate) => reviewedRoute = candidate,
    );
    return (
      action: action,
      route: reviewedRoute.withMarkerReview(markerReview),
    );
  }

  bool _canGenerateNavigableRoute(ImportedRoute route) =>
      canGenerateNavigableRoute(route);

  Future<_ImportedTrackChoice> _chooseImportedTrackTreatment(
    ImportedRoute route,
  ) async =>
      await showDialog<_ImportedTrackChoice>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Add turn directions?'),
          content: Text(
            '${route.name} is an imported line without turn instructions. '
            'You can follow it exactly as supplied, or use an internet '
            'connection to generate a navigable road route.\n\n'
            'The original line will be kept in Saved routes either way.',
          ),
          actions: [
            TextButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(_ImportedTrackChoice.cancel),
              child: const Text('Cancel'),
            ),
            TextButton(
              key: const Key('follow-original-track'),
              onPressed: () => Navigator.of(
                dialogContext,
              ).pop(_ImportedTrackChoice.followOriginal),
              child: const Text('Follow original line'),
            ),
            FilledButton(
              key: const Key('generate-navigable-route'),
              onPressed: () => Navigator.of(
                dialogContext,
              ).pop(_ImportedTrackChoice.generateNavigable),
              child: const Text('Generate navigable route'),
            ),
          ],
        ),
      ) ??
      _ImportedTrackChoice.cancel;

  Future<ImportedRoute> _commitRoute(ImportedRoute activeRoute) async {
    await widget.routeStore.saveActiveRoute(activeRoute);
    if (!mounted) return activeRoute;
    _routeProgressTracker.reset();
    setState(() {
      _route = activeRoute;
      _setRouteStartConnector(null);
      _rejoinProgressTracker.reset();
      _rejoinProgressGeometry = _rejoinProgressTracker.update(
        _externalRejoinRoute,
        _effectivePosition,
      );
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

  Future<void> _navigateToRouteStart() async {
    final position = _effectivePosition;
    final start = _plannedRouteStart;
    if (position == null || start == null || _routingToStart) return;
    setState(() => _routingToStart = true);
    try {
      final result = await _roadRoutingService.routeThrough([position, start]);
      if (result.points.length < 2) {
        throw const FormatException(
          'The routing service returned no usable route.',
        );
      }
      final connector = ImportedRoute(
        id: 'route-start-${DateTime.now().microsecondsSinceEpoch}',
        name: 'Ride to route start',
        importedAt: DateTime.now().toUtc(),
        sourceFileName: 'route-start',
        paths: [
          RoutePath(
            kind: RoutePathKind.route,
            name: 'Route to planned start',
            points: result.points,
          ),
        ],
        waypoints: const [],
        maneuvers: result.maneuvers,
        plannedDuration: result.duration,
      );
      if (!mounted) return;
      setState(() {
        _setRouteStartConnector(connector);
        _rejoinProgressTracker.reset();
        _rejoinProgressGeometry = _rejoinProgressTracker.update(
          connector,
          _effectivePosition,
        );
      });
      _updateNavigationGuidance(_effectivePosition);
      _scheduleMapLibreSync(progress: true, overlays: true);
      _showMessage('Directions to the planned route start are ready.');
    } on Object catch (error) {
      _showMessage('Could not plan a route to the start: $error');
    } finally {
      if (mounted) setState(() => _routingToStart = false);
    }
  }

  void _finishRouteStartConnectorIfReached(GeoPoint? position) {
    final start = _plannedRouteStart;
    if (_routeStartConnector == null ||
        position == null ||
        start == null ||
        _mapDistanceMeters(position, start) > 100) {
      return;
    }
    setState(() {
      _setRouteStartConnector(null);
      _rejoinProgressTracker.reset();
      _rejoinProgressGeometry = const RouteProgressGeometry.empty();
    });
    _scheduleMapLibreSync(progress: true, overlays: true);
    _showMessage('Planned route reached. Following the main route.');
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
        final only = routePoints.single;
        if (!MapCameraCommand.isUsable(
          latitude: only.latitude,
          longitude: only.longitude,
          zoom: 14,
        )) {
          return;
        }
        unawaited(
          controller.animateCamera(
            ml.CameraUpdate.newLatLngZoom(
              ml.LatLng(only.latitude, only.longitude),
              14,
            ),
          ),
        );
        return;
      }
      final bounds = _mapLibreBounds(routePoints);
      if (!_boundsAreUsable(bounds)) return;
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
          child: SingleChildScrollView(
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
                  'Choose which optional café and road layers appear on the '
                  'free-roam map. Choices are remembered on this phone. The '
                  'layers hide automatically on wide-area views and return '
                  'when you zoom back in.',
                ),
                // A toggle that cannot work says so, rather than doing
                // nothing and leaving the rider to conclude the menu is
                // broken (#596).
                if (_discoveryLayerFailures.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Container(
                    key: const Key('discovery-layer-load-failure'),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF3A2A22),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      _discoveryLayerFailures.length == 1
                          ? 'Could not load ${_discoveryLayerFailures.single}. '
                                'Everything else here still works.'
                          : 'Could not load '
                                '${_discoveryLayerFailures.join(', ')}.',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                CheckboxListTile(
                  key: const Key('biker-cafes-layer-toggle'),
                  value: _bikerCafesVisible,
                  secondary: const Icon(
                    Icons.local_cafe,
                    color: Color(0xFFFFC857),
                  ),
                  title: const Text('Biker cafés'),
                  contentPadding: EdgeInsets.zero,
                  onChanged: (enabled) {
                    final visible = enabled ?? false;
                    setState(() => _bikerCafesVisible = visible);
                    setSheetState(() {});
                    unawaited(
                      _discoveryLayerPreferences?.setBikerCafesVisible(visible),
                    );
                    _scheduleMapLibreSync(overlays: true);
                  },
                ),
                for (final category in MotorcycleDiscoveryCategory.values)
                  CheckboxListTile(
                    key: Key('discovery-layer-${category.apiValue}'),
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
                      final visible = enabled ?? false;
                      setState(() {
                        if (visible) {
                          _enabledDiscoveryCategories.add(category);
                        } else {
                          _enabledDiscoveryCategories.remove(category);
                        }
                      });
                      setSheetState(() {});
                      unawaited(
                        _discoveryLayerPreferences?.setCategory(
                          category,
                          visible,
                        ),
                      );
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
    await DiscoveryRoadSheet.show(
      context,
      feature: feature,
      onAddToRoute: _routing
          ? null
          : () {
              Navigator.of(context).pop();
              unawaited(_addDiscoveryFeatureToRoute(feature));
            },
      onSuggestCorrection: () {
        Navigator.of(context).pop();
        unawaited(
          _showDiscoverySuggestionForm(feature: feature, action: 'correct'),
        );
      },
      onOpenLink: (url) => unawaited(
        launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
      ),
    );
  }

  Future<void> _showBikerPlace(BikerPlace place) async {
    final add = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 3, right: 12),
                    child: Icon(Icons.local_cafe, color: Color(0xFFFFC857)),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          place.name,
                          style: Theme.of(sheetContext).textTheme.titleLarge,
                        ),
                        if (place.address.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(place.address),
                        ],
                        const SizedBox(height: 4),
                        Text(
                          place.source,
                          style: const TextStyle(
                            color: Color(0xFF98A3B1),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // A way out that is not "act on it" (#592).
                  const SheetCloseButton(),
                ],
              ),
              const SizedBox(height: 18),
              FilledButton.icon(
                key: Key('route-via-biker-cafe-${place.id}'),
                onPressed: _routing
                    ? null
                    : () => Navigator.of(sheetContext).pop(true),
                icon: const Icon(Icons.add_road_outlined),
                label: const Text('Route via this café'),
              ),
              if (place.sourceUrl case final url?) ...[
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: () => unawaited(
                    launchUrl(
                      Uri.parse(url),
                      mode: LaunchMode.externalApplication,
                    ),
                  ),
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('Open café listing'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
    if (add == true) await _addBikerPlaceToRoute(place);
  }

  Future<void> _addBikerPlaceToRoute(BikerPlace place) async {
    if (_routing) return;
    // Checked here rather than left to the backstop inside
    // _reviewAndActivateRoute: the catch below prefixes whatever it is given
    // with "Could not route via ...", which turned a leadership rule into a
    // routing failure with the exception class printed at the rider (#576).
    if (widget.routeAuthority.routeChangeRefusal case final refusal?) {
      _showMessage(refusal);
      return;
    }
    final existing = _route;
    final start =
        existing?.paths.lastOrNull?.points.lastOrNull ?? _effectivePosition;
    if (start == null) {
      _showMessage('Enable location before routing to this café.');
      return;
    }
    setState(() => _routing = true);
    try {
      final extension = await _roadRoutingService.routeThrough([
        start,
        place.point,
      ], preferences: existing?.preferences);
      final route = ImportedRoute(
        id:
            existing?.id ??
            'biker-cafe-${DateTime.now().microsecondsSinceEpoch}',
        name: existing?.name ?? 'Route via ${place.name}',
        description: existing?.description,
        importedAt: existing?.importedAt ?? DateTime.now().toUtc(),
        sourceFileName: existing?.sourceFileName ?? 'biker-cafe',
        paths: [
          ...?existing?.paths,
          RoutePath(
            kind: RoutePathKind.route,
            name: place.name,
            points: extension.points,
          ),
        ],
        waypoints: [
          ...?existing?.waypoints,
          RouteWaypoint(
            point: place.point,
            name: place.name,
            description: place.address,
            symbol: 'Restaurant',
          ),
        ],
        preferences: existing?.preferences,
        plannedDuration:
            (existing?.plannedDuration ?? Duration.zero) + extension.duration,
      );
      await _reviewAndActivateRoute(route);
    } on Object catch (error) {
      _showMessage('Could not route via ${place.name}: $error');
    } finally {
      if (mounted) setState(() => _routing = false);
    }
  }

  Future<void> _addDiscoveryFeatureToRoute(
    MotorcycleDiscoveryFeature feature,
  ) async {
    if (_routing) return;
    // See _addBikerPlaceToRoute: the same prefixing catch is below (#576).
    if (widget.routeAuthority.routeChangeRefusal case final refusal?) {
      _showMessage(refusal);
      return;
    }
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
      ], preferences: existing?.preferences);
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
        preferences: existing?.preferences,
        plannedDuration:
            (existing?.plannedDuration ?? Duration.zero) + extension.duration,
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
      case _MapAction.hostMore:
        widget.hostChrome?.onMore?.call();
      case _MapAction.importGpx:
        await _importGpx();
      case _MapAction.loadDemo:
        await _loadDemoRoute();
      case _MapAction.circularRide:
        await _planCircularRide();
      case _MapAction.discoveryLayers:
        await _showDiscoveryLayersSheet();
      case _MapAction.personalRideHeatmap:
        await _togglePersonalRideHeatmap();
      case _MapAction.globalRideHeatmap:
        await _toggleGlobalRideHeatmap();
      case _MapAction.speedLimitDisplay:
        if (_speedLimitDisplay.enabled) {
          await _speedLimitDisplay.setEnabled(false);
        } else {
          await _confirmEnableSpeedLimitDisplay();
        }
      case _MapAction.maneuverList:
        await _showManeuverList();
      case _MapAction.fitRoute:
        _showWholeRoute();
      case _MapAction.exportRoute:
        await _openNavigationExport();
      case _MapAction.markerPlan:
        setState(() => _markerPlanVisible = !_markerPlanVisible);
        _scheduleMapLibreSync(overlays: true);
      case _MapAction.groupPip:
        await _openGroupPip();
      case _MapAction.downloadOffline:
        await _downloadOfflineMap();
      case _MapAction.removeRoute:
        if (!widget.canEditRoute || !await _confirmRemoveRoute()) return;
        await _clearActiveRouteAndState();
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
          'GPS positions, plus sampled points up to 1 km ahead on your route '
          'or heading, to a Valhalla road-matching service. It works in Great '
          'Britain and the Isle of Man and uses mapped OpenStreetMap limits, '
          'which may be missing or out of date. Roadside signs always apply.',
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

  /// Clears the active route and every piece of state that follows from it.
  ///
  /// Shared by the overflow menu's "Remove route" and by the ETA card's
  /// "Stop navigating" (#615), so the two exits cannot drift apart.
  Future<void> _clearActiveRouteAndState() async {
    await widget.routeStore.clearActiveRoute();
    if (!mounted) return;
    _routeProgressTracker.reset();
    setState(() {
      _route = null;
      _setRouteStartConnector(null);
      _rejoinProgressTracker.reset();
      _rejoinProgressGeometry = _rejoinProgressTracker.update(
        _externalRejoinRoute,
        _effectivePosition,
      );
      _progressGeometry = const RouteProgressGeometry.empty();
      _navigationMode = false;
      _navigationCanvasActive = false;
      _markerPlanVisible = false;
      _initialCameraPositioned = false;
      _releaseNavigationViewport();
    });
    _navigationGuidance.value = const NavigationGuidanceAssessment.noRoute();
    widget.onNavigationGuidanceChanged?.call(null);
    await _syncMapLibreSources();
    widget.onRouteChanged?.call(null);
    widget.onRouteCommitted?.call(null);
  }

  /// The way out of navigating in free roam (#615).
  ///
  /// Ride 723888's rider followed a route for 48 minutes and could not find how
  /// to stop: the only exit was the overflow menu's "Remove route", an
  /// unlabelled ellipsis and a scroll away. This sits on the ETA card — the
  /// surface that says "you are navigating" — and asks in free roam's own
  /// words. `_confirmRemoveRoute` is deliberately not reused: it speaks of the
  /// group route being removed for every rider, and free roam has no group.
  Future<void> _stopFreeRoamNavigation() async {
    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Stop navigating?'),
            content: const Text('The route is removed from the map.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Keep going'),
              ),
              FilledButton(
                key: const Key('confirm-stop-navigating'),
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Stop navigating'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;
    await _clearActiveRouteAndState();
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
    final inAppRoute = widget.pendingInAppRoute;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.onChangeRouteRequestHandled?.call();
      if (!mounted) return;
      if (widget.routeAuthority.routeChangeRefusal case final refusal?) {
        _showMessage(refusal);
        return;
      }
      if (sharedFile != null) {
        unawaited(_importSharedGpx(sharedFile));
      } else if (inAppRoute != null) {
        unawaited(
          _reviewAndActivateRoute(
            inAppRoute.route,
            warnings: inAppRoute.reviewNotes,
          ),
        );
      } else {
        _showChangeRouteSheet();
      }
    });
  }

  /// Opens the same circular-route planner as the map overflow when Home's
  /// destination sheet requests it. The token prevents a rebuild or tab return
  /// from reopening the sheet.
  void _maybeHandleCircularRideRequest() {
    final token = widget.circularRideRequestToken;
    if (token == null || identical(token, _handledCircularRideRequestToken)) {
      return;
    }
    _handledCircularRideRequestToken = token;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.onCircularRideRequestHandled?.call();
      if (!mounted) return;
      if (widget.routeAuthority.routeChangeRefusal case final refusal?) {
        _showMessage(refusal);
        return;
      }
      unawaited(_planCircularRide());
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
    if (widget.routeAuthority.routeChangeRefusal case final refusal?) {
      _showMessage(refusal);
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
                key: const Key('continue-without-route-sheet-item'),
                leading: const Icon(Icons.map_outlined),
                title: Text(
                  _route == null
                      ? 'Continue without a route'
                      : 'Keep current route',
                ),
                subtitle: _route == null
                    ? const Text('Use the live group map without navigation')
                    : null,
                onTap: () {
                  _continueWithoutRoute();
                  Navigator.of(sheetContext).pop();
                },
              ),
              const Divider(height: 1),
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

  void _continueWithoutRoute() {
    if (_waitingRoutePromptDismissed) return;
    setState(() => _waitingRoutePromptDismissed = true);
  }
}

enum _MapAction {
  hostMore,
  importGpx,
  loadDemo,
  circularRide,
  discoveryLayers,
  personalRideHeatmap,
  globalRideHeatmap,
  speedLimitDisplay,
  maneuverList,
  markerPlan,

  /// Both only reach the menu when a host is sharing the app bar and the icon
  /// buttons for them were dropped to make room (#600).
  fitRoute,
  exportRoute,
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
/// [phoneNumber] is null unless that rider has explicitly shared their own
/// number into this ride (#188). It is never derived: not from the roster, not
/// from a location event, not from the device, and emphatically not from an ICE
/// share, which carries a rider's next of kin rather than the rider. A rider's
/// own number arrives through `RideController.receivedRiderContacts`, and their
/// next of kin's through the separate ICE flow (IceShareInboxSheet /
/// shareEmergencyInfo); neither is ever read as the other.
///
/// [phoneNumber] exists so the emergency sheet can dial. It is not a display
/// field: nothing shows it beside a rider's name, because a number is not an
/// identity.
class MapEmergencyContact {
  const MapEmergencyContact({
    required this.riderId,
    required this.displayName,
    required this.role,
    this.phoneNumber,
    this.contactShareEventId,
  });

  final String riderId;
  final String displayName;
  final RideRole role;
  final String? phoneNumber;

  /// The share the number came from, so dialling can mark it used and exempt it
  /// from the ride-end purge.
  final String? contactShareEventId;

  bool get hasPhoneNumber => (phoneNumber ?? '').isNotEmpty;

  String get shortRoleLabel => switch (role) {
    RideRole.lead => 'the leader',
    RideRole.tailEndCharlie => 'the TEC',
    _ => displayName,
  };

  /// "Oliver (leader)". Used at the point of dialling, where the rider needs to
  /// know both who and which role.
  String get roleQualifiedName => switch (role) {
    RideRole.lead => '$displayName (leader)',
    RideRole.tailEndCharlie => '$displayName (TEC)',
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

/// How one source's arrows are drawn. Carried through the selection untouched.
class _TrailArrowStyle {
  const _TrailArrowStyle({
    required this.color,
    required this.idPrefix,
    required this.semanticLabel,
  });

  final Color color;
  final String idPrefix;
  final String semanticLabel;
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
    this.riderSymbol = riderSymbolDefault,
    this.riderDisplayName,
    this.hazardSymbol,
  });

  final String id;
  final GeoPoint point;
  final String label;

  /// Used for non-rider markers (hazards). Ignored when [motorcycleStyle] is
  /// set, which riders always provide.
  final IconData icon;
  final Color color;
  final MotorcycleIconStyle? motorcycleStyle;
  final RiderSymbol riderSymbol;
  final String? riderDisplayName;

  /// A reported hazard's decided symbol: shape, glyph, fill and freshness (#135).
  ///
  /// The one field both renderers read for hazard artwork. When it is set, the
  /// MapLibre symbol layer draws a raster of [HazardMapSymbolPainter] and the
  /// flutter_map fallback draws the same painter directly, so the two cannot
  /// disagree about what shipped (#141). Null keeps the older generic
  /// icon-on-a-circle badge, which is what a caller that has no report behind the
  /// marker still gets.
  final HazardMapSymbol? hazardSymbol;
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

/// Whether MapLibre can be asked to frame this box.
///
/// `animateCamera` with bounds reaches the same throw the follow camera does -
/// `mbgl::LatLng` out of `constrainCameraAndZoomToBounds` - by way of
/// `Transform::flyTo` rather than `easeTo`. A device log from 28 July 2026
/// carries exactly that, so guarding the follow target alone left this half
/// open (#359).
bool _boundsAreUsable(ml.LatLngBounds bounds) =>
    MapCameraCommand.boundsAreUsable(
      south: bounds.southwest.latitude,
      west: bounds.southwest.longitude,
      north: bounds.northeast.latitude,
      east: bounds.northeast.longitude,
    );

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
    required this.onDismiss,
  });

  final bool importing;
  final bool routing;
  final VoidCallback onPlanDestination;
  final VoidCallback onImport;
  final VoidCallback onUseStoredRoute;
  final VoidCallback onLoadDemo;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: LayoutBuilder(
      builder: (context, constraints) => Align(
        alignment: Alignment.center,
        child: SizedBox(
          width: math.min(392, constraints.maxWidth),
          height: constraints.maxHeight,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: math.max(0, constraints.maxHeight - 32),
              ),
              child: Center(
                child: Card(
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
                          'A route is optional. Continue to the live group map '
                          'without navigation, or add directions using a '
                          'destination, saved route or GPX file.',
                          style: TextStyle(color: Color(0xFF98A3B1)),
                        ),
                        const SizedBox(height: 20),
                        FilledButton.icon(
                          key: const Key('continue-without-route-button'),
                          onPressed: onDismiss,
                          icon: const Icon(Icons.map_outlined),
                          label: const Text('Continue without a route'),
                        ),
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          key: const Key('plan-destination-empty-button'),
                          onPressed: routing ? null : onPlanDestination,
                          icon: routing
                              ? const SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.add_road),
                          label: const Text('Enter destination'),
                        ),
                        const SizedBox(height: 8),
                        // Stored geometry is a route source in its own right,
                        // offered here beside the file picker rather than
                        // buried behind it (#155).
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
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
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
            ),
          ),
        ),
      ),
    ),
  );
}

class _WaitingForLeaderRoutePrompt extends StatelessWidget {
  const _WaitingForLeaderRoutePrompt({required this.onDismiss});

  final VoidCallback onDismiss;

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
              const Text(
                'Waiting for the leader’s route',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              const Text(
                'This ride has no group route yet. It will appear here when '
                'the leader shares one. The leader can also start without a '
                'route.',
                style: TextStyle(color: Color(0xFF98A3B1)),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                key: const Key('dismiss-waiting-route-prompt'),
                onPressed: onDismiss,
                icon: const Icon(Icons.map_outlined),
                label: const Text('Continue without a route'),
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
    required this.onCallContact,
    required this.onMessageContact,
  });

  final List<MapEmergencyContact> contacts;
  final Future<void> Function(QuickMessage message) onIssueSelected;
  final Future<void> Function() onOpenMessages;
  final Future<void> Function(MapEmergencyContact contact) onCallContact;
  final Future<void> Function(MapEmergencyContact contact) onMessageContact;

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

  Future<void> _dial(
    Future<void> Function(MapEmergencyContact contact) action,
    MapEmergencyContact contact,
  ) async {
    if (_sending) return;
    setState(() => _sending = true);
    try {
      await action(contact);
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
      // The order puts what matters first: the four issue buttons, then the
      // per-role Call/Message controls (#188), then the contacts-book fallback,
      // then the explanatory note. So the note is what goes below the fold,
      // which is the right thing to lose. Adding the contact rows made this
      // sheet taller again, so the scroll matters more, not less.
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
              if (contacts.isNotEmpty) ...[
                const SizedBox(height: 20),
                Text(
                  'Reach them directly',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 10),
                // Every leader and TEC is listed whether or not a number is
                // held: "they have not shared one" is information, and hiding
                // the row would leave a rider guessing whether the app had
                // simply failed to draw it (#188).
                for (final contact in contacts) ...[
                  _EmergencyContactRow(
                    contact: contact,
                    enabled: !_sending,
                    onCall: () =>
                        unawaited(_dial(widget.onCallContact, contact)),
                    onMessage: () =>
                        unawaited(_dial(widget.onMessageContact, contact)),
                  ),
                  const SizedBox(height: 10),
                ],
              ],
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: const Key('emergency-open-messages-button'),
                onPressed: _sending ? null : () => unawaited(_openMessages()),
                icon: const Icon(Icons.sms_outlined),
                // Names the recipient problem in the label, not only in the note
                // below it: a rider who has stopped and needs help does not read
                // 12 px of grey text, and an empty To: field looked like a fault
                // rather than a choice (#173). Still here after #188, because a
                // rider whose leader and TEC have shared nothing needs a route
                // out, and so does one who needs somebody outside the ride.
                label: const Text('Text someone from your contacts'),
              ),
              const SizedBox(height: 6),
              const Text(
                'Your position is filled in ready to send. Pick who to text - '
                'the leader and TEC have already had the alert in the app.',
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

/// One coordination role in the emergency sheet: who they are, and either the
/// dial controls or the plain fact that there is nothing to dial.
///
/// The number itself is deliberately not rendered. A rider needs to reach the
/// leader, not to read the leader's phone number off a screen, and putting it in
/// the UI would make it a display field — the one thing #188 says it must never
/// be.
class _EmergencyContactRow extends StatelessWidget {
  const _EmergencyContactRow({
    required this.contact,
    required this.enabled,
    required this.onCall,
    required this.onMessage,
  });

  final MapEmergencyContact contact;
  final bool enabled;
  final VoidCallback onCall;
  final VoidCallback onMessage;

  @override
  Widget build(BuildContext context) => Container(
    key: Key('emergency-contact-${contact.riderId}'),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      border: Border.all(color: const Color(0xFF2A2E38)),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          contact.roleQualifiedName,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        if (contact.hasPhoneNumber)
          Row(
            children: [
              FilledButton.icon(
                key: Key('emergency-contact-call-${contact.riderId}'),
                onPressed: enabled ? onCall : null,
                icon: const Icon(Icons.call, size: 18),
                label: const Text('Call'),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                key: Key('emergency-contact-message-${contact.riderId}'),
                onPressed: enabled ? onMessage : null,
                icon: const Icon(Icons.sms_outlined, size: 18),
                label: const Text('Message'),
              ),
            ],
          )
        else
          Text(
            '${contact.displayName} has not shared a phone number. '
            'The alert has reached them in the app.',
            style: const TextStyle(color: Color(0xFF98A3B1), fontSize: 12),
          ),
      ],
    ),
  );
}

class _GroupMiniMap extends StatefulWidget {
  const _GroupMiniMap({
    required this.width,
    required this.height,
    required this.routePaths,
    required this.currentPosition,
    required this.riders,
    required this.riderCount,
    required this.localMotorcycleStyle,
    required this.localRiderSymbol,
    required this.localDisplayName,
    required this.onTap,
    required this.renderer,
    required this.mapStyleUrl,
    required this.mapStyleString,
  });

  final double width;
  final double height;
  final List<List<GeoPoint>> routePaths;
  final GeoPoint? currentPosition;
  final List<MapOverlayMarker> riders;
  final int riderCount;
  final MotorcycleIconStyle localMotorcycleStyle;
  final RiderSymbol localRiderSymbol;
  final String localDisplayName;
  final VoidCallback? onTap;
  final GroupMiniMapRenderer renderer;
  final String mapStyleUrl;
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

  /// Radius of a rider's badge on the group overview, which is smaller than the
  /// main map's because the whole map is.
  static const _miniBadgeRadius = 7.0;

  /// Left plus right, and top plus bottom, of the fit padding the old bounds
  /// call used. Subtracted before framing so padding can never exceed the box.
  static const _fitHorizontalPadding = 40.0;
  static const _fitVerticalPadding = 40.0;

  ml.MapLibreMapController? _controller;
  final MapControllerImpl _vectorMapController = MapControllerImpl();
  Future<vmt.Style>? _vectorStyle;
  Timer? _refreshTimer;
  DateTime? _lastRefreshAt;
  bool _styleReady = false;
  bool _vectorMapReady = false;
  bool _refreshing = false;

  /// Set when a refresh is asked for while one is running, so the in-flight pass
  /// repeats instead of the request being lost. See [_refreshMap].
  bool _refreshRequestedWhileBusy = false;
  final Set<String> _registeredSymbolImages = {};

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
    _loadVectorStyle();
    _scheduleFit();
  }

  @override
  void didUpdateWidget(_GroupMiniMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.renderer != widget.renderer ||
        oldWidget.mapStyleUrl != widget.mapStyleUrl) {
      _vectorMapReady = false;
      _registeredSymbolImages.clear();
      _loadVectorStyle();
    }
    _scheduleRefresh();
  }

  void _loadVectorStyle() {
    _vectorStyle =
        widget.renderer == GroupMiniMapRenderer.flutterVector &&
            widget.mapStyleUrl.trim().isNotEmpty
        ? vmt.StyleReader(
            uri: widget.mapStyleUrl,
            httpHeaders: const {'User-Agent': 'me.osholt.ride_relay'},
          ).read().timeout(const Duration(seconds: 7))
        : null;
  }

  void _scheduleFit() {
    if (widget.renderer == GroupMiniMapRenderer.local) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_fitGroup());
    });
  }

  void _scheduleRefresh() {
    if (widget.renderer == GroupMiniMapRenderer.flutterVector) {
      _scheduleFit();
      return;
    }
    if (widget.renderer != GroupMiniMapRenderer.mapLibre) return;
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
                child: switch (widget.renderer) {
                  GroupMiniMapRenderer.local => _buildLocalOverview(
                    visibleRoutePaths,
                  ),
                  GroupMiniMapRenderer.mapLibre => _buildTileMap(),
                  GroupMiniMapRenderer.flutterVector => _buildFlutterVectorMap(
                    visibleRoutePaths,
                  ),
                },
              ),
              // The primary map retains MapLibre's attribution control. The
              // overview repeats the same licensed map inside that surface, so
              // a second verbose provider banner only obscures group markers.
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
              if (widget.renderer != GroupMiniMapRenderer.mapLibre)
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

  Widget _buildLocalOverview(List<List<GeoPoint>> visibleRoutePaths) =>
      CustomPaint(
        key: const Key('group-mini-map-local-fallback'),
        painter: _GroupMiniMapPainter(
          routePaths: visibleRoutePaths,
          currentPosition: widget.currentPosition,
          riders: widget.riders,
          localRiderSymbol: widget.localRiderSymbol,
          localDisplayName: widget.localDisplayName,
          brightness: Theme.of(context).brightness,
        ),
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
      // A 300 km group needs a zoom below 5 in this 150 px window. Keeping the
      // native renderer at 5 overrode the tested framing and left iOS showing
      // only the midpoint countryside while Android framed everyone (#172).
      minMaxZoomPreference: const ml.MinMaxZoomPreference(
        GroupMiniMapFraming.minimumZoom,
        16,
      ),
    );
  }

  Widget _buildFlutterVectorMap(List<List<GeoPoint>> visibleRoutePaths) {
    final styleFuture = _vectorStyle;
    if (styleFuture == null) return _buildLocalOverview(visibleRoutePaths);
    return FutureBuilder<vmt.Style>(
      future: styleFuture,
      builder: (context, snapshot) {
        final style = snapshot.data;
        final groupPoints = <GeoPoint?>[
          widget.currentPosition,
          ...widget.riders.map((rider) => rider.point),
        ].nonNulls.toList(growable: false);
        if (style == null || groupPoints.isEmpty) {
          return _buildLocalOverview(visibleRoutePaths);
        }
        final framing = GroupMiniMapFraming.forPoints(
          groupPoints,
          width: widget.width - _fitHorizontalPadding,
          height: widget.height - _fitVerticalPadding,
        );
        return Stack(
          children: [
            FlutterMap(
              key: ValueKey(
                'group-mini-map-vector-tiles-${widget.mapStyleUrl}',
              ),
              mapController: _vectorMapController,
              options: MapOptions(
                initialCenter: LatLng(
                  framing.centre.latitude,
                  framing.centre.longitude,
                ),
                initialZoom: framing.zoom,
                minZoom: GroupMiniMapFraming.minimumZoom,
                maxZoom: 16,
                backgroundColor: groupMiniMapBackgroundColor(
                  Theme.of(context).brightness,
                ),
                interactionOptions: const InteractionOptions(
                  flags: InteractiveFlag.none,
                ),
                onMapReady: () {
                  _vectorMapReady = true;
                  _scheduleFit();
                },
              ),
              children: [
                vmt.VectorTileLayer(
                  tileProviders: style.providers,
                  theme: style.theme,
                  sprites: style.sprites,
                  maximumZoom: 16,
                  concurrency: 2,
                  fileCacheTtl: Duration.zero,
                  fileCacheMaximumSizeInBytes: 0,
                ),
                if (visibleRoutePaths.isNotEmpty)
                  PolylineLayer(
                    polylines: [
                      for (final path in visibleRoutePaths)
                        if (path.length >= 2)
                          Polyline(
                            points: path
                                .map(
                                  (point) =>
                                      LatLng(point.latitude, point.longitude),
                                )
                                .toList(growable: false),
                            color: RouteTrailStyle.miniMapRoute.color,
                            strokeWidth:
                                RouteTrailStyle.miniMapRoute.widthPixels,
                            borderColor: RouteTrailStyle.casing,
                            borderStrokeWidth:
                                RouteTrailStyle.miniMapRoute.casingWidthPixels -
                                RouteTrailStyle.miniMapRoute.widthPixels,
                          ),
                    ],
                  ),
                MarkerLayer(
                  markers: [
                    for (final rider in widget.riders)
                      _vectorRiderMarker(
                        point: rider.point,
                        color: rider.color,
                        size: 16,
                        motorcycleStyle:
                            rider.motorcycleStyle ?? motorcycleIconStyleDefault,
                        riderSymbol: rider.riderSymbol,
                        displayName: rider.riderDisplayName ?? rider.label,
                      ),
                    if (widget.currentPosition case final point?)
                      _vectorRiderMarker(
                        point: point,
                        color: const Color(0xFFFF7A1A),
                        size: 18,
                        motorcycleStyle: widget.localMotorcycleStyle,
                        riderSymbol: widget.localRiderSymbol,
                        displayName: widget.localDisplayName,
                      ),
                  ],
                ),
              ],
            ),
            // The primary map retains the provider attribution control; do not
            // obscure this compact overview with a duplicate banner.
          ],
        );
      },
    );
  }

  Marker _vectorRiderMarker({
    required GeoPoint point,
    required Color color,
    required double size,
    required MotorcycleIconStyle motorcycleStyle,
    required RiderSymbol riderSymbol,
    required String displayName,
  }) => Marker(
    point: LatLng(point.latitude, point.longitude),
    width: size + 4,
    height: size + 4,
    child: DecoratedBox(
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [BoxShadow(color: Colors.black87, spreadRadius: 2)],
      ),
      child: RiderMarkerBadge(
        style: motorcycleStyle,
        symbol: riderSymbol,
        displayName: displayName,
        badgeColor: color,
        size: size,
        borderColor: Colors.white,
        borderWidth: 1,
      ),
    ),
  );

  Future<void> _prepareStyle() async {
    final controller = _controller;
    if (controller == null) return;
    _styleReady = false;
    final snapshot = _snapshot();
    try {
      await _registerSymbolImages(controller, snapshot);
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
          circleRadius: _miniBadgeRadius,
          circleColor: ['get', 'color'],
          circleStrokeWidth: 1.5,
          circleStrokeColor: ['get', 'strokeColor'],
        ),
        enableInteraction: false,
      );
      await controller.addSymbolLayer(
        _riderSource,
        'ride-relay-mini-rider-symbols',
        ml.SymbolLayerProperties(
          iconImage: ['get', 'iconImage'],
          iconColor: RouteTrailStyle.markerGlyphHex,
          // The same rule as the main map, at this map's badge size (#259).
          iconSize: _RideMapScreenState._riderIconSize(
            _miniBadgeRadius * 2,
            0.09,
          ),
          iconAllowOverlap: true,
          iconIgnorePlacement: true,
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
    if (!_styleReady || controller == null) return;
    // A refresh arriving mid-refresh is remembered rather than dropped. Each one
    // awaits several platform-channel calls, so on a moving group the updates
    // that used to be discarded here were precisely the ones carrying a rider's
    // first position - leaving the camera at the zoom it chose before anyone else
    // could be placed (#172).
    if (_refreshing) {
      _refreshRequestedWhileBusy = true;
      return;
    }
    _refreshing = true;
    try {
      do {
        _refreshRequestedWhileBusy = false;
        final snapshot = _snapshot();
        await _registerSymbolImages(controller, snapshot);
        await controller.setGeoJsonSource(
          _routeSource,
          _routeGeoJson(snapshot),
        );
        await controller.setGeoJsonSource(
          _riderSource,
          _riderGeoJson(snapshot),
        );
        await _fitGroup(snapshot);
      } while (_refreshRequestedWhileBusy && mounted);
    } on Object catch (error) {
      if (kDebugMode) {
        debugPrint('Could not refresh group mini-map: $error');
      }
    } finally {
      _refreshing = false;
      _refreshRequestedWhileBusy = false;
    }
  }

  Future<void> _fitGroup([_MiniMapSnapshot? snapshot]) async {
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
      // The caption counts the roster; this only receives riders the map can
      // place. When they disagree, someone has joined whose first position has
      // not arrived, and framing at street level would show one rider under a
      // caption saying two (#172).
      awaitingOtherRiders: widget.riderCount > points.length,
    );
    if (widget.renderer == GroupMiniMapRenderer.flutterVector) {
      if (!_vectorMapReady) return;
      try {
        _vectorMapController.move(
          LatLng(framing.centre.latitude, framing.centre.longitude),
          framing.zoom,
        );
      } on StateError {
        // The FutureBuilder can finish before FlutterMap attaches its camera.
      }
      return;
    }
    final controller = _controller;
    if (controller == null) return;
    final centre = ml.LatLng(framing.centre.latitude, framing.centre.longitude);
    // The mini-map frames the whole group, so one rider reporting a bad
    // position takes the camera - and with it the process - down for everyone
    // watching (#359).
    if (!mapLibreCameraIsUsable(centre, zoom: framing.zoom)) return;
    await controller.animateCamera(
      ml.CameraUpdate.newLatLngZoom(centre, framing.zoom),
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
            properties: {
              'color': _hexColor(rider.color),
              'strokeColor': _hexColor(riderBadgeStrokeColor(rider.color)),
              'iconImage': rider.riderSymbol.imageName(
                rider.riderDisplayName ?? rider.label,
                rider.motorcycleStyle ?? motorcycleIconStyleDefault,
              ),
              'initialsSymbol':
                  rider.riderSymbol.kind == RiderSymbolKind.initials,
            },
          ),
        if (snapshot.currentPosition case final point?)
          MapGeoJsonPoint(
            id: 'mini-local-rider',
            point: point,
            properties: {
              'color': '#FF7A1A',
              'strokeColor': _hexColor(
                riderBadgeStrokeColor(const Color(0xFFFF7A1A)),
              ),
              'iconImage': widget.localRiderSymbol.imageName(
                widget.localDisplayName,
                widget.localMotorcycleStyle,
              ),
              'initialsSymbol':
                  widget.localRiderSymbol.kind == RiderSymbolKind.initials,
            },
          ),
      ]);

  Future<void> _registerSymbolImages(
    ml.MapLibreMapController controller,
    _MiniMapSnapshot snapshot,
  ) async {
    final riders =
        <({RiderSymbol symbol, String displayName, MotorcycleIconStyle style})>[
          for (final rider in snapshot.riders)
            (
              symbol: rider.riderSymbol,
              displayName: rider.riderDisplayName ?? rider.label,
              style: rider.motorcycleStyle ?? motorcycleIconStyleDefault,
            ),
          if (snapshot.currentPosition != null)
            (
              symbol: widget.localRiderSymbol,
              displayName: widget.localDisplayName,
              style: widget.localMotorcycleStyle,
            ),
        ];
    for (final rider in riders) {
      final imageName = rider.symbol.imageName(rider.displayName, rider.style);
      if (!_registeredSymbolImages.add(imageName)) continue;
      final raster = await rasterizeRiderSymbolPng(
        symbol: rider.symbol,
        displayName: rider.displayName,
        motorcycleStyle: rider.style,
      );
      await controller.addImage(imageName, raster.bytes, raster.sdf);
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _vectorMapController.dispose();
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
      20000,
      50000,
      100000,
      200000,
      500000,
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
    required this.localRiderSymbol,
    required this.localDisplayName,
    required this.brightness,
  });

  final List<List<GeoPoint>> routePaths;
  final GeoPoint? currentPosition;
  final List<MapOverlayMarker> riders;
  final RiderSymbol localRiderSymbol;
  final String localDisplayName;
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

    void drawRider(
      Offset offset,
      Color color,
      double radius,
      RiderSymbol symbol,
      String displayName,
    ) {
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
      if (symbol.kind == RiderSymbolKind.motorcycle) return;
      final text = symbol.kind == RiderSymbolKind.initials
          ? riderInitials(displayName)
          : symbol.emoji!;
      final painter = TextPainter(
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center,
        text: TextSpan(
          text: text,
          style: TextStyle(
            color: RouteTrailStyle.markerGlyph,
            fontSize:
                radius * (symbol.kind == RiderSymbolKind.initials ? 2 : 1.25),
            height: symbol.kind == RiderSymbolKind.initials ? 0.9 : 1,
            fontWeight: FontWeight.w900,
            letterSpacing: symbol.kind == RiderSymbolKind.initials
                ? -0.8
                : null,
          ),
        ),
      )..layout();
      final available = radius * 2 * 0.94;
      final scale = symbol.kind == RiderSymbolKind.initials
          ? math.min(available / painter.width, available / painter.height)
          : 1.0;
      final paintedWidth = painter.width * scale;
      final paintedHeight = painter.height * scale;
      canvas
        ..save()
        ..translate(offset.dx - paintedWidth / 2, offset.dy - paintedHeight / 2)
        ..scale(scale);
      painter.paint(canvas, Offset.zero);
      canvas.restore();
    }

    final dots =
        <
          ({
            GeoPoint point,
            Color color,
            double radius,
            RiderSymbol symbol,
            String displayName,
          })
        >[
          for (final rider in riders)
            (
              point: rider.point,
              color: rider.color,
              radius: 7,
              symbol: rider.riderSymbol,
              displayName: rider.riderDisplayName ?? rider.label,
            ),
          if (currentPosition case final point?)
            (
              point: point,
              color: const Color(0xFFFF7A1A),
              radius: 8,
              symbol: localRiderSymbol,
              displayName: localDisplayName,
            ),
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
      drawRider(offset, dot.color, dot.radius, dot.symbol, dot.displayName);
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

/// The two-part enforcement warning: a bubble, then a border (#446).
///
/// See `enforcement_alert_presentation.dart` for why it is two parts and not one
/// panel. In short: announcing a camera is an event and being on the approach is a
/// state, and the panel was doing both badly because a surface loud enough to
/// announce is too big to hold for a mile.
class _EnforcementAlertLayer extends StatefulWidget {
  const _EnforcementAlertLayer({
    super.key,
    required this.alert,
    required this.distanceUnit,
    required this.topInset,
    required this.onDismiss,
  });

  final EnforcementAlert alert;
  final DistanceUnit distanceUnit;

  /// Safe-area inset, so the bubble follows a notch or Dynamic Island.
  final double topInset;

  final VoidCallback onDismiss;

  @override
  State<_EnforcementAlertLayer> createState() => _EnforcementAlertLayerState();
}

class _EnforcementAlertLayerState extends State<_EnforcementAlertLayer> {
  Timer? _bubbleTimer;
  bool _announced = false;

  @override
  void initState() {
    super.initState();
    // Fixed, and not restarted when the distance changes. The distance updates
    // several times a second on an approach, and a life tied to it would never
    // end — which is how the panel came to own the screen for a whole mile.
    _bubbleTimer = Timer(enforcementBubbleLife, () {
      if (mounted) setState(() => _announced = true);
    });
  }

  @override
  void dispose() {
    _bubbleTimer?.cancel();
    super.dispose();
  }

  EnforcementAlertStage get _stage => enforcementAlertStage(
    armed: true,
    dismissed: false,
    // The widget is rebuilt from scratch for a new hazard, so elapsed time is
    // carried by the timer rather than measured against a stored clock.
    sinceArmed: _announced ? enforcementBubbleLife : Duration.zero,
  );

  @override
  Widget build(BuildContext context) {
    final camera = widget.alert.hazard.type == HazardType.speedCamera;
    final stage = _stage;
    return Stack(
      children: [
        // The border holds for the whole approach and is the entire warning once
        // the bubble has gone. IgnorePointer because it covers the map: a warning
        // that swallowed a pan would be the full-screen problem again in a
        // thinner disguise.
        Positioned.fill(
          left: enforcementBorderInset,
          top: enforcementBorderInset,
          right: enforcementBorderInset,
          bottom: enforcementBorderInset,
          child: IgnorePointer(
            child: DecoratedBox(
              key: const Key('enforcement-alert-border'),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(enforcementBorderRadius),
                border: Border.all(
                  color: camera
                      ? const Color(0xFFFF3B30)
                      : const Color(0xFF4C9AFF),
                  width: enforcementBorderWidth,
                ),
              ),
            ),
          ),
        ),
        if (stage == EnforcementAlertStage.announcing)
          Positioned(
            left: 0,
            right: 0,
            top: widget.topInset + 12,
            child: Align(
              alignment: Alignment.topCenter,
              child: _EnforcementAlertBubble(
                alert: widget.alert,
                distanceUnit: widget.distanceUnit,
                onDismiss: widget.onDismiss,
              ),
            ),
          ),
      ],
    );
  }
}

/// The announcement itself: compact, loud, and clear of the rider marker.
///
/// Top-centre keeps it away from the forward-biased current position and the
/// bottom navigation rails. [enforcementBubbleMaxWidth] keeps a landscape phone
/// to a notification rather than a band across the screen.
class _EnforcementAlertBubble extends StatelessWidget {
  const _EnforcementAlertBubble({
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
    final enforcedLimit = enforcementLimitLabel(alert.hazard.details);
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
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          constraints: const BoxConstraints(
            maxWidth: enforcementBubbleMaxWidth,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            // Opaque: anything showing through the words competes with them at
            // the moment the rider has least attention to spare (#107).
            color: camera ? const Color(0xFF6E1015) : const Color(0xFF0F3560),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: camera ? const Color(0xFFFF3B30) : const Color(0xFF4C9AFF),
              width: 3,
            ),
            boxShadow: const [
              BoxShadow(
                color: Color(0x99000000),
                blurRadius: 12,
                offset: Offset(0, 4),
              ),
            ],
          ),
          // A row, not a column. The stacked column is what made every previous
          // version tall, and height is the only dimension that competes with the
          // map.
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                camera ? Icons.speed_rounded : Icons.local_police_rounded,
                size: 30,
                color: Colors.white,
              ),
              const SizedBox(width: 12),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        height: 1.1,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.2,
                      ),
                    ),
                    Text(
                      key: const Key('enforcement-alert-distance'),
                      distance,
                      maxLines: 1,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        height: 1.15,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
              ),
              if (enforcedLimit != null) ...[
                const SizedBox(width: 12),
                // The limit is the one number that matters at a camera, so it
                // gets the sign shape rather than a line of text. `VARIABLE` and
                // the rest of the wording come from #418's own label.
                Container(
                  key: const Key('enforcement-alert-limit'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: const Color(0xFFD71920),
                      width: 4,
                    ),
                  ),
                  child: Text(
                    enforcedLimit,
                    maxLines: 1,
                    style: const TextStyle(
                      color: Color(0xFF111111),
                      fontSize: 18,
                      height: 1,
                      fontWeight: FontWeight.w900,
                    ),
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

/// Tells its child whether an enforcement warning is live (#446).
///
/// A wrapper rather than a flag threaded down, because the alert is a listenable
/// the badge has no business subscribing to itself, and the badge is rebuilt often
/// enough already.
class _EnforcementEmphasis extends StatelessWidget {
  const _EnforcementEmphasis({
    required this.alert,
    required this.dismissedHazardId,
    required this.builder,
  });

  final ValueListenable<EnforcementAlert?>? alert;
  final String? dismissedHazardId;
  final Widget Function(bool emphasised) builder;

  @override
  Widget build(BuildContext context) {
    final listenable = alert;
    // No detector configured at all — most tests, and any build without the
    // provider. Emphasis is then never applied rather than defaulted on.
    if (listenable == null) return builder(false);
    return ValueListenableBuilder<EnforcementAlert?>(
      valueListenable: listenable,
      builder: (context, value, _) => builder(
        enforcementEmphasisApplies(
          armed: value != null,
          dismissed: value != null && value.hazard.id == dismissedHazardId,
        ),
      ),
    );
  }
}

class _PostedSpeedLimitBadge extends StatelessWidget {
  const _PostedSpeedLimitBadge({
    required this.status,
    required this.outcome,
    required this.limit,
    required this.riderSpeedMetersPerSecond,
    this.riderSpeedIsAgeing = false,
    this.emphasised = false,
  });

  /// Enlarged for the approach to a speed camera (#446).
  ///
  /// This is the one thing allowed to change the surface's width, and it is worth
  /// naming why: #142 fixed the *content* moving the width — a three-digit speed
  /// widening the sign and shoving its left edge across the map — by making the
  /// number give way inside a fixed 58px. That contract still holds. This is a
  /// deliberate, bounded, whole-surface change with a reason a rider can see, not
  /// a length of text leaking into a layout.
  final bool emphasised;

  final SpeedLimitDisplayStatus status;
  final SpeedLimitLookupOutcome? outcome;
  final PostedSpeedLimit? limit;
  final double? riderSpeedMetersPerSecond;

  /// True while the number is the last one observed rather than a current
  /// reading. Shown dimmed so a glance can tell the two apart - a held number
  /// presented as current is what #210 was about.
  final bool riderSpeedIsAgeing;

  @override
  Widget build(BuildContext context) {
    // Half again on a camera approach, and exactly 1 otherwise, so an ordinary
    // ride gets byte-identical geometry to before (#446, #142).
    final scale = emphasised ? enforcementEmphasisScale : 1.0;
    final signDiameter = 58 * scale;
    final reading = limit;
    final known = status == SpeedLimitDisplayStatus.known && reading != null;
    final value = known
        ? reading.unlimited
              ? '∞'
              : '${reading.milesPerHour}'
        : '–';
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
              SpeedLimitLookupOutcome.unsupportedRegion =>
                'Great Britain and Isle of Man only',
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
    final semanticLimit = reading?.unlimited == true
        ? 'unrestricted'
        : '${reading?.milesPerHour} miles per hour';
    final semanticLabel = known
        ? 'Mapped speed limit $semanticLimit'
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
          width: signDiameter,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: signDiameter,
                height: signDiameter,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: known
                        ? const Color(0xFFD71920)
                        : const Color(0xFF8993A0),
                    width: 6 * scale,
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
                        style: TextStyle(
                          color: const Color(0xFF111111),
                          fontSize: 26 * scale,
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
                style: TextStyle(
                  // Dimmed while the number is held rather than current, so a
                  // glance can tell the difference without a caption to read
                  // (#125 removed the caption; #210 is why the difference has to
                  // be visible at all).
                  color: riderSpeedIsAgeing
                      ? const Color(0xFFFFFFFF).withValues(alpha: 0.55)
                      : const Color(0xFFFFFFFF),
                  // The rider's own speed grows with the sign: the pair is what
                  // the report asked to be readable on the approach, and a
                  // large limit beside a small speed invites reading one for
                  // the other.
                  fontSize: 26 * scale,
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

/// A stable, app-owned compass paired with the posted-speed sign.
///
/// MapLibre's native compass has a platform-fixed footprint, so it could be
/// close to the sign or the same size, but not both on every phone. Drawing the
/// camera bearing here makes the two circles one deliberate cluster and keeps
/// the contract identical on iOS, Android and the fallback renderer.
class _RideCompass extends StatelessWidget {
  const _RideCompass({
    required this.bearingDegrees,
    required this.diameter,
    required this.darkMap,
  });

  final double bearingDegrees;
  final double diameter;
  final bool darkMap;

  @override
  Widget build(BuildContext context) => Semantics(
    key: const Key('ride-compass-position'),
    label: 'Map heading ${bearingDegrees.round()} degrees',
    excludeSemantics: true,
    child: Container(
      width: diameter,
      height: diameter,
      decoration: BoxDecoration(
        color: darkMap ? const Color(0xD9252E39) : const Color(0xE6FFFFFF),
        shape: BoxShape.circle,
        border: Border.all(
          color: darkMap ? const Color(0xFF8993A0) : const Color(0xFF30343B),
          width: 2,
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x66000000),
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Transform.rotate(
        angle: -bearingDegrees * math.pi / 180,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Positioned(
              top: 6,
              child: Text(
                'N',
                style: TextStyle(
                  color: darkMap ? Colors.white : Colors.black,
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                  height: 1,
                ),
              ),
            ),
            Icon(
              Icons.navigation,
              size: diameter * 0.42,
              color: const Color(0xFFD9304F),
            ),
          ],
        ),
      ),
    ),
  );
}

class _RouteStartBanner extends StatelessWidget {
  const _RouteStartBanner({
    required this.distanceMeters,
    required this.distanceUnit,
    required this.compact,
    required this.routing,
    required this.onNavigate,
  });

  final double distanceMeters;
  final DistanceUnit distanceUnit;
  final bool compact;
  final bool routing;
  final VoidCallback? onNavigate;

  @override
  Widget build(BuildContext context) {
    final distance = MeasurementFormatter(
      distanceUnit,
    ).distance(distanceMeters);
    return Semantics(
      key: const Key('route-start-guidance-banner'),
      container: true,
      liveRegion: true,
      label: 'The planned route starts $distance away.',
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Container(
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 8 : 10,
              vertical: compact ? 6 : 8,
            ),
            decoration: BoxDecoration(
              color: rideMapPrimaryPanelFill,
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
                const Icon(
                  Icons.route_rounded,
                  color: Color(0xFF68A9FF),
                  size: 26,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Planned route starts $distance away',
                    maxLines: compact ? 1 : 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: compact ? 13 : 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonalIcon(
                  key: const Key('navigate-to-route-start'),
                  onPressed: onNavigate,
                  style: FilledButton.styleFrom(
                    padding: EdgeInsets.symmetric(horizontal: compact ? 9 : 12),
                    visualDensity: VisualDensity.compact,
                  ),
                  icon: routing
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.navigation_rounded, size: 18),
                  label: Text(
                    routing
                        ? 'Planning…'
                        : compact
                        ? 'To start'
                        : 'Navigate to start',
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
              horizontal: compact ? 8 : 10,
              vertical: 4,
            ),
            decoration: BoxDecoration(
              color: rideMapPrimaryPanelFill,
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
                  size: compact ? 40 : 50,
                  color: const Color(0xFF68A9FF),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Distance on its own line and dominant, the way Google
                      // Maps and Waze set it, because it is the one value a
                      // rider glances at rather than reads: how long they have.
                      // It used to share a 16pt line with the instruction, so
                      // the whole banner had to be read to get either (#361).
                      //
                      // This costs height, and the portrait band the #105 camera
                      // measures pays for it in forward bias. That is the right
                      // way round: a banner too small to glance at is not worth
                      // any framing.
                      // Counted down rather than stepped (#449). Only the drawn
                      // number is interpolated: `guidance.distanceMeters` — the
                      // value the schedule, the camera detector and the spoken
                      // prompts all use — is untouched, so a smooth display
                      // cannot become a smoothly wrong decision.
                      //
                      // Keyed on the manoeuvre so a new junction starts its own
                      // count instead of gliding down from the last one's.
                      SmoothCountdown(
                        key: ValueKey(instruction.maneuver.identity),
                        meters: guidance.distanceMeters,
                        builder: (context, meters) => Text(
                          formatter.distance(meters),
                          maxLines: 1,
                          style: TextStyle(
                            fontSize: compact ? 26 : 30,
                            fontWeight: FontWeight.w900,
                            // Tight leading: the number is one line and every
                            // point of height here is paid for out of the band
                            // the camera's forward bias has to clear.
                            height: 1.0,
                          ),
                        ),
                      ),
                      Text(
                        instruction.text,
                        maxLines: 2,
                        softWrap: true,
                        style: TextStyle(
                          fontSize: compact ? 16 : 18,
                          fontWeight: FontWeight.w800,
                          height: 1.1,
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
                              size: compact ? 20 : 22,
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
                                  fontSize: compact ? 14 : 15,
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
                        style: TextStyle(
                          fontSize: compact ? 13 : 14,
                          color: const Color(0xFFB7C2CF),
                        ),
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

class _NavigationGuidanceStatusBanner extends StatelessWidget {
  const _NavigationGuidanceStatusBanner({
    required this.assessment,
    required this.compact,
  });

  final NavigationGuidanceAssessment assessment;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (assessment.state) {
      NavigationGuidanceState.waitingForLocation => (
        Icons.gps_not_fixed_rounded,
        const Color(0xFFFFC857),
      ),
      NavigationGuidanceState.offRoute => (
        Icons.alt_route_rounded,
        const Color(0xFFFFC857),
      ),
      NavigationGuidanceState.complete => (
        Icons.flag_rounded,
        const Color(0xFF72D69C),
      ),
      NavigationGuidanceState.noManeuvers => (
        Icons.directions_off_rounded,
        const Color(0xFFFFC857),
      ),
      // Read as a fault rather than a mode: this route was meant to have
      // directions and does not, which is something the rider can act on.
      NavigationGuidanceState.routingUnfinished => (
        Icons.wrong_location_rounded,
        const Color(0xFFFF8A65),
      ),
      NavigationGuidanceState.noRoute || NavigationGuidanceState.active => (
        Icons.navigation_rounded,
        const Color(0xFF68A9FF),
      ),
    };
    return Semantics(
      key: const Key('navigation-guidance-status-banner'),
      container: true,
      liveRegion: true,
      label: assessment.message,
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
              color: rideMapPrimaryPanelFill,
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
                Icon(icon, size: compact ? 20 : 22, color: color),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    assessment.message,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: compact ? 12 : 13,
                      fontWeight: FontWeight.w800,
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
          '${formatter.distance(distance)} · ~${_durationLabel(eta)}'
              '${_trendSuffix(trend)}',
        TecAvailability.stale when age != null =>
          'Last update ${_ageLabel(age)}',
        _ => 'Waiting for location',
      };
      return Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Card(
            key: const Key('leader-tec-gap'),
            margin: EdgeInsets.zero,
            color: rideMapPrimaryPanelFill,
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
      color: rideMapPrimaryPanelFill,
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
    required this.symbol,
    required this.displayName,
    required this.badgeColor,
  });

  final bool navigationMode;
  final double headingDegrees;
  final MotorcycleIconStyle style;
  final RiderSymbol symbol;
  final String displayName;
  final Color badgeColor;

  @override
  Widget build(BuildContext context) => Transform.rotate(
    // The badge circle is rotation-symmetric, so only the bike glyph inside
    // visibly turns - this keeps showing heading without the odd look a
    // rotating non-circular marker would have.
    angle: navigationMode || symbol.kind != RiderSymbolKind.motorcycle
        ? 0
        : headingDegrees * math.pi / 180,
    child: DecoratedBox(
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [BoxShadow(color: Colors.black45, blurRadius: 5)],
      ),
      child: RiderMarkerBadge(
        style: style,
        symbol: symbol,
        displayName: displayName,
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

/// Says what the map is drawing behind the rider's position and trail, and
/// appears only when that is not the map (#281).
///
/// Its absence carries as much as its presence: an empty-looking map with no
/// badge is genuinely empty countryside, which is the distinction the ride map
/// could not previously make. The three fault labels are deliberately
/// different from each other so a screenshot alone identifies which fault
/// occurred — the reason this issue survived three rounds of diagnosis is that
/// every occurrence produced the same uninformative picture.
///
/// A build with no style configured keeps the wording it always had; that one
/// is a statement of design, not a failure.
class _BasemapStatusBadge extends StatelessWidget {
  const _BasemapStatusBadge({required this.status, this.onTap});

  final BasemapStatus status;
  final VoidCallback? onTap;

  /// Route-only is expected and unremarkable; the rest are faults and are
  /// outlined so they read as one at a glance on a moving map.
  bool get _isFailure => status.isFault && status != BasemapStatus.routeOnly;

  @override
  Widget build(BuildContext context) => Semantics(
    button: onTap != null,
    // Both halves, so the fault is legible to a screen reader without the
    // rider having to open the message to find out what the label means.
    label: '${status.badgeLabel}. ${status.explanation}',
    excludeSemantics: true,
    child: GestureDetector(
      key: const Key('basemap-status-badge'),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: const Color(0xDD171D25),
          borderRadius: BorderRadius.circular(9),
          border: _isFailure
              ? Border.all(color: const Color(0xFFFF8A6B))
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_isFailure) ...[
              const Icon(
                Icons.layers_clear_outlined,
                size: 12,
                color: Color(0xFFFF8A6B),
              ),
              const SizedBox(width: 5),
            ],
            Text(status.badgeLabel, style: const TextStyle(fontSize: 10)),
          ],
        ),
      ),
    ),
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
    child: FittedBox(
      fit: BoxFit.scaleDown,
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
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.7,
                ),
              ),
            ],
          ),
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

/// The arrival question, offered in the chrome instead of over the map (#380).
///
/// It used to be a `showDialog`, which put a barrier across the whole surface
/// at the one moment a rider still needed to see where they were going. A
/// tester reported exactly that. This asks the same question in the band the
/// rider already reads, leaves the map alone, and can be waved away.
///
/// Ending for everyone stays behind its confirmation: this is about the
/// suggestion not blocking, not about removing the consequence.
class _RideCompletionSuggestion extends StatelessWidget {
  const _RideCompletionSuggestion({
    required this.assessment,
    required this.compact,
    this.onEndForEveryone,
    this.onDismiss,
  });

  final RideCompletionAssessment assessment;
  final bool compact;
  final VoidCallback? onEndForEveryone;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      key: const Key('ride-completion-suggestion'),
      margin: EdgeInsets.zero,
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: 12,
          vertical: compact ? 2 : 4,
        ),
        child: Row(
          children: [
            Icon(
              Icons.flag_circle_outlined,
              size: compact ? 18 : 20,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                // The counts the dialog spelled out are the leader's evidence,
                // not the rider's question, and at a glance on a bike the
                // question is the only part that can be read. The detail stays
                // one tap away in the confirmation.
                'All ${assessment.riderCount} riders have finished.',
                style: (compact
                    ? theme.textTheme.bodyMedium
                    : theme.textTheme.bodyLarge),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            // Dense on purpose. This sits in a band that is already close to
            // its cap, and the whole point of #380 was to cost the rider less
            // screen than the modal did, not more.
            TextButton(
              key: const Key('continue-completed-ride'),
              onPressed: onDismiss,
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
              child: const Text('Not yet'),
            ),
            FilledButton(
              key: const Key('confirm-completed-ride'),
              onPressed: onEndForEveryone,
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
              child: const Text('End ride'),
            ),
          ],
        ),
      ),
    );
  }
}
