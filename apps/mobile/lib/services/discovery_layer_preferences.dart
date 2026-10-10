import 'package:shared_preferences/shared_preferences.dart';

import 'motorcycle_discovery.dart';

/// Persisted visibility for optional free-roam discovery overlays.
class DiscoveryLayerPreferences {
  DiscoveryLayerPreferences._(
    this._preferences,
    this.categories,
    this.bikerCafesVisible,
    this.fuelStationsVisible,
  );

  static const bikerCafesKey = 'map_layer_biker_cafes_visible';

  /// Fuel stations and chargers for the rider's fuel (#951). On by default:
  /// knowing where the next pump is matters on any ride.
  static const fuelStationsKey = 'map_layer_fuel_stations_visible';
  static const _categoryPrefix = 'map_layer_discovery_';

  final SharedPreferences _preferences;
  final Set<MotorcycleDiscoveryCategory> categories;
  bool bikerCafesVisible;
  bool fuelStationsVisible;

  static Future<DiscoveryLayerPreferences> load() async {
    final preferences = await SharedPreferences.getInstance();
    final categories = <MotorcycleDiscoveryCategory>{};
    for (final category in MotorcycleDiscoveryCategory.values) {
      final defaultVisible =
          category == MotorcycleDiscoveryCategory.twistyHighlight;
      if (preferences.getBool(_key(category)) ?? defaultVisible) {
        categories.add(category);
      }
    }
    return DiscoveryLayerPreferences._(
      preferences,
      categories,
      preferences.getBool(bikerCafesKey) ?? true,
      preferences.getBool(fuelStationsKey) ?? true,
    );
  }

  Future<void> setCategory(
    MotorcycleDiscoveryCategory category,
    bool visible,
  ) async {
    if (visible) {
      categories.add(category);
    } else {
      categories.remove(category);
    }
    await _preferences.setBool(_key(category), visible);
  }

  Future<void> setBikerCafesVisible(bool visible) async {
    bikerCafesVisible = visible;
    await _preferences.setBool(bikerCafesKey, visible);
  }

  Future<void> setFuelStationsVisible(bool visible) async {
    fuelStationsVisible = visible;
    await _preferences.setBool(fuelStationsKey, visible);
  }

  static String _key(MotorcycleDiscoveryCategory category) =>
      '$_categoryPrefix${category.apiValue}_visible';
}
