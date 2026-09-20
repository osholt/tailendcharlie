import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/distance_unit_controller.dart';
import 'package:ride_relay/controllers/map_style_mode_controller.dart';
import 'package:ride_relay/controllers/rider_profile_controller.dart';
import 'package:ride_relay/controllers/speed_limit_display_controller.dart';
import 'package:ride_relay/features/settings/unit_settings_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('Settings is a full page and profile edits return to it', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final map = await MapStyleModeController.load();
    final rider = await RiderProfileController.load();
    final speed = SpeedLimitDisplayController.inMemory();
    final units = DistanceUnitController.forLocale(const Locale('en', 'GB'));
    addTearDown(map.dispose);
    addTearDown(rider.dispose);
    addTearDown(speed.dispose);
    addTearDown(units.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => UnitSettingsSheet.show(
                context,
                units,
                map,
                rider,
                speedLimitDisplay: speed,
              ),
              child: const Text('Home settings'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Home settings'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.text('Settings'), findsOneWidget);
    await tester.tap(find.text('Profile'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('open-rider-profile')));
    await tester.pumpAndSettle();
    expect(find.text('Rider profile'), findsOneWidget);
    Navigator.of(tester.element(find.text('Rider profile'))).pop();
    await tester.pumpAndSettle();
    expect(find.byType(UnitSettingsSheet), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Home settings'), findsOneWidget);
  });
}
