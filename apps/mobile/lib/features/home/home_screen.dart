import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/services.dart';
import 'package:crypto/crypto.dart';
import 'package:share_plus/share_plus.dart';

import '../simulation/demo_route_picker.dart';
import '../../controllers/app_update_gate_controller.dart';
import '../../controllers/distance_unit_controller.dart';
import '../../controllers/global_ride_heatmap_controller.dart';
import '../../controllers/completed_rides_controller.dart';
import '../../controllers/map_style_mode_controller.dart';
import '../../controllers/ride_code_preference_controller.dart';
import '../../controllers/ride_controller.dart';
import '../../controllers/demo_route_choice_controller.dart';
import '../../controllers/mini_map_display_controller.dart';
import '../../controllers/route_progress_display_controller.dart';
import '../../controllers/rider_profile_controller.dart';
import '../../controllers/shared_route_controller.dart';
import '../../controllers/speed_limit_display_controller.dart';
import '../../controllers/ride_diagnostics_controller.dart';
import '../../controllers/spoken_guidance_controller.dart';
import '../../data/ride_diagnostics_log_store.dart';
import '../../domain/completed_ride.dart';
import '../../domain/imported_route.dart' show GeoPoint, ImportedRoute;
import '../../domain/map_style_mode.dart';
import '../../services/road_routing.dart';
import '../../services/verified_road_routing.dart';
import 'home_destination_search.dart';
import 'home_map_backdrop.dart';
import 'ride_with_others_sheet.dart';
import 'scan_invitation_screen.dart';
import '../../controllers/test_control_controller.dart';
import '../../domain/join_invite.dart';
import '../../domain/recorded_route_store.dart';
import '../../domain/route_store.dart';
import '../../data/json_file_route_store.dart';
import '../../domain/ride_coordination_mode.dart';
import '../../domain/ride_plan.dart';
import '../../internet/plan_directory.dart';
import '../../services/build_identity.dart';
import '../../services/basemap_configuration.dart';
import '../../services/carplay_bridge.dart';
import '../../services/carplay_route_preview.dart';
import '../../services/gpx_import_source.dart';
import '../../services/ride_plan_router.dart';
import '../../services/route_importer.dart';
import '../../services/stored_route_library.dart';
import '../../services/route_preferences_memory.dart';
import '../map/ride_map_feature.dart'
    show HostMapChrome, HostMapMenuAction, rideMapToolbarHeight;
