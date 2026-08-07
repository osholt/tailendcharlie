import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/spoken_guidance.dart';

/// Whether turn instructions are spoken aloud.
///
/// **Off by default, and that is not timidity.** Most riders already have an
/// intercom carrying music or another navigation app's prompts, and a second
/// uninvited voice is worse than silence. A rider who wants this will find it;
/// one who does not must never be surprised by it (#286).
class SpokenGuidanceController extends ChangeNotifier
    implements ValueListenable<bool> {
  SpokenGuidanceController._(this._preferences, this._enabled, this.engine);

  /// The voice. Carried here rather than built by the ride surface so a test can
  /// substitute one, and so there is exactly one place that decides what speaks.
  final SpokenGuidanceEngine Function() engine;

  static const preferenceKey = 'spoken_guidance_enabled';

  final SharedPreferences? _preferences;
  bool _enabled;

  static Future<SpokenGuidanceController> load() async {
    final preferences = await SharedPreferences.getInstance();
    return SpokenGuidanceController._(
      preferences,
      preferences.getBool(preferenceKey) ?? false,
      FlutterTtsSpokenGuidanceEngine.new,
    );
  }

  /// For tests and for callers that have no storage.
  SpokenGuidanceController.inMemory({
    bool enabled = false,
    SpokenGuidanceEngine Function()? engine,
  }) : this._(null, enabled, engine ?? FlutterTtsSpokenGuidanceEngine.new);

  @override
  bool get value => _enabled;

  bool get enabled => _enabled;

  Future<void> setEnabled(bool enabled) async {
    if (_enabled == enabled) return;
    _enabled = enabled;
    await _preferences?.setBool(preferenceKey, enabled);
    notifyListeners();
  }
}
