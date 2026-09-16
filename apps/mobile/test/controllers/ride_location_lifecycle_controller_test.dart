import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/ride_location_lifecycle_controller.dart';

void main() {
  test('waiting map gets one fix without starting ride-grade GPS', () async {
    final calls = _LocationCalls();
    final controller = calls.controller();

    await controller.prepareWaitingRideMap();

    expect(calls.refreshes, 1);
    expect(calls.stops, 0);
    expect(calls.restarts, 0);
  });

  test(
    'prepared ride stops foreground following for a background trip',
    () async {
      final calls = _LocationCalls();
      final controller = calls.controller();

      await controller.transition(
        AppLifecycleState.inactive,
        rideStarted: false,
        rideEnded: false,
      );
      await controller.transition(
        AppLifecycleState.hidden,
        rideStarted: false,
        rideEnded: false,
      );
      await controller.transition(
        AppLifecycleState.paused,
        rideStarted: false,
        rideEnded: false,
      );
      await controller.transition(
        AppLifecycleState.resumed,
        rideStarted: false,
        rideEnded: false,
      );

      expect(calls.stops, 1);
      expect(calls.refreshes, 1);
      expect(calls.restarts, 0);
    },
  );

  test('started ride keeps background GPS and restarts it on resume', () async {
    final calls = _LocationCalls();
    final controller = calls.controller();

    await controller.transition(
      AppLifecycleState.paused,
      rideStarted: true,
      rideEnded: false,
    );
    expect(calls.stops, 0);

    await controller.transition(
      AppLifecycleState.resumed,
      rideStarted: true,
      rideEnded: false,
    );

    expect(calls.restarts, 1);
    expect(calls.refreshes, 0);
  });

  test('ended ride never reacquires a location on resume', () async {
    final calls = _LocationCalls();
    final controller = calls.controller();

    await controller.transition(
      AppLifecycleState.inactive,
      rideStarted: true,
      rideEnded: true,
    );
    await controller.transition(
      AppLifecycleState.resumed,
      rideStarted: true,
      rideEnded: true,
    );

    expect(calls.stops, 1);
    expect(calls.refreshes, 0);
    expect(calls.restarts, 0);
  });

  test('spurious resumed state does not start any location work', () async {
    final calls = _LocationCalls();
    final controller = calls.controller();

    await controller.transition(
      AppLifecycleState.resumed,
      rideStarted: false,
      rideEnded: false,
    );

    expect(calls.stops, 0);
    expect(calls.refreshes, 0);
    expect(calls.restarts, 0);
  });
}

class _LocationCalls {
  int stops = 0;
  int refreshes = 0;
  int restarts = 0;

  RideLocationLifecycleController controller() =>
      RideLocationLifecycleController(
        () async => stops += 1,
        () async => refreshes += 1,
        () async => restarts += 1,
      );
}
