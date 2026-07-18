import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../controllers/distance_unit_controller.dart';
import '../../controllers/foreground_location_controller.dart';
import '../../controllers/internet_relay_controller.dart';
import '../../controllers/marker_assistance_controller.dart';
import '../../controllers/nearby_relay_controller.dart';
import '../../controllers/ride_controller.dart';
import '../../controllers/ride_simulation_controller.dart';
import '../../controllers/situational_awareness_controller.dart';
import '../../data/in_memory_event_store.dart';
import '../../data/json_file_route_store.dart';
import '../../domain/event_store.dart';
import '../../domain/geo_point.dart' as awareness_geo;
import '../../domain/hazard.dart';
import '../../domain/imported_route.dart' as route_domain;
import '../../domain/quick_message.dart';
import '../../domain/ride_event.dart';
import '../../domain/ride_role.dart';
import '../../domain/route_alert.dart';
import '../../domain/route_store.dart';
import '../../internet/internet_relay_client.dart';
import '../../internet/internet_relay_worker.dart';
import '../../internet/shared_preferences_internet_cursor_store.dart';
import '../../relay/native_nearby_transport.dart';
import '../../relay/nearby_event_source.dart';
import '../../relay/relay_engine.dart';
import '../../relay/sqlite_relay_queue.dart';
import '../../services/device_location_source.dart';
import '../../services/demo_route_loader.dart';
import '../../services/external_hazard_provider.dart';
import '../../services/leader_ride_status.dart';
import '../../services/route_decision_point_extractor.dart';
import '../../services/ride_completion_detector.dart';
import '../map/ride_map.dart';
import '../situational_awareness/situational_awareness_screen.dart';
import '../simulation/ride_simulation_screen.dart';
import 'ended_ride_screen.dart';
import 'ride_dashboard.dart';

/// Owns the active-ride feature lifecycle and keeps each feature independently
/// testable. Native permissions are requested only by the installed app, not by
/// widget tests that construct [RideRelayApp].
class ActiveRideShell extends StatefulWidget {
  const ActiveRideShell({
    super.key,
    required this.rideController,
    required this.distanceUnits,
    required this.eventStore,
    required this.enableNativeServices,
  });

  final RideController rideController;
  final DistanceUnitController distanceUnits;
  final EventStore eventStore;
  final bool enableNativeServices;

  @override
  State<ActiveRideShell> createState() => _ActiveRideShellState();
}

/// Compact, always-available navigation for the full-screen map canvas.
class _RideNavigationMenu extends StatelessWidget {
  const _RideNavigationMenu({
    required this.simulation,
    required this.selectedIndex,
    required this.onSelected,
  });

  final bool simulation;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final destinations = <({int index, IconData icon, String label})>[
      (index: 0, icon: Icons.map_outlined, label: 'Navigation map'),
      if (simulation)
        (index: 1, icon: Icons.science_outlined, label: 'Ride Lab'),
      (
        index: simulation ? 2 : 1,
        icon: Icons.tune_outlined,
        label: 'Ride details',
      ),
      (
        index: simulation ? 3 : 2,
        icon: Icons.health_and_safety_outlined,
        label: 'Safety',
      ),
    ];
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Ride menu', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 8),
            for (final destination in destinations)
              ListTile(
                key: Key('ride-menu-${destination.index}'),
                leading: Icon(destination.icon),
                title: Text(destination.label),
                trailing: selectedIndex == destination.index
                    ? const Icon(Icons.check, color: Color(0xFFFFC857))
                    : null,
                onTap: () => onSelected(destination.index),
              ),
          ],
        ),
      ),
    );
  }
}

class _ActiveRideShellState extends State<ActiveRideShell> {
  final _mapPosition = ValueNotifier<route_domain.GeoPoint?>(null);
  final _mapNavigationPosition = ValueNotifier<MapNavigationPosition?>(null);
  final _mapOverlays = ValueNotifier<List<MapOverlayMarker>>(const []);
  final _offRouteTraces = ValueNotifier<List<MapOverlayTrace>>(const []);
  final _leaderStatus = ValueNotifier<LeaderRideStatus?>(null);
  final _junctionMarkerOverlay = ValueNotifier<MapJunctionMarkerOverlay?>(null);
  final _locationSharing = ValueNotifier(false);
  final _riderTrails = <String, List<route_domain.GeoPoint>>{};
  final _publishedEventIds = <String>{};
  final _warnings = <String>{};
  final _rideCompletionDetector = RideCompletionDetector();

  SituationalAwarenessController? _awarenessController;
  ForegroundLocationController? _locationController;
  MarkerAssistanceController? _markerAssistanceController;
  NearbyRelayController? _relayController;
  InternetRelayController? _internetRelayController;
  SharedPreferencesInternetCursorStore? _internetCursorStore;
  RideSimulationController? _simulationController;
  InMemoryRouteStore? _simulationRouteStore;
  StreamSubscription<RideEvent>? _receivedEventSubscription;
  StreamSubscription<RideEvent>? _internetReceivedEventSubscription;
  Timer? _stalenessTimer;
  Timer? _simulationAwarenessTimer;
  Timer? _markerExitChromeTimer;
  Future<void> _publishChain = Future.value();
  String? _routeFingerprint;
  String? _simulationRouteFingerprint;
  route_domain.ImportedRoute? _activeRoute;
  int _routeGeneration = 0;
  int _selectedIndex = 0;
  int _handledAutomaticMarkerActivation = 0;
  int _handledAutomaticMarkerRideOffActivation = 0;
  DateTime? _lastSimulationNavigationUpdateAt;
  DateTime? _lastSimulationOverlayUpdateAt;
  bool _loading = true;
  bool _relayConfigured = false;
  bool _refreshingRideEvents = false;
  bool _rideEndHandled = false;
  bool _holdingNavigationChromeForMarkerExit = false;
  bool _autoEndingRide = false;
  bool _simulationPausedByRide = false;

