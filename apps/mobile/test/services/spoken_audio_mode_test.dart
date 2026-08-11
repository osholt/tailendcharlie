import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/services/spoken_audio_mode.dart';

void main() {
  group('silencing navigation must never silence safety (#415)', () {
    test('alerts only speaks a warning and not a turn', () {
      // The mode that was asked for, and the whole reason a single on/off switch
      // could not express it.
      expect(
        spokenAudioAllows(SpokenAudioMode.alertsOnly, SpokenAudioClass.safety),
        isTrue,
      );
      expect(
        spokenAudioAllows(
          SpokenAudioMode.alertsOnly,
          SpokenAudioClass.navigation,
        ),
        isFalse,
      );
    });

    test('everything speaks both', () {
      for (final audioClass in SpokenAudioClass.values) {
        expect(
          spokenAudioAllows(SpokenAudioMode.everything, audioClass),
          isTrue,
          reason: '$audioClass',
        );
      }
    });

    test('silent speaks neither, because a rider chose that', () {
      // Deliberately including safety. A rider who asks for silence has asked
      // for it; overriding them would make the control untrustworthy, and a
      // control a rider does not trust is one they stop using.
      for (final audioClass in SpokenAudioClass.values) {
        expect(
          spokenAudioAllows(SpokenAudioMode.silent, audioClass),
          isFalse,
          reason: '$audioClass',
        );
      }
    });

    test('every mode has an answer for every class', () {
      // The switch is total, so a new mode or class is a compile error here
      // rather than a silent omission at some call site.
      for (final mode in SpokenAudioMode.values) {
        for (final audioClass in SpokenAudioClass.values) {
          expect(() => spokenAudioAllows(mode, audioClass), returnsNormally);
        }
      }
    });
  });

  group('going off route quietens navigation, not warnings', () {
    test('a rider off route drops to alerts only', () {
      // Turn-by-turn for a route the rider is not on names junctions that are
      // not coming.
      expect(
        spokenAudioModeOffRoute(SpokenAudioMode.everything),
        SpokenAudioMode.alertsOnly,
      );
    });

    test('a rider who chose silence stays silent', () {
      // An explicit choice outranks an automatic one — the same rule the mapped
      // speed limit follows for a rider who turned it off.
      expect(
        spokenAudioModeOffRoute(SpokenAudioMode.silent),
        SpokenAudioMode.silent,
      );
    });

    test('alerts only is already there and stays', () {
      expect(
        spokenAudioModeOffRoute(SpokenAudioMode.alertsOnly),
        SpokenAudioMode.alertsOnly,
      );
    });
  });

  group('the control on the map says what it is', () {
    test('every mode is named in words', () {
      // #306: no feature reachable only through an unlabelled icon, and a rider
      // pressing by feel needs to know what state they are in.
      for (final mode in SpokenAudioMode.values) {
        expect(spokenAudioModeLabel(mode).trim(), isNotEmpty, reason: '$mode');
      }
      expect(spokenAudioModeLabel(SpokenAudioMode.alertsOnly), 'Alerts only');
    });

    test('cycling reaches every mode and returns', () {
      var mode = SpokenAudioMode.everything;
      final seen = <SpokenAudioMode>[];
      for (var press = 0; press < SpokenAudioMode.values.length; press += 1) {
        seen.add(mode);
        mode = nextSpokenAudioMode(mode);
      }

      expect(seen.toSet(), SpokenAudioMode.values.toSet());
      expect(mode, SpokenAudioMode.everything, reason: 'it must come back');
    });

    test('cycling goes from most talkative to least', () {
      // One direction of travel, so a rider who wants quiet keeps pressing.
      expect(
        nextSpokenAudioMode(SpokenAudioMode.everything),
        SpokenAudioMode.alertsOnly,
      );
      expect(
        nextSpokenAudioMode(SpokenAudioMode.alertsOnly),
        SpokenAudioMode.silent,
      );
    });
  });
}
