import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/speed_adaptive_zoom_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'is on until the rider says otherwise, and remembers the choice',
    () async {
      SharedPreferences.setMockInitialValues({});
      final controller = await SpeedAdaptiveZoomController.load();
      addTearDown(controller.dispose);

      expect(controller.enabled, isTrue);
      await controller.setEnabled(false);

      final restored = await SpeedAdaptiveZoomController.load();
      addTearDown(restored.dispose);
      expect(restored.enabled, isFalse);

      await restored.setEnabled(true);
      final again = await SpeedAdaptiveZoomController.load();
      addTearDown(again.dispose);
      expect(again.enabled, isTrue);
    },
  );

  test('tells listeners only when the value changes', () async {
    SharedPreferences.setMockInitialValues({});
    final controller = SpeedAdaptiveZoomController.inMemory();
    addTearDown(controller.dispose);
    var notified = 0;
    controller.addListener(() => notified += 1);

    await controller.setEnabled(true);
    expect(notified, 0, reason: 'already on');
    await controller.setEnabled(false);
    await controller.setEnabled(false);
    expect(notified, 1);
    expect(controller.enabled, isFalse);
  });
}
