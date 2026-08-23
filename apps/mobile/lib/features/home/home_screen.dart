import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/services.dart';
import 'package:crypto/crypto.dart';
import 'package:share_plus/share_plus.dart';

import '../../controllers/distance_unit_controller.dart';
import '../../controllers/global_ride_heatmap_controller.dart';
import '../../controllers/completed_rides_controller.dart';
import '../../controllers/map_style_mode_controller.dart';
import '../../controllers/ride_code_preference_controller.dart';
import '../../controllers/ride_controller.dart';
import '../../controllers/route_progress_display_controller.dart';
import '../../controllers/rider_profile_controller.dart';
import '../../controllers/shared_route_controller.dart';
import '../../controllers/speed_limit_display_controller.dart';
import '../../controllers/ride_diagnostics_controller.dart';
import '../../controllers/spoken_guidance_controller.dart';
import '../../domain/completed_ride.dart';
import '../../domain/imported_route.dart' show GeoPoint, ImportedRoute;
import '../../domain/map_style_mode.dart';
import '../../services/road_routing.dart';
import 'home_destination_search.dart';
import 'home_map_backdrop.dart';
import 'scan_invitation_screen.dart';
import '../../controllers/test_control_controller.dart';
import '../../domain/join_invite.dart';
import '../../domain/recorded_route_store.dart';
import '../../domain/ride_coordination_mode.dart';
import '../../internet/plan_directory.dart';
import '../../services/build_identity.dart';
import '../../services/basemap_configuration.dart';
import '../../services/carplay_bridge.dart';
import '../../services/gpx_import_source.dart';
import '../../services/route_importer.dart';
import '../../services/stored_route_library.dart';
import '../map/ride_map_feature.dart' show HostMapChrome, rideMapToolbarHeight;
import '../map/stored_route_picker.dart';
import '../ride/previous_rides_screen.dart';
import '../ride/route_recorder_screen.dart';
import '../settings/about_build_sheet.dart';
import '../settings/unit_settings_sheet.dart';

/// Runs the stateful half of a destination-search handoff in the only safe
/// order: the route belongs to the ride that has just been created.
///
/// Kept small and public so the ordering regression from #546 can be tested
/// without replacing the real home screen with a test-only implementation.
Future<void> createRideThenStageDestinationRoute({
  required Future<void> Function() createRide,
  required VoidCallback stageRoute,
}) async {
  await createRide();
  stageRoute();
}