  bool get _isSimulation => widget.rideController.session?.isSimulation == true;

  @override
  void initState() {
    super.initState();
    widget.rideController.addListener(_onRideControllerChanged);
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    route_domain.ImportedRoute? route;
    if (_isSimulation) {
      try {
        route = await const BundledDemoRouteLoader().load();
        _simulationRouteStore = InMemoryRouteStore(route);
        _warnings.add(
          'Ride Lab is isolated: device GPS, internet relay and nearby radios '
          'are disabled.',
        );
      } on Object catch (error) {
        _warnings.add('The simulation route could not be loaded: $error');
      }
    } else if (widget.enableNativeServices) {
      try {
        final routeStore = await JsonFileRouteStore.openDefault();
        route = await routeStore.loadActiveRoute();
      } on Object catch (error) {
        _warnings.add('Route storage could not be opened: $error');
      }
    }

    _activeRoute = route;
    await _replaceAwarenessController(route, notify: false);
    if (_isSimulation) {
      await _replaceSimulationController(route, notify: false);
    }
    if (!mounted) return;

    if (widget.enableNativeServices && !_isSimulation) {
      final session = widget.rideController.session;
      if (session?.role == RideRole.lead) {
        try {
          await widget.rideController.publishRideCode();
        } on RideCodeDirectoryException catch (error) {
          _warnings.add('Ride code is not ready yet: ${error.message}');
        }
      }
      _stalenessTimer = Timer.periodic(const Duration(seconds: 15), (_) {
        final awareness = _awarenessController;
        if (awareness != null) unawaited(awareness.refreshStaleness());
      });
      final locationController = ForegroundLocationController(
        DeviceLocationSource(),
        (sample) async {
          final awareness = _awarenessController;
          if (awareness != null) {
            await awareness.recordLocalLocation(sample);
          }
        },
      );
      _locationController = locationController;
      locationController.addListener(_onLocationSharingChanged);
      try {
        await locationController.initialize();
        _onLocationSharingChanged();
      } on Object catch (error) {
        _warnings.add('Location capability check failed: $error');
      }

      if (session != null) {
        final cursorStore = SharedPreferencesInternetCursorStore();
        _internetCursorStore = cursorStore;
        final internetRelayController = InternetRelayController(
          InternetRelayWorker(
            api: HttpInternetRelayClient(
              configuration: InternetRelayConfiguration.fromEnvironment(),
              client: http.Client(),
            ),
            eventStore: widget.eventStore,
            cursorStore: cursorStore,
          ),
        );
        _internetRelayController = internetRelayController;
        _internetReceivedEventSubscription = internetRelayController
            .receivedEvents
            .listen(_onReceivedEvent);
        await internetRelayController.start(session);
      }
      if (session != null && session.inviteSecret.length >= 16) {
        final relayController = NearbyRelayController(
          RelayEngine(
            transport: NativeNearbyTransport(),
            eventStore: widget.eventStore,
            queue: SqliteRelayQueue(),
          ),
        );
        _relayController = relayController;
        _receivedEventSubscription = relayController.receivedEvents.listen(
          _onReceivedEvent,
        );
        try {
          await relayController.start(session);
          _relayConfigured = true;
        } on Object catch (error) {
          _warnings.add('Nearby relay could not start: $error');
        }
      }
    }

    if (!mounted) return;
    if (widget.rideController.rideEnded) {
      await _handleRideEnded();
    }
    setState(() => _loading = false);
    _schedulePublish();
  }

  Future<void> _replaceAwarenessController(
    route_domain.ImportedRoute? route, {
    bool notify = true,
  }) async {
    final fingerprint = route == null
        ? 'none'
        : '${route.id}:${route.importedAt.toUtc().toIso8601String()}:'
              '${route.pathPointCount}';
    if (_awarenessController != null && fingerprint == _routeFingerprint) {
      return;
    }
    final generation = ++_routeGeneration;
    final session = widget.rideController.session;
    if (session == null) return;

    final routeSegments =
        route?.paths
            .where((path) => path.points.length >= 2)
            .map(
              (path) => path.points
                  .map(
                    (point) => awareness_geo.GeoPoint(
                      latitude: point.latitude,
                      longitude: point.longitude,
                    ),
                  )
                  .toList(growable: false),
            )
            .toList(growable: false) ??
        const <List<awareness_geo.GeoPoint>>[];
    // Synthetic position updates are intentionally ephemeral. Writing five
    // riders to SQLite throughout a Ride Lab run makes the durable event
    // history grow quickly, which in turn slows down the phone.
    final awarenessEventStore = _isSimulation
        ? InMemoryEventStore()
        : widget.eventStore;
    final controller = SituationalAwarenessController(
      awarenessEventStore,
      session,
      route: routeSegments.expand((segment) => segment).toList(growable: false),
      routeSegments: routeSegments,
      externalProviders: const [
        WazeReadHazardProvider(),
        UnconfiguredExternalHazardProvider(
          id: 'licensed-traffic-feed',
          displayName: 'Licensed traffic feed',
          configurationHint: 'No external traffic provider is configured.',
        ),
      ],
    );
    await controller.initialize();
    if (!mounted || generation != _routeGeneration) {
      controller.dispose();
      return;
    }

    final markerRoute = _markerRouteFor(route);
    final decisionPoints = const RouteDecisionPointExtractor().extract(
      route: markerRoute,
      explicitPoints:
          route?.waypoints
              .map(
                (waypoint) => ExplicitDecisionPoint(
                  position: awareness_geo.GeoPoint(
                    latitude: waypoint.point.latitude,
                    longitude: waypoint.point.longitude,
                  ),
                  label: waypoint.name,
                ),
              )
              .toList(growable: false) ??
          const [],
    );
    final markerController = MarkerAssistanceController(
      widget.rideController,
      controller,
      route: markerRoute,
      decisionPoints: decisionPoints,
    )..initialize();

    final previous = _awarenessController;
    final previousMarker = _markerAssistanceController;
    previous?.removeListener(_onAwarenessChanged);
    previousMarker?.dispose();
    _awarenessController = controller;
    _markerAssistanceController = markerController;
    _routeFingerprint = fingerprint;
    _riderTrails.clear();
    _offRouteTraces.value = const [];
    controller.addListener(_onAwarenessChanged);
    previous?.dispose();
    _updateMapOverlays();
    if (notify) setState(() {});
  }

