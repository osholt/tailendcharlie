import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/distance_unit.dart';
import '../services/road_jurisdiction.dart';

class DistanceUnitController extends ChangeNotifier
    implements ValueListenable<DistanceUnit> {
  factory DistanceUnitController.forLocale(
    Locale locale, {
    Future<RoadJurisdictionCatalogue> Function() readRoadJurisdictions =
        bundledRoadJurisdictions,
  }) => DistanceUnitController._(null, locale, null, readRoadJurisdictions);

  DistanceUnitController._(
    this._preferences,
    this.locale,
    this._override,
    this._readRoadJurisdictions,
  );

  static const preferenceKey = 'distance_unit_override';

  final SharedPreferences? _preferences;
  final Locale locale;
  final Future<RoadJurisdictionCatalogue> Function() _readRoadJurisdictions;
  DistanceUnit? _override;
  RoadJurisdiction? _roadJurisdiction;
  int _positionGeneration = 0;

  static Future<DistanceUnitController> load({
    required Locale locale,
    Future<RoadJurisdictionCatalogue> Function() readRoadJurisdictions =
        bundledRoadJurisdictions,
  }) async {
    final preferences = await SharedPreferences.getInstance();
    final stored = preferences.getString(preferenceKey);
    final override = DistanceUnit.values
        .where((unit) => unit.name == stored)
        .firstOrNull;
    return DistanceUnitController._(
      preferences,
      locale,
      override,
      readRoadJurisdictions,
    );
  }

  static DistanceUnit defaultForLocale(Locale locale) {
    final country = locale.countryCode?.toUpperCase();
    return country == 'GB' || country == 'UK' || country == 'US'
        ? DistanceUnit.miles
        : DistanceUnit.kilometres;
  }

  DistanceUnit get localeDefault => defaultForLocale(locale);

  DistanceUnit get automaticDefault =>
      _roadJurisdiction?.distanceUnit ?? localeDefault;

  RoadJurisdiction? get roadJurisdiction => _roadJurisdiction;

  bool get followsLocale => _override == null;

  bool get followsAutomatic => _override == null;

  @override
  DistanceUnit get value => _override ?? automaticDefault;

  /// Updates automatic units from where the road actually is.
  ///
  /// A UK phone remains a UK phone in France; using the device locale alone
  /// therefore leaves every distance in miles. The bundled lookup is offline,
  /// and an explicit rider override still wins.
  Future<void> observeRoadPosition({
    required double latitude,
    required double longitude,
  }) async {
    final generation = ++_positionGeneration;
    final catalogue = await _readRoadJurisdictions();
    if (generation != _positionGeneration) return;
    final resolved = catalogue.resolve(
      latitude: latitude,
      longitude: longitude,
    );
    if (resolved?.countryCode == _roadJurisdiction?.countryCode) return;
    _roadJurisdiction = resolved;
    notifyListeners();
  }

  Future<void> setUnit(DistanceUnit unit) async {
    if (_override == unit) return;
    _override = unit;
    await _preferences?.setString(preferenceKey, unit.name);
    notifyListeners();
  }

  Future<void> useLocaleDefault() async {
    if (_override == null) return;
    _override = null;
    await _preferences?.remove(preferenceKey);
    notifyListeners();
  }

  Future<void> useAutomaticDefault() => useLocaleDefault();
}
