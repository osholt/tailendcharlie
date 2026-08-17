import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/features/map/discovery_layer_toggles.dart';
import 'package:ride_relay/services/discovery_layer_preferences.dart';
import 'package:ride_relay/services/motorcycle_discovery.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #593. The layer controls lived only in the map's overflow menu, and that
/// menu does not exist during a ride — `hideChrome` removes the whole app bar
/// once the navigation canvas is up. Settings is reachable in free roam, before
/// a ride and during one, so the controls live there too.
///
/// #596 is the other half: the toggles used to write through a nullable that
/// was left null whenever any one of three parallel asset reads failed, so they
/// silently did nothing.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a toggle persists and is read back', (tester) async {
    final preferences = await DiscoveryLayerPreferences.load();
    var changes = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DiscoveryLayerToggles(
            preferences: preferences,
            onChanged: () => changes += 1,
          ),
        ),
      ),
    );

    const category = MotorcycleDiscoveryCategory.twistyHighlight;
    final before = preferences.categories.contains(category);
    await tester.tap(find.byKey(Key('discovery-layer-${category.apiValue}')));
    await tester.pumpAndSettle();

    expect(preferences.categories.contains(category), !before);
    expect(changes, 1, reason: 'the host has to know to redraw');

    // Read back through a fresh load: the choice is on the phone, not just in
    // this widget's state.
    final reloaded = await DiscoveryLayerPreferences.load();
    expect(reloaded.categories.contains(category), !before);
  });

  testWidgets('a control that cannot work says so instead of doing nothing', (
    tester,
  ) async {
    // The #596 state: preferences failed to load. The toggles used to render
    // enabled and write through a `?.`, which persisted nothing and redrew
    // nothing — indistinguishable from the menu being broken.
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: DiscoveryLayerToggles(
            preferences: null,
            failures: ['the saved layer choices'],
          ),
        ),
      ),
    );

    expect(
      find.byKey(const Key('discovery-layer-load-failure')),
      findsOneWidget,
    );
    expect(find.textContaining('the saved layer choices'), findsOneWidget);
    expect(
      tester
          .widget<CheckboxListTile>(
            find.byKey(const Key('biker-cafes-layer-toggle')),
          )
          .onChanged,
      isNull,
      reason: 'a toggle that cannot persist must not pretend it can',
    );
  });

  testWidgets('the standalone sheet loads and closes', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => DiscoveryLayersScreen.show(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Map layers'), findsOneWidget);
    expect(find.byKey(const Key('biker-cafes-layer-toggle')), findsOneWidget);

    await tester.tap(find.byKey(const Key('sheet-close-button')));
    await tester.pumpAndSettle();
    expect(find.text('Map layers'), findsNothing);
  });
}