  void _onRouteChanged(route_domain.ImportedRoute? route) {
    unawaited(_handleRouteChanged(route));
  }

  Future<void> _handleRouteChanged(route_domain.ImportedRoute? route) async {
    _activeRoute = route;
    await _replaceAwarenessController(route);
    if (_isSimulation) await _replaceSimulationController(route);
  }

  Future<void> _replaceSimulationController(
    route_domain.ImportedRoute? route, {
    bool notify = true,
  }) async {
    final fingerprint = route == null
        ? 'none'
        : '${route.id}:${route.importedAt.toUtc().toIso8601String()}:'
              '${route.pathPointCount}';
    if (_simulationController != null &&
        fingerprint == _simulationRouteFingerprint) {
      return;
    }
    final previous = _simulationController;
    _simulationController = null;
    _simulationRouteFingerprint = fingerprint;
    _handledAutomaticMarkerActivation = 0;
    _handledAutomaticMarkerRideOffActivation = 0;
    _junctionMarkerOverlay.value = null;
    _lastSimulationNavigationUpdateAt = null;
    previous?.removeListener(_onSimulationVisualChanged);
    previous?.dispose();

    final awareness = _awarenessController;
    final session = widget.rideController.session;
    final simulationRoute = _markerRouteFor(route);
    if (awareness == null ||
        session == null ||
        !session.isSimulation ||
        simulationRoute.length < 2) {
      if (notify && mounted) setState(() {});
      return;
    }
    final markerJunctions = await _simulationJunctions(route);
    final derivedJunctions = const RouteDecisionPointExtractor()
        .extract(route: simulationRoute)
        .map((point) => point.position)
        .toList(growable: false);

    final controller = RideSimulationController(
      awareness,
      session: session,
      route: simulationRoute,
      markerJunctions: markerJunctions,
      fallbackJunctions: derivedJunctions,
      riderCount: session.simulationRiderCount,
    );
    _simulationController = controller;
    controller.addListener(_onSimulationVisualChanged);
    await controller.initialize();
    if (!mounted || _simulationController != controller) {
      controller.dispose();
      return;
    }
    controller.start();
    _onSimulationVisualChanged();
    if (notify) setState(() {});
  }

  Future<List<awareness_geo.GeoPoint>> _simulationJunctions(
    route_domain.ImportedRoute? route,
  ) async {
    if (route?.sourceFileName == 'demo_route.gpx') {
      try {
        return (await const BundledDemoRouteLoader().loadManeuvers())
            .map(
              (maneuver) => awareness_geo.GeoPoint(
                latitude: maneuver.position.latitude,
                longitude: maneuver.position.longitude,
              ),
            )
            .toList(growable: false);
      } on FormatException {
        // Keep the demo usable if a local asset is damaged. GPX waypoints are
        // a less detailed but still valid fallback for the simulation.
      }
    }
    return route?.waypoints
            .map(
              (waypoint) => awareness_geo.GeoPoint(
                latitude: waypoint.point.latitude,
                longitude: waypoint.point.longitude,
              ),
            )
            .toList(growable: false) ??
        const <awareness_geo.GeoPoint>[];
  }

  void _onSimulationVisualChanged() {
    if (!mounted || !_isSimulation) return;
    final controller = _simulationController;
    _locationSharing.value = controller?.isRunning ?? false;
    if (controller != null) _updateJunctionMarkerOverlay(controller);
    if (controller != null &&
        controller.automaticMarkerActivation >
            _handledAutomaticMarkerActivation) {
      _handledAutomaticMarkerActivation = controller.automaticMarkerActivation;
      unawaited(_startAutomaticSimulationMarker(controller));
    }
    if (controller != null &&
        controller.automaticMarkerRideOffActivation >
            _handledAutomaticMarkerRideOffActivation) {
      _handledAutomaticMarkerRideOffActivation =
          controller.automaticMarkerRideOffActivation;
      unawaited(_finishAutomaticSimulationMarker(controller));
    }
    final now = DateTime.now();
    final updateNavigationPosition =
        _lastSimulationNavigationUpdateAt == null ||
        now.difference(_lastSimulationNavigationUpdateAt!) >=
            const Duration(milliseconds: 200);
    if (updateNavigationPosition) {
      _lastSimulationNavigationUpdateAt = now;
    }
    final updateOverlayMarkers =
        _lastSimulationOverlayUpdateAt == null ||
        now.difference(_lastSimulationOverlayUpdateAt!) >=
            const Duration(milliseconds: 250);
    if (updateOverlayMarkers) _lastSimulationOverlayUpdateAt = now;
    _updateMapOverlays(
      // The map status card is derived from the same authenticated synthetic
      // fixes as the overlays. Without this, a restarted leader view could
      // keep saying that Charlie's location was unavailable.
      updateDerivedState: updateOverlayMarkers,
      updateOverlayMarkers: updateOverlayMarkers,
      updateNavigationPosition: updateNavigationPosition,
    );
  }

