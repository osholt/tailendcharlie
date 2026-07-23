import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/features/map/navigation_export_sheet.dart';
import 'package:ride_relay/services/navigation_export.dart';

void main() {
  testWidgets('labels direct and GPX-share handoffs honestly', (tester) async {
    NavigationTarget? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () async {
                selected = await NavigationExportSheet.show(context);
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.text('Google Maps'), findsOneWidget);
    expect(find.text('Waze'), findsOneWidget);
    expect(find.text('Calimoto'), findsOneWidget);
    expect(find.textContaining('final destination only'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('BMW Motorrad'),
      180,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('MyRoute-app'), findsOneWidget);
    expect(find.text('Garmin'), findsOneWidget);
    expect(find.text('BMW Motorrad'), findsOneWidget);
    expect(find.textContaining('BMW Motorrad Connected app'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Harley-Davidson'),
      180,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.textContaining('H-D app'), findsOneWidget);

    await tester.tap(find.text('Harley-Davidson'));
    await tester.pumpAndSettle();
    expect(selected, NavigationTarget.harleyDavidson);
  });
}
