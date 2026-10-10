import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/app/ride_relay_app.dart';
import 'package:ride_relay/controllers/app_update_gate_controller.dart';
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
import 'package:ride_relay/domain/ride_session.dart';
import 'package:ride_relay/internet/internet_relay_client.dart';
import 'package:ride_relay/services/nearby_bridge.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The home map and the join form under the update gate (#37), through the real
/// app shell.
void main() {
  late RiderProfileController riderProfile;
  late SharedRouteController sharedRoutes;
  late SpeedLimitDisplayController speedLimitDisplay;
  late MapStyleModeController mapStyleMode;
  late CompletedRidesController completedRides;
  final recordedRoutes = InMemoryRecordedRouteStore();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    riderProfile = await RiderProfileController.load();
    await riderProfile.completeOnboarding(
      displayName: 'Oliver',
      motorcycleStyle: riderProfile.motorcycleStyle,
      riderColor: riderProfile.riderColor,
      educationSkipped: false,
      rideChoice: OnboardingRideChoice.create,
    );
    riderProfile.takePendingRideChoice();
    sharedRoutes = await SharedRouteController.load();
    speedLimitDisplay = SpeedLimitDisplayController.inMemory();
    mapStyleMode = await MapStyleModeController.load();
    completedRides = await CompletedRidesController.load(
      InMemoryCompletedRideStore(),
    );
  });

  Future<RideController> newController({RideCodeDirectory? directory}) async {
    final controller = RideController(
      InMemoryEventStore(),
      InMemorySessionStore(),
      const _FakeNearbyBridge(),
      rideCodeDirectory: directory,
    );
    await controller.initialize();
    addTearDown(controller.dispose);
    return controller;
  }

  RideRelayApp app(
    RideController controller, {
    AppUpdateGateController? gate,
  }) => RideRelayApp(
    controller: controller,
    distanceUnits: DistanceUnitController.forLocale(const Locale('en', 'GB')),
    mapStyleMode: mapStyleMode,
    rideCodePreference: RideCodePreferenceController.memory(),
    riderProfile: riderProfile,
    sharedRoutes: sharedRoutes,
    speedLimitDisplay: speedLimitDisplay,
    recordedRoutes: recordedRoutes,
    completedRides: completedRides,
    updateGate: gate,
    enableNativeServices: false,
  );

  AppUpdateGateController refusedGate() {
    final gate = AppUpdateGateController(checkCompatibility: null)
      ..apply(
        RelayCompatibilityResult(
          disposition: RelayCompatibilityDisposition.updateRequired,
          serverProtocol: 1,
          minimumClientProtocol: 1,
          capabilities: const {},
          checkedAt: DateTime.utc(2026, 10, 9),
          validUntil: DateTime.utc(2026, 10, 9, 0, 5),
          message:
              'Build 98 is older than the oldest build the ride service '
              'supports (103).',
          minimumClientBuild: 103,
          clientBuild: 98,
        ),
      );
    addTearDown(gate.dispose);
    return gate;
  }

  testWidgets(
    'a build the relay has retired is told once, and the banner stays',
    (tester) async {
      final controller = await newController();
      final gate = refusedGate();

      await tester.pumpWidget(app(controller, gate: gate));
      await tester.pumpAndSettle();

      // The full explanation opened by itself...
      expect(find.byKey(const Key('update-required-screen')), findsOneWidget);
      expect(find.byKey(const Key('update-required-open')), findsOneWidget);
      expect(gate.presented, isTrue);

      // ...and the rider can simply carry on.
      await tester.scrollUntilVisible(
        find.byKey(const Key('update-required-continue')),
        200,
      );
      await tester.tap(find.byKey(const Key('update-required-continue')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('update-required-screen')), findsNothing);
      expect(find.byKey(const Key('update-required-banner')), findsOneWidget);
      // Nothing on the map was taken away: the ride actions are all still there.
      expect(find.byKey(const Key('home-join-ride')), findsOneWidget);
      expect(find.byKey(const Key('home-more-actions')), findsOneWidget);

      // It is not offered again by a rebuild.
      gate.apply(
        RelayCompatibilityResult(
          disposition: RelayCompatibilityDisposition.updateRequired,
          serverProtocol: 1,
          minimumClientProtocol: 1,
          capabilities: const {},
          checkedAt: DateTime.utc(2026, 10, 9),
          validUntil: DateTime.utc(2026, 10, 9, 0, 5),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('update-required-screen')), findsNothing);
      expect(find.byKey(const Key('update-required-banner')), findsOneWidget);
    },
  );

  testWidgets(
    'a build the relay accepts sees neither the screen nor the banner',
    (tester) async {
      final controller = await newController();
      final gate = AppUpdateGateController(checkCompatibility: null)
        ..apply(
          RelayCompatibilityResult(
            disposition: RelayCompatibilityDisposition.compatible,
            serverProtocol: 1,
            minimumClientProtocol: 1,
            capabilities: const {},
            checkedAt: DateTime.utc(2026, 10, 9),
            validUntil: DateTime.utc(2026, 10, 9, 0, 5),
          ),
        );
      addTearDown(gate.dispose);

      await tester.pumpWidget(app(controller, gate: gate));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('update-required-screen')), findsNothing);
      expect(find.byKey(const Key('update-required-banner')), findsNothing);
    },
  );

  testWidgets('with no gate at all the map is unchanged', (tester) async {
    final controller = await newController();

    await tester.pumpWidget(app(controller));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('update-required-screen')), findsNothing);
    expect(find.byKey(const Key('update-required-banner')), findsNothing);
  });

  testWidgets(
    'joining with a retired build offers the update, not a bare sentence',
    (tester) async {
      final controller = await newController(
        directory: _RetiredBuildDirectory(),
      );

      await tester.pumpWidget(app(controller));
      await tester.tap(find.byKey(const Key('home-join-ride')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('rider-name-field')),
        'Oliver',
      );
      await tester.enterText(
        find.byKey(const Key('ride-code-field')),
        '994954',
      );
      final joinButton = find.widgetWithText(FilledButton, 'Join ride');
      await tester.scrollUntilVisible(
        joinButton,
        180,
        scrollable: find
            .descendant(
              of: find.byKey(const Key('ride-form-scroll-view')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(joinButton);
      await tester.pumpAndSettle();

      expect(controller.hasActiveRide, isFalse);
      expect(controller.errorNeedsUpdate, isTrue);
      // Retrying cannot help, so no retry is offered.
      expect(find.byKey(const Key('retry-ride-submit')), findsNothing);

      await tester.scrollUntilVisible(
        find.byKey(const Key('join-update-required')),
        180,
        scrollable: find
            .descendant(
              of: find.byKey(const Key('ride-form-scroll-view')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(find.byKey(const Key('join-update-required')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('update-required-screen')), findsOneWidget);
      expect(find.textContaining('Build 98'), findsWidgets);
    },
  );
}

class _RetiredBuildDirectory implements RideCodeDirectory {
  @override
  void close() {}

  @override
  Future<void> register(RideSession session) async {}

  @override
  Future<RideCodeCredentials> resolve(
    String rideCode, {
    String? joinToken,
  }) async => throw const RideCodeDirectoryException(
    'Build 98 is older than the oldest build the ride service supports (103). '
    'Update Tail End Charlie to join or synchronize rides.',
    updateRequired: true,
  );
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