import '../map/route_review_screen.dart';
import '../map/stored_route_picker.dart';
import '../ride/previous_rides_screen.dart';
import '../ride/route_recorder_screen.dart';
import '../settings/unit_settings_sheet.dart';
import '../settings/about_build_sheet.dart';
import '../update/update_required_screen.dart';

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
  if (existing != null) {
    if (existing.libraryStatus == RideLibraryStatus.active) return existing;
    final restored = existing.withLibraryDetails(
      status: RideLibraryStatus.active,
    );
    await recordedRoutes.save(restored);
    return restored;
  }

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
    this.miniMapDisplay,
    this.demoRouteChoice,
    required this.recordedRoutes,
    required this.completedRides,
    this.globalRideHeatmap,
    this.planDirectory,
    this.testControl,
    this.spokenGuidance,
    this.rideDiagnostics,
    this.updateGate,
    this.restoringRideCode,
    this.restorationError,
    this.onRetryRestoration,
    this.openJoinGroup = false,
    this.onJoinGroupOpened,
    this.enableNativeServices = true,
    this.destinationPlanner,
    this.freeRoamRouteStore,
  });

  final RideController controller;
  final DistanceUnitController distanceUnits;
  final MapStyleModeController mapStyleMode;
  final RideCodePreferenceController rideCodePreference;
  final RiderProfileController riderProfile;
  final SharedRouteController sharedRoutes;
  final SpeedLimitDisplayController speedLimitDisplay;
  final RouteProgressDisplayController? routeProgressDisplay;
  final MiniMapDisplayController? miniMapDisplay;

  /// Which bundled demo route a simulated ride and the map's demo action use
  /// (#934). Null in tests that do not exercise the choice.
  final DemoRouteChoiceController? demoRouteChoice;
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

  /// What the ride service has said about this build (#37). Null in a widget
  /// test that does not exercise it. It only changes what the map says: the
  /// banner and one full-screen explanation, never anything a ride depends on.
  final AppUpdateGateController? updateGate;

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

  @visibleForTesting
  final DestinationRoutePlanner? destinationPlanner;

  /// Free roam's route store, which Ride with others clears once the route
  /// has moved into the ride. Null opens the app-wide default.
  @visibleForTesting
  final Future<RouteStore> Function()? freeRoamRouteStore;

  /// The planner Home uses when none is injected.
  ///
  /// A function of its own so a test can hold it to the one thing it once got
  /// wrong. It was built on OSRM alone, which cannot express a single route
  /// preference, so "Avoid motorways" was dropped on the way to the router and
  /// a route up the M5 was reviewed under a note saying motorways were excluded
  /// (#858). It plans through the same preference-aware, checked routing as the
  /// map does, and a route that could not be checked or re-planned around a
  /// track could not be either (#840).
  @visibleForTesting
  static DestinationRoutePlanner defaultDestinationPlanner({
    required http.Client client,
    required RoutingConfiguration configuration,
  }) => DestinationRoutePlanner(
    searchService: buildDestinationSearchService(
      client: client,
      configuration: configuration,
    ),
    routingService: buildPlanningRoutingService(
      client: client,
      configuration: configuration,
    ),
  );

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
      onDestinationPreviewRequested: _previewCarPlayDestination,
      onDestinationPreviewCommitted: _commitCarPlayDestinationPreview,
      onDestinationPreviewCancelled: _cancelCarPlayDestinationPreview,
      onFreeRoamRequested: _startCarPlayFreeRoam,
      onStateRequested: () async => _publishHomeCarPlayState(),
    );
    _position.addListener(_publishHomeCarPlayState);
    _position.addListener(_observeAutomaticUnits);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _publishHomeCarPlayState();
    });
    widget.updateGate?.addListener(_onUpdateGateChanged);
    unawaited(widget.updateGate?.check());
    _onUpdateGateChanged();
    _takeRouteFromGroup();
    if (widget.openJoinGroup) {
      _scheduleJoinGroupSheet();
      return;
    }
    final choice = widget.riderProfile.takePendingRideChoice();
    if (choice != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        // "Create a ride" from onboarding is riding with others: there is no
        // second, solo kind of ride to create on the phone any more (#847).
        if (choice == OnboardingRideChoice.create) {
          unawaited(_rideWithOthers());
        } else {
          unawaited(_showJoinSheet(context));
        }
      });
    }
  }

  /// A route a rider is riding on with alone, handed back by the group ride
  /// they left (#847). Free roam navigates it as it is: it was confirmed
  /// already, and the rider is probably moving.
  void _takeRouteFromGroup() {
    final route = widget.sharedRoutes.takeFreeRoamRoute();
    if (route == null) return;
    _freeRoamRoute = PendingInAppRoute(route: route, reviewed: true);
    _freeRoamRouteToken = Object();
  }

  /// Ride with others: one action that turns what this rider is doing into a
  /// group ride (#847). A route on the map comes with them, and a rider who is
  /// following it is not put back into a lobby: the ride starts at once and
  /// navigation carries on.
  Future<void> _rideWithOthers() async {
    final route = _routeOnMap;
    final controller = widget.controller;
    final freeRoamRouteStore = widget.freeRoamRouteStore;
    await RideWithOthersSheet.show(
      context,
      controller: controller,
      riderProfile: widget.riderProfile,
      route: route,
      startNow: route != null,
    );
    if (route == null ||
        !controller.hasActiveRide ||
        !controller.coordinationMode.isGroup) {
      return;
    }
    // The route moved into the ride. Free roam keeps its own copy on disk, and
    // leaving it there would bring it back as navigation when the group ride
    // is over.
    try {
      final store =
          await (freeRoamRouteStore ?? JsonFileRouteStore.openDefault)();
      await store.clearActiveRoute();
    } on Object {
      // Best effort: a route that comes back can still be stopped.
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
    if (oldWidget.updateGate != widget.updateGate) {
      oldWidget.updateGate?.removeListener(_onUpdateGateChanged);
      widget.updateGate?.addListener(_onUpdateGateChanged);
      _onUpdateGateChanged();
    }
    if (widget.sharedRoutes.pendingFreeRoamRoute != null) {
      setState(_takeRouteFromGroup);
    }
  }

  void _onUpdateGateChanged() {
    if (!mounted) return;
    // Rebuild for the banner; the full-screen explanation is offered at most
    // once per launch, and only when nothing else owns the rider's attention.
    setState(() {});
    final gate = widget.updateGate;
    if (gate == null ||
        !shouldOfferUpdateScreen(
          gate: gate,
          hasActiveRide: widget.controller.hasActiveRide,
          restoring: widget.onRetryRestoration != null,
        )) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          ModalRoute.of(context)?.isCurrent != true ||
          !shouldOfferUpdateScreen(
            gate: gate,
            hasActiveRide: widget.controller.hasActiveRide,
            restoring: widget.onRetryRestoration != null,
          )) {
        return;
      }
      gate.markPresented();
      unawaited(
        UpdateRequiredScreen.show(
          context,
          identity: _buildIdentity,
          state: gate.state,
        ),
      );
    });
  }

  void _scheduleJoinGroupSheet() {
    if (_joinGroupOpenScheduled) return;
    _joinGroupOpenScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      widget.onJoinGroupOpened?.call();
      await _showJoinSheet(context);
      _joinGroupOpenScheduled = false;
    });
  }

  /// Where the rider is, shared with the map below so a searched destination can
  /// be routed from here (#431).
  final _position = ValueNotifier<GeoPoint?>(null);

  void _observeAutomaticUnits() {
    final position = _position.value;
    if (position == null) return;
    unawaited(
      widget.distanceUnits.observeRoadPosition(
        latitude: position.latitude,
        longitude: position.longitude,
      ),
    );
  }

  @override
  void dispose() {
    // This screen had nothing to dispose until #431 gave it a notifier it shares
    // with the map and a client it lends to the geocoder.
    _position.removeListener(_publishHomeCarPlayState);
    _position.removeListener(_observeAutomaticUnits);
    widget.updateGate?.removeListener(_onUpdateGateChanged);
    unawaited(_carPlayBridge.dispose());
    _position.dispose();
    _routingClient.close();
    super.dispose();
  }

  /// True while a route is being planned, which disables the actions so a rider
  /// cannot start a second ride on top of the one being arranged.
  bool _planningDestination = false;
  final _carPlayRoutePreview = CarPlayRoutePreviewTransaction();

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

  /// Bumped to reopen the free-roam route on the plan surface (#847). The map
  /// owns the route and the surface, so Home only asks.
  Object? _editRouteRequestToken;

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

  late final DestinationRoutePlanner _destinationPlanner =
      widget.destinationPlanner ??
      HomeScreen.defaultDestinationPlanner(
        client: _routingClient,
        configuration: RoutingConfiguration.fromEnvironment(),
      );

  /// Routes the plan surface's plans through the destination planner's own
  /// service, so a plan is routed exactly as a destination is (#847).
  late final RidePlanRouter _planRouter = RidePlanRouter(
    routingService: _destinationPlanner.routingService,
  );

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
        // Location consent and account/profile setup are pre-drive work. Do
        // not expose an in-car action until it can finish entirely in CarPlay.
        canPlanRoute: position != null && _rideEntryEnabled,
        canFreeRoam: position != null && _rideEntryEnabled,
        showTecStatus: false,
        followRider: position != null,
        distanceUnit: widget.distanceUnits.value,
        localeIdentifier: Localizations.localeOf(context).toLanguageTag(),
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
        'Location is not ready. Route planning is unavailable.',
      );
    }
    if (groupRide == null) {
      await _navigateTo(
        DestinationChoice(label: destination.label, point: destination.point),
      );
      return;
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

  Future<CarPlayTripPreview> _previewCarPlayDestination(
    CarPlayDestination destination,
  ) async {
    if (_planningDestination || widget.controller.busy) {
      throw const FormatException('Ride setup is already in progress.');
    }
    final origin = _position.value;
    if (origin == null) {
      throw const FormatException(
        'Location is not ready. Route planning is unavailable.',
      );
    }
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
      final preview = CarPlayTripPreview.single(
        destinationLabel: destination.label,
        plan: plan,
      );
      _carPlayRoutePreview.replace(preview);
      return preview;
    } finally {
      if (mounted) {
        setState(() => _planningDestination = false);
        _publishHomeCarPlayState();
      }
    }
  }

  Future<void> _commitCarPlayDestinationPreview(
    String previewId,
    String routeChoiceId,
  ) async {
    if (_planningDestination || widget.controller.busy) {
      throw const FormatException('Ride setup is already in progress.');
    }
    final selected = _carPlayRoutePreview.commit(
      previewId: previewId,
      routeChoiceId: routeChoiceId,
    );
    final controller = widget.controller;
    final profile = widget.riderProfile;
    setState(() => _planningDestination = true);
    _publishHomeCarPlayState();
    try {
      await controller.createRide(
        profile.displayName,
        motorcycleStyle: profile.motorcycleStyle,
        riderSymbol: profile.riderSymbol,
        riderColor: profile.riderColor,
        coordinationMode: RideCoordinationMode.solo,
        rideName: selected.destinationLabel,
      );
      await controller.publishRoute(selected.route);
    } finally {
      if (mounted) {
        setState(() => _planningDestination = false);
        _publishHomeCarPlayState();
      }
    }
  }

  Future<void> _cancelCarPlayDestinationPreview(String previewId) async {
    _carPlayRoutePreview.cancel(previewId);
  }

  Future<void> _startCarPlayFreeRoam() async {
    if (_planningDestination || widget.controller.busy) {
      throw const FormatException('Ride setup is already in progress.');
    }
    if (_position.value == null) {
      throw const FormatException(
        'Location is not ready. Free roam is unavailable.',
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
            spokenGuidance: widget.spokenGuidance,
            rideDiagnostics: widget.rideDiagnostics,
            distanceUnit: widget.distanceUnits.value,
            completedRideStore: widget.completedRides,
            recordedRouteStore: widget.recordedRoutes,
            globalRideHeatmap: widget.globalRideHeatmap,
            enableNativeServices: widget.enableNativeServices,
            demoRouteChoice: widget.demoRouteChoice,
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
            editRouteRequestToken: _editRouteRequestToken,
            onEditRouteRequestHandled: () => setState(() {
              _editRouteRequestToken = null;
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
              menuActions: [
                // Confirming a route is not final (#847). Offered from the
                // menu, which the navigation canvas's menu button also opens,
                // so it is reachable on the move as well as at a standstill.
                if (_routeOnMap != null)
                  HostMapMenuAction(
                    id: 'home-edit-route',
                    label: 'Edit route',
                    icon: Icons.edit_road_outlined,
                    onSelected: () =>
                        setState(() => _editRouteRequestToken = Object()),
                  ),
                HostMapMenuAction(
                  id: 'home-create-ride',
                  // Carries the route on the map into the ride (#847). It
                  // used to open a form that left the route behind.
                  label: 'Ride with others',
                  icon: Icons.groups_2_outlined,
                  onSelected: _rideEntryEnabled
                      ? () => unawaited(_rideWithOthers())
                      : null,
                ),
                HostMapMenuAction(
                  id: 'record-a-route-button',
                  label: 'Record a route',
                  icon: Icons.fiber_manual_record_outlined,
                  onSelected: () => unawaited(
                    RouteRecorderScreen.show(context, widget.recordedRoutes),
                  ),
                ),
                HostMapMenuAction(
                  id: 'home-more-settings',
                  label: 'Settings',
                  icon: Icons.settings_outlined,
                  onSelected: () => unawaited(_openSettings()),
                ),
                if (widget.controller.rideSetAside &&
                    widget.controller.session != null)
                  HostMapMenuAction(
                    id: 'home-rejoin-set-aside-ride',
                    label: 'Rejoin ride ${widget.controller.session!.rideCode}',
                    icon: Icons.restore,
                    onSelected: widget.controller.reopenEndedRide,
                  ),
                HostMapMenuAction(
                  id: 'start-ride-simulator',
                  label: 'Try a simulated ride',
                  icon: Icons.science_outlined,
                  onSelected:
                      !widget.controller.busy &&
                          widget.onRetryRestoration == null
                      ? () => unawaited(_startSimulation())
                      : null,
                ),
              ],
              onOpenRideLibrary: () => unawaited(_openRideLibrary(context)),
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
                            ? () => unawaited(_showJoinSheet(context))
                            : null,
                        icon: const Icon(Icons.group_add_outlined, size: 16),
                        label: const Text('Join'),
                      ),
                      IconButton(
                        tooltip: 'Settings',
                        onPressed: _openSettings,
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
                  dark: basemap.dark,
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
    if (widget.updateGate case final gate? when gate.updateRequired)
      UpdateRequiredBanner(gate: gate, identity: _buildIdentity),
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

  /// Asks which demo route to ride, remembers it, then starts the simulation
  /// (#934). Dismissing the sheet starts nothing.
  Future<void> _startSimulation() async {
    final choice = widget.demoRouteChoice;
    if (choice != null) {
      final picked = await showDemoRoutePicker(
        context,
        current: choice.current,
      );
      if (picked == null) return;
      await choice.choose(picked);
      if (!mounted) return;
    }
    await widget.controller.createSimulationRide();
  }

  Future<void> _openSettings() => UnitSettingsSheet.show(
    context,
    widget.distanceUnits,
    widget.mapStyleMode,
    widget.riderProfile,
    speedLimitDisplay: widget.speedLimitDisplay,
    routeProgressDisplay: widget.routeProgressDisplay,
    miniMapDisplay: widget.miniMapDisplay,
    testControl: widget.testControl,
    spokenGuidance: widget.spokenGuidance,
    rideDiagnostics: widget.rideDiagnostics,
    globalRideHeatmap: widget.globalRideHeatmap,
    completedRideStore: widget.completedRides,
  );

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
          // Joining takes a six-digit code, so it stays the join form.
          case HomeSearchHandoffKind.joinWithCode:
            await _showJoinSheet(context);
          // A planned route is a route, not a ride: it is reviewed and ridden
          // in free roam like an imported GPX, and riding it with others is a
          // choice made afterwards (#847).
          case HomeSearchHandoffKind.plannedRouteCode:
            await _recallPlannedRoute();
          case HomeSearchHandoffKind.storedRoute:
            await _openRideLibrary(context);
          case HomeSearchHandoffKind.circularRide:
            setState(() => _circularRideRequestToken = Object());
        }
    }
  }

  /// Opens the plan surface on a route to the chosen place (#847).
  ///
  /// The start is the rider's location unless they change it there, and a
  /// missing fix does not stop a destination being chosen: the start row says
  /// it is waiting, and offers a place instead. The text form that used to sit
  /// between the search and the route is gone; stops, the start and route
  /// options are all edited on the surface that shows the route.
  ///
  /// No ride is created for a solo plan. A rider who searched for somewhere to
  /// go said nothing about riding with anybody (#600), and the map navigates
  /// the confirmed route as it is, without a second review (#624). Choosing a
  /// group on the plan creates the ride with the route already in it.
  Future<void> _navigateTo(DestinationChoice choice) async {
    // A new plan starts with the options the rider last confirmed (#894).
    final preferences = await const RoutePreferencesMemory().load();
    if (!mounted) return;
    final outcome = await RouteReviewScreen.showPlan(
      context,
      planning: RidePlanEditing(
        plan: RidePlan.toDestination(
          RidePlanPlace.fromSearchResult(
            label: choice.label,
            point: choice.point,
          ),
          preferences: preferences,
        ),
        route: (plan, location) => _planRouter.route(
          plan,
          currentLocation: location,
          distanceUnit: widget.distanceUnits.value,
        ),
        searchService: _destinationPlanner.searchService,
        currentLocation: _position,
        offerCoordinationChoice: true,
        confirmLabel: (plan) => plan.isGroup ? 'Create group ride' : 'Start',
      ),
      distanceUnit: widget.distanceUnits.value,
      basemapConfiguration: _planBasemap,
    );
    if (outcome == null || !mounted) return;
    if (outcome.plan.isGroup) {
      await RideWithOthersSheet.show(
        context,
        controller: widget.controller,
        riderProfile: widget.riderProfile,
        route: outcome.route,
        coordinationMode: outcome.plan.coordinationMode,
      );
      return;
    }
    setState(() {
      _freeRoamRoute = PendingInAppRoute(route: outcome.route, reviewed: true);
      _freeRoamRouteToken = Object();
    });
  }

  /// The plan surface's map. A build without the platform map — widget tests,
  /// plugin-less builds — gets the route-only preview the review already has.
  BasemapConfiguration get _planBasemap =>
      widget.enableNativeServices ? _homeBasemap : const BasemapConfiguration();

  /// The join form: a six-digit code, a paste, or an invitation to scan.
  ///
  /// It used to create rides too, with a Solo/Group choice, a ride name and a
  /// planned-route code in front of any route (#847). Solo is free roam now,
  /// a group ride is Ride with others carrying the route, and a planned-route
  /// code is reviewed in free roam, so joining is all this form does.
  Future<void> _showJoinSheet(BuildContext context) async {
    widget.controller.clearError();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: const Color(0xFF171D25),
      builder: (sheetContext) => _JoinForm(
        controller: widget.controller,
        rideCodePreference: widget.rideCodePreference,
        riderProfile: widget.riderProfile,
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
    // Into free roam's review, as a GPX import is, rather than a ride form
    // in front of it: choosing a saved route used to create a ride before the
    // rider could see it (#847).
    _reviewInFreeRoam(
      PendingInAppRoute(route: prepared.route, reviewNotes: prepared.notes),
    );
  }

  /// Hands a route to the free-roam map's review.
  void _reviewInFreeRoam(PendingInAppRoute route) => setState(() {
    _freeRoamRoute = route;
    _freeRoamRouteToken = Object();
  });

  /// Fetches a web-planner route by its code and reviews it in free roam.
  Future<void> _recallPlannedRoute() async {
    final code = await showDialog<String>(
      context: context,
      builder: (dialogContext) => const _PlanCodeDialog(),
    );
    if (code == null || code.trim().isEmpty || !mounted) return;
    final owned = widget.planDirectory == null
        ? HttpPlanDirectory.fromEnvironment()
        : null;
    try {
      final plan = await (widget.planDirectory ?? owned!).fetch(code.trim());
      final route = RouteImporter(source: const SystemGpxImportSource())
          .importFromFile(
            PickedGpxFile(
              name: '${plan.name ?? 'planned-route'}.gpx',
              bytes: Uint8List.fromList(utf8.encode(plan.gpx)),
            ),
          );
      if (!mounted) return;
      _reviewInFreeRoam(PendingInAppRoute(route: route));
    } on PlanDirectoryException catch (error) {
      _showSnack(error.message);
    } on FormatException catch (error) {
      _showSnack(error.message);
    } on Object {
      _showSnack(
        'The planned route could not be loaded. Check your connection and '
        'try again.',
      );
    } finally {
      owned?.close();
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _showSavedNavigation(CompletedRide ride) async {
    if (!mounted) return;
    final diagnostics = await _diagnosticsFor(ride.rideId);
    if (!mounted) return;
    final open = await showModalBottomSheet<bool>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheetContext) => SingleChildScrollView(
        child: Padding(
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
              if (diagnostics != null) ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  key: const Key('share-saved-navigation-diagnostics'),
                  onPressed: () => unawaited(
                    _shareNavigationDiagnostics(sheetContext, diagnostics),
                  ),
                  icon: const Icon(Icons.bug_report_outlined),
                  label: const Text('Share ride diagnostics'),
                ),
              ],
              TextButton(
                onPressed: () => Navigator.of(sheetContext).pop(false),
                child: const Text('Done'),
              ),
            ],
          ),
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

  Future<RideDiagnosticsLog?> _diagnosticsFor(String rideId) async {
    final store = widget.rideDiagnostics?.logStore;
    if (store == null) return null;
    return (await store.list())
        .where((log) => log.rideId == rideId)
        .firstOrNull;
  }

  Future<void> _shareNavigationDiagnostics(
    BuildContext context,
    RideDiagnosticsLog log,
  ) async {
    try {
      await SharePlus.instance.share(
        ShareParams(
          title: 'Ride diagnostics ${log.rideCode ?? log.rideId}',
          subject: 'Tail End Charlie diagnostics ${log.rideCode ?? log.rideId}',
          files: [
            XFile.fromData(
              Uint8List.fromList(utf8.encode(log.text)),
              mimeType: 'text/plain',
              name: log.fileName,
            ),
          ],
          fileNameOverrides: [log.fileName],
        ),
      );
    } on Object catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not share the diagnostics: $error')),
      );
    }
  }
}

