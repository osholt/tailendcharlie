import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/ride_controller.dart';
import 'package:ride_relay/data/in_memory_event_store.dart';
import 'package:ride_relay/data/in_memory_session_store.dart';
import 'package:ride_relay/domain/quick_message.dart';
import 'package:ride_relay/domain/ride_coordination_mode.dart';
import 'package:ride_relay/domain/ride_event.dart';
import 'package:ride_relay/domain/ride_session.dart';
import 'package:ride_relay/internet/internet_relay_client.dart';
import 'package:ride_relay/relay/relay_event_compatibility.dart';
import 'package:ride_relay/services/nearby_bridge.dart';
import 'package:ride_relay/services/received_quick_message.dart';
import 'package:ride_relay/services/ride_event_authenticator.dart';

/// #854 changed the set of quick messages while build 1.0.1+101 is in testers'
/// hands, and a group ride mixes the two for as long as they take to update. Both
/// directions have to degrade safely: an older phone must show the leader's words
/// and never crash or hide them, and a newer phone must read everything an older
/// one sends exactly as it did.
///
/// The older build is [_Build101], a frozen restatement of how 1.0.1+101 reads a
/// quick message. It is deliberately **not** the code under test: a decoder that
/// moved with the code could never fail.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<(RideController, RideEvent)> leaderSends(QuickMessage message) async {
    final now = DateTime.utc(2026, 10, 4, 14, 40);
    var id = 0;
    final controller = RideController(
      InMemoryEventStore(),
      InMemorySessionStore(),
      NearbyBridge(),
      clock: () => now,
      idFactory: () => 'id-${id++}',
      random: Random(7),
      rideCodeDirectory: _OfflineRideCodeDirectory(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.createRide(
      'Oliver',
      coordinationMode: RideCoordinationMode.keepTogether,
    );
    await controller.startRide();
    await controller.sendLeaderBroadcast(message);
    return (
      controller,
      controller.events.lastWhere(
        (event) => event.type == RideEventType.statusMessage,
      ),
    );
  }

  Map<String, Object?> overTheWire(RideEvent event) =>
      Map<String, Object?>.from(jsonDecode(jsonEncode(event.toJson())) as Map);

  group('a build 102 broadcast, read by build 101', () {
    test(
      'travels as an event type every build and the relay already carry',
      () async {
        for (final message in leaderBroadcastMessages) {
          final (controller, event) = await leaderSends(message);
          final wire = overTheWire(event);

          expect(
            _Build101.eventTypes,
            contains(wire['type']),
            reason: message.name,
          );
          // Not skipped as "from a newer build", which 101 could only name.
          expect(describeUnsupportedRelayEvent(wire), isNull);
          expect(RideEvent.fromJson(wire).id, event.id);
          expect(
            RideEventAuthenticator.verify(
              RideEvent.fromJson(wire),
              controller.session!.inviteSecret,
            ),
            isTrue,
          );
        }
      },
    );

    test('adds no key to the payload that 101 has not always read', () async {
      final (_, event) = await leaderSends(QuickMessage.pullOver);

      expect(
        event.payload.keys.toSet().difference(_Build101.payloadKeys),
        isEmpty,
      );
    });

    test(
      'is shown by the leader\'s own words, never dropped and never a crash',
      () async {
        for (final message in leaderBroadcastMessages) {
          final (_, event) = await leaderSends(message);

          final shown = _Build101.present(overTheWire(event));

          // 101 has no name for it, so it falls back to the label the leader's
          // phone relayed - which is the whole reason that field exists.
          expect(shown, isNotNull, reason: message.name);
          expect(shown!.kind, isNull, reason: 'a kind 101 does not know');
          expect(shown.headline, 'Oliver: ${message.label}');
        }
      },
    );

    test(
      'is pressing on a 101 phone and does not take the screen over',
      () async {
        final (_, event) = await leaderSends(QuickMessage.pullOver);

        final shown = _Build101.present(overTheWire(event))!;

        expect(shown.priority, EventPriority.important);
        expect(shown.interrupts, isFalse);
      },
    );

    test('can be acknowledged by a 101 phone, as any message can', () async {
      // The acknowledgement 101 sends is addressed to the sender and names the
      // message by event id; this build reads it as it always has.
      final (controller, event) = await leaderSends(QuickMessage.pullOver);
      final session = controller.session!;
      final unsigned = RideEvent(
        id: 'seen',
        rideId: session.rideId,
        deviceId: 'follower',
        type: RideEventType.statusMessage,
        priority: EventPriority.important,
        createdAt: event.createdAt.add(const Duration(seconds: 5)),
        payload: {
          'acknowledgesQuickMessageEventId': event.id,
          'label': 'Seen: Pull over',
          'recipientRiderIds': [session.localRiderId],
        },
        signature: '',
      );
      final seen = RideEvent(
        id: unsigned.id,
        rideId: unsigned.rideId,
        deviceId: unsigned.deviceId,
        type: unsigned.type,
        priority: unsigned.priority,
        createdAt: unsigned.createdAt,
        payload: unsigned.payload,
        signature: RideEventAuthenticator.sign(unsigned, session.inviteSecret),
      );

      final messages = const ReceivedQuickMessageReducer().fromEvents(
        rideId: session.rideId,
        inviteSecret: session.inviteSecret,
        events: [...controller.events, seen],
        localRiderId: session.localRiderId,
        now: event.createdAt.add(const Duration(minutes: 1)),
      );

      expect(messages.single.firstAcknowledgement?.riderId, 'follower');
    });

    test(
      'names that no older build knows, so none can be read as an older kind',
      () {
        for (final message in leaderBroadcastMessages) {
          expect(
            _Build101.kinds,
            isNot(contains(message.name)),
            reason: message.name,
          );
        }
      },
    );
  });

  group('a build 101 message, read by build 102', () {
    test(
      'every older kind still parses to itself, with the words and priority it had',
      () {
        for (final entry in _Build101.table.entries) {
          final kind = tryParseQuickMessage(entry.key);

          expect(kind, isNotNull, reason: entry.key);
          expect(kind!.label, entry.value.label, reason: entry.key);
          expect(kind.priority, entry.value.priority, reason: entry.key);
        }
      },
    );

    test('is presented as it always was, with no leader rule applied', () {
      // A rider's own kinds need no role at all.
      final now = DateTime.utc(2026, 10, 4, 14, 40);
      final unsigned = RideEvent(
        id: 'fuel',
        rideId: 'ride-1',
        deviceId: 'nigel',
        type: RideEventType.statusMessage,
        priority: EventPriority.routine,
        createdAt: now,
        expiresAt: now.add(const Duration(hours: 2)),
        payload: {
          'message': 'fuel',
          'label': 'Need fuel',
          'senderDisplayName': 'Nigel',
        },
        signature: '',
      );
      final fuel = RideEvent(
        id: unsigned.id,
        rideId: unsigned.rideId,
        deviceId: unsigned.deviceId,
        type: unsigned.type,
        priority: unsigned.priority,
        createdAt: unsigned.createdAt,
        expiresAt: unsigned.expiresAt,
        payload: unsigned.payload,
        signature: RideEventAuthenticator.sign(unsigned, 'secret'),
      );

      final messages = const ReceivedQuickMessageReducer().fromEvents(
        rideId: 'ride-1',
        inviteSecret: 'secret',
        events: [fuel],
        localRiderId: 'becks',
        now: now,
      );

      expect(messages.single.headline, 'Nigel needs fuel');
    });

    test(
      'the older kinds are the first eight, in the order they always were',
      () {
        expect(
          QuickMessage.values
              .take(_Build101.table.length)
              .map((kind) => kind.name),
          _Build101.table.keys,
        );
      },
    );
  });
}

