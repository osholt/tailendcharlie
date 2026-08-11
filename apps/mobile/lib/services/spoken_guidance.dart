import 'package:flutter_tts/flutter_tts.dart';

/// Speaks turn instructions so a rider does not have to look down.
///
/// A tester asked for it directly: "does the directions also have audio prompts
/// or just visual?" (#286). On a bike this is not a convenience over the visual
/// guidance - guidance you have to *read* competes with the road, so audio is the
/// difference between guidance usable at speed and guidance usable only when
/// stopped.
///
/// The engine sits behind [SpokenGuidanceEngine] so the decisions in
/// [SpokenGuidanceSpeaker] - what to say, when, and how often - are testable
/// without a platform channel. Those decisions are the part that can be wrong in
/// a way a rider would notice.
abstract interface class SpokenGuidanceEngine {
  Future<void> configure();
  Future<void> speak(String phrase);
  Future<void> stop();
}

/// The real engine.
///
/// Two platform settings matter more than the voice does:
///
/// - **iOS must duck rather than take over.** Most riders have an intercom
///   carrying music or another navigation app. `.mixWithOthers` plus
///   `duckOthers` lowers the other source for the phrase instead of stopping it.
///   Getting this wrong makes the feature actively unwelcome, because a prompt
///   that kills the music is worse than no prompt.
/// - **Android must not request audio focus permanently**, for the same reason.
///
/// **Foreground only, deliberately.** iOS would need the `audio` background mode
/// declared for prompts to continue once the app is not frontmost, and that is not
/// added here for two reasons. It is a release and review decision rather than a
/// code one. And #205 means the app does not yet record position in the
/// background at all - so background prompts would be guidance computed from a
/// position that had stopped updating, which is worse than silence. A rider
/// running another navigation app in front will not hear these; that is a known
/// limit, not an oversight.
class FlutterTtsSpokenGuidanceEngine implements SpokenGuidanceEngine {
  FlutterTtsSpokenGuidanceEngine([FlutterTts? tts])
    : _tts = tts ?? FlutterTts();

  final FlutterTts _tts;

  @override
  Future<void> configure() async {
    await _tts.setSharedInstance(true);
    await _tts.setIosAudioCategory(IosTextToSpeechAudioCategory.playback, [
      IosTextToSpeechAudioCategoryOptions.mixWithOthers,
      IosTextToSpeechAudioCategoryOptions.duckOthers,
    ], IosTextToSpeechAudioMode.voicePrompt);
    // Slightly slower than default: a phrase heard once at 50 mph through a
    // helmet has to land first time.
    await _tts.setSpeechRate(0.48);
    await _tts.awaitSpeakCompletion(true);
  }

  @override
  Future<void> speak(String phrase) => _tts.speak(phrase);

  @override
  Future<void> stop() => _tts.stop();
}

/// Decides what is worth saying, and refuses to say it twice.
///
/// Deliberately holds no opinion about how instructions are computed - #15, #103,
/// #127 and #163 own that. This speaks what the screen is already showing, and
/// nothing the screen is not: a rider who hears one thing and sees another will
/// trust neither.
class SpokenGuidanceSpeaker {
  SpokenGuidanceSpeaker(this._engine);

  final SpokenGuidanceEngine _engine;

  String? _lastSpokenKey;
  final _spokenAlertKeys = <String>{};
  bool _configured = false;

  /// The instruction most recently spoken, for tests and for the caller to check
  /// it is not about to repeat itself.
  String? get lastSpokenKey => _lastSpokenKey;

  /// Speaks [phrase] for the manoeuvre identified by [key], at most once.
  ///
  /// [key] is the manoeuvre's identity rather than its wording, so re-rendering
  /// the same turn - which happens on every position fix - does not speak it
  /// again. Repeating a prompt every few seconds would be worse than silence.
  ///
  /// Returns whether anything was spoken, so a caller can tell "already said" from
  /// "not appropriate".
  Future<bool> speakManoeuvre({
    required String key,
    required String phrase,
    required bool enabled,
    required bool rideActive,
  }) async {
    // Off means silent, with no engine work at all: a rider who has not asked for
    // audio must not have a speech engine initialised behind their back.
    if (!enabled) return false;
    // Nothing is spoken outside a running ride. An instruction read aloud after
    // the ride has ended, or while still parked at the start, is noise at best
    // and misleading at worst.
    if (!rideActive) return false;
    if (phrase.trim().isEmpty) return false;
    if (key == _lastSpokenKey) return false;

    if (!_configured) {
      await _engine.configure();
      _configured = true;
    }
    _lastSpokenKey = key;
    await _engine.speak(phrase);
    return true;
  }

  /// Speaks a warning about the road, which is a different class of thing from a
  /// turn (#430).
  ///
  /// Kept apart from [speakManoeuvre] on purpose. A turn is guidance and a camera
  /// is safety, and #415's alerts-only mode exists precisely so a rider can
  /// silence one without silencing the other. Sharing one method would have made
  /// that distinction a boolean somebody forgets to pass.
  ///
  /// [key] is the hazard's identity, so a warning armed a mile out and held all
  /// the way in is said once rather than on every fix.
  Future<bool> speakAlert({
    required String key,
    required String phrase,
    required bool enabled,
    required bool rideActive,
  }) async {
    if (!enabled) return false;
    if (!rideActive) return false;
    if (phrase.trim().isEmpty) return false;
    if (_spokenAlertKeys.contains(key)) return false;

    if (!_configured) {
      await _engine.configure();
      _configured = true;
    }
    // Alerts keep their own memory rather than sharing `_lastSpokenKey`: a turn
    // spoken between two sightings of the same camera would otherwise let the
    // camera be announced twice.
    _spokenAlertKeys.add(key);
    await _engine.speak(phrase);
    return true;
  }

  /// Forgets what was last spoken, so the next ride starts clean.
  ///
  /// Without this a new ride whose first manoeuvre happened to carry the same
  /// identity as the last ride's final one would be silent for it.
  void reset() {
    _lastSpokenKey = null;
    _spokenAlertKeys.clear();
  }

  Future<void> stop() => _engine.stop();
}
