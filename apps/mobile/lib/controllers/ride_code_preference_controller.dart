import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Remembers only the six-digit code from a successful join.
///
/// The high-entropy invitation token is intentionally never accepted by this
/// controller, so it cannot leak into ordinary preferences or device backups.
class RideCodePreferenceController extends ChangeNotifier {
  RideCodePreferenceController._(
    this._preferences,
    this._keepCode,
    String? savedCode,
  ) : _savedCode = _validCode(savedCode);

  static const keepCodeKey = 'join_keep_last_ride_code';
  static const savedCodeKey = 'join_last_ride_code';

  final SharedPreferences? _preferences;
  bool _keepCode;
  String? _savedCode;

  bool get keepCode => _keepCode;
  String? get savedCode => _keepCode ? _savedCode : null;

  static Future<RideCodePreferenceController> load() async {
    final preferences = await SharedPreferences.getInstance();
    final keepCode = preferences.getBool(keepCodeKey) ?? true;
    final savedCode = keepCode
        ? _validCode(preferences.getString(savedCodeKey))
        : null;
    if (savedCode == null) await preferences.remove(savedCodeKey);
    return RideCodePreferenceController._(preferences, keepCode, savedCode);
  }

  @visibleForTesting
  factory RideCodePreferenceController.memory({
    bool keepCode = true,
    String? savedCode,
  }) => RideCodePreferenceController._(null, keepCode, savedCode);

  Future<void> setKeepCode(bool value) async {
    if (_keepCode == value) return;
    _keepCode = value;
    await _preferences?.setBool(keepCodeKey, value);
    if (!value) {
      _savedCode = null;
      await _preferences?.remove(savedCodeKey);
    }
    notifyListeners();
  }

  Future<void> rememberSuccessfulJoin(String code) async {
    if (!_keepCode) return;
    final validCode = _validCode(code);
    if (validCode == null || validCode == _savedCode) return;
    _savedCode = validCode;
    await _preferences?.setString(savedCodeKey, validCode);
    notifyListeners();
  }

  Future<void> clear() async {
    if (_savedCode == null) return;
    _savedCode = null;
    await _preferences?.remove(savedCodeKey);
    notifyListeners();
  }

  /// Removes a remembered code after the directory confirms it is inactive.
  /// The current form value remains untouched so the rider can correct it.
  Future<void> clearIfInactive(String code) async {
    if (_validCode(code) != _savedCode) return;
    await clear();
  }

  static String? _validCode(String? value) {
    final code = value?.trim();
    return code != null && RegExp(r'^\d{6}$').hasMatch(code) ? code : null;
  }
}
