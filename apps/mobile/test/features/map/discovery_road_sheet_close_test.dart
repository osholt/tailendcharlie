import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/features/map/discovery_road_sheet.dart';
import 'package:ride_relay/features/map/sheet_close_button.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/services/motorcycle_discovery.dart';

/// #592. The highlight sheet had two implicit ways out — tap the scrim, drag
/// the handle — and no explicit one. Both stop working at the size where a
/// rider most needs one: opened `isScrollControlled`, a feature carrying its
/// full research detail fills the screen, taking the scrim with it and
/// scrolling the handle out of reach. What was left was "Add to route via
/// here", which is why that read as the only way out.
void main() {
  MotorcycleDiscoveryFeature feature({required bool verbose}) =>
      MotorcycleDiscoveryFeature(
        id: 'twisty',
        category: MotorcycleDiscoveryCategory.twistyHighlight,
        name: 'A long and well researched road',
        points: const [
          GeoPoint(latitude: 51.45, longitude: -2.55),
          GeoPoint(latitude: 51.48, longitude: -2.50),
        ],
        sourceName: 'Test',
        sourceUrl: 'https://example.test/road',
        confidence: verbose ? 'high' : 'test',
        lastVerified: '2026-08-17',
        warning: verbose ? 'Caution. ' * 200 : 'Test fixture',
      );

  Future<void> openSheet(
    WidgetTester tester, {
    required bool verbose,
    VoidCallback? onAddToRoute,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => DiscoveryRoadSheet.show(
                context,
                feature: feature(verbose: verbose),
                onAddToRoute: onAddToRoute,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('a short highlight can be closed without acting on it', (
    tester,
  ) async {
    var added = false;
    await openSheet(tester, verbose: false, onAddToRoute: () => added = true);

    expect(find.byType(SheetCloseButton), findsOneWidget);
    await tester.tap(find.byKey(const Key('sheet-close-button')));
    await tester.pumpAndSettle();

    expect(find.byType(DiscoveryRoadSheet), findsNothing);
    expect(added, isFalse, reason: 'closing must not change the route');
  });

  testWidgets('a long highlight keeps its close button on screen', (
    tester,
  ) async {
    // The reported case. The button is pinned outside the scroll view, so it
    // is hittable however much research sits underneath it.
    await openSheet(tester, verbose: true);

    final button = find.byKey(const Key('sheet-close-button'));
    expect(button, findsOneWidget);

    // Scroll the detail. This is the whole point: a close button that lives
    // inside the scroll view is on screen at rest and gone the moment a rider
    // reads past the first paragraph. Asserting its position without scrolling
    // first passes either way — an earlier version of this test did, and a
    // mutation that moved the button back inside the scroll view survived it.
    await tester.drag(
      find.byType(SingleChildScrollView).last,
      const Offset(0, -400),
    );
    await tester.pumpAndSettle();

    final rect = tester.getRect(button);
    final screen = tester.getSize(find.byType(MaterialApp));
    expect(
      rect.top >= 0 && rect.bottom <= screen.height,
      isTrue,
      reason: 'close button at $rect scrolled off a ${screen.height}px screen',
    );

    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.byType(DiscoveryRoadSheet), findsNothing);
  });

  testWidgets('the add action is still there', (tester) async {
    // Guarding the obvious over-correction: a way out is not a way to remove
    // the reason the sheet exists.
    await openSheet(tester, verbose: false, onAddToRoute: () {});

    expect(find.byKey(const Key('discovery-add-to-route')), findsOneWidget);
  });
}
