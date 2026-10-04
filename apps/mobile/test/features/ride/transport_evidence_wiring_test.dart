import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// #855: the one transport-evidence ledger reaches every route and every surface.
///
/// The ride shell cannot be built in a widget test (it needs a session, a relay, a
/// location stream and a map), so the wiring that joins the pieces is checked as
/// source, the way `diagnostics_share_doors_test.dart` checks the share doors. The
/// pieces themselves are tested directly; what only this wiring can get wrong is
/// that **one route is left unreported**. That fails silently and convincingly: a
/// ledger fed by Bluetooth alone reads as "the internet delivered nothing", and
/// one fed by the internet alone reads as "Bluetooth never worked" - which is the
/// exact conclusion this feature exists to prevent anyone drawing by mistake.
void main() {
  final shell = File(
    'lib/features/ride/active_ride_shell.dart',
  ).readAsStringSync();

  /// The text of the argument list of the first call to [name], found by
  /// matching its brackets rather than by assuming a layout.
  String argumentsOf(String source, String name) {
    final start = source.indexOf(name);
    expect(start, isNonNegative, reason: '$name is no longer in the shell');
    var depth = 0;
    for (var index = start + name.length - 1; index < source.length; index++) {
      final character = source[index];
      if (character == '(') depth++;
      if (character == ')') {
        depth--;
        if (depth == 0) return source.substring(start, index + 1);
      }
    }
    fail('unbalanced brackets after $name');
  }

  group('every route reports into the one ledger', () {
    test('the ledger is built once, for a group ride only', () {
      expect('TransportEvidenceLedger('.allMatches(shell), hasLength(1));
      final creation = shell.substring(
        shell.indexOf('final evidence = groupRide'),
        shell.indexOf('_transportEvidence = evidence;'),
      );
      expect(creation, contains('groupRide'));
      expect(creation, contains('localRiderId: session.localRiderId'));
    });

    test('the ride service worker is handed it', () {
      expect(
        argumentsOf(shell, 'InternetRelayWorker('),
        contains('evidence: evidence'),
      );
    });

    test('the live-position channel is handed it', () {
      expect(
        argumentsOf(shell, 'PreStartPresenceController('),
        contains('evidence: evidence'),
      );
    });

    test('the direct link\'s relay engine is handed it', () {
      expect(
        argumentsOf(shell, 'RelayEngine('),
        contains('evidence: _transportEvidence'),
      );
    });
  });

  group('every surface that reads it is handed it', () {
    test('the roster', () {
      final roster = argumentsOf(shell, 'RideRosterSheet.show(');
      expect(roster, contains('transportEvidence: _transportEvidence'));
      expect(roster, contains('nearbyRelayController: _relayController'));
    });

    test('the ended-ride screen', () {
      expect(
        argumentsOf(shell, 'EndedRideScreen('),
        contains('transportEvidence: _transportEvidence'),
      );
    });

    test('the ride dashboard', () {
      expect(
        argumentsOf(shell, 'RideDashboard('),
        contains('transportEvidence: _transportEvidence'),
      );
    });
  });

  group('the diagnostics log is fed from the links', () {
    test('the direct link\'s status reaches the recorder and the ledger', () {
      expect(shell, contains('.addListener(_onNearbyStatusChanged)'));
      expect(shell, contains('.removeListener(_onNearbyStatusChanged)'));
      final handler = shell.substring(
        shell.indexOf('void _onNearbyStatusChanged()'),
        shell.indexOf('void _onInternetStatusChanged()'),
      );
      expect(handler, contains('observeNearbyStatus(status)'));
      expect(handler, contains('observeBluetoothPeers('));
    });

    test('the ride service\'s status reaches the recorder', () {
      expect(shell, contains('.addListener(_onInternetStatusChanged)'));
      expect(shell, contains('.removeListener(_onInternetStatusChanged)'));
      expect(shell, contains('observeInternetRelay(status.phase)'));
    });

    test('the tally is ticked from the existing timer', () {
      final timer = shell.substring(
        shell.indexOf('_stalenessTimer = Timer.periodic'),
        shell.indexOf('_externalHazardTimer = Timer.periodic'),
      );
      expect(timer, contains('_recordTransportSummaryIfDue()'));
    });

    test('the log closes with the verdict, before it is flushed', () {
      final ended = shell.substring(
        shell.indexOf('Future<void> _handleRideEnded()'),
        shell.indexOf('_stalenessTimer?.cancel();'),
      );
      expect(ended, contains('_recordTransportVerdict()'));
      expect(
        ended.indexOf('_recordTransportVerdict()'),
        lessThan(ended.indexOf('_diagnosticsWriter?.flush()')),
        reason: 'a verdict recorded after the flush is never written',
      );
    });

    test('names are kept out of the log', () {
      expect(
        argumentsOf(shell, 'RideDiagnosticsRecorder('),
        contains('privateTerms: _diagnosticsPrivateTerms'),
      );
    });
  });

  group('a rebuilt ride screen continues the log rather than replacing it', () {
    test('the writer waits for the earlier log to be read back', () {
      expect(
        argumentsOf(shell, 'RideDiagnosticsLogWriter('),
        contains('ready: _diagnosticsReady'),
      );
      expect(
        shell,
        contains('_diagnosticsReady = continueRecordingFromStore('),
      );
    });

    test('a ride that is already over is not recorded again', () {
      // Both doors that can start a recorder consult the one decision, with the
      // ride's state, so a relaunched ended-ride screen cannot rewrite the log.
      final decisions = RegExp(
        r'rideDiagnosticsTransition\([^)]*rideEnded: widget\.rideController\.rideEnded',
        dotAll: true,
      ).allMatches(shell);
      expect(decisions, hasLength(2));
    });
  });
}
