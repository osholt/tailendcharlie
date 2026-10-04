import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/quick_message.dart';
import 'package:ride_relay/domain/ride_coordination_mode.dart';
import 'package:ride_relay/domain/ride_event.dart';
import 'package:ride_relay/services/leader_broadcast.dart';
import 'package:ride_relay/services/received_quick_message.dart';

/// #854: the leader's one-tap broadcasts. These are the pure rules - what the four
/// messages are, who is offered them, and what the natural voice says - so they can
/// be read and held without a ride.
void main() {
  final now = DateTime.utc(2026, 10, 4, 14, 40);

  group('the four broadcasts', () {
    test('are the four the leader asked for, in this order', () {
      expect(leaderBroadcastMessages, [
        QuickMessage.wrongWay,
        QuickMessage.stoppedForFuel,
        QuickMessage.pullOver,
        QuickMessage.regroupNextStop,
      ]);
      expect(leaderBroadcastMessages.map((message) => message.label), [
        'Wrong way – turn around',
        'Stopped for fuel',
        'Pull over',
        'Regroup at next stop',
      ]);
    });

    test('are the only quick messages that are leader broadcasts', () {
      for (final message in QuickMessage.values) {
        expect(
          message.isLeaderBroadcast,
          leaderBroadcastMessages.contains(message),
          reason: message.name,
        );
      }
    });

    test('extend the existing kinds without touching them', () {
      // Appended, so no older kind changed its wire name or its position.
      expect(QuickMessage.values.take(8), [
        QuickMessage.stopped,
        QuickMessage.mechanical,
        QuickMessage.fuel,
        QuickMessage.assistance,
        QuickMessage.routeBlocked,
        QuickMessage.emergencyStop,
        QuickMessage.allPassed,
        QuickMessage.resolved,
      ]);
      expect(QuickMessage.fuel.label, 'Need fuel');
      expect(QuickMessage.fuel.priority, EventPriority.routine);
      expect(QuickMessage.emergencyStop.priority, EventPriority.critical);
      expect(QuickMessage.fuel.isLeaderBroadcast, isFalse);
      // "Stopped for fuel" is the leader saying they have stopped, not a rider
      // needing it; the two must not be the same message.
      expect(QuickMessage.stoppedForFuel, isNot(QuickMessage.fuel));
    });

    test('are pressing, never an emergency', () {
      // Critical would blank the map at speed. These take the alert palette and
      // are read out, and that is all.
      for (final message in leaderBroadcastMessages) {
        expect(message.priority, EventPriority.important, reason: message.name);
      }
    });

    test('each reads as a sentence naming the leader', () {
      expect(
        QuickMessage.wrongWay.sentenceFor('Oliver'),
        'Oliver says wrong way, turn around',
      );
      expect(
        QuickMessage.stoppedForFuel.sentenceFor('Oliver'),
        'Oliver has stopped for fuel',
      );
      expect(
        QuickMessage.pullOver.sentenceFor('Oliver'),
        'Oliver says pull over',
      );
      expect(
        QuickMessage.regroupNextStop.sentenceFor('Oliver'),
        'Oliver says regroup at the next stop',
      );
    });

    test('live ten minutes, not the two hours of a rider\'s own message', () {
      expect(leaderBroadcastLife, const Duration(minutes: 10));
    });

    test('are never retiring, which only "Resolved" is', () {
      for (final message in leaderBroadcastMessages) {
        expect(message.retiresEarlierMessages, isFalse, reason: message.name);
      }
    });

    test('a build that does not know one still gets the leader\'s own words', () {
      // The relayed event carries `label`, and `tryParseQuickMessage` returns null
      // for a name an older build lacks, so the banner reads the label instead.
      expect(tryParseQuickMessage('pullOver'), QuickMessage.pullOver);
      expect(tryParseQuickMessage('slowDown'), isNull);
    });
  });

  group('who is offered them', () {
    bool offered({
      bool leader = true,
      bool started = true,
      bool ended = false,
      RideCoordinationMode mode = RideCoordinationMode.keepTogether,
    }) => leaderBroadcastsAvailable(
      isLocalRideLeader: leader,
      rideStarted: started,
      rideEnded: ended,
      coordinationMode: mode,
    );

    test('the leader of a running group ride', () {
      expect(offered(), isTrue);
      expect(offered(mode: RideCoordinationMode.secondBikeDropOff), isTrue);
    });

    test('nobody else', () {
      expect(offered(leader: false), isFalse);
    });

    test('not before the ride starts, nor after it ends', () {
      expect(offered(started: false), isFalse);
      expect(offered(ended: true), isFalse);
      expect(offered(started: false, ended: true), isFalse);
    });

    test('not a solo ride, which has nobody to tell', () {
      expect(offered(mode: RideCoordinationMode.solo), isFalse);
    });

    test('every combination, so no new input can quietly widen the rule', () {
      for (final leader in [true, false]) {
        for (final started in [true, false]) {
          for (final ended in [true, false]) {
            for (final mode in RideCoordinationMode.values) {
              expect(
                offered(
                  leader: leader,
                  started: started,
                  ended: ended,
                  mode: mode,
                ),
                leader &&
                    started &&
                    !ended &&
                    mode != RideCoordinationMode.solo,
                reason: '$leader $started $ended ${mode.name}',
              );
            }
          }
        }
      }
    });
  });

  group('what the natural voice says', () {
    ReceivedQuickMessage received({
      QuickMessage kind = QuickMessage.pullOver,
      String sender = 'Oliver',
      bool local = false,
      Duration age = Duration.zero,
      String eventId = 'event-1',
    }) => ReceivedQuickMessage(
      eventId: eventId,
      senderRiderId: 'oliver',
      senderDisplayName: sender,
      label: kind.label,
      priority: kind.priority,
      raisedAt: now.subtract(age),
      raisedFromLocalRider: local,
      message: kind,
    );

    test('says each broadcast as the sentence the banner shows', () {
      for (final kind in leaderBroadcastMessages) {
        expect(
          leaderBroadcastSpeech(
            message: received(kind: kind),
            now: now,
          ),
          '${kind.sentenceFor('Oliver')}.',
          reason: kind.name,
        );
      }
    });

    test('says nothing for a message that is not a leader broadcast', () {
      for (final kind in QuickMessage.values.where(
        (kind) => !kind.isLeaderBroadcast,
      )) {
        expect(
          leaderBroadcastSpeech(
            message: received(kind: kind),
            now: now,
          ),
          isNull,
          reason: kind.name,
        );
      }
    });

    test('says nothing for a kind this build does not know', () {
      final unknown = ReceivedQuickMessage(
        eventId: 'event-2',
        senderRiderId: 'oliver',
        senderDisplayName: 'Oliver',
        label: 'Slow down',
        priority: EventPriority.important,
        raisedAt: now,
        raisedFromLocalRider: false,
      );

      expect(leaderBroadcastSpeech(message: unknown, now: now), isNull);
    });

    test('does not read the leader\'s own message back to them', () {
      expect(
        leaderBroadcastSpeech(message: received(local: true), now: now),
        isNull,
      );
    });

    test(
      'says a fresh one, and not one a restart has rebuilt from the journal',
      () {
        // Rebuilt from the journal after a restart, a ten-minute-old "Pull over"
        // would be said a second time as though it were new.
        expect(
          leaderBroadcastSpeech(
            message: received(age: const Duration(seconds: 90)),
            now: now,
          ),
          isNotNull,
        );
        expect(
          leaderBroadcastSpeech(
            message: received(age: leaderBroadcastSpeechFreshness),
            now: now,
          ),
          isNotNull,
        );
        expect(
          leaderBroadcastSpeech(
            message: received(
              age: leaderBroadcastSpeechFreshness + const Duration(seconds: 1),
            ),
            now: now,
          ),
          isNull,
        );
        expect(
          leaderBroadcastSpeech(
            message: received(age: const Duration(minutes: 9)),
            now: now,
          ),
          isNull,
        );
      },
    );

    test(
      'allows for two phones\' clocks never agreeing, but not a time far ahead',
      () {
        expect(
          leaderBroadcastSpeech(
            message: received(age: const Duration(seconds: -45)),
            now: now,
          ),
          isNotNull,
        );
        expect(
          leaderBroadcastSpeech(
            message: received(age: const Duration(minutes: -30)),
            now: now,
          ),
          isNull,
        );
      },
    );

    test('is keyed by the journal event, so two copies are one broadcast', () {
      expect(
        leaderBroadcastSpeechKey(received(eventId: 'event-9')),
        leaderBroadcastSpeechKey(
          received(eventId: 'event-9', age: const Duration(seconds: 3)),
        ),
      );
      expect(
        leaderBroadcastSpeechKey(received(eventId: 'event-9')),
        isNot(leaderBroadcastSpeechKey(received(eventId: 'event-10'))),
      );
    });

    test('a leader who says the same thing twice is said twice', () {
      // Two journal events, two keys: the leader repeating "Pull over" because
      // nobody has is a deliberate repeat, not a duplicate.
      expect(
        leaderBroadcastSpeechKey(received(eventId: 'first')),
        isNot(leaderBroadcastSpeechKey(received(eventId: 'second'))),
      );
    });
  });

  group('a name made safe to say', () {
    test('keeps an ordinary name, accents and all', () {
      expect(spokenRiderName('Oliver'), 'Oliver');
      expect(spokenRiderName('Zoë O’Brien-Smith'), 'Zoë O’Brien-Smith');
      expect(spokenRiderName('J. R. R.'), 'J. R. R.');
    });

    test('drops what is not a name, and collapses the gaps it leaves', () {
      expect(spokenRiderName('  Oli\nver  '), 'Oli ver');
      expect(spokenRiderName('Bill <b>bold</b>'), 'Bill b bold b');
      expect(
        spokenRiderName('Bill; ignore the leader'),
        'Bill ignore the leader',
      );
    });

    test('is bounded, so a name cannot lengthen a safety instruction', () {
      expect(spokenRiderName('A' * 200).length, 24);
      expect(spokenRiderName('A' * 200, maximumLength: 5), 'AAAAA');
    });

    test('is "Your leader" when nothing is left', () {
      expect(spokenRiderName(''), 'Your leader');
      expect(spokenRiderName('   '), 'Your leader');
      expect(spokenRiderName('!!! ???'), 'Your leader');
      expect(spokenRiderName('\u{1F3CD}'), 'Your leader');
    });

    test('goes into the sentence as one name', () {
      final message = ReceivedQuickMessage(
        eventId: 'event-1',
        senderRiderId: 'oliver',
        senderDisplayName: 'Oliver!!! (hacker)',
        label: QuickMessage.pullOver.label,
        priority: EventPriority.important,
        raisedAt: now,
        raisedFromLocalRider: false,
        message: QuickMessage.pullOver,
      );

      expect(
        leaderBroadcastSpeech(message: message, now: now),
        'Oliver hacker says pull over.',
      );
    });
  });

  test('a double tap is one broadcast for four seconds', () {
    expect(leaderBroadcastBounceWindow, const Duration(seconds: 4));
  });

  group('what the shell asks the voice to say', () {
    ReceivedQuickMessage received(
      String eventId, {
      QuickMessage kind = QuickMessage.pullOver,
      Duration age = Duration.zero,
      bool local = false,
    }) => ReceivedQuickMessage(
      eventId: eventId,
      senderRiderId: 'oliver',
      senderDisplayName: 'Oliver',
      label: kind.label,
      priority: kind.priority,
      raisedAt: now.subtract(age),
      raisedFromLocalRider: local,
      message: kind,
    );

    test(
      'one entry per broadcast, with the key the engine remembers it by',
      () {
        final spoken = leaderBroadcastsToSpeak(
          alerts: [
            RideQuickMessageAlert(message: received('a')),
            RideQuickMessageAlert(
              message: received('b', kind: QuickMessage.wrongWay),
            ),
          ],
          now: now,
        );

        expect(spoken.map((entry) => entry.key), [
          'leader-broadcast:a',
          'leader-broadcast:b',
        ]);
        expect(spoken.map((entry) => entry.phrase), [
          'Oliver says pull over.',
          'Oliver says wrong way, turn around.',
        ]);
      },
    );

    test('a banner that stands for a repeat still says each journal event', () {
      // The leader said "Pull over" twice. One card, two events, two keys.
      final spoken = leaderBroadcastsToSpeak(
        alerts: [
          RideQuickMessageAlert(
            message: received('first'),
            repeats: [received('second')],
          ),
        ],
        now: now,
      );

      expect(spoken.map((entry) => entry.key), [
        'leader-broadcast:first',
        'leader-broadcast:second',
      ]);
    });

    test(
      'leaves out what is stale, what is the rider\'s own and what is not a broadcast',
      () {
        final spoken = leaderBroadcastsToSpeak(
          alerts: [
            RideQuickMessageAlert(
              message: received('stale', age: const Duration(minutes: 9)),
            ),
            RideQuickMessageAlert(message: received('mine', local: true)),
            RideQuickMessageAlert(
              message: received('fuel', kind: QuickMessage.fuel),
            ),
            RideQuickMessageAlert(message: received('fresh')),
          ],
          now: now,
        );

        expect(spoken.map((entry) => entry.key), ['leader-broadcast:fresh']);
      },
    );

    test('has nothing to say when there is nothing to say', () {
      expect(leaderBroadcastsToSpeak(alerts: const [], now: now), isEmpty);
    });
  });
}
