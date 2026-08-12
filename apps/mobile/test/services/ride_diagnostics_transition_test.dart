import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/services/ride_diagnostics_recorder.dart';
import 'package:ride_relay/services/ride_diagnostics_transition.dart';

void main() {
  group('the switch is followed whenever it moves (#457)', () {
    test('switched on with no recorder starts one', () {
      // The reported case: a rider reaches Settings through the ride menu, which
      // means the ride is already under way and the shell was built with the
      // switch off.
      expect(
        rideDiagnosticsTransition(
          switchedOn: true,
          hasRecorder: false,
          isRecording: false,
        ),
        RideDiagnosticsTransition.start,
      );
    });

    test('switched on with a stopped recorder takes it up again', () {
      expect(
        rideDiagnosticsTransition(
          switchedOn: true,
          hasRecorder: true,
          isRecording: false,
        ),
        RideDiagnosticsTransition.resume,
      );
    });

    test('switched off while recording stops it', () {
      expect(
        rideDiagnosticsTransition(
          switchedOn: false,
          hasRecorder: true,
          isRecording: true,
        ),
        RideDiagnosticsTransition.stop,
      );
    });

    test('every combination is decided, and none needs work twice', () {
      // Enumerated rather than sampled: this is the whole state space, and the
      // shell's own `if` was only reachable by riding.
      final decisions = {
        for (final on in [true, false])
          for (final has in [true, false])
            for (final recording in [true, false])
              (on, has, recording): rideDiagnosticsTransition(
                switchedOn: on,
                hasRecorder: has,
                isRecording: recording,
              ),
      };

      // Already in the asked-for state, so nothing to do.
      expect(decisions[(true, true, true)], RideDiagnosticsTransition.nothing);
      expect(
        decisions[(false, false, false)],
        RideDiagnosticsTransition.nothing,
      );
      // A recorder cannot be recording without existing, but the switch being off
      // with no recorder is the ordinary case and must stay quiet.
      expect(
        decisions[(false, false, true)],
        RideDiagnosticsTransition.nothing,
      );
      expect(decisions.values, isNot(contains(null)));
    });

    test('applying a transition twice changes nothing the second time', () {
      final recorder = RideDiagnosticsRecorder()..recordNote('first');

      recorder.stopRecording();
      final afterFirstStop = recorder.entries.length;
      recorder.stopRecording();

      expect(recorder.entries, hasLength(afterFirstStop));
      expect(
        rideDiagnosticsTransition(
          switchedOn: false,
          hasRecorder: true,
          isRecording: recorder.isRecording,
        ),
        RideDiagnosticsTransition.nothing,
      );
    });
  });

  group('a log that begins mid-ride says so', () {
    test('the note names what is missing, not just when it started', () {
      // A log that starts halfway through and does not say so reads as a record of
      // the whole ride with a quiet first half.
      expect(rideDiagnosticsStartedMidRideNote, contains('mid-ride'));
      expect(
        rideDiagnosticsStartedMidRideNote,
        contains('nothing before this point'),
      );
    });

    test('it is distinguishable from a log that began with the ride', () {
      expect(
        rideDiagnosticsStartedMidRideNote,
        isNot(rideDiagnosticsStartedNote),
      );
    });
  });

  group('switching off keeps what was gathered', () {
    test('entries survive, and new ones stop arriving', () {
      final recorder = RideDiagnosticsRecorder()
        ..recordNote('the junction that went wrong')
        ..recordReroute(reason: 'off route', succeeded: true);
      final before = recorder.entries.length;

      recorder.stopRecording();
      recorder.recordNote('after the switch went off');

      expect(
        recorder.entries.join('\n'),
        contains('the junction that went wrong'),
        reason: 'switching off is not a request to discard',
      );
      expect(recorder.entries.join('\n'), contains('recording stopped'));
      expect(
        recorder.entries.join('\n'),
        isNot(contains('after the switch went off')),
      );
      // The stop note itself is one entry; nothing after it.
      expect(recorder.entries, hasLength(before + 1));
    });

    test('resuming says so and starts accepting again', () {
      final recorder = RideDiagnosticsRecorder()..recordNote('first');

      recorder.stopRecording();
      recorder.resumeRecording();
      recorder.recordNote('after resuming');

      expect(recorder.entries.join('\n'), contains('recording resumed'));
      expect(recorder.entries.join('\n'), contains('after resuming'));
      expect(recorder.isRecording, isTrue);
    });

    test('a stopped recorder still renders what it holds', () {
      // The share has to work after switching off, which is when a rider is most
      // likely to reach for it.
      final recorder = RideDiagnosticsRecorder()..recordNote('kept');
      recorder.stopRecording();

      expect(recorder.render(rideCode: 'ABCD'), contains('kept'));
      expect(recorder.isEmpty, isFalse);
    });
  });

  group('the shell actually follows the switch', () {
    test('it listens to the controller rather than sampling once', () {
      // Structural because no widget test here can build `ActiveRideShell`: it
      // needs a session, a relay, a location stream and a map. What broke was a
      // missing subscription, and that is what this reads.
      final source = File(
        'lib/features/ride/active_ride_shell.dart',
      ).readAsStringSync();

      expect(
        source,
        contains('rideDiagnostics?.addListener'),
        reason:
            'the switch must be read on every change, not once in initState',
      );
      expect(
        source,
        contains('rideDiagnostics?.removeListener'),
        reason:
            'a listener on a controller outliving the shell must be removed',
      );
      expect(
        source,
        contains('rideDiagnosticsTransition('),
        reason: 'the decision under test above must be the one actually used',
      );
    });
  });
}
