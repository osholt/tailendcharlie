import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:ride_relay/services/spoken_audio_mode.dart';
import 'package:ride_relay/services/spoken_guidance.dart';
import 'package:ride_relay/services/spoken_guidance_audio_focus.dart';

/// The engine is behind an interface so these decisions - what to say, when, and
/// how often - can be tested without a platform channel. They are the part that
/// can be wrong in a way a rider on a bike would notice.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _RecordingEngine engine;
  late SpokenGuidanceSpeaker speaker;

  setUp(() {
    engine = _RecordingEngine();
    speaker = SpokenGuidanceSpeaker(engine);
  });

  Future<bool> speak({
    String key = 'turn-1',
    String phrase = 'Second exit',
    bool enabled = true,
    bool rideActive = true,
  }) => speaker.speakManoeuvre(
    key: key,
    phrase: phrase,
    enabled: enabled,
    rideActive: rideActive,
  );

  test('speaks a manoeuvre once', () async {
    expect(await speak(), isTrue);
    expect(engine.spoken, ['Second exit']);
  });

  test('does not repeat the same manoeuvre', () async {
    // Guidance is re-derived on every position fix, so without this a single turn
    // would be announced every few seconds all the way to the junction. Repetition
    // like that is worse than silence: a rider stops listening.
    await speak();
    expect(await speak(), isFalse);
    await speak();

    expect(engine.spoken, hasLength(1));
  });

  test('speaks the next manoeuvre after the first', () async {
    await speak(key: 'turn-1', phrase: 'Second exit');
    expect(await speak(key: 'turn-2', phrase: 'Turn left'), isTrue);

    expect(engine.spoken, ['Second exit', 'Turn left']);
  });

  test(
    'a temporarily denied prompt remains eligible for the next fix (#726)',
    () async {
      final denied = _DenyOnceEngine();
      final retryingSpeaker = SpokenGuidanceSpeaker(denied);
      final deliveredKeys = <String>{};

      expect(
        await retryingSpeaker.speakTrackedManoeuvre(
          deliveredKeys: deliveredKeys,
          key: 'turn-1|approach',
          phrase: 'In 500 yards, turn left',
          enabled: true,
          rideActive: true,
        ),
        isFalse,
      );
      expect(deliveredKeys, isEmpty);

      expect(
        await retryingSpeaker.speakTrackedManoeuvre(
          deliveredKeys: deliveredKeys,
          key: 'turn-1|approach',
          phrase: 'In 500 yards, turn left',
          enabled: true,
          rideActive: true,
        ),
        isTrue,
      );
      expect(deliveredKeys, {'turn-1|approach'});
      expect(denied.attempts, 2);
    },
  );

  test(
    'a later navigation stage is deferred while a prompt is active',
    () async {
      final blocking = _BlockingRecordingEngine();
      final guardedSpeaker = SpokenGuidanceSpeaker(blocking);

      final first = guardedSpeaker.speakManoeuvre(
        key: 'turn-1|approach',
        phrase: 'In 60 yd, turn right',
        enabled: true,
        rideActive: true,
      );
      await blocking.waitForCallCount(1);

      final second = guardedSpeaker.speakManoeuvre(
        key: 'turn-1|immediate',
        phrase: 'Turn right',
        enabled: true,
        rideActive: true,
      );
      await Future<void>.delayed(Duration.zero);
      final callsBeforeRelease = List<String>.of(blocking.spoken);
      blocking.completeAll();

      expect(await first, isTrue);
      expect(await second, isFalse);
      expect(callsBeforeRelease, ['In 60 yards, turn right']);
      expect(guardedSpeaker.isSpeaking, isFalse);

      final deferred = guardedSpeaker.speakManoeuvre(
        key: 'turn-1|immediate',
        phrase: 'Turn right',
        enabled: true,
        rideActive: true,
      );
      await blocking.waitForCallCount(2);
      blocking.completeNext();
      expect(
        await deferred,
        isTrue,
        reason: 'the deferred stage remains eligible after the speaker is idle',
      );
    },
  );

  test('a safety alert is serialized behind an active direction', () async {
    final blocking = _BlockingRecordingEngine();
    final guardedSpeaker = SpokenGuidanceSpeaker(blocking);

    final direction = guardedSpeaker.speakManoeuvre(
      key: 'turn-1|approach',
      phrase: 'In 60 yd, turn right',
      enabled: true,
      rideActive: true,
    );
    await blocking.waitForCallCount(1);
    final alert = guardedSpeaker.speakAlert(
      key: 'camera-1',
      phrase: 'Speed camera, in 150 yd',
      enabled: true,
      rideActive: true,
    );
    await Future<void>.delayed(Duration.zero);

    expect(blocking.spoken, ['In 60 yards, turn right']);
    blocking.completeNext();
    await direction;
    await blocking.waitForCallCount(2);
    expect(blocking.spoken, [
      'In 60 yards, turn right',
      'Speed camera, in 150 yards',
    ]);
    blocking.completeNext();
    expect(await alert, isTrue);
    expect(blocking.audioClasses, [
      SpokenAudioClass.navigation,
      SpokenAudioClass.safety,
    ]);
  });

  test(
    'host ownership loss cancels queued speech until explicit resume',
    () async {
      final blocking = _BlockingRecordingEngine();
      final guardedSpeaker = SpokenGuidanceSpeaker(blocking);
      final direction = guardedSpeaker.speakManoeuvre(
        key: 'turn-1',
        phrase: 'Turn right',
        enabled: true,
        rideActive: true,
      );
      await blocking.waitForCallCount(1);
      final queuedAlert = guardedSpeaker.speakAlert(
        key: 'camera-1',
        phrase: 'Speed camera',
        enabled: true,
        rideActive: true,
      );

      await guardedSpeaker.suspendNavigation();

      expect(await direction, isTrue);
      expect(await queuedAlert, isFalse);
      expect(
        await guardedSpeaker.speakManoeuvre(
          key: 'turn-2',
          phrase: 'Turn left',
          enabled: true,
          rideActive: true,
        ),
        isFalse,
      );

      guardedSpeaker.resumeNavigation();
      final resumed = guardedSpeaker.speakManoeuvre(
        key: 'turn-2',
        phrase: 'Turn left',
        enabled: true,
        rideActive: true,
      );
      await blocking.waitForCallCount(2);
      blocking.completeNext();
      expect(await resumed, isTrue);
    },
  );

  test('says nothing at all while the option is off', () async {
    // And touches no engine: a rider who has not asked for audio must not have a
    // speech engine initialised behind their back.
    expect(await speak(enabled: false), isFalse);

    expect(engine.spoken, isEmpty);
    expect(
      engine.configured,
      isFalse,
      reason: 'the engine must not be configured for a rider who said no',
    );
  });

  test('says nothing outside a running ride', () async {
    // An instruction read aloud after the ride has ended, or while still parked
    // at the start point, is noise at best and misleading at worst.
    expect(await speak(rideActive: false), isFalse);
    expect(engine.spoken, isEmpty);
  });

  test('an empty instruction is not spoken', () async {
    expect(await speak(phrase: '   '), isFalse);
    expect(engine.spoken, isEmpty);
  });

  test('configures the engine once, not per phrase', () async {
    await speak(key: 'turn-1');
    await speak(key: 'turn-2');
    await speak(key: 'turn-3');

    expect(
      engine.configureCalls,
      1,
      reason: 'audio session setup is not per-phrase work',
    );
  });

  test(
    'natural voice warm-up is silent, explicit, and reused by first alert',
    () async {
      final warmable = _WarmableRecordingEngine();
      final warmSpeaker = SpokenGuidanceSpeaker(warmable);

      expect(await warmSpeaker.warmUp(enabled: false), isFalse);
      expect(warmable.configureCalls, 0);
      expect(warmable.warmCalls, 0);

      expect(await warmSpeaker.warmUp(enabled: true), isTrue);
      expect(warmable.configureCalls, 1);
      expect(warmable.warmCalls, 1);

      await warmSpeaker.speakAlert(
        key: 'camera-1',
        phrase: 'Speed camera, in 151 yd',
        enabled: true,
        rideActive: true,
      );
      expect(warmable.configureCalls, 1);
      expect(warmable.spoken, ['Speed camera, in 151 yards']);
    },
  );

  test('a reset lets an identical manoeuvre be spoken again', () async {
    // Without this a new ride whose first manoeuvre happened to carry the same
    // identity as the last ride's final one would be silent for it.
    await speak(key: 'turn-1');
    speaker.reset();

    expect(await speak(key: 'turn-1'), isTrue);
    expect(engine.spoken, hasLength(2));
  });

  test('installed voice discovery keeps usable English voices', () async {
    final voices = await loadSpokenGuidanceVoices(_VoiceListTts());

    expect(voices, const [
      SpokenGuidanceVoice(
        name: 'Daniel',
        locale: 'en-GB',
        identifier: 'daniel',
        quality: 'enhanced',
        gender: 'male',
      ),
    ]);
    expect(voices.single.label, 'Daniel · en-GB · Enhanced');
  });

  test('Daniel and natural British voices sort ahead of novelty voices', () {
    final voices = [
      const SpokenGuidanceVoice(name: 'Bells', locale: 'en-US'),
      const SpokenGuidanceVoice(
        name: 'Samantha',
        locale: 'en-US',
        quality: 'premium',
      ),
      const SpokenGuidanceVoice(name: 'Martha', locale: 'en-GB'),
      const SpokenGuidanceVoice(
        name: 'Serena',
        locale: 'en-GB',
        quality: 'enhanced',
      ),
      const SpokenGuidanceVoice(name: 'Daniel', locale: 'en-GB'),
    ]..sort(compareSpokenGuidanceVoices);

    expect(voices.map((voice) => voice.name), [
      'Daniel',
      'Serena',
      'Martha',
      'Samantha',
      'Bells',
    ]);
    expect(voices.last.isRecommended, isFalse);
  });

  test('Android voice metadata identifies natural offline voices', () {
    final voice = SpokenGuidanceVoice.fromJson({
      'name': 'en-gb-x-gbb-local',
      'locale': 'en-GB',
      'quality': 'very high',
      'network_required': '0',
    });

    expect(voice, isNotNull);
    expect(voice!.requiresNetwork, isFalse);
    expect(voice.isRecommended, isTrue);
    expect(
      voice.label,
      'en-gb-x-gbb-local · en-GB · Very high quality · Offline',
    );
    expect(
      SpokenGuidanceVoice.fromJson(voice.toJson())!.requiresNetwork,
      isFalse,
    );
  });

  test(
    'the chosen voice is applied and system default can be restored',
    () async {
      const daniel = SpokenGuidanceVoice(
        name: 'Daniel',
        locale: 'en-GB',
        identifier: 'daniel',
      );
      SpokenGuidanceVoice? chosen = daniel;
      final tts = _VoiceRecordingTts();
      final voiceEngine = FlutterTtsSpokenGuidanceEngine(
        tts: tts,
        voiceProvider: () => chosen,
      );

      await voiceEngine.speak('Turn left');
      expect(tts.voices, [daniel.platformArguments]);

      chosen = null;
      await voiceEngine.speak('Turn right');
      expect(tts.clearVoiceCalls, 1);
      expect(tts.spoken, ['Turn left', 'Turn right']);
    },
  );

  test('a removed voice falls back instead of losing the prompt', () async {
    const removed = SpokenGuidanceVoice(name: 'Removed', locale: 'en-GB');
    final tts = _VoiceRecordingTts(voiceResult: 0);
    final voiceEngine = FlutterTtsSpokenGuidanceEngine(
      tts: tts,
      voiceProvider: () => removed,
    );

    await voiceEngine.speak('Second exit');

    expect(tts.clearVoiceCalls, 1);
    expect(tts.spoken, ['Second exit']);
  });

  test('expands display abbreviations before handing text to TTS', () async {
    final tts = _VoiceRecordingTts();
    final voiceEngine = FlutterTtsSpokenGuidanceEngine(tts: tts);

    await voiceEngine.speak(
      'In 1 yd, then 55 yd. Continue for 1.0 mi, then 2 mi. '
      'Clearance 1 ft, then 8 ft. In 1 m, then 400 m. '
      'Continue for 1.0 km, then 2 km at 30 mph or 50 km/h. '
      'Stay on the M4 past Lloyd Way.',
    );

    expect(tts.spoken, [
      'In 1 yard, then 55 yards. Continue for 1.0 mile, then 2 miles. '
          'Clearance 1 foot, then 8 feet. In 1 metre, then 400 metres. '
          'Continue for 1.0 kilometre, then 2 kilometres at '
          '30 miles per hour or 50 kilometres per hour. '
          'Stay on the M4 past Lloyd Way.',
    ]);
  });

  test('system TTS uses one short focus lease without plugin focus', () async {
    final tts = _VoiceRecordingTts();
    final focus = _RecordingAudioFocus();
    final lifecycle = <SpokenGuidanceLifecycleEvent>[];
    final voiceEngine = FlutterTtsSpokenGuidanceEngine(
      tts: tts,
      audioFocus: focus,
      onLifecycle: (_, event) => lifecycle.add(event),
    );

    await voiceEngine.speak(
      'Speed camera',
      audioClass: SpokenAudioClass.safety,
    );

    expect(focus.audioClasses, [SpokenAudioClass.safety]);
    expect(focus.abandonCalls, 1);
    expect(tts.focusValues, [isFalse]);
    expect(lifecycle, [
      SpokenGuidanceLifecycleEvent.focusAcquired,
      SpokenGuidanceLifecycleEvent.playbackCompleted,
    ]);
  });

  test(
    'system TTS stays silent when another audio owner denies focus',
    () async {
      final tts = _VoiceRecordingTts();
      final lifecycle = <SpokenGuidanceLifecycleEvent>[];
      final voiceEngine = FlutterTtsSpokenGuidanceEngine(
        tts: tts,
        audioFocus: _RecordingAudioFocus(granted: false),
        onLifecycle: (_, event) => lifecycle.add(event),
      );

      await expectLater(
        voiceEngine.speak('Turn right'),
        throwsA(isA<SpokenGuidanceFocusDenied>()),
      );

      expect(tts.spoken, isEmpty);
      expect(lifecycle, [SpokenGuidanceLifecycleEvent.focusDenied]);
    },
  );
}

