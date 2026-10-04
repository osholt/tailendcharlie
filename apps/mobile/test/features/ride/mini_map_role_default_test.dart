import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/app/ride_relay_app.dart';
import 'package:ride_relay/controllers/completed_rides_controller.dart';
import 'package:ride_relay/controllers/distance_unit_controller.dart';
import 'package:ride_relay/controllers/map_style_mode_controller.dart';
import 'package:ride_relay/controllers/mini_map_display_controller.dart';
import 'package:ride_relay/controllers/ride_code_preference_controller.dart';
import 'package:ride_relay/controllers/ride_controller.dart';
import 'package:ride_relay/controllers/rider_profile_controller.dart';
import 'package:ride_relay/controllers/shared_route_controller.dart';
import 'package:ride_relay/controllers/speed_limit_display_controller.dart';
import 'package:ride_relay/data/in_memory_event_store.dart';
import 'package:ride_relay/data/in_memory_session_store.dart';
import 'package:ride_relay/domain/completed_ride_store.dart';
import 'package:ride_relay/domain/recorded_route_store.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/features/map/ride_map.dart';
import 'package:ride_relay/services/nearby_bridge.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #850 through the real shell: the group mini-map a rider is shown follows
/// their role live, and their own choice outranks it.
///
/// Reads what the shell hands the map rather than looking for pixels, so it
/// asks the question the shell answers - "may the overview be drawn?" - without
/// depending on a group being on screen. Its own file for the reason the
/// navigation-escape test gives: a ride driven through the shell does not share
/// a process with the other shell tests.
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

  testWidgets('follows the rider\'s role live, and their choice outranks it', (
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
    final miniMap = MiniMapDisplayController.inMemory();
    addTearDown(miniMap.dispose);

    await tester.pumpWidget(_app(controller, distanceUnits, miniMap));
    for (
      var attempt = 0;
      attempt < 60 && find.byType(RideMapFeature).evaluate().isEmpty;
      attempt += 1
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    bool mayDrawOverview() => tester
        .widget<RideMapFeature>(find.byType(RideMapFeature))
        .showGroupMiniMap;

    // The simulated ride starts with the local rider leading it.
    expect(controller.session?.role, RideRole.lead);
    expect(mayDrawOverview(), isTrue, reason: 'the leader sees the overview');

    // Handed to a follower, the overview goes - nothing was restarted.
    await controller.setRole(RideRole.rider);
    await tester.pump();
    expect(mayDrawOverview(), isFalse, reason: 'a follower does not');

    await controller.setRole(RideRole.tailEndCharlie);
    await tester.pump();
    expect(mayDrawOverview(), isTrue, reason: 'the Tail End Charlie does');

    // A rider who chose to see it sees it as a follower...
    await controller.setRole(RideRole.rider);
    await miniMap.setVisible(true);
    await tester.pump();
    expect(mayDrawOverview(), isTrue, reason: 'a follower who chose to');

    // ...and one who chose not to does not see it as the leader.
    await controller.setRole(RideRole.lead);
    await miniMap.setVisible(false);
    await tester.pump();
    expect(mayDrawOverview(), isFalse, reason: 'a leader who chose not to');

    // Back to the default, and the role decides again.
    await miniMap.useRoleDefault();
    await tester.pump();
    expect(mayDrawOverview(), isTrue);
    await controller.setRole(RideRole.rider);
    await tester.pump();
    expect(mayDrawOverview(), isFalse);

    // An embedder that brings no setting keeps the behaviour it had: the overview
    // is drawn whenever there is a group, as a follower too.
    await tester.pumpWidget(_app(controller, distanceUnits, null));
    await tester.pump();
    expect(controller.session?.role, RideRole.rider);
    expect(mayDrawOverview(), isTrue);

    // Let the simulation's own quarter-second awareness refresh run out before the
    // tree goes, so nothing of it is still pending.
    await tester.pump(const Duration(seconds: 1));
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

RideRelayApp _app(
  RideController controller,
  DistanceUnitController distanceUnits,
  MiniMapDisplayController? miniMap,
) => RideRelayApp(
  controller: controller,
  distanceUnits: distanceUnits,
  mapStyleMode: _mapStyleMode,
  rideCodePreference: _rideCodePreference,
  riderProfile: _riderProfile,
  sharedRoutes: _sharedRoutes,
  speedLimitDisplay: _speedLimitDisplay,
  miniMapDisplay: miniMap,
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
