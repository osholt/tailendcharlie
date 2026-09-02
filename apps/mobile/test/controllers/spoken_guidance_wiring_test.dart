import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/spoken_guidance_controller.dart';
import 'package:ride_relay/services/spoken_audio_mode.dart';
import 'package:ride_relay/services/spoken_guidance.dart';

/// Records what it was asked to say, so a test can tell silence from speech.
class _RecordingEngine implements SpokenGuidanceEngine {
  final spoken = <String>[];
  var configured = 0;

  @override
  Future<void> configure() async => configured += 1;

  @override
  Future<void> speak(
    String phrase, {
    SpokenAudioClass audioClass = SpokenAudioClass.navigation,
  }) async => spoken.add(phrase);

  @override
  Future<void> stop() async {}
}

void main() {
  // #361: the ride surface declared a speaker and never built one, so it was
  // null for the whole life of every ride and the speak call returned at its
  // first guard. The setting saved, the setting read, and nothing behind it.
  //
  // The voice now comes from the controller, which is the thing the surface is
  // already given - so "is there a voice" is answerable without a running app.
  test('an enabled controller supplies a voice that can be spoken through', () {
    final engine = _RecordingEngine();
    final controller = SpokenGuidanceController.inMemory(
      enabled: true,
      engine: () => engine,
    );

    expect(controller.enabled, isTrue);
    expect(identical(controller.engine(), engine), isTrue);
  });

  test(
    'turning it on is what makes it speak, and only once per manoeuvre',
    () async {
      final engine = _RecordingEngine();
      final speaker = SpokenGuidanceSpeaker(engine);

      // Off: no engine work at all, not even configuration.
      await speaker.speakManoeuvre(
        key: 'turn-1',
        phrase: 'Turn left onto Tennis Court Road',
        enabled: false,
        rideActive: true,
      );
      expect(engine.spoken, isEmpty);
      expect(engine.configured, 0);

      final spoke = await speaker.speakManoeuvre(
        key: 'turn-1',
        phrase: 'Turn left onto Tennis Court Road',
        enabled: true,
        rideActive: true,
      );
      expect(spoke, isTrue);
      expect(engine.spoken, ['Turn left onto Tennis Court Road']);
      expect(engine.configured, 1);

      // The same manoeuvre re-derived on the next position fix stays quiet.
      final repeated = await speaker.speakManoeuvre(
        key: 'turn-1',
        phrase: 'Turn left onto Tennis Court Road',
        enabled: true,
        rideActive: true,
      );
      expect(repeated, isFalse);
      expect(engine.spoken, hasLength(1));
    },
  );
}
