import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/distance_unit_controller.dart';
import 'package:ride_relay/controllers/map_style_mode_controller.dart';
import 'package:ride_relay/controllers/rider_profile_controller.dart';
import 'package:ride_relay/controllers/speed_adaptive_zoom_controller.dart';
import 'package:ride_relay/controllers/speed_limit_display_controller.dart';
import 'package:ride_relay/features/settings/unit_settings_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #936: Settings can turn the speed-adaptive zoom off and on again, and it is
/// on for a rider who has never opened Settings.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> open(
    WidgetTester tester, {
    SpeedAdaptiveZoomController? zoom,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final mapStyle = await MapStyleModeController.load();
    final riderProfile = await RiderProfileController.load();
    final speedLimit = SpeedLimitDisplayController.inMemory();
    addTearDown(mapStyle.dispose);
    addTearDown(riderProfile.dispose);
    addTearDown(speedLimit.dispose);
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
            speedAdaptiveZoom: zoom,
            embedded: true,
          ),
        ),
      ),
    );
  }

  testWidgets('can turn the zoom off and back on', (tester) async {
    final zoom = SpeedAdaptiveZoomController.inMemory();
    addTearDown(zoom.dispose);
    await open(tester, zoom: zoom);

    final toggle = find.byKey(const Key('speed-adaptive-zoom-toggle'));
    await tester.ensureVisible(toggle);
    expect(toggle, findsOneWidget);
    expect(find.text('Zoom the map with speed'), findsOneWidget);
    expect(zoom.enabled, isTrue, reason: 'on by default');
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);

    await tester.tap(toggle);
    await tester.pump();
    expect(zoom.enabled, isFalse);
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);

    await tester.tap(toggle);
    await tester.pump();
    expect(zoom.enabled, isTrue);
  });

  testWidgets('shows no switch where there is nothing to switch', (
    tester,
  ) async {
    await open(tester);
    expect(find.byKey(const Key('speed-adaptive-zoom-toggle')), findsNothing);
  });
}
