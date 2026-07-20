import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/situational_awareness_controller.dart';
import 'package:ride_relay/data/in_memory_event_store.dart';
import 'package:ride_relay/domain/geo_point.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/ride_session.dart';
import 'package:ride_relay/domain/rider_location.dart';
import 'package:ride_relay/features/situational_awareness/situational_awareness_screen.dart';
import 'package:ride_relay/services/external_hazard_provider.dart';
import 'package:ride_relay/services/route_deviation_detector.dart';

void main() {
  late DateTime now;
  late SituationalAwarenessController controller;

  setUp(() async {
    now = DateTime.utc(2026, 7, 16, 12);
    var id = 0;
    controller = SituationalAwarenessController(
      InMemoryEventStore(),
      RideSession(
        rideId: 'ride',
        rideCode: 'ABC123',
        inviteSecret: 'secret',
        joinToken: 'test-join-token-0123456789',
        localRiderId: 'rider',
        displayName: 'Oliver',
        role: RideRole.lead,
        joinedAt: now,
      ),
      route: const [
        GeoPoint(latitude: 51, longitude: -1),
        GeoPoint(latitude: 51, longitude: -0.99),
      ],
      externalProviders: const [WazeReadHazardProvider()],
      clock: () => now,
      idFactory: () => 'id-${id++}',
      routeConfig: const RouteDeviationConfig(samplesToConfirmOffRoute: 1),
    );
    await controller.initialize();
  });

  tearDown(() => controller.dispose());

  testWidgets('reports a rider hazard from the current position', (
    tester,
  ) async {
    await controller.recordLocalLocation(_sample(51));
    await tester.pumpWidget(_app(controller));

    await tester.tap(find.byKey(const Key('report-hazard-button')));
    await tester.pumpAndSettle();
    expect(find.text('Report a hazard'), findsOneWidget);

    await tester.tap(find.byKey(const Key('submit-hazard-button')));
    await tester.pumpAndSettle();

    expect(find.text('Roadworks'), findsOneWidget);
    expect(find.textContaining('1 report'), findsOneWidget);
  });

  testWidgets('shows coordinator off-route alert and Waze unavailable state', (
    tester,
  ) async {
    await controller.recordLocalLocation(_sample(51.002));
    await tester.pumpWidget(_app(controller));

    expect(find.text('1 coordinator alert'), findsOneWidget);
    expect(find.text('Acknowledge'), findsOneWidget);
    expect(find.text('Waze reports'), findsOneWidget);
    expect(find.textContaining('No supported general Waze'), findsOneWidget);

    await tester.tap(find.text('Acknowledge'));
    await tester.pump();
    expect(find.text('Seen'), findsOneWidget);
  });
}

Widget _app(SituationalAwarenessController controller) => MaterialApp(
  theme: ThemeData.dark(useMaterial3: true),
  home: SituationalAwarenessScreen(controller: controller),
);

LocationSample _sample(double latitude) => LocationSample(
  position: GeoPoint(latitude: latitude, longitude: -0.995),
  recordedAt: DateTime.utc(2026, 7, 16, 12),
  accuracyMeters: 5,
);
