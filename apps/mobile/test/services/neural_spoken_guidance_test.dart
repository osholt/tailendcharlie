import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/services/neural_spoken_guidance.dart';
import 'package:ride_relay/services/spoken_guidance.dart';

void main() {
  test('a neural utterance that starts in time is used whole', () async {
    final neural = _FakeNeuralStarter();
    final fallback = _RecordingEngine();
    final engine = FailSafeNeuralSpokenGuidanceEngine(
      neural: neural,
      fallback: fallback,
      startDeadline: const Duration(milliseconds: 20),
    );

    await engine.configure();
    await engine.speak('Oliver is off course near Siston Common.');

    expect(neural.phrases, ['Oliver is off course near Siston Common.']);
    expect(fallback.spoken, isEmpty);
  });

  test(
    'a late neural result is cancelled and OS speech gets the same text',
    () async {
      final neural = _FakeNeuralStarter(neverStarts: true);
      final fallback = _RecordingEngine();
      final engine = FailSafeNeuralSpokenGuidanceEngine(
        neural: neural,
        fallback: fallback,
        startDeadline: const Duration(milliseconds: 5),
      );

      await engine.configure();
      await engine.speak('In 400 yards, turn right onto Wickwar Road.');

      expect(neural.stopCalls, 1);
      expect(fallback.spoken, ['In 400 yards, turn right onto Wickwar Road.']);
    },
  );

  test(
    'disabling natural speech during a ride immediately uses fallback',
    () async {
      var enabled = true;
      final neural = _FakeNeuralStarter();
      final fallback = _RecordingEngine();
      final engine = AdaptiveNeuralSpokenGuidanceEngine(
        enabled: () => enabled,
        neuralFactory: () => neural,
        fallback: fallback,
      );

      await engine.configure();
      await engine.speak('First prompt');
      enabled = false;
      await engine.speak('Second prompt');

      expect(neural.phrases, ['First prompt']);
      expect(fallback.spoken, ['Second prompt']);
    },
  );
}

class _FakeNeuralStarter implements NeuralSpeechStarter {
  _FakeNeuralStarter({this.neverStarts = false});

  final bool neverStarts;
  final phrases = <String>[];
  int stopCalls = 0;

  @override
  Future<void> prepare() async {}

  @override
  NeuralSpeechAttempt beginSpeak(String phrase) {
    phrases.add(phrase);
    return NeuralSpeechAttempt(
      neverStarts ? Completer<void>().future : Future<void>.value(),
      Future<void>.value(),
    );
  }

  @override
  Future<void> stop() async => stopCalls += 1;
}

class _RecordingEngine implements SpokenGuidanceEngine {
  final spoken = <String>[];

  @override
  Future<void> configure() async {}

  @override
  Future<void> speak(String phrase) async => spoken.add(phrase);

  @override
  Future<void> stop() async {}
}