  void _updateJunctionMarkerOverlay(RideSimulationController controller) {
    final hadOverlay = _junctionMarkerOverlay.value != null;
    // Junction guidance is an instruction for the rider holding the turn. The
    // rest of the group keeps their normal navigation view and never receives
    // the stationary marker camera transition.
    if (!controller.automaticMarkerActive ||
        !controller.automaticMarkerIsLocal) {
      if (hadOverlay) {
        _holdNavigationChromeAfterMarkerExit();
        _junctionMarkerOverlay.value = null;
        setState(() {});
      }
      return;
    }
    final marker = controller.riders
        .where((rider) => rider.role == RideRole.marker)
        .firstOrNull;
    if (marker == null) return;
    final stage = switch (controller.markerPhase) {
      SimulationMarkerPhase.tecApproaching =>
        MapJunctionMarkerStage.tecApproaching,
      SimulationMarkerPhase.readyToRideOff =>
        MapJunctionMarkerStage.readyToRideOff,
      _ => MapJunctionMarkerStage.waitingForRiders,
    };
    _junctionMarkerOverlay.value = MapJunctionMarkerOverlay(
      markerPoint: route_domain.GeoPoint(
        latitude: marker.position.latitude,
        longitude: marker.position.longitude,
      ),
      markerRiderName: controller.automaticMarkerIsLocal
          ? 'You'
          : (controller.automaticMarkerRiderName ?? 'Second bike'),
      isLocalMarker: controller.automaticMarkerIsLocal,
      ridersPassed: controller.ridersPassedMarker,
      ridersExpected: controller.ridersExpectedToPass,
      tecDistanceMeters: controller.tecDistanceToMarkerMeters,
      instruction: controller.markerInstruction,
      stage: stage,
    );
    if (!hadOverlay) setState(() {});
  }

  void _holdNavigationChromeAfterMarkerExit() {
    _markerExitChromeTimer?.cancel();
    _holdingNavigationChromeForMarkerExit = true;
    _markerExitChromeTimer = Timer(const Duration(milliseconds: 900), () {
      if (!mounted) return;
      setState(() => _holdingNavigationChromeForMarkerExit = false);
    });
  }

  void _onAwarenessChanged() {
    if (_isSimulation) {
      _scheduleSimulationAwarenessUpdate();
      return;
    }
    _updateMapOverlays();
    _schedulePublish();
    if (!_refreshingRideEvents) {
      _refreshingRideEvents = true;
      unawaited(() async {
        try {
          await widget.rideController.reloadEvents();
        } finally {
          _refreshingRideEvents = false;
        }
      }());
    }
  }

  void _scheduleSimulationAwarenessUpdate() {
    if (_simulationAwarenessTimer != null) return;
    _simulationAwarenessTimer = Timer(const Duration(milliseconds: 250), () {
      _simulationAwarenessTimer = null;
      if (!mounted) return;
      // Simulation awareness maintains its own in-memory location evidence.
      // Local marker actions update RideController directly, so reloading and
      // decoding the entire durable ride history here is unnecessary.
      _updateMapOverlays(
        updateDerivedState: true,
        updateNavigationPosition: false,
      );
    });
  }

  void _updateMapOverlays({
    bool updateDerivedState = true,
    bool updateOverlayMarkers = true,
    bool updateNavigationPosition = true,
  }) {
    final awareness = _awarenessController;
    if (awareness == null) return;
    final localLocation = awareness.localLocation;
    final simulatedRiders = _isSimulation
        ? _simulationController?.riders
        : null;
    final simulatedLocal = simulatedRiders
        ?.where((rider) => rider.isLocal)
        .firstOrNull;
    final mapPoint = simulatedLocal != null
        ? route_domain.GeoPoint(
            latitude: simulatedLocal.position.latitude,
            longitude: simulatedLocal.position.longitude,
          )
        : localLocation == null
        ? null
        : route_domain.GeoPoint(
            latitude: localLocation.sample.position.latitude,
            longitude: localLocation.sample.position.longitude,
            recordedAt: localLocation.sample.recordedAt,
          );
    final navigationRecordedAt = simulatedLocal == null
        ? localLocation?.sample.recordedAt
        : DateTime.now();
    if (updateNavigationPosition) {
      _mapNavigationPosition.value = mapPoint == null
          ? null
          : MapNavigationPosition(
              point: mapPoint,
              recordedAt: navigationRecordedAt!,
              speedMetersPerSecond:
                  simulatedLocal?.speedMetersPerSecond ??
                  localLocation!.sample.speedMetersPerSecond,
              headingDegrees:
                  simulatedLocal?.headingDegrees ??
                  localLocation!.sample.headingDegrees,
            );
      _mapPosition.value = mapPoint;
    }

    // A simulation can finish between throttled overlay frames. Completion
    // needs to inspect the final GPS fixes even when no later overlay frame is
    // scheduled to arrive.
    unawaited(_maybeAutomaticallyEndRide(awareness));
    if (!updateOverlayMarkers) return;
    if (_isSimulation) {
      _updateSimulationOffRouteTraces(simulatedRiders ?? const []);
    } else if (updateDerivedState) {
      _updateOffRouteTraces(awareness);
    }

    final overlays = <MapOverlayMarker>[
      ...awareness.activeHazards.map(
        (hazard) => MapOverlayMarker(
          id: 'hazard-${hazard.id}',
          point: route_domain.GeoPoint(
            latitude: hazard.position.latitude,
            longitude: hazard.position.longitude,
          ),
          label: '${hazard.type.label} · ${hazard.severity.label}',
          icon: Icons.warning_amber_rounded,
          color: _hazardColor(hazard.severity),
        ),
      ),
      ...(simulatedRiders == null
              ? awareness.riderLocations
                    .where(
                      (location) => location.riderId != localLocation?.riderId,
                    )
                    .map(
                      (location) => (
                        riderId: location.riderId,
                        displayName: location.displayName,
                        role: location.role,
                        point: route_domain.GeoPoint(
                          latitude: location.sample.position.latitude,
                          longitude: location.sample.position.longitude,
                          recordedAt: location.sample.recordedAt,
                        ),
                      ),
                    )
              : simulatedRiders
                    .where((rider) => !rider.isLocal)
                    .map(
                      (rider) => (
                        riderId: rider.id,
                        displayName: rider.displayName,
                        role: rider.role,
                        point: route_domain.GeoPoint(
                          latitude: rider.position.latitude,
                          longitude: rider.position.longitude,
                        ),
                      ),
                    ))
          .map((location) {
            final alert = awareness.alertFor(location.riderId);
            final needsAttention =
                alert != null &&
                alert.assessment.alertLevel.index >=
                    RouteAlertLevel.urgent.index;
            final isTec = location.role == RideRole.tailEndCharlie;
            final isLead = location.role == RideRole.lead;
            return MapOverlayMarker(
              id: 'rider-${location.riderId}',
              point: location.point,
              label: needsAttention
                  ? '${location.displayName} · check route'
                  : isTec
                  ? '${location.displayName} · TEC'
                  : isLead
                  ? '${location.displayName} · Lead'
                  : location.displayName,
              icon: isTec
                  ? Icons.shield_outlined
                  : isLead
                  ? Icons.flag_rounded
                  : Icons.two_wheeler,
              color: needsAttention
                  ? const Color(0xFFFF5D73)
                  : isTec
                  ? const Color(0xFF68A9FF)
                  : isLead
                  ? const Color(0xFFB58CFF)
                  : const Color(0xFF6ED89A),
            );
          }),
    ];
    _mapOverlays.value = List.unmodifiable(overlays);
    if (updateDerivedState) {
      final session = widget.rideController.session;
      _leaderStatus.value = session == null
          ? null
          : const LeaderRideStatusCalculator().calculate(
              localRole: session.role,
              localRiderId: session.localRiderId,
              localLocation: localLocation,
              riderLocations: awareness.riderLocations,
              routeAlerts: awareness.routeAlerts,
              route: awareness.route,
            );
    }
  }

