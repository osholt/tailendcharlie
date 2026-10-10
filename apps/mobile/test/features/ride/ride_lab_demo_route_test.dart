import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/app/ride_relay_app.dart';
import 'package:ride_relay/controllers/completed_rides_controller.dart';
import 'package:ride_relay/controllers/demo_route_choice_controller.dart';
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
import 'package:ride_relay/features/map/ride_map.dart';
import 'package:ride_relay/services/demo_route_loader.dart';
import 'package:ride_relay/services/nearby_bridge.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// **Ride Lab rides the demo route the rider chose, and offers another (#934).**
///
/// The simulation used to load one French route whatever the rider wanted. It
/// now loads the remembered choice, shows which route that is on the Ride Lab
/// tab, and starts a clean simulation on a different one when asked.
///
/// One test, in its own file: a second simulation in one file never reaches its
/// map (see `active_ride_navigation_escape_test.dart`).
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

  testWidgets('a simulation loads the chosen route and can switch to another', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = await _controller();
    await controller.createSimulationRide();
    addTearDown(controller.dispose);
    final distanceUnits = DistanceUnitController.forLocale(
      const Locale('en', 'GB'),
    );
    addTearDown(distanceUnits.dispose);
    final choice = DemoRouteChoiceController.inMemory(DemoRoutes.cotswolds);
    addTearDown(choice.dispose);

    await tester.pumpWidget(_app(controller, distanceUnits, choice));
    await _pumpUntil(
      tester,
      () => find.byType(RideMapFeature).evaluate().isNotEmpty,
    );
    // What the map was actually handed, not what a label says.
    expect(await _loadedRouteName(tester), DemoRoutes.cotswolds.title);

    // The Ride Lab tab says which route this is and offers another.
    await tester.tap(find.byIcon(Icons.science_outlined));
    await _pumpUntil(
      tester,
      () =>
          find.byKey(const Key('simulation-demo-route')).evaluate().isNotEmpty,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('simulation-demo-route')),
        matching: find.text(DemoRoutes.cotswolds.title),
      ),
      findsOneWidget,
    );
    final firstRideId = controller.session!.rideId;

    await tester.tap(find.byKey(const Key('simulation-demo-route')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('demo-route-${DemoRoutes.france.id}')));
    await _pumpUntil(
      tester,
      () => find.byType(RideMapFeature).evaluate().isNotEmpty,
    );

    // A clean simulation on the other route, and the pick is remembered.
    expect(controller.session!.rideId, isNot(firstRideId));
    expect(controller.session!.isSimulation, isTrue);
    expect(choice.current, same(DemoRoutes.france));
    expect(await _loadedRouteName(tester), DemoRoutes.france.title);

    await _tearDown(tester);
  });
}

/// The name of the route the live map's store holds.
Future<String?> _loadedRouteName(WidgetTester tester) async {
  final map = tester.widget<RideMapFeature>(find.byType(RideMapFeature));
  final route = await tester.runAsync(() => map.routeStore!.loadActiveRoute());
  return route?.name;
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() satisfied) async {
  for (var attempt = 0; attempt < 150 && !satisfied(); attempt += 1) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// A simulation never settles on its own: let the ride it was still setting up
/// finish and its timers fire before the test's invariants are checked.
Future<void> _tearDown(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 200)),
  );
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
}

late RiderProfileController _riderProfile;
late SharedRouteController _sharedRoutes;
late SpeedLimitDisplayController _speedLimitDisplay;
late MapStyleModeController _mapStyleMode;
late RideCodePreferenceController _rideCodePreference;
late CompletedRidesController _completedRides;
final _recordedRoutes = InMemoryRecordedRouteStore();

RideRelayApp _app(
  RideController controller,
  DistanceUnitController distanceUnits,
  DemoRouteChoiceController choice,
) => RideRelayApp(
  controller: controller,
  distanceUnits: distanceUnits,
  mapStyleMode: _mapStyleMode,
  rideCodePreference: _rideCodePreference,
  riderProfile: _riderProfile,
  sharedRoutes: _sharedRoutes,
  speedLimitDisplay: _speedLimitDisplay,
  recordedRoutes: _recordedRoutes,
  completedRides: _completedRides,
  demoRouteChoice: choice,
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