/// Asks for a web-planner code. Its own widget so its text controller is
/// disposed with it.
class _PlanCodeDialog extends StatefulWidget {
  const _PlanCodeDialog();

  @override
  State<_PlanCodeDialog> createState() => _PlanCodeDialogState();
}

class _PlanCodeDialogState extends State<_PlanCodeDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Recall a planned route'),
    content: TextField(
      key: const Key('recall-plan-code-field'),
      controller: _controller,
      autofocus: true,
      textCapitalization: TextCapitalization.characters,
      maxLength: 16,
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp('[A-Za-z0-9]')),
        LengthLimitingTextInputFormatter(16),
      ],
      decoration: const InputDecoration(
        labelText: 'Plan code',
        hintText: 'e.g. 7F3K9QRT',
        helperText: 'From the web planner',
      ),
      onSubmitted: (value) => Navigator.of(context).pop(value),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const Key('recall-plan-code-load'),
        onPressed: () => Navigator.of(context).pop(_controller.text),
        child: const Text('Load'),
      ),
    ],
  );
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

class _JoinForm extends StatefulWidget {
  const _JoinForm({
    required this.controller,
    required this.rideCodePreference,
    required this.riderProfile,
    required this.onComplete,
  });

  final RideController controller;
  final RideCodePreferenceController rideCodePreference;
  final RiderProfileController riderProfile;
  final VoidCallback onComplete;

