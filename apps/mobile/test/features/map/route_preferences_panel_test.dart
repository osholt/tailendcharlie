import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/route_preferences.dart';
import 'package:ride_relay/features/map/route_preferences_panel.dart';

void main() {
  Future<List<RoutePreferences>> pumpPanel(
    WidgetTester tester,
    RoutePreferences initial,
  ) async {
    final changes = <RoutePreferences>[];
    var current = initial;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => SingleChildScrollView(
              child: RoutePreferencesPanel(
                preferences: current,
                onChanged: (value) => setState(() {
                  changes.add(value);
                  current = value;
                }),
              ),
            ),
          ),
        ),
      ),
    );
    return changes;
  }

  testWidgets('unsurfaced byways are avoided until a rider says otherwise', (
    tester,
  ) async {
    final changes = await pumpPanel(tester, RoutePreferences.defaults);

    final byways = find.byKey(const Key('avoid-unsurfaced-byways-switch'));
    await tester.ensureVisible(byways);
    expect(
      tester.widget<SwitchListTile>(byways).value,
      isTrue,
      reason: 'the documented default is to avoid them',
    );

    await tester.tap(find.byKey(const Key('avoid-motorways-switch')));
    await tester.pumpAndSettle();
    expect(changes.last.avoidMotorways, isTrue);
    // Avoiding motorways alone is not a byway decision, and vice versa.
    expect(changes.last.bywaySurface, BywaySurfacePreference.avoidUnsurfaced);
    expect(changes.last.style, RouteStyle.quickest);
  });

  testWidgets('a rider can ask for byways', (tester) async {
    final changes = await pumpPanel(
      tester,
      const RoutePreferences(style: RouteStyle.twisty),
    );

    final byways = find.byKey(const Key('avoid-unsurfaced-byways-switch'));
    await tester.ensureVisible(byways);
    await tester.tap(byways);
    await tester.pumpAndSettle();

    expect(changes.last.style, RouteStyle.twisty);
    expect(changes.last.bywaySurface, BywaySurfacePreference.allowUnsurfaced);
    expect(changes.last.requiresMotorcycleCosting, isTrue);
  });
}
