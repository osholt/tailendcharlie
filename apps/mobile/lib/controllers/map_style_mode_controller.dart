import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/map_style_mode.dart';

typedef SunPositionSource = Future<GeoCoordinate?> Function();

class MapStyleModeController extends ChangeNotifier
    implements ValueListenable<MapStyleMode> {
  MapStyleModeController._(
    this._preferences,
    this._mode,
    this._dayStyle,
    this._locationSource,
  );

  static const preferenceKey = 'map_style_mode';
  static const dayStylePreferenceKey = 'day_map_style';
  static const defaultMode = MapStyleMode.system;
  static const defaultDayStyle = DayMapStyle.restrained;

  final SharedPreferences? _preferences;
  final SunPositionSource _locationSource;
  MapStyleMode _mode;
  DayMapStyle _dayStyle;
  GeoCoordinate? _lastKnownSunPosition;

  static Future<MapStyleModeController> load({
    SunPositionSource? locationSource,
  }) async {
    final preferences = await SharedPreferences.getInstance();
    final stored = preferences.getString(preferenceKey);
    final mode =
        MapStyleMode.values
            .where((value) => value.name == stored)
            .firstOrNull ??
        defaultMode;
    final storedDayStyle = preferences.getString(dayStylePreferenceKey);
    final dayStyle =
        DayMapStyle.values
            .where((value) => value.name == storedDayStyle)
            .firstOrNull ??
        defaultDayStyle;
    final controller = MapStyleModeController._(
      preferences,
      mode,
      dayStyle,
      locationSource ?? _lastKnownDevicePosition,
    );
    if (mode == MapStyleMode.sunriseSunset) {
      await controller.refreshSunPosition();
    }
    return controller;
  }

  @override
  MapStyleMode get value => _mode;

  DayMapStyle get dayStyle => _dayStyle;

  /// Whether a location fix is already cached for [MapStyleMode.sunriseSunset]
  /// - if not, [resolveDark] is currently falling back to platform brightness.
  bool get hasSunPosition => _lastKnownSunPosition != null;

  /// Resolves [value] to a definite dark/light choice, folding in the last
  /// known sun position for [MapStyleMode.sunriseSunset].
  bool resolveDark(Brightness platformBrightness) =>
      _mode.resolveDark(platformBrightness, sunPosition: _lastKnownSunPosition);

  Future<void> setMode(MapStyleMode mode) async {
    if (_mode == mode) return;
    _mode = mode;
    await _preferences?.setString(preferenceKey, mode.name);
    notifyListeners();
    if (mode == MapStyleMode.sunriseSunset && _lastKnownSunPosition == null) {
      await refreshSunPosition();
    }
  }

  Future<void> setDayStyle(DayMapStyle style) async {
    if (_dayStyle == style) return;
    _dayStyle = style;
    await _preferences?.setString(dayStylePreferenceKey, style.name);
    notifyListeners();
  }

  /// Re-reads the device's last known location for
  /// [MapStyleMode.sunriseSunset] - a cache refresh, not a live location
  /// subscription, since this doesn't need to track movement in real time.
  /// A failing location source leaves the previous (or absent) position in
  /// place rather than throwing - map appearance falling back to platform
  /// brightness is preferable to crashing the settings screen.
  Future<void> refreshSunPosition() async {
    GeoCoordinate? position;
    try {
      position = await _locationSource();
    } on Object {
      position = null;
    }
    if (position == _lastKnownSunPosition) return;
    _lastKnownSunPosition = position;
    notifyListeners();
  }

  static Future<GeoCoordinate?> _lastKnownDevicePosition() async {
    final position = await Geolocator.getLastKnownPosition();
    if (position == null) return null;
    return (latitude: position.latitude, longitude: position.longitude);
  }
}
