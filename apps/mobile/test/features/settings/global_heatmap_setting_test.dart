import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ride_relay/controllers/distance_unit_controller.dart';
import 'package:ride_relay/controllers/global_ride_heatmap_controller.dart';
import 'package:ride_relay/controllers/map_style_mode_controller.dart';
import 'package:ride_relay/controllers/rider_profile_controller.dart';
import 'package:ride_relay/controllers/speed_limit_display_controller.dart';
import 'package:ride_relay/domain/completed_ride_store.dart';
import 'package:ride_relay/features/settings/unit_settings_sheet.dart';
import 'package:ride_relay/services/global_ride_heatmap.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'contribution is separate from viewing and requires clear consent',
    (tester) async {
      SharedPreferences.setMockInitialValues(const {});
      final mapStyle = await MapStyleModeController.load();
      final riderProfile = await RiderProfileController.load();
      final speedLimit = SpeedLimitDisplayController.inMemory();
      final heatmap = await GlobalRideHeatmapController.load(
        client: GlobalHeatmapClient(
          baseUri: Uri.parse('https://relay.example/api/'),
          client: MockClient((_) async => http.Response('{}', 200)),
        ),
        credentials: _MemoryCredentials(),
      );
      addTearDown(mapStyle.dispose);
      addTearDown(riderProfile.dispose);
      addTearDown(speedLimit.dispose);
      addTearDown(heatmap.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: UnitSettingsSheet(
              controller: DistanceUnitController.forLocale(
                const Locale('en', 'GB'),
              ),
              mapStyleMode: mapStyle,
              riderProfile: riderProfile,
              speedLimitDisplay: speedLimit,
              globalRideHeatmap: heatmap,
              completedRideStore: InMemoryCompletedRideStore(),
              embedded: true,
            ),
          ),
        ),
      );

      final consent = find.byKey(const Key('global-heatmap-consent'));
      await tester.ensureVisible(consent);
      expect(heatmap.visible, isFalse);
      expect(heatmap.consent, HeatmapContributionConsent.always);

      final shareHistory = find.byKey(
        const Key('global-heatmap-share-history'),
      );
      await tester.ensureVisible(shareHistory);
      await tester.tap(shareHistory);
      await tester.pumpAndSettle();
      expect(
        find.text('There are no saved rides to share yet.'),
        findsOneWidget,
      );

      await tester.tap(consent);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Never').last);
      await tester.pumpAndSettle();
      expect(heatmap.consent, HeatmapContributionConsent.never);
      expect(heatmap.visible, isFalse);

      await tester.tap(consent);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ask after each ride').last);
      await tester.pumpAndSettle();
      expect(find.text('Contribute road coverage?'), findsOneWidget);
      expect(find.textContaining('24 months'), findsOneWidget);
      await tester.tap(find.text('I understand'));
      await tester.pumpAndSettle();
      expect(heatmap.consent, HeatmapContributionConsent.askAfterEachRide);
      expect(heatmap.visible, isFalse);

      final remove = find.byKey(const Key('global-heatmap-remove-data'));
      await tester.ensureVisible(remove);
      await tester.tap(remove);
      await tester.pumpAndSettle();
      expect(heatmap.consent, HeatmapContributionConsent.never);
    },
  );
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
