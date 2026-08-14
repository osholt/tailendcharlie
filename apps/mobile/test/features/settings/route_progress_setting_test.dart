import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/distance_unit_controller.dart';
import 'package:ride_relay/controllers/map_style_mode_controller.dart';
import 'package:ride_relay/controllers/rider_profile_controller.dart';
import 'package:ride_relay/controllers/route_progress_display_controller.dart';
import 'package:ride_relay/controllers/speed_limit_display_controller.dart';
import 'package:ride_relay/features/settings/unit_settings_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('settings can hide and restore route progress', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final mapStyle = await MapStyleModeController.load();
    final riderProfile = await RiderProfileController.load();
    final speedLimit = SpeedLimitDisplayController.inMemory();
    final routeProgress = RouteProgressDisplayController.inMemory();
    addTearDown(mapStyle.dispose);
    addTearDown(riderProfile.dispose);
    addTearDown(speedLimit.dispose);
    addTearDown(routeProgress.dispose);

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
            routeProgressDisplay: routeProgress,
            embedded: true,
          ),
        ),
      ),
    );

    final toggle = find.byKey(const Key('route-progress-display-toggle'));
    await tester.ensureVisible(toggle);
    expect(toggle, findsOneWidget);
    expect(routeProgress.enabled, isTrue);

    await tester.tap(toggle);
    await tester.pump();
    expect(routeProgress.enabled, isFalse);

    await tester.tap(toggle);
    await tester.pump();
    expect(routeProgress.enabled, isTrue);
  });
}
