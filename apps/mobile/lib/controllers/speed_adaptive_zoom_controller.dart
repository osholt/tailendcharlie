import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Remembers whether the follow camera zooms with road speed (#936).
///
/// On by default: a rider who has never opened Settings gets a map that is
/// closer around town and further out on the open road. Off puts back the
/// framing the app had before, which varies the zoom by a fixed 0.8 of a level
/// across the whole speed range.
class SpeedAdaptiveZoomController extends ChangeNotifier {
  SpeedAdaptiveZoomController._(this._preferences, this._enabled);

  static const preferenceKey = 'navigation_speed_zoom_enabled_v1';
  static const defaultEnabled = true;

  final SharedPreferences? _preferences;
  bool _enabled;

  bool get enabled => _enabled;

  static Future<SpeedAdaptiveZoomController> load() async {
    final preferences = await SharedPreferences.getInstance();
    return SpeedAdaptiveZoomController._(
      preferences,
      preferences.getBool(preferenceKey) ?? defaultEnabled,
    );
  }

  factory SpeedAdaptiveZoomController.inMemory({
    bool enabled = defaultEnabled,
  }) => SpeedAdaptiveZoomController._(null, enabled);

  Future<void> setEnabled(bool value) async {
    if (_enabled == value) return;
    _enabled = value;
    notifyListeners();
    await _preferences?.setBool(preferenceKey, value);
  }
}