class _RecordingEngine implements SpokenGuidanceEngine {
  final spoken = <String>[];
  final audioClasses = <SpokenAudioClass>[];
  int configureCalls = 0;
  bool stopped = false;

  bool get configured => configureCalls > 0;

  @override
  Future<void> configure() async => configureCalls += 1;

  @override
  Future<void> speak(
    String phrase, {
    SpokenAudioClass audioClass = SpokenAudioClass.navigation,
  }) async {
    spoken.add(phrase);
    audioClasses.add(audioClass);
  }

  @override
  Future<void> stop() async => stopped = true;
}

class _BlockingRecordingEngine extends _RecordingEngine {
  final _pending = <Completer<void>>[];
  Completer<void> _changed = Completer<void>();

  @override
  Future<void> speak(
    String phrase, {
    SpokenAudioClass audioClass = SpokenAudioClass.navigation,
  }) {
    spoken.add(phrase);
    audioClasses.add(audioClass);
    final completion = Completer<void>();
    _pending.add(completion);
    _changed.complete();
    _changed = Completer<void>();
    return completion.future;
  }

  Future<void> waitForCallCount(int count) async {
    while (spoken.length < count) {
      final changed = _changed.future;
      if (spoken.length >= count) return;
      await changed;
    }
  }

  void completeNext() {
    if (_pending.isEmpty) return;
    _pending.removeAt(0).complete();
  }