  Future<void> _maybeAutomaticallyEndRide(
    SituationalAwarenessController awareness,
  ) async {
    if (_autoEndingRide ||
        widget.rideController.rideEnded ||
        widget.rideController.ridePaused ||
        widget.rideController.markerActive) {
      return;
    }
    final session = widget.rideController.session;
    // A real ride remains leader-owned. Ride Lab drives the entire virtual
    // group locally, so completion must work from its leader, follower and TEC
    // perspectives alike.
    if (session == null || (!_isSimulation && session.role != RideRole.lead)) {
      return;
    }
    final route = _activeRoute;
    final destination = _routeDestination(route);
    if (destination == null) return;
    final arrived = _rideCompletionDetector.everyoneReachedDestination(
      destination: awareness_geo.GeoPoint(
        latitude: destination.latitude,
        longitude: destination.longitude,
      ),
      riderLocations: awareness.riderLocations,
      now: DateTime.now(),
    );
    if (!arrived) return;
    _autoEndingRide = true;
    try {
      await widget.rideController.endRide();
    } catch (error, stackTrace) {
      if (kDebugMode) {
        debugPrint('Could not automatically end ride: $error\n$stackTrace');
      }
    } finally {
      _autoEndingRide = false;
    }
  }

  static route_domain.GeoPoint? _routeDestination(
    route_domain.ImportedRoute? route,
  ) {
    if (route == null) return null;
    for (final path in route.paths.reversed) {
      if (path.points.isNotEmpty) return path.points.last;
    }
    return route.waypoints.isEmpty ? null : route.waypoints.last.point;
  }

  void _updateSimulationOffRouteTraces(List<SimulatedRiderSnapshot> riders) {
    final traces = <MapOverlayTrace>[];
    final leader = riders
        .where((rider) => rider.role == RideRole.lead)
        .firstOrNull;
    if (leader != null && leader.travelTrail.length >= 2) {
      traces.add(
        MapOverlayTrace(
          id: 'leader-track-${leader.id}',
          points: leader.travelTrail
              .map(
                (point) => route_domain.GeoPoint(
                  latitude: point.latitude,
                  longitude: point.longitude,
                ),
              )
              .toList(growable: false),
          label: '${leader.displayName} leader track',
          color: const Color(0xFFB58CFF),
        ),
      );
    }
    traces.addAll(
      riders
          .where((rider) => rider.isOffRoute && rider.offRouteTrail.length >= 2)
          .map(
            (rider) => MapOverlayTrace(
              id: 'off-route-${rider.id}',
              points: rider.offRouteTrail
                  .map(
                    (point) => route_domain.GeoPoint(
                      latitude: point.latitude,
                      longitude: point.longitude,
                    ),
                  )
                  .toList(growable: false),
              label: '${rider.displayName} off-route trace',
            ),
          ),
    );
    _offRouteTraces.value = List.unmodifiable(traces);
  }

  void _updateOffRouteTraces(SituationalAwarenessController awareness) {
    final alerts = {
      for (final alert in awareness.routeAlerts) alert.riderId: alert,
    };
    final traces = <MapOverlayTrace>[];
    for (final location in awareness.riderLocations) {
      final point = route_domain.GeoPoint(
        latitude: location.sample.position.latitude,
        longitude: location.sample.position.longitude,
        recordedAt: location.sample.recordedAt,
      );
      final trail = _riderTrails.putIfAbsent(location.riderId, () => []);
      if (trail.isEmpty || _trailPointChanged(trail.last, point)) {
        trail.add(point);
        if (trail.length > 120) trail.removeRange(0, trail.length - 120);
      }
      final state = alerts[location.riderId]?.assessment.state;
      final isOffRoute =
          state == RouteTrackingState.suspectedOffRoute ||
          state == RouteTrackingState.offRoute ||
          state == RouteTrackingState.recovering;
      if (isOffRoute && trail.length >= 2) {
        traces.add(
          MapOverlayTrace(
            id: 'off-route-${location.riderId}',
            points: List.unmodifiable(trail),
            label: '${location.displayName} off-route trace',
          ),
        );
      }
    }
    _offRouteTraces.value = List.unmodifiable(traces);
  }

  static bool _trailPointChanged(
    route_domain.GeoPoint first,
    route_domain.GeoPoint second,
  ) =>
      (first.latitude - second.latitude).abs() > 1e-7 ||
      (first.longitude - second.longitude).abs() > 1e-7;