  @override
  State<_JoinForm> createState() => _JoinFormState();
}

class _JoinFormState extends State<_JoinForm> with WidgetsBindingObserver {
  late final _nameController = TextEditingController(
    text: widget.riderProfile.displayName,
  );
  late final _codeController = TextEditingController(
    text: widget.rideCodePreference.savedCode,
  );
  final _codeFocusNode = FocusNode();
  final _codeFieldKey = GlobalKey();

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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
                'Join your group',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 8),
              const Text(
                'Enter the six-digit code shared by the ride lead. You need a connection once to join, then the app keeps using the secure relay.',
                style: TextStyle(color: Color(0xFFABB5C1)),
              ),
              const SizedBox(height: 24),
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
              if (widget.controller.errorMessage case final String message) ...[
                const SizedBox(height: 12),
                Text(
                  message,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                // An old build cannot be helped by trying again; the way
                // through is the update, so it is one tap away (#37).
                if (widget.controller.errorNeedsUpdate)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: const Key('join-update-required'),
                      onPressed: () => unawaited(
                        UpdateRequiredScreen.show(
                          context,
                          identity: BuildIdentity.fromEnvironment(),
                          state: UpdateGateState.updateRequired(
                            message: message,
                          ),
                        ),
                      ),
                      icon: const Icon(Icons.system_update_alt),
                      label: const Text('Update Tail End Charlie'),
                    ),
                  ),
                // A connection or service failure is worth another go, and there
                // was nothing to press: the rider read a sentence about a relay
                // handshake and had to guess (#208).
                if (widget.controller.errorIsRetryable)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: const Key('retry-ride-submit'),
                      onPressed: widget.controller.busy
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
                onPressed: widget.controller.busy ? null : _submit,
                child: widget.controller.busy
                    ? const SizedBox.square(
                        dimension: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Join ride'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _submit() async {
    final name = _nameController.text;
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
    if (widget.controller.hasActiveRide && mounted) {
      await widget.riderProfile.save(
        displayName: name.trim(),
        motorcycleStyle: widget.riderProfile.motorcycleStyle,
        riderSymbol: widget.riderProfile.riderSymbol,
        riderColor: widget.riderProfile.riderColor,
      );
      widget.onComplete();
    }
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
