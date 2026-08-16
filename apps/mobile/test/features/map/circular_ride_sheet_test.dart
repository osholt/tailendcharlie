import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/distance_unit.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/features/map/circular_ride_sheet.dart';
import 'package:ride_relay/services/circular_ride_planner.dart';

void main() {
  testWidgets('returns direction distance and road character', (tester) async {
    CircularRideRequest? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () async {
                result = await CircularRideSheet.show(
                  context,
                  start: const GeoPoint(latitude: 51.46, longitude: -2.51),
                  distanceUnit: DistanceUnit.miles,
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('circular-direction-SW')));
    await tester.enterText(find.byKey(const Key('circular-distance')), '100');
    await tester.ensureVisible(find.byKey(const Key('generate-circular-ride')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('generate-circular-ride')));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.direction, CircularRideDirection.southWest);
    expect(result!.distanceMeters, closeTo(160934.4, 0.1));
    expect(result!.preferences.style, RouteStyle.flowing);
    expect(result!.preferences.avoidMotorways, isTrue);
  });

  testWidgets('day preset supplies distance and break frequency', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: CircularRideSheet(
            start: GeoPoint(latitude: 51.46, longitude: -2.51),
            distanceUnit: DistanceUnit.kilometres,
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('circular-day-length')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Half day').last);
    await tester.pumpAndSettle();

    final distance = tester.widget<TextFormField>(
      find.byKey(const Key('circular-distance')),
    );
    expect(distance.controller!.text, '220');
    expect(find.byKey(const Key('circular-fuel-frequency')), findsOneWidget);
    expect(find.byKey(const Key('circular-comfort-frequency')), findsOneWidget);
    expect(find.byKey(const Key('circular-meal-time')), findsOneWidget);
  });
}