/// Build 1.0.1+101's reading of a quick message, restated by hand.
abstract final class _Build101 {
  /// Its `RideEventType`, by name.
  static const eventTypes = {
    'rideCreated',
    'riderJoined',
    'riderLeft',
    'roleChanged',
    'rideStarted',
    'markerStarted',
    'markerPass',
    'markerEnded',
    'statusMessage',
    'riderLocationUpdated',
    'hazardReported',
    'hazardCleared',
    'routeDeviationChanged',
    'routeAlertAcknowledged',
    'routeRevisionChunk',
    'routeRevisionPublished',
    'routeCleared',
    'ridePaused',
    'rideResumed',
    'rideEnded',
    'iceInfoShared',
    'iceInfoViewed',
    'tecRoleRequested',
    'tecRoleResponded',
    'rejoinRouteShared',
    'riderContactShared',
    'rideReopened',
  };

  /// Its `QuickMessage` kinds, with the label and priority each had.
  static const table = <String, ({String label, EventPriority priority})>{
    'stopped': (label: 'Stopped', priority: EventPriority.routine),
    'mechanical': (label: 'Mechanical', priority: EventPriority.important),
    'fuel': (label: 'Need fuel', priority: EventPriority.routine),
    'assistance': (label: 'Need help', priority: EventPriority.critical),
    'routeBlocked': (label: 'Route blocked', priority: EventPriority.important),
    'emergencyStop': (
      label: 'Emergency stop',
      priority: EventPriority.critical,
    ),
    'allPassed': (label: 'All riders passed', priority: EventPriority.routine),
    'resolved': (label: 'Resolved', priority: EventPriority.routine),
  };

  static Set<String> get kinds => table.keys.toSet();

  /// The keys of a quick message's payload it has always read.
  static const payloadKeys = {
    'message',
    'label',
    'senderDisplayName',
    'position',
    'recipientRiderIds',
    'acknowledgesQuickMessageEventId',
  };

  /// `ReceivedQuickMessageReducer` as 101 had it, for one message: a label that is
  /// a non-empty string, a kind it may not know, the kind's priority when it knows
  /// it and the envelope's when it does not, and a headline built from the kind's
  /// sentence or, failing that, "name: label".
  static ({
    String? kind,
    EventPriority priority,
    bool interrupts,
    String headline,
  })?
  present(Map<String, Object?> wire) {
    final payload = Map<String, Object?>.from(wire['payload']! as Map);
    final label = payload['label'];
    if (label is! String || label.isEmpty) return null;
    final name = payload['message'];
    final known = name is String && table.containsKey(name) ? name : null;
    final priority = known == null
        ? EventPriority.values.byName(wire['priority']! as String)
        : table[known]!.priority;
    final sender = (payload['senderDisplayName'] as String?)?.trim();
    return (
      kind: known,
      priority: priority,
      interrupts: priority == EventPriority.critical,
      headline:
          '${sender == null || sender.isEmpty ? 'A rider' : sender}: $label',
    );
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
