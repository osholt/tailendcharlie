import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/geo_point.dart';
import 'package:ride_relay/domain/quick_message.dart';
import 'package:ride_relay/domain/ride_event.dart';
import 'package:ride_relay/services/received_quick_message.dart';
import 'package:ride_relay/services/ride_event_authenticator.dart';

/// #854: what a phone makes of the leader's broadcasts in its journal. The rule
/// that matters is who they are admitted from - the leader at that point in the
/// ride, like a ride start or a Tail End Charlie request (#99, #128) - and the
/// rest is that they behave like every other quick message: once, until
/// acknowledged, until they expire.
void main() {
  const rideId = 'ride-1';
  const secret = 'invite-secret';
  final start = DateTime.utc(2026, 10, 4, 12);
  const here = GeoPoint(latitude: 54.15, longitude: -4.48);

  RideEvent signed(
    String id, {
    required String device,
    required RideEventType type,
    required Map<String, Object?> payload,
    required DateTime at,
    EventPriority priority = EventPriority.routine,
    DateTime? expiresAt,
    String key = secret,
  }) {
    final unsigned = RideEvent(
      id: id,
      rideId: rideId,
      deviceId: device,
      type: type,
      priority: priority,
      createdAt: at,
      expiresAt: expiresAt,
      payload: payload,
      signature: '',
    );
    return RideEvent(
      id: id,
      rideId: rideId,
      deviceId: device,
      type: type,
      priority: priority,
      createdAt: at,
      expiresAt: expiresAt,
      payload: payload,
      signature: RideEventAuthenticator.sign(unsigned, key),
    );
  }

  RideEvent role(
    String id,
    String device,
    String roleName,
    DateTime at, {
    RideEventType type = RideEventType.roleChanged,
    String key = secret,
  }) => signed(
    id,
    device: device,
    type: type,
    payload: {'role': roleName},
    at: at,
    key: key,
  );

  RideEvent broadcast(
    String id, {
    required String device,
    required DateTime at,
    QuickMessage kind = QuickMessage.pullOver,
    String name = 'Oliver',
    Duration life = leaderBroadcastLife,
    Object? recipients,
  }) => signed(
    id,
    device: device,
    type: RideEventType.statusMessage,
    payload: {
      'message': kind.name,
      'label': kind.label,
      'senderDisplayName': name,
      'position': here.toJson(),
      'recipientRiderIds': ?recipients,
    },
    at: at,
    priority: kind.priority,
    expiresAt: at.add(life),
  );

  List<ReceivedQuickMessage> read(
    Iterable<RideEvent> events, {
    String me = 'becks',
    DateTime? now,
    Iterable<String> departed = const [],
  }) => const ReceivedQuickMessageReducer().fromEvents(
    rideId: rideId,
    inviteSecret: secret,
    events: events,
    localRiderId: me,
    now: now ?? start.add(const Duration(minutes: 30)),
    departedRiderIds: departed,
  );

  final leaderCreates = role(
    'created',
    'oliver',
    'lead',
    start,
    type: RideEventType.rideCreated,
  );
  final beckJoins = role(
    'joined',
    'becks',
    'rider',
    start.add(const Duration(minutes: 1)),
    type: RideEventType.riderJoined,
  );
  final at = start.add(const Duration(minutes: 30));

  group('admitted from the leader', () {
    test(
      'a follower is shown it, in the leader\'s words, with where they were',
      () {
        final shown = read([
          leaderCreates,
          beckJoins,
          broadcast('b1', device: 'oliver', at: at),
        ], now: at.add(const Duration(seconds: 5)));

        expect(shown, hasLength(1));
        final message = shown.single;
        expect(message.message, QuickMessage.pullOver);
        expect(message.headline, 'Oliver says pull over');
        expect(message.senderRiderId, 'oliver');
        expect(message.raisedAtPosition, here);
        expect(message.raisedFromLocalRider, isFalse);
      },
    );

    test('it is pressing, and does not take the screen over', () {
      final message = read([
        leaderCreates,
        broadcast('b1', device: 'oliver', at: at),
      ], now: at).single;

      expect(message.isPressing, isTrue);
      expect(message.interrupts, isFalse);
    });

    test('goes to the whole group, as it names no recipient', () {
      final events = [
        leaderCreates,
        beckJoins,
        broadcast('b1', device: 'oliver', at: at),
      ];

      for (final me in ['becks', 'nigel', 'someone-who-joined-later']) {
        expect(
          read(events, me: me, now: at),
          hasLength(1),
          reason: me,
        );
      }
    });

    test(
      'the leader sees their own as a message of theirs, for the receipt',
      () {
        final message = read(
          [leaderCreates, broadcast('b1', device: 'oliver', at: at)],
          me: 'oliver',
          now: at,
        ).single;

        expect(message.raisedFromLocalRider, isTrue);
      },
    );
  });

  group('refused from anybody else', () {
    test('a rider who has never been the leader', () {
      final shown = read(
        [
          leaderCreates,
          beckJoins,
          // Becks forges "Pull over" on the leader's behalf, or on her own.
          broadcast('forged', device: 'becks', at: at, name: 'Oliver'),
        ],
        me: 'nigel',
        now: at,
      );

      expect(shown, isEmpty);
    });

    test('a device the journal knows nothing about', () {
      final shown = read([
        leaderCreates,
        broadcast('stranger', device: 'nobody', at: at),
      ], now: at);

      expect(shown, isEmpty);
    });

    test(
      'a role event signed with another ride\'s secret does not make a leader',
      () {
        final shown = read(
          [
            role('fake-lead', 'becks', 'lead', start, key: 'another-secret'),
            broadcast('b1', device: 'becks', at: at),
          ],
          me: 'nigel',
          now: at,
        );

        expect(shown, isEmpty);
      },
    );

    test('a broadcast signed with another ride\'s secret', () {
      final shown = read([
        leaderCreates,
        signed(
          'forged-signature',
          device: 'oliver',
          type: RideEventType.statusMessage,
          payload: {
            'message': QuickMessage.pullOver.name,
            'label': QuickMessage.pullOver.label,
          },
          at: at,
          key: 'another-secret',
        ),
      ], now: at);

      expect(shown, isEmpty);
    });

    test(
      'the leader before they were the leader, and after they handed over',
      () {
        final handsOver = [
          leaderCreates,
          beckJoins,
          broadcast('while-leading', device: 'oliver', at: at),
          role(
            'hand-over-1',
            'oliver',
            'rider',
            at.add(const Duration(minutes: 5)),
          ),
          role(
            'hand-over-2',
            'becks',
            'lead',
            at.add(const Duration(minutes: 5)),
          ),
          broadcast(
            'after-handing-over',
            device: 'oliver',
            at: at.add(const Duration(minutes: 6)),
          ),
          broadcast(
            'new-leader',
            device: 'becks',
            at: at.add(const Duration(minutes: 7)),
            name: 'Becks',
          ),
        ];

        final shown = read(
          handsOver,
          me: 'nigel',
          now: at.add(const Duration(minutes: 8)),
        );

        // The old leader's message from while they led stands; their later one is
        // not an instruction; the new leader's is.
        expect(shown.map((message) => message.eventId).toSet(), {
          'while-leading',
          'new-leader',
        });
      },
    );
  });

  group('whatever order the journal arrives in', () {
    test('a role event that arrives after the broadcast still admits it', () {
      // Two transports, two orders. The reducer is a function of the journal, not
      // of arrival, so the broadcast appears once the leader's role is known.
      final events = [broadcast('b1', device: 'oliver', at: at), leaderCreates];

      expect(read(events, now: at), hasLength(1));
      expect(read(events.reversed, now: at), hasLength(1));
    });

    test('the same event delivered twice is one message', () {
      final one = broadcast('b1', device: 'oliver', at: at);

      expect(read([leaderCreates, one, one, one], now: at), hasLength(1));
    });

    test('a leader acting as a junction marker can still be heard', () {
      // A marker session changes the phone's own role but records no roleChanged,
      // so the journal still says this rider leads.
      final marker = signed(
        'marker',
        device: 'oliver',
        type: RideEventType.markerStarted,
        payload: {'previousRole': 'lead'},
        at: at.subtract(const Duration(minutes: 1)),
      );

      expect(
        read([
          leaderCreates,
          marker,
          broadcast('b1', device: 'oliver', at: at),
        ], now: at),
        hasLength(1),
      );
    });
  });

  group('lives and ends like every other quick message', () {
    test('is on screen for ten minutes, then gone', () {
      final events = [leaderCreates, broadcast('b1', device: 'oliver', at: at)];

      expect(
        read(events, now: at.add(const Duration(minutes: 9))),
        hasLength(1),
      );
      expect(read(events, now: at.add(const Duration(minutes: 10))), isEmpty);
      expect(read(events, now: at.add(const Duration(hours: 2))), isEmpty);
    });

    test('stays until this rider says they have seen it', () {
      final events = [leaderCreates, broadcast('b1', device: 'oliver', at: at)];
      final message = read(events, now: at).single;
      final seen = signed(
        'seen',
        device: 'becks',
        type: RideEventType.statusMessage,
        payload: ReceivedQuickMessageReducer.acknowledgementPayload(
          message: message,
        ),
        at: at.add(const Duration(seconds: 20)),
        priority: EventPriority.important,
      );

      final afterwards = read([
        ...events,
        seen,
      ], now: at.add(const Duration(minutes: 1)));

      expect(afterwards.single.acknowledgedBy('becks'), isTrue);
      expect(afterwards.single.acknowledgedBy('nigel'), isFalse);
    });

    test('goes when the leader leaves the ride', () {
      final events = [leaderCreates, broadcast('b1', device: 'oliver', at: at)];

      expect(read(events, now: at, departed: ['oliver']), isEmpty);
    });

    test(
      'the same words twice are two messages, so each is said and shown',
      () {
        final events = [
          leaderCreates,
          broadcast('first', device: 'oliver', at: at),
          broadcast(
            'second',
            device: 'oliver',
            at: at.add(const Duration(seconds: 30)),
          ),
        ];

        expect(
          read(
            events,
            now: at.add(const Duration(minutes: 1)),
          ).map((m) => m.eventId).toSet(),
          {'first', 'second'},
        );
      },
    );
  });

  group('the rule is only for the leader\'s broadcasts', () {
    test('a rider\'s own quick messages need no role at all', () {
      // Fuel, mechanical, help: any rider may send them, and none changed.
      final fuel = signed(
        'fuel',
        device: 'nigel',
        type: RideEventType.statusMessage,
        payload: {
          'message': QuickMessage.fuel.name,
          'label': QuickMessage.fuel.label,
          'senderDisplayName': 'Nigel',
        },
        at: at,
      );

      expect(read([fuel], now: at).single.headline, 'Nigel needs fuel');
    });

    test('a kind this build has never heard of is shown by its own label', () {
      // Nothing says it is a broadcast, so it cannot be refused as one; it is
      // presented the way every unknown kind is, with what its sender called it.
      final future = signed(
        'future',
        device: 'nigel',
        type: RideEventType.statusMessage,
        payload: {
          'message': 'slowDown',
          'label': 'Slow down',
          'senderDisplayName': 'Nigel',
        },
        at: at,
        priority: EventPriority.important,
      );

      final message = read([future], now: at).single;

      expect(message.message, isNull);
      expect(message.headline, 'Nigel: Slow down');
    });
  });
}
