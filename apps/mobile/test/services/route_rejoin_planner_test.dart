import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/distance_unit.dart';
import 'package:ride_relay/domain/geo_point.dart';
import 'package:ride_relay/domain/imported_route.dart' as route_domain;
import 'package:ride_relay/domain/rider_location.dart';
import 'package:ride_relay/domain/route_alert.dart';
import 'package:ride_relay/services/geo_calculations.dart';
import 'package:ride_relay/services/road_routing.dart';
import 'package:ride_relay/services/route_rejoin_planner.dart';

void main() {
  // A straight run east along latitude 51 in 0.01 degree steps. One step is
  // roughly 700 m at this latitude, so the route is about 14 km long.
  final route = [
    for (var index = 0; index <= 20; index += 1)
      GeoPoint(latitude: 51, longitude: -1 + index * 0.01),
  ];
  final total = RouteRejoinGeometry.totalLengthMeters(route);
  final start = DateTime.utc(2026, 7, 25, 10);

  double progressOf(GeoPoint point) => GeoCalculations.projectOntoPolyline(
    point,
    route,
  ).distanceAlongRouteMeters;

  group('threshold classification', () {
    final planner = RouteRejoinPlanner(routingService: _StubRouting());

    test('a confirmed deviation inside 1500 m is a plain rejoin', () {
      expect(
        planner.classify(
          assessment: _offRoute(at: start, distance: 900, since: start),
          now: start,
        ),
        RouteRejoinSeverity.offRoute,
      );
    });

    test('1500 m or more from the route is massively off course', () {
      expect(
        planner.classify(
          assessment: _offRoute(at: start, distance: 1500, since: start),
          now: start,
        ),
        RouteRejoinSeverity.massivelyOffRoute,
      );
    });

    test('ten minutes off route is massively off course on its own', () {
      final now = start.add(const Duration(minutes: 10));
      expect(
        planner.classify(
          assessment: _offRoute(at: now, distance: 200, since: start),
          now: now,
        ),
        RouteRejoinSeverity.massivelyOffRoute,
      );
      expect(
        planner.classify(
          assessment: _offRoute(
            at: start.add(const Duration(minutes: 9)),
            distance: 200,
            since: start,
          ),
          now: start.add(const Duration(minutes: 9)),
        ),
        RouteRejoinSeverity.offRoute,
      );
    });

    test('a rider following the leader is never off course', () {
      expect(
        planner.classify(
          assessment: _offRoute(at: start, distance: 9000, since: start),
          followingLeaderTrack: true,
          now: start,
        ),
        RouteRejoinSeverity.onRoute,
      );
    });

    test('an unconfirmed deviation is not routed for', () {
      expect(
        planner.classify(
          assessment: RouteDeviationAssessment(
            state: RouteTrackingState.suspectedOffRoute,
            alertLevel: RouteAlertLevel.watch,
            audience: RouteAlertAudience.rider,
            evaluatedAt: start,
            message: 'Possible route deviation.',
            distanceFromRouteMeters: 400,
          ),
          now: start,
        ),
        RouteRejoinSeverity.onRoute,
      );
    });
  });

  group('rejoin selection', () {
    test('prefers a rejoin point ahead of the last matched progress', () {
      final selection = RouteRejoinGeometry.selectRejoin(
        route: route,
        riderPosition: const GeoPoint(latitude: 51.01, longitude: -0.95),
        lastMatchedProgressMeters: progressOf(
          const GeoPoint(latitude: 51, longitude: -0.96),
        ),
      );

      final candidate = selection.candidate;
      expect(candidate, isNotNull);
      expect(candidate!.requiresBacktracking, isFalse);
      expect(
        candidate.progressMeters,
        greaterThan(progressOf(const GeoPoint(latitude: 51, longitude: -0.96))),
      );
    });

    test('backtracks, and says so, when no forward rejoin exists', () {
      // The rider left the route at its very end, so nothing lies ahead.
      final selection = RouteRejoinGeometry.selectRejoin(
        route: route,
        riderPosition: const GeoPoint(latitude: 51.01, longitude: -0.79),
        lastMatchedProgressMeters: total,
      );

      final candidate = selection.candidate;
      expect(candidate, isNotNull);
      expect(candidate!.requiresBacktracking, isTrue);
      expect(candidate.progressMeters, lessThan(total));
    });

    test('an unconstrained rider may rejoin ahead of the leader', () {
      final selection = RouteRejoinGeometry.selectRejoin(
        route: route,
        riderPosition: const GeoPoint(latitude: 51.01, longitude: -0.9),
        lastMatchedProgressMeters: progressOf(
          const GeoPoint(latitude: 51, longitude: -0.96),
        ),
        leaderProgressMeters: progressOf(
          const GeoPoint(latitude: 51, longitude: -0.95),
        ),
      );

      expect(
        selection.candidate!.progressMeters,
        greaterThan(progressOf(const GeoPoint(latitude: 51, longitude: -0.95))),
      );
    });

    test('a massively off-course rider is capped at the leader progress', () {
      final leaderProgress = progressOf(
        const GeoPoint(latitude: 51, longitude: -0.95),
      );
      final selection = RouteRejoinGeometry.selectRejoin(
        route: route,
        riderPosition: const GeoPoint(latitude: 51.02, longitude: -0.9),
        lastMatchedProgressMeters: progressOf(
          const GeoPoint(latitude: 51, longitude: -0.96),
        ),
        leaderProgressMeters: leaderProgress,
        massivelyOffRoute: true,
      );

      final candidate = selection.candidate;
      expect(candidate, isNotNull);
      expect(
        candidate!.progressMeters,
        lessThanOrEqualTo(leaderProgress + 100),
      );
    });

    test(
      'refuses rather than routing a massively off-course rider ahead of the '
      'leader',
      () {
        final selection = RouteRejoinGeometry.selectRejoin(
          route: route,
          riderPosition: const GeoPoint(latitude: 51.005, longitude: -0.9),
          lastMatchedProgressMeters: progressOf(
            const GeoPoint(latitude: 51, longitude: -0.96),
          ),
          leaderProgressMeters: 0,
          massivelyOffRoute: true,
          thresholds: const RouteRejoinThresholds(
            maximumRejoinDetourMeters: 2000,
          ),
        );

        expect(selection.candidate, isNull);
        expect(selection.status, RouteRejoinStatus.aheadOfLeaderOnly);
      },
    );

    test('a massively off-course rider needs the leader to be known', () {
      final selection = RouteRejoinGeometry.selectRejoin(
        route: route,
        riderPosition: const GeoPoint(latitude: 51.02, longitude: -0.9),
        lastMatchedProgressMeters: 0,
        massivelyOffRoute: true,
      );

      expect(selection.candidate, isNull);
      expect(selection.status, RouteRejoinStatus.leaderPositionUnknown);
    });

    test('a route with fewer than two points cannot be rejoined', () {
      final selection = RouteRejoinGeometry.selectRejoin(
        route: const [GeoPoint(latitude: 51, longitude: -1)],
        riderPosition: const GeoPoint(latitude: 51.02, longitude: -0.9),
        lastMatchedProgressMeters: 0,
      );

      expect(selection.status, RouteRejoinStatus.noPlannedRoute);
    });
  });

  group('planner', () {
    test('draws only geometry the routing engine returned', () async {
      final routing = _StubRouting();
      final planner = RouteRejoinPlanner(routingService: routing);

      await planner.update(
        riderId: 'rider',
        sample: _sample(51, -0.96, start),
        assessment: _onRoute(start),
        plannedRoute: route,
      );
      final plan = await planner.update(
        riderId: 'rider',
        sample: _sample(51.01, -0.95, start.add(const Duration(minutes: 1))),
        assessment: _offRoute(
          at: start.add(const Duration(minutes: 1)),
          distance: 1112,
          since: start.add(const Duration(seconds: 30)),
        ),
        plannedRoute: route,
      );

      expect(plan.status, RouteRejoinStatus.routed);
      expect(plan.severity, RouteRejoinSeverity.offRoute);
      expect(plan.target, RouteRejoinTarget.plannedRoute);
      expect(plan.hasBreadcrumb, isTrue);
      expect(plan.breadcrumb, hasLength(routing.lastReturnedPointCount));
      expect(plan.requiresBacktracking, isFalse);
      expect(plan.guidance, contains('Advisory rejoin route'));
      expect(plan.guidance, contains('Rejoining ahead of'));
      expect(routing.calls, hasLength(1));
      // The first waypoint is the rider and the last is a point on the route.
      expect(routing.calls.single.first.latitude, closeTo(51.01, 1e-9));
      expect(routing.calls.single.last.latitude, closeTo(51, 1e-6));
    });

    test('routes a massively off-course rider to the TEC', () async {
      final routing = _StubRouting();
      final planner = RouteRejoinPlanner(routingService: routing);
      final now = start.add(const Duration(minutes: 2));

      await planner.update(
        riderId: 'rider',
        sample: _sample(51, -0.96, start),
        assessment: _onRoute(start),
        plannedRoute: route,
      );
      final plan = await planner.update(
        riderId: 'rider',
        sample: _sample(51.03, -0.9, now),
        assessment: _offRoute(at: now, distance: 3336, since: start),
        plannedRoute: route,
        leaderPosition: const GeoPoint(latitude: 51, longitude: -0.9),
        tecPosition: const GeoPoint(latitude: 51, longitude: -0.94),
      );

      expect(plan.severity, RouteRejoinSeverity.massivelyOffRoute);
      expect(plan.target, RouteRejoinTarget.tailEndCharlie);
      expect(plan.guidance, contains('Tail End Charlie'));
      expect(plan.guidance, contains('stays behind the leader'));
      // Rejoin point behind the leader, and the TEC is the final waypoint.
      expect(
        progressOf(plan.rejoinPoint!),
        lessThanOrEqualTo(
          progressOf(const GeoPoint(latitude: 51, longitude: -0.9)) + 100,
        ),
      );
      expect(routing.calls.single.last.longitude, closeTo(-0.94, 1e-9));
    });

    test('routes to the leader when no TEC is registered', () async {
      final routing = _StubRouting();
      final planner = RouteRejoinPlanner(routingService: routing);
      final now = start.add(const Duration(minutes: 2));

      final plan = await planner.update(
        riderId: 'rider',
        sample: _sample(51.03, -0.9, now),
        assessment: _offRoute(at: now, distance: 3336, since: start),
        plannedRoute: route,
        leaderPosition: const GeoPoint(latitude: 51, longitude: -0.92),
      );

      expect(plan.target, RouteRejoinTarget.leader);
      expect(plan.guidance, contains('on to the ride leader'));
      expect(routing.calls.single.last.longitude, closeTo(-0.92, 1e-9));
    });

    test('a TEC fix that projects ahead of the leader is not used', () async {
      final routing = _StubRouting();
      final planner = RouteRejoinPlanner(routingService: routing);
      final now = start.add(const Duration(minutes: 2));

      final plan = await planner.update(
        riderId: 'rider',
        sample: _sample(51.03, -0.9, now),
        assessment: _offRoute(at: now, distance: 3336, since: start),
        plannedRoute: route,
        leaderPosition: const GeoPoint(latitude: 51, longitude: -0.92),
        // A stale or wild TEC fix, further along the route than the leader.
        tecPosition: const GeoPoint(latitude: 51, longitude: -0.88),
      );

      expect(plan.target, RouteRejoinTarget.leader);
      expect(routing.calls.single.last.longitude, closeTo(-0.92, 1e-9));
    });

    test('a rider following the leader is not routed at all', () async {
      final routing = _StubRouting();
      final planner = RouteRejoinPlanner(routingService: routing);

      final plan = await planner.update(
        riderId: 'rider',
        sample: _sample(52, -0.9, start),
        assessment: _offRoute(at: start, distance: 111000, since: start),
        plannedRoute: route,
        followingLeaderTrack: true,
      );

      expect(plan.severity, RouteRejoinSeverity.onRoute);
      expect(plan.status, RouteRejoinStatus.notRequired);
      expect(plan.hasBreadcrumb, isFalse);
      expect(routing.calls, isEmpty);
    });

    test('recompute is bounded by interval and by movement', () async {
      final routing = _StubRouting();
      final planner = RouteRejoinPlanner(routingService: routing);
      var now = start;

      Future<RouteRejoinPlan> feed(double latitude, double longitude) =>
          planner.update(
            riderId: 'rider',
            sample: _sample(latitude, longitude, now),
            assessment: _offRoute(at: now, distance: 1112, since: start),
            plannedRoute: route,
            now: now,
          );

      await feed(51.01, -0.95);
      expect(planner.routingCallCount, 1);

      // Inside the interval: no further calls however many fixes arrive.
      for (var index = 0; index < 10; index += 1) {
        now = now.add(const Duration(seconds: 4));
        await feed(51.01, -0.95 + index * 0.002);
      }
      expect(planner.routingCallCount, 1);

      // Past the interval but barely moved: still no call.
      now = now.add(const Duration(minutes: 5));
      await feed(51.0101, -0.95);
      expect(planner.routingCallCount, 1);

      // Past the interval and moved more than 250 m along the road: one more
      // call. Deliberately no further from the route, so the rider stays in the
      // plain-rejoin band rather than being promoted.
      now = now.add(const Duration(minutes: 1));
      await feed(51.01, -0.945);
      expect(planner.routingCallCount, 2);
    });

    test(
      'a rider circling one spot makes at most one call per interval',
      () async {
        final routing = _StubRouting();
        final planner = RouteRejoinPlanner(routingService: routing);
        var now = start;

        // Ten minutes of fixes every five seconds, looping around a village.
        for (var index = 0; index < 120; index += 1) {
          final angle = index * 0.5;
          await planner.update(
            riderId: 'rider',
            sample: _sample(
              51.01 + 0.002 * math.sin(angle),
              -0.95 + 0.006 * math.cos(angle),
              now,
            ),
            assessment: _offRoute(at: now, distance: 1112, since: start),
            plannedRoute: route,
            now: now,
          );
          now = now.add(const Duration(seconds: 5));
        }

        // 600 s of riding at a 45 s floor can never exceed 14 calls.
        expect(planner.routingCallCount, lessThanOrEqualTo(14));
        expect(routing.calls.length, planner.routingCallCount);
      },
    );

    test('routing failure degrades to the distance message', () async {
      final planner = RouteRejoinPlanner(
        routingService: _FailingRouting(),
        distanceUnit: DistanceUnit.kilometres,
      );

      final plan = await planner.update(
        riderId: 'rider',
        sample: _sample(51.01, -0.95, start),
        assessment: _offRoute(at: start, distance: 1112, since: start),
        plannedRoute: route,
      );

      expect(plan.status, RouteRejoinStatus.routingUnavailable);
      expect(plan.hasBreadcrumb, isFalse);
      expect(plan.degraded, isTrue);
      expect(plan.guidance, contains('You are off route by'));
      expect(plan.guidance, contains('unavailable'));
    });

    test('a single returned point is not a route', () async {
      final planner = RouteRejoinPlanner(
        routingService: _StubRouting(points: 1),
      );

      final plan = await planner.update(
        riderId: 'rider',
        sample: _sample(51.01, -0.95, start),
        assessment: _offRoute(at: start, distance: 1112, since: start),
        plannedRoute: route,
      );

      expect(plan.status, RouteRejoinStatus.routingUnavailable);
      expect(plan.breadcrumb, isEmpty);
    });

    test(
      'repeated failures back off instead of retrying every interval',
      () async {
        final routing = _FailingRouting();
        final planner = RouteRejoinPlanner(routingService: routing);
        var now = start;

        for (var index = 0; index < 6; index += 1) {
          await planner.update(
            riderId: 'rider',
            sample: _sample(51.01 + index * 0.01, -0.95, now),
            assessment: _offRoute(at: now, distance: 1112, since: start),
            plannedRoute: route,
            now: now,
          );
          now = now.add(const Duration(seconds: 50));
        }

        // Without backoff each 50 s step would have retried: six calls.
        expect(planner.routingCallCount, lessThan(4));
      },
    );

    test('no route imported degrades safely', () async {
      final routing = _StubRouting();
      final planner = RouteRejoinPlanner(routingService: routing);

      final plan = await planner.update(
        riderId: 'rider',
        sample: _sample(51.01, -0.95, start),
        assessment: _offRoute(at: start, distance: 1112, since: start),
        plannedRoute: const [],
      );

      expect(plan.status, RouteRejoinStatus.noPlannedRoute);
      expect(plan.hasBreadcrumb, isFalse);
      expect(plan.guidance, contains('nothing to rejoin'));
      expect(routing.calls, isEmpty);
    });

    test(
      'no leader position degrades safely when massively off course',
      () async {
        final routing = _StubRouting();
        final planner = RouteRejoinPlanner(routingService: routing);

        final plan = await planner.update(
          riderId: 'rider',
          sample: _sample(51.03, -0.9, start),
          assessment: _offRoute(at: start, distance: 3336, since: start),
          plannedRoute: route,
        );

        expect(plan.status, RouteRejoinStatus.leaderPositionUnknown);
        expect(plan.hasBreadcrumb, isFalse);
        expect(plan.guidance, contains('position is unknown'));
        expect(routing.calls, isEmpty);
      },
    );

    test('recovering to the route clears the plan and the throttle', () async {
      final routing = _StubRouting();
      final planner = RouteRejoinPlanner(routingService: routing);
      var now = start;

      await planner.update(
        riderId: 'rider',
        sample: _sample(51.01, -0.95, now),
        assessment: _offRoute(at: now, distance: 1112, since: now),
        plannedRoute: route,
        now: now,
      );
      expect(planner.routingCallCount, 1);

      now = now.add(const Duration(seconds: 10));
      final recovered = await planner.update(
        riderId: 'rider',
        sample: _sample(51, -0.95, now),
        assessment: _onRoute(now),
        plannedRoute: route,
        now: now,
      );
      expect(recovered.status, RouteRejoinStatus.notRequired);
      expect(planner.planFor('rider')?.hasBreadcrumb, isFalse);

      // A brand new deviation is routed at once, not after another interval.
      now = now.add(const Duration(seconds: 10));
      await planner.update(
        riderId: 'rider',
        sample: _sample(51.01, -0.94, now),
        assessment: _offRoute(at: now, distance: 1112, since: now),
        plannedRoute: route,
        now: now,
      );
      expect(planner.routingCallCount, 2);
    });
  });

  group('leader-track exemption', () {
    final leaderTrack = [
      for (var index = 0; index <= 10; index += 1)
        GeoPoint(latitude: 52, longitude: -1 + index * 0.01),
    ];

    test('a rider inside the corridor is following the leader', () {
      expect(
        LeaderTrackExemption.isFollowingLeaderTrack(
          position: const GeoPoint(latitude: 52.0005, longitude: -0.95),
          leaderTrack: leaderTrack,
        ),
        isTrue,
      );
    });

    test('a rider outside the corridor is not', () {
      expect(
        LeaderTrackExemption.isFollowingLeaderTrack(
          position: const GeoPoint(latitude: 52.01, longitude: -0.95),
          leaderTrack: leaderTrack,
        ),
        isFalse,
      );
    });

    test('an uncertain fix gets the benefit of its own accuracy', () {
      const justOutside = GeoPoint(latitude: 52.0015, longitude: -0.95);
      expect(
        LeaderTrackExemption.isFollowingLeaderTrack(
          position: justOutside,
          leaderTrack: leaderTrack,
        ),
        isFalse,
      );
      expect(
        LeaderTrackExemption.isFollowingLeaderTrack(
          position: justOutside,
          leaderTrack: leaderTrack,
          accuracyMeters: 75,
        ),
        isTrue,
      );
    });

    test('a leader with no track yet exempts nobody', () {
      expect(
        LeaderTrackExemption.isFollowingLeaderTrack(
          position: const GeoPoint(latitude: 52, longitude: -1),
          leaderTrack: const [GeoPoint(latitude: 52, longitude: -1)],
        ),
        isFalse,
      );
    });
  });

  test('a point can be taken at any progress along the route', () {
    expect(
      RouteRejoinGeometry.pointAtProgress(route, 0).longitude,
      closeTo(-1, 1e-9),
    );
    expect(
      RouteRejoinGeometry.pointAtProgress(route, total).longitude,
      closeTo(-0.8, 1e-9),
    );
    expect(
      RouteRejoinGeometry.pointAtProgress(route, total * 2).longitude,
      closeTo(-0.8, 1e-9),
    );
    expect(
      progressOf(RouteRejoinGeometry.pointAtProgress(route, 3500)),
      closeTo(3500, 5),
    );
  });
}

