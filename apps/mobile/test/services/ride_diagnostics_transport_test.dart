import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/internet/internet_relay_worker.dart';
import 'package:ride_relay/relay/relay_engine.dart';
import 'package:ride_relay/services/ride_diagnostics_configuration.dart';
import 'package:ride_relay/services/ride_diagnostics_recorder.dart';
import 'package:ride_relay/services/transport_evidence_ledger.dart';

/// #855: the diagnostics log records how updates reached this phone.
///
/// The 4 October diagnostics were solo navigation logs, and the recorder wrote
/// no transport events at all, so "did Bluetooth peer-to-peer work?" could not be
/// answered from the one artefact meant to answer questions like it.
void main() {
  final start = DateTime.utc(2026, 10, 4, 10);
  late DateTime now;
  late RideDiagnosticsRecorder recorder;

  void advance(Duration by) => now = now.add(by);

  setUp(() {
    now = start;
    recorder = RideDiagnosticsRecorder(clock: () => now);
  });

  RelayStatus status(
    RelayConnectionState state, {
    Set<String> peers = const {},
    String? message,
  }) => RelayStatus(state: state, peerIds: peers, message: message);

  /// The TRANSPORT entries, with the timestamp stripped so a test reads as the
  /// sentence the log carries.
  List<String> transportLines() => [
    for (final entry in recorder.entries)
      if (entry.contains('  TRANSPORT  '))
        entry.substring(entry.indexOf('TRANSPORT')),
  ];

  group('the direct link\'s state', () {
    test('the first status writes where the link started', () {
      recorder.observeNearbyStatus(status(RelayConnectionState.searching));

      expect(transportLines(), ['TRANSPORT  bluetooth searching  0 phones']);
    });

    test('a status that changes nothing writes nothing', () {
      recorder.observeNearbyStatus(status(RelayConnectionState.searching));
      // The relay emits a status for every exchange, because the queue count
      // moved. None of those is a transition.
      for (var index = 0; index < 20; index += 1) {
        recorder.observeNearbyStatus(status(RelayConnectionState.searching));
      }

      expect(transportLines(), hasLength(1));
    });

    test('a state change carries the number of phones', () {
      recorder.observeNearbyStatus(status(RelayConnectionState.searching));
      recorder.observeNearbyStatus(
        status(RelayConnectionState.connected, peers: {'q7XK', 'm2ZP'}),
      );

      expect(
        transportLines(),
        contains('TRANSPORT  bluetooth connected  2 phones'),
      );
    });

    test('says "1 phone", not "1 phones"', () {
      recorder.observeNearbyStatus(
        status(RelayConnectionState.connected, peers: {'q7XK'}),
      );

      expect(transportLines().first, 'TRANSPORT  bluetooth connected  1 phone');
    });

    test('an unavailable link says why', () {
      recorder.observeNearbyStatus(
        status(
          RelayConnectionState.unavailable,
          message: 'Nearby-device permission is required',
        ),
      );

      expect(transportLines(), [
        'TRANSPORT  bluetooth unavailable  0 phones  '
            'Nearby-device permission is required',
      ]);
    });

    test(
      'a new problem on the same state is written, and clearing it is not',
      () {
        recorder.observeNearbyStatus(status(RelayConnectionState.searching));
        recorder.observeNearbyStatus(
          status(
            RelayConnectionState.searching,
            message: 'Connection rejected: 8013',
          ),
        );
        // The same message again, then the message clearing: neither is news.
        recorder.observeNearbyStatus(
          status(
            RelayConnectionState.searching,
            message: 'Connection rejected: 8013',
          ),
        );
        recorder.observeNearbyStatus(status(RelayConnectionState.searching));

        expect(transportLines(), [
          'TRANSPORT  bluetooth searching  0 phones',
          'TRANSPORT  bluetooth searching  0 phones  Connection rejected: 8013',
        ]);
      },
    );

    test('a link that backs off is written as reconnecting', () {
      recorder.observeNearbyStatus(
        status(RelayConnectionState.backingOff, message: 'Nearby start failed'),
      );

      expect(
        transportLines().single,
        'TRANSPORT  bluetooth reconnecting  0 phones  Nearby start failed',
      );
    });
  });

  group('peers connecting and dropping', () {
    test('a peer is written as "phone A", with the count that results', () {
      recorder.observeNearbyStatus(status(RelayConnectionState.searching));
      recorder.observeNearbyStatus(
        status(RelayConnectionState.connected, peers: {'q7XK'}),
      );

      expect(transportLines(), [
        'TRANSPORT  bluetooth searching  0 phones',
        'TRANSPORT  bluetooth connected  1 phone',
        'TRANSPORT  bluetooth peer connected  phone A  (1 phone now)',
      ]);
    });

    test('phones are lettered in the order they were first seen', () {
      recorder.observeNearbyStatus(
        status(RelayConnectionState.connected, peers: {'q7XK'}),
      );
      recorder.observeNearbyStatus(
        status(RelayConnectionState.connected, peers: {'q7XK', 'm2ZP'}),
      );
      recorder.observeNearbyStatus(
        status(RelayConnectionState.connected, peers: {'q7XK', 'm2ZP', 't9WD'}),
      );

      final lines = transportLines();
      expect(
        lines,
        contains('TRANSPORT  bluetooth peer connected  phone A  (1 phone now)'),
      );
      expect(
        lines,
        contains(
          'TRANSPORT  bluetooth peer connected  phone B  (2 phones now)',
        ),
      );
      expect(
        lines,
        contains(
          'TRANSPORT  bluetooth peer connected  phone C  (3 phones now)',
        ),
      );
    });

    test('a peer that drops is written as lost, and the link stays up', () {
      recorder.observeNearbyStatus(
        status(RelayConnectionState.connected, peers: {'q7XK', 'm2ZP'}),
      );
      recorder.observeNearbyStatus(
        status(RelayConnectionState.connected, peers: {'m2ZP'}),
      );

      expect(
        transportLines().last,
        'TRANSPORT  bluetooth peer lost  phone A  (1 phone now)',
      );
      // Still connected, so the state line is not repeated.
      expect(
        transportLines().where((line) => line.contains('bluetooth connected')),
        hasLength(1),
      );
    });

    test('losing the last peer moves the state back to searching', () {
      recorder.observeNearbyStatus(
        status(RelayConnectionState.connected, peers: {'q7XK'}),
      );
      recorder.observeNearbyStatus(status(RelayConnectionState.searching));

      expect(transportLines().sublist(2), [
        'TRANSPORT  bluetooth searching  0 phones',
        'TRANSPORT  bluetooth peer lost  phone A  (0 phones now)',
      ]);
    });

    test('a peer that comes back keeps the same label', () {
      recorder.observeNearbyStatus(
        status(RelayConnectionState.connected, peers: {'q7XK'}),
      );
      recorder.observeNearbyStatus(status(RelayConnectionState.searching));
      recorder.observeNearbyStatus(
        status(RelayConnectionState.connected, peers: {'q7XK'}),
      );

      expect(
        transportLines().where((line) => line.contains('peer connected')),
        everyElement(contains('phone A')),
      );
    });

    test('no raw endpoint id ever reaches the log', () {
      recorder.observeNearbyStatus(
        status(RelayConnectionState.connected, peers: {'q7XK', 'm2ZP'}),
      );
      recorder.observeNearbyStatus(status(RelayConnectionState.searching));

      final log = recorder.render(rideCode: '123456');
      expect(log, isNot(contains('q7XK')));
      expect(log, isNot(contains('m2ZP')));
    });
  });

  group('names never reach the log', () {
    test(
      'an endpoint id inside a platform message is replaced by its label',
      () {
        recorder.observeNearbyStatus(
          status(RelayConnectionState.connected, peers: {'q7XK'}),
        );
        recorder.observeNearbyStatus(
          status(
            RelayConnectionState.searching,
            message: 'Connection to q7XK was reset',
          ),
        );

        final log = recorder.render();
        expect(log, isNot(contains('q7XK')));
        expect(log, contains('Connection to phone A was reset'));
      },
    );

    test('a rider\'s own name inside a platform message is scrubbed', () {
      final scrubbing = RideDiagnosticsRecorder(
        clock: () => now,
        privateTerms: () => ['Oliver', 'Sam'],
      );

      scrubbing.observeNearbyStatus(
        status(
          RelayConnectionState.failed,
          message: 'Could not advertise as Oliver; sam rejected the request',
        ),
      );

      final log = scrubbing.render();
      expect(log, isNot(contains('Oliver')));
      expect(log.toLowerCase(), isNot(contains('sam')));
      expect(
        log,
        contains(
          'Could not advertise as a rider; a rider rejected the request',
        ),
      );
    });

    test(
      'names are read at the moment of writing, so late joiners are covered',
      () {
        final names = <String>['Oliver'];
        final scrubbing = RideDiagnosticsRecorder(
          clock: () => now,
          privateTerms: () => names,
        );
        names.add('Jo');

        scrubbing.observeNearbyStatus(
          status(RelayConnectionState.failed, message: 'Jo is unreachable'),
        );

        expect(scrubbing.render(), isNot(contains('Jo')));
      },
    );

    test('a short name does not garble the words around it', () {
      final scrubbing = RideDiagnosticsRecorder(
        clock: () => now,
        privateTerms: () => ['Ed', 'Al'],
      );

      scrubbing.observeNearbyStatus(
        status(
          RelayConnectionState.failed,
          message: 'Ed needed an unavailable radio; Al\'s phone stayed quiet',
        ),
      );

      final log = scrubbing.render();
      // The names go, standing alone and with a possessive...
      expect(log, contains('a rider needed an unavailable radio'));
      expect(log, contains('a rider\'s phone stayed quiet'));
      // ...and "needed" and "unavailable" are not touched.
      expect(log, isNot(contains('neea rider')));
      expect(log, contains('an unavailable radio'));
    });

    test('a platform message is kept to one bounded line', () {
      recorder.observeNearbyStatus(
        status(
          RelayConnectionState.failed,
          message: 'first line\nsecond line\n${'x' * 400}',
        ),
      );

      final line = transportLines().single;
      expect(line, isNot(contains('\n')));
      expect(line.length, lessThan(220));
    });

    test('the header says other phones are only ever lettered', () {
      recorder.recordNote('anything');

      final header = recorder.render(rideCode: '123456');

      expect(header, contains('"phone A"'));
      expect(header, contains('No rider or Bluetooth device name is recorded'));
      // The existing privacy statement is untouched.
      expect(header, contains('no ride or invite secret'));
    });
  });

  group('the ride service answering or failing', () {
    test('the first success is written once, however often it repeats', () {
      for (var index = 0; index < 10; index += 1) {
        recorder.observeInternetSync(succeeded: true);
      }

      expect(transportLines(), ['TRANSPORT  internet sync ok']);
    });

    test('a failure is written once for the whole run of failures', () {
      recorder.observeInternetSync(succeeded: true);
      for (var index = 0; index < 5; index += 1) {
        recorder.observeInternetSync(succeeded: false, reason: 'retrying');
      }

      expect(transportLines(), [
        'TRANSPORT  internet sync ok',
        'TRANSPORT  internet sync failing  retrying',
      ]);
    });

    test('recovery says how many attempts failed and for how long', () {
      recorder.observeInternetSync(succeeded: true);
      recorder.observeInternetSync(succeeded: false, reason: 'retrying');
      advance(const Duration(seconds: 20));
      recorder.observeInternetSync(succeeded: false, reason: 'retrying');
      advance(const Duration(seconds: 25));
      recorder.observeInternetSync(succeeded: false, reason: 'retrying');
      advance(const Duration(seconds: 5));
      recorder.observeInternetSync(succeeded: true);

      expect(
        transportLines().last,
        'TRANSPORT  internet sync ok  (recovered after 3 failed attempts, 50 s)',
      );
    });

    test('a run that starts with a failure is written as one', () {
      recorder.observeInternetSync(succeeded: false, reason: 'unauthorized');

      expect(transportLines(), [
        'TRANSPORT  internet sync failing  unauthorized',
      ]);
    });

    test('each outage counts its own failed attempts', () {
      recorder.observeInternetSync(succeeded: true);
      recorder.observeInternetSync(succeeded: false, reason: 'retrying');
      recorder.observeInternetSync(succeeded: false, reason: 'retrying');
      recorder.observeInternetSync(succeeded: false, reason: 'retrying');
      recorder.observeInternetSync(succeeded: true);
      recorder.observeInternetSync(succeeded: false, reason: 'retrying');
      recorder.observeInternetSync(succeeded: true);

      final recoveries = transportLines()
          .where((line) => line.contains('recovered'))
          .toList();
      expect(recoveries, hasLength(2));
      expect(recoveries.first, contains('after 3 failed attempts'));
      expect(recoveries.last, contains('after 1 failed attempts'));
    });

    test('a second outage is written as well as the first', () {
      recorder.observeInternetSync(succeeded: true);
      recorder.observeInternetSync(succeeded: false, reason: 'retrying');
      recorder.observeInternetSync(succeeded: true);
      recorder.observeInternetSync(succeeded: false, reason: 'retrying');

      expect(
        transportLines().where((line) => line.contains('failing')),
        hasLength(2),
      );
    });
  });

  group('which ride-service phases count as an answer', () {
    test('a completed sync is a success', () {
      recorder.observeInternetRelay(InternetRelayPhase.synced);

      expect(transportLines(), ['TRANSPORT  internet sync ok']);
    });

    test(
      'every phase that means the service could not be used is a failure',
      () {
        for (final phase in [
          InternetRelayPhase.retrying,
          InternetRelayPhase.failed,
          InternetRelayPhase.unauthorized,
          InternetRelayPhase.updateRequired,
          InternetRelayPhase.serverUpgradeRequired,
          InternetRelayPhase.unconfigured,
        ]) {
          final fresh = RideDiagnosticsRecorder(clock: () => now);

          fresh.observeInternetRelay(phase);

          expect(
            fresh.entries.single,
            endsWith('TRANSPORT  internet sync failing  ${phase.name}'),
            reason: '$phase',
          );
        }
      },
    );

    test('a sync in progress, or a stopped relay, says nothing either way', () {
      recorder.observeInternetRelay(InternetRelayPhase.synced);
      recorder.observeInternetRelay(InternetRelayPhase.syncing);
      recorder.observeInternetRelay(InternetRelayPhase.stopped);

      // Neither an outage nor a recovery: the one line is the first success.
      expect(transportLines(), ['TRANSPORT  internet sync ok']);
    });

    test('a sync starting between two failures does not split the outage', () {
      recorder.observeInternetRelay(InternetRelayPhase.retrying);
      recorder.observeInternetRelay(InternetRelayPhase.syncing);
      recorder.observeInternetRelay(InternetRelayPhase.retrying);
      recorder.observeInternetRelay(InternetRelayPhase.syncing);
      recorder.observeInternetRelay(InternetRelayPhase.synced);

      expect(transportLines(), [
        'TRANSPORT  internet sync failing  retrying',
        'TRANSPORT  internet sync ok  (recovered after 2 failed attempts, 0 s)',
      ]);
    });
  });

  group('the once-a-minute summary', () {
    TransportEvidenceLedger ledgerWithTraffic() {
      final ledger = TransportEvidenceLedger(
        localRiderId: 'me',
        clock: () => now,
      );
      ledger.recordEvent(
        transport: EvidenceTransport.bluetooth,
        eventId: 'e1',
        authorId: 'alex',
      );
      ledger.recordEvent(
        transport: EvidenceTransport.internet,
        eventId: 'e1',
        authorId: 'alex',
      );
      ledger.recordEvent(
        transport: EvidenceTransport.internet,
        eventId: 'e2',
        authorId: 'alex',
      );
      ledger.recordPresence(
        transport: EvidenceTransport.bluetooth,
        riderId: 'alex',
      );
      ledger.recordPresence(
        transport: EvidenceTransport.bluetooth,
        riderId: 'alex',
      );
      return ledger;
    }

    test(
      'writes, for each transport, events, first-delivered, presence and the oldest age',
      () {
        final ledger = ledgerWithTraffic();
        advance(const Duration(seconds: 14));

        recorder.recordTransportSummary(ledger.summary());

        expect(transportLines(), [
          'TRANSPORT  bluetooth summary  events 1  first 1  presence 2  oldest rider 14 s ago',
          'TRANSPORT  internet summary  events 2  first 1  presence 0  oldest rider 14 s ago',
        ]);
      },
    );

    test('says so when nobody has been heard on a transport', () {
      final ledger = TransportEvidenceLedger(
        localRiderId: 'me',
        clock: () => now,
      );

      recorder.recordTransportSummary(ledger.summary());

      expect(transportLines(), everyElement(endsWith('nobody heard yet')));
    });

    test('shows the change since the previous summary', () {
      final ledger = ledgerWithTraffic();
      recorder.recordTransportSummary(ledger.summary());
      ledger.recordPresence(
        transport: EvidenceTransport.bluetooth,
        riderId: 'alex',
      );
      ledger.recordEvent(
        transport: EvidenceTransport.bluetooth,
        eventId: 'e3',
        authorId: 'alex',
      );
      advance(const Duration(seconds: 60));

      recorder.recordTransportSummary(ledger.summary());

      expect(
        transportLines()
            .where((line) => line.contains('bluetooth summary'))
            .last,
        contains('events 2 (+1)  first 2 (+1)  presence 3 (+1)'),
      );
    });

    test('is written once a minute, in slots, however often it is ticked', () {
      final ledger = ledgerWithTraffic();
      var summarised = 0;
      TransportEvidenceSummary summarise() {
        summarised += 1;
        return ledger.summary();
      }

      // A tick every 15 seconds for three minutes, as the ride screen does.
      for (var second = 0; second <= 180; second += 15) {
        recorder.recordTransportSummaryIfDue(summarise);
        advance(const Duration(seconds: 15));
      }

      // At 0, 60, 120 and 180 seconds: four summaries of two lines each.
      expect(summarised, 4);
      expect(
        transportLines().where((line) => line.contains('bluetooth summary')),
        hasLength(4),
      );
      expect(
        transportLines().where((line) => line.contains('internet summary')),
        hasLength(4),
      );
    });

    test('does not build a summary that is not going to be written', () {
      var summarised = 0;
      final ledger = ledgerWithTraffic();
      recorder.recordTransportSummaryIfDue(() {
        summarised += 1;
        return ledger.summary();
      });
      advance(const Duration(seconds: 15));
      recorder.recordTransportSummaryIfDue(() {
        summarised += 1;
        return ledger.summary();
      });

      expect(summarised, 1);
    });

    test('is not written while recording is stopped', () {
      recorder.stopRecording();
      final ledger = ledgerWithTraffic();

      recorder.recordTransportSummaryIfDue(ledger.summary);

      expect(transportLines(), isEmpty);
    });

    test('uses the configured interval', () {
      expect(
        RideDiagnosticsConfiguration.transportSummaryInterval,
        const Duration(minutes: 1),
      );
    });
  });

  group('the end-of-ride verdict', () {
    test('is written in the words the ended-ride screen shows', () {
      recorder.recordTransportVerdict(
        'Bluetooth peer-to-peer worked: 4 of 5 updates arrived over '
        'Bluetooth; 2 arrived over Bluetooth before the internet; 1 arrived '
        'only over Bluetooth.',
      );

      expect(
        transportLines().single,
        startsWith('TRANSPORT  verdict  Bluetooth peer-to-peer worked: 4 of 5'),
      );
    });

    test('a verdict that echoes a name has it scrubbed', () {
      final scrubbing = RideDiagnosticsRecorder(
        clock: () => now,
        privateTerms: () => ['Oliver'],
      );

      scrubbing.recordTransportVerdict('Nothing arrived for Oliver');

      expect(scrubbing.render(), isNot(contains('Oliver')));
    });
  });

  group('recording stopped and resumed', () {
    test('nothing is written while stopped', () {
      recorder.stopRecording();

      recorder.observeNearbyStatus(
        status(RelayConnectionState.connected, peers: {'q7XK'}),
      );
      recorder.observeInternetSync(succeeded: false, reason: 'retrying');

      expect(transportLines(), isEmpty);
    });

    test('resuming states where the links are now, not where they were', () {
      recorder.observeNearbyStatus(status(RelayConnectionState.searching));
      recorder.observeInternetSync(succeeded: true);
      recorder.stopRecording();
      recorder.resumeRecording();

      // Same state as before the pause. Without the reset this would be
      // swallowed as "no change" and the log would resume with no statement of
      // where the links stood.
      recorder.observeNearbyStatus(status(RelayConnectionState.searching));
      recorder.observeInternetSync(succeeded: true);

      expect(
        transportLines().where((line) => line.contains('bluetooth searching')),
        hasLength(2),
      );
      expect(
        transportLines().where((line) => line.contains('internet sync ok')),
        hasLength(2),
      );
    });
  });
}
