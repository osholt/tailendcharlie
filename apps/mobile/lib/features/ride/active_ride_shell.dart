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
import '../../controllers/road_rating_controller.dart';
import '../../controllers/ride_push_notification_controller.dart';
import '../../controllers/ride_simulation_controller.dart';
import '../../controllers/rider_profile_controller.dart';
import '../../controllers/shared_route_controller.dart';
import '../../controllers/spoken_guidance_controller.dart';
import '../../controllers/speed_limit_display_controller.dart';
import '../../controllers/test_control_controller.dart';
import '../../controllers/situational_awareness_controller.dart';
import '../../data/in_memory_event_store.dart';
import '../../data/json_file_route_store.dart';
import '../../data/secure_observer_grant_store.dart';
import '../../domain/event_store.dart';
import '../../domain/geo_point.dart' as awareness_geo;
import '../../domain/hazard.dart';
import '../../domain/imported_route.dart' as route_domain;
import '../../domain/quick_message.dart';
import '../../domain/ride_coordination_mode.dart';
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
import '../../relay/relay_engine.dart';
import '../../relay/sqlite_relay_queue.dart';
import '../../services/carplay_bridge.dart';
import '../../services/carplay_tec_status.dart';
import '../../services/spoken_guidance.dart';
import '../../services/test_control_registry.dart';
import '../../services/basemap_configuration.dart';
import '../../services/demo_route_loader.dart';
import '../../services/device_location_source.dart';
import '../../services/external_hazard_provider.dart';
import '../../services/gpx_import_source.dart';
import '../../services/leader_ride_status.dart';
import '../../services/measurement_formatter.dart';
import '../../services/native_push_token_source.dart';
import '../../services/position_report_policy.dart';
import '../../services/received_quick_message.dart';
import '../../services/navigation_guidance.dart';
import '../../services/route_decision_point_extractor.dart';
import '../../services/ride_completion_detector.dart';
import '../../services/route_progress.dart';
import '../../services/ride_membership.dart';
import '../../services/ride_screen_awake.dart';
import '../../services/enforcement_alert_detector.dart';
import '../../services/hazard_map_relevance.dart';
import '../../services/relay_traffic_hazard_provider.dart';
import '../../services/relay_traffic_reroute_provider.dart';
import '../../services/rejoin_route_share.dart';
import '../../services/rider_contact_share.dart';
import '../../services/road_routing.dart';
import '../../services/ride_connectivity_summary.dart';
import '../../services/tec_gap_trend.dart';
import '../../services/route_rejoin_planner.dart';
import '../../services/trail_display_simplifier.dart';
import '../map/hazard_map_symbol.dart';
import '../map/maneuver_list_screen.dart';
import '../map/motorcycle_icon.dart';
import '../map/ride_map.dart';
import '../map/route_review_screen.dart';
import '../settings/emergency_info_sheet.dart';
import '../settings/notification_preferences_sheet.dart';
import 'ice_share_inbox_sheet.dart';
import '../situational_awareness/situational_awareness_screen.dart';
import '../simulation/ride_simulation_screen.dart';
import 'end_ride_confirmation.dart';
import 'ended_ride_screen.dart';
import 'observer_access_sheet.dart';
import 'ride_dashboard.dart';
import 'ride_roster_sheet.dart';

/// The only thing an observer link publishes.
///
/// Its argument list is the privacy boundary: an observer is a separate
/// authorisation decision (#36), so nothing that a rider shared *inside* the
/// ride is an input here. That covers the ICE contact, a rejoin breadcrumb
/// (#128) and a rider's own phone number (#188) — none of them has a parameter
/// to populate, by accident or otherwise.
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

/// The leader-published, bounded whole-group watcher snapshot.
///
/// This deliberately accepts only the reconciled live roster, current rendered
/// positions and planned route. Durable events, trails, nearby identifiers,
/// contact/ICE state and ride credentials are not inputs, so they cannot leak
/// into a watcher response by accident.
@visibleForTesting
ObserverPublishedSnapshot buildGroupObserverSnapshot({
  required RideSession session,
  required DateTime snapshotGeneratedAt,
  required String rideStatus,
  required DateTime statusUpdatedAt,
  required DateTime assistanceUpdatedAt,
  required Iterable<RideParticipant> liveParticipants,
  required Iterable<RiderLocation> renderedPositions,
  required LocationSample? localLocation,
  required route_domain.ImportedRoute? route,
}) {
  final positionsByRider = {
    for (final location in renderedPositions) location.riderId: location.sample,
  };
  if (localLocation != null) {
    positionsByRider[session.localRiderId] = localLocation;
  }
  final participants = liveParticipants
      .take(50)
      .map((participant) {
        final sample = positionsByRider[participant.riderId];
        final color = participant.riderColor.color
            .toARGB32()
            .toRadixString(16)
            .padLeft(8, '0')
            .substring(2)
            .toUpperCase();
        return ObserverPublishedGroupParticipant(
          displayName: _boundedObserverText(participant.displayName, 80),
          role: participant.role.name,
          color: '#$color',
          position: sample == null
              ? null
              : ObserverPublishedPosition(
                  latitude: sample.position.latitude,
                  longitude: sample.position.longitude,
                  accuracyMeters: sample.accuracyMeters,
                  recordedAt: sample.recordedAt,
                ),
        );
      })
      .toList(growable: false);
  final routePoints = _boundedObserverRoutePoints(route);
  return ObserverPublishedSnapshot(
    scope: ObserverAccessScope.group,
    subjectName: _boundedObserverText(
      session.rideName ?? 'Group ride led by ${session.displayName}',
      80,
    ),
    snapshotGeneratedAt: snapshotGeneratedAt,
    rideStatus: rideStatus,
    statusUpdatedAt: statusUpdatedAt,
    assistanceUpdatedAt: assistanceUpdatedAt,
    participants: participants,
    route: route == null || routePoints.length < 2
        ? null
        : ObserverPublishedRoute(
            name: _boundedObserverText(route.name, 80),
            points: routePoints,
          ),
  );
}

String _boundedObserverText(String value, int maximumLength) {
  final trimmed = value.trim();
  if (trimmed.length <= maximumLength) return trimmed;
  return trimmed.substring(0, maximumLength);
}

