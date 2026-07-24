import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/quick_message.dart';
import 'package:ride_relay/features/ride/ride_dashboard.dart';

void main() {
  testWidgets('dashboard help action uses the shell-owned local send path', (
    tester,
  ) async {
    final sent = <QuickMessage>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: QuickMessageGrid(
            busy: false,
            onSend: (message) async => sent.add(message),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Need help'));
    await tester.pump();

    expect(sent, [QuickMessage.assistance]);
  });

  testWidgets('active observer assistance exposes an explicit resolve action', (
    tester,
  ) async {
    final sent = <QuickMessage>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: QuickMessageGrid(
            busy: false,
            showResolved: true,
            onSend: (message) async => sent.add(message),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('observer-assistance-resolved')));
    await tester.pump();

    expect(sent, [QuickMessage.resolved]);
  });
}
