import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/app/ride_relay_app.dart';
import 'package:ride_relay/controllers/distance_unit_controller.dart';
import 'package:ride_relay/controllers/completed_rides_controller.dart';
import 'package:ride_relay/controllers/map_style_mode_controller.dart';
import 'package:ride_relay/controllers/ride_code_preference_controller.dart';
import 'package:ride_relay/controllers/ride_controller.dart';
import 'package:ride_relay/controllers/rider_profile_controller.dart';
import 'package:ride_relay/controllers/shared_route_controller.dart';
import 'package:ride_relay/controllers/speed_limit_display_controller.dart';
import 'package:ride_relay/data/in_memory_event_store.dart';
import 'package:ride_relay/data/in_memory_session_store.dart';
import 'package:ride_relay/domain/distance_unit.dart';
import 'package:ride_relay/domain/completed_ride_store.dart';
import 'package:ride_relay/domain/recorded_route_store.dart';
import 'package:ride_relay/domain/ride_session.dart';
import 'package:ride_relay/internet/internet_relay_client.dart';
import 'package:ride_relay/internet/plan_directory.dart';
import 'package:ride_relay/services/nearby_bridge.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  testWidgets('home screen exposes the two ride entry points', (tester) async {
    final controller = await _controller();
    await tester.pumpWidget(_app(controller));

    expect(find.text('Create a ride'), findsOneWidget);
    expect(find.text('Join a ride'), findsOneWidget);
    expect(find.text('Try a simulated ride'), findsOneWidget);
    expect(find.text('Ready to ride?'), findsOneWidget);

    controller.dispose();
  });

  testWidgets('create ride accepts a web-planner route code', (tester) async {
    final controller = await _controller();
    addTearDown(controller.dispose);
    _sharedRoutes.clearPending();
    addTearDown(_sharedRoutes.clearPending);
    final plans = _FakePlanDirectory();

    await tester.pumpWidget(_app(controller, planDirectory: plans));
    await tester.tap(find.text('Create a ride'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('planned-route-code-field')), findsOneWidget);
    expect(find.text('Planned route code (optional)'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('planned-route-code-field')),
      'AB12CD34',
    );
    await tester.scrollUntilVisible(
      find.widgetWithText(FilledButton, 'Create ride'),
      180,
      scrollable: _rideFormScrollable,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Create ride'));
    await tester.pumpAndSettle();

    expect(plans.requestedCode, 'AB12CD34');
    expect(find.text('Continue to ride'), findsOneWidget);

    await tester.tap(find.text('Continue to ride'));
    expect(_sharedRoutes.pending?.name, 'Peak Loop.gpx');
  });

  testWidgets('join form keeps the active ride code above an iOS keyboard', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 667);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    final controller = await _controller();
    addTearDown(controller.dispose);

    await tester.pumpWidget(_app(controller));
    await tester.tap(find.text('Join a ride'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('ride-code-field')),
      180,
      scrollable: _rideFormScrollable,
    );
    await tester.tap(find.byKey(const Key('ride-code-field')));
    tester.view.viewInsets = const FakeViewPadding(bottom: 290);
    await tester.pumpAndSettle();

    final keyboardTop = tester.view.physicalSize.height - 290;
    expect(
      tester.getRect(find.byKey(const Key('ride-code-field'))).bottom,
      lessThanOrEqualTo(keyboardTop),
    );
    expect(tester.takeException(), isNull);

    await tester.scrollUntilVisible(
      find.widgetWithText(FilledButton, 'Join ride'),
      160,
      scrollable: _rideFormScrollable,
    );
    expect(find.widgetWithText(FilledButton, 'Join ride'), findsOneWidget);
  });

  testWidgets('join form explains and clears a remembered ride code', (
    tester,
  ) async {
    final controller = await _controller();
    addTearDown(controller.dispose);
    final preference = RideCodePreferenceController.memory(savedCode: '123456');
    addTearDown(preference.dispose);

    await tester.pumpWidget(_app(controller, rideCodePreference: preference));
    await tester.tap(find.text('Join a ride'));
    await tester.pumpAndSettle();

    final codeField = tester.widget<TextField>(
      find.byKey(const Key('ride-code-field')),
    );
    expect(codeField.controller?.text, '123456');
    expect(find.text('Saved from your last successful join'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.byKey(const Key('forget-saved-ride-code')),
      160,
      scrollable: _rideFormScrollable,
    );
    await tester.tap(find.byKey(const Key('forget-saved-ride-code')));
    await tester.pump();

    expect(preference.savedCode, isNull);
    expect(codeField.controller?.text, isEmpty);
    expect(find.text('Saved from your last successful join'), findsNothing);
  });

  testWidgets('only a successful join replaces the remembered code', (
    tester,
  ) async {
    final preference = RideCodePreferenceController.memory(savedCode: '111111');
    addTearDown(preference.dispose);
    final controller = await _controller(
      rideCodeDirectory: const _SuccessfulRideCodeDirectory(),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(_app(controller, rideCodePreference: preference));
    await tester.tap(find.text('Join a ride'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('rider-name-field')), 'Oliver');
    await tester.enterText(find.byKey(const Key('ride-code-field')), '123');
    await tester.scrollUntilVisible(
      find.widgetWithText(FilledButton, 'Join ride'),
      180,
      scrollable: _rideFormScrollable,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Join ride'));
    await tester.pumpAndSettle();
    expect(preference.savedCode, '111111');
    expect(find.text('Enter a valid six-digit ride code.'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('ride-code-field')), '222222');
    await tester.scrollUntilVisible(
      find.widgetWithText(FilledButton, 'Join ride'),
      180,
      scrollable: _rideFormScrollable,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Join ride'));
    await tester.pumpAndSettle();

    expect(preference.savedCode, '222222');
    expect(controller.hasActiveRide, isTrue);
  });

  testWidgets('settings can override locale-based distance units', (
    tester,
  ) async {
    final controller = await _controller();
    final distanceUnits = DistanceUnitController.forLocale(
      const Locale('fr', 'FR'),
    );
    addTearDown(distanceUnits.dispose);
    await tester.pumpWidget(
      RideRelayApp(
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
      ),
    );

    expect(distanceUnits.value, DistanceUnit.kilometres);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('DISTANCE UNITS'), findsOneWidget);

    await tester.tap(find.text('Miles'));
    await tester.pumpAndSettle();
    expect(distanceUnits.value, DistanceUnit.miles);
    expect(find.byKey(const Key('use-locale-distance-unit')), findsOneWidget);

    controller.dispose();
  });

  testWidgets('active ride shows coordination controls', (tester) async {
    final controller = await _controller();
    await controller.createRide('Oliver');
    await controller.startRide();
    await tester.pumpWidget(_app(controller));
    await tester.pumpAndSettle();

    expect(find.text('Navigation'), findsOneWidget);
    expect(find.text('Navigation map'), findsOneWidget);
    expect(find.byIcon(Icons.map), findsOneWidget);
    expect(find.byIcon(Icons.tune_outlined), findsOneWidget);
    expect(find.byIcon(Icons.health_and_safety_outlined), findsOneWidget);

    await tester.tap(find.byIcon(Icons.tune_outlined));
    await tester.pumpAndSettle();

    expect(find.text('Oliver'), findsOneWidget);
    expect(find.text('Marker mode'), findsOneWidget);
    expect(find.byTooltip('Leave or switch ride'), findsOneWidget);
    expect(find.byTooltip('Share ride summary'), findsOneWidget);
    expect(find.text('MARKING STATS'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('QUICK MESSAGES'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('QUICK MESSAGES'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.health_and_safety_outlined));
    await tester.pumpAndSettle();

    expect(find.text('Ride awareness'), findsOneWidget);
    expect(find.text('ACTIVE HAZARDS'), findsOneWidget);

    controller.dispose();
  });

  testWidgets('leader confirms start while pre-start roster stays private', (
    tester,
  ) async {
    final controller = await _controller();
    await controller.createRide('Oliver');
    addTearDown(controller.dispose);

    await tester.pumpWidget(_app(controller));
    await tester.pumpAndSettle();

    expect(find.text('Waiting to start'), findsOneWidget);
    expect(find.textContaining('Current positions only'), findsOneWidget);
    expect(find.byKey(const Key('pre-start-roster')), findsOneWidget);
    expect(find.text('Oliver (you)'), findsOneWidget);
    expect(controller.rideStarted, isFalse);

    await tester.tap(find.byKey(const Key('start-ride-button')));
    await tester.pumpAndSettle();
    expect(find.text('Start this ride?'), findsOneWidget);
    expect(find.textContaining('No route is selected'), findsOneWidget);

    await tester.tap(find.byKey(const Key('start-without-route-button')));
    await tester.pumpAndSettle();

    expect(controller.rideStarted, isTrue);
    expect(find.text('Waiting to start'), findsNothing);
    expect(find.text('Navigation map'), findsOneWidget);
  });

  testWidgets('simulated bikes wait for the leader to start the ride', (
    tester,
  ) async {
    final controller = await _controller();
    await controller.createSimulationRide();
    addTearDown(controller.dispose);

    await tester.pumpWidget(_app(controller));
    for (
      var attempt = 0;
      attempt < 30 && find.byIcon(Icons.science_outlined).evaluate().isEmpty;
      attempt += 1
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.byIcon(Icons.science_outlined));
    for (
      var attempt = 0;
      attempt < 30 && find.text('READY').evaluate().isEmpty;
      attempt += 1
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.text('READY'), findsOneWidget);
    expect(find.text('Waiting for start'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('simulation-play-pause')))
          .onPressed,
      isNull,
    );

    await tester.tap(find.byKey(const Key('start-ride-button')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('confirm-start-ride-button')));
    await tester.pump();
    for (
      var attempt = 0;
      attempt < 30 && find.text('RUNNING').evaluate().isEmpty;
      attempt += 1
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(controller.rideStarted, isTrue);
    expect(find.text('RUNNING'), findsOneWidget);
    expect(find.text('Pause'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets(
    'active ride moves navigation chrome to a left rail in landscape',
    (tester) async {
      tester.view.physicalSize = const Size(844, 390);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = await _controller();
      await controller.createRide('Oliver');

      await tester.pumpWidget(_app(controller));
      await tester.pumpAndSettle();

      expect(find.byType(NavigationBar), findsNothing);
      expect(
        find.byKey(const Key('landscape-navigation-rail')),
        findsOneWidget,
      );
      final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
      expect(rail.minWidth, 56);
      expect(rail.labelType, NavigationRailLabelType.none);

      controller.dispose();
    },
  );

  testWidgets('active ride can be left to choose another ride', (tester) async {
    final controller = await _controller();
    await controller.createRide('Oliver');
    await tester.pumpWidget(_app(controller));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.tune_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Leave or switch ride'));
    await tester.pumpAndSettle();
    expect(find.text('Leave this ride?'), findsOneWidget);

    await tester.tap(find.text('Leave and choose another'));
    await tester.pumpAndSettle();

    expect(find.text('Create a ride'), findsOneWidget);
    expect(find.text('Join a ride'), findsOneWidget);
    expect(controller.hasActiveRide, isFalse);

    controller.dispose();
  });

  testWidgets('end ride confirmation includes marking summary', (tester) async {
    final controller = await _controller();
    await controller.createRide('Oliver');
    await controller.startRide();
    await controller.startMarker();
    await controller.recordMarkerPass('rider-a');
    await tester.pumpWidget(_app(controller));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.tune_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('End ride'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('end-ride-marking-summary')), findsOneWidget);
    expect(find.textContaining('1 session'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    controller.dispose();
  });

  testWidgets('ended ride retains relay recovery until removal', (
    tester,
  ) async {
    final controller = await _controller();
    await controller.createRide('Oliver');
    await tester.pumpWidget(_app(controller));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.tune_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('End ride'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'End ride'));
    await tester.pumpAndSettle();

    expect(find.text('Ride summary ready'), findsOneWidget);
    expect(find.text('Remove ride from this phone'), findsOneWidget);
    expect(controller.rideEnded, isTrue);
    expect(controller.hasActiveRide, isTrue);

    await tester.tap(find.text('Share ride recap image'));
    await tester.pumpAndSettle();
    expect(find.text('Ride recap'), findsOneWidget);
    expect(find.byKey(const Key('share-recap-image-button')), findsOneWidget);

    controller.dispose();
  });
}

late RiderProfileController _riderProfile;
late SharedRouteController _sharedRoutes;
late SpeedLimitDisplayController _speedLimitDisplay;
late MapStyleModeController _mapStyleMode;
late RideCodePreferenceController _rideCodePreference;
late CompletedRidesController _completedRides;
final _recordedRoutes = InMemoryRecordedRouteStore();
final _rideFormScrollable = find
    .descendant(
      of: find.byKey(const Key('ride-form-scroll-view')),
      matching: find.byType(Scrollable),
    )
    .first;

RideRelayApp _app(
  RideController controller, {
  RideCodePreferenceController? rideCodePreference,
  PlanDirectory? planDirectory,
}) => RideRelayApp(
  controller: controller,
  distanceUnits: DistanceUnitController.forLocale(const Locale('en', 'GB')),
  mapStyleMode: _mapStyleMode,
  rideCodePreference: rideCodePreference ?? _rideCodePreference,
  riderProfile: _riderProfile,
  sharedRoutes: _sharedRoutes,
  speedLimitDisplay: _speedLimitDisplay,
  recordedRoutes: _recordedRoutes,
  completedRides: _completedRides,
  planDirectory: planDirectory,
  enableNativeServices: false,
);

Future<RideController> _controller({
  RideCodeDirectory? rideCodeDirectory,
}) async {
  final controller = RideController(
    InMemoryEventStore(),
    InMemorySessionStore(),
    const _FakeNearbyBridge(),
    rideCodeDirectory: rideCodeDirectory,
  );
  await controller.initialize();
  return controller;
}

class _SuccessfulRideCodeDirectory implements RideCodeDirectory {
  const _SuccessfulRideCodeDirectory();

  @override
  void close() {}

  @override
  Future<void> register(RideSession session) async {}

  @override
  Future<RideCodeCredentials> resolve(
    String rideCode, {
    String? joinToken,
  }) async => RideCodeCredentials(
    rideId: 'ride-$rideCode',
    rideCode: rideCode,
    inviteSecret: 'test-invite-secret-0123456789',
    joinToken: 'test-join-token-0123456789',
  );
}

class _FakePlanDirectory implements PlanDirectory {
  String? requestedCode;

  @override
  Future<FetchedPlan> fetch(String code) async {
    requestedCode = code;
    return const FetchedPlan(
      name: 'Peak Loop',
      gpx:
          '<gpx version="1.1"><trk><trkseg>'
          '<trkpt lat="53.1" lon="-1.2"/>'
          '<trkpt lat="53.2" lon="-1.1"/>'
          '</trkseg></trk></gpx>',
    );
  }
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
