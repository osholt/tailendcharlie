import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/foreground_location_controller.dart';
import 'package:ride_relay/controllers/situational_awareness_controller.dart';
import 'package:ride_relay/data/in_memory_event_store.dart';
import 'package:ride_relay/domain/geo_point.dart';
import 'package:ride_relay/domain/hazard.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/ride_session.dart';
import 'package:ride_relay/domain/rider_location.dart';
import 'package:ride_relay/features/situational_awareness/situational_awareness_screen.dart';
import 'package:ride_relay/services/device_location_source.dart';
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

  testWidgets('does not offer enforcement report categories', (tester) async {
    await controller.recordLocalLocation(_sample(51));
    await tester.pumpWidget(_app(controller));

    await tester.tap(find.byKey(const Key('report-hazard-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('hazard-type-field')));
    await tester.pumpAndSettle();

    expect(find.text(HazardType.policeActivity.label), findsNothing);
    expect(find.text(HazardType.speedCamera.label), findsNothing);
    expect(find.text(HazardType.debris.label), findsOneWidget);
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

  testWidgets('pre-start offers current position without promising a track', (
    tester,
  ) async {
    final platform = _FakeLocationPlatform();
    final location = ForegroundLocationController(
      DeviceLocationSource(platform),
      (_) async {},
    );
    await location.initialize();
    addTearDown(location.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: SituationalAwarenessScreen(
          controller: controller,
          rideStarted: false,
          locationController: location,
        ),
      ),
    );

    expect(find.text('Current position only before departure'), findsOneWidget);
    expect(find.text('Your assembly position'), findsOneWidget);
    expect(find.textContaining('Tracks, route progress'), findsOneWidget);
    expect(find.byKey(const Key('location-sharing-button')), findsOneWidget);
  });

  testWidgets(
    'offers a serious traffic alternative only through leader review',
    (tester) async {
      var reviewed = false;
      var dismissed = false;
      final hazard = HazardReport(
        id: 'tomtom-closure',
        rideId: 'ride',
        type: HazardType.roadworks,
        severity: HazardSeverity.critical,
        position: const GeoPoint(latitude: 51, longitude: -0.995),
        reportedAt: now,
        updatedAt: now,
        expiresAt: now.add(const Duration(minutes: 15)),
        reporterId: 'tomtom-traffic',
        source: HazardSource.externalProvider,
        providerId: 'tomtom-traffic',
        details: 'A48 closed · TomTom · updated now',
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: SituationalAwarenessScreen(
            controller: controller,
            trafficRerouteHazards: [hazard],
            trafficRerouteError: 'Provider retry is available.',
            onReviewTrafficAlternative: () async => reviewed = true,
            onDismissTrafficAlternative: () async => dismissed = true,
          ),
        ),
      );

      expect(
        find.text('Serious incident may affect the route'),
        findsOneWidget,
      );
      expect(find.textContaining('group route changes only'), findsOneWidget);
      expect(find.byKey(const Key('traffic-reroute-error')), findsOneWidget);

      await tester.tap(find.byKey(const Key('review-traffic-alternative')));
      await tester.pump();
      expect(reviewed, isTrue);

      await tester.tap(find.byKey(const Key('dismiss-traffic-alternative')));
      await tester.pump();
      expect(dismissed, isTrue);
    },
  );
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

class _FakeLocationPlatform implements DeviceLocationPlatform {
  final _positions = StreamController<LocationSample>.broadcast();

  @override
  Future<DeviceLocationPermission> checkPermission() async =>
      DeviceLocationPermission.whileInUse;

  @override
  Future<bool> isServiceEnabled() async => true;

  @override
  Stream<LocationSample> positionStream() => _positions.stream;

  @override
  Future<DeviceLocationPermission> requestPermission() async =>
      DeviceLocationPermission.whileInUse;
}
