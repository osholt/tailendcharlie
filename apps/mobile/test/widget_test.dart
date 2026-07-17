import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/app/ride_relay_app.dart';
import 'package:ride_relay/controllers/distance_unit_controller.dart';
import 'package:ride_relay/controllers/ride_controller.dart';
import 'package:ride_relay/data/in_memory_event_store.dart';
import 'package:ride_relay/data/in_memory_session_store.dart';
import 'package:ride_relay/domain/distance_unit.dart';
import 'package:ride_relay/services/nearby_bridge.dart';

void main() {
  testWidgets('home screen exposes the two ride entry points', (tester) async {
    final controller = await _controller();
    await tester.pumpWidget(_app(controller));

    expect(find.text('Create a ride'), findsOneWidget);
    expect(find.text('Join a ride'), findsOneWidget);
    expect(find.text('Try a simulated ride'), findsOneWidget);
    expect(find.text('Ready to ride?'), findsOneWidget);

    controller.dispose();
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

    controller.dispose();
  });
}

RideRelayApp _app(RideController controller) => RideRelayApp(
  controller: controller,
  distanceUnits: DistanceUnitController.forLocale(const Locale('en', 'GB')),
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
