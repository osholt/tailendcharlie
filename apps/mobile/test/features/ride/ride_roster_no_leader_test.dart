// The roster's side of #176: a running ride whose leader has gone.
//
//   "No option to assign, have I left? Did you get informed? Is someone else a
//    lead now?"
//   "The ride seems to continue quite happily without a leader."
//
// The notice offers the role rather than assigning it. Roles are self-selected -
// the precedent #128 set for the TEC, where the leader asks and the target's own
// `roleChanged` is what counts - so the app cannot pick a leader on the strength
// of who happens to be nearest the front.

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

void main() {
  late InMemoryEventStore eventStore;
  late RideController controller;
  final startedAt = DateTime.utc(2026, 7, 27, 14);

  setUp(() async {
    eventStore = InMemoryEventStore();
    var id = 0;
    controller = RideController(
      eventStore,
      InMemorySessionStore(),
      const _FakeNearbyBridge(),
      clock: () => startedAt.add(const Duration(minutes: 30)),
      idFactory: () => 'id-${(id++).toString().padLeft(3, '0')}',
      random: Random(13),
      rideCodeDirectory: _NullRideCodeDirectory(),
    );
    await controller.initialize();
    await controller.createRide('Oliver');
    await controller.startRide();
    final session = controller.session!;
    await eventStore.append(
      _signed(
        session: session,
        id: 'join-kate',
        deviceId: 'kate',
        type: RideEventType.riderJoined,
        createdAt: startedAt,
        payload: const {'displayName': 'Kate', 'role': 'rider'},
      ),
    );
    await controller.reloadEvents();
  });

  tearDown(() => controller.dispose());

  Widget harness() => MaterialApp(
    home: Scaffold(body: RideRosterSheet(controller: controller)),
  );

  testWidgets('no notice while somebody holds the lead', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('roster-missing-leader-notice')), findsNothing);
  });

  testWidgets('the notice appears once the ride has no leader', (tester) async {
    await controller.setRole(RideRole.rider);
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('roster-missing-leader-notice')),
      findsOneWidget,
    );
    expect(find.text('This ride has no leader'), findsOneWidget);
    // States the consequences rather than only the fact.
    expect(find.textContaining('setting the pace'), findsOneWidget);
    expect(find.textContaining('Tail End Charlie has no line'), findsOneWidget);
    expect(find.textContaining('route changes'), findsOneWidget);
  });

  testWidgets('taking the lead records it and closes the roster', (
    tester,
  ) async {
    await controller.setRole(RideRole.rider);
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('roster-take-the-lead-button')));
    await tester.pumpAndSettle();

    expect(controller.session?.role, RideRole.lead);
    expect(controller.rideHasNoLeader, isFalse);
    expect(controller.leaderRiderId, controller.session!.localRiderId);
    // Recorded as this rider's own role change, which is what makes it
    // authoritative for every other device.
    final roleChanges = controller.events.where(
      (event) => event.type == RideEventType.roleChanged,
    );
    expect(roleChanges.last.deviceId, controller.session!.localRiderId);
  });
}

RideEvent _signed({
  required RideSession session,
  required String id,
  required String deviceId,
  required RideEventType type,
  required DateTime createdAt,
  required Map<String, Object?> payload,
}) {
  final unsigned = RideEvent(
    id: id,
    rideId: session.rideId,
    deviceId: deviceId,
    type: type,
    priority: EventPriority.important,
    createdAt: createdAt,
    payload: payload,
    signature: '',
  );
  return RideEvent(
    id: unsigned.id,
    rideId: unsigned.rideId,
    deviceId: unsigned.deviceId,
    type: unsigned.type,
    priority: unsigned.priority,
    createdAt: unsigned.createdAt,
    payload: unsigned.payload,
    signature: RideEventAuthenticator.sign(unsigned, session.inviteSecret),
  );
}

class _FakeNearbyBridge extends NearbyBridge {
  const _FakeNearbyBridge();

  @override
  Future<NearbyCapabilities> capabilities() async =>
      const NearbyCapabilities.unavailable();
}

class _NullRideCodeDirectory implements RideCodeDirectory {
  @override
  Future<void> register(RideSession session) async {}

  @override
  Future<RideCodeCredentials> resolve(
    String rideCode, {
    String? joinToken,
  }) async => throw const RideCodeDirectoryException('Not used in this test.');

  @override
  void close() {}
}
