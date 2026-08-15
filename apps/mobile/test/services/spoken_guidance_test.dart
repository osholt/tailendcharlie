import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:ride_relay/services/spoken_guidance.dart';

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
}

class _RecordingEngine implements SpokenGuidanceEngine {
  final spoken = <String>[];
  int configureCalls = 0;
  bool stopped = false;

  bool get configured => configureCalls > 0;

  @override
  Future<void> configure() async => configureCalls += 1;

  @override
  Future<void> speak(String phrase) async => spoken.add(phrase);

  @override
  Future<void> stop() async => stopped = true;
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
    return 1;
  }
}
