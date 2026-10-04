import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/services/transport_evidence_ledger.dart';

/// #855: which path delivered each update from the other riders, and which was
/// first. The 4 October ride could not answer "was that the phone signal or real
/// phone-to-phone sharing?" because nothing recorded the route an update took.
void main() {
  final start = DateTime.utc(2026, 10, 4, 10);
  late DateTime now;
  late TransportEvidenceLedger ledger;

  void advance(Duration by) => now = now.add(by);

  setUp(() {
    now = start;
    ledger = TransportEvidenceLedger(localRiderId: 'me', clock: () => now);
  });

  void event(
    EvidenceTransport transport,
    String id, {
    String author = 'alex',
  }) => ledger.recordEvent(transport: transport, eventId: id, authorId: author);

  group('which transport delivered an event first', () {
    test('an event only Bluetooth has delivered is first on Bluetooth', () {
      event(EvidenceTransport.bluetooth, 'e1');

      final alex = ledger.evidenceFor('alex')!;
      expect(alex.bluetooth.events, 1);
      expect(alex.bluetooth.firstDelivered, 1);
      expect(alex.internet.events, 0);
      expect(alex.internet.firstDelivered, 0);
    });

    test(
      'an event only the internet has delivered is first on the internet',
      () {
        event(EvidenceTransport.internet, 'e1');

        final alex = ledger.evidenceFor('alex')!;
        expect(alex.internet.events, 1);
        expect(alex.internet.firstDelivered, 1);
        expect(alex.bluetooth.events, 0);
      },
    );

    test(
      'the second route is counted, and is not credited with being first',
      () {
        event(EvidenceTransport.internet, 'e1');
        advance(const Duration(seconds: 2));
        event(EvidenceTransport.bluetooth, 'e1');

        final alex = ledger.evidenceFor('alex')!;
        // Both delivered it, so both have it in `events`...
        expect(alex.internet.events, 1);
        expect(alex.bluetooth.events, 1);
        // ...but only the internet was first.
        expect(alex.internet.firstDelivered, 1);
        expect(alex.bluetooth.firstDelivered, 0);
      },
    );

    test('every distinct event has exactly one first-delivering transport', () {
      for (var index = 0; index < 5; index += 1) {
        event(EvidenceTransport.bluetooth, 'b$index');
      }
      for (var index = 0; index < 3; index += 1) {
        event(EvidenceTransport.internet, 'i$index');
      }
      event(EvidenceTransport.internet, 'b0');
      event(EvidenceTransport.bluetooth, 'i0');

      final totals = ledger.summary();
      expect(
        totals.bluetooth.firstDelivered + totals.internet.firstDelivered,
        8,
        reason: 'five Bluetooth-first plus three internet-first, no more',
      );
      expect(totals.bluetooth.firstDelivered, 5);
      expect(totals.internet.firstDelivered, 3);
    });
  });

  group('the lead time when both transports delivered', () {
    test('Bluetooth ahead of the internet is measured', () {
      event(EvidenceTransport.bluetooth, 'e1');
      advance(const Duration(seconds: 4));
      event(EvidenceTransport.internet, 'e1');

      final verdict = ledger.verdict();
      expect(verdict.bluetoothFirst, 1);
      expect(verdict.medianLeadOverInternet, const Duration(seconds: 4));
      expect(verdict.longestLeadOverInternet, const Duration(seconds: 4));
    });

    test('the median and the longest lead are taken over every such event', () {
      for (final (index, seconds) in [2, 4, 9].indexed) {
        event(EvidenceTransport.bluetooth, 'e$index');
        advance(Duration(seconds: seconds));
        event(EvidenceTransport.internet, 'e$index');
      }

      final verdict = ledger.verdict();
      expect(verdict.bluetoothFirst, 3);
      expect(verdict.medianLeadOverInternet, const Duration(seconds: 4));
      expect(verdict.longestLeadOverInternet, const Duration(seconds: 9));
    });

    test('the internet arriving first is not a Bluetooth lead', () {
      event(EvidenceTransport.internet, 'e1');
      advance(const Duration(seconds: 3));
      event(EvidenceTransport.bluetooth, 'e1');

      final verdict = ledger.verdict();
      expect(verdict.bluetoothFirst, 0);
      expect(verdict.medianLeadOverInternet, isNull);
      // It still arrived over Bluetooth, which is what N counts.
      expect(verdict.viaBluetooth, 1);
      expect(verdict.updatesFromOthers, 1);
      expect(verdict.bluetoothOnly, 0);
    });
  });

  group('events only Bluetooth ever delivered', () {
    test('are claimed once they have waited past the settling time', () {
      event(EvidenceTransport.bluetooth, 'e1');
      advance(const Duration(seconds: 31));

      final verdict = ledger.verdict();
      expect(verdict.bluetoothOnly, 1);
      expect(verdict.bluetoothFirst, 0);
    });

    test('are not claimed while the internet may simply be about to deliver', () {
      event(EvidenceTransport.bluetooth, 'e1');
      advance(const Duration(seconds: 6));

      // The internet polls every few seconds: six seconds old and not there yet
      // is early, not Bluetooth-only. Claiming it would overstate the evidence.
      final verdict = ledger.verdict();
      expect(verdict.bluetoothOnly, 0);
      expect(verdict.viaBluetooth, 1);
    });

    test('stop being "only" the moment the internet delivers them', () {
      event(EvidenceTransport.bluetooth, 'e1');
      advance(const Duration(minutes: 2));
      expect(ledger.verdict().bluetoothOnly, 1);

      event(EvidenceTransport.internet, 'e1');

      final verdict = ledger.verdict();
      expect(verdict.bluetoothOnly, 0);
      expect(verdict.bluetoothFirst, 1);
      expect(verdict.medianLeadOverInternet, const Duration(minutes: 2));
    });

    test('N is K plus J plus the ones the internet delivered first', () {
      // Bluetooth first, internet later: K.
      event(EvidenceTransport.bluetooth, 'k1');
      advance(const Duration(seconds: 2));
      event(EvidenceTransport.internet, 'k1');
      // Bluetooth only: J.
      event(EvidenceTransport.bluetooth, 'j1');
      event(EvidenceTransport.bluetooth, 'j2');
      // Internet first, Bluetooth later: neither K nor J.
      event(EvidenceTransport.internet, 'i1');
      event(EvidenceTransport.bluetooth, 'i1');
      // Internet only: not Bluetooth at all.
      event(EvidenceTransport.internet, 'x1');
      advance(const Duration(minutes: 1));

      final verdict = ledger.verdict();
      expect(verdict.updatesFromOthers, 5);
      expect(verdict.viaBluetooth, 4);
      expect(verdict.bluetoothFirst, 1);
      expect(verdict.bluetoothOnly, 2);
    });
  });

  group('duplicate arrivals', () {
    test('a redelivery over the same route is not counted twice', () {
      event(EvidenceTransport.bluetooth, 'e1');
      event(EvidenceTransport.bluetooth, 'e1');
      event(EvidenceTransport.bluetooth, 'e1');

      final alex = ledger.evidenceFor('alex')!;
      expect(alex.bluetooth.events, 1);
      expect(ledger.verdict().viaBluetooth, 1);
      expect(ledger.verdict().updatesFromOthers, 1);
    });

    test(
      'the second route is recorded even though the event is already held',
      () {
        // The case the whole ledger exists for. An event stored once and then
        // delivered again by the other route is dropped as a duplicate by the
        // journal, so unless the arrival is recorded before that, the quicker
        // route makes the slower one invisible.
        event(EvidenceTransport.internet, 'e1');
        advance(const Duration(seconds: 5));
        event(EvidenceTransport.bluetooth, 'e1');

        expect(ledger.evidenceFor('alex')!.bluetooth.events, 1);
        expect(ledger.verdict().viaBluetooth, 1);
      },
    );

    test(
      'a third delivery after both routes have delivered changes nothing',
      () {
        event(EvidenceTransport.bluetooth, 'e1');
        advance(const Duration(seconds: 2));
        event(EvidenceTransport.internet, 'e1');
        advance(const Duration(seconds: 30));
        event(EvidenceTransport.bluetooth, 'e1');
        event(EvidenceTransport.internet, 'e1');

        final alex = ledger.evidenceFor('alex')!;
        expect(alex.bluetooth.events, 1);
        expect(alex.internet.events, 1);
        expect(ledger.verdict().bluetoothFirst, 1);
        expect(
          ledger.verdict().medianLeadOverInternet,
          const Duration(seconds: 2),
        );
        // And the last-heard time is when the route actually delivered, not when
        // it redelivered.
        expect(
          alex.bluetooth.lastReceivedAt,
          start,
          reason: 'a redelivery is not the rider being heard again',
        );
      },
    );

    test('the event is credited to its author on both routes', () {
      event(EvidenceTransport.bluetooth, 'e1', author: 'alex');
      // A second arrival that names someone else must not move the credit: an id
      // has one author.
      event(EvidenceTransport.internet, 'e1', author: 'sam');

      expect(ledger.evidenceFor('alex')!.internet.events, 1);
      expect(ledger.evidenceFor('sam'), isNull);
    });
  });

  group('live-position updates', () {
    test('are counted per rider and per transport', () {
      ledger.recordPresence(
        transport: EvidenceTransport.bluetooth,
        riderId: 'alex',
      );
      ledger.recordPresence(
        transport: EvidenceTransport.bluetooth,
        riderId: 'alex',
      );
      ledger.recordPresence(
        transport: EvidenceTransport.internet,
        riderId: 'alex',
      );
      ledger.recordPresence(
        transport: EvidenceTransport.bluetooth,
        riderId: 'sam',
      );

      expect(ledger.evidenceFor('alex')!.bluetooth.presenceUpdates, 2);
      expect(ledger.evidenceFor('alex')!.internet.presenceUpdates, 1);
      expect(ledger.evidenceFor('sam')!.bluetooth.presenceUpdates, 1);
      expect(ledger.evidenceFor('sam')!.internet.presenceUpdates, 0);
    });

    test('keep the time each transport last heard the rider', () {
      ledger.recordPresence(
        transport: EvidenceTransport.bluetooth,
        riderId: 'alex',
      );
      advance(const Duration(seconds: 7));
      ledger.recordPresence(
        transport: EvidenceTransport.internet,
        riderId: 'alex',
      );

      final alex = ledger.evidenceFor('alex')!;
      expect(alex.bluetooth.lastReceivedAt, start);
      expect(
        alex.internet.lastReceivedAt,
        start.add(const Duration(seconds: 7)),
      );
    });

    test('and events share one last-heard time per transport', () {
      event(EvidenceTransport.bluetooth, 'e1');
      advance(const Duration(seconds: 10));
      ledger.recordPresence(
        transport: EvidenceTransport.bluetooth,
        riderId: 'alex',
      );
      advance(const Duration(seconds: 10));
      event(EvidenceTransport.bluetooth, 'e2');

      expect(
        ledger.evidenceFor('alex')!.bluetooth.lastReceivedAt,
        start.add(const Duration(seconds: 20)),
      );
    });

    test(
      'count as Bluetooth working even before any durable event arrives',
      () {
        ledger.recordPresence(
          transport: EvidenceTransport.bluetooth,
          riderId: 'alex',
        );

        final verdict = ledger.verdict();
        expect(verdict.worked, isTrue);
        expect(verdict.viaBluetooth, 0);
        expect(verdict.bluetoothPresenceUpdates, 1);
      },
    );

    test(
      'over the internet alone do not make Bluetooth look as if it worked',
      () {
        ledger.recordPresence(
          transport: EvidenceTransport.internet,
          riderId: 'alex',
        );
        event(EvidenceTransport.internet, 'e1');

        final verdict = ledger.verdict();
        expect(verdict.worked, isFalse);
        expect(verdict.internetPresenceUpdates, 1);
      },
    );
  });

  group('only other riders count', () {
    test('this rider\'s own events echoing back are ignored', () {
      event(EvidenceTransport.internet, 'mine', author: 'me');
      event(EvidenceTransport.bluetooth, 'mine', author: 'me');
      ledger.recordPresence(
        transport: EvidenceTransport.bluetooth,
        riderId: 'me',
      );

      expect(ledger.riders, isEmpty);
      expect(ledger.verdict().updatesFromOthers, 0);
      expect(ledger.verdict().worked, isFalse);
    });

    test('empty ids are ignored rather than creating a nameless rider', () {
      ledger.recordEvent(
        transport: EvidenceTransport.bluetooth,
        eventId: '',
        authorId: 'alex',
      );
      ledger.recordEvent(
        transport: EvidenceTransport.bluetooth,
        eventId: 'e1',
        authorId: '',
      );
      ledger.recordPresence(
        transport: EvidenceTransport.bluetooth,
        riderId: '',
      );

      expect(ledger.riders, isEmpty);
    });
  });

  group('the summary', () {
    test('totals each transport across every rider', () {
      event(EvidenceTransport.bluetooth, 'a1', author: 'alex');
      event(EvidenceTransport.bluetooth, 'b1', author: 'sam');
      event(EvidenceTransport.internet, 'a1', author: 'alex');
      event(EvidenceTransport.internet, 'n1', author: 'jo');
      ledger.recordPresence(
        transport: EvidenceTransport.bluetooth,
        riderId: 'alex',
      );
      ledger.recordPresence(
        transport: EvidenceTransport.internet,
        riderId: 'sam',
      );

      final summary = ledger.summary();
      expect(summary.bluetooth.events, 2);
      expect(summary.bluetooth.firstDelivered, 2);
      expect(summary.bluetooth.presenceUpdates, 1);
      expect(summary.bluetooth.ridersHeard, 2);
      expect(summary.internet.events, 2);
      expect(summary.internet.firstDelivered, 1);
      expect(summary.internet.presenceUpdates, 1);
      expect(summary.internet.ridersHeard, 3);
    });

    test('reports the oldest last-heard age across riders', () {
      event(EvidenceTransport.bluetooth, 'a1', author: 'alex');
      advance(const Duration(seconds: 40));
      event(EvidenceTransport.bluetooth, 'b1', author: 'sam');
      advance(const Duration(seconds: 5));

      final bluetooth = ledger.summary().bluetooth;
      // Alex was last heard 45 s ago and Sam 5 s ago: the worst case is Alex.
      expect(bluetooth.oldestLastReceivedAge, const Duration(seconds: 45));
    });

    test('has no age for a transport nobody has been heard on', () {
      event(EvidenceTransport.internet, 'a1');

      final summary = ledger.summary();
      expect(summary.bluetooth.oldestLastReceivedAge, isNull);
      expect(summary.bluetooth.ridersHeard, 0);
      expect(summary.internet.oldestLastReceivedAge, Duration.zero);
    });

    test('is empty before anything arrives', () {
      final summary = ledger.summary();

      expect(summary.bluetooth.events, 0);
      expect(summary.internet.presenceUpdates, 0);
      expect(summary.bluetooth.oldestLastReceivedAge, isNull);
    });
  });

  group('the window of remembered events', () {
    test('is bounded, and the totals stay cumulative beyond it', () {
      final small = TransportEvidenceLedger(
        localRiderId: 'me',
        clock: () => now,
        maximumTrackedEvents: 3,
      );
      for (var index = 0; index < 10; index += 1) {
        small.recordEvent(
          transport: EvidenceTransport.bluetooth,
          eventId: 'e$index',
          authorId: 'alex',
        );
      }

      expect(small.summary().bluetooth.events, 10);
      expect(small.verdict().viaBluetooth, 10);
      expect(small.verdict().updatesFromOthers, 10);
    });
  });

  group('whether the direct link ever connected', () {
    test('is unknown until a peer count is observed', () {
      expect(ledger.bluetoothEverConnected, isFalse);

      ledger.observeBluetoothPeers(0);

      expect(ledger.bluetoothEverConnected, isFalse);
    });

    test('remembers that it did, after the peers have gone again', () {
      ledger.observeBluetoothPeers(2);
      ledger.observeBluetoothPeers(0);

      expect(ledger.bluetoothEverConnected, isTrue);
      expect(ledger.verdict().everConnectedToPhone, isTrue);
    });
  });

  group('when the ledger started watching', () {
    test('is recorded, so a count of zero can say how much it covers', () {
      advance(const Duration(minutes: 90));

      final late = TransportEvidenceLedger(
        localRiderId: 'me',
        clock: () => now,
      );

      expect(
        late.verdict().observingSince,
        start.add(const Duration(minutes: 90)),
      );
    });
  });

  group('peers are named by the order they were first seen', () {
    test('phone A, phone B, phone C in order of first sight', () {
      final anonymiser = PeerAnonymiser();

      expect(anonymiser.labelFor('q7XK'), 'phone A');
      expect(anonymiser.labelFor('m2ZP'), 'phone B');
      expect(anonymiser.labelFor('t9WD'), 'phone C');
    });

    test('the same peer keeps its label', () {
      final anonymiser = PeerAnonymiser();
      anonymiser.labelFor('q7XK');
      anonymiser.labelFor('m2ZP');

      expect(anonymiser.labelFor('m2ZP'), 'phone B');
      expect(anonymiser.labelFor('q7XK'), 'phone A');
      expect(anonymiser.count, 2);
    });

    test('a label never contains the raw id it stands for', () {
      final anonymiser = PeerAnonymiser();
      for (final id in ['Oliver-iPhone', 'Sam Pixel', 'ABCD']) {
        expect(anonymiser.labelFor(id), isNot(contains(id)));
      }
    });

    test('labels do not collide past the twenty-sixth phone', () {
      final anonymiser = PeerAnonymiser();
      final labels = {
        for (var index = 0; index < 60; index += 1)
          anonymiser.labelFor('peer-$index'),
      };

      expect(labels, hasLength(60));
      expect(anonymiser.labelFor('peer-0'), 'phone A');
      expect(anonymiser.labelFor('peer-25'), 'phone Z');
      expect(anonymiser.labelFor('peer-26'), 'phone AA');
      expect(anonymiser.labelFor('peer-27'), 'phone AB');
    });
  });

  group('what the ledger holds', () {
    test('is ids, counts and times, with nothing to hold a name or position', () {
      event(EvidenceTransport.bluetooth, 'e1');
      ledger.recordPresence(
        transport: EvidenceTransport.bluetooth,
        riderId: 'alex',
      );

      final alex = ledger.evidenceFor('alex')!;
      // The snapshot carries the opaque rider id and the counters, and nothing
      // else. A rider's name or position has no field to be stored in, which is
      // what makes it safe to summarise into a log that leaves the phone.
      expect(alex.riderId, 'alex');
      expect(alex.bluetooth, isA<TransportCounters>());
      expect(alex.toString(), isNot(contains('latitude')));
    });
  });
}
