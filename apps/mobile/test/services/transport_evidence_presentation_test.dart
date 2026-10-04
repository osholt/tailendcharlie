import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/relay/relay_engine.dart';
import 'package:ride_relay/services/transport_evidence_ledger.dart';
import 'package:ride_relay/services/transport_evidence_presentation.dart';

void main() {
  final start = DateTime.utc(2026, 10, 4, 10);
  late DateTime now;
  late TransportEvidenceLedger ledger;

  void advance(Duration by) => now = now.add(by);

  setUp(() {
    now = start;
    ledger = TransportEvidenceLedger(localRiderId: 'me', clock: () => now);
  });

  void event(EvidenceTransport transport, String id) =>
      ledger.recordEvent(transport: transport, eventId: id, authorId: 'alex');

  group('how old an arrival is, in words', () {
    test('seconds, minutes and hours', () {
      expect(formatEvidenceAge(Duration.zero), 'just now');
      expect(formatEvidenceAge(const Duration(seconds: 1)), 'just now');
      expect(formatEvidenceAge(const Duration(seconds: 12)), '12 s ago');
      expect(formatEvidenceAge(const Duration(seconds: 59)), '59 s ago');
      expect(formatEvidenceAge(const Duration(seconds: 60)), '1 min ago');
      expect(formatEvidenceAge(const Duration(minutes: 59)), '59 min ago');
      expect(formatEvidenceAge(const Duration(minutes: 125)), '2 h ago');
    });

    test('a clock that stepped backwards reads as just now, not negative', () {
      expect(formatEvidenceAge(const Duration(seconds: -30)), 'just now');
    });
  });

  group('the line under each rider', () {
    test('says when each route last delivered', () {
      ledger.recordPresence(
        transport: EvidenceTransport.bluetooth,
        riderId: 'alex',
      );
      advance(const Duration(seconds: 4));
      ledger.recordPresence(
        transport: EvidenceTransport.internet,
        riderId: 'alex',
      );
      advance(const Duration(seconds: 8));

      expect(
        riderEvidenceLine(ledger.evidenceFor('alex'), now),
        'Bluetooth 12 s ago · Internet 8 s ago',
      );
    });

    test('says "nothing yet" for a route that has delivered nothing', () {
      event(EvidenceTransport.internet, 'e1');
      advance(const Duration(seconds: 8));

      expect(
        riderEvidenceLine(ledger.evidenceFor('alex'), now),
        'Bluetooth: nothing yet · Internet 8 s ago',
      );
    });

    test('says so for a rider nothing has been heard from at all', () {
      expect(
        riderEvidenceLine(null, now),
        'Bluetooth: nothing yet · Internet: nothing yet',
      );
    });
  });

  group('the ride-level line about the direct link', () {
    RelayStatus status(
      RelayConnectionState state, {
      Set<String> peers = const {},
      String? message,
    }) => RelayStatus(state: state, peerIds: peers, message: message);

    test('counts the phones it is connected to', () {
      expect(
        bluetoothLinkLine(
          status(RelayConnectionState.connected, peers: {'a', 'b'}),
        ),
        'Bluetooth: connected to 2 phones',
      );
      expect(
        bluetoothLinkLine(status(RelayConnectionState.connected, peers: {'a'})),
        'Bluetooth: connected to 1 phone',
      );
    });

    test('says when it is searching or starting', () {
      expect(
        bluetoothLinkLine(status(RelayConnectionState.searching)),
        'Bluetooth: searching for nearby phones',
      );
      expect(
        bluetoothLinkLine(status(RelayConnectionState.starting)),
        'Bluetooth: starting',
      );
    });

    test('names a missing permission as the reason it is unavailable', () {
      expect(
        bluetoothLinkLine(
          status(
            RelayConnectionState.unavailable,
            message: 'Nearby-device permission is required',
          ),
        ),
        'Bluetooth: unavailable: nearby-device permission is needed',
      );
    });

    test('gives the platform reason when it is not a permission', () {
      expect(
        bluetoothLinkLine(
          status(RelayConnectionState.failed, message: 'Radio is off'),
        ),
        'Bluetooth: unavailable: Radio is off',
      );
    });

    test('says plainly when it has no reason to give', () {
      expect(
        bluetoothLinkLine(status(RelayConnectionState.unavailable)),
        'Bluetooth: unavailable: no reason reported',
      );
    });

    test('says it is reconnecting rather than that it has failed', () {
      expect(
        bluetoothLinkLine(
          status(RelayConnectionState.backingOff, message: 'Start failed'),
        ),
        'Bluetooth: reconnecting (Start failed)',
      );
    });

    test('says when it is not running at all', () {
      expect(bluetoothLinkLine(null), 'Bluetooth: not running on this phone');
      expect(
        bluetoothLinkLine(status(RelayConnectionState.stopped)),
        'Bluetooth: stopped',
      );
    });

    test('cuts a long platform message short', () {
      final line = bluetoothLinkLine(
        status(RelayConnectionState.failed, message: 'x' * 300),
      );

      expect(line.length, lessThan(120));
      expect(line, endsWith('…'));
    });
  });

  group('the end-of-ride verdict when Bluetooth worked', () {
    test('states N of M, K before the internet and J only over Bluetooth', () {
      // Two updates Bluetooth delivered first and the internet followed.
      event(EvidenceTransport.bluetooth, 'k1');
      event(EvidenceTransport.bluetooth, 'k2');
      advance(const Duration(seconds: 3));
      event(EvidenceTransport.internet, 'k1');
      event(EvidenceTransport.internet, 'k2');
      // One only Bluetooth ever delivered.
      event(EvidenceTransport.bluetooth, 'j1');
      // Two the internet delivered first, one of which Bluetooth then repeated.
      event(EvidenceTransport.internet, 'i1');
      event(EvidenceTransport.internet, 'i2');
      event(EvidenceTransport.bluetooth, 'i1');
      advance(const Duration(minutes: 1));

      final wording = bluetoothVerdictWording(ledger.verdict());

      expect(
        wording.headline,
        'Bluetooth peer-to-peer worked: 4 of 5 updates arrived over '
        'Bluetooth; 2 arrived over Bluetooth before the internet; 1 arrived '
        'only over Bluetooth.',
      );
    });

    test('adds the live-position counts as their own sentence', () {
      event(EvidenceTransport.bluetooth, 'e1');
      for (var index = 0; index < 3; index += 1) {
        ledger.recordPresence(
          transport: EvidenceTransport.bluetooth,
          riderId: 'alex',
        );
      }
      for (var index = 0; index < 7; index += 1) {
        ledger.recordPresence(
          transport: EvidenceTransport.internet,
          riderId: 'alex',
        );
      }

      final wording = bluetoothVerdictWording(ledger.verdict());

      expect(wording.details, [
        'Live positions: 3 arrived over Bluetooth, 7 over the internet.',
      ]);
    });

    test('still says it worked when only live positions came that way', () {
      ledger.recordPresence(
        transport: EvidenceTransport.bluetooth,
        riderId: 'alex',
      );
      event(EvidenceTransport.internet, 'e1');

      final wording = bluetoothVerdictWording(ledger.verdict());

      expect(wording.headline, startsWith('Bluetooth peer-to-peer worked'));
      expect(wording.headline, contains('live positions'));
      expect(wording.headline, isNot(contains('of 1 updates')));
    });

    test('plain text is the headline and its details in one paragraph', () {
      event(EvidenceTransport.bluetooth, 'e1');
      ledger.recordPresence(
        transport: EvidenceTransport.internet,
        riderId: 'alex',
      );

      final wording = bluetoothVerdictWording(ledger.verdict());

      expect(wording.plain, startsWith(wording.headline));
      expect(wording.plain, contains('Live positions'));
    });
  });

  group('the end-of-ride verdict when nothing arrived over Bluetooth', () {
    RelayStatus status(RelayConnectionState state, {String? message}) =>
        RelayStatus(state: state, message: message);

    test('says so, and that the phone never connected to another', () {
      event(EvidenceTransport.internet, 'e1');

      final wording = bluetoothVerdictWording(
        ledger.verdict(),
        status: status(RelayConnectionState.searching),
      );

      expect(wording.headline, 'Nothing arrived over Bluetooth on this ride.');
      expect(wording.plain, contains('never connected to another phone'));
    });

    test('names a refused permission as the reason', () {
      final wording = bluetoothVerdictWording(
        ledger.verdict(),
        status: status(
          RelayConnectionState.unavailable,
          message: 'Nearby-device permission is required',
        ),
      );

      expect(wording.headline, startsWith('Nothing arrived over Bluetooth'));
      expect(wording.plain, contains('permission was not granted'));
    });

    test('names a refused permission even while the link is retrying', () {
      // A refusal leaves the engine backing off rather than parked in
      // "unavailable", so the reason has to be read from either.
      final wording = bluetoothVerdictWording(
        ledger.verdict(),
        status: status(
          RelayConnectionState.backingOff,
          message: 'Nearby start failed: Bad state: permission was denied',
        ),
      );

      expect(wording.plain, contains('permission was not granted'));
      expect(wording.plain, isNot(contains('never connected')));
    });

    test('names an unavailable link with the platform reason', () {
      final wording = bluetoothVerdictWording(
        ledger.verdict(),
        status: status(RelayConnectionState.failed, message: 'Radio is off'),
      );

      expect(wording.plain, contains('Bluetooth was unavailable'));
      expect(wording.plain, contains('Radio is off'));
    });

    test('says when it connected but nothing came over the link', () {
      ledger.observeBluetoothPeers(1);

      final wording = bluetoothVerdictWording(
        ledger.verdict(),
        status: status(RelayConnectionState.searching),
      );

      expect(wording.plain, contains('did connect to another phone'));
      expect(wording.plain, isNot(contains('never connected')));
    });

    test('does not call a stretch nobody watched an empty one', () {
      advance(const Duration(minutes: 40));
      final rebuilt = TransportEvidenceLedger(
        localRiderId: 'me',
        clock: () => now,
      );

      final wording = bluetoothVerdictWording(
        rebuilt.verdict(),
        rideStartedAt: start,
      );

      expect(wording.headline, startsWith('Nothing arrived over Bluetooth'));
      expect(
        wording.plain,
        contains('only began recording Bluetooth evidence'),
      );
      expect(wording.plain, contains('10:40'));
    });

    test('does not add that caveat when the whole ride was watched', () {
      advance(const Duration(seconds: 20));
      final prompt = TransportEvidenceLedger(
        localRiderId: 'me',
        clock: () => start,
      );

      final wording = bluetoothVerdictWording(
        prompt.verdict(),
        rideStartedAt: start.add(const Duration(seconds: 20)),
      );

      expect(wording.plain, isNot(contains('only began recording')));
    });
  });

  group('the verdict as the diagnostics log records it', () {
    test('is the screen\'s wording, plus how far ahead Bluetooth was', () {
      event(EvidenceTransport.bluetooth, 'e1');
      advance(const Duration(milliseconds: 2400));
      event(EvidenceTransport.internet, 'e1');

      final text = transportVerdictLogText(ledger.verdict());

      expect(text, startsWith('Bluetooth peer-to-peer worked: 1 of 1 updates'));
      expect(
        text,
        contains(
          'Where Bluetooth was ahead of the internet it led by a median of '
          '2.4 s (longest 2.4 s) over 1 updates.',
        ),
      );
    });

    test('has no lead sentence when Bluetooth was never ahead', () {
      event(EvidenceTransport.bluetooth, 'e1');
      advance(const Duration(minutes: 1));

      expect(
        transportVerdictLogText(ledger.verdict()),
        isNot(contains('led by')),
      );
    });

    test('carries the negative outcome with its reason', () {
      final text = transportVerdictLogText(
        ledger.verdict(),
        status: const RelayStatus(
          state: RelayConnectionState.unavailable,
          message: 'Nearby-device permission is required',
        ),
      );

      expect(text, startsWith('Nothing arrived over Bluetooth on this ride.'));
      expect(text, contains('permission was not granted'));
    });
  });

  group('the dashboard line about what has been received', () {
    test('says nothing has arrived yet', () {
      expect(
        bluetoothReceivedLine(ledger.summary().bluetooth),
        'Nothing received over Bluetooth yet',
      );
    });

    test('counts updates and riders', () {
      event(EvidenceTransport.bluetooth, 'e1');
      ledger.recordPresence(
        transport: EvidenceTransport.bluetooth,
        riderId: 'sam',
      );

      expect(
        bluetoothReceivedLine(ledger.summary().bluetooth),
        'Received over Bluetooth: 2 updates from 2 riders',
      );
    });
  });
}
