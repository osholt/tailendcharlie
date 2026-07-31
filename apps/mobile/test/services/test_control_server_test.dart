import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/test_control_controller.dart';
import 'package:ride_relay/services/test_control_configuration.dart';

/// The define-**off** half of the test-control coverage: what an ordinary build,
/// and every store build, must do.
///
/// `test_control_server_enabled_test.dart` is the mirror image. Each half skips
/// itself in the other's configuration, so `flutter test` and
/// `flutter test --dart-define=RIDE_RELAY_TEST_CONTROL=true` are both green and
/// neither silently covers nothing.
void main() {
  // Always-true properties, whichever way the build was compiled.
  group('TestControlConfiguration invariants', () {
    test('excludes every action that reaches a person or a phone network', () {
      // Named individually rather than asserting a count, so adding an exclusion
      // is easy and removing one has to be deliberate.
      expect(
        testControlForbiddenActions,
        containsAll(<String>[
          'sos',
          'emergency',
          'ice',
          'contact-share',
          'call',
          'message-send',
        ]),
      );
    });

    test('closes an abandoned session rather than holding a port open', () {
      expect(
        TestControlConfiguration.defaultIdleTimeout,
        lessThanOrEqualTo(const Duration(hours: 1)),
      );
    });
  });

  group(
    'without the compile-time define',
    () {
      // The single most important assertion in the suite. Every other gate is a
      // runtime decision that could be got wrong; this one is what keeps the
      // surface out of a store build entirely.
      //
      // The default suite runs without the define, exactly as CI and a release
      // build do. If this fails, a shipped build can be driven over the network
      // by anyone who can reach the phone.
      test('the surface is not compiled in', () {
        expect(TestControlConfiguration.enabled, isFalse);
      });

      // Must refuse to switch on even when asked directly, and even if storage
      // carries a `true` from a previously installed instrumented build.
      test('cannot be switched on, and issues no token', () async {
        final controller = await TestControlController.load();

        expect(controller.isOn, isFalse);
        expect(controller.token, isNull);

        await controller.setForTesting(
          on: true,
          token: 'field-test-token-abcdefghij',
        );

        expect(
          controller.isOn,
          isFalse,
          reason: 'no switch or token may open the surface without the define',
        );
        expect(controller.token, isNull);
      });

      test('rejects every candidate token', () async {
        final controller = await TestControlController.load();

        expect(controller.authorize(null), isFalse);
        expect(controller.authorize(''), isFalse);
        expect(controller.authorize('any-token'), isFalse);
      });

      test('reports no expiry while off', () async {
        final controller = await TestControlController.load();
        expect(controller.expiresAt, isNull);
      });
    },
    // Skipped in a driven build, where the enabled-path suite asserts the
    // opposite. A named reason so a skipped run says why.
    skip: TestControlConfiguration.enabled
        ? 'asserts the define-off build; run without RIDE_RELAY_TEST_CONTROL'
        : null,
  );
}
