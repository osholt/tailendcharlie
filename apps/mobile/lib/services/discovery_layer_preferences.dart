import 'package:shared_preferences/shared_preferences.dart';

import 'motorcycle_discovery.dart';

/// Persisted visibility for optional free-roam discovery overlays.
class DiscoveryLayerPreferences {
  DiscoveryLayerPreferences._(
    this._preferences,
    this.categories,
    this.bikerCafesVisible,
  );

  static const bikerCafesKey = 'map_layer_biker_cafes_visible';
  static const _categoryPrefix = 'map_layer_discovery_';

  final SharedPreferences _preferences;
  final Set<MotorcycleDiscoveryCategory> categories;
  bool bikerCafesVisible;

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

  static String _key(MotorcycleDiscoveryCategory category) =>
      '$_categoryPrefix${category.apiValue}_visible';
}
