import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/route_progress_display_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('defaults on and remembers an explicit choice', () async {
    SharedPreferences.setMockInitialValues({});
    final controller = await RouteProgressDisplayController.load();
    addTearDown(controller.dispose);

    expect(controller.enabled, isTrue);
    await controller.setEnabled(false);

    final restored = await RouteProgressDisplayController.load();
    addTearDown(restored.dispose);
    expect(restored.enabled, isFalse);
  });
}
