import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/services/spoken_guidance.dart';

/// The engine is behind an interface so these decisions - what to say, when, and
/// how often - can be tested without a platform channel. They are the part that
/// can be wrong in a way a rider on a bike would notice.
void main() {
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

  test('a reset lets an identical manoeuvre be spoken again', () async {
    // Without this a new ride whose first manoeuvre happened to carry the same
    // identity as the last ride's final one would be silent for it.
    await speak(key: 'turn-1');
    speaker.reset();

    expect(await speak(key: 'turn-1'), isTrue);
    expect(engine.spoken, hasLength(2));
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
