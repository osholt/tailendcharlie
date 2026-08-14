import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/natural_voice_pack.dart';
import '../services/neural_spoken_guidance.dart';
import '../services/spoken_audio_mode.dart';
import '../services/spoken_guidance.dart';

/// Whether turn instructions are spoken aloud.
///
/// **Off by default, and that is not timidity.** Most riders already have an
/// intercom carrying music or another navigation app's prompts, and a second
/// uninvited voice is worse than silence. A rider who wants this will find it;
/// one who does not must never be surprised by it (#286).
class SpokenGuidanceController extends ChangeNotifier
    implements ValueListenable<bool> {
  SpokenGuidanceController._(
    this._preferences,
    this._mode,
    this._voice,
    this._engineOverride,
    this._voiceLoader,
    this.naturalVoicePack,
    this._naturalPreviewEngineOverride,
  ) {
    naturalVoicePack.addListener(_onNaturalVoiceChanged);
  }

  /// The voice. Carried here rather than built by the ride surface so a test can
  /// substitute one, and so there is exactly one place that decides what speaks.
  final SpokenGuidanceEngine Function()? _engineOverride;

  final SpokenGuidanceEngine Function()? _naturalPreviewEngineOverride;

  /// Cross-platform voice pack state is kept beside the OS voice choice. The
  /// installed OS voice remains the fail-safe for every natural utterance.
  final NaturalVoicePackController naturalVoicePack;

  /// Creates the ride's engine. The production closure reads [voice] before
  /// every phrase, so a Settings change applies without restarting the ride.
  SpokenGuidanceEngine Function() get engine =>
      _engineOverride ??
      () {
        final fallback = FlutterTtsSpokenGuidanceEngine(
          voiceProvider: () => _voice,
        );
        return AdaptiveNeuralSpokenGuidanceEngine(
          enabled: () =>
              naturalVoicePack.enabled &&
              naturalVoicePack.modelDirectory != null,
          neuralFactory: _createNaturalEngine,
          fallback: fallback,
        );
      };

  static const preferenceKey = 'spoken_guidance_enabled';

  /// Which of the three states the rider chose (#415).
  ///
  /// Stored beside the old boolean rather than replacing it, so a rider upgrading
  /// from a build that only had on/off keeps their choice: an absent mode falls
  /// back to the boolean, and `enabled` stays meaningful for every caller that
  /// only needs "is anything spoken".
  static const modePreferenceKey = 'spoken_guidance_mode';
  static const voicePreferenceKey = 'spoken_guidance_voice';
  static const voiceChoiceMadePreferenceKey =
      'spoken_guidance_voice_choice_made';
  static const voicePreviewPhrase =
      'In 2 miles, at the roundabout, turn right.';
  static const preferredDefaultVoice = SpokenGuidanceVoice(
    name: 'Daniel',
    locale: 'en-GB',
  );

  final SharedPreferences? _preferences;
  SpokenAudioMode _mode;
  SpokenGuidanceVoice? _voice;
  final Future<List<SpokenGuidanceVoice>> Function() _voiceLoader;

  static Future<SpokenGuidanceController> load() async {
    final preferences = await SharedPreferences.getInstance();
    late NaturalVoicePackController naturalVoicePack;
    try {
      naturalVoicePack = await NaturalVoicePackController.load();
    } on Object {
      // The optional pack must not prevent startup when platform storage is
      // unavailable (including pure Dart controller tests). OS speech remains
      // fully usable.
      naturalVoicePack = NaturalVoicePackController.inMemory(
        store: _UnavailableNaturalVoicePackStore(),
      );
    }
    final storedMode = preferences.getString(modePreferenceKey);
    return SpokenGuidanceController._(
      preferences,
      _modeFromNames(
        storedMode,
        fallbackEnabled: preferences.getBool(preferenceKey) ?? false,
      ),
      _voiceOnLoad(preferences),
      null,
      loadSpokenGuidanceVoices,
      naturalVoicePack,
      null,
    );
  }

  /// A stored mode if it is one this build knows, else the old boolean.
  ///
  /// An unrecognised value is treated as absent rather than as an error: a build
  /// that once wrote a mode this one has dropped must not leave a rider unable to
  /// turn audio on.
  static SpokenAudioMode _modeFromNames(
    String? stored, {
    required bool fallbackEnabled,
  }) {
    for (final mode in SpokenAudioMode.values) {
      if (mode.name == stored) return mode;
    }
    return fallbackEnabled
        ? SpokenAudioMode.everything
        : SpokenAudioMode.silent;
  }

  /// For tests and for callers that have no storage.
  SpokenGuidanceController.inMemory({
    bool enabled = false,
    SpokenAudioMode? mode,
    SpokenGuidanceVoice? voice,
    SpokenGuidanceEngine Function()? engine,
    Future<List<SpokenGuidanceVoice>> Function()? voiceLoader,
    NaturalVoicePackController? naturalVoicePack,
    SpokenGuidanceEngine Function()? naturalPreviewEngine,
  }) : this._(
         null,
         mode ??
             (enabled ? SpokenAudioMode.everything : SpokenAudioMode.silent),
         voice,
         engine,
         voiceLoader ?? loadSpokenGuidanceVoices,
         naturalVoicePack ??
             NaturalVoicePackController.inMemory(
               store: _UnavailableNaturalVoicePackStore(),
             ),
         naturalPreviewEngine,
       );

  @override
  bool get value => enabled;

  /// Whether anything at all is spoken. Kept for callers that do not care which
  /// class of thing it is.
  bool get enabled => _mode != SpokenAudioMode.silent;

  SpokenAudioMode get mode => _mode;
  SpokenGuidanceVoice? get voice => _voice;

  Future<List<SpokenGuidanceVoice>> availableVoices() => _voiceLoader();

  Future<void> setVoice(SpokenGuidanceVoice? voice) async {
    final changed = _voice != voice;
    _voice = voice;
    if (voice == null) {
      await _preferences?.remove(voicePreferenceKey);
    } else {
      await _preferences?.setString(
        voicePreferenceKey,
        jsonEncode(voice.toJson()),
      );
    }
    // Null has two meanings without this marker: a rider deliberately chose
    // System default, or an older/fresh install has never chosen. Only the
    // latter should receive Daniel as the product default (#508).
    await _preferences?.setBool(voiceChoiceMadePreferenceKey, true);
    if (changed) notifyListeners();
  }

  /// Saves a voice selection and gives the rider an immediate useful sample.
  ///
  /// Preview does not depend on guidance being enabled: Settings is where a
  /// rider decides whether they like a voice. Saving happens first and remains
  /// successful if a platform has no working speech engine (#503).
  Future<void> setVoiceAndPreview(SpokenGuidanceVoice? voice) async {
    await setVoice(voice);
    final preview =
        _engineOverride?.call() ??
        FlutterTtsSpokenGuidanceEngine(voiceProvider: () => _voice);
    try {
      await preview.configure();
      await preview.speak(voicePreviewPhrase);
    } on Object {
      // A voice preview is helpful, not a prerequisite for saving the choice.
      // The ordinary speech path will still fall back to the system default if
      // an installed voice disappears between Settings and the next ride.
    }
  }

  Future<void> installNaturalVoiceAndPreview() async {
    await naturalVoicePack.install();
    if (naturalVoicePack.installed) await previewNaturalVoice();
  }

  Future<void> setNaturalVoiceAndPreview(NaturalNavigationVoice voice) async {
    await naturalVoicePack.setVoice(voice);
    await previewNaturalVoice();
  }

  Future<void> previewNaturalVoice() async {
    if (!naturalVoicePack.installed) return;
    final preview =
        _naturalPreviewEngineOverride?.call() ??
        _createNaturalEngine(disposePlayerOnStop: true);
    try {
      await preview.configure();
      await preview.speak(voicePreviewPhrase);
    } on Object {
      // Installation remains useful even if this one preview cannot start. The
      // live ride engine will use the already configured OS fallback.
    } finally {
      await preview.stop();
    }
  }

  NeuralSpokenGuidanceEngine _createNaturalEngine({
    bool disposePlayerOnStop = false,
  }) {
    final directory = naturalVoicePack.modelDirectory;
    if (directory == null) {
      throw StateError('The natural voice pack is not installed.');
    }
    return NeuralSpokenGuidanceEngine(
      backend: SherpaOnnxNeuralSpeechBackend(modelDirectory: directory),
      voiceProvider: () => naturalVoicePack.voice,
      disposePlayerOnStop: disposePlayerOnStop,
    );
  }

  void _onNaturalVoiceChanged() => notifyListeners();

  /// What the rider gets by pressing the map control once more.
  SpokenAudioMode get nextMode => nextSpokenAudioMode(_mode);

  Future<void> setEnabled(bool enabled) =>
      setMode(enabled ? SpokenAudioMode.everything : SpokenAudioMode.silent);

  Future<void> setMode(SpokenAudioMode mode) async {
    if (_mode == mode) return;
    _mode = mode;
    await _preferences?.setString(modePreferenceKey, mode.name);
    // The old boolean is kept in step so a downgrade to a build without modes
    // still finds the rider's choice rather than defaulting them to silence.
    await _preferences?.setBool(preferenceKey, enabled);
    notifyListeners();
  }

  /// Advances to the next mode, which is what the map control does.
  Future<void> cycleMode() => setMode(nextMode);

  static SpokenGuidanceVoice? _voiceFromStorage(String? stored) {
    if (stored == null || stored.isEmpty) return null;
    try {
      final decoded = jsonDecode(stored);
      return decoded is Map
          ? SpokenGuidanceVoice.fromJson(Map<String, Object?>.from(decoded))
          : null;
    } on FormatException {
      return null;
    }
  }

  static SpokenGuidanceVoice? _voiceOnLoad(SharedPreferences preferences) {
    final stored = preferences.getString(voicePreferenceKey);
    final hasMadeChoice =
        preferences.getBool(voiceChoiceMadePreferenceKey) ??
        preferences.containsKey(voicePreferenceKey);
    if (hasMadeChoice) return _voiceFromStorage(stored);
    return preferredDefaultVoice;
  }

  @override
  void dispose() {
    naturalVoicePack.removeListener(_onNaturalVoiceChanged);
    naturalVoicePack.dispose();
    super.dispose();
  }
}

class _UnavailableNaturalVoicePackStore implements NaturalVoicePackStore {
  @override
  String get modelDirectory => '';

  @override
  Future<void> cancelInstall() async {}

  @override
  Future<void> install({required ValueChanged<double?> onProgress}) async {
    throw StateError('No natural voice pack store was supplied.');
  }

  @override
  Future<bool> isInstalled() async => false;

  @override
  Future<void> remove() async {}
}
