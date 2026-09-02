import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/spoken_guidance_controller.dart';
import 'package:ride_relay/services/spoken_audio_mode.dart';
import 'package:ride_relay/services/spoken_guidance.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('the rider keeps the voice setting they chose (#415)', () {
    test('a fresh install is silent', () async {
      // Off by default is deliberate and long-standing: most riders already have
      // an intercom carrying music or another app's prompts, and a second
      // uninvited voice is worse than silence (#286).
      final controller = await SpokenGuidanceController.load();

      expect(controller.mode, SpokenAudioMode.silent);
      expect(controller.enabled, isFalse);
    });

    test('the chosen mode survives a restart', () async {
      final controller = await SpokenGuidanceController.load();
      await controller.setMode(SpokenAudioMode.alertsOnly);

      final reloaded = await SpokenGuidanceController.load();

      expect(reloaded.mode, SpokenAudioMode.alertsOnly);
      expect(reloaded.enabled, isTrue, reason: 'alerts are still something');
    });

    test(
      'a rider upgrading from the on/off build keeps their choice',
      () async {
        // The case that would otherwise silence somebody: storage written by a
        // build that had only a boolean, read by this one.
        SharedPreferences.setMockInitialValues({
          SpokenGuidanceController.preferenceKey: true,
        });

        final controller = await SpokenGuidanceController.load();

        expect(controller.mode, SpokenAudioMode.everything);
      },
    );

    test(
      'a mode this build does not know falls back rather than failing',
      () async {
        // A build that once wrote a mode this one has dropped must not leave a
        // rider unable to turn audio on.
        SharedPreferences.setMockInitialValues({
          SpokenGuidanceController.modePreferenceKey: 'somethingElse',
          SpokenGuidanceController.preferenceKey: true,
        });

        final controller = await SpokenGuidanceController.load();

        expect(controller.mode, SpokenAudioMode.everything);
      },
    );

    test(
      'the old boolean is kept in step, so a downgrade still finds it',
      () async {
        final controller = await SpokenGuidanceController.load();
        await controller.setMode(SpokenAudioMode.everything);

        final preferences = await SharedPreferences.getInstance();

        expect(
          preferences.getBool(SpokenGuidanceController.preferenceKey),
          isTrue,
        );

        await controller.setMode(SpokenAudioMode.silent);
        expect(
          preferences.getBool(SpokenGuidanceController.preferenceKey),
          isFalse,
        );
      },
    );
  });

  group('the control cycles', () {
    test('three presses come back to where they started', () async {
      final controller = await SpokenGuidanceController.load();
      final seen = <SpokenAudioMode>[];

      for (var press = 0; press < SpokenAudioMode.values.length; press += 1) {
        seen.add(controller.mode);
        await controller.cycleMode();
      }

      expect(seen.toSet(), SpokenAudioMode.values.toSet());
      expect(controller.mode, seen.first);
    });

    test('it announces what the next press gives', () async {
      final controller = await SpokenGuidanceController.load();
      await controller.setMode(SpokenAudioMode.everything);

      expect(controller.nextMode, SpokenAudioMode.alertsOnly);
    });

    test(
      'setEnabled still works for callers that only know on and off',
      () async {
        final controller = await SpokenGuidanceController.load();

        await controller.setEnabled(true);
        expect(controller.mode, SpokenAudioMode.everything);

        await controller.setEnabled(false);
        expect(controller.mode, SpokenAudioMode.silent);
      },
    );
  });

  group('the selected voice', () {
    const voice = SpokenGuidanceVoice(
      name: 'Samantha',
      locale: 'en-GB',
      identifier: 'com.apple.voice.samantha',
    );

    test(
      'a fresh profile starts with Daniel without enabling speech',
      () async {
        final controller = await SpokenGuidanceController.load();

        expect(
          controller.voice,
          SpokenGuidanceController.preferredDefaultVoice,
        );
        expect(controller.enabled, isFalse);
      },
    );

    test('survives a restart and can return to system default', () async {
      final controller = await SpokenGuidanceController.load();
      await controller.setVoice(voice);

      expect((await SpokenGuidanceController.load()).voice, voice);

      await controller.setVoice(null);
      expect((await SpokenGuidanceController.load()).voice, isNull);
      final preferences = await SharedPreferences.getInstance();
      expect(
        preferences.getBool(
          SpokenGuidanceController.voiceChoiceMadePreferenceKey,
        ),
        isTrue,
      );
    });

    test('an existing saved voice is never replaced by Daniel', () async {
      SharedPreferences.setMockInitialValues({
        SpokenGuidanceController.voicePreferenceKey:
            '{"name":"Samantha","locale":"en-GB",'
            '"identifier":"com.apple.voice.samantha"}',
      });

      expect((await SpokenGuidanceController.load()).voice, voice);
    });

    test('a corrupt stored voice falls back to system default', () async {
      SharedPreferences.setMockInitialValues({
        SpokenGuidanceController.voicePreferenceKey: '{not json',
      });

      expect((await SpokenGuidanceController.load()).voice, isNull);
    });

    test('installed voices are supplied through the controller', () async {
      final controller = SpokenGuidanceController.inMemory(
        voiceLoader: () async => const [voice],
      );

      expect(await controller.availableVoices(), const [voice]);
    });

    test('a failed preview does not undo the saved voice', () async {
      final controller = SpokenGuidanceController.inMemory(
        engine: _FailingEngine.new,
      );

      await controller.setVoiceAndPreview(voice);

      expect(controller.voice, voice);
    });
  });
}

class _FailingEngine implements SpokenGuidanceEngine {
  @override
  Future<void> configure() => Future<void>.error(StateError('no TTS'));

  @override
  Future<void> speak(
    String phrase, {
    SpokenAudioClass audioClass = SpokenAudioClass.navigation,
  }) async {}

  @override
  Future<void> stop() async {}
}
