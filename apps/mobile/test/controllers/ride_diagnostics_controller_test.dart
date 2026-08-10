import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/ride_diagnostics_controller.dart';
import 'package:ride_relay/services/ride_diagnostics_configuration.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('recording is off until it is asked for', () async {
    final controller = await RideDiagnosticsController.load();

    expect(controller.isOn, isFalse);
  });

  group(
    'an ordinary build cannot record, whatever storage says',
    () {
      // The case this exists for: a phone that ran an instrumented build with the
      // switch on, then took an ordinary build over the top. The stored `true`
      // survives the upgrade, and only the compile-time gate stands between it and
      // a store build writing a location log.
      test('a stored true does not switch recording on', () async {
        SharedPreferences.setMockInitialValues({
          RideDiagnosticsController.preferenceKey: true,
        });

        final controller = await RideDiagnosticsController.load();

        expect(controller.isOn, isFalse);
        expect(controller.isAvailable, isFalse);
      });

      test('it refuses to be switched on when asked directly', () async {
        final controller = await RideDiagnosticsController.load();

        await controller.setEnabled(true);

        expect(controller.isOn, isFalse);
      });
    },
    skip: RideDiagnosticsConfiguration.enabled
        ? 'asserts the define-off build; run without RIDE_RELAY_RIDE_DIAGNOSTICS'
        : null,
  );

  group(
    'an instrumented build can be switched on and off',
    () {
      test('the switch persists and notifies', () async {
        final controller = await RideDiagnosticsController.load();
        var notifications = 0;
        controller.addListener(() => notifications += 1);

        await controller.setEnabled(true);
        expect(controller.isOn, isTrue);
        expect(notifications, 1);

        // Reloading is what a rider does by restarting the app.
        final reloaded = await RideDiagnosticsController.load();
        expect(reloaded.isOn, isTrue);

        await controller.setEnabled(false);
        expect(controller.isOn, isFalse);
        expect(notifications, 2);
      });

      test('setting the value it already has notifies nobody', () async {
        final controller = await RideDiagnosticsController.load();
        var notifications = 0;
        controller.addListener(() => notifications += 1);

        await controller.setEnabled(false);

        expect(notifications, 0);
      });
    },
    skip: RideDiagnosticsConfiguration.enabled
        ? null
        : 'asserts the instrumented build; run with RIDE_RELAY_RIDE_DIAGNOSTICS',
  );
}
