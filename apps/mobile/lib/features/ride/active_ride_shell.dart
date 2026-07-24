import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../controllers/distance_unit_controller.dart';
import '../../controllers/foreground_location_controller.dart';
import '../../controllers/internet_relay_controller.dart';
import '../../controllers/map_style_mode_controller.dart';
import '../../controllers/marker_assistance_controller.dart';
import '../../controllers/nearby_relay_controller.dart';
import '../../controllers/pre_start_presence_controller.dart';
import '../../controllers/ride_controller.dart';
import '../../controllers/ride_push_notification_controller.dart';
import '../../controllers/ride_simulation_controller.dart';
import '../../controllers/rider_profile_controller.dart';
import '../../controllers/shared_route_controller.dart';
import '../../controllers/speed_limit_display_controller.dart';
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
import '../../domain/rider_location.dart';
import '../../domain/rider_color.dart';
import '../../domain/route_alert.dart';
import '../../domain/route_store.dart';
import '../../internet/internet_relay_client.dart';
import '../../internet/internet_relay_worker.dart';
import '../../internet/push_registration_client.dart';
import '../../internet/shared_preferences_internet_cursor_store.dart';
import '../../relay/native_nearby_transport.dart';
import '../../relay/nearby_event_source.dart';
import '../../relay/relay_engine.dart';
import '../../relay/sqlite_relay_queue.dart';
import '../../services/device_location_source.dart';
import '../../services/carplay_bridge.dart';
import '../../services/demo_route_loader.dart';
import '../../services/external_hazard_provider.dart';
import '../../services/gpx_import_source.dart';
import '../../services/leader_ride_status.dart';
import '../../services/native_push_token_source.dart';
import '../../services/route_decision_point_extractor.dart';
import '../../services/ride_completion_detector.dart';
import '../../services/ride_membership.dart';
import '../../services/ride_screen_awake.dart';
import '../map/motorcycle_icon.dart';
import '../map/ride_map.dart';
import '../settings/emergency_info_sheet.dart';
import '../settings/notification_preferences_sheet.dart';
import 'ice_share_inbox_sheet.dart';
import '../situational_awareness/situational_awareness_screen.dart';
import '../simulation/ride_simulation_screen.dart';
import 'ended_ride_screen.dart';
import 'ride_dashboard.dart';
import 'ride_roster_sheet.dart';

/// Owns the active-ride feature lifecycle and keeps each feature independently
/// testable. Native permissions are requested only by the installed app, not by
/// widget tests that construct [RideRelayApp].
class ActiveRideShell extends StatefulWidget {
  const ActiveRideShell({
    super.key,
    required this.rideController,
    required this.distanceUnits,
    required this.mapStyleMode,
    required this.eventStore,
    required this.enableNativeServices,
    required this.riderProfile,
    required this.sharedRoutes,
    required this.speedLimitDisplay,
    this.screenWakeLock = const WakelockPlusScreenWakeLock(),
    this.screenWakeReassertInterval = const Duration(seconds: 15),
    this.pushTokenSource,
    this.pushRegistrationApi,
  });

  final RideController rideController;
  final DistanceUnitController distanceUnits;
  final MapStyleModeController mapStyleMode;
  final EventStore eventStore;
  final bool enableNativeServices;
  final RiderProfileController riderProfile;
  final SharedRouteController sharedRoutes;
  final SpeedLimitDisplayController speedLimitDisplay;
  final ScreenWakeLock screenWakeLock;
  final Duration screenWakeReassertInterval;
  final PushTokenSource? pushTokenSource;
  final PushRegistrationApi? pushRegistrationApi;

  @override
  State<ActiveRideShell> createState() => _ActiveRideShellState();
}

/// Prevents an active ride from mounting the map against its legacy global
/// fallback while the ride-scoped route store is still opening.
///
/// Returning only the store for the current ride type also ensures a genuinely
/// new ride cannot inherit another ride's selected route.
@visibleForTesting
RouteStore? activeRideMapStoreWhenReady({
  required bool initializing,
  required bool isSimulation,
  required RouteStore? rideRouteStore,
  required RouteStore? simulationRouteStore,
}) {
  if (initializing) return null;
  return isSimulation ? simulationRouteStore : rideRouteStore;
}

/// Compact, always-available navigation for the full-screen map canvas.
class _RideNavigationMenu extends StatelessWidget {
  const _RideNavigationMenu({
    required this.simulation,
    required this.selectedIndex,
    required this.onSelected,
    required this.canChangeRoute,
    required this.onOpenRoster,
    required this.onShareRoster,
    required this.onChangeRoute,
    required this.onEmergencyInfo,
    required this.onNotifications,
    required this.canShareIceInfo,
    required this.onShareIceInfo,
    required this.receivedIceShareCount,
    required this.onViewIceShares,
    required this.ridePaused,
    required this.canToggleRidePause,
    required this.onToggleRidePause,
    required this.canEndRide,
    required this.onEndRide,
  });

