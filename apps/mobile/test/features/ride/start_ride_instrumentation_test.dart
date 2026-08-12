import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// #441: "with CarPlay connected, the Start ride control on the phone does
/// nothing."
///
/// ## Why this is instrumentation and not a fix
///
/// The issue proposes that something in the CarPlay projection path is "taking
/// the phone's start with it". Reading `active_ride_shell.dart` does not bear
/// that out: **no path in it treats a CarPlay session differently**. The phone's
/// button is `onPressed: busy ? null : onStartRide`, where `busy` is
/// `rideController.busy || _loading`, and neither is touched by CarPlay.
/// `_carPlayRideStart` only feeds the snapshot; it changes nothing on the phone.
///
/// So there is nothing to fix that I can point at, and guessing at a
/// safety-relevant control is how #408 nearly shipped an illegal manoeuvre.
///
/// What the log can settle in one ride:
///
/// - **no `start ride tapped` entry** — the tap never reached Dart, which points
///   at the Flutter view not receiving touches while CarPlay is attached;
/// - **tapped, then `refused before the dialog`** — the leadership or
///   already-started gate swallowed it, and the entry says which;
/// - **tapped, then `decision: dismissed`** — the dialog appeared and was
///   dismissed, which would mean the control works and the dialog is the
///   problem;
/// - **tapped, then `decision: chooseRoute`** — the phone demanded a route
///   decision where CarPlay starts immediately, which is a real asymmetry
///   between the two surfaces and would be the thing to fix.
///
/// The entries are asserted structurally because starting a ride needs a
/// session, a relay, a location stream and a map, and no test here constructs
/// `ActiveRideShell`.
void main() {
  final source = File(
    'lib/features/ride/active_ride_shell.dart',
  ).readAsStringSync();

  group('the next ride can say what the start button did (#441)', () {
    test('the tap is recorded before any gate can swallow it', () {
      expect(source, contains('start ride tapped on the phone'));
      // Before the early return, or a refused tap would leave no trace at all.
      expect(
        source.indexOf('start ride tapped on the phone'),
        lessThan(source.indexOf('start ride refused before the dialog')),
      );
    });

    test('the tap entry carries the state that decides the gate', () {
      // Without these, "it did nothing" stays unfalsifiable.
      for (final field in ['role=', 'started=', 'busy=', 'route=']) {
        expect(source, contains(field), reason: field);
      }
    });

    test('the outcome of the dialog is recorded', () {
      expect(source, contains('start ride decision:'));
    });

    test('a CarPlay start is distinguishable from a phone start', () {
      // The report is that only the car could start the ride, so a log has to
      // say which surface did.
      expect(source, contains('start ride accepted from CarPlay'));
    });
  });

  group('the premise of the issue is recorded as untrue', () {
    test('nothing on the phone start path is conditioned on CarPlay', () {
      // If someone later adds such a condition, this fails and they have to say
      // why — which is the note the issue itself needed.
      // Bounded by the next method declaration, not by an enum: the enums are
      // declared near the top of the file, well before this method, and slicing
      // to one of them inverts the range.
      final start = source.indexOf('Future<void> _confirmStartRide()');
      expect(start, greaterThan(0), reason: 'the method must still exist');
      final next = source.indexOf(
        RegExp(r'\n  (Future|void|Widget|bool) '),
        start + 1,
      );
      // Comments stripped: this is a claim about the *code*, and the method's own
      // note explains that the report was "with CarPlay connected" — which
      // otherwise matches itself.
      final startPath = source
          .substring(start, next > start ? next : source.length)
          .split('\n')
          .where((line) => !line.trimLeft().startsWith('//'))
          .join('\n');

      expect(
        startPath,
        isNot(matches(RegExp(r'(if|while)\s*\([^)]*[Cc]arPlay'))),
        reason: 'the phone start must not depend on a car being attached',
      );
    });
  });
}
