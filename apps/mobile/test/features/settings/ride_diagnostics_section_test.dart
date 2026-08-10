import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/ride_diagnostics_controller.dart';
import 'package:ride_relay/features/settings/ride_diagnostics_section.dart';
import 'package:ride_relay/services/ride_diagnostics_configuration.dart';

void main() {
  Future<void> pumpSection(
    WidgetTester tester,
    RideDiagnosticsController controller,
  ) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: RideDiagnosticsSection(controller: controller)),
    ),
  );

  group(
    'an ordinary build',
    () {
      testWidgets('an ordinary build offers no switch at all', (tester) async {
        // Not merely disabled: the recorder is not in the binary, so a control for
        // it would be a control that cannot work. TestControlSection renders nothing
        // in the same situation for the same reason.
        await pumpSection(tester, RideDiagnosticsController.inMemory());

        expect(find.byKey(const Key('ride-diagnostics-toggle')), findsNothing);
        expect(find.byType(SwitchListTile), findsNothing);
      });
    },
    skip: RideDiagnosticsConfiguration.enabled
        ? 'asserts the define-off build; run without RIDE_RELAY_RIDE_DIAGNOSTICS'
        : null,
  );

  group(
    'an instrumented build',
    () {
      testWidgets('an instrumented build says in plain words what it records', (
        tester,
      ) async {
        await pumpSection(tester, RideDiagnosticsController.inMemory());

        // #306, and the reasoning docs/test-control-api.md gives for why its row
        // says what it does: a rider who finds this on should not have to infer
        // "records where I went" from the word "diagnostics".
        expect(
          find.byKey(const Key('ride-diagnostics-toggle')),
          findsOneWidget,
        );
        expect(find.textContaining('own route'), findsOneWidget);
        expect(
          find.textContaining('No other rider’s position is recorded'),
          findsOneWidget,
        );
        expect(
          find.textContaining('Nothing is sent anywhere until you choose'),
          findsOneWidget,
        );
      });

      testWidgets('the switch turns recording on', (tester) async {
        final controller = RideDiagnosticsController.inMemory();
        await pumpSection(tester, controller);

        await tester.tap(find.byKey(const Key('ride-diagnostics-toggle')));
        await tester.pumpAndSettle();

        expect(controller.isOn, isTrue);
      });
    },
    skip: RideDiagnosticsConfiguration.enabled
        ? null
        : 'asserts the instrumented build; run with RIDE_RELAY_RIDE_DIAGNOSTICS',
  );
}