  final bool simulation;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final bool canChangeRoute;
  final VoidCallback onOpenRoster;
  final VoidCallback onShareRoster;
  final VoidCallback onChangeRoute;
  final VoidCallback onEmergencyInfo;
  final VoidCallback onNotifications;
  final bool canShareIceInfo;
  final VoidCallback onShareIceInfo;
  final int receivedIceShareCount;
  final VoidCallback onViewIceShares;
  final bool ridePaused;
  final bool canToggleRidePause;
  final VoidCallback onToggleRidePause;
  final bool canEndRide;
  final VoidCallback onEndRide;

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
      child: SingleChildScrollView(
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
            const Divider(height: 20),
            ListTile(
              key: const Key('ride-menu-open-roster'),
              leading: const Icon(Icons.groups_2_outlined),
              title: const Text('Ride roster'),
              subtitle: const Text('Presence, freshness and relay evidence'),
              onTap: () {
                Navigator.of(context).pop();
                onOpenRoster();
              },
            ),
            if (canChangeRoute)
              ListTile(
                key: const Key('ride-menu-change-route'),
                leading: const Icon(Icons.edit_road_outlined),
                title: const Text('Change route'),
                subtitle: const Text(
                  'Plan a destination, import a GPX file, or load the demo route',
                ),
                onTap: () {
                  Navigator.of(context).pop();
                  onChangeRoute();
                },
              ),
            ListTile(
              key: const Key('ride-menu-share-roster'),
              leading: const Icon(Icons.groups_outlined),
              title: const Text('Share rider list'),
              subtitle: const Text(
                'Names and roles, to paste into a group chat you create',
              ),
              onTap: () {
                Navigator.of(context).pop();
                onShareRoster();
              },
            ),
            ListTile(
              key: const Key('ride-menu-emergency-info'),
              leading: const Icon(Icons.medical_information_outlined),
              title: const Text('Emergency info'),
              subtitle: const Text('Edit your details and sharing settings'),
              onTap: () {
                Navigator.of(context).pop();
                onEmergencyInfo();
              },
            ),
            ListTile(
              key: const Key('ride-menu-notifications'),
              leading: const Icon(Icons.notifications_outlined),
              title: const Text('Ride notifications'),
              subtitle: const Text(
                'Background alert permission and preferences',
              ),
              onTap: () {
                Navigator.of(context).pop();
                onNotifications();
              },
            ),
            if (canShareIceInfo)
              ListTile(
                key: const Key('ride-menu-share-ice-info'),
                leading: const Icon(Icons.contact_emergency_outlined),
                title: const Text('Share my emergency contact'),
                subtitle: const Text('Shares it with the whole group, now'),
                onTap: () {
                  Navigator.of(context).pop();
                  onShareIceInfo();
                },
              ),
            ListTile(
              key: const Key('ride-menu-view-ice-shares'),
              leading: Badge(
                isLabelVisible: receivedIceShareCount > 0,
                label: Text('$receivedIceShareCount'),
                child: const Icon(Icons.contacts_outlined),
              ),
              title: const Text('Shared emergency contacts'),
              subtitle: const Text('From other riders, for this ride only'),
              onTap: () {
                Navigator.of(context).pop();
                onViewIceShares();
              },
            ),
            if (canToggleRidePause || canEndRide) const Divider(height: 20),
            if (canToggleRidePause)
              ListTile(
                key: const Key('ride-menu-toggle-pause'),
                leading: Icon(ridePaused ? Icons.play_arrow : Icons.pause),
                title: Text(ridePaused ? 'Resume ride' : 'Pause ride'),
                subtitle: const Text(
                  'Pauses tracking and progress for the whole group',
                ),
                onTap: () {
                  Navigator.of(context).pop();
                  onToggleRidePause();
                },
              ),
            if (canEndRide)
              ListTile(
                key: const Key('ride-menu-end-ride'),
                leading: const Icon(Icons.stop_circle_outlined),
                title: const Text('End ride'),
                subtitle: const Text('Ends the group ride for everyone'),
                onTap: () {
                  Navigator.of(context).pop();
                  onEndRide();
                },
              ),
          ],
        ),
      ),
    );
  }
}

class _PreStartRidePanel extends StatelessWidget {
  const _PreStartRidePanel({
    required this.rideCode,
    required this.participants,
    required this.isLeader,
    required this.busy,
    required this.routeName,
    required this.onStartRide,
    required this.onChooseRoute,
  });

  final String rideCode;
  final List<RideParticipant> participants;
  final bool isLeader;
  final bool busy;
  final String? routeName;
  final VoidCallback onStartRide;
  final VoidCallback onChooseRoute;

