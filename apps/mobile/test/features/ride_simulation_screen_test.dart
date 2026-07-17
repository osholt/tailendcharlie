import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/ride_simulation_controller.dart';
import 'package:ride_relay/controllers/situational_awareness_controller.dart';
import 'package:ride_relay/data/in_memory_event_store.dart';
import 'package:ride_relay/domain/geo_point.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/ride_session.dart';
import 'package:ride_relay/features/simulation/ride_simulation_screen.dart';

void main() {
  testWidgets('Ride Lab exposes fleet scenarios in landscape', (tester) async {
    tester.view.physicalSize = const Size(844, 390);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final session = RideSession(
      rideId: 'sim-ride',
      rideCode: 'SIM123',
      inviteSecret: 'simulation-secret-that-is-long-enough',
      localRiderId: 'lead',
      displayName: 'Demo Lead',
      role: RideRole.lead,
      joinedAt: DateTime.utc(2026, 7, 17),
      isSimulation: true,
    );
    const route = [
      GeoPoint(latitude: 51, longitude: -1),
      GeoPoint(latitude: 51, longitude: -0.9),
    ];
    final awareness = SituationalAwarenessController(
      InMemoryEventStore(),
      session,
      route: route,
    );
    await awareness.initialize();
    final simulation = RideSimulationController(
      awareness,
      session: session,
      route: route,
      tickInterval: const Duration(days: 1),
    );
    await simulation.initialize();
    addTearDown(() {
      simulation.dispose();
      awareness.dispose();
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: RideSimulationScreen(
          controller: simulation,
          onRestart: () async {},
          onExit: () async {},
        ),
      ),
    );

    expect(find.text('Ride Lab'), findsOneWidget);
    expect(find.text('VIRTUAL FLEET'), findsOneWidget);
    expect(find.text('Demo Lead'), findsOneWidget);
    expect(find.text('Charlie'), findsOneWidget);
    expect(find.byKey(const Key('simulation-off-route')), findsOneWidget);

    await tester.ensureVisible(find.byKey(const Key('simulation-off-route')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('simulation-off-route')));
    await tester.pump();
    expect(simulation.alexOffRoute, isTrue);
    expect(tester.takeException(), isNull);
  });
}
