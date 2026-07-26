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
import 'package:ride_relay/domain/ride_event.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/services/nearby_bridge.dart';
import 'package:ride_relay/services/ride_event_authenticator.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Starting a ride with no Tail End Charlie silently removes the safety role
/// the app is named after, so the leader is warned before the ride starts
/// rather than after.
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
    _completedRides = await CompletedRidesController.load(
      InMemoryCompletedRideStore(),
    );
  });

  testWidgets('a ride with no TEC warns before it starts and names the loss', (
    tester,
  ) async {
    final harness = await _harness();
    addTearDown(harness.dispose);
    await harness.controller.createRide('Oliver');

    await tester.pumpWidget(harness.app);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('start-ride-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('start-without-route-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('no-tec-warning')), findsOneWidget);
    expect(find.text('No Tail End Charlie'), findsOneWidget);
    expect(find.textContaining('no back-marker'), findsOneWidget);
    expect(find.textContaining('no distance to the back'), findsOneWidget);
    expect(find.textContaining('falls a long way behind'), findsOneWidget);
    // The warning must not have started the ride behind the leader's back.
    expect(harness.controller.rideStarted, isFalse);

    // Proceeding is a single deliberate action, not a block.
    await tester.tap(find.byKey(const Key('start-without-tec-button')));
    await tester.pumpAndSettle();

    expect(harness.controller.rideStarted, isTrue);
    expect(find.byKey(const Key('no-tec-warning')), findsNothing);
  });

  testWidgets('the warning is shown once per ride start, not during the ride', (
    tester,
  ) async {
    final harness = await _harness();
    addTearDown(harness.dispose);
    await harness.controller.createRide('Oliver');

    await tester.pumpWidget(harness.app);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('start-ride-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('start-without-route-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('start-without-tec-button')));
    await tester.pumpAndSettle();

    expect(harness.controller.rideStarted, isTrue);

    // The ride is running with no TEC. Nothing may re-open the warning while
    // it runs: it lives in the start confirmation only.
    for (var frame = 0; frame < 5; frame += 1) {
      await tester.pump(const Duration(seconds: 3));
      expect(find.byKey(const Key('no-tec-warning')), findsNothing);
    }
    harness.controller.refreshMembershipFreshness();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('no-tec-warning')), findsNothing);
  });

  testWidgets('a registered TEC starts the ride with no warning at all', (
    tester,
  ) async {
    final harness = await _harness();
    addTearDown(harness.dispose);
    await harness.controller.createRide('Oliver');
    // A TEC who has joined but never reported a position still counts: the
    // check reads the reconciled membership model, not a location snapshot.
    await harness.joinRemoteRider(
      riderId: 'charlie',
      displayName: 'Charlie',
      role: RideRole.tailEndCharlie,
    );

    await tester.pumpWidget(harness.app);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('start-ride-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('start-without-route-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('no-tec-warning')), findsNothing);
    expect(harness.controller.rideStarted, isTrue);
  });

  testWidgets('a rider who is not the TEC does not satisfy the warning', (
    tester,
  ) async {
    final harness = await _harness();
    addTearDown(harness.dispose);
    await harness.controller.createRide('Oliver');
    await harness.joinRemoteRider(
      riderId: 'alex',
      displayName: 'Alex',
      role: RideRole.rider,
    );

    await tester.pumpWidget(harness.app);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('start-ride-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('start-without-route-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('no-tec-warning')), findsOneWidget);
    expect(harness.controller.rideStarted, isFalse);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(harness.controller.rideStarted, isFalse);
    expect(find.text('Waiting to start'), findsOneWidget);
  });

  testWidgets('the warning offers the roster as the role-assignment route', (
    tester,
  ) async {
    final harness = await _harness();
    addTearDown(harness.dispose);
    await harness.controller.createRide('Oliver');
    await harness.joinRemoteRider(
      riderId: 'alex',
      displayName: 'Alex',
      role: RideRole.rider,
    );

    await tester.pumpWidget(harness.app);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('start-ride-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('start-without-route-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('assign-tec-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('ride-roster-list')), findsOneWidget);
    expect(find.byKey(const Key('roster-missing-tec-notice')), findsOneWidget);
    expect(find.textContaining('set their role to'), findsOneWidget);
    // Choosing to fix the gap does not start the ride.
    expect(harness.controller.rideStarted, isFalse);
  });

  testWidgets('the roster drops the missing-TEC notice once a TEC exists', (
    tester,
  ) async {
    final harness = await _harness();
    addTearDown(harness.dispose);
    await harness.controller.createRide('Oliver');
    await harness.joinRemoteRider(
      riderId: 'charlie',
      displayName: 'Charlie',
      role: RideRole.tailEndCharlie,
    );

    await tester.pumpWidget(harness.app);
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.tune_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('riders'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('ride-roster-list')), findsOneWidget);
    expect(find.byKey(const Key('roster-missing-tec-notice')), findsNothing);
    expect(find.byKey(const Key('roster-rider-charlie')), findsOneWidget);
  });
}

late RiderProfileController _riderProfile;
late SharedRouteController _sharedRoutes;
late SpeedLimitDisplayController _speedLimitDisplay;
late MapStyleModeController _mapStyleMode;
late CompletedRidesController _completedRides;

Future<_Harness> _harness() async {
  final eventStore = InMemoryEventStore();
  final controller = RideController(
    eventStore,
    InMemorySessionStore(),
    const _FakeNearbyBridge(),
  );
  await controller.initialize();
  return _Harness(controller, eventStore);
}

class _Harness {
  _Harness(this.controller, this.eventStore);

  final RideController controller;
  final InMemoryEventStore eventStore;

  RideRelayApp get app => RideRelayApp(
    controller: controller,
    distanceUnits: DistanceUnitController.forLocale(const Locale('en', 'GB')),
    mapStyleMode: _mapStyleMode,
    rideCodePreference: RideCodePreferenceController.memory(),
    riderProfile: _riderProfile,
    sharedRoutes: _sharedRoutes,
    speedLimitDisplay: _speedLimitDisplay,
    recordedRoutes: InMemoryRecordedRouteStore(),
    completedRides: _completedRides,
    enableNativeServices: false,
  );

  /// Appends the signed join another device would have relayed, so the
  /// membership reducer resolves the same roster the leader's phone would.
  Future<void> joinRemoteRider({
    required String riderId,
    required String displayName,
    required RideRole role,
  }) async {
    final session = controller.session!;
    final unsigned = RideEvent(
      id: 'join-$riderId',
      rideId: session.rideId,
      deviceId: riderId,
      type: RideEventType.riderJoined,
      priority: EventPriority.important,
      createdAt: DateTime.now(),
      payload: {'displayName': displayName, 'role': role.name},
      signature: '',
    );
    await eventStore.append(
      RideEvent(
        id: unsigned.id,
        rideId: unsigned.rideId,
        deviceId: unsigned.deviceId,
        type: unsigned.type,
        priority: unsigned.priority,
        createdAt: unsigned.createdAt,
        payload: unsigned.payload,
        signature: RideEventAuthenticator.sign(unsigned, session.inviteSecret),
      ),
    );
    await controller.reloadEvents();
  }

  void dispose() => controller.dispose();
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