  static Color _hazardColor(HazardSeverity severity) => switch (severity) {
    HazardSeverity.advisory => const Color(0xFF8EA7C4),
    HazardSeverity.caution => const Color(0xFFFFC857),
    HazardSeverity.serious => const Color(0xFFFF8A4C),
    HazardSeverity.critical => const Color(0xFFFF5D73),
  };

  static List<awareness_geo.GeoPoint> _markerRouteFor(
    route_domain.ImportedRoute? route,
  ) {
    if (route == null || route.paths.isEmpty) return const [];
    final longestPath = route.paths.reduce(
      (current, candidate) =>
          candidate.points.length > current.points.length ? candidate : current,
    );
    return longestPath.points
        .map(
          (point) => awareness_geo.GeoPoint(
            latitude: point.latitude,
            longitude: point.longitude,
          ),
        )
        .toList(growable: false);
  }

  Future<void> _onReceivedEvent(RideEvent event) async {
    if (_isSituationalEvent(event.type)) {
      try {
        await _awarenessController?.ingestRemoteEvent(event);
      } on Object catch (error, stackTrace) {
        if (kDebugMode) {
          debugPrint(
            'Rejected received situational event: $error\n$stackTrace',
          );
        }
      }
    }
    await widget.rideController.reloadEvents();
  }

  static bool _isSituationalEvent(RideEventType type) => switch (type) {
    RideEventType.riderLocationUpdated ||
    RideEventType.hazardReported ||
    RideEventType.hazardCleared ||
    RideEventType.routeDeviationChanged ||
    RideEventType.routeAlertAcknowledged => true,
    _ => false,
  };

  void _onRideControllerChanged() {
    final session = widget.rideController.session;
    if (session != null) {
      _awarenessController?.updateLocalSession(session);
      _updateMapOverlays();
    }
    _applyRidePauseState();
    if (widget.rideController.rideEnded && !_rideEndHandled) {
      unawaited(_handleRideEnded());
    }
    _schedulePublish();
  }

  void _applyRidePauseState() {
    if (!_isSimulation) return;
    final simulation = _simulationController;
    if (simulation == null) return;
    if (widget.rideController.ridePaused) {
      if (simulation.isRunning) {
        simulation.pause();
        _simulationPausedByRide = true;
      }
      return;
    }
    if (_simulationPausedByRide) {
      _simulationPausedByRide = false;
      simulation.start();
    }
  }

  Future<void> _handleRideEnded() async {
    if (_rideEndHandled) return;
    _rideEndHandled = true;
    _stalenessTimer?.cancel();
    _simulationAwarenessTimer?.cancel();
    _stalenessTimer = null;
    await _locationController?.stop();
  }

  void _schedulePublish() {
    final previous = _publishChain;
    _publishChain = () async {
      try {
        await previous;
      } on Object {
        // A later event must still be allowed to enter the durable queue.
      }
      await _publishPendingEvents();
    }();
  }

