import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ride_relay/controllers/completed_rides_controller.dart';
import 'package:ride_relay/controllers/distance_unit_controller.dart';
import 'package:ride_relay/controllers/global_ride_heatmap_controller.dart';
import 'package:ride_relay/controllers/map_style_mode_controller.dart';
import 'package:ride_relay/controllers/ride_code_preference_controller.dart';
import 'package:ride_relay/controllers/ride_controller.dart';
import 'package:ride_relay/controllers/rider_profile_controller.dart';
import 'package:ride_relay/controllers/shared_route_controller.dart';
import 'package:ride_relay/controllers/speed_limit_display_controller.dart';
import 'package:ride_relay/controllers/spoken_guidance_controller.dart';
import 'package:ride_relay/data/in_memory_event_store.dart';
import 'package:ride_relay/data/in_memory_session_store.dart';
import 'package:ride_relay/domain/completed_ride_store.dart';
import 'package:ride_relay/domain/recorded_route_store.dart';
import 'package:ride_relay/domain/ride_session.dart';
import 'package:ride_relay/features/home/home_screen.dart';
import 'package:ride_relay/features/settings/heatmap_consent_prompt.dart';
import 'package:ride_relay/internet/internet_relay_client.dart';
import 'package:ride_relay/services/global_ride_heatmap.dart';
import 'package:ride_relay/services/nearby_bridge.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The one-time global-heatmap question (#957): for installs that never stored a
/// choice, asked once from the home map, never over a ride or navigation.
void main() {
  group('shouldAskHeatmapConsent', () {
    bool ask({
      bool consentAnswered = false,
      bool hasActiveRide = false,
      bool restoring = false,
      bool navigating = false,
      bool arrangingRide = false,
    }) => shouldAskHeatmapConsent(
      consentAnswered: consentAnswered,
      hasActiveRide: hasActiveRide,
      restoring: restoring,
      navigating: navigating,
      arrangingRide: arrangingRide,
    );

    test('asks an unanswered rider on an idle home map', () {
      expect(ask(), isTrue);
    });

    test('never asks a rider who has answered', () {
      expect(ask(consentAnswered: true), isFalse);
    });

    test('never asks during a ride', () {
      expect(ask(hasActiveRide: true), isFalse);
    });

    test('never asks over navigation', () {
      expect(ask(navigating: true), isFalse);
    });

    test('never asks while a ride is being restored', () {
      expect(ask(restoring: true), isFalse);
    });

    test('never asks while a ride or destination is being arranged', () {
      expect(ask(arrangingRide: true), isFalse);
    });
  });

  group('on the home map', () {
    late RideController rideController;
    late DistanceUnitController distanceUnits;
    late MapStyleModeController mapStyleMode;
    late RideCodePreferenceController rideCodePreference;
    late RiderProfileController riderProfile;
    late SharedRouteController sharedRoutes;
    late SpeedLimitDisplayController speedLimitDisplay;
    late CompletedRidesController completedRides;
    late SpokenGuidanceController spokenGuidance;

    setUp(() async {
      SharedPreferences.setMockInitialValues(const {});
      var id = 0;
      rideController = RideController(
        InMemoryEventStore(),
        InMemorySessionStore(),
        const _FakeNearbyBridge(),
        clock: () => DateTime.utc(2026, 10, 10, 9),
        idFactory: () => 'id-${id++}',
        random: Random(7),
        rideCodeDirectory: _NullRideCodeDirectory(),
      );
      await rideController.initialize();
      distanceUnits = DistanceUnitController.forLocale(
        const Locale('en', 'GB'),
      );
      mapStyleMode = await MapStyleModeController.load();
      rideCodePreference = await RideCodePreferenceController.load();
      riderProfile = await RiderProfileController.load();
      sharedRoutes = await SharedRouteController.load(planDirectory: null);
      speedLimitDisplay = SpeedLimitDisplayController.inMemory();
      completedRides = await CompletedRidesController.load(
        InMemoryCompletedRideStore(),
      );
      spokenGuidance = SpokenGuidanceController.inMemory(enabled: true);
    });

    tearDown(() {
      rideController.dispose();
      distanceUnits.dispose();
      mapStyleMode.dispose();
      rideCodePreference.dispose();
      riderProfile.dispose();
      sharedRoutes.dispose();
      speedLimitDisplay.dispose();
      completedRides.dispose();
      spokenGuidance.dispose();
    });

    Future<GlobalRideHeatmapController> loadHeatmap({
      Map<String, Object> stored = const {},
    }) async {
      SharedPreferences.setMockInitialValues(stored);
      final heatmap = await GlobalRideHeatmapController.load(
        client: GlobalHeatmapClient(
          baseUri: Uri.parse('https://relay.example/api/'),
          client: MockClient((_) async => http.Response('{}', 200)),
        ),
        credentials: _MemoryCredentials(),
      );
      addTearDown(heatmap.dispose);
      return heatmap;
    }

    Future<void> pumpHome(
      WidgetTester tester,
      GlobalRideHeatmapController heatmap, {
      VoidCallback? onRetryRestoration,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: HomeScreen(
            controller: rideController,
            distanceUnits: distanceUnits,
            mapStyleMode: mapStyleMode,
            rideCodePreference: rideCodePreference,
            riderProfile: riderProfile,
            sharedRoutes: sharedRoutes,
            speedLimitDisplay: speedLimitDisplay,
            spokenGuidance: spokenGuidance,
            recordedRoutes: InMemoryRecordedRouteStore(),
            completedRides: completedRides,
            globalRideHeatmap: heatmap,
            onRetryRestoration: onRetryRestoration,
            enableNativeServices: false,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    final dialog = find.byKey(const Key('heatmap-consent-dialog'));

    testWidgets('asks a rider who never chose, and until then shares nothing', (
      tester,
    ) async {
      final heatmap = await loadHeatmap();
      await pumpHome(tester, heatmap);

      expect(dialog, findsOneWidget);
      expect(heatmap.consent, HeatmapContributionConsent.never);
      expect(heatmap.consentAnswered, isFalse);
      // Nothing is selected for them, and Save waits for a choice.
      expect(
        tester
            .widget<RadioGroup<HeatmapContributionConsent>>(
              find.byType(RadioGroup<HeatmapContributionConsent>),
            )
            .groupValue,
        isNull,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('heatmap-consent-dialog-save')),
            )
            .onPressed,
        isNull,
      );
      expect(find.textContaining('Never your track'), findsOneWidget);
    });

    for (final choice in [
      HeatmapContributionConsent.always,
      HeatmapContributionConsent.askAfterEachRide,
    ]) {
      testWidgets('stores ${choice.name} and does not ask again', (
        tester,
      ) async {
        final heatmap = await loadHeatmap();
        await pumpHome(tester, heatmap);

        await tester.tap(
          find.byKey(Key('heatmap-consent-dialog-${choice.name}')),
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('heatmap-consent-dialog-save')));
        await tester.pumpAndSettle();

        expect(dialog, findsNothing);
        expect(heatmap.consent, choice);
        expect(heatmap.consentAnswered, isTrue);

        // The screen is rebuilt over and over in production.
        await pumpHome(tester, heatmap);
        await pumpHome(tester, heatmap);
        expect(dialog, findsNothing);
      });
    }

    testWidgets('declining stores never, and the question stays answered', (
      tester,
    ) async {
      final heatmap = await loadHeatmap();
      await pumpHome(tester, heatmap);

      await tester.tap(find.byKey(const Key('heatmap-consent-dialog-decline')));
      await tester.pumpAndSettle();

      expect(dialog, findsNothing);
      expect(heatmap.consent, HeatmapContributionConsent.never);
      expect(heatmap.consentAnswered, isTrue);
      final stored = await SharedPreferences.getInstance();
      expect(stored.getString(GlobalRideHeatmapController.consentKey), 'never');

      await pumpHome(tester, heatmap);
      expect(dialog, findsNothing);
    });

    testWidgets('pressing back is an answer too, and the answer is no', (
      tester,
    ) async {
      final heatmap = await loadHeatmap();
      await pumpHome(tester, heatmap);
      expect(dialog, findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(dialog, findsNothing);
      expect(heatmap.consent, HeatmapContributionConsent.never);
      expect(heatmap.consentAnswered, isTrue);
    });

    testWidgets('is asked once: a relaunch after an answer does not ask', (
      tester,
    ) async {
      final first = await loadHeatmap();
      await pumpHome(tester, first);
      await tester.tap(find.byKey(const Key('heatmap-consent-dialog-decline')));
      await tester.pumpAndSettle();

      // A new launch reads what was stored.
      final relaunched = await GlobalRideHeatmapController.load(
        client: GlobalHeatmapClient(
          baseUri: Uri.parse('https://relay.example/api/'),
          client: MockClient((_) async => http.Response('{}', 200)),
        ),
        credentials: _MemoryCredentials(),
      );
      addTearDown(relaunched.dispose);
      await pumpHome(tester, relaunched);

      expect(dialog, findsNothing);
    });

    for (final choice in HeatmapContributionConsent.values) {
      testWidgets('does not ask a rider who chose ${choice.name} earlier', (
        tester,
      ) async {
        final heatmap = await loadHeatmap(
          stored: {GlobalRideHeatmapController.consentKey: choice.name},
        );
        await pumpHome(tester, heatmap);

        expect(dialog, findsNothing);
        expect(heatmap.consent, choice);
      });
    }

    testWidgets('does not ask while a ride is running', (tester) async {
      final heatmap = await loadHeatmap();
      await rideController.createRide('Oliver');
      rideController.setRunningRideAside();
      expect(rideController.hasActiveRide, isTrue);

      await pumpHome(tester, heatmap);

      expect(dialog, findsNothing);
      expect(heatmap.consentAnswered, isFalse);
    });

    testWidgets('does not ask while a ride is being restored', (tester) async {
      final heatmap = await loadHeatmap();

      await pumpHome(tester, heatmap, onRetryRestoration: () {});

      expect(dialog, findsNothing);
      expect(heatmap.consentAnswered, isFalse);
    });
  });
}

class _FakeNearbyBridge extends NearbyBridge {
  const _FakeNearbyBridge();

  @override
  Future<NearbyCapabilities> capabilities() async =>
      const NearbyCapabilities.unavailable();
}

class _NullRideCodeDirectory implements RideCodeDirectory {
  @override
  Future<void> register(RideSession session) async {}

  @override
  Future<RideCodeCredentials> resolve(
    String rideCode, {
    String? joinToken,
  }) async => throw const RideCodeDirectoryException('Not used in this test.');

  @override
  void close() {}
}

class _MemoryCredentials implements HeatmapCredentialStore {
  HeatmapCredential? value;

  @override
  Future<void> delete() async => value = null;

  @override
  Future<HeatmapCredential?> read() async => value;

  @override
  Future<void> write(HeatmapCredential credential) async => value = credential;
}
