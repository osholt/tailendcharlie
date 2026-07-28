import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/features/ride/active_ride_shell.dart';

void main() {
  testWidgets('the leader Leave flow offers end for everyone directly', (
    tester,
  ) async {
    RideExitDecision? decision;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => FilledButton(
            onPressed: () async {
              decision = await showRideExitDialog(context, isLeader: true);
            },
            child: const Text('Open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.text('Leave or end this ride?'), findsOneWidget);
    expect(find.byKey(const Key('leave-only-this-phone')), findsOneWidget);
    expect(find.byKey(const Key('end-ride-for-everyone')), findsOneWidget);

    await tester.tap(find.byKey(const Key('end-ride-for-everyone')));
    await tester.pumpAndSettle();

    expect(decision, RideExitDecision.endForEveryone);
  });

  testWidgets('a rider cannot end the ride for everyone', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => FilledButton(
            onPressed: () => showRideExitDialog(context, isLeader: false),
            child: const Text('Open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.text('Leave this ride?'), findsOneWidget);
    expect(find.byKey(const Key('end-ride-for-everyone')), findsNothing);
    expect(find.text('Leave ride'), findsOneWidget);
  });
}
