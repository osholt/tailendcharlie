import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/ride_controller.dart';
import 'package:ride_relay/data/in_memory_event_store.dart';
import 'package:ride_relay/data/in_memory_session_store.dart';
import 'package:ride_relay/domain/ride_event.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/ride_session.dart';
import 'package:ride_relay/features/ride/ride_roster_sheet.dart';
import 'package:ride_relay/internet/internet_relay_client.dart';
import 'package:ride_relay/services/nearby_bridge.dart';
import 'package:ride_relay/services/ride_event_authenticator.dart';
import 'package:ride_relay/services/tec_role_assignment.dart';

/// Issue #128 part 1 from the leader's side: the roster is where a leader closes
/// the TEC gap, and it must never claim the gap is closed before the rider has
/// accepted.
void main() {
  late InMemoryEventStore eventStore;
  late InMemorySessionStore sessionStore;
  late RideController controller;
  final now = DateTime.utc(2026, 7, 26, 12);

  setUp(() async {
    eventStore = InMemoryEventStore();
    sessionStore = InMemorySessionStore();
    var id = 0;
    controller = RideController(
      eventStore,
      sessionStore,
      const _FakeNearbyBridge(),
      clock: () => now,
      idFactory: () => 'id-${(id++).toString().padLeft(3, '0')}',
      random: Random(7),
      rideCodeDirectory: _NullRideCodeDirectory(),
    );
    await controller.initialize();
    await controller.createRide('Lead');
    final session = controller.session!;
    final join = RideEvent(
      id: 'join-bill',
      rideId: session.rideId,
      deviceId: 'bill',
      type: RideEventType.riderJoined,
      priority: EventPriority.routine,
      createdAt: now,
      payload: const {'displayName': 'Bill', 'role': 'rider'},
      signature: '',
    );
    await eventStore.append(
      RideEvent(
        id: join.id,
        rideId: join.rideId,
        deviceId: join.deviceId,
        type: join.type,
        priority: join.priority,
        createdAt: join.createdAt,
        payload: join.payload,
        signature: RideEventAuthenticator.sign(join, session.inviteSecret),
      ),
    );
    await controller.reloadEvents();
  });

  tearDown(() => controller.dispose());

  Widget harness({
    bool relayCanCarryTecRequest = true,
    Set<String> legacyPeerRiderIds = const {},
  }) => MaterialApp(
    home: Scaffold(
      body: RideRosterSheet(
        controller: controller,
        relayCanCarryTecRequest: relayCanCarryTecRequest,
        legacyPeerRiderIds: legacyPeerRiderIds,
      ),
    ),
  );

  testWidgets('the leader can ask a named rider, and sees pending state', (
    tester,
  ) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    // The gap is named, and so is the way to close it.
    expect(find.byKey(const Key('roster-missing-tec-notice')), findsOneWidget);
    expect(find.textContaining('have\nto accept'), findsNothing);
    expect(find.byKey(const Key('roster-tec-request-status')), findsNothing);
    // The leader cannot ask themselves.
    expect(find.byKey(const Key('ask-tec-bill')), findsOneWidget);

    await tester.tap(find.byKey(const Key('ask-tec-bill')));
    await tester.pumpAndSettle();

    expect(controller.tecRoleAssignments.latest?.targetRiderId, 'bill');
    expect(
      controller.tecRoleAssignments.latest?.status,
      TecRoleAssignmentStatus.pending,
    );
    expect(find.byKey(const Key('roster-tec-request-status')), findsOneWidget);
    expect(
      find.textContaining('waiting for them to accept'),
      findsOneWidget,
      reason: 'the back is not covered until Bill accepts',
    );
    // The gap notice is still up: nobody holds the role yet.
    expect(find.byKey(const Key('roster-missing-tec-notice')), findsOneWidget);
  });

  testWidgets('an older relay is named instead of recording a request', (
    tester,
  ) async {
    await tester.pumpWidget(harness(relayCanCarryTecRequest: false));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('ask-tec-bill')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byKey(const Key('tec-request-outcome')), findsOneWidget);
    expect(find.textContaining('too old to pass on'), findsOneWidget);
    expect(
      controller.events.where(
        (event) => event.type == RideEventType.tecRoleRequested,
      ),
      isEmpty,
    );
  });

  testWidgets("an older peer's build is named before the request goes out", (
    tester,
  ) async {
    await tester.pumpWidget(harness(legacyPeerRiderIds: const {'bill'}));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('ask-tec-bill')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining("Bill's app is older"), findsOneWidget);
    expect(
      controller.events.where(
        (event) => event.type == RideEventType.tecRoleRequested,
      ),
      isEmpty,
    );
  });

  testWidgets('a rider who already holds the role is not asked again', (
    tester,
  ) async {
    final session = controller.session!;
    final roleChange = RideEvent(
      id: 'bill-role',
      rideId: session.rideId,
      deviceId: 'bill',
      type: RideEventType.roleChanged,
      priority: EventPriority.routine,
      createdAt: now.add(const Duration(seconds: 1)),
      payload: const {'role': 'tailEndCharlie'},
      signature: '',
    );
    await eventStore.append(
      RideEvent(
        id: roleChange.id,
        rideId: roleChange.rideId,
        deviceId: roleChange.deviceId,
        type: roleChange.type,
        priority: roleChange.priority,
        createdAt: roleChange.createdAt,
        payload: roleChange.payload,
        signature: RideEventAuthenticator.sign(
          roleChange,
          session.inviteSecret,
        ),
      ),
    );
    await controller.reloadEvents();

    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('roster-missing-tec-notice')), findsNothing);
    expect(find.byKey(const Key('ask-tec-bill')), findsNothing);
  });

  testWidgets('a rider who is not the leader sees no ask action', (
    tester,
  ) async {
    await controller.setRole(RideRole.rider);

    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('ask-tec-bill')), findsNothing);
    expect(find.byKey(const Key('roster-missing-tec-notice')), findsNothing);
  });
}

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
