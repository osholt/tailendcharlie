// Drives the path a phone actually takes on an off-course excursion (#162):
// real SituationalAwarenessController, real RouteDeviationDetector, real
// RouteRejoinPlanner, composed exactly as ActiveRideShell._updateRejoinRoute
// composes them.
//
// #102 shipped rerouting and it never fired in the field. It worked for a
// follower the whole time; it never once worked for the leader, who was compared
// against their own recorded trail and so read as on route from anywhere. Both
// roles run here for that reason - and because #141 was three failed fixes for a
// bug whose tests never exercised the path the device took.

import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/situational_awareness_controller.dart';
import 'package:ride_relay/data/in_memory_event_store.dart';
import 'package:ride_relay/domain/geo_point.dart';
import 'package:ride_relay/domain/imported_route.dart' as route_domain;
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/ride_session.dart';
import 'package:ride_relay/domain/rider_location.dart';
import 'package:ride_relay/domain/route_alert.dart';
import 'package:ride_relay/services/leader_ride_status.dart'
    show TecAvailability;
import 'package:ride_relay/services/road_routing.dart';
import 'package:ride_relay/services/route_rejoin_planner.dart';

void main() {
  for (final role in [RideRole.lead, RideRole.rider]) {
    _testsFor(role);
  }
}

void _testsFor(RideRole role) {
  final session = _sessionFor(role);
  late InMemoryEventStore store;
  late DateTime now;
  late int nextId;
  late SituationalAwarenessController awareness;
  late _RecordingRoutingService routing;
  late RouteRejoinPlanner planner;

  /// One position fix, through the same two steps the shell performs.
  Future<RouteRejoinPlan?> fix(GeoPoint position) async {
    await awareness.recordLocalLocation(
      LocationSample(
        position: position,
        recordedAt: now,
        accuracyMeters: 5,
        speedMetersPerSecond: 13,
      ),
    );
    final local = awareness.localLocation;
    final alert = awareness.alertFor(session.localRiderId);
    if (local == null || alert == null) return null;
    return planner.update(
      riderId: session.localRiderId,
      sample: local.sample,
      assessment: alert.assessment,
      plannedRoute: awareness.route,
      followingLeaderTrack: awareness.isFollowingLeaderTrack(
        session.localRiderId,
      ),
      // The leader is their own leader; a follower's leader is further along the
      // planned route, which is what the never-ahead-of-the-leader rule needs.
      leaderPosition: role == RideRole.lead
          ? position
          : const GeoPoint(latitude: 51, longitude: -0.9915),
      tecAvailability: TecAvailability.none,
      now: now,
    );
  }

  void advance(Duration by) => now = now.add(by);

  Future<void> rideAlongRoute() async {
    for (var step = 0; step < 3; step += 1) {
      await fix(GeoPoint(latitude: 51, longitude: -1 + step * 0.002));
      advance(const Duration(seconds: 3));
    }
  }

  /// Leaves the route heading north, ending roughly 500 m off the line - a
  /// missed turn, not a different county, and well past the 120 m threshold.
  Future<RouteRejoinPlan?> rideOffRoute() async {
    RouteRejoinPlan? plan;
    for (var step = 0; step < 6; step += 1) {
      plan = await fix(
        GeoPoint(latitude: 51.0027 + step * 0.0005, longitude: -0.994),
      );
      advance(const Duration(seconds: 3));
    }
    return plan;
  }

  group('as ${role.name}', () {
    setUp(() async {
      store = InMemoryEventStore();
      now = DateTime.utc(2026, 7, 27, 10);
      nextId = 0;
      routing = _RecordingRoutingService();
      planner = RouteRejoinPlanner(routingService: routing);
      awareness = SituationalAwarenessController(
        store,
        session,
        route: _route,
        clock: () => now,
        idFactory: () => 'id-${nextId++}',
      );
      await awareness.initialize();
    });

    tearDown(() => awareness.dispose());

    test('leaving the route produces a rejoin route unprompted', () async {
      await rideAlongRoute();
      final plan = await rideOffRoute();

      expect(
        awareness.alertFor(session.localRiderId)?.assessment.state,
        RouteTrackingState.offRoute,
        reason: 'a 500 m departure from the plan is off route for any role',
      );
      expect(plan?.severity, RouteRejoinSeverity.offRoute);
      expect(
        routing.calls,
        greaterThan(0),
        reason: 'a rejoin route must be requested from the router unprompted',
      );
      expect(
        plan?.status,
        RouteRejoinStatus.routed,
        reason: 'the rider gets a route back, not only a distance',
      );
      expect(plan?.hasBreadcrumb, isTrue);
    });

    test('the rider is told they are off route, and by how far', () async {
      await rideAlongRoute();
      final plan = await rideOffRoute();

      expect(plan?.guidance, contains('off route'));
      expect(
        plan?.distanceFromRouteMeters,
        greaterThan(400),
        reason:
            'the distance must be the current one, not the one from the moment '
            'the state changed',
      );
    });

    test('the reported distance keeps up as the rider goes further', () async {
      await rideAlongRoute();
      await rideOffRoute();
      final atTransition = awareness
          .alertFor(session.localRiderId)!
          .assessment
          .distanceFromRouteMeters!;

      for (var step = 0; step < 4; step += 1) {
        await fix(GeoPoint(latitude: 51.008 + step * 0.001, longitude: -0.994));
        advance(const Duration(seconds: 3));
      }

      expect(
        awareness
            .alertFor(session.localRiderId)!
            .assessment
            .distanceFromRouteMeters,
        greaterThan(atTransition),
        reason: 'a frozen distance is what made the guidance text wrong',
      );
    });

    test('regaining the route restores guidance within two fixes', () async {
      await rideAlongRoute();
      await rideOffRoute();
      expect(
        awareness.alertFor(session.localRiderId)?.assessment.state,
        RouteTrackingState.offRoute,
      );

      // exitOffRouteMeters is 60 m and recovery is confirmed over two samples,
      // so two fixes on the line is the stated target latency.
      await fix(const GeoPoint(latitude: 51, longitude: -0.994));
      advance(const Duration(seconds: 3));
      final plan = await fix(const GeoPoint(latitude: 51, longitude: -0.992));

      expect(
        awareness.alertFor(session.localRiderId)?.assessment.state,
        RouteTrackingState.onRoute,
        reason: 'two fixes back on the line clears the off-route state',
      );
      expect(plan?.severity, RouteRejoinSeverity.onRoute);
      expect(plan?.status, RouteRejoinStatus.notRequired);
    });
  });
}

