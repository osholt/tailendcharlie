import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Whether turn instructions are spoken aloud.
///
/// **Off by default, and that is not timidity.** Most riders already have an
/// intercom carrying music or another navigation app's prompts, and a second
/// uninvited voice is worse than silence. A rider who wants this will find it;
/// one who does not must never be surprised by it (#286).
class SpokenGuidanceController extends ChangeNotifier
    implements ValueListenable<bool> {
  SpokenGuidanceController._(this._preferences, this._enabled);

  static const preferenceKey = 'spoken_guidance_enabled';

  final SharedPreferences? _preferences;
  bool _enabled;

  static Future<SpokenGuidanceController> load() async {
    final preferences = await SharedPreferences.getInstance();
    return SpokenGuidanceController._(
      preferences,
      preferences.getBool(preferenceKey) ?? false,
    );
  }

  /// For tests and for callers that have no storage.
  SpokenGuidanceController.inMemory({bool enabled = false})
    : this._(null, enabled);

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
