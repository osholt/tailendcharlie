import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/ride_controller.dart';
import 'package:ride_relay/controllers/test_control_controller.dart';
import 'package:ride_relay/data/in_memory_event_store.dart';
import 'package:ride_relay/data/in_memory_session_store.dart';
import 'package:ride_relay/domain/completed_ride_store.dart';
import 'package:ride_relay/services/nearby_bridge.dart';
import 'package:ride_relay/services/test_control_registry.dart';
import 'package:ride_relay/services/test_control_server.dart';
import 'package:ride_relay/services/ride_screen_awake.dart';
import 'package:ride_relay/services/test_control_configuration.dart';
import 'package:ride_relay/services/test_control_session.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Regression cover for the two things that made a two-phone run impossible to
/// coordinate by hand. Both were found by attempting one, not by reasoning.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final withoutDefine = TestControlConfiguration.enabled
      ? null
      : 'needs --dart-define=RIDE_RELAY_TEST_CONTROL=true';

  group('idle clock', () {
    late TestControlController control;
    late DateTime now;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      now = DateTime.utc(2026, 7, 31, 12);
      control = await TestControlController.load(now: () => now);
    });

    test(
      'an authenticated request is refused once the idle window has passed',
      () async {
        await control.setForTesting(
          on: true,
          token: 'field-test-token-abcdefghij',
        );
        final token = control.token;

        now = now.add(TestControlConfiguration.defaultIdleTimeout * 2);

        expect(
          control.authorize(token),
          isFalse,
          reason: 'an abandoned session stops serving',
        );
        // Deliberately still "on": the switch belongs to whoever set it in iOS
        // Settings, and silently rewriting someone's preference to express an
        // internal timeout would leave them looking at a switch that had moved
        // by itself. Refusing to serve is the honest expression of the timeout.
        expect(control.switchRequested, isTrue);
      },
      skip: withoutDefine,
    );

    test(
      'touch restarts the clock, so suspended time is not counted',
      () async {
        // The failure this fixes: the operator turns the switch on, leaves the
        // app to copy the token - which suspends it on iOS - and by the time the
        // second phone is ready more than the idle window has passed. The first
        // real request then switched the surface off, silently. Time the app
        // could not have served must not count against it.
        await control.setForTesting(
          on: true,
          token: 'field-test-token-abcdefghij',
        );
        final token = control.token;

        now = now.add(TestControlConfiguration.defaultIdleTimeout * 2);
        control.touch(); // what a foreground resume does

        expect(
          control.authorize(token),
          isTrue,
          reason: 'resuming must make the session usable again',
        );
        expect(control.isOn, isTrue);
      },
      skip: withoutDefine,
    );

    test('a switch and token set outside the app are picked up', () async {
      // Neither value is written by this app - both live in the iOS Settings
      // bundle - so the only thing that makes the feature work is reading them
      // back. This is that path.
      SharedPreferences.setMockInitialValues({
        TestControlController.preferenceKey: true,
        TestControlController.tokenPreferenceKey: 'field-test-token-abcdefghij',
      });
      final fresh = await TestControlController.load(now: () => now);

      expect(fresh.isOn, isTrue);
      expect(fresh.token, 'field-test-token-abcdefghij');
      expect(fresh.needsToken, isFalse);
    }, skip: withoutDefine);

    test('the switch alone serves nothing without a token', () async {
      // The invariant that makes a person-chosen secret safe to allow: a switch
      // with no token is not "half on". It binds no port and authorises nothing.
      SharedPreferences.setMockInitialValues({
        TestControlController.preferenceKey: true,
      });
      final fresh = await TestControlController.load(now: () => now);

      expect(fresh.switchRequested, isTrue);
      expect(fresh.isOn, isFalse);
      expect(fresh.needsToken, isTrue);
      expect(fresh.authorize('anything'), isFalse);
    }, skip: withoutDefine);

    test('clearing the switch outside the app stops serving', () async {
      SharedPreferences.setMockInitialValues({
        TestControlController.preferenceKey: false,
        TestControlController.tokenPreferenceKey: 'field-test-token-abcdefghij',
      });
      final fresh = await TestControlController.load(now: () => now);

      expect(fresh.isOn, isFalse);
      expect(fresh.authorize('field-test-token-abcdefghij'), isFalse);
    }, skip: withoutDefine);

    test('touch does nothing while the switch is off', () async {
      expect(control.isOn, isFalse);
      control.touch();
      expect(control.expiresAt, isNull);
    });
  });

  group('screen wake lock', () {
    test(
      'held while the switch is on, released when it goes off',
      () async {
        SharedPreferences.setMockInitialValues({});
        final wakeLock = _RecordingWakeLock();
        final control = await TestControlController.load();
        final ride = RideController(
          InMemoryEventStore(),
          InMemorySessionStore(),
          const _FakeNearbyBridge(),
          completedRideStore: InMemoryCompletedRideStore(),
        );
        addTearDown(ride.dispose);
        final session = TestControlSession(
          control,
          TestControlServer(
            control,
            ride,
            TestControlRegistry(),
            // Its own port so this cannot collide with a driven build.
            configuration: const TestControlConfiguration(port: 8481),
          ),
          screenAwake: RideScreenAwakeCoordinator(wakeLock: wakeLock),
        )..start();
        addTearDown(session.stop);

        await control.setForTesting(
          on: true,
          token: 'field-test-token-abcdefghij',
        );
        await wakeLock.settled;
        expect(
          wakeLock.states.last,
          isTrue,
          reason: 'a build handed to another machine must not sleep',
        );

        await control.setForTesting(on: false);
        await wakeLock.settled;
        expect(wakeLock.states.last, isFalse);
      },
      skip: withoutDefine,
    );
  });
}

class _RecordingWakeLock implements ScreenWakeLock {
  final states = <bool>[];
  Future<void> settled = Future<void>.value();

  @override
  Future<void> setEnabled(bool enabled) {
    states.add(enabled);
    return settled = Future<void>.value();
  }
}

class _FakeNearbyBridge implements NearbyBridge {
  const _FakeNearbyBridge();

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
