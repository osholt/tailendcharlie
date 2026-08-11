import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
  SpokenGuidanceController._(this._preferences, this._mode, this.engine);

  /// The voice. Carried here rather than built by the ride surface so a test can
  /// substitute one, and so there is exactly one place that decides what speaks.
  final SpokenGuidanceEngine Function() engine;

  static const preferenceKey = 'spoken_guidance_enabled';

  /// Which of the three states the rider chose (#415).
  ///
  /// Stored beside the old boolean rather than replacing it, so a rider upgrading
  /// from a build that only had on/off keeps their choice: an absent mode falls
  /// back to the boolean, and `enabled` stays meaningful for every caller that
  /// only needs "is anything spoken".
  static const modePreferenceKey = 'spoken_guidance_mode';

  final SharedPreferences? _preferences;
  SpokenAudioMode _mode;

  static Future<SpokenGuidanceController> load() async {
    final preferences = await SharedPreferences.getInstance();
    final storedMode = preferences.getString(modePreferenceKey);
    return SpokenGuidanceController._(
      preferences,
      _modeFromNames(
        storedMode,
        fallbackEnabled: preferences.getBool(preferenceKey) ?? false,
      ),
      FlutterTtsSpokenGuidanceEngine.new,
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
    SpokenGuidanceEngine Function()? engine,
  }) : this._(
         null,
         mode ??
             (enabled ? SpokenAudioMode.everything : SpokenAudioMode.silent),
         engine ?? FlutterTtsSpokenGuidanceEngine.new,
       );

  @override
  bool get value => enabled;

  /// Whether anything at all is spoken. Kept for callers that do not care which
  /// class of thing it is.
  bool get enabled => _mode != SpokenAudioMode.silent;

  SpokenAudioMode get mode => _mode;

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
}
