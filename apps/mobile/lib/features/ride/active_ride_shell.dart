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
import '../../controllers/observer_access_controller.dart';
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
import '../../data/secure_observer_grant_store.dart';
import '../../domain/event_store.dart';
import '../../domain/geo_point.dart' as awareness_geo;
import '../../domain/hazard.dart';
import '../../domain/imported_route.dart' as route_domain;
import '../../domain/quick_message.dart';
import '../../domain/ride_event.dart';
import '../../domain/ride_role.dart';
import '../../domain/ride_session.dart';
import '../../domain/rider_location.dart';
import '../../domain/rider_color.dart';
import '../../domain/route_alert.dart';
import '../../domain/route_store.dart';
import '../../internet/internet_relay_client.dart';
import '../../internet/internet_relay_worker.dart';
import '../../internet/observer_access_client.dart';
import '../../internet/push_registration_client.dart';
import '../../internet/shared_preferences_internet_cursor_store.dart';
import '../../relay/live_presence.dart';
import '../../relay/native_nearby_transport.dart';
import '../../relay/nearby_event_source.dart';
import '../../relay/relay_engine.dart';
import '../../relay/sqlite_relay_queue.dart';
import '../../services/carplay_bridge.dart';
import '../../services/basemap_configuration.dart';
import '../../services/demo_route_loader.dart';
import '../../services/device_location_source.dart';
import '../../services/external_hazard_provider.dart';
import '../../services/gpx_import_source.dart';
import '../../services/leader_ride_status.dart';
import '../../services/measurement_formatter.dart';
import '../../services/native_push_token_source.dart';
import '../../services/received_quick_message.dart';
import '../../services/navigation_guidance.dart';
import '../../services/route_decision_point_extractor.dart';
import '../../services/ride_completion_detector.dart';
import '../../services/ride_membership.dart';
import '../../services/ride_screen_awake.dart';
import '../../services/enforcement_alert_detector.dart';
import '../../services/relay_traffic_hazard_provider.dart';
import '../../services/relay_traffic_reroute_provider.dart';
import '../../services/rejoin_route_share.dart';
import '../../services/road_routing.dart';
import '../../services/ride_connectivity_summary.dart';
import '../../services/tec_gap_trend.dart';
import '../../services/route_rejoin_planner.dart';
import '../../services/trail_display_simplifier.dart';
import '../map/maneuver_list_screen.dart';
import '../map/motorcycle_icon.dart';
import '../map/ride_map.dart';
import '../map/route_review_screen.dart';
import '../settings/emergency_info_sheet.dart';
import '../settings/notification_preferences_sheet.dart';
import 'ice_share_inbox_sheet.dart';
import '../situational_awareness/situational_awareness_screen.dart';
import '../simulation/ride_simulation_screen.dart';
import 'ended_ride_screen.dart';
import 'observer_access_sheet.dart';
import 'ride_dashboard.dart';
import 'ride_roster_sheet.dart';

@visibleForTesting
ObserverPublishedSnapshot buildLocalObserverSnapshot({
  required RideSession session,
  required DateTime snapshotGeneratedAt,
  required String rideStatus,
  required DateTime statusUpdatedAt,
  required DateTime assistanceUpdatedAt,
  required LocationSample? localLocation,
  required ObserverPublishedAssistance? assistance,
}) {
  return ObserverPublishedSnapshot(
    subjectName: session.displayName,
    snapshotGeneratedAt: snapshotGeneratedAt,
    rideStatus: rideStatus,
    statusUpdatedAt: statusUpdatedAt,
    assistanceUpdatedAt: assistanceUpdatedAt,
    position: localLocation == null
        ? null
        : ObserverPublishedPosition(
            latitude: localLocation.position.latitude,
            longitude: localLocation.position.longitude,
            accuracyMeters: localLocation.accuracyMeters,
            recordedAt: localLocation.recordedAt,
          ),
    assistance: assistance,
  );
}

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

/// What the ride map should present of the quick messages in the journal, and
/// the most urgent one per sender so their marker can say what they raised.
///
/// [ReceivedQuickMessageReducer] decides what is admissible; this decides what
/// is still *this rider's* to act on, and works out where each sender is:
///
/// * another rider's message stays until this phone acknowledges it, so a rider
///   who glances away cannot lose it;
/// * this rider's own message appears only once somebody has acknowledged it,
///   as a receipt — nobody needs their own alert read back to them;
/// * the sender's **live** fix is preferred, because where they are now is what
///   a leader turning round needs, falling back to the fix relayed with the
///   message. A rider stopped for fuel is not moving, and their location events
///   age out of the 30-minute retention band long before the two-hour message
///   does, so the relayed fix is what outlasts them.
///
/// Extracted so the decision a two-device test exercises is testable without
/// two devices (#151).
@visibleForTesting
({
  List<RideQuickMessageAlert> alerts,
  Map<String, ReceivedQuickMessage> bySender,
})
presentableQuickMessageAlerts({
  required Iterable<ReceivedQuickMessage> messages,
  required String localRiderId,
  required awareness_geo.GeoPoint? readerPosition,
  Map<String, awareness_geo.GeoPoint> livePositions = const {},
  List<awareness_geo.GeoPoint> route = const [],
}) {
  final alerts = <RideQuickMessageAlert>[];
  final bySender = <String, ReceivedQuickMessage>{};
  // The same rider saying the same thing again is one fact, not another prompt.
  // Keyed by sender and the label the rider actually reads, so someone who
  // raises `Stopped` three times is acknowledged once (#178), a `Stopped` and a
  // `Mechanical` from them stay separate because those are two things to know,
  // and a kind this build has never heard of still groups by its own words.
  final repeatsOfIndex = <({String senderRiderId, String label}), int>{};
  for (final message in messages) {
    if (message.raisedFromLocalRider) {
      if (!message.isAcknowledged) continue;
    } else {
      if (message.acknowledgedBy(localRiderId)) continue;
      bySender.putIfAbsent(message.senderRiderId, () => message);
      final key = (senderRiderId: message.senderRiderId, label: message.label);
      final existing = repeatsOfIndex[key];
      if (existing != null) {
        final kept = alerts[existing];
        alerts[existing] = RideQuickMessageAlert(
          message: kept.message,
          origin: kept.origin,
          repeats: [...kept.repeats, message],
        );
        continue;
      }
      repeatsOfIndex[key] = alerts.length;
    }
    final live = livePositions[message.senderRiderId];
    alerts.add(
      RideQuickMessageAlert(
        message: message,
        origin: QuickMessageOrigin.between(
          readerPosition: readerPosition,
          senderPosition: live ?? message.raisedAtPosition,
          route: route,
          positionIsLive: live != null,
        ),
      ),
    );
  }
  return (
    alerts: List.unmodifiable(alerts),
    bySender: Map.unmodifiable(bySender),
  );
}

