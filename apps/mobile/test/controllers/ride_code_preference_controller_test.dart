import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/ride_code_preference_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('remembers and replaces only valid successful ride codes', () async {
    final controller = await RideCodePreferenceController.load();

    await controller.rememberSuccessfulJoin('123456');
    expect(controller.savedCode, '123456');

    await controller.rememberSuccessfulJoin(
      '654321#not-a-preference-safe-invitation-token',
    );
    expect(controller.savedCode, '123456');

    await controller.rememberSuccessfulJoin('654321');
    expect(controller.savedCode, '654321');

    final preferences = await SharedPreferences.getInstance();
    expect(
      preferences.getString(RideCodePreferenceController.savedCodeKey),
      '654321',
    );
  });

  test('opt out clears the value and prevents future saves', () async {
    final controller = await RideCodePreferenceController.load();
    await controller.rememberSuccessfulJoin('123456');

    await controller.setKeepCode(false);
    await controller.rememberSuccessfulJoin('654321');

    expect(controller.keepCode, isFalse);
    expect(controller.savedCode, isNull);
    final preferences = await SharedPreferences.getInstance();
    expect(
      preferences.containsKey(RideCodePreferenceController.savedCodeKey),
      isFalse,
    );
  });

  test(
    'inactive saved code is cleared without clearing a different code',
    () async {
      final controller = await RideCodePreferenceController.load();
      await controller.rememberSuccessfulJoin('123456');

      await controller.clearIfInactive('654321');
      expect(controller.savedCode, '123456');

      await controller.clearIfInactive('123456');
      expect(controller.savedCode, isNull);
    },
  );

  test('load discards malformed preference values', () async {
    SharedPreferences.setMockInitialValues({
      RideCodePreferenceController.savedCodeKey: '123456#secret',
    });

    final controller = await RideCodePreferenceController.load();

    expect(controller.savedCode, isNull);
    final preferences = await SharedPreferences.getInstance();
    expect(
      preferences.containsKey(RideCodePreferenceController.savedCodeKey),
      isFalse,
    );
  });
}