RideSession _sessionFor(RideRole role) => RideSession(
  rideId: 'ride',
  rideCode: '123456',
  inviteSecret: 'shared-secret',
  joinToken: 'test-join-token-0123456789',
  localRiderId: 'local-rider',
  displayName: 'Oliver',
  role: role,
  joinedAt: DateTime.utc(2026, 7, 27, 9),
);

/// ~1.4 km of route running due east along latitude 51.
const _route = <GeoPoint>[
  GeoPoint(latitude: 51, longitude: -1),
  GeoPoint(latitude: 51, longitude: -0.998),
  GeoPoint(latitude: 51, longitude: -0.996),
  GeoPoint(latitude: 51, longitude: -0.994),
  GeoPoint(latitude: 51, longitude: -0.992),
  GeoPoint(latitude: 51, longitude: -0.99),
];

class _RecordingRoutingService implements RoadRoutingService {
  int calls = 0;

  @override
  Future<RoadRouteResult> routeThrough(
    List<route_domain.GeoPoint> waypoints, {
    route_domain.RoutePreferences? preferences,
    double? originBearingDegrees,
  }) async {
    calls += 1;
    return RoadRouteResult(
      points: List.unmodifiable(waypoints),
      distanceMeters: 500,
      duration: const Duration(minutes: 1),
      maneuvers: const [],
    );
  }
}