List<ObserverPublishedRoutePoint> _boundedObserverRoutePoints(
  route_domain.ImportedRoute? route, {
  int maximum = 500,
}) {
  if (route == null || maximum < 2) return const [];
  final source = [
    for (final path in route.paths)
      for (final point in path.points) point,
    if (route.paths.isEmpty)
      for (final waypoint in route.waypoints) waypoint.point,
  ];
  if (source.length < 2) return const [];
  final indexes = source.length <= maximum
      ? List<int>.generate(source.length, (index) => index)
      : List<int>.generate(
          maximum,
          (index) => (index * (source.length - 1) / (maximum - 1)).round(),
        );
  return List.unmodifiable([
    for (final index in indexes)
      ObserverPublishedRoutePoint(
        latitude: source[index].latitude,
        longitude: source[index].longitude,
      ),
  ]);
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
    this.roadRatings,
    this.testControl,
    this.testControlRegistry,
    this.spokenGuidance,
  });

  final RideController rideController;

  /// Both null unless this build carries the test-control define. The shell
  /// forwards [testControl] to the settings sheet and publishes each
  /// situational-awareness controller it creates into [testControlRegistry], so
  /// the driven surface always talks to the live one.
  final TestControlController? testControl;
  final TestControlRegistry? testControlRegistry;

  /// Whether turn instructions are spoken. Null in surfaces that do not offer it,
  /// which is treated as off (#286).
  final SpokenGuidanceController? spokenGuidance;

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

  /// Drives the end-of-ride catalogued-road rating card (#159). Null in a build
  /// with no catalogue service configured, and the card is then never built.
  final RoadRatingController? roadRatings;

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
    required this.hasOwnPhoneNumber,
    required this.ownPhoneNumberShared,
    required this.ownPhoneNumberRecipientLabel,
    required this.onShareOwnPhoneNumber,
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

  /// #188. The tile is always shown, because "you have not added a number" is
  /// worth saying: a rider who never sees the control cannot know the option
  /// exists, and the emergency sheet's silence would look like a fault.
  final bool hasOwnPhoneNumber;
  final bool ownPhoneNumberShared;
  final String ownPhoneNumberRecipientLabel;
  final VoidCallback onShareOwnPhoneNumber;
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
                title: const Text('Share watcher link'),
                subtitle: const Text(
                  'Private, read-only web view for a trusted contact',
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
              key: const Key('ride-menu-share-own-number'),
              leading: const Icon(Icons.phone_forwarded_outlined),
              title: Text(
                ownPhoneNumberShared
                    ? 'Your number is shared'
                    : 'Share my phone number',
              ),
              subtitle: Text(
                !hasOwnPhoneNumber
                    ? 'Optional. Add your number first, so they can ring you '
                          'if you stop'
                    : ownPhoneNumberShared
                    ? 'Sent to $ownPhoneNumberRecipientLabel for this ride. '
                          'Cleared when the ride ends'
                    : 'Gives it to $ownPhoneNumberRecipientLabel for this ride '
                          'only',
              ),
              onTap: () {
                Navigator.of(context).pop();
                onShareOwnPhoneNumber();
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
    required this.coordinationMode,
    required this.isLeader,
    required this.busy,
    required this.routeName,
    required this.onStartRide,
    required this.onChooseRoute,
  });

  final String rideCode;
  final List<RideParticipant> participants;
  final RideCoordinationMode coordinationMode;
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
                Icon(
                  coordinationMode == RideCoordinationMode.solo
                      ? Icons.person_outline
                      : Icons.groups_outlined,
                  color: const Color(0xFFFFC857),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        coordinationMode == RideCoordinationMode.solo
                            ? 'Ready for solo ride'
                            : 'Waiting to start',
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                      Text(
                        coordinationMode == RideCoordinationMode.solo
                            ? 'Tracking begins when you start'
                            : 'Ride $rideCode · Current positions only until the leader starts',
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
            if (coordinationMode.isGroup) ...[
              const SizedBox(height: 4),
              Row(
                key: const Key('pre-start-roster'),
                children: [
                  const Icon(
                    Icons.people_outline,
                    size: 17,
                    color: Color(0xFFA9B4C2),
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      '${participants.length} ready'
                      '${participants.isEmpty ? '' : ' · ${participants.map((participant) => '${participant.displayName}${participant.isLocal ? ' (you)' : ''}').join(', ')}'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFFA9B4C2),
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    ),
  );
}

enum _StartRideDecision { cancel, chooseRoute, start }

enum _MissingTecDecision { cancel, assignTec, startAnyway }

@visibleForTesting
enum RideExitDecision { cancel, leave, endForEveryone }

@visibleForTesting
enum RideCompletionDecision { continueRide, endForEveryone }

@visibleForTesting
Future<RideExitDecision?> showRideExitDialog(
  BuildContext context, {
  required bool isLeader,
}) => showDialog<RideExitDecision>(
  context: context,
  builder: (dialogContext) => AlertDialog(
    title: Text(isLeader ? 'Leave or end this ride?' : 'Leave this ride?'),
    content: Text(
      isLeader
          ? 'Leave only this phone, or end the group ride for everyone.'
          : 'Your location sharing will stop on this phone. The group ride '
                'will continue for everyone else.',
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(dialogContext, RideExitDecision.cancel),
        child: const Text('Cancel'),
      ),
      TextButton(
        key: const Key('leave-only-this-phone'),
        onPressed: () => Navigator.pop(dialogContext, RideExitDecision.leave),
        child: Text(isLeader ? 'Leave only' : 'Leave ride'),
      ),
      if (isLeader)
        FilledButton(
          key: const Key('end-ride-for-everyone'),
          onPressed: () =>
              Navigator.pop(dialogContext, RideExitDecision.endForEveryone),
          child: const Text('End for everyone'),
        ),
    ],
  ),
);

@visibleForTesting
Future<RideCompletionDecision?> showRideCompletionDialog(
  BuildContext context, {
  required RideCompletionAssessment assessment,
  required bool relayCanCarryReopen,
}) => showDialog<RideCompletionDecision>(
  context: context,
  barrierDismissible: false,
  builder: (dialogContext) => AlertDialog(
    key: const Key('ride-completion-suggestion'),
    icon: const Icon(Icons.flag_circle_outlined),
    title: const Text('Has everyone finished?'),
    content: Text(
      '${assessment.arrivedRiderCount} of ${assessment.riderCount} riders have '
      'fresh positions within ${assessment.destinationRadiusMeters.round()} m '
      'of the destination, and '
      '${(assessment.routeProgressFraction * 100).clamp(0, 100).round()}% of '
      'the route has been completed.\n\n'
      '${relayCanCarryReopen ? 'If this is wrong, the leader can resume this ride within 24 hours without changing its code.' : 'This relay cannot resume an ended ride on the other phones. Only end when the whole group is definitely finished.'}',
    ),
    actions: [
      TextButton(
        key: const Key('continue-completed-ride'),
        onPressed: () =>
            Navigator.pop(dialogContext, RideCompletionDecision.continueRide),
        child: const Text('Continue ride'),
      ),
      FilledButton(
        key: const Key('confirm-completed-ride'),
        onPressed: () =>
            Navigator.pop(dialogContext, RideCompletionDecision.endForEveryone),
        child: const Text('End for everyone'),
      ),
    ],
  ),
);

class _ActiveRideShellState extends State<ActiveRideShell>
    with WidgetsBindingObserver {
  final _mapPosition = ValueNotifier<route_domain.GeoPoint?>(null);
  final _mapNavigationPosition = ValueNotifier<MapNavigationPosition?>(null);
  final _mapOverlays = ValueNotifier<List<MapOverlayMarker>>(const []);
  final _riderTrails = ValueNotifier<List<MapOverlayTrace>>(const []);
  final _carPlayRouteProgressTracker = RouteProgressTracker();
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
  final _dismissedQuickMessageInterruptIds = <String>{};
  final _dismissedQuickMessageReceiptIds = <String>{};

  // The active-ride tabs are a `switch` on the selected index, not an
  // IndexedStack, so moving to Ride details and back disposes and rebuilds the
  // map. Anything the rider has decided that lives in the map's own State is
  // therefore undone by a tab change - which is what a tester hit: cleared
  // enforcement alerts coming back, and an accepted route-start leg having to be
  // accepted again (#282). These live here because this shell outlives the tabs.
  String? _dismissedEnforcementAlertId;
  route_domain.ImportedRoute? _routeStartConnector;

  /// Built only in a surface that offers spoken guidance. The engine itself is
  /// not touched until something is actually spoken, so a rider who leaves the
  /// option off never has a speech engine initialised behind their back.
  SpokenGuidanceSpeaker? _spokenGuidance;
  final _trailRecorder = RiderTrailRecorder();
  final _publishedEventIds = <String>{};
  final _warnings = <String>{};
  static const _backgroundLocationWarning =
      'Background GPS is limited. In iPhone Settings, allow Location → Always '
      'before using another navigation app; otherwise your group position and '
      'recorded trail may pause.';
  final _rideCompletionDetector = RideCompletionDetector();
  bool _completionPromptedForArrival = false;

  /// Progress along the active route, used only to arm the automatic ride end.
  ///
  /// Deliberately the shell's own tracker rather than the map's: completion has
  /// to work when the map is not the visible tab, and the map's tracker is tied
  /// to that widget's lifecycle. Both are monotonic and fed the same fixes, so
  /// they agree.
  final _completionProgressTracker = RouteProgressTracker();
  late final RouteRejoinPlanner _rejoinPlanner;
  Future<void> _rejoinChain = Future.value();
  String? _rejoinGuidance;
  final _rejoinNavigationRoute = ValueNotifier<route_domain.ImportedRoute?>(
    null,
  );

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
  String? _carPlayMapStyleJson;
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
  int _observedNearbyPublishEventCount = -1;
  bool _nearbyPublishWorkPending = true;
  bool _nearbyPublishInFlight = false;
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
  PendingInAppRoute? _pendingInAppRoute;
  int _handledAutomaticMarkerActivation = 0;
  int _handledAutomaticMarkerRideOffActivation = 0;
  DateTime? _lastSimulationNavigationUpdateAt;
  DateTime? _lastSimulationOverlayUpdateAt;
  LocationSample? _latestObserverLocationSample;

  /// Decides which device fixes become durable position reports (#166).
  ///
  /// It gates the journal only. The observer snapshot and the ephemeral presence
  /// channel above it see every fix, so a rider stays continuously visible while
  /// the expensive half of reporting follows distance travelled.
  final PositionReportGate _positionReportGate = PositionReportGate();
  bool _loading = true;
  bool _relayConfigured = false;
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
    } else if (widget.sharedRoutes.pendingInAppRoute case final route?) {
      if (widget.rideController.isLocalRideLeader) {
        _selectedIndex = 0;
        _changeRouteRequestToken = Object();
        _pendingInAppRoute = route;
      } else {
        _warnings.add('Only the ride leader can replace the group route.');
      }
      _clearSharedRoutePending();
    }
    unawaited(_initialize());
    _carPlayBridge = CarPlayBridge(
      onEmergencyTriggered: _sendEmergencyMapAlert,
      onTecRoleAnswered: _answerTecRoleRequestFromCarPlay,
      onStateRequested: () async {
        if (!mounted) return;
        _updateMapOverlays(updateDerivedState: false);
      },
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
    final inAppRoute = widget.sharedRoutes.pendingInAppRoute;
    if (file == null && inAppRoute == null) {
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
      _pendingInAppRoute = inAppRoute;
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
          ).timeout(_localRouteRestoreTimeout);
          route = await _rideRouteStore!.loadActiveRoute().timeout(
            _localRouteRestoreTimeout,
          );
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
        _rideRouteStore = InMemoryRouteStore();
        _warnings.add('Route storage could not be opened: $error');
        final authoritative = widget.rideController.authoritativeRouteState;
        _appliedAuthoritativeRouteRevision = authoritative.revisionId;
        if (authoritative.hasDecision) route = authoritative.route;
      }
    }

    _activeRoute = route;
    if (!mounted) return;

    // The map depends only on its ride-scoped route store. It must not leave a
    // full-screen spinner up while GPS, push, internet presence or nearby
    // transport start in the background. This frame is the escape hatch for a
    // transport plugin that never returns on a particular Android phone
    // (#209).
    setState(() => _loading = false);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;

    try {
      await _initializeTrafficRerouting();
    } on Object catch (error) {
      _warnings.add('Traffic preferences could not be restored: $error');
    }
    try {
      await _replaceAwarenessController(route);
    } on Object catch (error) {
      _warnings.add('Ride map history could not be restored: $error');
    }
    if (_isSimulation) {
      try {
        await _replaceSimulationController(route);
      } on Object catch (error) {
        _warnings.add('Ride Lab could not be restored: $error');
      }
    }
    if (publishStoredLeaderRoute && route != null) {
      try {
        await widget.rideController.publishRoute(route);
        _appliedAuthoritativeRouteRevision =
            widget.rideController.authoritativeRouteState.revisionId;
      } on Object catch (error) {
        _warnings.add('The stored group route could not be published: $error');
      }
    }
    if (!mounted) return;

    if (widget.enableNativeServices && !_isSimulation) {
      final session = widget.rideController.session;
      final groupRide = widget.rideController.coordinationMode.isGroup;
      if (groupRide && session?.role == RideRole.lead) {
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
          // One decision, taken once, for both halves of reporting: distance
          // travelled, a turn, or the keep-alive timer (#166).
          final reported = _positionReportGate.consider(sample);
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
                riderSymbol: currentSession.riderSymbol,
                riderColor: currentSession.riderColor,
              ),
              // A withheld fix is still held as the newest position and still
              // goes out on the next presence tick; it just does not bring that
              // tick forward. Presence itself never waits for movement.
              publishImmediately: reported != null,
            );
          }
          final startedAt = widget.rideController.rideStartedAt;
          if (startedAt == null || sample.recordedAt.isBefore(startedAt)) {
            return;
          }
          // A withheld fix is not a lost fix: the presence channel above has it,
          // so the only thing not happening here is a journal event nobody
          // needed.
          if (reported == null) return;
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
      } else {
        await _startLocationForPreStartMap();
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
        if (groupRide) {
          final pushNotificationController = RidePushNotificationController(
            tokenSource:
                widget.pushTokenSource ??
                NativePushTokenSource(
                  NativePushConfiguration.fromEnvironment(),
                ),
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
      }
      if (groupRide && session != null && session.inviteSecret.length >= 16) {
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
    _schedulePublish();
  }

  /// Route storage is local and normally opens in milliseconds. If the
  /// platform file-service call itself wedges, fall back to an empty in-memory
  /// store so the rider gets controls rather than an indefinite map spinner.
  static const _localRouteRestoreTimeout = Duration(seconds: 2);

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
              // The marker review decides which decision points the live
              // detector may suggest, so rejecting one has to rebuild it (#179).
              '${route.pathPointCount}:${route.markerReview.signature}';
    final lifecycleFingerprint =
        widget.rideController.rideStartedAt?.toUtc().toIso8601String() ??
        'open';
    final effectiveFingerprint =
        '$fingerprint:$lifecycleFingerprint:'
        '${widget.rideController.coordinationMode.name}';
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
      onEventStored: widget.rideController.ingestStoredEvent,
    );
    await controller.initialize(restoredEvents: widget.rideController.events);
    if (!mounted || generation != _routeGeneration) {
      controller.dispose();
      return;
    }
    // Publish only after the generation check: a controller built for a
    // superseded route is disposed above, and driving a disposed controller is
    // exactly the stale-reference bug TestControlRegistry exists to avoid.
    widget.testControlRegistry?.publish(controller);

    MarkerAssistanceController? markerController;
    if (widget.rideController.coordinationMode.usesSecondBikeDropOff) {
      final markerRoute = _markerRouteFor(route);
      final markerReview =
          route?.markerReview ?? route_domain.MarkerPlanReview.empty;
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
        rejectedPositions: markerReview.rejected
            .map(
              (point) => awareness_geo.GeoPoint(
                latitude: point.position.latitude,
                longitude: point.position.longitude,
              ),
            )
            .toList(growable: false),
        addedPositions: markerReview.added
            .map(
              (point) => ExplicitDecisionPoint(
                position: awareness_geo.GeoPoint(
                  latitude: point.position.latitude,
                  longitude: point.position.longitude,
                ),
                label: point.label,
              ),
            )
            .toList(growable: false),
      );
      markerController = MarkerAssistanceController(
        widget.rideController,
        controller,
        route: markerRoute,
        decisionPoints: decisionPoints,
      )..initialize();
    }

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
              // The marker review decides which decision points the live
              // detector may suggest, so rejecting one has to rebuild it (#179).
              '${route.pathPointCount}:${route.markerReview.signature}';
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
    final liveView = widget.rideController.liveView;
    final participants = {
      for (final participant in liveView.participants)
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
        : liveView.renderedPositions;
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
    unawaited(_maybeAutomaticallyEndRide(awareness, mapPoint));
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
    // Issue #135. Judged once, here, so the MapLibre renderer and the
    // flutter_map fallback are handed the same decision rather than each
    // deciding for itself what is ahead and what a camera looks like (#141).
    final now = DateTime.now();
    final hazardJudgements = const HazardMapRelevance().judgeAll(
      reports: awareness.activeHazards,
      riderPosition: localLocation?.sample.position,
      headingDegrees: localLocation?.sample.headingDegrees,
      route: awareness.route,
      now: now,
    );
    final overlays = <MapOverlayMarker>[
      for (final judgement in hazardJudgements)
        if (judgement.isVisible) _hazardOverlayMarker(judgement.report, now),
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
                        riderSymbol: location.riderSymbol,
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
                        riderSymbol: rider.riderSymbol,
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
            final isTec = _effectiveTecRiderIds.contains(location.riderId);
            final isLead = location.role == RideRole.lead;
            // A position past its freshness threshold is demoted explicitly in
            // the label. The identity fill remains stable across surfaces.
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
            // raised rather than inventing a second symbol beside it.
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
            // The roster, both maps and trails share this one identity colour.
            // Role and alerts are already named in [label]; changing the fill
            // made one rider look like different people across surfaces (#250).
            final baseColor = location.riderColor.color;
            return MapOverlayMarker(
              id: 'rider-${location.riderId}',
              point: location.point,
              label: label,
              motorcycleStyle: location.motorcycleStyle,
              riderSymbol: location.riderSymbol,
              riderDisplayName: location.displayName,
              color: baseColor,
            );
          }),
    ];
    _mapOverlays.value = List.unmodifiable(overlays);
    _enforcementAlert.value = const EnforcementAlertDetector().detect(
      position: localLocation?.sample.position,
      headingDegrees: localLocation?.sample.headingDegrees,
      route: awareness.route,
      hazards: awareness.activeHazards,
      now: now,
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
              registeredTecRiderIds: _effectiveTecRiderIds,
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
    // Published after the leader status and the gap trend, not before: a
    // snapshot built first would carry the previous frame's back-marker, so
    // the head unit would always be one update behind the phone about the one
    // thing the app is named after.
    _publishCarPlaySnapshot(
      awareness: awareness,
      visibleRiderLocations: visibleRiderLocations,
      activeRiderIds: activeRiderIds,
    );
    _updateSharedRejoinTraces();
  }

  /// Projects the ride onto CarPlay, including the back-marker.
  ///
  /// The TEC is resolved through [LeaderRideStatusCalculator.resolveTecTarget]
  /// rather than read off the rider list, for the same reason every other
  /// surface does: "nobody is TEC", "registered but never reported" and "last
  /// fix too old to trust" are three different answers and a car screen must
  /// not blur them into a missing row. [_leaderStatus] then adds the gap and
  /// the trend, and is null for everyone who is not the leader — that means
  /// this device has no gap to show, never that there is no TEC.
  void _publishCarPlaySnapshot({
    required SituationalAwarenessController awareness,
    required List<RiderLocation> visibleRiderLocations,
    required Set<String> activeRiderIds,
  }) {
    final bridge = _carPlayBridge;
    if (bridge == null) return;
    final session = widget.rideController.session;
    final effectiveTecRiderIds = _effectiveTecRiderIds;
    // Ride Lab drives a virtual roster and has no relayed requests to answer.
    final pendingTecRequest = _isSimulation
        ? null
        : widget.rideController.pendingTecRoleRequestForLocalRider;
    final tec = session == null
        ? CarPlayTecStatus.absent
        : CarPlayTecStatus.from(
            target: const LeaderRideStatusCalculator().resolveTecTarget(
              localRiderId: session.localRiderId,
              riderLocations: visibleRiderLocations,
              registeredTecRiderIds: effectiveTecRiderIds,
              assignedTecRiderId: _assignedTecRiderId,
              now: DateTime.now(),
            ),
            leaderStatus: _leaderStatus.value,
            trend: _tecGapTrend.value,
            distanceUnit: widget.distanceUnits.value,
            now: DateTime.now(),
          );
    final navigationRoute = _rejoinNavigationRoute.value ?? _activeRoute;
    final routeProgress = _carPlayRouteProgressTracker.update(
      navigationRoute,
      _mapPosition.value,
    );
    final selectedBasemap = BasemapConfiguration.fromEnvironment()
        .forBrightness(
          dark: widget.mapStyleMode.resolveDark(
            MediaQuery.platformBrightnessOf(context),
          ),
        );
    final markerOverlay = _junctionMarkerOverlay.value;
    final marker = markerOverlay == null
        ? null
        : CarPlayMarkerStatus(
            stage: markerOverlay.stage.name,
            title: switch (markerOverlay.stage) {
              MapJunctionMarkerStage.waitingForRiders => 'Hold this junction',
              MapJunctionMarkerStage.tecApproaching => 'TEC approaching',
              MapJunctionMarkerStage.readyToRideOff => 'Ride off now',
            },
            detail: [
              '${markerOverlay.ridersPassed}/${markerOverlay.ridersExpected} riders passed',
              if (markerOverlay.tecDistanceMeters case final distance?)
                'TEC ${MeasurementFormatter(widget.distanceUnits.value).distance(distance)} away',
            ].join(' · '),
            ridersPassed: markerOverlay.ridersPassed,
            ridersExpected: markerOverlay.ridersExpected,
            tecDistanceMeters: markerOverlay.tecDistanceMeters,
          );
    unawaited(
      bridge.publish(
        session: session,
        riderLocations: visibleRiderLocations,
        routeAlerts: awareness.routeAlerts
            .where((alert) => activeRiderIds.contains(alert.riderId))
            .toList(growable: false),
        activeHazards: awareness.activeHazards,
        route: navigationRoute,
        routeName: navigationRoute?.name,
        rideState: _projectedRideState,
        followRider:
            widget.rideController.rideStarted &&
            !widget.rideController.rideEnded,
        guidanceTitle: _projectedGuidanceTitle,
        guidanceDetail: _projectedGuidanceDetail,
        guidanceRoadName: _latestNavigationGuidance?.roadLabel,
        guidanceDistanceMeters: _latestNavigationGuidance?.distanceMeters,
        distanceUnit: widget.distanceUnits.value,
        groupStatus: '${visibleRiderLocations.length} riders visible',
        markerStatus: markerOverlay?.instruction,
        marker: marker,
        tec: tec,
        effectiveTecRiderIds: effectiveTecRiderIds,
        basemap: selectedBasemap,
        mapStyleJson: _carPlayMapStyleJson,
        localPosition: _mapPosition.value,
        localHeadingDegrees: _mapNavigationPosition.value?.headingDegrees,
        routeProgress: routeProgress,
        tecRequest: pendingTecRequest == null
            ? null
            : CarPlayTecRequest(
                requestId: pendingTecRequest.requestId,
                leaderName: widget.rideController
                    .participantFor(pendingTecRequest.leaderRiderId)
                    ?.displayName,
              ),
      ),
    );
  }

  /// Answers a leader's TEC request from the head unit (#128).
  ///
  /// The same call the phone's roster sheet makes, so the journal cannot tell
  /// the two apart: accepting records the answer *and* this rider's own
  /// `roleChanged`, and the reducer still admits an answer only from the rider
  /// the request named. A stale alert — the request expired, was superseded, or
  /// was already answered on the phone — is rejected there rather than here,
  /// which is why this passes the request id straight through.
  Future<void> _answerTecRoleRequestFromCarPlay(
    String requestId,
    bool accepted,
  ) async {
    if (_isSimulation) return;
    await widget.rideController.respondToTecRoleRequest(
      requestId: requestId,
      accepted: accepted,
    );
    if (!mounted) return;
    _updateMapOverlays(updateNavigationPosition: false);
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

  /// One effective back-marker. A leader-requested TEC wins over an older
  /// self-selection, so the roster, map, gap, rejoin and contact targets do not
  /// simultaneously treat two riders as the back of one group (#128).
  Set<String> get _effectiveTecRiderIds {
    final registered = _registeredTecRiderIds;
    final assigned = _assignedTecRiderId;
    final assignedParticipant = assigned == null
        ? null
        : widget.rideController.participantFor(assigned);
    if (assignedParticipant?.isIncludedInLiveCount == true) return {assigned!};
    return registered;
  }

  Future<void> _maybeAutomaticallyEndRide(
    SituationalAwarenessController awareness,
    route_domain.GeoPoint? localPosition,
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
    // Monotonic progress along the plan, not proximity to its last point. On a
    // loop the two are the same thing at the start line (#206).
    final progress = _completionProgressTracker.update(route, localPosition);
    final assessment = _rideCompletionDetector.assess(
      destination: awareness_geo.GeoPoint(
        latitude: destination.latitude,
        longitude: destination.longitude,
      ),
      riderLocations: awareness.riderLocations,
      now: DateTime.now(),
      routeProgressFraction: progress.totalMeters <= 0
          ? 0
          : progress.progressMeters / progress.totalMeters,
    );
    if (!assessment.ready) {
      _completionPromptedForArrival = false;
      return;
    }
    // A dismissed suggestion stays dismissed while the group remains inside
    // the destination radius. Leaving and returning arms a fresh suggestion.
    if (_completionPromptedForArrival) return;
    _completionPromptedForArrival = true;
    _autoEndingRide = true;
    try {
      if (!mounted) return;
      final decision = await showRideCompletionDialog(
        context,
        assessment: assessment,
        relayCanCarryReopen: _relayCanCarryReopen,
      );
      if (decision == RideCompletionDecision.endForEveryone) {
        await widget.rideController.endRide();
      }
    } catch (error, stackTrace) {
      if (kDebugMode) {
        debugPrint('Could not offer ride completion: $error\n$stackTrace');
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
                ? [
                    for (final sample in awareness.leaderTrailSamples)
                      route_domain.GeoPoint(
                        latitude: sample.position.latitude,
                        longitude: sample.position.longitude,
                        recordedAt: sample.recordedAt,
                      ),
                  ]
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
        _setRejoinPlan(null);
        return;
      }
      // The TEC is resolved through the one availability model (#113) rather
      // than a null check, so "nobody is TEC", "registered but never reported"
      // and "last fix too old to trust" all fall back to the leader.
      final tec = const LeaderRideStatusCalculator().resolveTecTarget(
        localRiderId: session.localRiderId,
        riderLocations: awareness.riderLocations,
        registeredTecRiderIds: _effectiveTecRiderIds,
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
        plan.severity == RouteRejoinSeverity.onRoute ? null : plan,
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

  void _setRejoinPlan(RouteRejoinPlan? plan) {
    final guidance = plan?.guidance;
    final trace = plan?.hasBreadcrumb ?? false
        ? MapOverlayTrace(
            id: 'rejoin-${plan!.riderId}',
            points: _routePoints(plan.breadcrumb),
            label: 'Advisory rejoin route',
            kind: RiderTrailKind.rejoin,
          )
        : null;
    if (trace != _rejoinTrace) {
      _rejoinTrace = trace;
      _pushRiderTrails();
    }
    final navigationRoute = rejoinNavigationRoute(plan);
    if (_rejoinNavigationRoute.value?.id != navigationRoute?.id) {
      _rejoinNavigationRoute.value = navigationRoute;
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
        for (final (index, points)
            in _trailRecorder
                .continuousSegments(trail.points)
                .where((segment) => segment.length >= 2)
                .indexed)
          MapOverlayTrace(
            id: index == 0
                ? 'trail-${trail.riderId}'
                : 'trail-${trail.riderId}-$index',
            points: points,
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

  /// One reported hazard as a map marker (#135).
  ///
  /// The symbol - shape, glyph, fill, freshness - is resolved here and travels
  /// on the marker, so both renderers draw the same thing and the tap text is
  /// the same sentence in both.
  static MapOverlayMarker _hazardOverlayMarker(
    HazardReport report,
    DateTime now,
  ) {
    final symbol = HazardMapSymbols.forReport(report, now: now);
    return MapOverlayMarker(
      id: 'hazard-${report.id}',
      point: route_domain.GeoPoint(
        latitude: report.position.latitude,
        longitude: report.position.longitude,
      ),
      label: HazardMapSymbols.describe(report, now: now),
      color: symbol.fill,
      hazardSymbol: symbol,
    );
  }

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
      final awareness = _awarenessController;
      if (awareness == null) {
        widget.rideController.ingestStoredEvent(event);
        return;
      }
      try {
        await awareness.ingestRemoteEvent(event);
      } on Object catch (error, stackTrace) {
        if (kDebugMode) {
          debugPrint(
            'Rejected received situational event: $error\n$stackTrace',
          );
        }
      }
    } else {
      widget.rideController.ingestStoredEvent(event);
    }
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
    // The journal only accepts fixes from the start onwards, so the first fix
    // after the start has nothing to be measured against and must report
    // whatever the rider has or has not moved since.
    if (rideJustStarted) _positionReportGate.reset();
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

  /// Starts location for the map before the ride does, so a rider can see
  /// themselves while the group is still gathering (#300).
  ///
  /// Location used to start only once the ride had, which left the pre-start map
  /// with no own position and no way to get one - reported as "before I started
  /// a ride I couldn't see my own position and there was no way to get it".
  /// Gathering is exactly when a group is checking who has arrived and where
  /// they are.
  ///
  /// **Starting the stream does not start recording.** Fixes reach the map
  /// through `_onDeviceLocationChanged`, which only redraws overlays;
  /// `SituationalAwarenessController.recordLocalLocation` refuses every sample
  /// until `rideStarted`, and relay publishing is driven by the event journal
  /// rather than by fixes. So nothing is journalled or shared before Start ride,
  /// which is the half of the request that must not be broken.
  ///
  /// Deliberately not [_resumeLocationForActiveRide]: that resets the
  /// position-report gate, which paces *sharing*, and there is nothing to pace
  /// yet. A failure here is also silent rather than a warning banner - #262 asks
  /// for a calmer pre-start screen, and Follow me still surfaces a genuine
  /// permission problem when the rider asks for it.
  Future<void> _startLocationForPreStartMap() async {
    final locationController = _locationController;
    if (locationController == null ||
        widget.rideController.rideStarted ||
        widget.rideController.rideEnded) {
      return;
    }
    try {
      await locationController.resumeIfAuthorized();
    } on Object catch (error, stackTrace) {
      if (kDebugMode) {
        debugPrint('Could not start GPS before the ride: $error\n$stackTrace');
      }
    }
  }

  Future<void> _resumeLocationForActiveRide() async {
    final locationController = _locationController;
    if (locationController == null ||
        !widget.rideController.rideStarted ||
        widget.rideController.rideEnded) {
      return;
    }
    // The gap since the last report is not travel, so the next fix reports
    // unconditionally rather than being measured against wherever this rider was
    // when sharing last stopped.
    _positionReportGate.reset();
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
    final status = _locationController?.status;
    final warningChanged =
        status != null && status.canSample && !status.backgroundCapable
        ? _warnings.add(_backgroundLocationWarning)
        : _warnings.remove(_backgroundLocationWarning);
    // The foreground map follows the newest device fix even if writing that
    // sample to the durable ride journal is briefly delayed or fails. Only
    // the journal feeds trails, summaries and GPX recording.
    _updateMapOverlays(updateDerivedState: false, updateOverlayMarkers: false);
    if (warningChanged) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    unawaited(_locationController?.restartAfterForegroundResume());
  }

  void _schedulePublish() {
    final eventCount = widget.rideController.eventCount;
    if (eventCount != _observedNearbyPublishEventCount) {
      _observedNearbyPublishEventCount = eventCount;
      _nearbyPublishWorkPending = true;
    }
    if (!_nearbyPublishWorkPending || _nearbyPublishInFlight) return;
    _nearbyPublishWorkPending = false;
    _nearbyPublishInFlight = true;
    unawaited(() async {
      var retryNeeded = false;
      try {
        retryNeeded = await _publishPendingEvents();
      } finally {
        _nearbyPublishInFlight = false;
        if (retryNeeded) {
          // A later controller or transport notification retries it. Do not
          // spin immediately against an unavailable radio.
          _nearbyPublishWorkPending = true;
        } else if (_nearbyPublishWorkPending) {
          // An event arrived while the scan was running.
          _schedulePublish();
        }
      }
    }());
  }

  /// Returns true when at least one event could not be handed to Nearby.
  Future<bool> _publishPendingEvents() async {
    _internetRelayController?.wake();
    final relay = _relayController;
    final session = widget.rideController.session;
    if (!_relayConfigured || relay == null || session == null) return false;
    var retryNeeded = false;
    // RideController is updated one event at a time as the shared store is
    // written. Walking that in-memory view avoids querying and JSON-decoding
    // the complete SQLite ride on every new position (#165).
    for (final event in widget.rideController.events) {
      if (_publishedEventIds.contains(event.id)) continue;
      try {
        // Bounded, because this is an await on a transport from a chain that a
        // rejoin and a cold start both walk over the whole eligible backlog. A
        // publish that never returns would stall every later event behind it for
        // as long as the app is running, and a phone in that state is
        // indistinguishable from a hung app (#209).
        await relay
            .publish(event)
            .timeout(
              _nearbyPublishTimeout,
              onTimeout: () {
                throw TimeoutException('nearby publish', _nearbyPublishTimeout);
              },
            );
        _publishedEventIds.add(event.id);
      } on Object catch (error) {
        retryNeeded = true;
        if (kDebugMode) {
          debugPrint('Could not queue ${event.id} for nearby relay: $error');
        }
      }
    }
    return retryNeeded;
  }

  /// One nearby publish is a local hand-off to the transport, not a round trip,
  /// so seconds are already generous. The number exists to make "never" and
  /// "slow" different outcomes.
  static const _nearbyPublishTimeout = Duration(seconds: 5);

  @override
  Widget build(BuildContext context) {
    if (widget.rideController.rideEnded) {
      return EndedRideScreen(
        controller: widget.rideController,
        distanceUnits: widget.distanceUnits,
        nearbyRelayController: _relayController,
        internetRelayController: _internetRelayController,
        onRemoveRide: _removeEndedRide,
        roadRatings: widget.roadRatings,
        relayCanCarryReopen: _relayCanCarryReopen,
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
                coordinationMode: widget.rideController.coordinationMode,
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
                    // Wider than the 56 it was, to carry the words. Same
                    // reasoning as the portrait bar: this rail is hidden while
                    // the rider is moving, so its cost is paid only at a
                    // standstill, and four unlabelled icons are what #306 is
                    // about.
                    minWidth: 72,
                    groupAlignment: -0.7,
                    labelType: NavigationRailLabelType.all,
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
                  height: landscape ? 60 : 68,
                  // Named, not four bare icons.
                  //
                  // #306: "no feature reachable only through an unlabelled
                  // icon", after a shipped feature was concluded missing
                  // because its only affordance was one. This bar is the app's
                  // primary navigation and it was hiding what its four
                  // destinations are.
                  //
                  // It costs nothing where it matters: the whole bar is already
                  // hidden while the rider is moving (`hideWhileMoving`), so
                  // labels only ever appear at a standstill, which is exactly
                  // the surface that can afford words.
                  labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
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
      rejoinNavigationRoute: _rejoinNavigationRoute,
      leaderStatus: _leaderStatus,
      tecGapTrend: _tecGapTrend,
      groupRiderCount: widget.rideController.liveParticipants.length,
      onOpenRoster: _openRoster,
      junctionMarkerOverlay: _junctionMarkerOverlay,
      enforcementAlert: _enforcementAlert,
      quickMessageAlerts: _quickMessageAlerts,
      onAcknowledgeQuickMessage: _acknowledgeQuickMessage,
      dismissedQuickMessageInterruptIds: _dismissedQuickMessageInterruptIds,
      dismissedQuickMessageReceiptIds: _dismissedQuickMessageReceiptIds,
      onDismissQuickMessageInterrupt: _dismissedQuickMessageInterruptIds.add,
      onDismissQuickMessageReceipt: _dismissedQuickMessageReceiptIds.add,
      dismissedEnforcementAlertId: _dismissedEnforcementAlertId,
      onDismissEnforcementAlert: (id) => _dismissedEnforcementAlertId = id,
      initialRouteStartConnector: _routeStartConnector,
      onRouteStartConnectorChanged: (connector) =>
          _routeStartConnector = connector,
      onReportHazard: _awarenessController == null
          ? null
          : _reportHazardFromMap,
      emergencyContacts: _emergencyContacts,
      onEmergencyAlert: _sendEmergencyMapAlert,
      onEmergencyIssue: _sendEmergencyMapIssue,
      onEmergencyContactUsed: _onEmergencyContactUsed,
      ridePaused: widget.rideController.ridePaused,
      rideHasNoLeader: widget.rideController.rideHasNoLeader,
      rideStarted: widget.rideController.rideStarted,
      markerFeaturesEnabled:
          widget.rideController.coordinationMode.usesSecondBikeDropOff,
      onLeaveRide: _confirmLeaveRideFromMap,
      onOpenRideMenu: _openRideMenu,
      onRouteCommitted: _onRouteChanged,
      onNavigationGuidanceChanged: _onNavigationGuidanceChanged,
      onNavigationViewportChanged: (viewport) {
        final bridge = _carPlayBridge;
        if (bridge != null) unawaited(bridge.publishViewport(viewport));
      },
      onMapStyleResolved: (styleJson) {
        if (!mounted) return;
        _carPlayMapStyleJson = styleJson;
        final bridge = _carPlayBridge;
        if (bridge == null) return;
        final basemap = BasemapConfiguration.fromEnvironment().forBrightness(
          dark: widget.mapStyleMode.resolveDark(
            MediaQuery.platformBrightnessOf(context),
          ),
        );
        unawaited(
          bridge.publishMapStyle(
            styleJson: styleJson,
            fallbackStyleUrl: basemap.styleUrl,
          ),
        );
      },
      changeRouteRequestToken: _changeRouteRequestToken,
      onChangeRouteRequestHandled: _clearChangeRouteRequest,
      pendingSharedGpxFile: _pendingSharedGpxFile,
      pendingInAppRoute: _pendingInAppRoute,
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
      localRiderSymbol:
          widget.rideController.session?.riderSymbol ?? riderSymbolDefault,
      localDisplayName: widget.rideController.session?.displayName ?? 'You',
      localBadgeColor: _localBadgeColor,
    );
  }

  void _onNavigationGuidanceChanged(NavigationGuidance? guidance) {
    _latestNavigationGuidance = guidance;
    _speakGuidance(guidance);
    _updateMapOverlays(updateDerivedState: false);
  }

  /// Speaks the instruction the phone banner and the car rows are already showing
  /// (#286).
  ///
  /// Deliberately driven from here rather than from its own timer or a second
  /// derivation of the route. This is the one place the current instruction
  /// changes, so audio cannot disagree with the screen - and a rider who hears
  /// one thing and sees another will trust neither.
  ///
  /// [ManeuverInstruction.standaloneText] is the wording, for the reason it
  /// already exists: it is what surfaces with no symbol beside them use, which is
  /// exactly what audio is. A roundabout says so out loud, where the banner can
  /// leave it to the drawn glyph.
  void _speakGuidance(NavigationGuidance? guidance) {
    final speaker = _spokenGuidance;
    if (speaker == null) return;
    if (guidance == null) return;
    final controller = widget.rideController;
    unawaited(
      speaker.speakManoeuvre(
        // The manoeuvre's identity, not its wording, so re-deriving the same turn
        // on every position fix does not speak it again.
        key: '${guidance.instruction.maneuver.hashCode}',
        phrase: guidance.instruction.standaloneText,
        enabled: widget.spokenGuidance?.enabled ?? false,
        rideActive:
            controller.rideStarted &&
            !controller.rideEnded &&
            !controller.ridePaused,
      ),
    );
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
    return session.riderColor.color;
  }

  /// The leader and TEC, with a phone number attached only where that rider has
  /// explicitly shared their own (#188).
  ///
  /// The number comes from `receivedRiderContacts` and nowhere else. It is never
  /// taken from an ICE share — that is the rider's next of kin — and never from
  /// the roster, a location event or the device. A role with nothing attached is
  /// still listed: the emergency sheet says so plainly rather than hiding it.
  List<MapEmergencyContact> get _emergencyContacts {
    final contacts = <String, MapEmergencyContact>{};
    final sharedNumbers = widget.rideController.receivedRiderContacts;
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
      final shared = sharedNumbers[rider.riderId];
      contacts[rider.riderId] = MapEmergencyContact(
        riderId: rider.riderId,
        displayName: rider.displayName,
        role: rider.role,
        phoneNumber: shared?.phoneNumber,
        contactShareEventId: shared?.eventId,
      );
    }
    return contacts.values.toList(growable: false);
  }

  /// A dialled number is a used share, so it survives the ride-end purge for the
  /// same reason a called ICE contact does: a rider who has just phoned somebody
  /// may need to phone them again.
  void _onEmergencyContactUsed(MapEmergencyContact contact) {
    final eventId = contact.contactShareEventId;
    if (eventId != null) widget.rideController.markRiderContactUsed(eventId);
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

  /// Who this rider's own number would go to if they shared it now (#188).
  ///
  /// An ordinary rider addresses it to the leader and the TEC and to nobody
  /// else. A rider who holds either role is sharing so the riders they are
  /// leading can reach them, which is the case in the request, so theirs goes to
  /// the ride. Reversing that is a one-line change in
  /// [RiderContactRecipients.resolve].
  RiderContactRecipients get _ownContactRecipients {
    final session = widget.rideController.session;
    if (session == null) return const RiderContactRecipients.addressed([]);
    final leaderId = _currentLeaderRiderId;
    return RiderContactRecipients.resolve(
      localRole: session.role,
      leaderRiderId: leaderId == session.localRiderId ? null : leaderId,
      tecRiderIds: _effectiveTecRiderIds.where(
        (riderId) => riderId != session.localRiderId,
      ),
    );
  }

  /// Shares this rider's own number. An explicit action, never automatic: there
  /// is no path that shares a number as a side effect of anything else, and a
  /// rider who shares nothing keeps a fully working app.
  Future<void> _shareOwnPhoneNumber() async {
    if (!widget.riderProfile.hasOwnPhoneNumber) {
      await EmergencyInfoSheet.show(context, widget.riderProfile);
      return;
    }
    // A new event type is rejected outright by an older build, so an older relay
    // that will not carry it has to be named rather than allowed to look like a
    // successful share.
    final relayCanCarry =
        _internetRelayController?.supportsCapability(
          RelayProtocolCapabilities.riderContactSharing,
        ) ??
        true;
    if (!relayCanCarry) {
      _showRideSnackBar(
        PresenceLimitation.riderContactSharingUnsupportedByService.message,
      );
      return;
    }
    final recipients = _ownContactRecipients;
    if (recipients.isEmpty) {
      _showRideSnackBar(
        'Nobody is holding the leader or Tail End Charlie role yet, so there '
        'is nobody to give your number to. Nothing has been shared.',
      );
      return;
    }
    final shared = await widget.rideController.shareOwnContactNumber(
      phoneNumber: widget.riderProfile.ownPhoneNumber,
      recipients: recipients,
    );
    if (!mounted) return;
    _showRideSnackBar(
      shared
          ? (recipients.toRideGroup
                ? 'Your number is now available to this ride, for this ride '
                      'only.'
                : 'Your number has gone to the leader and Tail End Charlie, and '
                      'to nobody else.')
          : 'Your number was not shared. '
                    '${widget.rideController.errorMessage ?? ''}'
                .trim(),
    );
  }

  void _showRideSnackBar(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

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
    if (widget.rideController.coordinationMode == RideCoordinationMode.solo) {
      return true;
    }
    if (_effectiveTecRiderIds.isNotEmpty) return true;
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
    final isLeader = canEndRideForEveryone(widget.rideController);
    final decision = await showRideExitDialog(context, isLeader: isLeader);
    switch (decision) {
      case RideExitDecision.leave:
        await _leaveRide();
        return;
      case RideExitDecision.endForEveryone:
        await _confirmEndRide();
        return;
      case RideExitDecision.cancel:
      case null:
        return;
    }
  }

  Future<void> _confirmEndRide() async {
    // One shared dialog, so the words a leader reads do not depend on whether
    // they came from the ride menu or the dashboard header (#306).
    await confirmEndRide(
      context,
      controller: widget.rideController,
      relayCanCarryReopen: _relayCanCarryReopen,
    );
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
        hasOwnPhoneNumber: widget.riderProfile.hasOwnPhoneNumber,
        ownPhoneNumberShared: widget.rideController.hasSharedOwnContactNumber,
        ownPhoneNumberRecipientLabel: _ownContactRecipients.toRideGroup
            ? 'this ride'
            : 'the leader and Tail End Charlie',
        onShareOwnPhoneNumber: () => unawaited(_shareOwnPhoneNumber()),
        ridePaused: widget.rideController.ridePaused,
        canToggleRidePause:
            !_isSimulation &&
            widget.rideController.rideStarted &&
            widget.rideController.session?.role == RideRole.lead,
        onToggleRidePause: _toggleRidePause,
        canEndRide: canEndRideForEveryone(widget.rideController),
        onEndRide: _confirmEndRide,
      ),
    );
  }

  bool get _relayCanCarryReopen =>
      _internetRelayController?.supportsCapability(
        RelayProtocolCapabilities.rideReopen,
      ) ??
      true;

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
    await ObserverAccessSheet.show(
      context,
      controller,
      canShareGroup:
          widget.rideController.coordinationMode.isGroup &&
          widget.rideController.isLocalRideLeader,
    );
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
    final generatedAt = controller.nextSnapshotGeneratedAt();
    final rideStatus = widget.rideController.rideEnded
        ? 'ended'
        : widget.rideController.ridePaused
        ? 'paused'
        : widget.rideController.rideStarted
        ? 'active'
        : 'waiting';
    final statusUpdatedAt = _observerStatusUpdatedAt();
    final assistanceUpdatedAt = controller.localAssistanceUpdatedAt;
    final liveView = widget.rideController.liveView;
    controller.publishSnapshots(
      rider: buildLocalObserverSnapshot(
        session: session,
        snapshotGeneratedAt: generatedAt,
        rideStatus: rideStatus,
        statusUpdatedAt: statusUpdatedAt,
        assistanceUpdatedAt: assistanceUpdatedAt,
        localLocation: sample,
        assistance: controller.localAssistance,
      ),
      group:
          widget.rideController.coordinationMode.isGroup &&
              widget.rideController.isLocalRideLeader
          ? buildGroupObserverSnapshot(
              session: session,
              snapshotGeneratedAt: generatedAt,
              rideStatus: rideStatus,
              statusUpdatedAt: statusUpdatedAt,
              assistanceUpdatedAt: assistanceUpdatedAt,
              liveParticipants: liveView.liveParticipants,
              renderedPositions: liveView.renderedPositions,
              localLocation: sample,
              route: _activeRoute,
            )
          : null,
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
      _pendingInAppRoute = null;
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
        _pendingInAppRoute = null;
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
    relayCanCarryReopen: _relayCanCarryReopen,
    distanceUnits: widget.distanceUnits,
    mapStyleMode: widget.mapStyleMode,
    speedLimitDisplay: widget.speedLimitDisplay,
    riderProfile: widget.riderProfile,
    testControl: widget.testControl,
    spokenGuidance: widget.spokenGuidance,
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
    unawaited(_spokenGuidance?.stop());
    _awarenessController?.removeListener(_onAwarenessChanged);
    _markerAssistanceController?.dispose();
    if (_awarenessController case final awareness?) {
      widget.testControlRegistry?.withdraw(awareness);
    }
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
    _rejoinNavigationRoute.dispose();
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
