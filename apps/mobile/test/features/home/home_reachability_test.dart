import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
import 'package:ride_relay/domain/completed_ride.dart';
import 'package:ride_relay/domain/completed_ride_store.dart';
import 'package:ride_relay/domain/recorded_route_store.dart';
import 'package:ride_relay/domain/ride_session.dart';
import 'package:ride_relay/features/home/home_screen.dart';
import 'package:ride_relay/internet/internet_relay_client.dart';
import 'package:ride_relay/services/nearby_bridge.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Every way into the app, by the words a rider can read (#306).
///
/// "Features that exist but cannot be found are not delivered." QR joining
/// shipped in #279 and was then reported as missing, because its only
/// affordance was an unlabelled icon with a tooltip — and a tooltip does not
/// appear when you tap a phone. "Ride again" (#251) went the same way.
///
/// These assert the journeys #306 names by their **label**, not by a key or an
/// icon, so a consolidation that moves them has to keep them findable. They are
/// deliberately written before the reorganisation rather than after it: their
/// job is to be the safety net it lands into.
void main() {
  late InMemoryEventStore eventStore;
  late RideController rideController;
  late DistanceUnitController distanceUnits;
  late MapStyleModeController mapStyleMode;
  late RideCodePreferenceController rideCodePreference;
  late RiderProfileController riderProfile;
  late SharedRouteController sharedRoutes;
  late SpeedLimitDisplayController speedLimitDisplay;
  late CompletedRidesController completedRides;

  setUp(() async {
    SharedPreferences.setMockInitialValues(const {});
    eventStore = InMemoryEventStore();
    var id = 0;
    rideController = RideController(
      eventStore,
      InMemorySessionStore(),
      const _FakeNearbyBridge(),
      clock: () => DateTime.utc(2026, 8, 2, 9),
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
  });

  Future<void> pumpHome(WidgetTester tester) async {
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
          recordedRoutes: InMemoryRecordedRouteStore(),
          completedRides: completedRides,
          // The home map backdrop is live in production. Without this it would
          // wait forever here on a platform map and a location plugin that
          // never answer, and pumpAndSettle would time out.
          enableNativeServices: false,
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('starting a ride is offered in words on the first screen', (
    tester,
  ) async {
    await pumpHome(tester);

    expect(find.text('Create a ride'), findsOneWidget);
    expect(find.text('Join a ride'), findsOneWidget);
  });

  testWidgets('a past ride is offered in words on the first screen', (
    tester,
  ) async {
    await pumpHome(tester);

    expect(find.textContaining('Previous rides'), findsOneWidget);
  });

  testWidgets('joining by QR is offered in words, not only as an icon', (
    tester,
  ) async {
    // The specific failure #306 was raised over: this shipped in #279 and was
    // then concluded to be missing, because the only way to find it was an
    // unlabelled camera icon inside a text field's suffix.
    await pumpHome(tester);
    await tester.tap(find.text('Join a ride'));
    await tester.pumpAndSettle();

    expect(
      find.text('Scan an invitation code'),
      findsOneWidget,
      reason: 'a rider who has never seen the app has to be able to read it',
    );
  });

  testWidgets('the QR icon still works for riders who have learned it', (
    tester,
  ) async {
    // Adding the label must not have quietly replaced the compact affordance.
    await pumpHome(tester);
    await tester.tap(find.text('Join a ride'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('scan-invitation-button')), findsOneWidget);
    expect(
      find.byKey(const Key('scan-invitation-labelled-button')),
      findsOneWidget,
    );
  });
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
