import 'dart:async';

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
import 'package:ride_relay/domain/ride_event.dart';
import 'package:ride_relay/domain/ride_coordination_mode.dart';
import 'package:ride_relay/domain/ride_role.dart';
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

  testWidgets(
    'a stalled saved-ride journal falls back to an interactive home screen',
    (tester) async {
      final eventStore = _FirstRestoreBlockingEventStore();
      final sessionStore = InMemorySessionStore();
      await sessionStore.save(
        RideSession(
          rideId: 'ride-994954',
          rideCode: '994954',
          inviteSecret: '0123456789abcdef',
          joinToken: 'join-token-0123456789',
          localRiderId: 'rider-android',
          displayName: 'Android tester',
          role: RideRole.rider,
          joinedAt: DateTime(2026, 7, 28, 9),
        ),
      );
      final controller = RideController(
        eventStore,
        sessionStore,
        const _FakeNearbyBridge(),
      );
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        _app(
          controller,
          initializeController: controller.initialize,
          startupFallbackAfter: const Duration(milliseconds: 100),
        ),
      );
      await tester.pump();

      expect(find.text('Restoring your ride…'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byKey(const Key('ride-restoration-banner')), findsOneWidget);
      expect(find.text('Still restoring ride 994954'), findsOneWidget);
      expect(find.byTooltip('Settings'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Create a ride'),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Join a ride'),
            )
            .onPressed,
        isNull,
      );

      eventStore.completeFirstRestore(const []);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('ride-restoration-banner')), findsNothing);
      expect(find.text('Navigation map'), findsOneWidget);
      // ActiveRideShell must project the controller's already-restored events,
      // not begin a second full SQLite journal read behind another spinner.
      expect(eventStore.eventsForRideCalls, 1);
    },
  );

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

  testWidgets('a solo ride skips the group share-code step', (tester) async {
    final controller = await _controller();
    addTearDown(controller.dispose);

    await tester.pumpWidget(_app(controller));
    await tester.tap(find.text('Create a ride'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('ride-scope-selector')), findsOneWidget);
    expect(find.text('Second-bike drop-off'), findsOneWidget);
    expect(find.text('Keep-together group'), findsOneWidget);

    await tester.tap(find.text('Solo'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.widgetWithText(FilledButton, 'Create ride'),
      180,
      scrollable: _rideFormScrollable,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Create ride'));
    await tester.pumpAndSettle();

    expect(controller.coordinationMode, RideCoordinationMode.solo);
    expect(find.text('Continue to ride'), findsNothing);
    expect(find.text('Ready for solo ride'), findsOneWidget);
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

  // #208: a transient relay failure left a sentence on screen and nothing to
  // press, so a tester at a coffee stop could not get back into her own ride.
  testWidgets('a transient join failure offers a retry that works', (
    tester,
  ) async {
    final directory = _FlakyRideCodeDirectory();
    final controller = await _controller(rideCodeDirectory: directory);
    addTearDown(controller.dispose);

    await tester.pumpWidget(_app(controller));
    await tester.tap(find.text('Join a ride'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('rider-name-field')), 'Oliver');

    // A local validation failure is not worth retrying unchanged, so it offers
    // no retry.
    await tester.enterText(find.byKey(const Key('ride-code-field')), '123');
    await _tapJoin(tester);
    expect(find.text('Enter a valid six-digit ride code.'), findsOneWidget);
    expect(find.byKey(const Key('retry-ride-submit')), findsNothing);

    await tester.enterText(find.byKey(const Key('ride-code-field')), '994954');
    await _tapJoin(tester);

    expect(find.textContaining('temporarily unavailable'), findsOneWidget);
    expect(controller.hasActiveRide, isFalse);

    await tester.scrollUntilVisible(
      find.byKey(const Key('retry-ride-submit')),
      180,
      scrollable: _rideFormScrollable,
    );
    await tester.tap(find.byKey(const Key('retry-ride-submit')));
    await tester.pumpAndSettle();

    expect(controller.hasActiveRide, isTrue);
    expect(directory.attempts, 2);
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
    expect(find.byIcon(Icons.two_wheeler_outlined), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_outlined), findsOneWidget);

    await tester.tap(find.byIcon(Icons.two_wheeler_outlined));
    await tester.pumpAndSettle();

    expect(find.text('Oliver'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('MARKING STATS'),
      260,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Marker mode'), findsOneWidget);
    expect(find.byKey(const Key('open-ride-actions')), findsNothing);
    expect(find.text('MARKING STATS'), findsOneWidget);

    expect(find.text('Ride actions'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Share ride summary'), findsOneWidget);
    expect(find.text('Ride roster'), findsWidgets);
    expect(find.text('Navigation map'), findsNothing);
    expect(find.text('End ride'), findsNothing);

    await tester.scrollUntilVisible(
      find.text('QUICK MESSAGES'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('QUICK MESSAGES'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.warning_amber_outlined));
    await tester.pumpAndSettle();

    expect(find.text('Alerts'), findsWidgets);
    expect(find.text('ROAD ALERTS'), findsOneWidget);
    expect(find.text('EXTERNAL SOURCES'), findsNothing);
    expect(find.text('RIDER STATUS'), findsNothing);

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
    expect(find.textContaining('Oliver (you)'), findsOneWidget);
    expect(controller.rideStarted, isFalse);

    await tester.tap(find.byKey(const Key('start-ride-button')));
    await tester.pumpAndSettle();
    expect(find.text('Start this ride?'), findsOneWidget);
    expect(find.textContaining('No route is selected'), findsOneWidget);

    await tester.tap(find.byKey(const Key('start-without-route-button')));
    await tester.pumpAndSettle();

    // This solo ride has no Tail End Charlie, so the safety warning stands
    // between the confirmation and the start. Its own behaviour is covered by
    // ride_start_tec_warning_test.dart.
    expect(controller.rideStarted, isFalse);
    await tester.tap(find.byKey(const Key('start-without-tec-button')));
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

  testWidgets('the ride navigation bar names its destinations (#306)', (
    tester,
  ) async {
    // It was `alwaysHide`, which made the app's primary navigation four
    // unlabelled icons — the thing #306 says no feature may be reachable only
    // through. The bar is hidden while the rider is moving, so the height the
    // labels cost is only ever paid at a standstill.
    //
    // Portrait explicitly: the default test viewport is landscape, where the
    // shell uses the rail instead and there is no bar to find.
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = await _controller();
    await controller.createRide('Oliver');

    await tester.pumpWidget(_app(controller));
    await tester.pumpAndSettle();

    final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(bar.labelBehavior, NavigationDestinationLabelBehavior.alwaysShow);
    for (final label in ['Map', 'Ride', 'Alerts']) {
      expect(find.text(label), findsWidgets, reason: label);
    }

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    controller.dispose();
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
      // Named destinations, not four bare icons (#306). The rail is hidden
      // while the rider is moving, so the width the labels cost is only ever
      // paid at a standstill.
      expect(rail.minWidth, 72);
      expect(rail.labelType, NavigationRailLabelType.all);
      for (final label in ['Map', 'Ride', 'Alerts']) {
        expect(find.text(label), findsWidgets, reason: label);
      }

      controller.dispose();
    },
  );

  testWidgets('active ride can be left to choose another ride', (tester) async {
    final controller = await _controller();
    await controller.createRide('Oliver');
    await tester.pumpWidget(_app(controller));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.two_wheeler_outlined));
    await tester.pumpAndSettle();
    final leaveOrEnd = find.byKey(const Key('ride-actions-leave-or-end'));
    await tester.ensureVisible(leaveOrEnd);
    await tester.pumpAndSettle();
    await tester.tap(leaveOrEnd);
    await tester.pumpAndSettle();
    expect(find.text('Leave or end this ride?'), findsOneWidget);

    await tester.tap(find.text('Leave only'));
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
    // The state that exposed the guard defect (#306). Marking changes the
    // session role, so `session.role` is no longer `lead` while
    // `isLocalRideLeader` still is — and the shell's own end-ride guard read the
    // former while both entry points offer the action on the latter. A leader
    // marking a junction could tap End ride and have nothing happen.
    expect(controller.session?.role, isNot(RideRole.lead));
    expect(controller.isLocalRideLeader, isTrue);
    await tester.pumpWidget(_app(controller));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.two_wheeler_outlined));
    await tester.pumpAndSettle();
    final leaveOrEnd = find.byKey(const Key('ride-actions-leave-or-end'));
    await tester.ensureVisible(leaveOrEnd);
    await tester.pumpAndSettle();
    await tester.tap(leaveOrEnd);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('end-ride-for-everyone')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('end-ride-marking-summary')), findsOneWidget);
    expect(find.textContaining('1 session'), findsOneWidget);
    // The consolidated Leave-or-end decision reaches the one full
    // confirmation, including the consequence the old dashboard dialog missed.
    expect(find.textContaining('ends the group ride for everyone'), findsOne);

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

    await tester.tap(find.byIcon(Icons.two_wheeler_outlined));
    await tester.pumpAndSettle();
    final leaveOrEnd = find.byKey(const Key('ride-actions-leave-or-end'));
    await tester.ensureVisible(leaveOrEnd);
    await tester.pumpAndSettle();
    await tester.tap(leaveOrEnd);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('end-ride-for-everyone')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'End ride'));
    await tester.pumpAndSettle();

    expect(find.text('Ride summary ready'), findsOneWidget);
    // Renamed in #156: the button files the ride to Previous rides, and the old
    // label said it was removed from the phone.
    expect(find.text('Finish and file in Previous rides'), findsOneWidget);
    expect(controller.rideEnded, isTrue);
    expect(controller.hasActiveRide, isTrue);

    await tester.tap(find.text('Share ride recap image'));
    await tester.pumpAndSettle();
    expect(find.text('Ride recap'), findsOneWidget);
    expect(find.byKey(const Key('share-recap-image-button')), findsOneWidget);

    controller.dispose();
  });

  // #207: the ride-ended screen used to be the whole app with no way back, so
  // the only exit filed the ride and stopped relay recovery.
  testWidgets('ended ride can be closed and reopened without filing it', (
    tester,
  ) async {
    final controller = await _controller();
    await controller.createRide('Oliver');
    await controller.endRide();
    await tester.pumpWidget(_app(controller));
    await tester.pumpAndSettle();

    expect(find.text('Ride summary ready'), findsOneWidget);
    final rideCode = controller.session!.rideCode;

    await tester.tap(find.byKey(const Key('leave-ended-ride-button')));
    await tester.pumpAndSettle();

    expect(find.text('Create a ride'), findsOneWidget);
    expect(find.byKey(const Key('set-aside-ride-banner')), findsOneWidget);
    expect(find.text('Ride $rideCode has ended'), findsOneWidget);
    // Nothing was given up to get here.
    expect(controller.hasActiveRide, isTrue);
    expect(controller.rideEnded, isTrue);

    await tester.tap(find.byKey(const Key('reopen-set-aside-ride')));
    await tester.pumpAndSettle();

    expect(find.text('Ride summary ready'), findsOneWidget);

    // The app-bar close is the other way out, and it behaves the same.
    await tester.tap(find.byKey(const Key('leave-ended-ride-screen-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('set-aside-ride-banner')), findsOneWidget);

    controller.dispose();
  });

  testWidgets('creating after a set-aside ended ride opens the new ride', (
    tester,
  ) async {
    final controller = await _controller();
    addTearDown(controller.dispose);
    await controller.createRide('Oliver');
    final endedRideId = controller.session!.rideId;
    await controller.endRide();
    controller.setEndedRideAside();

    await tester.pumpWidget(_app(controller));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('set-aside-ride-banner')), findsOneWidget);

    await tester.tap(find.text('Create a ride'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.widgetWithText(FilledButton, 'Create ride'),
      180,
      scrollable: _rideFormScrollable,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Create ride'));
    await tester.pumpAndSettle();
    expect(find.text('Continue to ride'), findsOneWidget);

    await tester.tap(find.text('Continue to ride'));
    await tester.pumpAndSettle();

    expect(controller.session?.rideId, isNot(endedRideId));
    expect(controller.rideEnded, isFalse);
    expect(controller.endedRideSetAside, isFalse);
    expect(find.text('Navigation map'), findsOneWidget);
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
  Future<void> Function()? initializeController,
  Duration startupFallbackAfter = const Duration(seconds: 2),
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
  initializeController: initializeController,
  startupFallbackAfter: startupFallbackAfter,
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

Future<void> _tapJoin(WidgetTester tester) async {
  await tester.scrollUntilVisible(
    find.widgetWithText(FilledButton, 'Join ride'),
    180,
    scrollable: _rideFormScrollable,
  );
  await tester.tap(find.widgetWithText(FilledButton, 'Join ride'));
  await tester.pumpAndSettle();
}

/// Fails the first resolve the way an unreachable relay does, then succeeds.
class _FlakyRideCodeDirectory implements RideCodeDirectory {
  int attempts = 0;

  @override
  void close() {}

  @override
  Future<void> register(RideSession session) async {}

  @override
  Future<RideCodeCredentials> resolve(
    String rideCode, {
    String? joinToken,
  }) async {
    attempts += 1;
    if (attempts == 1) {
      throw const RideCodeDirectoryException(
        'Ride code service is temporarily unavailable. Check your connection '
        'and try again.',
        retryable: true,
      );
    }
    return RideCodeCredentials(
      rideId: 'ride-$rideCode',
      rideCode: rideCode,
      inviteSecret: 'test-invite-secret-0123456789',
      joinToken: 'test-join-token-0123456789',
    );
  }
}

class _FirstRestoreBlockingEventStore extends InMemoryEventStore {
  final _firstRestore = Completer<List<RideEvent>>();
  int eventsForRideCalls = 0;

  @override
  Future<List<RideEvent>> eventsForRide(String rideId) {
    eventsForRideCalls += 1;
    if (eventsForRideCalls == 1) return _firstRestore.future;
    return Completer<List<RideEvent>>().future;
  }

  void completeFirstRestore(List<RideEvent> events) {
    _firstRestore.complete(events);
  }
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
