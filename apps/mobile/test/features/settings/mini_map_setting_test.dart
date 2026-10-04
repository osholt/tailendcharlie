import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/distance_unit_controller.dart';
import 'package:ride_relay/controllers/map_style_mode_controller.dart';
import 'package:ride_relay/controllers/mini_map_display_controller.dart';
import 'package:ride_relay/controllers/rider_profile_controller.dart';
import 'package:ride_relay/controllers/speed_limit_display_controller.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/features/settings/unit_settings_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #850: Settings can show or hide the group mini-map, per device. The switch
/// says what the rider would see - the role's default until they choose.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const toggleKey = Key('mini-map-display-toggle');
  const useDefaultKey = Key('mini-map-display-use-role-default');

  late MapStyleModeController mapStyle;
  late RiderProfileController riderProfile;
  late SpeedLimitDisplayController speedLimit;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    mapStyle = await MapStyleModeController.load();
    riderProfile = await RiderProfileController.load();
    speedLimit = SpeedLimitDisplayController.inMemory();
  });

  tearDown(() {
    mapStyle.dispose();
    riderProfile.dispose();
    speedLimit.dispose();
  });

  Future<void> pumpSettings(
    WidgetTester tester,
    MiniMapDisplayController? miniMap, {
    RideRole? role,
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: UnitSettingsSheet(
          controller: DistanceUnitController.forLocale(
            const Locale('en', 'GB'),
          ),
          mapStyleMode: mapStyle,
          riderProfile: riderProfile,
          speedLimitDisplay: speedLimit,
          miniMapDisplay: miniMap,
          miniMapRole: role,
          embedded: true,
        ),
      ),
    ),
  );

  bool switchValue(WidgetTester tester) =>
      tester.widget<SwitchListTile>(find.byKey(toggleKey)).value;

  testWidgets('shows what a follower would see: off', (tester) async {
    final miniMap = MiniMapDisplayController.inMemory();
    addTearDown(miniMap.dispose);
    await pumpSettings(tester, miniMap, role: RideRole.rider);

    await tester.ensureVisible(find.byKey(toggleKey));
    expect(find.byKey(toggleKey), findsOneWidget);
    expect(switchValue(tester), isFalse);
    expect(
      find.textContaining('On for the leader and Tail End Charlie'),
      findsOneWidget,
    );
    expect(find.byKey(useDefaultKey), findsNothing);
  });

  testWidgets('shows what the leader and the TEC would see: on', (
    tester,
  ) async {
    for (final role in [RideRole.lead, RideRole.tailEndCharlie]) {
      final miniMap = MiniMapDisplayController.inMemory();
      addTearDown(miniMap.dispose);
      await pumpSettings(tester, miniMap, role: role);

      await tester.ensureVisible(find.byKey(toggleKey));
      expect(switchValue(tester), isTrue, reason: role.name);
    }
  });

  testWidgets('shows a rider outside any ride as a follower', (tester) async {
    final miniMap = MiniMapDisplayController.inMemory();
    addTearDown(miniMap.dispose);
    await pumpSettings(tester, miniMap);

    await tester.ensureVisible(find.byKey(toggleKey));
    expect(switchValue(tester), isFalse);
  });

  testWidgets('turning it on is a choice that outranks the role', (
    tester,
  ) async {
    final miniMap = MiniMapDisplayController.inMemory();
    addTearDown(miniMap.dispose);
    await pumpSettings(tester, miniMap, role: RideRole.rider);

    await tester.ensureVisible(find.byKey(toggleKey));
    await tester.tap(find.byKey(toggleKey));
    await tester.pump();

    expect(miniMap.explicitChoice, isTrue);
    expect(switchValue(tester), isTrue);
    expect(
      find.textContaining('Your choice, whatever your role'),
      findsOneWidget,
    );
    expect(find.byKey(useDefaultKey), findsOneWidget);
  });

  testWidgets('turning it off is a choice that outranks the role', (
    tester,
  ) async {
    final miniMap = MiniMapDisplayController.inMemory();
    addTearDown(miniMap.dispose);
    await pumpSettings(tester, miniMap, role: RideRole.lead);

    await tester.ensureVisible(find.byKey(toggleKey));
    expect(switchValue(tester), isTrue);
    await tester.tap(find.byKey(toggleKey));
    await tester.pump();

    expect(miniMap.explicitChoice, isFalse);
    expect(switchValue(tester), isFalse);
  });

  testWidgets('a choice is the switch whatever role the rider holds', (
    tester,
  ) async {
    final miniMap = MiniMapDisplayController.inMemory(explicitChoice: false);
    addTearDown(miniMap.dispose);

    for (final role in [RideRole.lead, RideRole.tailEndCharlie, null]) {
      await pumpSettings(tester, miniMap, role: role);
      await tester.ensureVisible(find.byKey(toggleKey));
      expect(switchValue(tester), isFalse, reason: '${role?.name}');
    }
  });

  testWidgets('without a choice the switch follows the role as it changes', (
    tester,
  ) async {
    final miniMap = MiniMapDisplayController.inMemory();
    addTearDown(miniMap.dispose);

    await pumpSettings(tester, miniMap, role: RideRole.rider);
    await tester.ensureVisible(find.byKey(toggleKey));
    expect(switchValue(tester), isFalse);

    await pumpSettings(tester, miniMap, role: RideRole.lead);
    await tester.ensureVisible(find.byKey(toggleKey));
    expect(switchValue(tester), isTrue);
  });

  testWidgets('offers the way back to the role default, only after a choice', (
    tester,
  ) async {
    final miniMap = MiniMapDisplayController.inMemory(explicitChoice: true);
    addTearDown(miniMap.dispose);
    await pumpSettings(tester, miniMap, role: RideRole.rider);

    await tester.ensureVisible(find.byKey(useDefaultKey));
    expect(find.text('Use the default for my role'), findsOneWidget);
    await tester.tap(find.byKey(useDefaultKey));
    await tester.pump();

    expect(miniMap.hasExplicitChoice, isFalse);
    expect(switchValue(tester), isFalse, reason: 'a follower is back to off');
    expect(find.byKey(useDefaultKey), findsNothing);
  });

  testWidgets('is not offered where the host brought no controller', (
    tester,
  ) async {
    await pumpSettings(tester, null);

    expect(find.byKey(toggleKey), findsNothing);
  });
}
