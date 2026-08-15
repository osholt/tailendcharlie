import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/services/neural_spoken_guidance.dart';
import 'package:ride_relay/services/spoken_guidance.dart';

void main() {
  test('a neural utterance that starts in time is used whole', () async {
    final neural = _FakeNeuralStarter();
    final fallback = _RecordingEngine();
    final outputs = <SpokenGuidanceOutput>[];
    final engine = FailSafeNeuralSpokenGuidanceEngine(
      neural: neural,
      fallback: fallback,
      startDeadline: const Duration(milliseconds: 20),
      onOutput: (_, output) => outputs.add(output),
    );

    await engine.configure();
    await engine.speak('Oliver is off course near Siston Common.');

    expect(neural.phrases, ['Oliver is off course near Siston Common.']);
    expect(fallback.spoken, isEmpty);
    expect(outputs, [SpokenGuidanceOutput.natural]);
  });

  test(
    'a late neural result is cancelled and OS speech gets the same text',
    () async {
      final neural = _FakeNeuralStarter(neverStarts: true);
      final fallback = _RecordingEngine();
      final outputs = <SpokenGuidanceOutput>[];
      final engine = FailSafeNeuralSpokenGuidanceEngine(
        neural: neural,
        fallback: fallback,
        startDeadline: const Duration(milliseconds: 5),
        onOutput: (_, output) => outputs.add(output),
      );

      await engine.configure();
      await engine.speak('In 400 yards, turn right onto Wickwar Road.');

      expect(neural.cancelCalls, 1);
      expect(neural.stopCalls, 0, reason: 'the warmed model stays available');
      expect(fallback.spoken, ['In 400 yards, turn right onto Wickwar Road.']);
      expect(outputs, [SpokenGuidanceOutput.systemFallback]);
    },
  );

  test(
    'explicit warm-up completes model preparation before an alert',
    () async {
      final neural = _FakeNeuralStarter();
      final engine = FailSafeNeuralSpokenGuidanceEngine(
        neural: neural,
        fallback: _RecordingEngine(),
      );

      await engine.configure();
      await engine.warmUp();
      await engine.speak('Speed camera, in 150 yards.');

      expect(neural.prepareCalls, greaterThanOrEqualTo(2));
      expect(neural.preparedBeforeFirstPhrase, isTrue);
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
  int prepareCalls = 0;
  int cancelCalls = 0;
  int stopCalls = 0;
  bool prepared = false;
  bool? preparedBeforeFirstPhrase;

  @override
  Future<void> prepare() async {
    prepareCalls += 1;
    prepared = true;
  }

  @override
  NeuralSpeechAttempt beginSpeak(String phrase) {
    preparedBeforeFirstPhrase ??= prepared;
    phrases.add(phrase);
    return NeuralSpeechAttempt(
      neverStarts ? Completer<void>().future : Future<void>.value(),
      Future<void>.value(),
    );
  }

  @override
  Future<void> cancelCurrentAttempt() async => cancelCalls += 1;

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