  Future<void> _publishPendingEvents() async {
    _internetRelayController?.wake();
    final relay = _relayController;
    final session = widget.rideController.session;
    if (!_relayConfigured || relay == null || session == null) return;
    final events = await eventsEligibleForNearbyRelay(
      widget.eventStore,
      session.rideId,
    );
    for (final event in events) {
      if (_publishedEventIds.contains(event.id)) continue;
      try {
        await relay.publish(event);
        _publishedEventIds.add(event.id);
      } on Object catch (error) {
        if (kDebugMode) {
          debugPrint('Could not queue ${event.id} for nearby relay: $error');
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.rideController.rideEnded) {
      return EndedRideScreen(
        controller: widget.rideController,
        nearbyRelayController: _relayController,
        internetRelayController: _internetRelayController,
        onRemoveRide: _removeEndedRide,
      );
    }
    final body = _isSimulation
        ? switch (_selectedIndex) {
            0 => _buildMap(),
            1 => _buildSimulation(),
            2 => _buildDetails(),
            _ => _buildAwareness(),
          }
        : switch (_selectedIndex) {
            0 => _buildMap(),
            1 => _buildDetails(),
            _ => _buildAwareness(),
          };

    return ValueListenableBuilder<MapNavigationPosition?>(
      valueListenable: _mapNavigationPosition,
      builder: (context, navigationPosition, _) {
        final landscape =
            MediaQuery.orientationOf(context) == Orientation.landscape;
        // The native map flashes when a bottom bar is repeatedly inserted as
        // GPS speed dips at lights. Once there is a navigation fix, preserve
        // the map viewport until the rider deliberately leaves the map tab.
        final hideWhileMoving =
            _selectedIndex == 0 &&
            _activeRoute != null &&
            (navigationPosition != null ||
                _junctionMarkerOverlay.value != null ||
                _holdingNavigationChromeForMarkerExit);
        final destinations = <NavigationDestination>[
          const NavigationDestination(
            icon: Icon(Icons.map_outlined),
            selectedIcon: Icon(Icons.map),
            label: 'Map',
          ),
          if (_isSimulation)
            const NavigationDestination(
              icon: Icon(Icons.science_outlined),
              selectedIcon: Icon(Icons.science),
              label: 'Ride Lab',
            ),
          const NavigationDestination(
            icon: Icon(Icons.tune_outlined),
            selectedIcon: Icon(Icons.tune),
            label: 'Details',
          ),
          const NavigationDestination(
            icon: Icon(Icons.health_and_safety_outlined),
            selectedIcon: Icon(Icons.health_and_safety),
            label: 'Safety',
          ),
        ];
        if (landscape && !hideWhileMoving) {
          return Scaffold(
            body: Row(
              children: [
                SafeArea(
                  right: false,
                  child: NavigationRail(
                    key: const Key('landscape-navigation-rail'),
                    minWidth: 56,
                    groupAlignment: -0.7,
                    labelType: NavigationRailLabelType.none,
                    selectedIndex: _selectedIndex,
                    onDestinationSelected: (index) =>
                        setState(() => _selectedIndex = index),
                    destinations: [
                      for (final destination in destinations)
                        NavigationRailDestination(
                          icon: destination.icon,
                          selectedIcon: destination.selectedIcon,
                          label: Text(destination.label),
                        ),
                    ],
                  ),
                ),
                const VerticalDivider(width: 1),
                Expanded(child: body),
              ],
            ),
          );
        }
        return Scaffold(
          body: body,
          bottomNavigationBar: hideWhileMoving
              ? null
              : NavigationBar(
                  height: landscape ? 48 : 56,
                  labelBehavior: NavigationDestinationLabelBehavior.alwaysHide,
                  selectedIndex: _selectedIndex,
                  onDestinationSelected: (index) =>
                      setState(() => _selectedIndex = index),
                  destinations: destinations,
                ),
        );
      },
    );
  }

  Widget _buildMap() {
    if (_isSimulation && (_loading || _simulationRouteStore == null)) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!widget.enableNativeServices && !_isSimulation) {
      return Scaffold(
        appBar: AppBar(title: const Text('Navigation')),
        body: const Center(child: Text('Navigation map')),
      );
    }
    return RideMapFeature.fromEnvironment(
      currentPosition: _mapPosition,
      navigationPosition: _mapNavigationPosition,
      overlayMarkers: _mapOverlays,
      offRouteTraces: _offRouteTraces,
      leaderStatus: _leaderStatus,
      junctionMarkerOverlay: _junctionMarkerOverlay,
      emergencyContacts: _emergencyContacts,
      onEmergencyAlert: _sendEmergencyMapAlert,
      onEmergencyIssue: _sendEmergencyMapIssue,
      ridePaused: widget.rideController.ridePaused,
      canToggleRidePause:
          !_isSimulation &&
          widget.rideController.session?.role == RideRole.lead,
      onToggleRidePause: _toggleRidePause,
      locationSharing: _locationSharing,
      onToggleLocationSharing: _toggleMapLocationSharing,
      onLeaveRide: _confirmLeaveRideFromMap,
      canEndRide: widget.rideController.session?.role == RideRole.lead,
      onEndRide: _confirmEndRideFromMap,
      onOpenRideMenu: _openRideMenu,
      onRouteChanged: _onRouteChanged,
      acquireCurrentPosition: _isSimulation
          ? () async => _mapPosition.value
          : _acquireCurrentPosition,
      routeStore: _simulationRouteStore,
      distanceUnit: widget.distanceUnits.value,
    );
  }

  List<MapEmergencyContact> get _emergencyContacts {
    final contacts = <String, MapEmergencyContact>{};
    final session = widget.rideController.session;
    if (session != null &&
        (session.role == RideRole.lead ||
            session.role == RideRole.tailEndCharlie)) {
      contacts[session.localRiderId] = MapEmergencyContact(
        riderId: session.localRiderId,
        displayName: session.displayName,
        role: session.role,
      );
    }
    for (final rider in _awarenessController?.riderLocations ?? const []) {
      if (rider.role != RideRole.lead &&
          rider.role != RideRole.tailEndCharlie) {
        continue;
      }
      contacts[rider.riderId] = MapEmergencyContact(
        riderId: rider.riderId,
        displayName: rider.displayName,
        role: rider.role,
      );
    }
    return contacts.values.toList(growable: false);
  }

  Future<void> _sendEmergencyMapAlert() =>
      _sendEmergencyQuickMessage(QuickMessage.emergencyStop);

  Future<void> _sendEmergencyMapIssue(QuickMessage message) =>
      _sendEmergencyQuickMessage(message);

  Future<void> _sendEmergencyQuickMessage(QuickMessage message) async {
    final session = widget.rideController.session;
    final recipients = _emergencyContacts
        .where((contact) => contact.riderId != session?.localRiderId)
        .map((contact) => contact.riderId)
        .toList(growable: false);
    await widget.rideController.sendQuickMessage(
      message,
      recipientRiderIds: recipients,
    );
  }

  Future<void> _toggleRidePause() async {
    if (widget.rideController.ridePaused) {
      await widget.rideController.resumeRide();
    } else {
      await widget.rideController.pauseRide();
    }
  }

  void _onLocationSharingChanged() {
    _locationSharing.value = _locationController?.sharing ?? false;
  }

  Future<void> _toggleMapLocationSharing() async {
    if (_isSimulation) {
      final simulation = _simulationController;
      if (simulation == null ||
          simulation.state == RideSimulationState.completed) {
        return;
      }
      if (simulation.isRunning) {
        simulation.pause();
      } else {
        simulation.start();
      }
      _locationSharing.value = simulation.isRunning;
      return;
    }
    final locationController = _locationController;
    if (locationController == null) return;
    if (locationController.sharing) {
      await locationController.stop();
    } else {
      await locationController.requestAndStart();
    }
    _onLocationSharingChanged();
  }

  Future<void> _confirmLeaveRideFromMap() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Leave this ride?'),
        content: const Text(
          'Your location sharing will stop on this phone. The group ride will '
          'continue for everyone else.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Leave ride'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) await _leaveRide();
  }

  Future<void> _confirmEndRideFromMap() async {
    if (widget.rideController.session?.role != RideRole.lead) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('End this ride?'),
        content: const Text(
          'This ends the group ride for everyone. Location sharing stops, '
          'but relay recovery remains available for final queued events.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('End ride'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      await widget.rideController.endRide();
    }
  }

