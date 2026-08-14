import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/distance_unit.dart';
import 'package:ride_relay/features/map/route_progress_panel.dart';
import 'package:ride_relay/services/route_journey_progress.dart';

void main() {
  testWidgets('shows trip, next-stop and current-time information compactly', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: RouteProgressPanel(
              distanceUnit: DistanceUnit.miles,
              showClock: true,
              progress: RouteJourneyProgress(
                remainingDistanceMeters: 16093.44,
                remainingTime: const Duration(minutes: 42),
                arrivalTime: DateTime(2026, 8, 14, 15, 42),
                nextWaypointName: 'Chippenham fuel stop',
                nextWaypointDistanceMeters: 8046.72,
                nextWaypointArrivalTime: DateTime(2026, 8, 14, 15, 20),
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.textContaining('42 min · 10.0 mi left'), findsOneWidget);
    expect(find.textContaining('Route ETA'), findsOneWidget);
    expect(find.text('Chippenham fuel stop'), findsOneWidget);
    expect(find.textContaining('5.0 mi'), findsOneWidget);
    expect(find.byKey(const Key('ride-clock')), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const Key('route-progress-panel'))).width,
      lessThanOrEqualTo(230),
    );
  });

  testWidgets('uses honest dashes before speed is known', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RouteProgressPanel(
            distanceUnit: DistanceUnit.kilometres,
            progress: const RouteJourneyProgress(
              remainingDistanceMeters: 4200,
              remainingTime: null,
              arrivalTime: null,
              nextWaypointName: 'Coffee',
              nextWaypointDistanceMeters: 2100,
              nextWaypointArrivalTime: null,
            ),
          ),
        ),
      ),
    );

    expect(find.textContaining('Time — · 4.2 km left'), findsOneWidget);
    expect(find.text('Route ETA —'), findsOneWidget);
    expect(find.textContaining('2.1 km · —'), findsOneWidget);
  });
}