/// Imports a web-planner/file handoff into the Ride Library without creating or
/// starting a ride. The map can activate it later through the normal review.
Future<ImportedRoute> saveSharedRouteToLibrary({
  required PickedGpxFile file,
  required RecordedRouteStore recordedRoutes,
  RouteImporter? importer,
}) async {
  final imported =
      (importer ?? RouteImporter(source: const SystemGpxImportSource()))
          .importFromFile(file);
  final stableId = 'shared-${sha256.convert(file.bytes)}';
  final existing = (await recordedRoutes.list())
      .where((route) => route.id == stableId)
      .firstOrNull;
  if (existing != null) return existing;

  final json = imported.toJson()..['id'] = stableId;
  final route = ImportedRoute.fromJson(json);
  await recordedRoutes.save(route);
  return route;
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.controller,
    required this.distanceUnits,
    required this.mapStyleMode,
    required this.rideCodePreference,
    required this.riderProfile,
    required this.sharedRoutes,
    required this.speedLimitDisplay,
    this.routeProgressDisplay,
    required this.recordedRoutes,
    required this.completedRides,
    this.globalRideHeatmap,
    this.planDirectory,
    this.testControl,
    this.spokenGuidance,
    this.rideDiagnostics,
    this.restoringRideCode,
    this.restorationError,
    this.onRetryRestoration,
    this.openJoinGroup = false,
    this.onJoinGroupOpened,
    this.enableNativeServices = true,
  });

  final RideController controller;
  final DistanceUnitController distanceUnits;
  final MapStyleModeController mapStyleMode;
  final RideCodePreferenceController rideCodePreference;
  final RiderProfileController riderProfile;
  final SharedRouteController sharedRoutes;
  final SpeedLimitDisplayController speedLimitDisplay;
  final RouteProgressDisplayController? routeProgressDisplay;
  final RecordedRouteStore recordedRoutes;
  final CompletedRidesController completedRides;
  final GlobalRideHeatmapController? globalRideHeatmap;
  final PlanDirectory? planDirectory;

  /// Null unless this build carries the test-control define; only forwarded to
  /// the settings sheet.
  final TestControlController? testControl;

  /// Whether turn instructions are spoken (#286). Forwarded to the settings
  /// sheet, which is where a rider opts in.
  final SpokenGuidanceController? spokenGuidance;

  /// Null in an ordinary build. Threaded so the Settings sheet opened from
  /// *here* offers the recorder too — wiring only the ride shell's sheet is
  /// what hid it from a tester who had never started a ride (#419).
  final RideDiagnosticsController? rideDiagnostics;

  final String? restoringRideCode;
  final Object? restorationError;
  final VoidCallback? onRetryRestoration;

  /// Set while an unstarted solo session is being replaced from the map. The
  /// ordinary join sheet opens as soon as Home owns the screen again (#261).
  final bool openJoinGroup;
  final VoidCallback? onJoinGroupOpened;

  /// False in widget tests and plugin-less builds; the map backdrop stands
  /// down rather than waiting on a platform map that will never load.
  final bool enableNativeServices;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _buildIdentity = BuildIdentity.fromEnvironment();
  bool _joinGroupOpenScheduled = false;

  /// True while the destination search is open, so the field can grow into it
  /// and the other actions can step aside (#595).
  bool _searching = false;

  /// Whether a ride may be started or joined right now.
  ///
  /// One getter for both ways in. They used to share a single `enabled` on the
  /// bottom bar; #595 moved joining into the app bar, and gating only one of
  /// them would let a rider join a ride while a restoration was still in
  /// flight.
  bool get _rideEntryEnabled =>
      !widget.controller.busy &&
      !_planningDestination &&
      widget.onRetryRestoration == null;
  late final CarPlayBridge _carPlayBridge;
  String? _carPlayMapStyleJson;

  @override
  void initState() {
    super.initState();
    _carPlayBridge = CarPlayBridge(
      onDestinationSearch: _searchCarPlayDestinations,
      onDestinationSelected: _planCarPlayDestination,
      onFreeRoamRequested: _startCarPlayFreeRoam,
      onStateRequested: () async => _publishHomeCarPlayState(),
    );
    _position.addListener(_publishHomeCarPlayState);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _publishHomeCarPlayState();
    });
    if (widget.openJoinGroup) {
      _scheduleJoinGroupSheet();
      return;
    }
    final choice = widget.riderProfile.takePendingRideChoice();
    if (choice != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _showRideSheet(
            context,
            creating: choice == OnboardingRideChoice.create,
          );
        }
      });
    }
  }

  @override
  void didUpdateWidget(covariant HomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _publishHomeCarPlayState();
    });
    if (!oldWidget.openJoinGroup && widget.openJoinGroup) {
      _scheduleJoinGroupSheet();
    }
  }

  void _scheduleJoinGroupSheet() {
    if (_joinGroupOpenScheduled) return;
    _joinGroupOpenScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      widget.onJoinGroupOpened?.call();
      await _showRideSheet(context, creating: false);
      _joinGroupOpenScheduled = false;
    });
  }

  /// Where the rider is, shared with the map below so a searched destination can
  /// be routed from here (#431).
  final _position = ValueNotifier<GeoPoint?>(null);

  @override
  void dispose() {
    // This screen had nothing to dispose until #431 gave it a notifier it shares
    // with the map and a client it lends to the geocoder.
    _position.removeListener(_publishHomeCarPlayState);
    unawaited(_carPlayBridge.dispose());
    _position.dispose();
    _routingClient.close();
    super.dispose();
  }

  /// True while a route is being planned, which disables the actions so a rider
  /// cannot start a second ride on top of the one being arranged.
  bool _planningDestination = false;

  /// A planned route waiting for the free-roam map to review and take it.
  ///
  /// Free roam answers a searched destination itself now. It used to create a
  /// ride first — a code, a coordination mode, a lobby — for a rider who had
  /// only said where they wanted to go, which is the mandatory ceremony #600
  /// was raised about. The route goes to the map through the same
  /// [PendingInAppRoute] handoff an imported GPX uses, so free roam and a ride
  /// review a new route identically.
  PendingInAppRoute? _freeRoamRoute;

  /// Bumped with [_freeRoamRoute]; the map takes the route when this changes.
  Object? _freeRoamRouteToken;

  /// Bumped when the destination sheet hands circular-route planning to the
  /// map. The map owns that planner and its review flow, so Home requests the
  /// existing flow rather than growing a second implementation of it.
  Object? _circularRideRequestToken;

  /// The route the free-roam map is following, if any.
  ///
  /// There is no lobby out here, so a route *is* the navigation: no start
  /// button, no waiting for anyone. Read from the map's own `onRouteChanged`
  /// rather than from whether a search just succeeded, so a route restored
  /// from the last session counts too — and so the group upgrade below knows
  /// what it is bringing along.
  ImportedRoute? _routeOnMap;

  /// Built once, and deliberately one instance: `NominatimDestinationSearchService`
  /// caches by query, so planning a route to a result the rider just searched for
  /// is a cache hit rather than a second call to a public geocoder that asks for
  /// no more than one a second.
  final _routingClient = http.Client();

  late final DestinationRoutePlanner _destinationPlanner = () {
    final configuration = RoutingConfiguration.fromEnvironment();
    return DestinationRoutePlanner(
      searchService: NominatimDestinationSearchService(
        client: _routingClient,
        baseUrl: configuration.geocodingBaseUrl,
      ),
      routingService: OsrmRoadRoutingService(
        client: _routingClient,
        baseUrl: configuration.routingBaseUrl,
      ),
    );
  }();

  BasemapConfiguration get _homeBasemap =>
      BasemapConfiguration.fromEnvironment().forBrightness(
        dark: widget.mapStyleMode.resolveDark(
          MediaQuery.platformBrightnessOf(context),
        ),
        restrainedLightStyle:
            widget.mapStyleMode.dayStyle == DayMapStyle.restrained,
      );

  void _publishHomeCarPlayState() {
    if (!mounted) return;
    final position = _position.value;
    unawaited(
      _carPlayBridge.publish(
        session: null,
        riderLocations: const [],
        routeAlerts: const [],
        activeHazards: const [],
        rideState: _planningDestination
            ? 'Planning route…'
            : 'Ready to plan or free roam',
        surfaceMode: CarPlaySurfaceMode.home,
        canPlanRoute: true,
        canFreeRoam: true,
        showTecStatus: false,
        followRider: position != null,
        distanceUnit: widget.distanceUnits.value,
        basemap: _homeBasemap,
        mapStyleJson: _carPlayMapStyleJson,
        localPosition: position,
        localRider: CarPlayLocalRider(
          riderId: widget.riderProfile.installationId,
          displayName: widget.riderProfile.displayName,
          motorcycleStyle: widget.riderProfile.motorcycleStyle,
          riderSymbol: widget.riderProfile.riderSymbol,
          riderColor: widget.riderProfile.riderColor,
        ),
      ),
    );
  }

  Future<List<CarPlayDestination>> _searchCarPlayDestinations(
    String query,
  ) async => [
    for (final match in await _destinationPlanner.searchService.search(query))
      CarPlayDestination(label: match.label, point: match.point),
  ];

  Future<void> _planCarPlayDestination(
    CarPlayDestination destination,
    bool? groupRide,
  ) async {
    if (_planningDestination || widget.controller.busy) {
      throw const FormatException('Ride setup is already in progress.');
    }
    final origin = _position.value;
    if (origin == null) {
      throw const FormatException(
        'Show your location on the iPhone before planning from CarPlay.',
      );
    }
    if (groupRide == null) {
      throw const FormatException('Choose a solo or group ride and try again.');
    }
    final controller = widget.controller;
    final profile = widget.riderProfile;
    setState(() => _planningDestination = true);
    _publishHomeCarPlayState();
    try {
      final plan = await _destinationPlanner.planForReview(
        origin: origin,
        query: destination.label,
        selectedDestination: DestinationMatch(
          label: destination.label,
          point: destination.point,
        ),
        distanceUnit: widget.distanceUnits.value,
      );
      await controller.createRide(
        profile.displayName,
        motorcycleStyle: profile.motorcycleStyle,
        riderSymbol: profile.riderSymbol,
        riderColor: profile.riderColor,
        coordinationMode: groupRide
            ? RideCoordinationMode.secondBikeDropOff
            : RideCoordinationMode.solo,
        rideName: destination.label,
      );
      // Publish the exact selected route before the active shell restores. The
      // authoritative journal then drives both phone and CarPlay without a
      // phone-only review sheet blocking the in-car flow.
      await controller.publishRoute(plan.route);
    } finally {
      if (mounted) {
        setState(() => _planningDestination = false);
        _publishHomeCarPlayState();
      }
    }
  }

  Future<void> _startCarPlayFreeRoam() async {
    if (_planningDestination || widget.controller.busy) {
      throw const FormatException('Ride setup is already in progress.');
    }
    if (_position.value == null) {
      throw const FormatException(
        'Show your location on the iPhone before starting free roam.',
      );
    }
    final controller = widget.controller;
    final profile = widget.riderProfile;
    await controller.createRide(
      profile.displayName,
      motorcycleStyle: profile.motorcycleStyle,
      riderSymbol: profile.riderSymbol,
      riderColor: profile.riderColor,
      coordinationMode: RideCoordinationMode.solo,
      rideName: 'Free roam',
    );
    await controller.startRide();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // The app opens on the map and the map is the *surface*, not a backdrop
      // (#426). #405 asked for this and #407 delivered a map behind a
      // full-screen panel — a brand mark, a heading, a paragraph, four buttons,
      // two links and a footer over a gradient covering the whole screen. From
      // the ride: "I don't want the start screen at all. I want the selection of
      // starting a ride to happen from the map view."
      //
      // So there is no panel and no scrim. The map has one top bar, plus notices
      // only when there is something to say.
      body: Stack(
        fit: StackFit.expand,
        children: [
          HomeMapBackdrop(
            mapStyleMode: widget.mapStyleMode,
            speedLimitDisplay: widget.speedLimitDisplay,
            distanceUnit: widget.distanceUnits.value,
            completedRideStore: widget.completedRides,
            globalRideHeatmap: widget.globalRideHeatmap,
            enableNativeServices: widget.enableNativeServices,
            bottomInset: 0,
            position: _position,
            // The searched destination, reviewed and activated by the map
            // itself. Free roam navigates; it does not hold a ride to do it
            // (#600).
            pendingInAppRoute: _freeRoamRoute,
            changeRouteRequestToken: _freeRoamRouteToken,
            onChangeRouteRequestHandled: () => setState(() {
              _freeRoamRoute = null;
              _freeRoamRouteToken = null;
            }),
            circularRideRequestToken: _circularRideRequestToken,
            onCircularRideRequestHandled: () => setState(() {
              _circularRideRequestToken = null;
            }),
            navigating: _routeOnMap != null,
            localDisplayName: widget.riderProfile.displayName,
            onNavigationArchived: (ride) =>
                unawaited(_showSavedNavigation(ride)),
            onRouteChanged: (route) => setState(() => _routeOnMap = route),
            // The search field and these two actions used to be painted on
            // top of the map's own AppBar, in the same corner of the same
            // safe area, from this widget tree rather than the map's. Both
            // were drawn and only these could be tapped, so the map's layer
            // menu was buried under the settings button (#572) and the icons
            // read as overlapping junk (#573). The map draws them now, in one
            // row, with one hit test.
            hostChrome: HostMapChrome(
              bottomInset: 0,
              onMore: () => unawaited(_showMoreActions(context)),
              title: HomeSearchBar(
                onTap: () => unawaited(_searchDestination()),
                expanded: _searching,
              ),
              // While a search is open the field takes the whole bar. The
              // rest step aside rather than competing with it, which is what
              // makes the search read as the way in rather than one control
              // among four (#595).
              actions: _searching
                  ? const []
                  : [
                      // Joining takes a six-digit code, not a destination, so
                      // it cannot fold into the field the way creating does.
                      // It sits beside it, and is offered again underneath the
                      // field once the search is open.
                      // A word, not a bare icon. #306 was raised because the
                      // only way to find a feature was an unlabelled glyph,
                      // and `home_reachability_test.dart` guards it — an
                      // icon-only version of this failed that suite, which is
                      // exactly what the suite is for.
                      TextButton.icon(
                        key: const Key('home-join-ride'),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          visualDensity: VisualDensity.compact,
                          textStyle: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        onPressed: _rideEntryEnabled
                            ? () => unawaited(
                                _showRideSheet(context, creating: false),
                              )
                            : null,
                        icon: const Icon(Icons.group_add_outlined, size: 16),
                        label: const Text('Join'),
                      ),
                      IconButton(
                        tooltip: 'Settings',
                        onPressed: () => UnitSettingsSheet.show(
                          context,
                          widget.distanceUnits,
                          widget.mapStyleMode,
                          widget.riderProfile,
                          speedLimitDisplay: widget.speedLimitDisplay,
                          routeProgressDisplay: widget.routeProgressDisplay,
                          testControl: widget.testControl,
                          spokenGuidance: widget.spokenGuidance,
                          rideDiagnostics: widget.rideDiagnostics,
                          globalRideHeatmap: widget.globalRideHeatmap,
                          completedRideStore: widget.completedRides,
                        ),
                        icon: const Icon(Icons.settings_outlined),
                      ),
                    ],
            ),
            onMapStyleResolved: (styleJson) {
              _carPlayMapStyleJson = styleJson;
              final basemap = _homeBasemap;
              unawaited(
                _carPlayBridge.publishMapStyle(
                  styleJson: styleJson,
                  fallbackStyleUrl: basemap.styleUrl,
                ),
              );
              _publishHomeCarPlayState();
            },
          ),
          // Notices, and nothing when there are none. Each of these used to sit
          // in the scrolling column of a full-screen panel, which is why the
          // panel existed at all; they are now cards on the map that appear and
          // go. The search field and the two actions that used to stand here
          // are now in the map's own AppBar — see `hostChrome` above — so this
          // layer holds nothing that competes for the top band.
          //
          // Clear of the AppBar rather than over it: the map's Scaffold has
          // already consumed the status bar, so this offset is measured from
          // the bottom of the toolbar.
          SafeArea(
            child: Padding(
              padding: EdgeInsets.only(
                top:
                    rideMapToolbarHeight(
                      landscape:
                          MediaQuery.orientationOf(context) ==
                          Orientation.landscape,
                    ) +
                    8,
                left: 12,
                right: 12,
              ),
              child: Align(
                alignment: Alignment.topCenter,
                child: _HomeNotices(children: _notices(context)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The banners that have something to say right now.
  ///
  /// Returned as a list rather than built inline so "are there any" is a question
  /// the layout can answer — a notices area that reserved space for nothing would
  /// be a small panel, which is the thing being removed.
  List<Widget> _notices(BuildContext context) => [
    TesterUpdateBanner(identity: _buildIdentity),
    if (widget.onRetryRestoration != null)
      _RideRestorationBanner(
        rideCode: widget.restoringRideCode,
        error: widget.restorationError,
        onRetry: widget.onRetryRestoration!,
      ),
    if (widget.controller.endedRideSetAside)
      _SetAsideRideBanner(
        rideCode: widget.controller.session!.rideCode,
        onReopen: widget.controller.reopenEndedRide,
        onDismiss: () => unawaited(widget.controller.clearEndedRide()),
      ),
    if (widget.sharedRoutes.pending case final file?)
      _PendingSharedRouteBanner(
        fileName: file.name,
        onSave: () => unawaited(_savePendingSharedRoute(file)),
        onDismiss: widget.sharedRoutes.clearPending,
      ),
    if (widget.sharedRoutes.plannerLinkStatus != PlannerLinkStatus.idle)
      _PlannerLinkStatusBanner(
        status: widget.sharedRoutes.plannerLinkStatus,
        message:
            widget.sharedRoutes.plannerLinkMessage ?? 'Loading shared route…',
        canRetry: widget.sharedRoutes.canRetryPlannerLink,
        onRetry: () => unawaited(widget.sharedRoutes.retryPlannerLink()),
        onDismiss: widget.sharedRoutes.clearPlannerLinkNotice,
      ),
  ];

  Future<void> _savePendingSharedRoute(PickedGpxFile file) async {
    try {
      final route = await saveSharedRouteToLibrary(
        file: file,
        recordedRoutes: widget.recordedRoutes,
      );
      widget.sharedRoutes.clearPending();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${route.name} saved to Ride Library.')),
      );
    } on FormatException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  /// The occasional actions, behind one button.
  ///
  /// Each of these was a permanent row on the old panel. None is used often enough
  /// to be worth a strip of map, and together they were most of what made the
  /// panel full-screen.
  Future<void> _showMoreActions(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      backgroundColor: const Color(0xFF171D25),
      // Scrollable, and `isScrollControlled` so it may exceed half the screen.
      // This was a bare Column: it fitted until #594 added the way back to a
      // set-aside ride, and then overflowed by 35 pixels on a short viewport.
      // A menu that grows by one entry should not start clipping.
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Settings by name, at the top, because a ride reaches it by
              // name from a named list — the "Settings" tab, and the same word
              // in the ride menu behind it. Free roam offered only the gear in
              // the top band, so the way to it changed the moment a ride
              // existed and changed back when it ended (#600).
              //
              // The gear stays for riders who have learned it. That is the
              // same call as the QR icon in `home_reachability_test.dart`:
              // adding the words is the fix, removing the icon is a second,
              // unrelated change to a control people already use.
              ListTile(
                key: const Key('home-more-settings'),
                leading: const Icon(Icons.settings_outlined),
                title: const Text('Settings'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  unawaited(
                    UnitSettingsSheet.show(
                      context,
                      widget.distanceUnits,
                      widget.mapStyleMode,
                      widget.riderProfile,
                      speedLimitDisplay: widget.speedLimitDisplay,
                      routeProgressDisplay: widget.routeProgressDisplay,
                      testControl: widget.testControl,
                      spokenGuidance: widget.spokenGuidance,
                      rideDiagnostics: widget.rideDiagnostics,
                      globalRideHeatmap: widget.globalRideHeatmap,
                      completedRideStore: widget.completedRides,
                    ),
                  );
                },
              ),
              const Divider(height: 1),
              ListTile(
                key: const Key('home-create-ride'),
                leading: const Icon(Icons.groups_2_outlined),
                title: const Text('Create a group ride'),
                enabled: _rideEntryEnabled,
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  unawaited(_showRideSheet(context, creating: true));
                },
              ),
              ListTile(
                key: const Key('start-ride-simulator'),
                leading: const Icon(Icons.science_outlined),
                title: const Text('Try a simulated ride'),
                subtitle: const Text('Never shares your location'),
                enabled:
                    !widget.controller.busy &&
                    widget.onRetryRestoration == null,
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  widget.controller.createSimulationRide();
                },
              ),
              ListTile(
                key: const Key('record-a-route-button'),
                leading: const Icon(Icons.fiber_manual_record_outlined),
                title: const Text('Record a route'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  unawaited(
                    RouteRecorderScreen.show(context, widget.recordedRoutes),
                  );
                },
              ),
              // The way back from a set-aside ride (#594). Stepping away from a
              // recovered ride keeps it and its journal intact but takes the
              // rider off it entirely — no banner, nothing on the map — so the
              // route back has to be somewhere they can find it.
              if (widget.controller.rideSetAside &&
                  widget.controller.session != null)
                ListTile(
                  key: const Key('home-rejoin-set-aside-ride'),
                  leading: const Icon(Icons.restore),
                  title: Text(
                    'Rejoin ride ${widget.controller.session!.rideCode}',
                  ),
                  subtitle: Text(
                    widget.controller.rideEnded
                        ? 'Its summary and recap are still here'
                        : 'Still running, and set aside on this phone',
                  ),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    widget.controller.reopenEndedRide();
                  },
                ),
              ListTile(
                key: const Key('ride-library-button'),
                leading: const Icon(Icons.route_outlined),
                title: const Text('Ride library'),
                subtitle: Text(
                  widget.completedRides.rides.isEmpty
                      ? 'Recorded routes and previous rides'
                      : 'Recorded routes and ${widget.completedRides.rides.length} previous ride${widget.completedRides.rides.length == 1 ? '' : 's'}',
                ),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  unawaited(_openRideLibrary(context));
                },
              ),
              const Divider(height: 8),
              ListTile(
                key: const Key('home-build-identity'),
                leading: const Icon(Icons.info_outline),
                title: Text(
                  '${_buildIdentity.versionLabel} · '
                  '${_buildIdentity.track.label}',
                ),
                subtitle: const Text('No account required'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  unawaited(
                    AboutBuildSheet.show(context, identity: _buildIdentity),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Search for somewhere to ride to, then arrange the ride around it (#431).
  ///
  /// The order is the point. The app used to ask for ride scope, coordination
  /// mode, display name and an optional route code *before* a rider got near a
  /// map; this asks where they are going and infers the rest.
  /// Takes no context: it uses the State's own, so the `mounted` check after
  /// each await is guarding the thing actually being used.
  Future<void> _searchDestination() async {
    // The field grows into the search and the other actions step aside while
    // it is open (#595).
    setState(() => _searching = true);
    try {
      await _runDestinationSearch();
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _runDestinationSearch() async {
    final outcome = await HomeDestinationSearchSheet.show(
      context,
      searchService: _destinationPlanner.searchService,
      hasPosition: _position.value != null,
    );
    if (outcome == null || !mounted) return;
    switch (outcome) {
      case HomeSearchDestination(:final choice):
        await _navigateTo(choice);
      case HomeSearchHandoff(:final kind):
        switch (kind) {
          // Both of these are the existing form, which already knows how to take
          // a six-digit ride code and a planner route code. #431 is about the way
          // in, not about replacing what works once you are there.
          case HomeSearchHandoffKind.joinWithCode:
            await _showRideSheet(context, creating: false);
          case HomeSearchHandoffKind.plannedRouteCode:
            await _showRideSheet(context, creating: true);
          case HomeSearchHandoffKind.storedRoute:
            await _openRideLibrary(context);
          case HomeSearchHandoffKind.circularRide:
            setState(() => _circularRideRequestToken = Object());
        }
    }
  }

  /// Plans a route to the chosen place and hands it to the map.
  ///
  /// No ride is created. A rider who searched for somewhere to go said nothing
  /// about riding with anybody, and the app used to answer that by making a
  /// ride — with a coordination mode it had to ask for — before it would show
  /// a route (#600). Riding with others is offered from the map afterwards,
  /// once there is a route to bring along, which keeps the #546 ordering:
  /// the route exists before the ride that carries it.
  Future<void> _navigateTo(DestinationChoice choice) async {
    final origin = _position.value;
    if (origin == null) return;
    setState(() => _planningDestination = true);
    try {
      final plan = await _destinationPlanner.planForReview(
        origin: origin,
        // The label the rider picked, not its coordinates: the service caches by
        // query so this is the same lookup again, and it keeps the route named
        // after the place rather than a pair of numbers.
        query: choice.label,
        selectedDestination: DestinationMatch(
          label: choice.label,
          point: choice.point,
        ),
        distanceUnit: widget.distanceUnits.value,
      );
      if (!mounted) return;
      setState(() {
        _freeRoamRoute = PendingInAppRoute(
          route: plan.route,
          reviewNotes: plan.warnings,
        );
        _freeRoamRouteToken = Object();
      });
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            error is FormatException
                ? error.message
                : 'Could not plan a route there. Try again, or pick a different '
                      'place.',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _planningDestination = false);
    }
  }

  Future<void> _showRideSheet(
    BuildContext context, {
    required bool creating,
    PendingInAppRoute? pendingInAppRoute,
  }) async {
    widget.controller.clearError();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: const Color(0xFF171D25),
      builder: (sheetContext) => _RideForm(
        controller: widget.controller,
        rideCodePreference: widget.rideCodePreference,
        riderProfile: widget.riderProfile,
        sharedRoutes: widget.sharedRoutes,
        planDirectory: widget.planDirectory,
        creating: creating,
        pendingInAppRoute: pendingInAppRoute,
        onComplete: () => Navigator.of(sheetContext).pop(),
      ),
    );
  }

  Future<void> _openRideLibrary(BuildContext launchContext) async {
    final library = StoredRouteLibrary(
      recordedRoutes: widget.recordedRoutes,
      completedRides: widget.completedRides,
    );
    final selection = await StoredRoutePickerScreen.show(
      launchContext,
      library: library,
      distanceUnit: widget.distanceUnits.value,
      basemapConfiguration: _homeBasemap,
      openPreviousRide: (libraryContext, ride) => PreviousRideDetailScreen.show(
        libraryContext,
        ride: ride,
        completedRides: widget.completedRides,
        distanceUnits: widget.distanceUnits,
      ),
    );
    if (selection == null || !mounted) return;
    final prepared = library.prepare(selection);
    await _showRideSheet(
      context,
      creating: true,
      pendingInAppRoute: PendingInAppRoute(
        route: prepared.route,
        reviewNotes: prepared.notes,
      ),
    );
  }

  Future<void> _showSavedNavigation(CompletedRide ride) async {
    if (!mounted) return;
    final open = await showModalBottomSheet<bool>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Navigation saved',
              style: Theme.of(sheetContext).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              '${ride.title} is now in My rides. You can share its summary, '
              'export the recorded GPX, or make a recap image.',
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              key: const Key('open-saved-navigation'),
              onPressed: () => Navigator.of(sheetContext).pop(true),
              icon: const Icon(Icons.ios_share),
              label: const Text('View ride and exports'),
            ),
            TextButton(
              onPressed: () => Navigator.of(sheetContext).pop(false),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
    if (open != true || !mounted) return;
    await PreviousRideDetailScreen.show(
      context,
      ride: ride,
      completedRides: widget.completedRides,
      distanceUnits: widget.distanceUnits,
    );
  }
}

class _RideRestorationBanner extends StatelessWidget {
  const _RideRestorationBanner({
    required this.rideCode,
    required this.error,
    required this.onRetry,
  });

  final String? rideCode;
  final Object? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final failed = error != null;
    final ride = rideCode == null ? 'your saved ride' : 'ride $rideCode';
    return Container(
      key: const Key('ride-restoration-banner'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1D2530),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: failed
              ? Theme.of(context).colorScheme.error
              : const Color(0xFF3B4654),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (failed)
            Icon(
              Icons.warning_amber_rounded,
              color: Theme.of(context).colorScheme.error,
            )
          else
            const SizedBox.square(
              dimension: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  failed ? 'Could not restore $ride' : 'Still restoring $ride',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  failed
                      ? 'The home screen remains available. Retry before '
                            'creating or joining another ride.'
                      : 'The home screen remains available while its journal '
                            'loads. Ride actions will unlock when it is ready.',
                ),
                if (failed) ...[
                  const SizedBox(height: 8),
                  TextButton.icon(
                    key: const Key('retry-ride-restoration'),
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry restore'),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SetAsideRideBanner extends StatelessWidget {
  const _SetAsideRideBanner({
    required this.rideCode,
    required this.onReopen,
    required this.onDismiss,
  });

  final String rideCode;
  final VoidCallback onReopen;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('set-aside-ride-banner'),
    margin: const EdgeInsets.only(bottom: 20),
    padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
    decoration: BoxDecoration(
      color: const Color(0xFF1D2530),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: const Color(0xFF3B4654)),
    ),
    child: Row(
      children: [
        const Icon(Icons.flag_outlined, color: Color(0xFFFFB15C)),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Ride $rideCode has ended',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const Text(
                'Its summary and recap are still here.',
                style: TextStyle(color: Color(0xFFABB5C1), fontSize: 12),
              ),
            ],
          ),
        ),
        TextButton(
          key: const Key('reopen-set-aside-ride'),
          onPressed: onReopen,
          child: const Text('Open'),
        ),
        IconButton(
          key: const Key('dismiss-set-aside-ride'),
          tooltip: 'Clear ended ride notice',
          onPressed: onDismiss,
          icon: const Icon(Icons.close),
        ),
      ],
    ),
  );
}

/// A GPX file opened from another app (Files, Mail, a route planner's share
/// sheet) has nowhere to go yet - there is no ride to attach a route to until
/// one exists. Surfaces that instead of silently discarding it.
class _PendingSharedRouteBanner extends StatelessWidget {
  const _PendingSharedRouteBanner({
    required this.fileName,
    required this.onSave,
    required this.onDismiss,
  });

  final String fileName;
  final VoidCallback onSave;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
    decoration: BoxDecoration(
      color: const Color(0xFF1D2530),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: const Color(0xFF3B4654)),
    ),
    child: Row(
      children: [
        const Icon(Icons.map_outlined, color: Color(0xFFFFB15C)),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                fileName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const Text(
                'Save it to Ride Library now, or start a ride to use it.',
                style: TextStyle(color: Color(0xFFABB5C1), fontSize: 12),
              ),
            ],
          ),
        ),
        TextButton(
          key: const Key('save-shared-route-to-library'),
          onPressed: onSave,
          child: const Text('Save'),
        ),
        IconButton(
          tooltip: 'Dismiss',
          onPressed: onDismiss,
          icon: const Icon(Icons.close, size: 20),
        ),
      ],
    ),
  );
}

