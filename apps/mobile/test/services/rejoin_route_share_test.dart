import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/geo_point.dart';
import 'package:ride_relay/domain/ride_event.dart';
import 'package:ride_relay/services/rejoin_route_share.dart';
import 'package:ride_relay/services/ride_event_authenticator.dart';
import 'package:ride_relay/services/route_rejoin_planner.dart';

/// Issue #128 part 2. A separated rider's rejoin route reaches the leader, and
/// only the leader; the relayed volume is bounded independently of #102's local
/// recompute policy; and the share expires on rejoin, on a route change and at
/// ride end.
void main() {
  const secret = '0123456789abcdef0123456789abcdef';
  final start = DateTime.utc(2026, 7, 26, 11);

  List<GeoPoint> breadcrumb({int points = 8, double offset = 0}) => [
    for (var index = 0; index < points; index += 1)
      GeoPoint(
        latitude: 51.5 + offset + index * 0.001,
        longitude: -0.1 + index * 0.001,
      ),
  ];

  RouteRejoinPlan plan({
    required DateTime computedAt,
    RouteRejoinSeverity severity = RouteRejoinSeverity.offRoute,
    RouteRejoinStatus status = RouteRejoinStatus.routed,
    RouteRejoinTarget? target = RouteRejoinTarget.plannedRoute,
    List<GeoPoint>? points,
  }) => RouteRejoinPlan(
    riderId: 'bill',
    severity: severity,
    status: status,
    target: target,
    computedAt: computedAt,
    guidance: 'You are off route by 800 m.',
    breadcrumb: points ?? breadcrumb(),
    rejoinPoint: const GeoPoint(latitude: 51.52, longitude: -0.08),
    distanceMeters: 4200,
    duration: const Duration(minutes: 6),
  );

  group('the relayed form is bounded independently of local recompute', () {
    test('a rider circling off route for ten minutes shares five times', () {
      final gate = RejoinRouteRelayGate();
      var recomputations = 0;
      // The worst case from the field report, fed at #102's own 45 s recompute
      // floor - the fastest the local planner can possibly produce a new plan.
      for (var second = 0; second <= 600; second += 45) {
        recomputations += 1;
        gate.evaluate(
          plan: plan(computedAt: start.add(Duration(seconds: second))),
          displayName: 'Bill',
          routeRevisionNumber: 1,
          now: start.add(Duration(seconds: second)),
        );
      }

      expect(recomputations, 14);
      // Fourteen local recomputations became five relayed events, because the
      // 45 s grid only clears the 120 s floor every third recomputation.
      expect(gate.sharedCount, 5);
      expect(gate.clearedCount, 0);
      expect(
        gate.sharedCount,
        lessThanOrEqualTo(maximumRejoinSharesOver(const Duration(minutes: 10))),
      );
    });

    test('the stated ceiling holds even if the plan changed every second', () {
      final gate = RejoinRouteRelayGate();
      for (var second = 0; second <= 600; second += 1) {
        gate.evaluate(
          plan: plan(computedAt: start.add(Duration(seconds: second))),
          displayName: 'Bill',
          routeRevisionNumber: 1,
          now: start.add(Duration(seconds: second)),
        );
      }

      // Six is the arithmetic ceiling for a ten-minute excursion at a 120 s
      // floor, and it is reached however fast the caller offers plans: the
      // relayed bound does not depend on the local recompute policy at all.
      expect(gate.sharedCount, 6);
      expect(
        gate.sharedCount,
        maximumRejoinSharesOver(const Duration(minutes: 10)),
      );
    });

    test('a severity or target change does not buy an extra share', () {
      final gate = RejoinRouteRelayGate();
      gate.evaluate(
        plan: plan(computedAt: start),
        displayName: 'Bill',
        routeRevisionNumber: 1,
        now: start,
      );
      // Escalating to massively off course and switching to the TEC target: the
      // leader already has the unthrottled deviation alert for both, so the
      // geometry still waits its turn.
      final escalated = gate.evaluate(
        plan: plan(
          computedAt: start.add(const Duration(seconds: 50)),
          severity: RouteRejoinSeverity.massivelyOffRoute,
          target: RouteRejoinTarget.tailEndCharlie,
        ),
        displayName: 'Bill',
        routeRevisionNumber: 1,
        now: start.add(const Duration(seconds: 50)),
      );

      expect(escalated.action, RejoinRouteRelayAction.skip);
      expect(escalated.reason, 'rate-limited');
      expect(gate.sharedCount, 1);

      final afterInterval = gate.evaluate(
        plan: plan(
          computedAt: start.add(const Duration(seconds: 125)),
          severity: RouteRejoinSeverity.massivelyOffRoute,
          target: RouteRejoinTarget.tailEndCharlie,
        ),
        displayName: 'Bill',
        routeRevisionNumber: 1,
        now: start.add(const Duration(seconds: 125)),
      );
      expect(afterInterval.action, RejoinRouteRelayAction.share);
      expect(afterInterval.share?.target, RouteRejoinTarget.tailEndCharlie);
    });

    test('a bounded breadcrumb keeps the event inside the schema limits', () {
      final gate = RejoinRouteRelayGate();
      final decision = gate.evaluate(
        plan: plan(computedAt: start, points: breadcrumb(points: 400)),
        displayName: 'Bill',
        routeRevisionNumber: 1,
        now: start,
      );
      final share = decision.share!;

      expect(share.breadcrumb, hasLength(60));
      // First and last point survive: the line still starts at the rider and
      // ends where the routing engine put the rejoin.
      expect(share.breadcrumb.first, breadcrumb(points: 400).first);
      expect(share.breadcrumb.last, breadcrumb(points: 400).last);
      final encoded = utf8.encode(
        jsonEncode(
          SharedRejoinRouteReducer.payload(
            share: share,
            leaderRiderId: 'leader',
          ),
        ),
      );
      // The event schema rejects a payload over 8 KiB and a list over 128
      // entries; both hold with room to spare.
      expect(encoded.length, lessThan(4 * 1024));
      expect(share.breadcrumb.length, lessThan(128));
    });
  });

  group('expiry', () {
    test('rejoining clears the share immediately, exempt from the interval', () {
      final gate = RejoinRouteRelayGate();
      gate.evaluate(
        plan: plan(computedAt: start),
        displayName: 'Bill',
        routeRevisionNumber: 1,
        now: start,
      );
      final cleared = gate.evaluate(
        plan: plan(
          computedAt: start.add(const Duration(seconds: 5)),
          severity: RouteRejoinSeverity.onRoute,
          status: RouteRejoinStatus.notRequired,
          target: null,
          points: const [],
        ),
        displayName: 'Bill',
        routeRevisionNumber: 1,
        now: start.add(const Duration(seconds: 5)),
      );

      expect(cleared.action, RejoinRouteRelayAction.clear);
      expect(cleared.share?.cleared, isTrue);
      expect(cleared.share?.hasBreadcrumb, isFalse);
      expect(gate.clearedCount, 1);

      // Nothing shared, nothing to clear: a rider who is on route generates no
      // events at all.
      final again = gate.evaluate(
        plan: null,
        displayName: 'Bill',
        routeRevisionNumber: 1,
        now: start.add(const Duration(seconds: 10)),
      );
      expect(again.action, RejoinRouteRelayAction.skip);
      expect(again.reason, 'nothing-shared');
    });

    test('a route change clears the share', () {
      final gate = RejoinRouteRelayGate();
      gate.evaluate(
        plan: plan(computedAt: start),
        displayName: 'Bill',
        routeRevisionNumber: 1,
        now: start,
      );
      final cleared = gate.evaluate(
        plan: plan(computedAt: start.add(const Duration(seconds: 5))),
        displayName: 'Bill',
        routeRevisionNumber: 2,
        now: start.add(const Duration(seconds: 5)),
      );

      expect(cleared.action, RejoinRouteRelayAction.clear);
      expect(cleared.share?.routeRevisionNumber, 1);
    });

    test('the ride ending clears the share', () {
      final gate = RejoinRouteRelayGate();
      gate.evaluate(
        plan: plan(computedAt: start),
        displayName: 'Bill',
        routeRevisionNumber: 1,
        now: start,
      );
      final cleared = gate.evaluate(
        plan: plan(computedAt: start.add(const Duration(seconds: 5))),
        displayName: 'Bill',
        routeRevisionNumber: 1,
        now: start.add(const Duration(seconds: 5)),
        rideEnded: true,
      );

      expect(cleared.action, RejoinRouteRelayAction.clear);
    });

    test('a share expires on its own ten-minute lifetime', () {
      final gate = RejoinRouteRelayGate();
      final share = gate
          .evaluate(
            plan: plan(computedAt: start),
            displayName: 'Bill',
            routeRevisionNumber: 1,
            now: start,
          )
          .share!;

      expect(share.isLiveAt(start.add(const Duration(minutes: 9))), isTrue);
      expect(share.isLiveAt(start.add(const Duration(minutes: 11))), isFalse);
    });
  });

  group('leader-only visibility', () {
    const reducer = SharedRejoinRouteReducer();

    RideEvent shareEvent({
      required String id,
      required String deviceId,
      required SharedRejoinRoute share,
      required String recipient,
      String? signingSecret,
      Object? rawPayload,
    }) {
      final payload =
          rawPayload as Map<String, Object?>? ??
          SharedRejoinRouteReducer.payload(
            share: share,
            leaderRiderId: recipient,
          );
      final unsigned = RideEvent(
        id: id,
        rideId: 'ride-a',
        deviceId: deviceId,
        type: RideEventType.rejoinRouteShared,
        priority: EventPriority.routine,
        createdAt: share.computedAt,
        payload: payload,
        signature: '',
      );
      return RideEvent(
        id: id,
        rideId: 'ride-a',
        deviceId: deviceId,
        type: RideEventType.rejoinRouteShared,
        priority: EventPriority.routine,
        createdAt: share.computedAt,
        payload: payload,
        signature: RideEventAuthenticator.sign(
          unsigned,
          signingSecret ?? secret,
        ),
      );
    }

    SharedRejoinRoute billsShare({
      DateTime? computedAt,
      int revision = 1,
      bool cleared = false,
      String riderId = 'bill',
    }) {
      final at = computedAt ?? start;
      return SharedRejoinRoute(
        riderId: riderId,
        displayName: 'Bill',
        computedAt: at,
        expiresAt: at.add(const Duration(minutes: 10)),
        routeRevisionNumber: revision,
        breadcrumb: cleared ? const [] : breadcrumb(),
        cleared: cleared,
      );
    }

    Map<String, SharedRejoinRoute> reduce(
      List<RideEvent> events, {
      String localRiderId = 'leader',
      int revision = 1,
      DateTime? now,
      Iterable<String> departed = const [],
      bool rideEnded = false,
    }) => reducer.fromEvents(
      rideId: 'ride-a',
      inviteSecret: secret,
      events: events,
      localRiderId: localRiderId,
      routeRevisionNumber: revision,
      now: now ?? start.add(const Duration(minutes: 1)),
      departedRiderIds: departed,
      rideEnded: rideEnded,
    );

    test('the leader sees it and another rider does not', () {
      final events = [
        shareEvent(
          id: 'share-1',
          deviceId: 'bill',
          share: billsShare(),
          recipient: 'leader',
        ),
      ];

      final leaderView = reduce(events);
      expect(leaderView.keys, ['bill']);
      expect(leaderView['bill']!.hasBreadcrumb, isTrue);
      expect(leaderView['bill']!.mapLabel, 'Bill rejoin route');

      // Every other rider in the same ride, holding the same ride secret, gets
      // nothing: the share is addressed, and the reducer fails closed.
      expect(reduce(events, localRiderId: 'dave'), isEmpty);
      // Including the rider it belongs to - their own plan is already local.
      expect(reduce(events, localRiderId: 'bill'), isEmpty);
    });

    test(
      'a share with no recipient list is ignored, not treated as public',
      () {
        final share = billsShare();
        final events = [
          shareEvent(
            id: 'share-1',
            deviceId: 'bill',
            share: share,
            recipient: 'leader',
            rawPayload: {'share': share.toJson()},
          ),
        ];

        expect(reduce(events), isEmpty);
      },
    );

    test('a share planted on another rider is rejected', () {
      final events = [
        // Dave's device publishing a breadcrumb attributed to Bill.
        shareEvent(
          id: 'share-1',
          deviceId: 'dave',
          share: billsShare(),
          recipient: 'leader',
        ),
      ];

      expect(reduce(events), isEmpty);
    });

    test('an unsigned share is rejected', () {
      final share = billsShare();
      final events = [
        RideEvent(
          id: 'share-1',
          rideId: 'ride-a',
          deviceId: 'bill',
          type: RideEventType.rejoinRouteShared,
          priority: EventPriority.routine,
          createdAt: share.computedAt,
          payload: SharedRejoinRouteReducer.payload(
            share: share,
            leaderRiderId: 'leader',
          ),
          signature: 'b' * 64,
        ),
      ];

      expect(reduce(events), isEmpty);
    });

    test(
      'cleared, expired, superseded-route and departed shares all vanish',
      () {
        final live = shareEvent(
          id: 'share-1',
          deviceId: 'bill',
          share: billsShare(),
          recipient: 'leader',
        );

        expect(reduce([live]), isNotEmpty);
        expect(
          reduce([
            live,
            shareEvent(
              id: 'share-2',
              deviceId: 'bill',
              share: billsShare(
                computedAt: start.add(const Duration(seconds: 30)),
                cleared: true,
              ),
              recipient: 'leader',
            ),
          ]),
          isEmpty,
          reason: 'a clear retires the share',
        );
        expect(
          reduce([live], now: start.add(const Duration(minutes: 11))),
          isEmpty,
          reason: 'the share outlived its own TTL',
        );
        expect(
          reduce([live], revision: 2),
          isEmpty,
          reason: 'the route it was computed against was replaced',
        );
        expect(
          reduce([live], departed: const ['bill']),
          isEmpty,
          reason: 'a rider who has left has no rejoin route',
        );
        expect(
          reduce([live], rideEnded: true),
          isEmpty,
          reason: 'the ride ended',
        );
      },
    );

    test(
      'out-of-order and duplicate delivery converge on the newest share',
      () {
        final first = shareEvent(
          id: 'share-1',
          deviceId: 'bill',
          share: billsShare(),
          recipient: 'leader',
        );
        final second = shareEvent(
          id: 'share-2',
          deviceId: 'bill',
          share: SharedRejoinRoute(
            riderId: 'bill',
            displayName: 'Bill',
            computedAt: start.add(const Duration(minutes: 2)),
            expiresAt: start.add(const Duration(minutes: 12)),
            routeRevisionNumber: 1,
            breadcrumb: breadcrumb(points: 4, offset: 0.05),
          ),
          recipient: 'leader',
        );

        final now = start.add(const Duration(minutes: 3));
        final ordered = reduce([first, second], now: now);
        final jumbled = reduce([second, first, second, first], now: now);

        expect(ordered['bill']!.breadcrumb, hasLength(4));
        expect(jumbled['bill']!.breadcrumb, ordered['bill']!.breadcrumb);
        expect(jumbled['bill']!.computedAt, ordered['bill']!.computedAt);
      },
    );
  });

  group('decoding a peer share', () {
    test('round-trips through the wire form', () {
      final share = SharedRejoinRoute(
        riderId: 'bill',
        displayName: 'Bill',
        computedAt: start,
        expiresAt: start.add(const Duration(minutes: 10)),
        routeRevisionNumber: 3,
        severity: RouteRejoinSeverity.massivelyOffRoute,
        status: RouteRejoinStatus.routed,
        target: RouteRejoinTarget.tailEndCharlie,
        breadcrumb: breadcrumb(points: 5),
        rejoinPoint: const GeoPoint(latitude: 51.52, longitude: -0.08),
        distanceMeters: 4200,
        duration: const Duration(minutes: 6),
        requiresBacktracking: true,
      );

      final decoded = SharedRejoinRoute.tryFromJson(
        jsonDecode(jsonEncode(share.toJson())),
      )!;

      expect(decoded.riderId, 'bill');
      expect(decoded.severity, RouteRejoinSeverity.massivelyOffRoute);
      expect(decoded.target, RouteRejoinTarget.tailEndCharlie);
      expect(decoded.requiresBacktracking, isTrue);
      expect(decoded.distanceMeters, 4200);
      expect(decoded.duration, const Duration(minutes: 6));
      expect(decoded.breadcrumb, hasLength(5));
      expect(decoded.mapLabel, contains('Tail End Charlie'));
      // Coordinates are relayed to five decimal places, about 1.1 m: fine
      // enough to draw, and deliberately coarser than a rider's own fix.
      expect(decoded.breadcrumb.first.latitude, closeTo(51.5, 0.00002));
    });

    test('a malformed or oversized share is rejected, never thrown', () {
      expect(SharedRejoinRoute.tryFromJson(null), isNull);
      expect(SharedRejoinRoute.tryFromJson('not a map'), isNull);
      expect(SharedRejoinRoute.tryFromJson(const {'riderId': 'bill'}), isNull);
      expect(
        SharedRejoinRoute.tryFromJson({
          'riderId': 'bill',
          'displayName': 'Bill',
          'computedAt': start.toIso8601String(),
          'expiresAt': start.toIso8601String(),
          'routeRevision': 1,
          'breadcrumb': [
            for (var index = 0; index < 200; index += 1) [51.5, -0.1],
          ],
        }),
        isNull,
      );
      expect(
        SharedRejoinRoute.tryFromJson({
          'riderId': 'bill',
          'displayName': 'Bill',
          'computedAt': start.toIso8601String(),
          'expiresAt': start.toIso8601String(),
          'routeRevision': 1,
          'breadcrumb': [
            [200.0, -0.1],
          ],
        }),
        isNull,
      );
    });
  });
}