/// Riders holding the Tail End Charlie role right now.
///
/// Resolved from the reconciled membership model rather than a location
/// snapshot, so a TEC who has joined but not yet reported a position still
/// counts as registered, and so the role disappearing (the TEC leaves the ride
/// or moves to another role) is picked up mid-ride without a restart. Only
/// riders still included in the live roster count: a departed TEC is no TEC.
///
/// Ride Lab drives its whole virtual group locally, so pass its roster as
/// [simulatedRiders] and it becomes the equivalent authority there.
@visibleForTesting
Set<String> registeredTecRiderIds({
  required Iterable<SimulatedRiderSnapshot>? simulatedRiders,
  required Iterable<RideParticipant> liveParticipants,
}) {
  if (simulatedRiders != null) {
    return simulatedRiders
        .where((rider) => rider.role == RideRole.tailEndCharlie)
        .map((rider) => rider.id)
        .toSet();
  }
  return liveParticipants
      .where(
        (participant) =>
            participant.role == RideRole.tailEndCharlie &&
            participant.isIncludedInLiveCount,
      )
      .map((participant) => participant.riderId)
      .toSet();
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
    required this.maneuverCount,
    required this.onShowManeuvers,
    required this.onEmergencyInfo,
    required this.onNotifications,
    required this.canManageObserverAccess,
    required this.onObserverAccess,
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
  final int maneuverCount;
  final VoidCallback onShowManeuvers;
  final VoidCallback onEmergencyInfo;
  final VoidCallback onNotifications;
  final bool canManageObserverAccess;
  final VoidCallback onObserverAccess;
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
            if (maneuverCount > 0)
              ListTile(
                key: const Key('ride-menu-maneuvers'),
                leading: const Icon(Icons.list_alt),
                title: const Text('All turns'),
                subtitle: Text(
                  '$maneuverCount instruction${maneuverCount == 1 ? '' : 's'} '
                  'for this route',
                ),
                onTap: () {
                  Navigator.of(context).pop();
                  onShowManeuvers();
                },
              ),
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
            if (canManageObserverAccess)
              ListTile(
                key: const Key('ride-menu-observer-access'),
                leading: const Icon(Icons.visibility_outlined),
                title: const Text('Share my progress'),
                subtitle: const Text(
                  'Private, time-limited link for a trusted safety contact',
                ),
                onTap: () {
                  Navigator.of(context).pop();
                  onObserverAccess();
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

enum _MissingTecDecision { cancel, assignTec, startAnyway }

class _ActiveRideShellState extends State<ActiveRideShell>
    with WidgetsBindingObserver {
  final _mapPosition = ValueNotifier<route_domain.GeoPoint?>(null);
  final _mapNavigationPosition = ValueNotifier<MapNavigationPosition?>(null);
  final _mapOverlays = ValueNotifier<List<MapOverlayMarker>>(const []);
  final _riderTrails = ValueNotifier<List<MapOverlayTrace>>(const []);
  final _trailSimplifier = const TrailDisplaySimplifier();
  final _leaderStatus = ValueNotifier<LeaderRideStatus?>(null);

  /// Which way the gap to the TEC is going (#181). Owned here because a trend
  /// needs history, and this is where each leader status is computed.
  final _tecGapTrendTracker = TecGapTrendTracker();
  final _tecGapTrend = ValueNotifier<TecGapTrend>(TecGapTrend.unknown);
  String? _trendedTecRiderId;
  final _junctionMarkerOverlay = ValueNotifier<MapJunctionMarkerOverlay?>(null);
  final _enforcementAlert = ValueNotifier<EnforcementAlert?>(null);

  /// Quick messages the ride map should be presenting, most urgent first (#151).
  ///
  /// Already filtered to what this rider still has to act on: another rider's
  /// message drops out the moment this phone acknowledges it, and this rider's
  /// own message only appears once somebody has acknowledged it, as a receipt.
  final _quickMessageAlerts = ValueNotifier<List<RideQuickMessageAlert>>(
    const [],
  );
  final _trailRecorder = RiderTrailRecorder();
  final _publishedEventIds = <String>{};
  final _warnings = <String>{};
  final _rideCompletionDetector = RideCompletionDetector();
  late final RouteRejoinPlanner _rejoinPlanner;
  Future<void> _rejoinChain = Future.value();
  String? _rejoinGuidance;

  /// Recorded travelled trails and, separately, the local rider's advisory
  /// rejoin breadcrumb (#102). They share the map's one trail channel so the
  /// rejoin route inherits the same palette table and layer ordering, but they
  /// are composed apart because a rejoin route is not recorded history: it must
  /// survive a trail refresh and be dropped the moment the rider is back on
  /// route.
  List<MapOverlayTrace> _recordedTrailTraces = const [];
  MapOverlayTrace? _rejoinTrace;

  /// Issue #128 part 2. Other riders' rejoin breadcrumbs, which only ever reach
  /// the leader's own map: they are relayed addressed to the leader, and the
  /// reducer drops anything this phone is not the recipient of. Held apart from
  /// [_recordedTrailTraces] for the same reason the local rejoin route is —
  /// they are intent, not recorded history.
  List<MapOverlayTrace> _sharedRejoinTraces = const [];

  /// Bounds how often the local rider's rejoin plan is relayed, independently of
  /// how often #102 recomputes it locally.
  final _rejoinRelayGate = RejoinRouteRelayGate();

  /// TEC requests this phone has already put in front of the rider, so an
  /// unanswered request does not reopen its dialog on every rebuild.
  final _promptedTecRequestIds = <String>{};
  bool _tecRequestPromptOpen = false;

  late final RideScreenAwakeCoordinator _screenAwakeCoordinator;

  SituationalAwarenessController? _awarenessController;
  CarPlayBridge? _carPlayBridge;
  ForegroundLocationController? _locationController;
  MarkerAssistanceController? _markerAssistanceController;
  NearbyRelayController? _relayController;
  InternetRelayController? _internetRelayController;
  ObserverAccessController? _observerAccessController;
  RidePushNotificationController? _pushNotificationController;
  PreStartPresenceController? _preStartPresenceController;
  SharedPreferencesInternetCursorStore? _internetCursorStore;
  RideSimulationController? _simulationController;
  RelayTrafficRerouteProvider? _trafficRerouteProvider;
  SharedPreferences? _trafficReroutePreferences;
  InMemoryRouteStore? _simulationRouteStore;
  RouteStore? _rideRouteStore;
  StreamSubscription<RideEvent>? _receivedEventSubscription;
  StreamSubscription<RideEvent>? _internetReceivedEventSubscription;
  StreamSubscription<PushOpenRequest>? _pushOpenSubscription;
  Timer? _stalenessTimer;
  Timer? _externalHazardTimer;
  Timer? _simulationAwarenessTimer;
  Timer? _markerExitChromeTimer;
  Future<void> _publishChain = Future.value();
  String? _routeFingerprint;
  String? _trailLifecycleFingerprint;
  String? _appliedAuthoritativeRouteRevision;
  String? _simulationRouteFingerprint;
  route_domain.ImportedRoute? _activeRoute;
  NavigationGuidance? _latestNavigationGuidance;
  TrafficRerouteSuppression? _trafficRerouteSuppression;
  String? _lastTrafficOfferFingerprint;
  String? _trafficRerouteError;
  int _routeGeneration = 0;
  int _selectedIndex = 0;
  Object? _changeRouteRequestToken;
  PickedGpxFile? _pendingSharedGpxFile;
  int _handledAutomaticMarkerActivation = 0;
  int _handledAutomaticMarkerRideOffActivation = 0;
  DateTime? _lastSimulationNavigationUpdateAt;
  DateTime? _lastSimulationOverlayUpdateAt;
  LocationSample? _latestObserverLocationSample;
  bool _loading = true;
  bool _relayConfigured = false;
  bool _refreshingRideEvents = false;
  bool _publishingRouteChange = false;
  bool _rideEndHandled = false;
  bool _holdingNavigationChromeForMarkerExit = false;
  bool _autoEndingRide = false;
  bool _simulationPausedByRide = false;
  bool _trafficRerouting = false;
  bool _observedRideStarted = false;
  bool _localRideStartInProgress = false;
  RideRole? _lastPushRole;

  bool get _isSimulation => widget.rideController.session?.isSimulation == true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _observedRideStarted =
        widget.rideController.rideStarted && !widget.rideController.rideEnded;
    _screenAwakeCoordinator = RideScreenAwakeCoordinator(
      wakeLock: widget.screenWakeLock,
      reassertInterval: widget.screenWakeReassertInterval,
      onError: (error, _) {
        if (kDebugMode) debugPrint('Could not enforce ride wake lock: $error');
      },
    )..start();
    // Issue #102: advisory off-route rejoin routing. Uses the same documented
    // OSRM configuration as the rest of the app; when it is unreachable the
    // planner degrades to the plain "you are off route by X" message.
    _rejoinPlanner = RouteRejoinPlanner(
      routingService: OsrmRoadRoutingService(
        client: http.Client(),
        baseUrl: RoutingConfiguration.fromEnvironment().routingBaseUrl,
      ),
      distanceUnit: widget.distanceUnits.value,
    );
    widget.rideController.addListener(_onRideControllerChanged);
    widget.sharedRoutes.addListener(_onSharedRoutesChanged);
    _capturePlannerLinkError();
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
    final warningAdded = _capturePlannerLinkError();
    final file = widget.sharedRoutes.pending;
    if (file == null) {
      if (warningAdded) setState(() {});
      return;
    }
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

  bool _capturePlannerLinkError() {
    if (widget.sharedRoutes.plannerLinkStatus != PlannerLinkStatus.error) {
      return false;
    }
    final message = widget.sharedRoutes.plannerLinkMessage;
    if (message == null) return false;
    final code = widget.sharedRoutes.plannerLinkCode;
    return _warnings.add(
      'Shared route link: $message'
      '${code == null ? '' : ' You can still enter code $code from Change route → Load a planned route.'}',
    );
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
    await _initializeTrafficRerouting();
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
      _externalHazardTimer = Timer.periodic(const Duration(minutes: 5), (_) {
        final awareness = _awarenessController;
        if (awareness != null) {
          unawaited(awareness.refreshExternalHazards());
        }
      });
      final locationController = ForegroundLocationController(
        DeviceLocationSource(),
        (sample) async {
          _latestObserverLocationSample = sample;
          _publishObserverSnapshot();
          // Every fix goes to the ephemeral presence channel, in both phases,
          // so this rider stays continuously visible to the group. The durable
          // journal still only receives post-start fixes.
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
          final startedAt = widget.rideController.rideStartedAt;
          if (startedAt == null || sample.recordedAt.isBefore(startedAt)) {
            return;
          }
          final awareness = _awarenessController;
          if (awareness != null) {
            await awareness.recordLocalLocation(sample);
          }
        },
        onSampleError: (error, stackTrace) {
          if (kDebugMode) {
            debugPrint(
              'Could not persist a location update; continuing: '
              '$error\n$stackTrace',
            );
          }
          final added = _warnings.add(
            'A location update could not be saved. Live GPS is continuing.',
          );
          if (added && mounted) setState(() {});
        },
      );
      _locationController = locationController;
      locationController.addListener(_onDeviceLocationChanged);
      try {
        await locationController.initialize();
      } on Object catch (error) {
        _warnings.add('Location capability check failed: $error');
      }
      if (widget.rideController.rideStarted &&
          !widget.rideController.rideEnded) {
        await _resumeLocationForActiveRide();
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
        final observerConfiguration =
            ObserverAccessConfiguration.fromEnvironment();
        if (observerConfiguration.configurationError == null) {
          _observerAccessController = ObserverAccessController(
            HttpObserverAccessClient(
              configuration: observerConfiguration,
              client: http.Client(),
            ),
            const SecureObserverGrantStore(),
          );
          await _observerAccessController!.attach(session);
          if (_observerAccessController!.hasActiveGrants) {
            await locationController.resumeIfAuthorized();
            _publishObserverSnapshot();
          }
        }
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
        // Presence runs for the whole ride, not only before the start. It is
        // what keeps a rider visible across `rideStarted` and what makes a
        // rider who joins an already-started ride appear immediately.
        if (!widget.rideController.rideEnded) {
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
          await _preStartPresenceController?.attachNearby(relayController);
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

  Future<void> _initializeTrafficRerouting() async {
    if (_isSimulation || !widget.enableNativeServices) return;
    _trafficRerouteProvider = RelayTrafficRerouteProvider(
      configuration: InternetRelayConfiguration.fromEnvironment(),
    );
    final preferences = await SharedPreferences.getInstance();
    _trafficReroutePreferences = preferences;
    final value = preferences.getString(_trafficRerouteSuppressionKey);
    if (value == null) return;
    final suppression = TrafficRerouteSuppression.tryDecode(value);
    if (suppression == null || !suppression.until.isAfter(DateTime.now())) {
      await preferences.remove(_trafficRerouteSuppressionKey);
      return;
    }
    _trafficRerouteSuppression = suppression;
  }

  String get _trafficRerouteSuppressionKey =>
      'traffic-reroute-suppression:'
      '${widget.rideController.session?.rideId ?? 'none'}';

  /// Publishes a rider's own enforcement sighting to the group.
  ///
  /// Reported as [HazardSeverity.serious] so it reaches the same advance
  /// warning the provider feed drives; the shorter enforcement expiry in
  /// [HazardExpiryPolicy] keeps a moved-on van from warning riders all day.
  Future<void> _reportHazardFromMap(HazardType type) async {
    final awareness = _awarenessController;
    if (awareness == null) {
      throw const FormatException('This ride is not tracking hazards yet.');
    }
    await awareness.reportHazard(type: type, severity: HazardSeverity.serious);
  }

  List<HazardReport> get _trafficRerouteHazards {
    if (!widget.rideController.isLocalRideLeader ||
        !widget.rideController.rideStarted ||
        _activeRoute == null) {
      return const [];
    }
    final now = DateTime.now();
    final hazards =
        _awarenessController?.activeHazards
            .where(
              (hazard) =>
                  hazard.source == HazardSource.externalProvider &&
                  hazard.providerId == 'tomtom-traffic' &&
                  // Enforcement is warned about, never routed around: a camera
                  // is not an obstruction and the group's route is not the
                  // place to act on one.
                  !enforcementHazardTypes.contains(hazard.type) &&
                  hazard.severity.index >= HazardSeverity.serious.index,
            )
            .take(10)
            .toList(growable: false) ??
        const <HazardReport>[];
    if (hazards.isEmpty) return hazards;
    if (_trafficRerouteSuppression?.suppresses(hazards, now) == true) {
      return const [];
    }
    return hazards;
  }

  Future<void> _dismissTrafficAlternative() async {
    final hazards = _trafficRerouteHazards;
    if (hazards.isEmpty) return;
    await _suppressTrafficIncidents(hazards);
    if (mounted) {
      setState(() {
        _trafficRerouteError = null;
        _lastTrafficOfferFingerprint = null;
      });
    }
  }

  Future<void> _suppressTrafficIncidents(List<HazardReport> hazards) async {
    if (hazards.isEmpty) return;
    final suppression = TrafficRerouteSuppression.forHazards(hazards);
    _trafficRerouteSuppression = suppression;
    await _trafficReroutePreferences?.setString(
      _trafficRerouteSuppressionKey,
      suppression.encode(),
    );
  }

  Future<void> _reviewTrafficAlternative() async {
    if (_trafficRerouting) return;
    final provider = _trafficRerouteProvider;
    final route = _activeRoute;
    final hazards = _trafficRerouteHazards;
    if (provider == null || route == null || hazards.isEmpty) return;
    setState(() {
      _trafficRerouting = true;
      _trafficRerouteError = null;
    });
    try {
      final preview = await provider.preview(
        route: route,
        currentPosition: _mapPosition.value,
        hazards: hazards,
      );
      if (!mounted) return;
      final formatter = MeasurementFormatter(widget.distanceUnits.value);
      final distanceDelta = preview.distanceDeltaMeters;
      final durationDelta = preview.durationDelta;
      final comparison =
          '${distanceDelta >= 0 ? '+' : '−'}'
          '${formatter.distance(distanceDelta.abs())}; '
          '${durationDelta.isNegative ? 'saves' : 'adds'} '
          '${_trafficDurationLabel(durationDelta.abs())}.';
      final action = await RouteReviewScreen.show(
        context,
        route: preview.route,
        distanceUnit: widget.distanceUnits.value,
        basemapConfiguration: BasemapConfiguration.fromEnvironment()
            .forBrightness(
              dark: widget.mapStyleMode.resolveDark(
                MediaQuery.platformBrightnessOf(context),
              ),
            ),
        distanceMeters: preview.alternativeDistanceMeters,
        duration: preview.alternativeDuration,
        previousRoute: route,
        warnings: [
          hazards.first.details ??
              '${hazards.first.type.label} may affect the current route.',
          'TomTom traffic alternative: $comparison',
          if (preview.trafficDelaySaved > Duration.zero)
            'Estimated live-traffic delay avoided: '
                '${_trafficDurationLabel(preview.trafficDelaySaved)}.',
          'The current group route remains authoritative until you confirm.',
        ],
      );
      if (action != RouteReviewAction.confirm || !mounted) return;
      final previousRevision =
          widget.rideController.authoritativeRouteState.revisionNumber;
      await _handleRouteChanged(preview.route);
      final published = widget.rideController.authoritativeRouteState;
      if (published.revisionNumber <= previousRevision ||
          published.route?.id != preview.route.id) {
        _activeRoute = route;
        await _replaceAwarenessController(route);
        await _rideRouteStore?.saveActiveRoute(route);
        throw const FormatException(
          'The traffic alternative could not be published. '
          'The current route has been restored.',
        );
      }
      await _suppressTrafficIncidents(hazards);
      if (mounted) {
        setState(() {
          _lastTrafficOfferFingerprint = null;
        });
      }
    } on FormatException catch (error) {
      if (mounted) setState(() => _trafficRerouteError = error.message);
    } on Object {
      if (mounted) {
        setState(() {
          _trafficRerouteError =
              'The traffic alternative could not be calculated. '
              'The current route has not changed.';
        });
      }
    } finally {
      if (mounted) setState(() => _trafficRerouting = false);
    }
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
    // Waze is deliberately absent. #111 closed it as ineligible for the partner
    // feed with no other read API, so its card could never become available and
    // a tester reported the permanently-unavailable row as a fault (#175). The
    // adapter itself stays in the repository, where a closed investigation
    // belongs, and is exercised by its own test.
    final externalProviders = <ExternalHazardProvider>[
      if (session.role == RideRole.lead && !_isSimulation)
        RelayTrafficHazardProvider(
          configuration: InternetRelayConfiguration.fromEnvironment(),
        ),
    ];
    final controller = SituationalAwarenessController(
      awarenessEventStore,
      session,
      route: routeSegments.expand((segment) => segment).toList(growable: false),
      routeSegments: routeSegments,
      externalProviders: externalProviders,
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
    // Replacing the awareness controller usually only means the route changed -
    // a leader reroute, say - and travelled history must survive that with no
    // gap or restart. Only a new ride lifecycle discards it, which is also what
    // keeps the pre-start no-trace rule intact (#35/#51).
    if (lifecycleFingerprint != _trailLifecycleFingerprint) {
      _trailLifecycleFingerprint = lifecycleFingerprint;
      _trailRecorder.clear();
      _recordedTrailTraces = const [];
    }
    // Issue #102: unlike travelled history, a rejoin plan is only valid for the
    // route it was computed against, so a route change always discards it along
    // with the last-matched progress behind it.
    _rejoinTrace = null;
    _rejoinGuidance = null;
    _rejoinPlanner.reset();
    // Issue #128: the relayed copy is discarded on the same trigger. A share
    // already on the leader's map is retired by its own route revision no longer
    // matching, so nothing is left drawn against a route it was not computed for.
    _rejoinRelayGate.reset();
    _sharedRejoinTraces = const [];
    _pushRiderTrails();
    controller.addListener(_onAwarenessChanged);
    if (session.role == RideRole.lead &&
        !_isSimulation &&
        widget.enableNativeServices) {
      unawaited(controller.refreshExternalHazards());
    }
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
    _refreshTrafficOfferState();
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

  void _refreshTrafficOfferState() {
    final fingerprint = trafficIncidentFingerprint(_trafficRerouteHazards);
    if (fingerprint == _lastTrafficOfferFingerprint) return;
    _lastTrafficOfferFingerprint = fingerprint;
    if (mounted) setState(() {});
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
    // One reconciled model for both ride phases and both transports, so nobody
    // disappears at the `rideStarted` transition, a late joiner appears at once,
    // and the count can never disagree with the drawn markers (#132).
    final livePresence = _isSimulation
        ? const <LiveRiderPresence>[]
        : _reconciledLivePresence();
    if (!_isSimulation) _publishLivePresence(livePresence);
    final participants = {
      for (final participant in widget.rideController.participants)
        participant.riderId: participant,
    };
    final freshnessByRider = {
      for (final presence in livePresence) presence.riderId: presence,
    };
    final visibleRiderLocations = _isSimulation
        ? awareness.riderLocations
              .where(
                (location) =>
                    participants[location.riderId]?.isEligibleForLivePosition ??
                    false,
              )
              .toList(growable: false)
        : widget.rideController.liveView.renderedPositions;
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
    final localMapSample = _newestLocationSample(
      localLocation?.sample,
      activeDeviceSample,
    );
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
      _updateSimulationRiderTrails(simulatedRiders ?? const []);
    } else if (updateDerivedState) {
      _updateRiderTrails(awareness);
    }

    // Issue #151. Resolved before the markers are built, because the rider who
    // raised something is the rider whose marker has to say so.
    final quickMessagesBySender = _refreshQuickMessageAlerts(
      localLocation: localLocation,
      visibleRiderLocations: visibleRiderLocations,
      route: awareness.route,
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
            // A position past its freshness threshold is demoted in words and
            // in colour, never drawn as though it were current.
            final freshness =
                freshnessByRider[location.riderId]?.freshness ??
                PresenceFreshness.live;
            final ageSuffix = switch (freshness) {
              PresenceFreshness.live => null,
              PresenceFreshness.none => PresenceFreshness.none.label,
              _ =>
                freshnessByRider[location.riderId]?.freshnessLabel ??
                    freshness.label,
            };
            // Issue #151's map companion, kept deliberately minimal: the rider
            // who raised something already has a marker, so it says what they
            // raised and takes the alert colour rather than a second symbol
            // being invented beside it. #135 owns the hazard and enforcement
            // symbol language and has not landed, and a dedicated quick-message
            // pin should share whatever it establishes rather than pre-empt it.
            final raised = quickMessagesBySender[location.riderId];
            final roleSuffix = raised != null
                ? raised.label
                : needsAttention
                ? 'check route'
                : isTec
                ? 'TEC'
                : isLead
                ? 'Lead'
                : null;
            final label = [
              location.displayName,
              ?roleSuffix,
              ?ageSuffix,
            ].join(' · ');
            final baseColor = raised != null
                ? (raised.interrupts ? alertColor : const Color(0xFFFFC857))
                : needsAttention
                ? alertColor
                : isTec
                ? tailEndCharlieColor
                : isLead
                ? leadColor
                : location.riderColor.color;
            return MapOverlayMarker(
              id: 'rider-${location.riderId}',
              point: location.point,
              label: label,
              motorcycleStyle: location.motorcycleStyle,
              color: freshness == PresenceFreshness.live
                  ? baseColor
                  : _demotedMarkerColor(baseColor, freshness),
            );
          }),
    ];
    _mapOverlays.value = List.unmodifiable(overlays);
    _enforcementAlert.value = const EnforcementAlertDetector().detect(
      position: localLocation?.sample.position,
      headingDegrees: localLocation?.sample.headingDegrees,
      route: awareness.route,
      hazards: awareness.activeHazards,
      now: DateTime.now(),
    );
    unawaited(
      _carPlayBridge?.publish(
            session: widget.rideController.session,
            riderLocations: visibleRiderLocations,
            routeAlerts: awareness.routeAlerts
                .where((alert) => activeRiderIds.contains(alert.riderId))
                .toList(growable: false),
            activeHazards: awareness.activeHazards,
            routeName: _activeRoute?.name,
            rideState: _projectedRideState,
            guidanceTitle: _projectedGuidanceTitle,
            guidanceDetail: _projectedGuidanceDetail,
            groupStatus: '${visibleRiderLocations.length} riders visible',
            markerStatus: _junctionMarkerOverlay.value?.instruction,
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
              // Issue #102: a rider inside the leader's own track corridor is
              // following the leader, not off course, and must not be counted.
              leaderTrail: awareness.leaderTrail,
              registeredTecRiderIds: _registeredTecRiderIds,
              // Issue #128: two riders can hold the role at once - one
              // self-selected, one asked - and the group needs one answer, so
              // the leader's own accepted request breaks the tie.
              assignedTecRiderId: _assignedTecRiderId,
            );
      _updateTecGapTrend(awareness);
    } else if (!widget.rideController.rideStarted) {
      _leaderStatus.value = null;
      _tecGapTrendTracker.reset();
      _tecGapTrend.value = TecGapTrend.unknown;
    }
    _updateSharedRejoinTraces();
  }

  /// Publishes the quick messages the ride map has to present, and returns the
  /// most urgent one per sender so their marker can say what they raised.
  ///
  /// The reducer decides what is admissible; this decides what is still *this
  /// rider's* to act on, and works out where each sender is. Two position
  /// sources, in that order:
  ///
  /// * the sender's live fix, when they are still reporting one — where they are
  ///   now is what a leader turning round needs;
  /// * otherwise the fix relayed with the message, which is where they were when
  ///   they raised it. A rider stopped for fuel is not moving, and their location
  ///   events age out of the 30-minute band long before the message does.
  Map<String, ReceivedQuickMessage> _refreshQuickMessageAlerts({
    required RiderLocation? localLocation,
    required List<RiderLocation> visibleRiderLocations,
    required List<awareness_geo.GeoPoint> route,
  }) {
    final localRiderId = widget.rideController.session?.localRiderId;
    if (localRiderId == null) {
      _quickMessageAlerts.value = const [];
      return const {};
    }
    final presented = presentableQuickMessageAlerts(
      messages: widget.rideController.quickMessages,
      localRiderId: localRiderId,
      readerPosition: localLocation?.sample.position,
      livePositions: {
        for (final location in visibleRiderLocations)
          location.riderId: location.sample.position,
      },
      route: route,
    );
    _quickMessageAlerts.value = presented.alerts;
    return presented.bySender;
  }

  /// Acknowledges the presented message *and* every repeat it stands for, so a
  /// rider who cancels a `Stopped` is not asked again about the two identical
  /// ones behind it (#178).
  Future<void> _acknowledgeQuickMessage(ReceivedQuickMessage message) async {
    final alert = _quickMessageAlerts.value
        .where((candidate) => candidate.message.eventId == message.eventId)
        .firstOrNull;
    for (final outstanding in alert?.acknowledgeable ?? [message]) {
      await widget.rideController.acknowledgeQuickMessage(outstanding);
    }
    _updateMapOverlays(updateNavigationPosition: false);
  }

  Set<String> get _registeredTecRiderIds => registeredTecRiderIds(
    simulatedRiders: _isSimulation ? _simulationController?.riders : null,
    liveParticipants: widget.rideController.liveParticipants,
  );

  /// The rider the leader's most recently accepted TEC request names, if any.
  /// Ride Lab drives its own virtual roster and has no relayed requests.
  String? get _assignedTecRiderId => _isSimulation
      ? null
      : widget.rideController.tecRoleAssignments.acceptedTecRiderId;

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

  /// Ride Lab drives the same trail model as a real ride, so the simulator can
  /// no longer show a leader track the live path never builds (#100).
  void _updateSimulationRiderTrails(List<SimulatedRiderSnapshot> riders) =>
      _publishRiderTrails([
        for (final rider in riders)
          RiderTrail(
            riderId: rider.id,
            displayName: rider.displayName,
            kind: RiderTrailRecorder.kindFor(
              isLeader: rider.role == RideRole.lead,
              isOffRoute: rider.isOffRoute,
            ),
            // Ride Lab maintains its own ephemeral history; the same per-rider
            // cap is applied here so the simulator and a real ride agree.
            points: _trailRecorder.boundedTrail(
              _routePoints(rider.travelTrail),
            ),
          ),
      ]);

  /// Records and publishes every eligible rider's travelled trail from position
  /// history alone.
  ///
  /// Route matching decides route progress and alerts; it never decides whether
  /// a trail is drawn. The leader's trail also draws on the awareness
  /// controller's leader history, which is rebuilt from the durable journal on
  /// restart, so it survives an app restart mid-ride as far as the journal
  /// allows.
  void _updateRiderTrails(SituationalAwarenessController awareness) {
    if (!widget.rideController.rideStarted) {
      _trailRecorder.clear();
      _publishRiderTrails(const []);
      return;
    }
    final alerts = {
      for (final alert in awareness.routeAlerts) alert.riderId: alert,
    };
    _publishRiderTrails(
      _trailRecorder.update([
        for (final location in awareness.riderLocations)
          RiderTrailUpdate(
            riderId: location.riderId,
            displayName: location.displayName,
            position: route_domain.GeoPoint(
              latitude: location.sample.position.latitude,
              longitude: location.sample.position.longitude,
              recordedAt: location.sample.recordedAt,
            ),
            isLeader: location.role == RideRole.lead,
            isOffRoute: _isOffRouteState(
              alerts[location.riderId]?.assessment.state,
            ),
            isEligible:
                widget.rideController
                    .participantFor(location.riderId)
                    ?.isEligibleForLivePosition ==
                true,
            journalTrail: location.role == RideRole.lead
                ? _routePoints(awareness.leaderTrail)
                : null,
          ),
      ]),
    );
    unawaited(_updateRejoinRoute(awareness));
  }

  /// Issue #102: keeps the local rider's advisory rejoin breadcrumb current.
  ///
  /// Only the local rider is planned for. The breadcrumb belongs to whoever is
  /// off route and nothing here is relayed, so no other rider's rejoin route can
  /// reach this map. Recompute frequency is bounded inside [RouteRejoinPlanner];
  /// this only serialises the calls so a burst of location events cannot overlap
  /// them.
  Future<void> _updateRejoinRoute(SituationalAwarenessController awareness) {
    _rejoinChain = _rejoinChain.then((_) async {
      // Ride Lab drives a virtual group and the headless mode has no map, so
      // neither may reach a real routing provider.
      if (!mounted || _isSimulation || !widget.enableNativeServices) return;
      final session = widget.rideController.session;
      final local = awareness.localLocation;
      final alert = session == null
          ? null
          : awareness.alertFor(session.localRiderId);
      if (session == null || local == null || alert == null) {
        _setRejoinPlan(null, null);
        return;
      }
      // The TEC is resolved through the one availability model (#113) rather
      // than a null check, so "nobody is TEC", "registered but never reported"
      // and "last fix too old to trust" all fall back to the leader.
      final tec = const LeaderRideStatusCalculator().resolveTecTarget(
        localRiderId: session.localRiderId,
        riderLocations: awareness.riderLocations,
        registeredTecRiderIds: _registeredTecRiderIds,
        now: DateTime.now(),
      );
      final leader = _newestLocationFor(awareness, RideRole.lead);
      final plan = await _rejoinPlanner.update(
        riderId: session.localRiderId,
        sample: local.sample,
        assessment: alert.assessment,
        plannedRoute: awareness.route,
        followingLeaderTrack: awareness.isFollowingLeaderTrack(
          session.localRiderId,
        ),
        leaderPosition: leader?.sample.position,
        tecAvailability: tec.availability,
        tecPosition: tec.navigableLocation?.sample.position,
      );
      if (!mounted) return;
      _setRejoinPlan(
        plan.severity == RouteRejoinSeverity.onRoute ? null : plan.guidance,
        plan.hasBreadcrumb
            ? MapOverlayTrace(
                id: 'rejoin-${plan.riderId}',
                points: _routePoints(plan.breadcrumb),
                label: 'Advisory rejoin route',
                kind: RiderTrailKind.rejoin,
              )
            : null,
      );
      await _relayRejoinPlanToLeader(plan, session);
    });
    return _rejoinChain;
  }

  /// Feeds the current gap into the trend tracker.
  ///
  /// The history is dropped when the role moves to a different rider: the
  /// previous TEC's gap says nothing about the new one's, and carrying it over
  /// would report a trend for a rider who has only just been asked.
  void _updateTecGapTrend(SituationalAwarenessController awareness) {
    final status = _leaderStatus.value;
    if (status == null) {
      _tecGapTrendTracker.reset();
      _tecGapTrend.value = TecGapTrend.unknown;
      return;
    }
    if (status.tecRiderId != _trendedTecRiderId) {
      _trendedTecRiderId = status.tecRiderId;
      _tecGapTrendTracker.reset();
    }
    final tecPosition = status.tecRiderId == null
        ? null
        : awareness.riderLocations
              .where((rider) => rider.riderId == status.tecRiderId)
              .map((rider) => rider.sample.position)
              .firstOrNull;
    _tecGapTrend.value = _tecGapTrendTracker.update(
      availability: status.tecAvailability,
      gapMeters: status.distanceToTecMeters,
      tecPosition: tecPosition,
      now: DateTime.now(),
    );
  }

  /// Issue #128 part 2: relays the local rider's rejoin plan to the leader, and
  /// to nobody else.
  ///
  /// The bound is [RejoinRouteRelayGate]'s, not #102's: one share per 120 s,
  /// with a clear exempt so an expiry is prompt. The leader already learns that
  /// this rider is off course, and how badly, from the unthrottled deviation
  /// alert; this carries only the geometry.
  Future<void> _relayRejoinPlanToLeader(
    RouteRejoinPlan? plan,
    RideSession session,
  ) async {
    if (_isSimulation) return;
    final controller = widget.rideController;
    // Nothing to address a leader-only event to, and a leader has their own plan
    // already: in both cases the gate is still evaluated so a share already sent
    // is cleared rather than left on the leader's map.
    final hasLeaderRecipient =
        controller.leaderRiderId != null &&
        controller.leaderRiderId != session.localRiderId;
    final decision = _rejoinRelayGate.evaluate(
      plan: hasLeaderRecipient ? plan : null,
      displayName: session.displayName,
      routeRevisionNumber: controller.authoritativeRouteState.revisionNumber,
      now: DateTime.now(),
      rideEnded: controller.rideEnded,
    );
    final share = decision.share;
    if (share == null) return;
    final relayCanCarry =
        _internetRelayController?.supportsCapability(
          RelayProtocolCapabilities.rejoinRouteSharing,
        ) ??
        true;
    final sent = await controller.shareRejoinRoute(
      share,
      relayCanCarryShare: relayCanCarry,
    );
    if (sent || !mounted) return;
    // Only ever raised for a share, never for a clear: a clear that cannot be
    // sent is covered by the share's own TTL expiring on the leader's phone.
    if (decision.action == RejoinRouteRelayAction.share && !relayCanCarry) {
      _rejoinRelayGate.reset();
      if (_warnings.add(
        PresenceLimitation.rejoinSharingUnsupportedByService.message,
      )) {
        setState(() {});
      }
    }
  }

  void _setRejoinPlan(String? guidance, MapOverlayTrace? trace) {
    if (trace != _rejoinTrace) {
      _rejoinTrace = trace;
      _pushRiderTrails();
    }
    if (guidance != _rejoinGuidance) {
      setState(() => _rejoinGuidance = guidance);
    }
  }

  static RiderLocation? _newestLocationFor(
    SituationalAwarenessController awareness,
    RideRole role,
  ) {
    RiderLocation? newest;
    for (final location in awareness.riderLocations) {
      if (location.role != role) continue;
      if (newest == null ||
          location.sample.recordedAt.isAfter(newest.sample.recordedAt)) {
        newest = location;
      }
    }
    return newest;
  }

  static List<route_domain.GeoPoint> _routePoints(
    List<awareness_geo.GeoPoint> points,
  ) => [
    for (final point in points)
      route_domain.GeoPoint(
        latitude: point.latitude,
        longitude: point.longitude,
      ),
  ];

  void _publishRiderTrails(List<RiderTrail> trails) {
    _recordedTrailTraces = List.unmodifiable([
      for (final trail in trails.where((trail) => trail.isRenderable))
        MapOverlayTrace(
          id: 'trail-${trail.riderId}',
          points: trail.points,
          label: switch (trail.kind) {
            RiderTrailKind.leader => '${trail.displayName} leader trail',
            RiderTrailKind.offRoute => '${trail.displayName} off-route trace',
            RiderTrailKind.rider => '${trail.displayName} trail',
            // RiderTrailRecorder only records where riders have been, so it
            // never produces a rejoin route.
            RiderTrailKind.rejoin => '${trail.displayName} rejoin route',
          },
          kind: trail.kind,
        ),
    ]);
    _pushRiderTrails();
  }

  /// The rejoin breadcrumbs are appended last so they draw above the trails in
  /// the flutter_map fallback, matching the MapLibre layer order. Shared
  /// breadcrumbs from other riders sit under the local rider's own, which is the
  /// only one that is guidance for this phone.
  /// Every trace is simplified for display here, once per change, rather than
  /// in a renderer or on every frame: this is the single point both map
  /// implementations read from, so the bound cannot apply to only one of them
  /// (#165).
  void _pushRiderTrails() {
    _riderTrails.value = List.unmodifiable([
      for (final trace in [
        ..._recordedTrailTraces,
        ..._sharedRejoinTraces,
        ?_rejoinTrace,
      ])
        _simplifiedForDisplay(trace),
    ]);
  }

  MapOverlayTrace _simplifiedForDisplay(MapOverlayTrace trace) {
    final simplified = _trailSimplifier.simplify(trace.points);
    if (simplified.length == trace.points.length) return trace;
    return MapOverlayTrace(
      id: trace.id,
      points: simplified,
      label: trace.label,
      kind: trace.kind,
    );
  }

  /// Issue #128 part 2: refreshes the rejoin breadcrumbs other riders have
  /// shared with this phone.
  ///
  /// Every gate lives in [SharedRejoinRouteReducer] — addressed to this rider,
  /// authored by the rider it describes, matching the current route revision,
  /// inside its own TTL, not cleared, not from someone who has left — so a share
  /// vanishing on rejoin, on a route change and at ride end all fall out of one
  /// rule set rather than three UI checks. Ride Lab has no relay, so it has
  /// nothing to show.
  void _updateSharedRejoinTraces() {
    final shares = _isSimulation
        ? const <String, SharedRejoinRoute>{}
        : widget.rideController.sharedRejoinRoutes;
    final traces = <MapOverlayTrace>[
      for (final share in shares.values)
        MapOverlayTrace(
          id: 'shared-rejoin-${share.riderId}',
          points: _routePoints(share.breadcrumb),
          label: share.mapLabel,
          kind: RiderTrailKind.rejoin,
        ),
    ]..sort((left, right) => left.id.compareTo(right.id));
    if (_sameTraces(_sharedRejoinTraces, traces)) return;
    _sharedRejoinTraces = List.unmodifiable(traces);
    _pushRiderTrails();
  }

  static bool _sameTraces(
    List<MapOverlayTrace> current,
    List<MapOverlayTrace> next,
  ) {
    if (current.length != next.length) return false;
    for (var index = 0; index < current.length; index += 1) {
      if (current[index].id != next[index].id ||
          current[index].label != next[index].label ||
          current[index].points.length != next[index].points.length) {
        return false;
      }
    }
    return true;
  }

  static bool _isOffRouteState(RouteTrackingState? state) =>
      state == RouteTrackingState.suspectedOffRoute ||
      state == RouteTrackingState.offRoute ||
      state == RouteTrackingState.recovering;

  /// Desaturates a rider marker as its position ages. The wording beside it
  /// always states the age too, so this is never the only signal.
  static Color _demotedMarkerColor(Color base, PresenceFreshness freshness) {
    final blend = switch (freshness) {
      PresenceFreshness.live => 0.0,
      PresenceFreshness.ageing => 0.35,
      PresenceFreshness.stale => 0.6,
      PresenceFreshness.none => 0.75,
    };
    return Color.lerp(base, const Color(0xFF6B7684), blend) ?? base;
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
    final rideStarted =
        widget.rideController.rideStarted && !widget.rideController.rideEnded;
    final rideJustStarted = rideStarted && !_observedRideStarted;
    _observedRideStarted = rideStarted;
    if (session != null) {
      _awarenessController?.updateLocalSession(session);
      _observerAccessController?.updateSession(session);
      _updateMapOverlays();
      unawaited(_synchroniseRideControllers());
      if (rideJustStarted && !_localRideStartInProgress) {
        unawaited(_resumeLocationForActiveRide());
      }
      if (_lastPushRole != session.role) {
        _lastPushRole = session.role;
        unawaited(_pushNotificationController?.refreshRegistration());
      }
      _publishObserverSnapshot();
      _updateSharedRejoinTraces();
      unawaited(_promptPendingTecRequest());
    }
    if (widget.rideController.rideEnded && !_rideEndHandled) {
      unawaited(_handleRideEnded());
    }
    _schedulePublish();
  }

  Future<void> _resumeLocationForActiveRide() async {
    final locationController = _locationController;
    if (locationController == null ||
        !widget.rideController.rideStarted ||
        widget.rideController.rideEnded) {
      return;
    }
    try {
      await locationController.resumeIfAuthorized();
    } on Object catch (error, stackTrace) {
      if (kDebugMode) {
        debugPrint('Could not resume live GPS: $error\n$stackTrace');
      }
      final added = _warnings.add(
        'Live GPS could not resume automatically. Use Follow me or Safety '
        'to try again.',
      );
      if (added && mounted) setState(() {});
    }
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
    _externalHazardTimer?.cancel();
    _simulationAwarenessTimer?.cancel();
    _stalenessTimer = null;
    _externalHazardTimer = null;
    await _preStartPresenceController?.stop();
    await _pushNotificationController?.stop();
    await _locationController?.stop();
  }

  /// Hands the reconciled presence to the one model every surface reads, along
  /// with whether this device can receive positions at all — so a missing marker
  /// is attributed to the transport rather than silently to the rider.
  void _publishLivePresence(List<LiveRiderPresence> presence) {
    widget.rideController.observeLivePresence(
      presence,
      // The roster still names the riders who have left, which is how their
      // record survives a departure even if their membership events never
      // reached this phone's journal (#144). It adds nobody to the live count.
      roster: _preStartPresenceController?.roster ?? const [],
      positionChannelUnavailable:
          _preStartPresenceController?.unavailableReason != null,
    );
  }

  void _onPreStartPresenceChanged() {
    if (!mounted) return;
    // Presence is the channel that does not depend on the bulk event batch, so
    // it is what tells the roster a rider has joined.
    _publishLivePresence(_reconciledLivePresence());
    // A capability refusal, a rejected credential or an older peer used to turn
    // live positions off with no visible reason at all.
    var changed = false;
    for (final limitation
        in _preStartPresenceController?.limitations ?? const []) {
      if (_warnings.add(limitation.message)) changed = true;
    }
    _updateMapOverlays();
    if (changed && mounted) setState(() {});
  }

  /// One reconciled live-position model: the durable journal, the internet
  /// presence channel, the nearby presence channel and the relay's
  /// cursor-independent roster, merged newest-sample-wins.
  List<LiveRiderPresence> _reconciledLivePresence() {
    final session = widget.rideController.session;
    if (session == null || _isSimulation) return const [];
    final presence = _preStartPresenceController;
    return const LivePresenceReconciler().reconcile(
      now: DateTime.now(),
      localRiderId: session.localRiderId,
      journal: _awarenessController?.riderLocations ?? const [],
      internetPresence: presence?.internetLocations ?? const [],
      nearbyPresence: presence?.nearbyLocations ?? const [],
      roster: presence?.roster ?? const [],
      // A peer's position is aged on the relay's clock, not this phone's.
      relayClockOffset: presence?.relayClockOffset ?? Duration.zero,
    );
  }

  void _onDeviceLocationChanged() {
    if (!mounted) return;
    // The foreground map follows the newest device fix even if writing that
    // sample to the durable ride journal is briefly delayed or fails. Only
    // the journal feeds trails, summaries and GPX recording.
    _updateMapOverlays(updateDerivedState: false, updateOverlayMarkers: false);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    unawaited(_locationController?.restartAfterForegroundResume());
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
                // Who is here, not who has been here: the waiting-to-start
                // lobby is a live list, and a rider who has left keeps their
                // record in the ride roster instead (#144).
                participants: widget.rideController.liveParticipants,
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
      riderTrails: _riderTrails,
      leaderStatus: _leaderStatus,
      tecGapTrend: _tecGapTrend,
      groupRiderCount: widget.rideController.liveParticipants.length,
      onOpenRoster: _openRoster,
      junctionMarkerOverlay: _junctionMarkerOverlay,
      enforcementAlert: _enforcementAlert,
      quickMessageAlerts: _quickMessageAlerts,
      onAcknowledgeQuickMessage: _acknowledgeQuickMessage,
      onReportHazard: _awarenessController == null
          ? null
          : _reportHazardFromMap,
      emergencyContacts: _emergencyContacts,
      onEmergencyAlert: _sendEmergencyMapAlert,
      onEmergencyIssue: _sendEmergencyMapIssue,
      ridePaused: widget.rideController.ridePaused,
      rideHasNoLeader: widget.rideController.rideHasNoLeader,
      onLeaveRide: _confirmLeaveRideFromMap,
      onOpenRideMenu: _openRideMenu,
      onRouteCommitted: _onRouteChanged,
      onNavigationGuidanceChanged: _onNavigationGuidanceChanged,
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

  void _onNavigationGuidanceChanged(NavigationGuidance? guidance) {
    _latestNavigationGuidance = guidance;
    _updateMapOverlays(updateDerivedState: false);
  }

  String get _projectedRideState {
    if (widget.rideController.rideEnded) return 'Ride ended';
    if (widget.rideController.ridePaused) return 'Ride paused';
    if (widget.rideController.rideStarted) return 'Ride in progress';
    return 'Waiting for the ride leader to start';
  }

  /// Next instruction for the projected car surfaces.
  ///
  /// This is the same collapsed instruction the phone banner shows, so a
  /// roundabout is announced once, with its exit and direction, rather than as
  /// the engine's separate entry and exit steps. The car rows are plain text
  /// with no symbol beside them, so they name the junction.
  String? get _projectedGuidanceTitle =>
      _latestNavigationGuidance?.instruction.standaloneText;

  String? get _projectedGuidanceDetail {
    final guidance = _latestNavigationGuidance;
    if (guidance == null) return null;
    final distance = MeasurementFormatter(
      widget.distanceUnits.value,
    ).distance(guidance.distanceMeters);
    return '$distance · ${guidance.roadLabel}';
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
      // Where the rider is standing, relayed with the message: "Bill needs fuel"
      // is not actionable without "1.2 miles back" (#151).
      position: _localQuickMessagePosition,
    );
    await _recordLocalObserverQuickMessage(message);
  }

  Future<void> _sendLocalQuickMessage(QuickMessage message) async {
    await widget.rideController.sendQuickMessage(
      message,
      position: _localQuickMessagePosition,
    );
    await _recordLocalObserverQuickMessage(message);
  }

  /// The best fix this phone has for itself, journal-first and falling back to
  /// the foreground sample a pre-movement rider has but has not yet recorded.
  awareness_geo.GeoPoint? get _localQuickMessagePosition =>
      _awarenessController?.localLocation?.sample.position ??
      _locationController?.activeSample?.position;

  Future<void> _recordLocalObserverQuickMessage(QuickMessage message) async {
    if (message == QuickMessage.assistance ||
        message == QuickMessage.emergencyStop ||
        message == QuickMessage.resolved) {
      await _observerAccessController?.recordLocalAssistance(
        message == QuickMessage.resolved ? null : message.name,
      );
      if (mounted) setState(() {});
      _publishObserverSnapshot();
    }
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
      if (!await _confirmStartWithoutTec()) return;
      _localRideStartInProgress = true;
      try {
        await widget.rideController.startRide();
        try {
          // The confirmation is an explicit user action and promises that
          // live sharing begins now, so it is the correct place to request
          // permission when the leader has not granted it yet.
          await _locationController?.requestAndStart();
        } on Object catch (error, stackTrace) {
          if (kDebugMode) {
            debugPrint('Could not start live GPS: $error\n$stackTrace');
          }
          final added = _warnings.add(
            'The ride started, but live GPS could not start. Use Follow me '
            'or Safety to try again.',
          );
          if (added && mounted) setState(() {});
        }
      } finally {
        _localRideStartInProgress = false;
      }
    }
  }

  /// Warns the leader once, before the ride starts, that nobody is Tail End
  /// Charlie, and returns whether they chose to ride anyway.
  ///
  /// This is deliberately a warning and not a block: a two-rider ride or a
  /// solo scouting ride is legitimate. It only ever runs inside the start
  /// confirmation, so it cannot nag during the ride.
  Future<bool> _confirmStartWithoutTec() async {
    if (_registeredTecRiderIds.isNotEmpty) return true;
    final decision = await showDialog<_MissingTecDecision>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('no-tec-warning'),
        icon: const Icon(Icons.warning_amber_rounded, color: Color(0xFFFFC857)),
        title: const Text('No Tail End Charlie'),
        content: const Text(
          'Nobody in this ride holds the Tail End Charlie role, so starting '
          'now means:\n\n'
          '· no back-marker to confirm the group is complete\n'
          '· no distance to the back of the group for you\n'
          '· no TEC for a rider who falls a long way behind to aim for\n\n'
          'A rider takes the role from their own Ride tab. Fine for a small '
          'or solo ride — worth fixing for a group.',
        ),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.pop(dialogContext, _MissingTecDecision.cancel),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const Key('assign-tec-button'),
            onPressed: () =>
                Navigator.pop(dialogContext, _MissingTecDecision.assignTec),
            child: const Text('Assign a TEC'),
          ),
          FilledButton(
            key: const Key('start-without-tec-button'),
            onPressed: () =>
                Navigator.pop(dialogContext, _MissingTecDecision.startAnyway),
            child: const Text('Start anyway'),
          ),
        ],
      ),
    );
    if (decision == _MissingTecDecision.assignTec && mounted) _openRoster();
    return decision == _MissingTecDecision.startAnyway;
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
        maneuverCount: const NavigationGuidancePlanner()
            .instructions(_activeRoute)
            .length,
        onShowManeuvers: _openManeuverList,
        onEmergencyInfo: () =>
            EmergencyInfoSheet.show(context, widget.riderProfile),
        onNotifications: _openNotificationPreferences,
        canManageObserverAccess: _observerAccessController != null,
        onObserverAccess: _openObserverAccess,
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
    unawaited(
      RideRosterSheet.show(
        context,
        widget.rideController,
        relayCanCarryTecRequest:
            _internetRelayController?.supportsCapability(
              RelayProtocolCapabilities.tecRoleAssignment,
            ) ??
            true,
        legacyPeerRiderIds: _legacyPeerRiderIds,
      ),
    );
  }

  /// Riders the live presence channel has already identified as running an
  /// older build. Such a build predates the TEC-request event entirely, so it
  /// will skip it — which is why the leader is told by name before asking rather
  /// than watching the request sit unanswered.
  Set<String> get _legacyPeerRiderIds => {
    for (final limitation
        in _preStartPresenceController?.limitations ?? const [])
      if (limitation.kind == PresenceLimitationKind.peerAppOlder &&
          limitation.riderId != null)
        limitation.riderId!,
  };

  /// Issue #128 part 1: puts an unanswered TEC request in front of the rider it
  /// names, once.
  ///
  /// The whole point of a request rather than a silent assignment is that the
  /// rider knows. A request the rider never sees would be worse than no TEC,
  /// because the leader would believe the back was covered.
  Future<void> _promptPendingTecRequest() async {
    if (_isSimulation || _tecRequestPromptOpen || !mounted) return;
    final request = widget.rideController.pendingTecRoleRequestForLocalRider;
    if (request == null) return;
    if (!_promptedTecRequestIds.add(request.requestId)) return;
    _tecRequestPromptOpen = true;
    try {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          key: const Key('tec-role-request'),
          icon: const Icon(
            Icons.shield_moon_outlined,
            color: Color(0xFFB58CFF),
          ),
          title: const Text('Be Tail End Charlie?'),
          content: const Text(
            'The ride leader has asked you to ride at the back as Tail End '
            'Charlie.\n\n'
            'It means you are the back-marker: the group is complete when you '
            'are there, the leader sees the distance back to you, and a rider '
            'who falls a long way behind is routed to you.\n\n'
            'Nobody covers the back until you accept.',
          ),
          actions: [
            TextButton(
              key: const Key('decline-tec-role-button'),
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Not me'),
            ),
            FilledButton(
              key: const Key('accept-tec-role-button'),
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('I will take it'),
            ),
          ],
        ),
      );
      if (accepted == null) {
        // Dismissed without answering: the request is still open, so let it be
        // offered again rather than silently swallowing it.
        _promptedTecRequestIds.remove(request.requestId);
        return;
      }
      await widget.rideController.respondToTecRoleRequest(
        requestId: request.requestId,
        accepted: accepted,
      );
    } finally {
      _tecRequestPromptOpen = false;
    }
  }

  /// Opens the route's manoeuvre list while the map is in navigation mode and
  /// its own menu is hidden. It reads persisted route data only.
  void _openManeuverList() {
    unawaited(
      ManeuverListScreen.show(
        context,
        route: _activeRoute,
        distanceUnit: widget.distanceUnits.value,
        riderPosition: _mapPosition.value,
      ),
    );
  }

  Future<void> _openObserverAccess() async {
    final controller = _observerAccessController;
    if (controller == null) return;
    await ObserverAccessSheet.show(context, controller);
    if (!mounted || !controller.hasActiveGrants) return;
    await _locationController?.requestAndStart();
    _publishObserverSnapshot();
  }

  void _publishObserverSnapshot() {
    final controller = _observerAccessController;
    final session = widget.rideController.session;
    if (controller == null || session == null || !controller.hasActiveGrants) {
      return;
    }
    final sample = _latestObserverLocationSample;
    controller.publishSnapshot(
      buildLocalObserverSnapshot(
        session: session,
        snapshotGeneratedAt: controller.nextSnapshotGeneratedAt(),
        rideStatus: widget.rideController.rideEnded
            ? 'ended'
            : widget.rideController.ridePaused
            ? 'paused'
            : widget.rideController.rideStarted
            ? 'active'
            : 'waiting',
        statusUpdatedAt: _observerStatusUpdatedAt(),
        assistanceUpdatedAt: controller.localAssistanceUpdatedAt,
        localLocation: sample,
        assistance: controller.localAssistance,
      ),
    );
  }

  DateTime _observerStatusUpdatedAt() {
    for (final event in widget.rideController.events.reversed) {
      if (event.type == RideEventType.rideStarted ||
          event.type == RideEventType.ridePaused ||
          event.type == RideEventType.rideResumed ||
          event.type == RideEventType.rideEnded) {
        return event.createdAt;
      }
    }
    return widget.rideController.session?.joinedAt ?? DateTime.now();
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
    onSendQuickMessage: _sendLocalQuickMessage,
    localObserverAssistanceActive:
        _observerAccessController?.localAssistance != null,
    serviceWarning: _warnings.isEmpty ? null : _warnings.join('\n'),
    connectivity: _connectivitySummary,
  );

  /// The one connectivity answer, built here because this is the only place that
  /// sees both channels: the event batch's own status and the presence channel's
  /// verdict on live positions (#174).
  RideConnectivitySummary? get _connectivitySummary {
    final internet = _internetRelayController;
    if (internet == null) return null;
    final status = internet.status;
    return RideConnectivitySummary.from(
      transportActive:
          status.phase != InternetRelayPhase.unconfigured &&
          status.phase != InternetRelayPhase.stopped,
      positionsPaused: widget.rideController.positionChannelUnavailable,
      queuedEventCount: status.pendingEventCount,
      lastSuccessfulSync: status.lastSuccessfulSync,
      now: DateTime.now(),
    );
  }

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
      trafficRerouteHazards: _trafficRerouteHazards,
      trafficRerouting: _trafficRerouting,
      trafficRerouteError: _trafficRerouteError,
      onReviewTrafficAlternative: _trafficRerouteHazards.isEmpty
          ? null
          : _reviewTrafficAlternative,
      onDismissTrafficAlternative: _trafficRerouteHazards.isEmpty
          ? null
          : _dismissTrafficAlternative,
      // Issue #102: the affected rider's own rejoin guidance, including the
      // honest "routing is unavailable" case.
      rejoinGuidance: _rejoinGuidance,
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
    WidgetsBinding.instance.removeObserver(this);
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
    _externalHazardTimer?.cancel();
    _markerExitChromeTimer?.cancel();
    _locationController?.removeListener(_onDeviceLocationChanged);
    _locationController?.dispose();
    unawaited(_relayController?.close());
    unawaited(_internetRelayController?.close());
    unawaited(_preStartPresenceController?.close());
    _pushNotificationController?.removeListener(
      _onPushNotificationStatusChanged,
    );
    unawaited(_pushNotificationController?.close());
    _observerAccessController?.dispose();
    _mapPosition.dispose();
    _mapNavigationPosition.dispose();
    _mapOverlays.dispose();
    _riderTrails.dispose();
    _quickMessageAlerts.dispose();
    _leaderStatus.dispose();
    _tecGapTrend.dispose();
    _junctionMarkerOverlay.dispose();
    _enforcementAlert.dispose();
    unawaited(_carPlayBridge?.dispose());
    super.dispose();
  }
}

LocationSample? _newestLocationSample(
  LocationSample? journalSample,
  LocationSample? deviceSample,
) {
  if (journalSample == null) return deviceSample;
  if (deviceSample == null) return journalSample;
  return deviceSample.recordedAt.isAfter(journalSample.recordedAt)
      ? deviceSample
      : journalSample;
}

String _trafficDurationLabel(Duration duration) {
  final minutes = (duration.inSeconds / 60).round();
  if (minutes < 1) return '${duration.inSeconds} sec';
  if (minutes < 60) return '$minutes min';
  final hours = minutes ~/ 60;
  final remainder = minutes % 60;
  return remainder == 0 ? '$hours hr' : '$hours hr $remainder min';
}
