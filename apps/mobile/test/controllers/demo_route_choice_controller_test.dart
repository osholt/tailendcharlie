import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/demo_route_choice_controller.dart';
import 'package:ride_relay/services/demo_route_loader.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a rider who has never chosen gets the default route', () async {
    SharedPreferences.setMockInitialValues({});
    final choice = await DemoRouteChoiceController.load();
    expect(choice.current, same(DemoRoutes.fallback));
  });

  test('the last choice is remembered across a restart (#934)', () async {
    SharedPreferences.setMockInitialValues({});
    final first = await DemoRouteChoiceController.load();
    await first.choose(DemoRoutes.france);
    expect(first.current, same(DemoRoutes.france));

    // A new controller over the same storage is the next launch.
    final second = await DemoRouteChoiceController.load();
    expect(second.current, same(DemoRoutes.france));

    await second.choose(DemoRoutes.cotswolds);
    expect(
      (await DemoRouteChoiceController.load()).current,
      same(DemoRoutes.cotswolds),
    );
  });

  test('choosing the default on purpose is stored too', () async {
    SharedPreferences.setMockInitialValues({});
    final choice = await DemoRouteChoiceController.load();
    await choice.choose(DemoRoutes.fallback);

    final preferences = await SharedPreferences.getInstance();
    expect(
      preferences.getString(DemoRouteChoiceController.preferenceKey),
      DemoRoutes.fallback.id,
    );
  });

  test('a stored id this build does not know reads as the default', () async {
    SharedPreferences.setMockInitialValues({
      DemoRouteChoiceController.preferenceKey: 'a-route-from-a-later-build',
    });
    expect(
      (await DemoRouteChoiceController.load()).current,
      same(DemoRoutes.fallback),
    );
  });

  test('listeners hear a change and only a change', () async {
    final choice = DemoRouteChoiceController.inMemory();
    var heard = 0;
    choice.addListener(() => heard += 1);

    await choice.choose(DemoRoutes.france);
    await choice.choose(DemoRoutes.france);
    expect(heard, 1);
  });
}
