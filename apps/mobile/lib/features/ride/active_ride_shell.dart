import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../controllers/foreground_location_controller.dart';
import '../../controllers/internet_relay_controller.dart';
import '../../controllers/marker_assistance_controller.dart';
import '../../controllers/nearby_relay_controller.dart';
import '../../controllers/ride_controller.dart';
import '../../controllers/situational_awareness_controller.dart';
import '../../data/json_file_route_store.dart';
import '../../domain/event_store.dart';
import '../../domain/geo_point.dart' as awareness_geo;
import '../../domain/hazard.dart';
import '../../domain/imported_route.dart' as route_domain;
import '../../domain/ride_event.dart';
import '../../domain/route_alert.dart';
import '../../internet/internet_relay_client.dart';
import '../../internet/internet_relay_worker.dart';
import '../../internet/shared_preferences_internet_cursor_store.dart';
import '../../relay/native_nearby_transport.dart';
import '../../relay/nearby_event_source.dart';
import '../../relay/relay_engine.dart';
import '../../relay/sqlite_relay_queue.dart';
import '../../services/device_location_source.dart';
import '../../services/external_hazard_provider.dart';
import '../../services/route_decision_point_extractor.dart';
import '../map/ride_map.dart';
import '../situational_awareness/situational_awareness_screen.dart';
import 'ride_dashboard.dart';

/// Owns the active-ride feature lifecycle and keeps each feature independently
/// testable. Native permissions are requested only by the installed app, not by
/// widget tests that construct [RideRelayApp].
class ActiveRideShell extends StatefulWidget {
  const ActiveRideShell({
    super.key,
    required this.rideController,
    required this.eventStore,
    required this.enableNativeServices,
  });

  final RideController rideController;
  final EventStore eventStore;
  final bool enableNativeServices;

  @override
  State<ActiveRideShell> createState() => _ActiveRideShellState();
}

class _ActiveRideShellState extends State<ActiveRideShell> {
  final _mapPosition = ValueNotifier<route_domain.GeoPoint?>(null);
  final _mapOverlays = ValueNotifier<List<MapOverlayMarker>>(const []);
  final _publishedEventIds = <String>{};
  final _warnings = <String>{};

  SituationalAwarenessController? _awarenessController;
  ForegroundLocationController? _locationController;
  MarkerAssistanceController? _markerAssistanceController;
  NearbyRelayController? _relayController;
  InternetRelayController? _internetRelayController;
  StreamSubscription<RideEvent>? _receivedEventSubscription;
  StreamSubscription<RideEvent>? _internetReceivedEventSubscription;
  Future<void> _publishChain = Future.value();
  String? _routeFingerprint;
  int _routeGeneration = 0;
  int _selectedIndex = 0;
  bool _loading = true;
  bool _relayConfigured = false;
  bool _refreshingRideEvents = false;

