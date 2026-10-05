import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/ride_controller.dart';
import 'package:ride_relay/data/in_memory_event_store.dart';
import 'package:ride_relay/data/in_memory_session_store.dart';
import 'package:ride_relay/domain/geo_point.dart';
import 'package:ride_relay/domain/quick_message.dart';
import 'package:ride_relay/domain/ride_coordination_mode.dart';
import 'package:ride_relay/domain/ride_event.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/ride_session.dart';
import 'package:ride_relay/internet/internet_relay_client.dart';
import 'package:ride_relay/services/leader_broadcast.dart';
import 'package:ride_relay/services/nearby_bridge.dart';
import 'package:ride_relay/services/ride_event_authenticator.dart';

/// #854, the sending half: what the leader's phone records when they tap one of
/// the four broadcasts, and the cases where it must record nothing.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late InMemoryEventStore store;
  late DateTime now;
  late int nextId;

  RideController controller() {
    final created = RideController(
      store,
      InMemorySessionStore(),
      NearbyBridge(),
      clock: () => now,
      idFactory: () => 'id-${nextId++}',
      random: Random(7),
      rideCodeDirectory: _OfflineRideCodeDirectory(),
    );
    addTearDown(created.dispose);
    return created;
  }

  Future<RideController> runningRide({
    RideCoordinationMode mode = RideCoordinationMode.keepTogether,
  }) async {
    final ride = controller();
    await ride.initialize();
    await ride.createRide('Oliver', coordinationMode: mode);
    await ride.startRide();
    return ride;
  }

  List<RideEvent> statusEvents(RideController ride) => ride.events
      .where((event) => event.type == RideEventType.statusMessage)
      .toList();

  setUp(() {
    store = InMemoryEventStore();
    now = DateTime.utc(2026, 10, 4, 14, 40, 2);
    nextId = 0;
  });

  group('the leader sends one', () {
    test('as an ordinary status message to the whole group', () async {
      final ride = await runningRide();

      final outcome = await ride.sendLeaderBroadcast(
        QuickMessage.pullOver,
        position: const GeoPoint(latitude: 54.15, longitude: -4.48),
      );

      expect(outcome, LeaderBroadcastOutcome.sent);
      final event = statusEvents(ride).single;
      // The same event type every quick message already uses: the relay needs no
      // new capability and an older build reads it by its label.
      expect(event.type, RideEventType.statusMessage);
      expect(event.payload['message'], 'pullOver');
      expect(event.payload['label'], 'Pull over');
      expect(event.payload['senderDisplayName'], 'Oliver');
      expect(event.payload['position'], {
        'latitude': 54.15,
        'longitude': -4.48,
      });
      // For everyone: no recipient list.
      expect(event.payload.containsKey('recipientRiderIds'), isFalse);
      expect(event.priority, EventPriority.important);
      expect(event.expiresAt, event.createdAt.add(leaderBroadcastLife));
      expect(
        RideEventAuthenticator.verify(event, ride.session!.inviteSecret),
        isTrue,
      );
    });

    test('and it is in the journal the ride history is built from', () async {
      final ride = await runningRide();

      await ride.sendLeaderBroadcast(QuickMessage.regroupNextStop);

      expect(statusEvents(ride), hasLength(1));
    });

    test('each of the four, with its own words', () async {
      final ride = await runningRide();

      for (final message in leaderBroadcastMessages) {
        now = now.add(const Duration(seconds: 30));
        expect(
          await ride.sendLeaderBroadcast(message),
          LeaderBroadcastOutcome.sent,
          reason: message.name,
        );
      }

      expect(statusEvents(ride).map((event) => event.payload['label']), [
        'Wrong way – turn around',
        'Stopped for fuel',
        'Pull over',
        'Regroup at next stop',
      ]);
    });

    test('without a position it still goes, and says no position', () async {
      final ride = await runningRide();

      await ride.sendLeaderBroadcast(QuickMessage.wrongWay);

      expect(
        statusEvents(ride).single.payload.containsKey('position'),
        isFalse,
      );
    });

    test(
      'also while the ride is paused, when "regroup" is most useful',
      () async {
        final ride = await runningRide();
        await ride.pauseRide();

        expect(
          await ride.sendLeaderBroadcast(QuickMessage.regroupNextStop),
          LeaderBroadcastOutcome.sent,
        );
      },
    );

    test('a leader acting as a junction marker is still the leader', () async {
      final ride = await runningRide(
        mode: RideCoordinationMode.secondBikeDropOff,
      );
      await ride.startMarker();

      expect(
        await ride.sendLeaderBroadcast(QuickMessage.pullOver),
        LeaderBroadcastOutcome.sent,
      );
    });
  });

  group('and nobody else can', () {
    test('a rider who is not the leader sends nothing', () async {
      final ride = await runningRide();
      await ride.setRole(RideRole.rider);

      final outcome = await ride.sendLeaderBroadcast(QuickMessage.pullOver);

      expect(outcome, LeaderBroadcastOutcome.notLeader);
      expect(statusEvents(ride), isEmpty);
    });

    test('the Tail End Charlie sends nothing', () async {
      final ride = await runningRide();
      await ride.setRole(RideRole.tailEndCharlie);

      expect(
        await ride.sendLeaderBroadcast(QuickMessage.pullOver),
        LeaderBroadcastOutcome.notLeader,
      );
    });

    test('nothing before the ride has started', () async {
      final ride = controller();
      await ride.initialize();
      await ride.createRide(
        'Oliver',
        coordinationMode: RideCoordinationMode.keepTogether,
      );

      expect(
        await ride.sendLeaderBroadcast(QuickMessage.pullOver),
        LeaderBroadcastOutcome.notAvailable,
      );
      expect(statusEvents(ride), isEmpty);
    });

    test('nothing after it has ended', () async {
      final ride = await runningRide();
      await ride.endRide();

      expect(
        await ride.sendLeaderBroadcast(QuickMessage.pullOver),
        LeaderBroadcastOutcome.notAvailable,
      );
    });

    test('nothing on a solo ride, which has nobody to tell', () async {
      final ride = await runningRide(mode: RideCoordinationMode.solo);

      expect(
        await ride.sendLeaderBroadcast(QuickMessage.pullOver),
        LeaderBroadcastOutcome.notAvailable,
      );
    });

    test('nothing with no ride at all', () async {
      final ride = controller();
      await ride.initialize();

      expect(
        await ride.sendLeaderBroadcast(QuickMessage.pullOver),
        LeaderBroadcastOutcome.notAvailable,
      );
    });

    test(
      'a rider\'s own kinds are not broadcasts, so cannot go this way',
      () async {
        final ride = await runningRide();

        for (final message in QuickMessage.values.where(
          (m) => !m.isLeaderBroadcast,
        )) {
          expect(
            await ride.sendLeaderBroadcast(message),
            LeaderBroadcastOutcome.notABroadcast,
            reason: message.name,
          );
        }
        expect(statusEvents(ride), isEmpty);
      },
    );
  });

  group('one tap is one broadcast', () {
    test('a double tap inside four seconds is one', () async {
      final ride = await runningRide();

      final first = await ride.sendLeaderBroadcast(QuickMessage.pullOver);
      now = now.add(const Duration(seconds: 2));
      final bounce = await ride.sendLeaderBroadcast(QuickMessage.pullOver);

      expect(first, LeaderBroadcastOutcome.sent);
      expect(bounce, LeaderBroadcastOutcome.bounced);
      expect(statusEvents(ride), hasLength(1));
    });

    test('two taps in the same instant are one', () async {
      final ride = await runningRide();

      final both = await Future.wait([
        ride.sendLeaderBroadcast(QuickMessage.pullOver),
        ride.sendLeaderBroadcast(QuickMessage.pullOver),
      ]);

      expect(both, [
        LeaderBroadcastOutcome.sent,
        LeaderBroadcastOutcome.bounced,
      ]);
      expect(statusEvents(ride), hasLength(1));
    });

    test('a different broadcast straight after is not held back', () async {
      final ride = await runningRide();

      await ride.sendLeaderBroadcast(QuickMessage.wrongWay);
      now = now.add(const Duration(seconds: 1));
      final next = await ride.sendLeaderBroadcast(QuickMessage.pullOver);

      expect(next, LeaderBroadcastOutcome.sent);
      expect(statusEvents(ride), hasLength(2));
    });

    test(
      'the same one again after the window is a deliberate repeat',
      () async {
        // Nobody has pulled over, so the leader says it again.
        final ride = await runningRide();

        await ride.sendLeaderBroadcast(QuickMessage.pullOver);
        now = now.add(leaderBroadcastBounceWindow);
        final again = await ride.sendLeaderBroadcast(QuickMessage.pullOver);

        expect(again, LeaderBroadcastOutcome.sent);
        expect(statusEvents(ride), hasLength(2));
      },
    );

    test(
      'is not dropped while the controller is busy with something else',
      () async {
        // The controller's own busy guard drops a call that arrives during another;
        // a "Pull over" that was dropped would leave the leader sure the group knew.
        final ride = await runningRide();
        final pausing = ride.pauseRide();

        final outcome = await ride.sendLeaderBroadcast(QuickMessage.pullOver);
        await pausing;

        expect(outcome, LeaderBroadcastOutcome.sent);
        expect(statusEvents(ride), hasLength(1));
      },
    );
  });

  group('when it cannot be saved', () {
    test('says so, and the retry is a first attempt', () async {
      store = _FailingOnceEventStore();
      final ride = await runningRide();
      (store as _FailingOnceEventStore).failNext = true;

      final failed = await ride.sendLeaderBroadcast(QuickMessage.pullOver);
      final retried = await ride.sendLeaderBroadcast(QuickMessage.pullOver);

      expect(failed, LeaderBroadcastOutcome.failed);
      // Within the bounce window, and still sent: nothing was stored the first
      // time, so the second is not a bounce of it.
      expect(retried, LeaderBroadcastOutcome.sent);
      expect(statusEvents(ride), hasLength(1));
    });
  });

  group('what the leader is told when it did not go', () {
    test('every outcome but sent and a bounce has a sentence', () {
      for (final outcome in LeaderBroadcastOutcome.values) {
        final sentence = outcome.failureSentence;
        if (outcome == LeaderBroadcastOutcome.sent ||
            outcome == LeaderBroadcastOutcome.bounced) {
          // A bounce is the same tap twice: the group already has it.
          expect(sentence, isNull, reason: outcome.name);
        } else {
          expect(sentence, isNotNull, reason: outcome.name);
          expect(sentence, isNotEmpty, reason: outcome.name);
        }
      }
    });

    test('says the reason in words', () {
      expect(
        LeaderBroadcastOutcome.notLeader.failureSentence,
        'Only the ride leader can tell the group.',
      );
      expect(
        LeaderBroadcastOutcome.notAvailable.failureSentence,
        'There is no running group ride to tell.',
      );
      expect(
        LeaderBroadcastOutcome.failed.failureSentence,
        'It could not be saved. Try again.',
      );
    });
  });
}

/// An event store that can be told to fail its next write, as a full disk would.
class _FailingOnceEventStore extends InMemoryEventStore {
  bool failNext = false;

  @override
  Future<void> append(RideEvent event) async {
    if (failNext) {
      failNext = false;
      throw StateError('disk is full');
    }
    return super.append(event);
  }
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
