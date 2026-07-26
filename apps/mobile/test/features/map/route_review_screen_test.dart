import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/distance_unit.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/features/map/route_review_screen.dart';
import 'package:ride_relay/services/basemap_configuration.dart';

void main() {
  test('warns when recalculation materially changes the route', () {
    final warning = materialRouteChangeWarning(
      _route(0.02),
      _route(0.04),
      DistanceUnit.kilometres,
    );

    expect(warning, contains('longer than the current route'));
  });

  test('does not warn for a small recalculation', () {
    final warning = materialRouteChangeWarning(
      _route(0.02),
      _route(0.022),
      DistanceUnit.kilometres,
    );

    expect(warning, isNull);
  });

  testWidgets('keeps disconnected imported paths visually separate', (
    tester,
  ) async {
    final route = ImportedRoute(
      id: 'segmented',
      name: 'Segmented route',
      importedAt: DateTime.utc(2026, 7, 23),
      sourceFileName: 'segmented.gpx',
      paths: const [
        RoutePath(
          kind: RoutePathKind.track,
          points: [
            GeoPoint(latitude: 51, longitude: -2),
            GeoPoint(latitude: 51.01, longitude: -2.01),
          ],
        ),
        RoutePath(
          kind: RoutePathKind.track,
          points: [
            GeoPoint(latitude: 52, longitude: -3),
            GeoPoint(latitude: 52.01, longitude: -3.01),
          ],
        ),
      ],
      waypoints: const [],
      maneuvers: const [
        RouteManeuver(
          position: GeoPoint(latitude: 51.005, longitude: -2.005),
          type: 'turn',
          modifier: 'left',
        ),
        RouteManeuver(
          position: GeoPoint(latitude: 52.005, longitude: -3.005),
          type: 'off ramp',
          modifier: 'left',
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: RouteReviewScreen(
          route: route,
          distanceUnit: DistanceUnit.kilometres,
          basemapConfiguration: const BasemapConfiguration(),
        ),
      ),
    );
    await tester.pump();

    final layer = tester.widget<PolylineLayer>(find.byType(PolylineLayer));
    expect(layer.polylines, hasLength(2));
    expect(find.text('2 turn instructions'), findsOneWidget);
    expect(find.text('1 likely marker position'), findsOneWidget);
    expect(find.text('1 junction safety review'), findsOneWidget);
    expect(find.byKey(const Key('route-review-marker-plan')), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Destination'),
      160,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('Start'), findsOneWidget);
    expect(find.text('Destination'), findsOneWidget);
  });

  testWidgets('route review opens the full manoeuvre list before the ride', (
    tester,
  ) async {
    final route = ImportedRoute(
      id: 'reviewed',
      name: 'Reviewed route',
      importedAt: DateTime.utc(2026, 7, 25),
      sourceFileName: 'reviewed.gpx',
      paths: const [
        RoutePath(
          kind: RoutePathKind.track,
          points: [
            GeoPoint(latitude: 51.45, longitude: -2.59),
            GeoPoint(latitude: 51.46, longitude: -2.59),
            GeoPoint(latitude: 51.47, longitude: -2.59),
          ],
        ),
      ],
      waypoints: const [],
      maneuvers: const [
        RouteManeuver(
          position: GeoPoint(latitude: 51.46, longitude: -2.59),
          type: 'roundabout',
          modifier: 'slight left',
          name: 'Wells Road',
          exitNumber: 2,
          drivingSide: 'left',
          bearingBeforeDegrees: 0,
          bearingAfterDegrees: 300,
        ),
        RouteManeuver(
          position: GeoPoint(latitude: 51.4602, longitude: -2.59),
          type: 'exit roundabout',
          modifier: 'slight left',
          name: 'Wells Road',
          drivingSide: 'left',
          bearingBeforeDegrees: 40,
          bearingAfterDegrees: 2,
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: RouteReviewScreen(
          route: route,
          distanceUnit: DistanceUnit.kilometres,
          basemapConfiguration: const BasemapConfiguration(),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('1 turn instruction'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const Key('review-maneuver-list')),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.byKey(const Key('review-maneuver-list')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.byKey(const Key('maneuver-list')), findsOneWidget);
    expect(find.text('2nd exit, straight on'), findsOneWidget);
  });
}

ImportedRoute _route(double longitudeDelta) => ImportedRoute(
  id: 'route-$longitudeDelta',
  name: 'Review route',
  importedAt: DateTime.utc(2026, 7, 23),
  sourceFileName: 'review.gpx',
  paths: [
    RoutePath(
      kind: RoutePathKind.track,
      points: [
        const GeoPoint(latitude: 51, longitude: -2),
        GeoPoint(latitude: 51, longitude: -2 + longitudeDelta),
      ],
    ),
  ],
  waypoints: const [],
);
