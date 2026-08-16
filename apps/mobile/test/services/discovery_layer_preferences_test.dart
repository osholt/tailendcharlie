import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/services/discovery_layer_preferences.dart';
import 'package:ride_relay/services/motorcycle_discovery.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test(
    'cafes and twisty highlights are visible by default and persist',
    () async {
      SharedPreferences.setMockInitialValues({});
      final initial = await DiscoveryLayerPreferences.load();

      expect(initial.bikerCafesVisible, isTrue);
      expect(
        initial.categories,
        contains(MotorcycleDiscoveryCategory.twistyHighlight),
      );
      expect(
        initial.categories,
        isNot(contains(MotorcycleDiscoveryCategory.mountainPass)),
      );

      await initial.setBikerCafesVisible(false);
      await initial.setCategory(
        MotorcycleDiscoveryCategory.twistyHighlight,
        false,
      );
      await initial.setCategory(MotorcycleDiscoveryCategory.mountainPass, true);

      final restored = await DiscoveryLayerPreferences.load();
      expect(restored.bikerCafesVisible, isFalse);
      expect(
        restored.categories,
        isNot(contains(MotorcycleDiscoveryCategory.twistyHighlight)),
      );
      expect(
        restored.categories,
        contains(MotorcycleDiscoveryCategory.mountainPass),
      );
    },
  );
}