class _PlannerLinkStatusBanner extends StatelessWidget {
  const _PlannerLinkStatusBanner({
    required this.status,
    required this.message,
    required this.canRetry,
    required this.onRetry,
    required this.onDismiss,
  });

  final PlannerLinkStatus status;
  final String message;
  final bool canRetry;
  final VoidCallback onRetry;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('planner-link-status'),
    padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
    decoration: BoxDecoration(
      color: const Color(0xFF1D2530),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(
        color: status == PlannerLinkStatus.error
            ? const Color(0xFFD96A6A)
            : const Color(0xFF3B4654),
      ),
    ),
    child: Row(
      children: [
        if (status == PlannerLinkStatus.loading)
          const SizedBox.square(
            dimension: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        else
          const Icon(Icons.link_off, color: Color(0xFFFFB15C)),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            message,
            style: const TextStyle(color: Color(0xFFD2D9E1), fontSize: 13),
          ),
        ),
        if (canRetry)
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        if (status == PlannerLinkStatus.error)
          IconButton(
            tooltip: 'Dismiss route link message',
            onPressed: onDismiss,
            icon: const Icon(Icons.close, size: 20),
          ),
      ],
    ),
  );
}

class _RideForm extends StatefulWidget {
  const _RideForm({
    required this.controller,
    required this.rideCodePreference,
    required this.riderProfile,
    required this.sharedRoutes,
    required this.planDirectory,
    required this.creating,
    required this.onComplete,
    this.pendingInAppRoute,
  });

