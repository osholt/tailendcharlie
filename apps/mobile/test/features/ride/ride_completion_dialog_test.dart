import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/features/ride/active_ride_shell.dart';
import 'package:ride_relay/services/ride_completion_detector.dart';

void main() {
  const assessment = RideCompletionAssessment(
    routeProgressFraction: 0.94,
    minimumRouteProgressFraction: 0.9,
    destinationRadiusMeters: 90,
    riderCount: 4,
    freshRiderCount: 4,
    arrivedRiderCount: 4,
  );

  testWidgets('completion asks the leader instead of ending silently', (
    tester,
  ) async {
    RideCompletionDecision? decision;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => FilledButton(
            onPressed: () async {
              decision = await showRideCompletionDialog(
                context,
                assessment: assessment,
                relayCanCarryReopen: true,
              );
            },
            child: const Text('Check completion'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Check completion'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('ride-completion-suggestion')), findsOneWidget);
    expect(find.textContaining('4 of 4 riders'), findsOneWidget);
    expect(find.textContaining('94% of the route'), findsOneWidget);
    expect(
      find.textContaining('resume this ride within 24 hours'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('continue-completed-ride')));
    await tester.pumpAndSettle();
    expect(decision, RideCompletionDecision.continueRide);
  });

  testWidgets('unsupported relays warn before the leader ends', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => FilledButton(
            onPressed: () => showRideCompletionDialog(
              context,
              assessment: assessment,
              relayCanCarryReopen: false,
            ),
            child: const Text('Check completion'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Check completion'));
    await tester.pumpAndSettle();

    expect(find.textContaining('cannot resume an ended ride'), findsOneWidget);
    expect(find.byKey(const Key('confirm-completed-ride')), findsOneWidget);
  });
}
