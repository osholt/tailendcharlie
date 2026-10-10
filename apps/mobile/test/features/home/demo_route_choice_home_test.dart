import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
import 'package:ride_relay/domain/completed_ride.dart';
import 'package:ride_relay/domain/completed_ride_store.dart';
import 'package:ride_relay/domain/recorded_route_store.dart';
import 'package:ride_relay/domain/ride_session.dart';
import 'package:ride_relay/features/home/home_screen.dart';
import 'package:ride_relay/internet/internet_relay_client.dart';
import 'package:ride_relay/services/demo_route_loader.dart';
import 'package:ride_relay/services/nearby_bridge.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// **"Try a simulated ride" asks which demo route to ride (#934).**
///
/// The demo used to be one French route. The home menu now offers the bundled
/// routes, remembers the pick, and starts nothing if the sheet is dismissed.
void main() {
  late RideController rideController;
  late DistanceUnitController distanceUnits;
  late MapStyleModeController mapStyleMode;
  late RideCodePreferenceController rideCodePreference;
  late RiderProfileController riderProfile;
  late SharedRouteController sharedRoutes;
  late SpeedLimitDisplayController speedLimitDisplay;
  late CompletedRidesController completedRides;
  late DemoRouteChoiceController choice;

  setUp(() async {
    SharedPreferences.setMockInitialValues(const {});
    var id = 0;
    rideController = RideController(
      InMemoryEventStore(),
      InMemorySessionStore(),
      const _FakeNearbyBridge(),
      clock: () => DateTime.utc(2026, 10, 10, 9),
      idFactory: () => 'id-${id++}',
      random: Random(7),
      rideCodeDirectory: _NullRideCodeDirectory(),
    );
    await rideController.initialize();
    distanceUnits = DistanceUnitController.forLocale(const Locale('en', 'GB'));
    mapStyleMode = await MapStyleModeController.load();
    rideCodePreference = await RideCodePreferenceController.load();
    riderProfile = await RiderProfileController.load();
    sharedRoutes = await SharedRouteController.load(planDirectory: null);
    speedLimitDisplay = SpeedLimitDisplayController.inMemory();
    completedRides = await CompletedRidesController.load(
      _EmptyCompletedRideStore(),
    );
    choice = DemoRouteChoiceController.inMemory(DemoRoutes.cotswolds);
  });

  tearDown(() {
    rideController.dispose();
    distanceUnits.dispose();
    mapStyleMode.dispose();
    rideCodePreference.dispose();
    riderProfile.dispose();
    sharedRoutes.dispose();
    speedLimitDisplay.dispose();
    completedRides.dispose();
    choice.dispose();
  });

  Future<void> openSimulatorMenu(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: HomeScreen(
          controller: rideController,
          distanceUnits: distanceUnits,
          mapStyleMode: mapStyleMode,
          rideCodePreference: rideCodePreference,
          riderProfile: riderProfile,
          sharedRoutes: sharedRoutes,
          speedLimitDisplay: speedLimitDisplay,
          demoRouteChoice: choice,
          recordedRoutes: InMemoryRecordedRouteStore(),
          completedRides: completedRides,
          enableNativeServices: false,
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('home-more-actions')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Try a simulated ride'));
    await tester.pumpAndSettle();
  }

  testWidgets('the simulator asks first, and starts on the route picked', (
    tester,
  ) async {
    await openSimulatorMenu(tester);

    expect(find.text('Choose a demo route'), findsOneWidget);
    expect(
      rideController.session,
      isNull,
      reason: 'nothing starts until a route is picked',
    );

    await tester.tap(find.byKey(Key('demo-route-${DemoRoutes.france.id}')));
    await tester.pumpAndSettle();

    expect(rideController.session?.isSimulation, isTrue);
    expect(choice.current, same(DemoRoutes.france));
  });

  testWidgets(
    'dismissing the sheet starts no simulation and keeps the choice',
    (tester) async {
      await openSimulatorMenu(tester);

      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      expect(rideController.session, isNull);
      expect(choice.current, same(DemoRoutes.cotswolds));
    },
  );
}

class _FakeNearbyBridge extends NearbyBridge {
  const _FakeNearbyBridge();

  @override
  Future<NearbyCapabilities> capabilities() async =>
      const NearbyCapabilities.unavailable();
}

class _NullRideCodeDirectory implements RideCodeDirectory {
  @override
  Future<void> register(RideSession session) async {}

  @override
  Future<RideCodeCredentials> resolve(
    String rideCode, {
    String? joinToken,
  }) async => throw const RideCodeDirectoryException('Not used in this test.');

  @override
  void close() {}
}

class _EmptyCompletedRideStore implements CompletedRideStore {
  @override
  Future<List<CompletedRide>> list() async => const [];

  @override
  Future<void> save(CompletedRide ride) async {}

  @override
  Future<void> delete(String rideId) async {}
}
