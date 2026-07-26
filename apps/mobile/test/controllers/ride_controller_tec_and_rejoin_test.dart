import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/ride_controller.dart';
import 'package:ride_relay/data/in_memory_event_store.dart';
import 'package:ride_relay/data/in_memory_session_store.dart';
import 'package:ride_relay/domain/geo_point.dart';
import 'package:ride_relay/domain/ride_event.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/ride_session.dart';
import 'package:ride_relay/internet/internet_relay_client.dart';
import 'package:ride_relay/services/nearby_bridge.dart';
import 'package:ride_relay/services/rejoin_route_share.dart';
import 'package:ride_relay/services/ride_event_authenticator.dart';
import 'package:ride_relay/services/tec_role_assignment.dart';

/// Issue #128 end-to-end through [RideController]: the two writes, their guards,
/// and that both survive a restart from the durable journal alone.
void main() {
  late InMemoryEventStore eventStore;
  late InMemorySessionStore sessionStore;
  late RideController controller;
  late int id;
  var now = DateTime.utc(2026, 7, 26, 12);

  RideController build() => RideController(
    eventStore,
    sessionStore,
    const _FakeNearbyBridge(),
    clock: () => now,
    idFactory: () => 'id-${(id++).toString().padLeft(3, '0')}',
    random: Random(42),
    rideCodeDirectory: _NullRideCodeDirectory(),
  );

  setUp(() async {
    eventStore = InMemoryEventStore();
    sessionStore = InMemorySessionStore();
    id = 0;
    now = DateTime.utc(2026, 7, 26, 12);
    controller = build();
    await controller.initialize();
  });

  tearDown(() => controller.dispose());

  /// Puts a second rider in the ride by appending their signed join event, the
  /// way the relay would deliver it.
  Future<void> addRider(String riderId, String displayName) async {
    final session = controller.session!;
    await eventStore.append(
      _sign(
        RideEvent(
          id: 'join-$riderId',
          rideId: session.rideId,
          deviceId: riderId,
          type: RideEventType.riderJoined,
          priority: EventPriority.routine,
          createdAt: now,
          payload: {'displayName': displayName, 'role': 'rider'},
          signature: '',
        ),
        session.inviteSecret,
      ),
    );
    await controller.reloadEvents();
  }

  group('a leader asking a rider to be Tail End Charlie', () {
    test('records a signed, addressed request the rider can answer', () async {
      await controller.createRide('Lead');
      await addRider('bill', 'Bill');

      final outcome = await controller.requestTecRole(
        targetRiderId: 'bill',
        targetDisplayName: 'Bill',
      );

      expect(outcome, TecRoleRequestOutcome.sent);
      final request = controller.events.singleWhere(
        (event) => event.type == RideEventType.tecRoleRequested,
      );
      expect(request.deviceId, controller.session!.localRiderId);
      expect(request.payload['targetRiderId'], 'bill');
      expect(request.payload['leaderRiderId'], request.deviceId);
      expect(request.signature, hasLength(64));
      expect(request.priority, EventPriority.important);

      final assignment = controller.tecRoleAssignments.latest!;
      expect(assignment.status, TecRoleAssignmentStatus.pending);
      // The leader is not told the back is covered yet.
      expect(controller.tecRoleAssignments.acceptedTecRiderId, isNull);
    });

    test(
      'is refused when the relay cannot carry it, recording nothing',
      () async {
        await controller.createRide('Lead');
        await addRider('bill', 'Bill');

        final outcome = await controller.requestTecRole(
          targetRiderId: 'bill',
          targetDisplayName: 'Bill',
          relayCanCarryRequest: false,
        );

        expect(outcome, TecRoleRequestOutcome.relayUnsupported);
        expect(
          controller.events.where(
            (event) => event.type == RideEventType.tecRoleRequested,
          ),
          isEmpty,
          reason: 'a request that cannot leave this phone must not look sent',
        );
        expect(controller.tecRoleAssignments.latest, isNull);
      },
    );

    test(
      'is refused for a rider who is not in the ride, or for oneself',
      () async {
        await controller.createRide('Lead');
        await addRider('bill', 'Bill');

        expect(
          await controller.requestTecRole(
            targetRiderId: 'nobody',
            targetDisplayName: 'Nobody',
          ),
          TecRoleRequestOutcome.invalidTarget,
        );
        expect(
          await controller.requestTecRole(
            targetRiderId: controller.session!.localRiderId,
            targetDisplayName: 'Lead',
          ),
          TecRoleRequestOutcome.invalidTarget,
        );
      },
    );

    test('is refused from a rider who is not the leader', () async {
      await controller.createRide('Lead');
      await addRider('bill', 'Bill');
      await controller.setRole(RideRole.rider);

      expect(
        await controller.requestTecRole(
          targetRiderId: 'bill',
          targetDisplayName: 'Bill',
        ),
        TecRoleRequestOutcome.notLeader,
      );
      expect(
        controller.events.where(
          (event) => event.type == RideEventType.tecRoleRequested,
        ),
        isEmpty,
      );
    });
  });

  group('the target answering', () {
    /// A ride where the leader is another device and this phone was asked.
    Future<void> joinAsAskedRider() async {
      await controller.createRide('Bill');
      // This phone is a rider; 'leader' is the lead.
      await controller.setRole(RideRole.rider);
      final session = controller.session!;
      await eventStore.append(
        _sign(
          RideEvent(
            id: 'leader-join',
            rideId: session.rideId,
            deviceId: 'leader',
            type: RideEventType.riderJoined,
            priority: EventPriority.routine,
            createdAt: now,
            payload: const {'displayName': 'Lead', 'role': 'lead'},
            signature: '',
          ),
          session.inviteSecret,
        ),
      );
      await eventStore.append(
        _sign(
          RideEvent(
            id: 'leader-request',
            rideId: session.rideId,
            deviceId: 'leader',
            type: RideEventType.tecRoleRequested,
            priority: EventPriority.important,
            createdAt: now.add(const Duration(seconds: 5)),
            payload: TecRoleAssignmentReducer.requestPayload(
              requestId: 'req-1',
              leaderRiderId: 'leader',
              targetRiderId: session.localRiderId,
              targetDisplayName: 'Bill',
            ),
            signature: '',
          ),
          session.inviteSecret,
        ),
      );
      await controller.reloadEvents();
    }

    test('accepting takes the role and tells the leader', () async {
      await joinAsAskedRider();
      expect(controller.pendingTecRoleRequestForLocalRider?.requestId, 'req-1');

      final answered = await controller.respondToTecRoleRequest(
        requestId: 'req-1',
        accepted: true,
      );

      expect(answered, isTrue);
      // The role itself is still self-selected: acceptance records this
      // device's own roleChanged, so the membership reducer is untouched.
      expect(controller.session!.role, RideRole.tailEndCharlie);
      final roleChange = controller.events.lastWhere(
        (event) => event.type == RideEventType.roleChanged,
      );
      expect(roleChange.deviceId, controller.session!.localRiderId);
      expect(roleChange.payload['role'], 'tailEndCharlie');
      final response = controller.events.singleWhere(
        (event) => event.type == RideEventType.tecRoleResponded,
      );
      expect(response.payload['accepted'], isTrue);
      expect(response.deviceId, controller.session!.localRiderId);
      expect(
        controller.tecRoleAssignments.acceptedTecRiderId,
        controller.session!.localRiderId,
      );
      expect(controller.pendingTecRoleRequestForLocalRider, isNull);

      // And it survives a restart from the journal alone.
      final restored = build();
      await restored.initialize();
      addTearDown(restored.dispose);
      expect(
        restored.tecRoleAssignments.acceptedTecRiderId,
        controller.session!.localRiderId,
      );
      expect(restored.session!.role, RideRole.tailEndCharlie);
    });

    test('declining leaves the role alone and is recorded', () async {
      await joinAsAskedRider();

      final answered = await controller.respondToTecRoleRequest(
        requestId: 'req-1',
        accepted: false,
      );

      expect(answered, isTrue);
      expect(controller.session!.role, RideRole.rider);
      expect(
        controller.tecRoleAssignments.latest?.status,
        TecRoleAssignmentStatus.declined,
      );
      expect(controller.tecRoleAssignments.acceptedTecRiderId, isNull);
    });

    test(
      'a rider cannot answer a request that was not addressed to them',
      () async {
        await controller.createRide('Lead');
        await addRider('bill', 'Bill');
        await controller.requestTecRole(
          targetRiderId: 'bill',
          targetDisplayName: 'Bill',
        );
        final requestId = controller.tecRoleAssignments.latest!.requestId;

        // The leader's own phone trying to accept on Bill's behalf.
        expect(
          await controller.respondToTecRoleRequest(
            requestId: requestId,
            accepted: true,
          ),
          isFalse,
        );
        expect(
          controller.events.where(
            (event) => event.type == RideEventType.tecRoleResponded,
          ),
          isEmpty,
        );
        expect(
          controller.tecRoleAssignments.latest?.status,
          TecRoleAssignmentStatus.pending,
        );
      },
    );
  });

  group('sharing a rejoin route with the leader', () {
    SharedRejoinRoute share(String riderId) => SharedRejoinRoute(
      riderId: riderId,
      displayName: 'Bill',
      computedAt: now,
      expiresAt: now.add(const Duration(minutes: 10)),
      routeRevisionNumber: 0,
      breadcrumb: const [
        GeoPoint(latitude: 51.5, longitude: -0.1),
        GeoPoint(latitude: 51.51, longitude: -0.09),
      ],
    );

    Future<void> joinWithALeader() async {
      await controller.createRide('Bill');
      await controller.setRole(RideRole.rider);
      final session = controller.session!;
      await eventStore.append(
        _sign(
          RideEvent(
            id: 'leader-join',
            rideId: session.rideId,
            deviceId: 'leader',
            type: RideEventType.riderJoined,
            priority: EventPriority.routine,
            createdAt: now,
            payload: const {'displayName': 'Lead', 'role': 'lead'},
            signature: '',
          ),
          session.inviteSecret,
        ),
      );
      await controller.reloadEvents();
    }

    test('addresses the event to the leader and to nobody else', () async {
      await joinWithALeader();

      final sent = await controller.shareRejoinRoute(
        share(controller.session!.localRiderId),
      );

      expect(sent, isTrue);
      final event = controller.events.singleWhere(
        (item) => item.type == RideEventType.rejoinRouteShared,
      );
      expect(event.payload['recipientRiderIds'], ['leader']);
      expect(event.expiresAt, now.add(const Duration(minutes: 10)));
      expect(event.signature, hasLength(64));
    });

    test('records nothing when there is no leader to address', () async {
      // A lone rider: this phone is the leader, so there is nobody to send to.
      await controller.createRide('Lead');

      expect(
        await controller.shareRejoinRoute(
          share(controller.session!.localRiderId),
        ),
        isFalse,
      );
      expect(
        controller.events.where(
          (event) => event.type == RideEventType.rejoinRouteShared,
        ),
        isEmpty,
      );
    });

    test('records nothing when the relay cannot carry it', () async {
      await joinWithALeader();

      expect(
        await controller.shareRejoinRoute(
          share(controller.session!.localRiderId),
          relayCanCarryShare: false,
        ),
        isFalse,
      );
      expect(
        controller.events.where(
          (event) => event.type == RideEventType.rejoinRouteShared,
        ),
        isEmpty,
      );
    });

    test('refuses to publish a plan attributed to another rider', () async {
      await joinWithALeader();

      expect(await controller.shareRejoinRoute(share('someone-else')), isFalse);
      expect(
        controller.events.where(
          (event) => event.type == RideEventType.rejoinRouteShared,
        ),
        isEmpty,
      );
    });

    test(
      'the addressed leader reads it back; the ride ending clears it',
      () async {
        await controller.createRide('Lead');
        await addRider('bill', 'Bill');
        final session = controller.session!;
        final billsShare = SharedRejoinRoute(
          riderId: 'bill',
          displayName: 'Bill',
          computedAt: now,
          expiresAt: now.add(const Duration(minutes: 10)),
          routeRevisionNumber: 0,
          breadcrumb: const [
            GeoPoint(latitude: 51.5, longitude: -0.1),
            GeoPoint(latitude: 51.51, longitude: -0.09),
          ],
        );
        await eventStore.append(
          _sign(
            RideEvent(
              id: 'bill-share',
              rideId: session.rideId,
              deviceId: 'bill',
              type: RideEventType.rejoinRouteShared,
              priority: EventPriority.routine,
              createdAt: now,
              payload: SharedRejoinRouteReducer.payload(
                share: billsShare,
                leaderRiderId: session.localRiderId,
              ),
              signature: '',
            ),
            session.inviteSecret,
          ),
        );
        await controller.reloadEvents();

        expect(controller.sharedRejoinRoutes.keys, ['bill']);
        expect(controller.sharedRejoinRoutes['bill']!.breadcrumb, hasLength(2));

        await controller.endRide();
        expect(controller.sharedRejoinRoutes, isEmpty);
      },
    );
  });
}

RideEvent _sign(RideEvent event, String secret) => RideEvent(
  id: event.id,
  rideId: event.rideId,
  deviceId: event.deviceId,
  type: event.type,
  priority: event.priority,
  createdAt: event.createdAt,
  expiresAt: event.expiresAt,
  payload: event.payload,
  signature: RideEventAuthenticator.sign(event, secret),
);

class _FakeNearbyBridge extends NearbyBridge {
  const _FakeNearbyBridge();

  @override
  Future<NearbyCapabilities> capabilities() async => const NearbyCapabilities(
    platform: 'test',
    nativeBridgeReady: true,
    nearbyApiLinked: false,
    status: 'phase0',
  );
}

class _NullRideCodeDirectory implements RideCodeDirectory {
  @override
  Future<void> register(RideSession session) async {}

  @override
  Future<RideCodeCredentials> resolve(String rideCode, {String? joinToken}) =>
      throw const RideCodeDirectoryException('Not used in this test');

  @override
  void close() {}
}