  final RideController controller;
  final RideCodePreferenceController rideCodePreference;
  final RiderProfileController riderProfile;
  final SharedRouteController sharedRoutes;
  final PlanDirectory? planDirectory;
  final bool creating;
  final VoidCallback onComplete;
  final PendingInAppRoute? pendingInAppRoute;

  @override
  State<_RideForm> createState() => _RideFormState();
}

class _RideFormState extends State<_RideForm> with WidgetsBindingObserver {
  late final _nameController = TextEditingController(
    text: widget.riderProfile.displayName,
  );
  late final _codeController = TextEditingController(
    text: widget.creating ? null : widget.rideCodePreference.savedCode,
  );
  final _rideNameController = TextEditingController();
  final _planCodeController = TextEditingController();
  final _codeFocusNode = FocusNode();
  final _codeFieldKey = GlobalKey();
  RideCoordinationMode _selectedCoordinationMode =
      RideCoordinationMode.secondBikeDropOff;

  /// Set once a created ride's code needs sharing before handing off to the
  /// map - the moment a leader most needs it, with people waiting nearby.
  bool _showShareStep = false;
  bool _checkingPlanCode = false;
  String? _planCodeError;
  PickedGpxFile? _pendingPlanFile;

  /// Captured when pasted text includes a join token alongside the six
  /// digits - see [parseJoinInvite]. Typing the code by hand leaves this
  /// null, which still works but only via the rate-limited fallback.
  String? _pastedJoinToken;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _codeFocusNode.addListener(_keepCodeFieldVisible);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _codeFocusNode.removeListener(_keepCodeFieldVisible);
    _codeFocusNode.dispose();
    _nameController.dispose();
    _codeController.dispose();
    _rideNameController.dispose();
    _planCodeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_showShareStep) {
      return _ShareCodeStep(
        controller: widget.controller,
        onContinue: _finishCreating,
      );
    }
    return AnimatedBuilder(
      animation: Listenable.merge([
        widget.controller,
        widget.rideCodePreference,
      ]),
      builder: (context, _) => AnimatedPadding(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SingleChildScrollView(
          key: const Key('ride-form-scroll-view'),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.creating ? 'Create a private ride' : 'Join your group',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 8),
              Text(
                widget.creating
                    ? 'You will become the ride lead and get a six-digit code to share.'
                    : 'Enter the six-digit code shared by the ride lead. You need a connection once to join, then the app keeps using the secure relay.',
                style: const TextStyle(color: Color(0xFFABB5C1)),
              ),
              const SizedBox(height: 24),
              if (widget.creating) ...[
                Text(
                  'Who is riding?',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                SegmentedButton<bool>(
                  key: const Key('ride-scope-selector'),
                  segments: const [
                    ButtonSegment(
                      value: false,
                      icon: Icon(Icons.person_outline),
                      label: Text('Solo'),
                    ),
                    ButtonSegment(
                      value: true,
                      icon: Icon(Icons.groups_2_outlined),
                      label: Text('Group'),
                    ),
                  ],
                  selected: {_selectedCoordinationMode.isGroup},
                  onSelectionChanged: (selection) => setState(() {
                    _selectedCoordinationMode = selection.first
                        ? RideCoordinationMode.secondBikeDropOff
                        : RideCoordinationMode.solo;
                  }),
                ),
                const SizedBox(height: 8),
                Text(
                  _selectedCoordinationMode == RideCoordinationMode.solo
                      ? RideCoordinationMode.solo.description
                      : 'Choose how this group will handle junctions.',
                  style: const TextStyle(
                    color: Color(0xFFABB5C1),
                    fontSize: 13,
                  ),
                ),
                if (_selectedCoordinationMode.isGroup) ...[
                  const SizedBox(height: 12),
                  RadioGroup<RideCoordinationMode>(
                    groupValue: _selectedCoordinationMode,
                    onChanged: (value) {
                      if (value != null) {
                        setState(() => _selectedCoordinationMode = value);
                      }
                    },
                    child: Column(
                      children: [
                        for (final mode in const [
                          RideCoordinationMode.secondBikeDropOff,
                          RideCoordinationMode.keepTogether,
                        ])
                          RadioListTile<RideCoordinationMode>(
                            key: Key('ride-mode-${mode.name}'),
                            contentPadding: EdgeInsets.zero,
                            value: mode,
                            title: Text(mode.label),
                            subtitle: Text(mode.description),
                          ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                TextField(
                  controller: _rideNameController,
                  maxLength: 32,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Ride name (optional)',
                    hintText: 'e.g. Sunday coast run',
                    counterText: '',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('planned-route-code-field'),
                  controller: _planCodeController,
                  textCapitalization: TextCapitalization.characters,
                  textInputAction: TextInputAction.next,
                  autocorrect: false,
                  maxLength: 16,
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp('[A-Za-z0-9]')),
                    LengthLimitingTextInputFormatter(16),
                  ],
                  decoration: InputDecoration(
                    labelText: 'Planned route code (optional)',
                    hintText: 'e.g. 7F3K9QRT',
                    helperText:
                        'From the web planner. The route opens for review after the ride is created.',
                    errorText: _planCodeError,
                    counterText: '',
                    suffixIcon: const Icon(Icons.qr_code),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              TextField(
                key: const Key('rider-name-field'),
                controller: _nameController,
                autofocus: true,
                maxLength: 24,
                textCapitalization: TextCapitalization.words,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: 'Rider name',
                  hintText: 'How the group will recognise you',
                  counterText: '',
                ),
              ),
              if (!widget.creating) ...[
                const SizedBox(height: 12),
                KeyedSubtree(
                  key: _codeFieldKey,
                  child: TextField(
                    key: const Key('ride-code-field'),
                    controller: _codeController,
                    focusNode: _codeFocusNode,
                    scrollPadding: const EdgeInsets.only(bottom: 112),
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) {
                      if (!widget.controller.busy) _submit();
                    },
                    autocorrect: false,
                    maxLength: 6,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(6),
                    ],
                    decoration: InputDecoration(
                      labelText: 'Six-digit ride code',
                      hintText: '123456',
                      helperText: widget.rideCodePreference.savedCode == null
                          ? null
                          : 'Saved from your last successful join',
                      counterText: '',
                      // Scanning sits beside pasting rather than replacing it.
                      // A camera is the only join path that works with no signal
                      // (#279), and must never become the only path at all.
                      suffixIcon: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            key: const Key('scan-invitation-button'),
                            tooltip: 'Scan an invitation code',
                            onPressed: _scanInvitation,
                            icon: const Icon(Icons.qr_code_scanner),
                          ),
                          IconButton(
                            tooltip: 'Paste ride code',
                            onPressed: _pasteRideCode,
                            icon: const Icon(Icons.content_paste),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                // The same action as the camera icon in the field above, said
                // out loud.
                //
                // #279 shipped QR joining and #306 found it had not been
                // delivered: the owner concluded it was missing entirely,
                // because the only affordance was an unlabelled icon and a
                // tooltip, and a tooltip does not appear when you tap a phone.
                // The icon stays for riders who have learned it; this is the
                // one a rider who has never seen the app can read.
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    key: const Key('scan-invitation-labelled-button'),
                    onPressed: _scanInvitation,
                    icon: const Icon(Icons.qr_code_scanner),
                    label: const Text('Scan an invitation code'),
                  ),
                ),
                CheckboxListTile(
                  key: const Key('keep-ride-code'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: widget.rideCodePreference.keepCode,
                  onChanged: (value) {
                    if (value != null) {
                      widget.rideCodePreference.setKeepCode(value);
                    }
                  },
                  title: const Text('Keep this code for next time'),
                  subtitle: const Text(
                    'Only the six-digit code is saved. Invitation secrets are not.',
                  ),
                ),
                if (widget.rideCodePreference.savedCode != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: const Key('forget-saved-ride-code'),
                      onPressed: _forgetSavedCode,
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Forget saved code'),
                    ),
                  ),
              ],
              if (widget.controller.errorMessage case final String message) ...[
                const SizedBox(height: 12),
                Text(
                  message,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                // A connection or service failure is worth another go, and there
                // was nothing to press: the rider read a sentence about a relay
                // handshake and had to guess (#208).
                if (widget.controller.errorIsRetryable)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: const Key('retry-ride-submit'),
                      onPressed: widget.controller.busy || _checkingPlanCode
                          ? null
                          : () {
                              widget.controller.clearError();
                              unawaited(_submit());
                            },
                      icon: const Icon(Icons.refresh),
                      label: const Text('Try again'),
                    ),
                  ),
              ],
              const SizedBox(height: 22),
              FilledButton(
                onPressed: widget.controller.busy || _checkingPlanCode
                    ? null
                    : _submit,
                child: widget.controller.busy || _checkingPlanCode
                    ? const SizedBox.square(
                        dimension: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(widget.creating ? 'Create ride' : 'Join ride'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _submit() async {
    final name = _nameController.text;
    if (widget.creating) {
      final code = _planCodeController.text.trim();
      _pendingPlanFile = null;
      if (code.isNotEmpty) {
        setState(() {
          _checkingPlanCode = true;
          _planCodeError = null;
        });
        final ownedDirectory = widget.planDirectory == null
            ? HttpPlanDirectory.fromEnvironment()
            : null;
        try {
          final plan = await (widget.planDirectory ?? ownedDirectory!).fetch(
            code,
          );
          _pendingPlanFile = PickedGpxFile(
            name: '${plan.name ?? 'planned-route'}.gpx',
            bytes: Uint8List.fromList(utf8.encode(plan.gpx)),
          );
        } on PlanDirectoryException catch (error) {
          if (mounted) setState(() => _planCodeError = error.message);
          return;
        } on Object {
          if (mounted) {
            setState(
              () => _planCodeError =
                  'The planned route could not be loaded. Check your connection and try again.',
            );
          }
          return;
        } finally {
          ownedDirectory?.close();
          if (mounted) setState(() => _checkingPlanCode = false);
        }
      }
      await widget.controller.createRide(
        name,
        motorcycleStyle: widget.riderProfile.motorcycleStyle,
        riderSymbol: widget.riderProfile.riderSymbol,
        riderColor: widget.riderProfile.riderColor,
        coordinationMode: _selectedCoordinationMode,
        rideName: _rideNameController.text,
      );
    } else {
      final code = _codeController.text.trim();
      await widget.controller.joinRide(
        code,
        name,
        motorcycleStyle: widget.riderProfile.motorcycleStyle,
        riderSymbol: widget.riderProfile.riderSymbol,
        riderColor: widget.riderProfile.riderColor,
        joinToken: _pastedJoinToken,
      );
      if (widget.controller.hasActiveRide) {
        await widget.rideCodePreference.rememberSuccessfulJoin(code);
      } else if (widget.controller.errorMessage?.startsWith(
            'That ride code is not active.',
          ) ??
          false) {
        await widget.rideCodePreference.clearIfInactive(code);
      }
    }
    if (widget.controller.hasActiveRide && mounted) {
      await widget.riderProfile.save(
        displayName: name.trim(),
        motorcycleStyle: widget.riderProfile.motorcycleStyle,
        riderSymbol: widget.riderProfile.riderSymbol,
        riderColor: widget.riderProfile.riderColor,
      );
      if (widget.creating) {
        if (_selectedCoordinationMode.isGroup) {
          setState(() => _showShareStep = true);
        } else {
          _finishCreating();
        }
      } else {
        widget.onComplete();
      }
    }
  }

  void _finishCreating() {
    if (_pendingPlanFile case final file?) {
      widget.sharedRoutes.stagePending(file);
      _pendingPlanFile = null;
    } else if (widget.pendingInAppRoute case final route?) {
      widget.sharedRoutes.stagePendingInAppRoute(
        route.route,
        reviewNotes: route.reviewNotes,
      );
    }
    widget.onComplete();
  }

  @override
  void didChangeMetrics() {
    if (!_codeFocusNode.hasFocus) return;
    Future<void>.delayed(const Duration(milliseconds: 220), () {
      if (mounted) _keepCodeFieldVisible();
    });
  }

  void _keepCodeFieldVisible() {
    if (!_codeFocusNode.hasFocus) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final fieldContext = _codeFieldKey.currentContext;
      if (!mounted || fieldContext == null) return;
      Scrollable.ensureVisible(
        fieldContext,
        alignment: 0.55,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _forgetSavedCode() async {
    final savedCode = widget.rideCodePreference.savedCode;
    await widget.rideCodePreference.clear();
    if (_codeController.text == savedCode) _codeController.clear();
  }

  /// Scans an invitation and joins from it, with no relay lookup (#279).
  ///
  /// The whole point is that this works with no signal, so it joins directly from
  /// the scanned credentials rather than filling in the code field and going
  /// through the online path - which would defeat it.
  Future<void> _scanInvitation() async {
    final invitation = await ScanInvitationScreen.show(context);
    if (invitation == null || !mounted) return;
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      // Ask for the name rather than joining as nobody: the roster is how a group
      // finds each other.
      setState(() => _codeController.text = invitation.rideCode);
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Add your rider name, then join.')),
      );
      return;
    }
    await widget.controller.joinRideFromInvitation(
      invitation,
      name,
      motorcycleStyle: widget.riderProfile.motorcycleStyle,
      riderSymbol: widget.riderProfile.riderSymbol,
      riderColor: widget.riderProfile.riderColor,
    );
    if (!mounted) return;
    if (widget.controller.hasActiveRide) {
      await widget.rideCodePreference.rememberSuccessfulJoin(
        invitation.rideCode,
      );
    }
  }

  Future<void> _pasteRideCode() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty || !mounted) return;
    final invite = parseJoinInvite(text);
    final code = invite.code ?? text;
    _pastedJoinToken = invite.token;
    _codeController.text = code;
    _codeController.selection = TextSelection.collapsed(offset: code.length);
  }
}

/// Shown immediately after creating a ride - the moment a leader most needs
/// the code, with riders waiting nearby, rather than requiring a trip
/// through the active Ride page to find it.
class _ShareCodeStep extends StatelessWidget {
  const _ShareCodeStep({required this.controller, required this.onContinue});

  final RideController controller;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    final session = controller.session;
    final code = session?.rideCode ?? '';
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(Icons.check_circle, color: Color(0xFF6ED89A), size: 40),
          const SizedBox(height: 16),
          Text(
            session?.rideName ?? 'Ride created',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 8),
          const Text(
            'Share this code so the group can join.',
            style: TextStyle(color: Color(0xFFABB5C1)),
          ),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 18),
            decoration: BoxDecoration(
              color: const Color(0xFF111720),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFF2A3441)),
            ),
            child: Center(
              child: Text(
                code,
                style: const TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 34,
                  letterSpacing: 6,
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => Clipboard.setData(ClipboardData(text: code)),
                  icon: const Icon(Icons.copy_outlined),
                  label: const Text('Copy'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => SharePlus.instance.share(
                    ShareParams(
                      text: controller.rideCodeShareText,
                      subject: 'Join my Tail End Charlie group',
                    ),
                  ),
                  icon: const Icon(Icons.ios_share),
                  label: const Text('Share'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 22),
          TextButton(
            onPressed: onContinue,
            child: const Text('Continue to ride'),
          ),
        ],
      ),
    );
  }
}

/// The notices area: compact cards on the map, and nothing at all when there is
/// nothing to say (#426).
///
/// The old home screen carried these in the scrolling column of a full-screen
/// panel, which is most of why the panel was full-screen. They still need a home —
/// a restoration failure, a set-aside ride, a pending shared route and a planner
/// link all matter — but not one that reserves space when empty.
///
/// Scrollable because several can be live at once and the map must not be pushed
/// off the screen by a stack of them.
class _HomeNotices extends StatelessWidget {
  const _HomeNotices({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final visible = children.where((child) => child is! SizedBox).toList();
    if (visible.isEmpty) return const SizedBox.shrink();
    return ConstrainedBox(
      // A third of the screen at most. A notice is worth interrupting the map
      // for; four notices are not worth losing it.
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height / 3,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final child in visible)
              Padding(padding: const EdgeInsets.only(bottom: 10), child: child),
          ],
        ),
      ),
    );
  }
}
