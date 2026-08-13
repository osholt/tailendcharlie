import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/app/ride_relay_app.dart';
import 'package:ride_relay/controllers/completed_rides_controller.dart';
import 'package:ride_relay/controllers/distance_unit_controller.dart';
import 'package:ride_relay/controllers/map_style_mode_controller.dart';
import 'package:ride_relay/controllers/ride_code_preference_controller.dart';
import 'package:ride_relay/controllers/ride_controller.dart';
import 'package:ride_relay/controllers/rider_profile_controller.dart';
import 'package:ride_relay/controllers/shared_route_controller.dart';
import 'package:ride_relay/controllers/speed_limit_display_controller.dart';
import 'package:ride_relay/data/in_memory_event_store.dart';
import 'package:ride_relay/data/in_memory_session_store.dart';
import 'package:ride_relay/domain/completed_ride_store.dart';
import 'package:ride_relay/domain/recorded_route_store.dart';
import 'package:ride_relay/services/nearby_bridge.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Its own file on purpose.
///
/// The state this exercises is reached by running a whole simulated ride, and
/// it did not survive sharing a file with the other shell tests: the ride
/// refused to start at all once earlier tests had run against the same
/// process-wide controllers. A separate file is a separate isolate, so the
/// ride this drives is the only ride there has ever been.
void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    _riderProfile = await RiderProfileController.load();
    await _riderProfile.completeOnboarding(
      displayName: 'Oliver',
      motorcycleStyle: _riderProfile.motorcycleStyle,
      riderColor: _riderProfile.riderColor,
      educationSkipped: false,
      rideChoice: OnboardingRideChoice.create,
    );
    _riderProfile.takePendingRideChoice();
    _sharedRoutes = await SharedRouteController.load();
    _speedLimitDisplay = SpeedLimitDisplayController.inMemory();
    _mapStyleMode = await MapStyleModeController.load();
    _rideCodePreference = RideCodePreferenceController.memory();
    _completedRides = await CompletedRidesController.load(
      InMemoryCompletedRideStore(),
    );
  });

  testWidgets('a moving rider can still reach the other tabs (#404)', (
    tester,
  ) async {
    // The defect: once a ride is under way on the map tab with a route and a
    // navigation fix, `hideWhileMoving` removes the whole navigation bar. Its
    // condition includes `_selectedIndex == 0`, so hiding the only control that
    // could change the index kept it hidden for the rest of the ride — Ride and
    // Settings were gone until the ride ended.
    //
    // It needs a *moving* ride with a route to appear, which is why a
    // stationary phone never showed it. That is the #133 pattern again.
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = await _controller();
    await controller.createSimulationRide();
    addTearDown(controller.dispose);

    await tester.pumpWidget(_app(controller));
    Future<void> pumpUntil(bool Function() satisfied) async {
      for (var attempt = 0; attempt < 60 && !satisfied(); attempt += 1) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    // Same opening as the simulation test above: the lab tab has to reach
    // READY before the ride can be started.
    await pumpUntil(
      () => find.byIcon(Icons.science_outlined).evaluate().isNotEmpty,
    );
    await tester.tap(find.byIcon(Icons.science_outlined));
    await pumpUntil(() => find.text('READY').evaluate().isNotEmpty);
    await tester.tap(find.byKey(const Key('start-ride-button')));
    // Which dialogs the start puts up depends on whether the bundled demo
    // route has finished loading and whether anyone holds TEC, and that varies
    // with what ran before this test. Answer whichever appears rather than
    // assuming an order.
    const startButtons = [
      'start-without-route-button',
      'start-without-tec-button',
      'confirm-start-ride-button',
    ];
    for (var attempt = 0; attempt < 40 && !controller.rideStarted; attempt++) {
      var tapped = false;
      for (final key in startButtons) {
        final button = find.byKey(Key(key));
        if (button.evaluate().isNotEmpty) {
          await tester.tap(button);
          tapped = true;
          break;
        }
      }
      await tester.pump(
        tapped ? Duration.zero : const Duration(milliseconds: 100),
      );
    }
    expect(controller.rideStarted, isTrue);
    // The bikes have to be moving, not merely started: the navigation fix that
    // hides the bar comes from a simulated position.
    await pumpUntil(() => find.text('RUNNING').evaluate().isNotEmpty);
    expect(find.text('RUNNING'), findsOneWidget);

    // Back to the map, which is where a rider actually rides.
    await tester.tap(find.text('Map').last);
    await tester.pump();

    // Ride until the shell decides the rider is navigating and takes the bar
    // away. That state is the whole point of the test: if it never arrives,
    // the test is not exercising the defect and must say so rather than pass.
    await pumpUntil(() => find.byType(NavigationBar).evaluate().isEmpty);
    expect(
      find.byType(NavigationBar),
      findsNothing,
      reason: 'the moving-map state this regression is about was never reached',
    );

    // Pre-fix this found nothing: ActiveRideShell never passed
    // `onOpenRideMenu`, so the corner button existed only where a test supplied
    // it and the rider had no way off the map at all.
    final rideMenu = find.byKey(const Key('ride-menu-button'));
    expect(rideMenu, findsOneWidget);

    // Bounded pumps, not pumpAndSettle: a running simulation never settles.
    await tester.tap(rideMenu);
    await pumpUntil(
      () => find
          .byKey(const Key('ride-menu-destination-2'))
          .evaluate()
          .isNotEmpty,
    );
    // The tile exists as soon as the sheet starts sliding up; tapping then
    // lands on the barrier instead. Let it finish arriving.
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Ride'), findsWidgets);
    expect(find.text('Settings'), findsWidgets);

    // Leaving the map puts the rider's navigation back, because the condition
    // that hid it required the map tab.
    await tester.tap(find.byKey(const Key('ride-menu-destination-2')));
    await pumpUntil(() => find.byType(NavigationBar).evaluate().isNotEmpty);
    expect(find.byType(NavigationBar), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}

late RiderProfileController _riderProfile;
late SharedRouteController _sharedRoutes;
late SpeedLimitDisplayController _speedLimitDisplay;
late MapStyleModeController _mapStyleMode;
late RideCodePreferenceController _rideCodePreference;
late CompletedRidesController _completedRides;
final _recordedRoutes = InMemoryRecordedRouteStore();

RideRelayApp _app(RideController controller) => RideRelayApp(
  controller: controller,
  distanceUnits: DistanceUnitController.forLocale(const Locale('en', 'GB')),
  mapStyleMode: _mapStyleMode,
  rideCodePreference: _rideCodePreference,
  riderProfile: _riderProfile,
  sharedRoutes: _sharedRoutes,
  speedLimitDisplay: _speedLimitDisplay,
  recordedRoutes: _recordedRoutes,
  completedRides: _completedRides,
  enableNativeServices: false,
);

Future<RideController> _controller() async {
  final controller = RideController(
    InMemoryEventStore(),
    InMemorySessionStore(),
    const _FakeNearbyBridge(),
  );
  await controller.initialize();
  return controller;
}

class _FakeNearbyBridge extends NearbyBridge {
  const _FakeNearbyBridge();

  @override
  Future<NearbyCapabilities> capabilities() async => const NearbyCapabilities(
    platform: 'test',
    nativeBridgeReady: true,
    nearbyApiLinked: false,
    status: 'phase0',
  );
}
