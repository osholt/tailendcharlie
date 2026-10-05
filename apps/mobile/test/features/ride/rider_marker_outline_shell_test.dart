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
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/rider_marker_outline.dart';
import 'package:ride_relay/features/map/ride_map.dart';
import 'package:ride_relay/services/nearby_bridge.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Its own file on purpose, like the other tests that run a whole simulated
/// ride: the state they reach does not survive sharing a process with the other
/// shell tests.
///
/// #845: the leader and the Tail End Charlie are stars on the map. This is the
/// shell's half of that - which markers it asks the map to draw as stars, and
/// that it asks again when a role changes - against Ride Lab's virtual group,
/// whose roster has a leader (this phone), a Tail End Charlie and riders between.
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

  testWidgets('the shell draws the leader and the Tail End Charlie as stars '
      'and changes this phone\'s marker when its role changes (#845)', (
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

    await tester.pumpWidget(_app(controller, distanceUnits));
    Future<void> pumpUntil(bool Function() satisfied) async {
      for (var attempt = 0; attempt < 60 && !satisfied(); attempt += 1) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    await pumpUntil(
      () => find.byIcon(Icons.science_outlined).evaluate().isNotEmpty,
    );
    await tester.tap(find.byIcon(Icons.science_outlined));
    await pumpUntil(() => find.text('READY').evaluate().isNotEmpty);
    await tester.tap(find.byKey(const Key('start-ride-button')));
    // Which dialogs the start puts up depends on what ran before; answer
    // whichever appears.
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
    await pumpUntil(() => find.text('RUNNING').evaluate().isNotEmpty);
    await tester.tap(find.text('Map').last);
    await tester.pump();

    RideMapFeature map() =>
        tester.widget<RideMapFeature>(find.byType(RideMapFeature));
    await pumpUntil(() => (map().overlayMarkers?.value ?? const []).isNotEmpty);
    final riders = map().overlayMarkers!.value
        .where((marker) => marker.id.startsWith('rider-'))
        .toList();
    expect(riders, isNotEmpty, reason: 'Ride Lab has a group to draw');

    // The group's back is named in the label the shell already gives its marker
    // ("Charlie · TEC"); it and nobody else among the others is a star. This
    // phone is the leader, so it is not among them.
    final stars = riders.where(
      (marker) => marker.outline == RiderMarkerOutline.star,
    );
    expect(
      stars.map((marker) => marker.label),
      everyElement(contains('TEC')),
      reason: 'only the Tail End Charlie is a star among the other riders',
    );
    expect(stars, hasLength(1));
    expect(
      riders
          .where((marker) => marker.outline == RiderMarkerOutline.circle)
          .length,
      riders.length - 1,
      reason: 'everyone else is a circle',
    );

    // This phone leads a group, so its own marker is a star ...
    expect(map().localMarkerOutline, RiderMarkerOutline.star);

    // ... until the rider gives the lead up, which is shown as it happens,
    // without a restart and without the phone moving.
    await tester.runAsync(() => controller.setRole(RideRole.rider));
    await pumpUntil(
      () => map().localMarkerOutline == RiderMarkerOutline.circle,
    );
    expect(map().localMarkerOutline, RiderMarkerOutline.circle);

    await tester.runAsync(() => controller.setRole(RideRole.lead));
    await pumpUntil(() => map().localMarkerOutline == RiderMarkerOutline.star);
    expect(map().localMarkerOutline, RiderMarkerOutline.star);

    // Claiming the Tail End Charlie role is not enough to be drawn as the back
    // of this group: the ride has resolved Charlie to it.
    await tester.runAsync(() => controller.setRole(RideRole.tailEndCharlie));
    await pumpUntil(
      () => map().localMarkerOutline == RiderMarkerOutline.circle,
    );
    expect(
      map().localMarkerOutline,
      RiderMarkerOutline.circle,
      reason: 'a second claimant to the back of the group is not a second star',
    );

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
