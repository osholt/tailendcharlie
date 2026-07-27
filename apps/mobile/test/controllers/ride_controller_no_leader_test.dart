// A running ride that has lost its leader (#176).
//
// A tester left the ride as leader to see what would happen:
//
//   "No option to assign, have I left? Did you get informed? Is someone else a
//    lead now?"
//
// and a remaining rider answered:
//
//   "The ride seems to continue quite happily without a leader."
//
// Nothing noticed, nobody was told, and nobody was offered the role. The
// departure itself was recorded correctly the whole time - #27 and #144 handle
// that - so what was missing was a state derived from it.

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/ride_controller.dart';
import 'package:ride_relay/data/in_memory_event_store.dart';
import 'package:ride_relay/data/in_memory_session_store.dart';
import 'package:ride_relay/domain/completed_ride_store.dart';
import 'package:ride_relay/domain/ride_event.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/ride_session.dart';
import 'package:ride_relay/internet/internet_relay_client.dart';
import 'package:ride_relay/services/nearby_bridge.dart';
import 'package:ride_relay/services/ride_event_authenticator.dart';

void main() {
  // NearbyBridge reaches a platform channel on construction.
  TestWidgetsFlutterBinding.ensureInitialized();

  late InMemoryEventStore events;
  late RideController controller;
  late DateTime now;

  setUp(() async {
    events = InMemoryEventStore();
    now = DateTime.utc(2026, 7, 27, 12);
    var id = 0;
    controller = RideController(
      events,
      InMemorySessionStore(),
      NearbyBridge(),
      clock: () => now,
      idFactory: () => 'id-${id++}',
      random: Random(11),
      rideCodeDirectory: _OfflineRideCodeDirectory(),
      completedRideStore: InMemoryCompletedRideStore(),
    );
    await controller.initialize();
  });

  tearDown(() => controller.dispose());

  /// A second rider joining, as their own device would record it.
  Future<void> joinFollower(String riderId) async {
    final session = controller.session!;
    final unsigned = RideEvent(
      id: 'joined-$riderId',
      rideId: session.rideId,
      deviceId: riderId,
      type: RideEventType.riderJoined,
      priority: EventPriority.important,
      createdAt: now,
      payload: {'displayName': riderId, 'role': RideRole.rider.name},
      signature: '',
    );
    await events.append(
      RideEvent(
        id: unsigned.id,
        rideId: unsigned.rideId,
        deviceId: unsigned.deviceId,
        type: unsigned.type,
        priority: unsigned.priority,
        createdAt: unsigned.createdAt,
        payload: unsigned.payload,
        signature: RideEventAuthenticator.sign(unsigned, session.inviteSecret),
      ),
    );
    await controller.reloadEvents();
  }

  test('a running ride with a leader is not flagged', () async {
    await controller.createRide('Oliver');
    await controller.startRide();

    expect(controller.leaderRiderId, controller.session!.localRiderId);
    expect(controller.rideHasNoLeader, isFalse);
  });

  test('a ride waiting to start is never flagged', () async {
    await controller.createRide('Oliver');

    expect(
      controller.rideHasNoLeader,
      isFalse,
      reason:
          'before the start the creator holds lead and nothing has gone '
          'wrong yet',
    );
  });

  test('the ride is flagged once the leader stops holding the role', () async {
    await controller.createRide('Oliver');
    await controller.startRide();
    await joinFollower('rider-2');

    // The leader hands their role away without anyone taking lead - the same
    // end state as the leader leaving, reached from this device.
    await controller.setRole(RideRole.rider);

    expect(controller.leaderRiderId, isNull);
    expect(
      controller.rideHasNoLeader,
      isTrue,
      reason: 'a running ride with nobody on lead has no leader',
    );
  });

  test('taking the lead clears it', () async {
    await controller.createRide('Oliver');
    await controller.startRide();
    await joinFollower('rider-2');
    await controller.setRole(RideRole.rider);
    expect(controller.rideHasNoLeader, isTrue);

    await controller.setRole(RideRole.lead);

    expect(controller.rideHasNoLeader, isFalse);
    expect(controller.leaderRiderId, controller.session!.localRiderId);
  });

  test('an ended ride is not flagged', () async {
    await controller.createRide('Oliver');
    await controller.startRide();
    await controller.setRole(RideRole.rider);
    expect(controller.rideHasNoLeader, isTrue);

    // endRide requires the lead role, so take it back to end the ride.
    await controller.setRole(RideRole.lead);
    await controller.endRide();

    expect(
      controller.rideHasNoLeader,
      isFalse,
      reason: 'there is nothing left to lead',
    );
  });

  test('a forged role change cannot make somebody else the leader', () async {
    await controller.createRide('Oliver');
    await controller.startRide();
    await joinFollower('rider-2');
    await controller.setRole(RideRole.rider);
    final session = controller.session!;

    // A device claiming *another* rider took the lead. Roles are self-selected,
    // so this is the forgery that matters: not "I am leader now", which any
    // rider may legitimately say, but "they are".
    final forged = RideEvent(
      id: 'forged-promotion',
      rideId: session.rideId,
      deviceId: 'rider-2',
      type: RideEventType.roleChanged,
      priority: EventPriority.important,
      createdAt: now,
      payload: {'role': RideRole.lead.name},
      // Signed with the wrong secret: a device outside the ride.
      signature: RideEventAuthenticator.sign(
        RideEvent(
          id: 'forged-promotion',
          rideId: session.rideId,
          deviceId: 'rider-2',
          type: RideEventType.roleChanged,
          priority: EventPriority.important,
          createdAt: now,
          payload: {'role': RideRole.lead.name},
          signature: '',
        ),
        'not-this-rides-secret',
      ),
    );
    await events.append(forged);
    await controller.reloadEvents();

    expect(
      controller.leaderRiderId,
      isNull,
      reason: 'an unsigned promotion must not install a leader',
    );
    expect(controller.rideHasNoLeader, isTrue);
  });
}

class _OfflineRideCodeDirectory implements RideCodeDirectory {
  @override
  Future<void> register(RideSession session) async {}

  @override
  Future<RideCodeCredentials> resolve(
    String rideCode, {
    String? joinToken,
  }) async => throw const RideCodeDirectoryException('Offline in tests.');

  @override
  void close() {}
}