  @override
  void initState() {
    super.initState();
    widget.rideController.addListener(_onRideControllerChanged);
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    route_domain.ImportedRoute? route;
    if (widget.enableNativeServices) {
      try {
        final routeStore = await JsonFileRouteStore.openDefault();
        route = await routeStore.loadActiveRoute();
      } on Object catch (error) {
        _warnings.add('Route storage could not be opened: $error');
      }
    }

    await _replaceAwarenessController(route, notify: false);
    if (!mounted) return;

    if (widget.enableNativeServices) {
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
      try {
        await locationController.initialize();
      } on Object catch (error) {
        _warnings.add('Location capability check failed: $error');
      }

      final session = widget.rideController.session;
      if (session != null) {
        final internetRelayController = InternetRelayController(
          InternetRelayWorker(
            api: HttpInternetRelayClient(
              configuration: InternetRelayConfiguration.fromEnvironment(),
              client: http.Client(),
            ),
            eventStore: widget.eventStore,
            cursorStore: SharedPreferencesInternetCursorStore(),
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
      } else {
        _warnings.add(
          'Nearby relay needs an authenticated QR/deep-link invitation; a '
          'manually entered ride code cannot establish the shared secret.',
        );
      }
    }

    if (!mounted) return;
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

    final controller = SituationalAwarenessController(
      widget.eventStore,
      session,
      route:
          route?.allPoints
              .map(
                (point) => awareness_geo.GeoPoint(
                  latitude: point.latitude,
                  longitude: point.longitude,
                ),
              )
              .toList(growable: false) ??
          const [],
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
    controller.addListener(_onAwarenessChanged);
    previous?.dispose();
    _updateMapOverlays();
    if (notify) setState(() {});
  }

  void _onRouteChanged(route_domain.ImportedRoute? route) {
    unawaited(_replaceAwarenessController(route));
  }

  void _onAwarenessChanged() {
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

  void _updateMapOverlays() {
    final awareness = _awarenessController;
    if (awareness == null) return;
    final localLocation = awareness.localLocation;
    _mapPosition.value = localLocation == null
        ? null
        : route_domain.GeoPoint(
            latitude: localLocation.sample.position.latitude,
            longitude: localLocation.sample.position.longitude,
            recordedAt: localLocation.sample.recordedAt,
          );

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
      ...awareness.riderLocations
          .where((location) => location.riderId != localLocation?.riderId)
          .map((location) {
            final alert = awareness.alertFor(location.riderId);
            final needsAttention =
                alert != null &&
                alert.assessment.alertLevel.index >=
                    RouteAlertLevel.urgent.index;
            return MapOverlayMarker(
              id: 'rider-${location.riderId}',
              point: route_domain.GeoPoint(
                latitude: location.sample.position.latitude,
                longitude: location.sample.position.longitude,
                recordedAt: location.sample.recordedAt,
              ),
              label: needsAttention
                  ? '${location.displayName} · check route'
                  : location.displayName,
              icon: Icons.two_wheeler,
              color: needsAttention
                  ? const Color(0xFFFF5D73)
                  : const Color(0xFF6ED89A),
            );
          }),
    ];
    _mapOverlays.value = List.unmodifiable(overlays);
  }

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
        debugPrint('Rejected received situational event: $error\n$stackTrace');
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

  void _onRideControllerChanged() => _schedulePublish();

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
        debugPrint('Could not queue ${event.id} for nearby relay: $error');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final body = switch (_selectedIndex) {
      0 => RideDashboard(
        controller: widget.rideController,
        relayController: _relayController,
        markerAssistanceController: _markerAssistanceController,
        internetRelayController: _internetRelayController,
        serviceWarning: _warnings.isEmpty ? null : _warnings.join('\n'),
      ),
      1 => RideMapFeature.fromEnvironment(
        currentPosition: _mapPosition,
        overlayMarkers: _mapOverlays,
        onRouteChanged: _onRouteChanged,
      ),
      _ => _buildAwareness(),
    };

    return Scaffold(
      body: body,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (index) =>
            setState(() => _selectedIndex = index),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.groups_outlined),
            selectedIcon: Icon(Icons.groups),
            label: 'Ride',
          ),
          NavigationDestination(
            icon: Icon(Icons.map_outlined),
            selectedIcon: Icon(Icons.map),
            label: 'Map',
          ),
          NavigationDestination(
            icon: Icon(Icons.health_and_safety_outlined),
            selectedIcon: Icon(Icons.health_and_safety),
            label: 'Awareness',
          ),
        ],
      ),
    );
  }

  Widget _buildAwareness() {
    final awareness = _awarenessController;
    if (_loading || awareness == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return SituationalAwarenessScreen(
      controller: awareness,
      locationController: widget.enableNativeServices
          ? _locationController
          : null,
    );
  }

  @override
  void dispose() {
    widget.rideController.removeListener(_onRideControllerChanged);
    _awarenessController?.removeListener(_onAwarenessChanged);
    _markerAssistanceController?.dispose();
    _awarenessController?.dispose();
    unawaited(_receivedEventSubscription?.cancel());
    unawaited(_internetReceivedEventSubscription?.cancel());
    _locationController?.dispose();
    unawaited(_relayController?.close());
    unawaited(_internetRelayController?.close());
    _mapPosition.dispose();
    _mapOverlays.dispose();
    super.dispose();
  }
}
