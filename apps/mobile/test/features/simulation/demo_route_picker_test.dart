import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/features/simulation/demo_route_picker.dart';
import 'package:ride_relay/services/demo_route_loader.dart';

void main() {
  /// Opens the picker from a button and records what it returned.
  Future<List<DemoRoute?>> open(
    WidgetTester tester, {
    required DemoRoute current,
  }) async {
    final results = <DemoRoute?>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async => results.add(
                  await showDemoRoutePicker(context, current: current),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return results;
  }

  testWidgets('lists every bundled route, with the current one marked (#934)', (
    tester,
  ) async {
    await open(tester, current: DemoRoutes.france);

    expect(find.text('Choose a demo route'), findsOneWidget);
    for (final route in DemoRoutes.all) {
      expect(find.byKey(Key('demo-route-${route.id}')), findsOneWidget);
      expect(find.text(route.title), findsOneWidget);
    }
    Icon markerOf(DemoRoute route) => tester.widget<Icon>(
      find.descendant(
        of: find.byKey(Key('demo-route-${route.id}')),
        matching: find.byType(Icon),
      ),
    );
    expect(markerOf(DemoRoutes.france).icon, Icons.radio_button_checked);
    expect(markerOf(DemoRoutes.cotswolds).icon, Icons.radio_button_unchecked);
    // A rider chooses by country and which side the traffic keeps to.
    expect(find.textContaining('left-hand traffic'), findsOneWidget);
    expect(find.textContaining('right-hand traffic'), findsOneWidget);
  });

  testWidgets('tapping a route returns it', (tester) async {
    final results = await open(tester, current: DemoRoutes.cotswolds);

    await tester.tap(find.byKey(Key('demo-route-${DemoRoutes.france.id}')));
    await tester.pumpAndSettle();

    expect(results, [same(DemoRoutes.france)]);
  });

  testWidgets('dismissing returns nothing, which is not the default', (
    tester,
  ) async {
    final results = await open(tester, current: DemoRoutes.cotswolds);

    // Tap the scrim above the sheet.
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(results, [isNull]);
  });
}
