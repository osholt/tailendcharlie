import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Remembers whether the compact route time/distance panel is shown (#413).
class RouteProgressDisplayController extends ChangeNotifier {
  RouteProgressDisplayController._(this._preferences, this._enabled);

  static const preferenceKey = 'route_progress_display_enabled_v1';
  static const defaultEnabled = true;

  final SharedPreferences? _preferences;
  bool _enabled;

  bool get enabled => _enabled;

  static Future<RouteProgressDisplayController> load() async {
    final preferences = await SharedPreferences.getInstance();
    return RouteProgressDisplayController._(
      preferences,
      preferences.getBool(preferenceKey) ?? defaultEnabled,
    );
  }

  factory RouteProgressDisplayController.inMemory({
    bool enabled = defaultEnabled,
  }) => RouteProgressDisplayController._(null, enabled);

  Future<void> setEnabled(bool value) async {
    if (_enabled == value) return;
    _enabled = value;
    notifyListeners();
    await _preferences?.setBool(preferenceKey, value);
  }
}
