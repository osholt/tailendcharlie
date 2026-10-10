import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/distance_unit.dart';
import 'package:ride_relay/services/measurement_formatter.dart';
import 'package:ride_relay/services/natural_voice_pack.dart';
import 'package:ride_relay/services/neural_spoken_guidance.dart';
import 'package:ride_relay/services/spoken_audio_mode.dart';
import 'package:ride_relay/services/spoken_guidance.dart';
import 'package:ride_relay/services/spoken_guidance_schedule.dart';

/// #616. On the 4 October ride 8 of 30 prompts were spoken in the system voice
/// with the natural voice installed and warm. Every one of them carried a
/// distance, and in every one the distance in the words had changed between the
/// prompt being decided and the voice finishing rendering it (7 to 12 seconds on
/// that phone): "In 130 yd" became "In 110 yards". The engine compared the
/// rendered words with the words the ride would now say, called the difference
/// stale, and handed the current words to the system voice. The prompts without
/// a distance were all natural.
///
/// This drives the real speaker, fail-safe engine and neural engine, with only
/// the model and the audio player faked, through that sequence.
void main() {
  const formatter = MeasurementFormatter(DistanceUnit.miles);
  const instruction = 'At the fork, continue straight on';

  late _GatedBackend backend;
  late _FakeAudioPlayer player;
  late _RecordingEngine fallback;
  late List<SpokenGuidanceOutput> outputs;
  late SpokenGuidanceSpeaker speaker;
  late NeuralSpokenGuidanceEngine neural;
  late _Ride ride;

  setUp(() async {
    backend = _GatedBackend();
    player = _FakeAudioPlayer();
    fallback = _RecordingEngine();
    outputs = [];
    neural = NeuralSpokenGuidanceEngine(
      backend: backend,
      voiceProvider: () => NaturalNavigationVoice.george,
      audioConfigurator: () async {},
      player: player,
    );
    speaker = SpokenGuidanceSpeaker(
      FailSafeNeuralSpokenGuidanceEngine(
        neural: neural,
        fallback: fallback,
        onOutput: (_, output) => outputs.add(output),
      ),
    );
    // Warm, as it is from the first fix of a ride that has the pack installed.
    await speaker.warmUp(enabled: true);
    ride = _Ride(formatter, instruction);
  });

  tearDown(() async {
    await neural.stop();
    await player.completions.close();
  });

  /// Decides the prompt the way the ride shell does at [distance] metres, and
  /// speaks it with the shell's own "is this still right" question.
  Future<bool> speakAt(double distance, {double speed = 6}) {
    ride.distance = distance;
    ride.speed = speed;
    final issued = ride.announce();
    expect(issued, isNotNull, reason: 'the stage is due at $distance m');
    return speaker.speakTrackedManoeuvre(
      deliveredKeys: ride.delivered,
      key: issued!.key,
      phrase: issued.phrase,
      currentPhrase: () => ride.currentPhrase(issued, issuedAt: distance),
      enabled: true,
      rideActive: true,
    );
  }

  Future<void> untilPlaying() async {
    for (var i = 0; i < 200 && player.played.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  test('a distance that ticks over while the voice renders is still spoken '
      'in the natural voice', () async {
    // Decided 123 m out: "In 130 yd". The render takes long enough for the
    // rider to cover 23 m, so the words would now read "In 110 yd".
    backend.onRender = () => ride.distance = 100;
    ride.speed = 6;
    expect(
      ride.phraseAt(123),
      isNot(ride.phraseAt(100)),
      reason: 'the words really do change, as they did on the ride',
    );

    final spoken = speakAt(123);
    await untilPlaying();
    expect(player.played, hasLength(1), reason: 'the rendered audio plays');
    expect(fallback.spoken, isEmpty, reason: 'no system voice');
    expect(outputs, [SpokenGuidanceOutput.natural]);
    expect(backend.rendered.last, contains('thirty yards'));

    player.finish();
    expect(await spoken, isTrue);
    expect(ride.delivered, contains('junction|approach'));
  });

  test(
    'every close prompt on the 4 October ride keeps the natural voice',
    () async {
      // (decided at, heard at, speed) in metres and metres per second, from the
      // log: where the rider was when the prompt was decided, where when the
      // render finished, and a speed that puts the prompt in the stage it was.
      const rides = [
        (61.0, 46.0, 3.0),
        (123.0, 100.0, 6.0),
        (154.0, 137.0, 7.7),
        (177.0, 146.0, 8.8),
        (149.0, 128.0, 7.4),
        (3963.0, 3860.0, 34.0),
        (579.0, 470.0, 29.0),
        (428.0, 330.0, 21.0),
      ];
      for (final (index, (decided, heard, speed)) in rides.indexed) {
        // A different junction each time, as on the ride.
        ride.identity = 'junction-$index';
        ride.delivered.clear();
        backend.onRender = () => ride.distance = heard;
        final spoken = speakAt(decided, speed: speed);
        await untilPlaying();
        expect(
          player.played,
          isNotEmpty,
          reason: 'decided at $decided m, heard at $heard m',
        );
        player.finish();
        expect(await spoken, isTrue, reason: '$decided m');
        player.played.clear();
      }
      expect(fallback.spoken, isEmpty);
      expect(outputs, everyElement(SpokenGuidanceOutput.natural));
      expect(outputs, hasLength(rides.length));
    },
  );

  test('a rider who slows while the voice renders still hears the prompt '
      '(#942)', () async {
    // The 10 October ride: "In 2.0 mi" was due as the early heads-up at
    // 3271 m only because the rider was doing 27.4 m/s. Two seconds later
    // they were at 26.3 m/s and the early stage was not due at that speed, so
    // the re-decision came back empty and the prompt was dropped in silence.
    backend.onRender = () {
      ride.distance = 3218;
      ride.speed = 26.3;
    };
    final spoken = speakAt(3271, speed: 27.4);
    await untilPlaying();
    expect(player.played, hasLength(1), reason: 'not dropped');
    expect(backend.rendered.last, startsWith('In 2.0 miles'));
    expect(fallback.spoken, isEmpty);
    player.finish();
    expect(await spoken, isTrue);
    expect(outputs, [SpokenGuidanceOutput.natural]);
    expect(ride.delivered, contains('junction|early'));
  });

  test(
    'a prompt whose distance is really out of date is dropped, not spoken '
    'by the system voice, and announced again from where the rider is',
    () async {
      // 428 m out: "In 0.3 mi". The render takes so long the rider has covered
      // more than two fifths of it, still in the same stage, so the words are
      // really out of date.
      backend.onRender = () => ride.distance = 250;
      final dropped = await speakAt(428, speed: 15);

      expect(dropped, isFalse);
      expect(fallback.spoken, isEmpty, reason: 'not the system voice');
      expect(player.played, isEmpty, reason: 'not stale audio');
      expect(
        ride.delivered,
        isNot(contains('junction|approach')),
        reason: 'the stage is not consumed, so the next fix announces it',
      );

      // The next fix, at the distance the rider has now, in the natural voice.
      backend.onRender = null;
      final next = speakAt(250, speed: 15);
      await untilPlaying();
      expect(player.played, hasLength(1));
      player.finish();
      expect(await next, isTrue);
      expect(outputs, [SpokenGuidanceOutput.natural]);
      expect(fallback.spoken, isEmpty);
    },
  );

  test('a later stage that arrives while an earlier one renders waits its turn '
      'and does not cost the natural voice', () async {
    ride.speed = 6;
    backend.hold();
    final first = speakAt(123);
    await backend.waitForRender();
    expect(speaker.isSpeaking, isTrue);

    // The next fix, 30 m from the junction: the final prompt is due, and the
    // speaker is busy with the first. It is refused without being consumed.
    ride.distance = 30;
    final closing = ride.announce()!;
    expect(closing.stage, GuidanceStage.immediate);
    final refused = await speaker.speakTrackedManoeuvre(
      deliveredKeys: ride.delivered,
      key: closing.key,
      phrase: closing.phrase,
      enabled: true,
      rideActive: true,
    );
    expect(refused, isFalse);
    expect(ride.delivered, isNot(contains(closing.key)));
    expect(fallback.spoken, isEmpty);

    // The first finishes rendering after the ride has moved on to the final
    // stage, so it is out of date and dropped; nothing goes to the system voice.
    backend.release();
    expect(await first, isFalse);
    expect(fallback.spoken, isEmpty);

    // And the final prompt, offered again at the next fix, is natural.
    final spoken = speakAt(28);
    await untilPlaying();
    player.finish();
    expect(await spoken, isTrue);
    expect(outputs, [SpokenGuidanceOutput.natural]);
    expect(fallback.spoken, isEmpty);
  });

  test('speech stopped while a prompt renders does not come out of the '
      'system voice', () async {
    backend.hold();
    final spoken = speakAt(123);
    await backend.waitForRender();

    await speaker.suspendNavigation();
    backend.release();

    expect(await spoken, isFalse);
    expect(fallback.spoken, isEmpty);
    expect(player.played, isEmpty);
  });

  test('a safety alert stopped while it renders is not said by the system '
      'voice and stays due', () async {
    backend.hold();
    final alert = speaker.speakAlert(
      key: 'camera-1',
      phrase: 'Speed camera, in 150 yards.',
      enabled: true,
      rideActive: true,
    );
    await backend.waitForRender();

    await speaker.suspendNavigation();
    backend.release();

    expect(await alert, isFalse);
    expect(fallback.spoken, isEmpty);

    // Not remembered as said: announced again once speech is allowed.
    speaker.resumeNavigation();
    final again = speaker.speakAlert(
      key: 'camera-1',
      phrase: 'Speed camera, in 150 yards.',
      enabled: true,
      rideActive: true,
    );
    await untilPlaying();
    player.finish();
    expect(await again, isTrue);
    expect(outputs, [SpokenGuidanceOutput.natural]);
  });

  test('a genuine natural-voice failure still gets the system voice', () async {
    backend.failNextRender = true;
    ride.distance = 123;
    ride.speed = 6;
    final issued = ride.announce()!;
    final spoken = await speaker.speakTrackedManoeuvre(
      deliveredKeys: ride.delivered,
      key: issued.key,
      phrase: issued.phrase,
      currentPhrase: () => ride.currentPhrase(issued, issuedAt: 123),
      enabled: true,
      rideActive: true,
    );

    expect(spoken, isTrue);
    expect(fallback.spoken, hasLength(1));
    expect(fallback.spoken.single, contains('thirty yards'));
    expect(outputs, [SpokenGuidanceOutput.systemFallback]);
  });

  test('both ride surfaces ask the schedule whether a rendered prompt is '
      'still right', () {
    for (final path in [
      'lib/features/ride/active_ride_shell.dart',
      'lib/features/home/home_map_backdrop.dart',
    ]) {
      final source = File(path).readAsStringSync();
      expect(source, contains('currentGuidancePhrase('), reason: path);
      expect(
        source,
        isNot(
          contains('refreshed?.key == announcement.key ? refreshed?.phrase'),
        ),
        reason: '$path compared the words exactly again',
      );
    }
  });
}

/// One junction, ahead of a rider, whose prompts are decided and re-decided the
/// way `_onNavigationGuidanceChanged` does it in the ride shell and Where To.
class _Ride {
  _Ride(this.formatter, this.instruction);

  final MeasurementFormatter formatter;
  final String instruction;
  final delivered = <String>{};
  String identity = 'junction';
  double distance = 0;
  double speed = 12;

  GuidanceAnnouncement? announceAt(
    double meters, {
    Set<String>? alreadySpoken,
  }) => nextGuidanceAnnouncement(
    maneuverIdentity: identity,
    instructionText: instruction,
    distanceToManeuverMeters: meters,
    speedMetersPerSecond: speed,
    alreadySpokenKeys: alreadySpoken ?? delivered,
    metersSincePreviousManeuver: null,
    distanceFormatter: formatter.spokenDistance,
  );

  GuidanceAnnouncement? announce() => announceAt(distance);

  String phraseAt(double meters) =>
      announceAt(meters, alreadySpoken: const {})!.phrase;

  /// The shell's `currentPhrase` closure: decide again with the guidance as it
  /// is now, and let the schedule say what that means for what was issued.
  String? currentPhrase(
    GuidanceAnnouncement issued, {
    required double issuedAt,
  }) {
    final refreshed = announceAt(
      distance,
      alreadySpoken: {...delivered}..remove(issued.key),
    );
    return currentGuidancePhrase(
      issued: issued,
      issuedDistanceMeters: issuedAt,
      refreshed: refreshed,
      currentDistanceMeters: distance,
    );
  }
}

class _GatedBackend implements NeuralSpeechBackend {
  void Function()? onRender;
  bool failNextRender = false;
  final rendered = <String>[];
  Completer<void>? _gate;
  final _rendering = Completer<void>();

  void hold() => _gate = Completer<void>();

  void release() => _gate?.complete();

  Future<void> waitForRender() => _rendering.future;

  @override
  Future<void> prepare() async {}

  @override
  Future<String> generate({
    required String phrase,
    required NaturalNavigationVoice voice,
    bool allowCachedAudio = true,
  }) async {
    if (phrase == 'Ready.') return '/tmp/natural-voice-prime.wav';
    rendered.add(phrase);
    if (!_rendering.isCompleted) _rendering.complete();
    final gate = _gate;
    if (gate != null) await gate.future;
    if (failNextRender) {
      failNextRender = false;
      throw StateError('The neural voice produced no audio.');
    }
    // The model is slow: while it renders, the rider keeps riding.
    onRender?.call();
    return '/tmp/natural-voice-render.wav';
  }

  @override
  Future<void> abort() async {}
}

class _FakeAudioPlayer extends Fake implements AudioPlayer {
  final completions = StreamController<void>.broadcast();
  final played = <Source>[];

  void finish() => completions.add(null);

  @override
  Stream<void> get onPlayerComplete => completions.stream;

  @override
  Future<void> setAudioContext(AudioContext ctx) async {}

  @override
  Future<void> setReleaseMode(ReleaseMode releaseMode) async {}

  @override
  Future<void> play(
    Source source, {
    double? volume,
    double? balance,
    AudioContext? ctx,
    Duration? position,
    PlayerMode? mode,
  }) async => played.add(source);

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}

class _RecordingEngine implements SpokenGuidanceEngine {
  final spoken = <String>[];

  @override
  Future<void> configure() async {}

  @override
  Future<void> speak(
    String phrase, {
    SpokenAudioClass audioClass = SpokenAudioClass.navigation,
  }) async => spoken.add(phrase);

  @override
  Future<void> stop() async {}
}