  @override
  Widget build(BuildContext context) => Material(
    color: const Color(0xFF17212B),
    child: SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Icon(Icons.groups_outlined, color: Color(0xFFFFC857)),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Waiting to start',
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                      Text(
                        'Ride $rideCode · Current positions only · no tracks recorded',
                        style: const TextStyle(
                          color: Color(0xFFA9B4C2),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                if (isLeader)
                  FilledButton.icon(
                    key: const Key('start-ride-button'),
                    onPressed: busy ? null : onStartRide,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Start ride'),
                  )
                else
                  const Text(
                    'LEADER STARTS',
                    style: TextStyle(
                      color: Color(0xFFFFC857),
                      fontWeight: FontWeight.w800,
                      fontSize: 11,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 9),
            Row(
              children: [
                Icon(
                  routeName == null
                      ? Icons.route_outlined
                      : Icons.check_circle_outline,
                  size: 18,
                  color: routeName == null
                      ? const Color(0xFFFFC857)
                      : const Color(0xFF6ED89A),
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    routeName == null
                        ? 'No route selected'
                        : 'Route: $routeName',
                    maxLines: 2,
                    style: const TextStyle(
                      color: Color(0xFFD4DCE6),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (isLeader)
                  TextButton(
                    key: const Key('pre-start-choose-route'),
                    onPressed: busy ? null : onChooseRoute,
                    child: Text(routeName == null ? 'Choose route' : 'Change'),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                key: const Key('pre-start-roster'),
                children: [
                  for (final participant in participants) ...[
                    Chip(
                      avatar: Icon(
                        participant.role == RideRole.lead
                            ? Icons.navigation
                            : Icons.motorcycle,
                        size: 16,
                      ),
                      label: Text(
                        '${participant.displayName}${participant.isLocal ? ' (you)' : ''}',
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

enum _StartRideDecision { cancel, chooseRoute, start }

class _ActiveRideShellState extends State<ActiveRideShell> {
  final _mapPosition = ValueNotifier<route_domain.GeoPoint?>(null);
  final _mapNavigationPosition = ValueNotifier<MapNavigationPosition?>(null);
  final _mapOverlays = ValueNotifier<List<MapOverlayMarker>>(const []);
  final _offRouteTraces = ValueNotifier<List<MapOverlayTrace>>(const []);
  final _leaderStatus = ValueNotifier<LeaderRideStatus?>(null);
  final _junctionMarkerOverlay = ValueNotifier<MapJunctionMarkerOverlay?>(null);
  final _riderTrails = <String, List<route_domain.GeoPoint>>{};
  final _publishedEventIds = <String>{};
  final _warnings = <String>{};
  final _rideCompletionDetector = RideCompletionDetector();

  late final RideScreenAwakeCoordinator _screenAwakeCoordinator;

  SituationalAwarenessController? _awarenessController;
  CarPlayBridge? _carPlayBridge;
  ForegroundLocationController? _locationController;
  MarkerAssistanceController? _markerAssistanceController;
  NearbyRelayController? _relayController;
  InternetRelayController? _internetRelayController;
  RidePushNotificationController? _pushNotificationController;
  PreStartPresenceController? _preStartPresenceController;
  SharedPreferencesInternetCursorStore? _internetCursorStore;
  RideSimulationController? _simulationController;
  InMemoryRouteStore? _simulationRouteStore;
  RouteStore? _rideRouteStore;
  StreamSubscription<RideEvent>? _receivedEventSubscription;
  StreamSubscription<RideEvent>? _internetReceivedEventSubscription;
  StreamSubscription<PushOpenRequest>? _pushOpenSubscription;
  Timer? _stalenessTimer;
  Timer? _simulationAwarenessTimer;
  Timer? _markerExitChromeTimer;
  Future<void> _publishChain = Future.value();
  String? _routeFingerprint;
  String? _appliedAuthoritativeRouteRevision;
  String? _simulationRouteFingerprint;
  route_domain.ImportedRoute? _activeRoute;
  int _routeGeneration = 0;
  int _selectedIndex = 0;
  Object? _changeRouteRequestToken;
  PickedGpxFile? _pendingSharedGpxFile;
  int _handledAutomaticMarkerActivation = 0;
  int _handledAutomaticMarkerRideOffActivation = 0;
  DateTime? _lastSimulationNavigationUpdateAt;
  DateTime? _lastSimulationOverlayUpdateAt;
  bool _loading = true;
  bool _relayConfigured = false;
  bool _refreshingRideEvents = false;
  bool _publishingRouteChange = false;
  bool _rideEndHandled = false;
  bool _holdingNavigationChromeForMarkerExit = false;
  bool _autoEndingRide = false;
  bool _simulationPausedByRide = false;
  RideRole? _lastPushRole;

  bool get _isSimulation => widget.rideController.session?.isSimulation == true;

  @override
  void initState() {
    super.initState();
    _screenAwakeCoordinator = RideScreenAwakeCoordinator(
      wakeLock: widget.screenWakeLock,
      reassertInterval: widget.screenWakeReassertInterval,
      onError: (error, _) {
        if (kDebugMode) debugPrint('Could not enforce ride wake lock: $error');
      },
    )..start();
    widget.rideController.addListener(_onRideControllerChanged);
    widget.sharedRoutes.addListener(_onSharedRoutesChanged);
    if (widget.sharedRoutes.pending case final file?) {
      if (widget.rideController.isLocalRideLeader) {
        _selectedIndex = 0;
        _changeRouteRequestToken = Object();
        _pendingSharedGpxFile = file;
      } else {
        _warnings.add('Only the ride leader can replace the group route.');
      }
      _clearSharedRoutePending();
    }
    unawaited(_initialize());
    _carPlayBridge = CarPlayBridge(
      onEmergencyTriggered: _sendEmergencyMapAlert,
    );
  }

  /// A GPX file can arrive (via the platform's "Open in..." delivery) while
  /// this ride is already on screen - e.g. resuming from background. Reuses
  /// the same request path as the ride menu's "Change route", just with the
  /// file already in hand instead of asking the map to show its picker.
  void _onSharedRoutesChanged() {
    if (!mounted) return;
    final file = widget.sharedRoutes.pending;
    if (file == null) return;
    if (!widget.rideController.isLocalRideLeader) {
      _warnings.add('Only the ride leader can replace the group route.');
      _clearSharedRoutePending();
      setState(() {});
      return;
    }
    setState(() {
      _selectedIndex = 0;
      _changeRouteRequestToken = Object();
      _pendingSharedGpxFile = file;
    });
    _clearSharedRoutePending();
  }

  /// Deferred a frame so this never calls notifyListeners() back into
  /// SharedRouteController from inside its own listener dispatch (this method
  /// runs either from that listener, or from initState before the first
  /// frame - neither is a safe place to notify synchronously).
  void _clearSharedRoutePending() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.sharedRoutes.clearPending();
    });
  }

  Future<void> _initialize() async {
    route_domain.ImportedRoute? route;
    var publishStoredLeaderRoute = false;
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
        final session = widget.rideController.session;
        if (session != null) {
          _rideRouteStore = await JsonFileRouteStore.openForRide(
            session.rideId,
          );
          route = await _rideRouteStore!.loadActiveRoute();
          final authoritative = widget.rideController.authoritativeRouteState;
          _appliedAuthoritativeRouteRevision = authoritative.revisionId;
          if (authoritative.hasDecision) {
            route = authoritative.route;
            if (route == null) {
              await _rideRouteStore!.clearActiveRoute();
            } else {
              await _rideRouteStore!.saveActiveRoute(route);
            }
          } else if (session.role != RideRole.lead) {
            route = null;
            await _rideRouteStore!.clearActiveRoute();
          } else {
            publishStoredLeaderRoute = route != null;
          }
        }
      } on Object catch (error) {
        // Never fall back to the legacy app-wide route file. A failed
        // ride-scoped store should leave this ride empty instead of reviving
        // a route chosen for an earlier ride.
        _rideRouteStore ??= InMemoryRouteStore();
        _warnings.add('Route storage could not be opened: $error');
      }
    }

    _activeRoute = route;
    await _replaceAwarenessController(route, notify: false);
    if (_isSimulation) {
      await _replaceSimulationController(route, notify: false);
    }
    if (publishStoredLeaderRoute && route != null) {
      await widget.rideController.publishRoute(route);
      _appliedAuthoritativeRouteRevision =
          widget.rideController.authoritativeRouteState.revisionId;
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
        widget.rideController.refreshMembershipFreshness();
        final awareness = _awarenessController;
        if (awareness != null) unawaited(awareness.refreshStaleness());
      });
      final locationController = ForegroundLocationController(
        DeviceLocationSource(),
        (sample) async {
          final startedAt = widget.rideController.rideStartedAt;
          if (startedAt == null) {
            final currentSession = widget.rideController.session;
            if (currentSession != null) {
              _preStartPresenceController?.updateLocalPosition(
                RiderLocation(
                  riderId: currentSession.localRiderId,
                  displayName: currentSession.displayName,
                  role: currentSession.role,
                  sample: sample,
                  receivedAt: DateTime.now(),
                  motorcycleStyle: currentSession.motorcycleStyle,
                  riderColor: currentSession.riderColor,
                ),
              );
            }
            return;
          }
          if (sample.recordedAt.isBefore(startedAt)) {
            return;
          }
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
            .listen(
              (event) =>
                  _onReceivedEvent(event, RideTransportEvidence.internetRelay),
            );
        await internetRelayController.start(session);
        final pushNotificationController = RidePushNotificationController(
          tokenSource:
              widget.pushTokenSource ??
              NativePushTokenSource(NativePushConfiguration.fromEnvironment()),
          registrationApi:
              widget.pushRegistrationApi ??
              HttpPushRegistrationClient(
                configuration: InternetRelayConfiguration.fromEnvironment(),
                client: http.Client(),
              ),
          preferencesStore: await SharedPreferences.getInstance(),
        );
        _pushNotificationController = pushNotificationController;
        pushNotificationController.addListener(
          _onPushNotificationStatusChanged,
        );
        _pushOpenSubscription = pushNotificationController.openedNotifications
            .listen(_onPushNotificationOpened);
        await pushNotificationController.start(session);
        _lastPushRole = session.role;
        final preStartPresenceController = PreStartPresenceController(
          HttpPreStartPresenceClient(
            configuration: InternetRelayConfiguration.fromEnvironment(),
            client: http.Client(),
          ),
        );
        _preStartPresenceController = preStartPresenceController;
        preStartPresenceController.addListener(_onPreStartPresenceChanged);
        if (!widget.rideController.rideStarted) {
          await preStartPresenceController.start(session);
        }
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
          (event) => _onReceivedEvent(event, RideTransportEvidence.nearbyRelay),
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
    final lifecycleFingerprint =
        widget.rideController.rideStartedAt?.toUtc().toIso8601String() ??
        'open';
    final effectiveFingerprint = '$fingerprint:$lifecycleFingerprint';
    if (_awarenessController != null &&
        effectiveFingerprint == _routeFingerprint) {
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
      rideStarted: widget.rideController.rideStarted,
      rideStartedAt: widget.rideController.rideStartedAt,
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
    _routeFingerprint = effectiveFingerprint;
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
    if (!_isSimulation && !widget.rideController.isLocalRideLeader) {
      _warnings.add('A rider cannot replace the leader’s group route.');
      await _applyAuthoritativeRouteDecision();
      if (mounted) setState(() {});
      return;
    }
    _publishingRouteChange = true;
    _activeRoute = route;
    try {
      await _replaceAwarenessController(route);
      if (_isSimulation) {
        await _replaceSimulationController(route);
        return;
      }
      if (route == null) {
        await widget.rideController.clearRoute();
      } else {
        await widget.rideController.publishRoute(route);
      }
      _appliedAuthoritativeRouteRevision =
          widget.rideController.authoritativeRouteState.revisionId;
      final store = _rideRouteStore;
      if (store != null) {
        if (route == null) {
          await store.clearActiveRoute();
        } else {
          await store.saveActiveRoute(route);
        }
      }
    } finally {
      _publishingRouteChange = false;
    }
  }

  Future<void> _applyAuthoritativeRouteDecision() async {
    if (_isSimulation || _publishingRouteChange) return;
    final state = widget.rideController.authoritativeRouteState;
    if (!state.hasDecision ||
        state.revisionId == _appliedAuthoritativeRouteRevision) {
      return;
    }
    _appliedAuthoritativeRouteRevision = state.revisionId;
    final route = state.route;
    final store = _rideRouteStore;
    if (store != null) {
      if (route == null) {
        await store.clearActiveRoute();
      } else {
        await store.saveActiveRoute(route);
      }
    }
    _activeRoute = route;
    await _replaceAwarenessController(route);
    if (mounted) setState(() {});
  }

  Future<void> _replaceSimulationController(
    route_domain.ImportedRoute? route, {
    bool notify = true,
  }) async {
    final fingerprint = route == null
        ? 'none'
        : '${route.id}:${route.importedAt.toUtc().toIso8601String()}:'
              '${route.pathPointCount}';
    final lifecycleFingerprint =
        widget.rideController.rideStartedAt?.toUtc().toIso8601String() ??
        'open';
    final effectiveFingerprint = '$fingerprint:$lifecycleFingerprint';
    if (_simulationController != null &&
        effectiveFingerprint == _simulationRouteFingerprint) {
      return;
    }
    final previous = _simulationController;
    _simulationController = null;
    _simulationRouteFingerprint = effectiveFingerprint;
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
      rideStarted: widget.rideController.rideStarted,
    );
    _simulationController = controller;
    controller.addListener(_onSimulationVisualChanged);
    await controller.initialize();
    if (!mounted || _simulationController != controller) {
      controller.dispose();
      return;
    }
    if (widget.rideController.rideStarted &&
        !widget.rideController.ridePaused &&
        !widget.rideController.rideEnded) {
      controller.start();
    }
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
    final participants = {
      for (final participant in widget.rideController.participants)
        participant.riderId: participant,
    };
    final locationSource = !_isSimulation && !widget.rideController.rideStarted
        ? _preStartPresenceController?.locations ?? const <RiderLocation>[]
        : awareness.riderLocations;
    final visibleRiderLocations = locationSource
        .where(
          (location) =>
              participants[location.riderId]?.isEligibleForLivePosition ??
              false,
        )
        .toList(growable: false);
    final activeRiderIds = participants.values
        .where((participant) => participant.isEligibleForRouteAlerts)
        .map((participant) => participant.riderId)
        .toSet();
    final localLocation = visibleRiderLocations
        .where(
          (location) =>
              location.riderId == widget.rideController.session?.localRiderId,
        )
        .firstOrNull;
    final simulatedRiders = _isSimulation
        ? _simulationController?.riders
        : null;
    final simulatedLocal = simulatedRiders
        ?.where((rider) => rider.isLocal)
        .firstOrNull;
    // The authoritative post-start location journal must not ingest a fix
    // captured before the leader started the ride. The map can still retain
    // that foreground-only fix while it waits for the first post-start
    // movement sample, otherwise a stationary rider disappears and Follow me
    // incorrectly looks like a permission failure.
    final activeDeviceSample = _isSimulation
        ? null
        : _locationController?.activeSample;
    final localMapSample = localLocation?.sample ?? activeDeviceSample;
    final mapPoint = simulatedLocal != null
        ? route_domain.GeoPoint(
            latitude: simulatedLocal.position.latitude,
            longitude: simulatedLocal.position.longitude,
          )
        : localMapSample == null
        ? null
        : route_domain.GeoPoint(
            latitude: localMapSample.position.latitude,
            longitude: localMapSample.position.longitude,
            recordedAt: localMapSample.recordedAt,
          );
    final navigationRecordedAt = simulatedLocal == null
        ? localMapSample?.recordedAt
        : DateTime.now();
    if (updateNavigationPosition) {
      _mapNavigationPosition.value = mapPoint == null
          ? null
          : MapNavigationPosition(
              point: mapPoint,
              recordedAt: navigationRecordedAt!,
              speedMetersPerSecond:
                  simulatedLocal?.speedMetersPerSecond ??
                  localMapSample!.speedMetersPerSecond,
              headingDegrees:
                  simulatedLocal?.headingDegrees ??
                  localMapSample!.headingDegrees,
              accuracyMeters: localMapSample?.accuracyMeters,
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
              ? visibleRiderLocations
                    .where(
                      (location) => location.riderId != localLocation?.riderId,
                    )
                    .map(
                      (location) => (
                        riderId: location.riderId,
                        displayName: location.displayName,
                        role: location.role,
                        motorcycleStyle: location.motorcycleStyle,
                        riderColor: location.riderColor,
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
                        motorcycleStyle: rider.motorcycleStyle,
                        riderColor: rider.riderColor,
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
              motorcycleStyle: location.motorcycleStyle,
              color: needsAttention
                  ? alertColor
                  : isTec
                  ? tailEndCharlieColor
                  : isLead
                  ? leadColor
                  : location.riderColor.color,
            );
          }),
    ];
    _mapOverlays.value = List.unmodifiable(overlays);
    unawaited(
      _carPlayBridge?.publish(
            session: widget.rideController.session,
            riderLocations: visibleRiderLocations,
            routeAlerts: awareness.routeAlerts
                .where((alert) => activeRiderIds.contains(alert.riderId))
                .toList(growable: false),
            activeHazards: awareness.activeHazards,
          ) ??
          Future<void>.value(),
    );
    if (updateDerivedState && widget.rideController.rideStarted) {
      final session = widget.rideController.session;
      _leaderStatus.value = session == null
          ? null
          : const LeaderRideStatusCalculator().calculate(
              localRole: session.role,
              localRiderId: session.localRiderId,
              localLocation: localLocation,
              riderLocations: visibleRiderLocations,
              routeAlerts: awareness.routeAlerts
                  .where((alert) => activeRiderIds.contains(alert.riderId))
                  .toList(growable: false),
              route: awareness.route,
            );
    } else if (!widget.rideController.rideStarted) {
      _leaderStatus.value = null;
    }
  }

  Future<void> _maybeAutomaticallyEndRide(
    SituationalAwarenessController awareness,
  ) async {
    if (_autoEndingRide ||
        !widget.rideController.rideStarted ||
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
      final participant = widget.rideController.participantFor(
        location.riderId,
      );
      if (participant?.isEligibleForLivePosition != true) {
        _riderTrails.remove(location.riderId);
        continue;
      }
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

  Future<void> _onReceivedEvent(
    RideEvent event,
    RideTransportEvidence transport,
  ) async {
    widget.rideController.noteTransportObservation(event.id, transport);
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
      unawaited(_synchroniseRideControllers());
      if (widget.rideController.rideStarted) {
        unawaited(_preStartPresenceController?.stop());
      }
      if (_lastPushRole != session.role) {
        _lastPushRole = session.role;
        unawaited(_pushNotificationController?.refreshRegistration());
      }
    }
    if (widget.rideController.rideEnded && !_rideEndHandled) {
      unawaited(_handleRideEnded());
    }
    _schedulePublish();
  }

  Future<void> _synchroniseRideControllers() async {
    await _replaceAwarenessController(_activeRoute);
    if (!mounted) return;
    if (_isSimulation) {
      await _replaceSimulationController(_activeRoute);
    } else {
      await _applyAuthoritativeRouteDecision();
    }
    _applyRidePauseState();
  }

  void _applyRidePauseState() {
    if (!_isSimulation) return;
    final simulation = _simulationController;
    if (simulation == null) return;
    final rideStarted =
        widget.rideController.rideStarted && !widget.rideController.rideEnded;
    final simulationHadStarted = simulation.rideStarted;
    simulation.setRideStarted(rideStarted);
    if (!rideStarted) {
      _simulationPausedByRide = false;
      return;
    }
    if (widget.rideController.ridePaused) {
      if (simulation.isRunning) {
        simulation.pause();
        _simulationPausedByRide = true;
      }
      return;
    }
    if (!simulationHadStarted || _simulationPausedByRide) {
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
    await _preStartPresenceController?.stop();
    await _pushNotificationController?.stop();
    await _locationController?.stop();
  }

  void _onPreStartPresenceChanged() {
    if (!mounted || widget.rideController.rideStarted) return;
    _updateMapOverlays();
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
        distanceUnits: widget.distanceUnits,
        nearbyRelayController: _relayController,
        internetRelayController: _internetRelayController,
        onRemoveRide: _removeEndedRide,
      );
    }
    final selectedBody = _isSimulation
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
    final session = widget.rideController.session!;
    final body = widget.rideController.rideStarted
        ? selectedBody
        : Column(
            children: [
              _PreStartRidePanel(
                rideCode: session.rideCode,
                participants: widget.rideController.participants,
                isLeader: session.role == RideRole.lead,
                busy: widget.rideController.busy || _loading,
                routeName: _activeRoute?.name,
                onStartRide: _confirmStartRide,
                onChooseRoute: _requestRouteChange,
              ),
              Expanded(
                child: MediaQuery.removePadding(
                  context: context,
                  removeTop: true,
                  child: selectedBody,
                ),
              ),
            ],
          );

    return ValueListenableBuilder<MapNavigationPosition?>(
      valueListenable: _mapNavigationPosition,
      builder: (context, navigationPosition, _) {
        final landscape =
            MediaQuery.orientationOf(context) == Orientation.landscape;
        // The native map flashes when a bottom bar is repeatedly inserted as
        // GPS speed dips at lights. Once there is a navigation fix, preserve
        // the map viewport until the rider deliberately leaves the map tab.
        final hideWhileMoving =
            widget.rideController.rideStarted &&
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
    if (!widget.enableNativeServices && !_isSimulation) {
      return Scaffold(
        appBar: AppBar(title: const Text('Navigation')),
        body: const Center(child: Text('Navigation map')),
      );
    }
    final routeStore = activeRideMapStoreWhenReady(
      initializing: _loading,
      isSimulation: _isSimulation,
      rideRouteStore: _rideRouteStore,
      simulationRouteStore: _simulationRouteStore,
    );
    if (routeStore == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return RideMapFeature.fromEnvironment(
      key: ValueKey(
        'ride-map:${_appliedAuthoritativeRouteRevision ?? 'local'}:'
        '${_activeRoute?.id ?? 'none'}',
      ),
      currentPosition: _mapPosition,
      navigationPosition: _mapNavigationPosition,
      overlayMarkers: _mapOverlays,
      offRouteTraces: _offRouteTraces,
      leaderStatus: _leaderStatus,
      groupRiderCount: widget.rideController.liveParticipants.length,
      onOpenRoster: _openRoster,
      junctionMarkerOverlay: _junctionMarkerOverlay,
      emergencyContacts: _emergencyContacts,
      onEmergencyAlert: _sendEmergencyMapAlert,
      onEmergencyIssue: _sendEmergencyMapIssue,
      ridePaused: widget.rideController.ridePaused,
      onLeaveRide: _confirmLeaveRideFromMap,
      onOpenRideMenu: _openRideMenu,
      onRouteCommitted: _onRouteChanged,
      changeRouteRequestToken: _changeRouteRequestToken,
      onChangeRouteRequestHandled: _clearChangeRouteRequest,
      pendingSharedGpxFile: _pendingSharedGpxFile,
      acquireCurrentPosition: _isSimulation
          ? () async => _mapPosition.value
          : _acquireCurrentPosition,
      routeStore: routeStore,
      canEditRoute: _isSimulation || widget.rideController.isLocalRideLeader,
      distanceUnit: widget.distanceUnits.value,
      speedLimitDisplay: widget.speedLimitDisplay,
      darkMapStyle: widget.mapStyleMode.resolveDark(
        MediaQuery.platformBrightnessOf(context),
      ),
      localMotorcycleStyle:
          widget.rideController.session?.motorcycleStyle ??
          motorcycleIconStyleDefault,
      localBadgeColor: _localBadgeColor,
    );
  }

  Color get _localBadgeColor {
    final session = widget.rideController.session;
    if (session == null) return riderColorDefault.color;
    return switch (session.role) {
      RideRole.tailEndCharlie => tailEndCharlieColor,
      RideRole.lead => leadColor,
      _ => session.riderColor.color,
    };
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

  Future<void> _sendEmergencyMapAlert() async {
    await _sendEmergencyQuickMessage(QuickMessage.emergencyStop);
    await _autoShareIceWithLeaderIfEnabled();
  }

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

  /// The opt-in "share with the leader by default" setting, fired alongside
  /// the emergency-stop alert so it still happens if the rider can't take a
  /// further step. A no-op if the setting is off, there's nothing to share,
  /// or the local rider is themselves the leader.
  Future<void> _autoShareIceWithLeaderIfEnabled() async {
    if (!widget.riderProfile.shareIceWithLeaderByDefault ||
        !widget.riderProfile.hasEmergencyInfo) {
      return;
    }
    final session = widget.rideController.session;
    final leaderId = _currentLeaderRiderId;
    if (session == null ||
        leaderId == null ||
        leaderId == session.localRiderId) {
      return;
    }
    await widget.rideController.shareEmergencyInfo(
      contactName: widget.riderProfile.emergencyContactName,
      contactPhone: widget.riderProfile.emergencyContactPhone,
      medicalNotes: widget.riderProfile.medicalNotes,
      recipientRiderIds: [leaderId],
    );
  }

  /// An explicit rider action: shares ICE info with everyone in the ride,
  /// including the phone number, regardless of the default-share setting.
  Future<void> _shareIceInfoWithGroup() async {
    await widget.rideController.shareEmergencyInfo(
      contactName: widget.riderProfile.emergencyContactName,
      contactPhone: widget.riderProfile.emergencyContactPhone,
      medicalNotes: widget.riderProfile.medicalNotes,
      recipientRiderIds: const [],
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Emergency contact shared with the group.')),
    );
  }

  Future<void> _openIceShareInbox() =>
      IceShareInboxSheet.show(context, widget.rideController);

  void _onPushNotificationStatusChanged() {
    if (mounted) setState(() {});
  }

  void _onPushNotificationOpened(PushOpenRequest request) {
    final session = widget.rideController.session;
    if (!mounted || session == null || request.rideId != session.rideId) {
      return;
    }
    _internetRelayController?.wake();
    final safetyAlert = request.category == 'safety';
    setState(
      () => _selectedIndex = switch ((_isSimulation, safetyAlert)) {
        (true, true) => 3,
        (true, false) => 2,
        (false, true) => 2,
        (false, false) => 1,
      },
    );
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(content: Text('Opened the authenticated ride alert.')),
      );
  }

  Future<void> _openNotificationPreferences() async {
    final controller = _pushNotificationController;
    if (controller == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Notification settings are still loading.'),
        ),
      );
      return;
    }
    await NotificationPreferencesSheet.show(context, controller);
  }

  String? get _currentLeaderRiderId {
    final session = widget.rideController.session;
    if (session?.role == RideRole.lead) return session!.localRiderId;
    for (final rider in _awarenessController?.riderLocations ?? const []) {
      if (rider.role == RideRole.lead) return rider.riderId;
    }
    return null;
  }

  Future<void> _toggleRidePause() async {
    if (widget.rideController.ridePaused) {
      await widget.rideController.resumeRide();
    } else {
      await widget.rideController.pauseRide();
    }
  }

  Future<void> _confirmStartRide() async {
    if (widget.rideController.session?.role != RideRole.lead ||
        widget.rideController.rideStarted) {
      return;
    }
    final route = _activeRoute;
    final decision = await showDialog<_StartRideDecision>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Start this ride?'),
        content: Text(
          route == null
              ? 'No route is selected. You can choose one now, or start '
                    'without navigation. Live location sharing and ride '
                    'recording begin only after you start.'
              : 'Route: ${route.name}\n\nLive location sharing, route '
                    'progress, off-course alerts and ride recording will '
                    'begin for the group.',
        ),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.pop(dialogContext, _StartRideDecision.cancel),
            child: const Text('Cancel'),
          ),
          if (route == null) ...[
            TextButton(
              key: const Key('start-without-route-button'),
              onPressed: () =>
                  Navigator.pop(dialogContext, _StartRideDecision.start),
              child: const Text('Start without route'),
            ),
            FilledButton.icon(
              key: const Key('choose-route-before-start-button'),
              onPressed: () =>
                  Navigator.pop(dialogContext, _StartRideDecision.chooseRoute),
              icon: const Icon(Icons.route_outlined),
              label: const Text('Choose route'),
            ),
          ] else
            FilledButton.icon(
              key: const Key('confirm-start-ride-button'),
              onPressed: () =>
                  Navigator.pop(dialogContext, _StartRideDecision.start),
              icon: const Icon(Icons.play_arrow),
              label: const Text('Start ride'),
            ),
        ],
      ),
    );
    if (decision == _StartRideDecision.chooseRoute) {
      _requestRouteChange();
      return;
    }
    if (decision == _StartRideDecision.start) {
      await widget.rideController.startRide();
    }
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

  Future<void> _confirmEndRide() async {
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
      isScrollControlled: true,
      builder: (context) => _RideNavigationMenu(
        simulation: _isSimulation,
        selectedIndex: _selectedIndex,
        canChangeRoute:
            _isSimulation || widget.rideController.isLocalRideLeader,
        onSelected: (index) {
          Navigator.of(context).pop();
          if (mounted) setState(() => _selectedIndex = index);
        },
        onOpenRoster: _openRoster,
        onShareRoster: _shareRoster,
        onChangeRoute: _requestRouteChange,
        onEmergencyInfo: () =>
            EmergencyInfoSheet.show(context, widget.riderProfile),
        onNotifications: _openNotificationPreferences,
        canShareIceInfo: widget.riderProfile.hasEmergencyInfo,
        onShareIceInfo: _shareIceInfoWithGroup,
        receivedIceShareCount: widget.rideController.receivedIceShares.length,
        onViewIceShares: _openIceShareInbox,
        ridePaused: widget.rideController.ridePaused,
        canToggleRidePause:
            !_isSimulation &&
            widget.rideController.rideStarted &&
            widget.rideController.session?.role == RideRole.lead,
        onToggleRidePause: _toggleRidePause,
        canEndRide: widget.rideController.isLocalRideLeader,
        onEndRide: _confirmEndRide,
      ),
    );
  }

  void _openRoster() {
    unawaited(RideRosterSheet.show(context, widget.rideController));
  }

  /// Switches to the map tab and asks it to open its route picker. The route
  /// picker itself lives entirely in [RideMapScreen] (it alone owns the
  /// on-disk route file), so this only ever hands it a fresh token to react
  /// to - never duplicates its import/demo-route/destination logic here.
  /// Explicitly clears any pending shared file: without that, a stale one
  /// from an earlier "Open in..." delivery would silently skip the picker
  /// this menu action is supposed to show.
  void _requestRouteChange() {
    setState(() {
      _selectedIndex = 0;
      _changeRouteRequestToken = Object();
      _pendingSharedGpxFile = null;
    });
  }

  /// The map screen is rebuilt from scratch every time the tab switch leaves
  /// and returns to it (no keep-alive), so it cannot remember "already
  /// handled" across that round trip. Only this State survives, so it alone
  /// can safely null the token back out once the request has been actioned.
  void _clearChangeRouteRequest() {
    if (_changeRouteRequestToken != null) {
      setState(() {
        _changeRouteRequestToken = null;
        _pendingSharedGpxFile = null;
      });
    }
  }

  /// The app deliberately never collects phone numbers (anonymous ride
  /// codes, no accounts), so it can't create a WhatsApp/Signal/iMessage
  /// group directly. This gives the leader a ready-to-paste roster for
  /// whichever group they create themselves.
  void _shareRoster() {
    final session = widget.rideController.session;
    if (session == null) return;
    final riders = <String>[];
    String labelFor(String name, RideRole role) => switch (role) {
      RideRole.lead => '$name (Lead)',
      RideRole.tailEndCharlie => '$name (Tail End Charlie)',
      _ => name,
    };
    riders.add(labelFor(session.displayName, session.role));
    if (_isSimulation) {
      for (final rider in _simulationController?.riders ?? const []) {
        if (!rider.isLocal) riders.add(labelFor(rider.displayName, rider.role));
      }
    } else {
      for (final rider in _awarenessController?.riderLocations ?? const []) {
        if (rider.riderId != session.localRiderId) {
          riders.add(labelFor(rider.displayName, rider.role));
        }
      }
    }
    final title = session.rideName ?? 'Tail End Charlie ride';
    final text = [
      title,
      'Ride code: ${session.rideCode}',
      '',
      ...riders,
    ].join('\n');
    unawaited(
      SharePlus.instance.share(
        ShareParams(text: text, subject: 'Riders on $title'),
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
    mapStyleMode: widget.mapStyleMode,
    speedLimitDisplay: widget.speedLimitDisplay,
    riderProfile: widget.riderProfile,
    onLeaveRide: _leaveRide,
    onOpenRoster: _openRoster,
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
      // requestAndStart can resume an already-active iOS stream whose latest
      // fix has not changed far enough to trigger the 10 m distance filter.
      // Rebuild the map from that retained fix instead of waiting for movement.
      _updateMapOverlays();
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
      rideStarted: widget.rideController.rideStarted,
      locationController: widget.enableNativeServices && !_isSimulation
          ? _locationController
          : null,
      onLocationStopped: _clearPreStartPresence,
    );
  }

  Future<void> _clearPreStartPresence() async {
    if (!widget.rideController.rideStarted) {
      await _preStartPresenceController?.clearLocalPosition();
    }
  }

  Future<void> _removeEndedRide() async {
    final rideId = widget.rideController.session?.rideId;
    if (rideId != null) await _internetCursorStore?.clear(rideId);
    await widget.rideController.clearEndedRide();
  }

  Future<void> _leaveRide() async {
    _simulationController?.pause();
    await _preStartPresenceController?.stop();
    await _pushNotificationController?.stop();
    final rideId = widget.rideController.session?.rideId;
    if (rideId != null) await _internetCursorStore?.clear(rideId);
    await widget.rideController.leaveRide(
      publishDeparture: (departure) async {
        await _relayController?.publish(departure);
        await _internetRelayController?.synchronizeNow();
      },
    );
  }

  @override
  void dispose() {
    unawaited(_screenAwakeCoordinator.stop());
    widget.rideController.removeListener(_onRideControllerChanged);
    widget.sharedRoutes.removeListener(_onSharedRoutesChanged);
    _simulationController?.removeListener(_onSimulationVisualChanged);
    _simulationController?.dispose();
    _preStartPresenceController?.removeListener(_onPreStartPresenceChanged);
    _awarenessController?.removeListener(_onAwarenessChanged);
    _markerAssistanceController?.dispose();
    _awarenessController?.dispose();
    unawaited(_receivedEventSubscription?.cancel());
    unawaited(_internetReceivedEventSubscription?.cancel());
    unawaited(_pushOpenSubscription?.cancel());
    _stalenessTimer?.cancel();
    _markerExitChromeTimer?.cancel();
    _locationController?.dispose();
    unawaited(_relayController?.close());
    unawaited(_internetRelayController?.close());
    unawaited(_preStartPresenceController?.close());
    _pushNotificationController?.removeListener(
      _onPushNotificationStatusChanged,
    );
    unawaited(_pushNotificationController?.close());
    _mapPosition.dispose();
    _mapNavigationPosition.dispose();
    _mapOverlays.dispose();
    _offRouteTraces.dispose();
    _leaderStatus.dispose();
    _junctionMarkerOverlay.dispose();
    unawaited(_carPlayBridge?.dispose());
    super.dispose();
  }
}
