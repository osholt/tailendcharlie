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
import 'package:ride_relay/features/map/ride_map.dart';
import 'package:ride_relay/services/nearby_bridge.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// **How much of the screen does a demo ride leave to the map before it starts?**
///
/// The operator's 10 October report (#933): a loaded demo ride was "far too
/// busy, in both portrait and landscape mode, mostly covered by the waiting to
/// start banner". The banner stacked a title, a full-width button, a route row
/// and a roster row above the map - about a third of a portrait phone and half
/// of a landscape one.
///
/// A demo has no code to read out and no riders to wait for, so its pre-start
/// surface is one strip with one action. A real ride keeps everything it had.
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

  testWidgets('a demo ride leaves the map most of the screen, upright and on '
      'its side, and offers only Start ride', (tester) async {
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

    // Upright first, then turned on its side: the report was about both, and
    // turning the phone is exactly what a rider does. One test rather than two
    // because a second simulation in this file never reaches its map (see the
    // note in active_ride_navigation_escape_test.dart).
    tester.view.physicalSize = const Size(390, 844);
    await tester.pumpWidget(_app(controller, distanceUnits));
    await _pumpUntilMap(tester);
    for (final (name, size) in [
      ('portrait', const Size(390, 844)),
      ('landscape', const Size(844, 390)),
    ]) {
      tester.view.physicalSize = size;
      await tester.pump(const Duration(milliseconds: 100));

      final bar = find.byKey(const Key('pre-start-compact-bar'));
      expect(bar, findsOneWidget, reason: name);
      // The one action. Every Material button is a ButtonStyleButton (which
      // carries its own InkWell, so ink is not counted separately), and the
      // remaining entries are the other ways a strip could grow a control.
      final actions = find.descendant(
        of: bar,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is ButtonStyleButton ||
              widget is IconButton ||
              widget is PopupMenuButton ||
              widget is ListTile ||
              widget is Checkbox ||
              widget is Switch,
        ),
      );
      expect(actions, findsOneWidget, reason: name);
      expect(
        find.descendant(
          of: bar,
          matching: find.byKey(const Key('start-ride-button')),
        ),
        findsOneWidget,
        reason: name,
      );
      // None of the lobby chrome the report was about.
      expect(find.text('Waiting to start'), findsNothing, reason: name);
      expect(find.byKey(const Key('pre-start-roster')), findsNothing);
      expect(find.byKey(const Key('pre-start-choose-route')), findsNothing);

      // The strip is slim, and the map keeps the rest. Measured against the
      // screen, not a pixel count, so it holds on both shapes of phone.
      expect(tester.getSize(bar).height, lessThanOrEqualTo(72), reason: name);
      final mapShare =
          tester.getSize(find.byType(RideMapFeature)).height / size.height;
      expect(
        mapShare,
        greaterThan(0.8),
        reason: 'the map must keep over four fifths of a $name screen',
      );
    }

    await _tearDown(tester);
  });

  testWidgets('a real pre-start ride keeps its code, route and roster '
      '(#933 loses nothing a leader checks)', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = await _controller();
    await controller.createRide('Oliver');
    addTearDown(controller.dispose);
    final distanceUnits = DistanceUnitController.forLocale(
      const Locale('en', 'GB'),
    );
    addTearDown(distanceUnits.dispose);

    await tester.pumpWidget(_app(controller, distanceUnits));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byKey(const Key('pre-start-compact-bar')), findsNothing);
    expect(find.text('Waiting to start'), findsOneWidget);
    expect(
      find.textContaining('Ride ${controller.session!.rideCode}'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('pre-start-roster')), findsOneWidget);
    expect(find.byKey(const Key('pre-start-choose-route')), findsOneWidget);
    expect(find.byKey(const Key('start-ride-button')), findsOneWidget);

    await _tearDown(tester);
  });
}

/// The bundled route comes off disk, which a test's fake clock does not wait
/// for: give the real event loop a moment between frames.
Future<void> _pumpUntilMap(WidgetTester tester) async {
  for (
    var attempt = 0;
    attempt < 100 && find.byType(RideMapFeature).evaluate().isEmpty;
    attempt += 1
  ) {
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