// A stand-in for the OSRM service. Returns a straight line between the
// requested waypoints so tests can assert on what was asked for, never on
// invented turn geometry.
class _StubRouting implements RoadRoutingService {
  _StubRouting({this.points = 6});

  final int points;
  final List<List<route_domain.GeoPoint>> calls = [];

  int get lastReturnedPointCount => points;

  @override
  Future<RoadRouteResult> routeThrough(
    List<route_domain.GeoPoint> waypoints,
  ) async {
    calls.add(List.unmodifiable(waypoints));
    final first = waypoints.first;
    final last = waypoints.last;
    return RoadRouteResult(
      points: [
        for (var index = 0; index < points; index += 1)
          route_domain.GeoPoint(
            latitude:
                first.latitude +
                (last.latitude - first.latitude) * index / (points - 1),
            longitude:
                first.longitude +
                (last.longitude - first.longitude) * index / (points - 1),
          ),
      ],
      distanceMeters: 1234,
      duration: const Duration(minutes: 3),
    );
  }
}

class _FailingRouting implements RoadRoutingService {
  int calls = 0;

  @override
  Future<RoadRouteResult> routeThrough(
    List<route_domain.GeoPoint> waypoints,
  ) async {
    calls += 1;
    throw const FormatException('No road route was found.');
  }
}

LocationSample _sample(double latitude, double longitude, DateTime at) =>
    LocationSample(
      position: GeoPoint(latitude: latitude, longitude: longitude),
      recordedAt: at,
      accuracyMeters: 5,
    );

RouteDeviationAssessment _onRoute(DateTime at) => RouteDeviationAssessment(
  state: RouteTrackingState.onRoute,
  alertLevel: RouteAlertLevel.none,
  audience: RouteAlertAudience.rider,
  evaluatedAt: at,
  message: 'On route.',
  distanceFromRouteMeters: 5,
);

RouteDeviationAssessment _offRoute({
  required DateTime at,
  required double distance,
  required DateTime since,
}) => RouteDeviationAssessment(
  state: RouteTrackingState.offRoute,
  alertLevel: RouteAlertLevel.urgent,
  audience: RouteAlertAudience.coordinators,
  evaluatedAt: at,
  message: 'Rider is confirmed off route.',
  distanceFromRouteMeters: distance,
  offRouteSince: since,
);