  Future<void> _openRideMenu() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => _RideNavigationMenu(
        simulation: _isSimulation,
        selectedIndex: _selectedIndex,
        onSelected: (index) {
          Navigator.of(context).pop();
          if (mounted) setState(() => _selectedIndex = index);
        },
      ),
    );
  }

  Widget _buildSimulation() {
    final controller = _simulationController;
    if (_loading || controller == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return RideSimulationScreen(
      controller: controller,
      distanceUnit: widget.distanceUnits.value,
      onRestart: _restartSimulation,
      onExit: _leaveRide,
      onRoleChanged: _setSimulationRole,
      onToggleMarker: _toggleSimulationMarker,
      onRideOff: _rideOffSimulationMarker,
      onRiderCountChanged: _restartSimulationWithRiderCount,
      markerPassCount: widget.rideController.markerPassCount,
      tecPassedMarker: widget.rideController.tecPassedCurrentMarker,
    );
  }

  Future<void> _setSimulationRole(RideRole role) async {
    final controller = _simulationController;
    if (controller == null || controller.markerMode) return;
    controller.setLocalRole(role);
    await widget.rideController.setRole(role);
  }

  Future<void> _toggleSimulationMarker() async {
    final controller = _simulationController;
    if (controller == null || controller.automaticMarkerActive) return;
    if (controller.markerMode) {
      await widget.rideController.endMarker();
      controller.setMarkerMode(false);
      final restoredRole = widget.rideController.session?.role;
      if (restoredRole != null && restoredRole != RideRole.marker) {
        controller.setLocalRole(restoredRole);
      }
      return;
    }
    await widget.rideController.startMarker(mode: 'simulation');
    controller.setMarkerMode(true);
  }

  Future<void> _startAutomaticSimulationMarker(
    RideSimulationController controller,
  ) async {
    if (!mounted ||
        _simulationController != controller ||
        !controller.automaticMarkerActive) {
      return;
    }
    if (controller.automaticMarkerIsLocal &&
        !widget.rideController.markerActive) {
      await widget.rideController.startMarker(mode: 'simulation-auto-junction');
      if (mounted &&
          _simulationController == controller &&
          !controller.markerMode &&
          widget.rideController.markerActive) {
        await widget.rideController.endMarker();
      }
    }
  }

  Future<void> _finishAutomaticSimulationMarker(
    RideSimulationController controller,
  ) async {
    if (!mounted || _simulationController != controller) return;
    if (controller.lastAutomaticMarkerRideOffWasLocal &&
        widget.rideController.markerActive) {
      await widget.rideController.endMarker();
    }
  }

  Future<void> _rideOffSimulationMarker() async {
    final controller = _simulationController;
    if (controller == null || !controller.canRideOff) return;
    if (controller.automaticMarkerIsLocal &&
        widget.rideController.markerActive) {
      await widget.rideController.endMarker();
    }
    controller.rideOff();
    if (mounted) setState(() => _selectedIndex = 0);
  }

  Future<void> _restartSimulation() async {
    _simulationController?.pause();
    await widget.rideController.restartSimulationRide();
  }

  Future<void> _restartSimulationWithRiderCount(int riderCount) async {
    final simulation = _simulationController;
    if (simulation == null || riderCount == simulation.riderCount) return;
    simulation.pause();
    await widget.rideController.restartSimulationRide(riderCount: riderCount);
  }

  Widget _buildDetails() => RideDashboard(
    controller: widget.rideController,
    distanceUnits: widget.distanceUnits,
    onLeaveRide: _leaveRide,
    relayController: _relayController,
    markerAssistanceController: _markerAssistanceController,
    internetRelayController: _internetRelayController,
    serviceWarning: _warnings.isEmpty ? null : _warnings.join('\n'),
  );

  Future<route_domain.GeoPoint?> _acquireCurrentPosition() async {
    final existing = _mapPosition.value;
    if (existing != null) return existing;
    final locationController = _locationController;
    if (locationController == null) return null;

    final completer = Completer<route_domain.GeoPoint?>();
    void onPosition() {
      final position = _mapPosition.value;
      if (position != null && !completer.isCompleted) {
        completer.complete(position);
      }
    }

    _mapPosition.addListener(onPosition);
    try {
      await locationController.requestAndStart();
      onPosition();
      if (!locationController.status.canSample && !completer.isCompleted) {
        return null;
      }
      return await completer.future.timeout(
        const Duration(seconds: 12),
        onTimeout: () => _mapPosition.value,
      );
    } finally {
      _mapPosition.removeListener(onPosition);
    }
  }

  Widget _buildAwareness() {
    final awareness = _awarenessController;
    if (_loading || awareness == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return SituationalAwarenessScreen(
      controller: awareness,
      locationController: widget.enableNativeServices && !_isSimulation
          ? _locationController
          : null,
    );
  }

  Future<void> _removeEndedRide() async {
    final rideId = widget.rideController.session?.rideId;
    if (rideId != null) await _internetCursorStore?.clear(rideId);
    await widget.rideController.clearEndedRide();
  }

  Future<void> _leaveRide() async {
    _simulationController?.pause();
    final rideId = widget.rideController.session?.rideId;
    if (rideId != null) await _internetCursorStore?.clear(rideId);
    await widget.rideController.leaveRide();
  }

  @override
  void dispose() {
    widget.rideController.removeListener(_onRideControllerChanged);
    _simulationController?.removeListener(_onSimulationVisualChanged);
    _simulationController?.dispose();
    _awarenessController?.removeListener(_onAwarenessChanged);
    _markerAssistanceController?.dispose();
    _awarenessController?.dispose();
    unawaited(_receivedEventSubscription?.cancel());
    unawaited(_internetReceivedEventSubscription?.cancel());
    _stalenessTimer?.cancel();
    _markerExitChromeTimer?.cancel();
    _locationController?.removeListener(_onLocationSharingChanged);
    _locationController?.dispose();
    unawaited(_relayController?.close());
    unawaited(_internetRelayController?.close());
    _mapPosition.dispose();
    _mapNavigationPosition.dispose();
    _mapOverlays.dispose();
    _offRouteTraces.dispose();
    _leaderStatus.dispose();
    _junctionMarkerOverlay.dispose();
    _locationSharing.dispose();
    super.dispose();
  }
}