  void completeAll() {
    while (_pending.isNotEmpty) {
      completeNext();
    }
  }

  @override
  Future<void> stop() async {
    stopped = true;
    completeAll();
  }
}

class _DenyOnceEngine extends _RecordingEngine {
  int attempts = 0;

  @override
  Future<void> speak(
    String phrase, {
    SpokenAudioClass audioClass = SpokenAudioClass.navigation,
  }) async {
    attempts += 1;
    if (attempts == 1) throw const SpokenGuidanceFocusDenied();
    await super.speak(phrase, audioClass: audioClass);
  }
}

class _WarmableRecordingEngine extends _RecordingEngine
    implements WarmableSpokenGuidanceEngine {
  int warmCalls = 0;

  @override
  Future<void> warmUp() async => warmCalls += 1;
}

class _VoiceListTts extends FlutterTts {
  @override
  Future<dynamic> get getVoices async => [
    {
      'name': 'Daniel',
      'locale': 'en-GB',
      'identifier': 'daniel',
      'quality': 'enhanced',
      'gender': 'male',
    },
    {'name': 'Thomas', 'locale': 'fr-FR', 'identifier': 'thomas'},
    {'name': '', 'locale': 'en-US'},
  ];
}

class _VoiceRecordingTts extends FlutterTts {
  _VoiceRecordingTts({this.voiceResult = 1});

  final int voiceResult;
  final voices = <Map<String, String>>[];
  final spoken = <String>[];
  int clearVoiceCalls = 0;
  final focusValues = <bool>[];

  @override
  Future<dynamic> setVoice(Map<String, String> voice) async {
    voices.add(voice);
    return voiceResult;
  }

  @override
  Future<dynamic> clearVoice() async => clearVoiceCalls += 1;

  @override
  Future<dynamic> speak(String text, {bool focus = false}) async {
    spoken.add(text);
    focusValues.add(focus);
    return 1;
  }
}

class _RecordingAudioFocus implements SpokenGuidanceAudioFocus {
  _RecordingAudioFocus({this.granted = true});

  final bool granted;
  final audioClasses = <SpokenAudioClass>[];
  int abandonCalls = 0;

  @override
  bool get managesPlatformFocus => true;

  @override
  Future<bool> acquire({
    required SpokenAudioClass audioClass,
    required SpokenGuidanceFocusLost onLost,
  }) async {
    audioClasses.add(audioClass);
    return granted;
  }

  @override
  Future<void> abandon() async => abandonCalls += 1;
}
