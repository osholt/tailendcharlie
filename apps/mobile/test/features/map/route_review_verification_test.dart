import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/distance_unit.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/features/map/route_review_screen.dart';
import 'package:ride_relay/services/basemap_configuration.dart';
import 'package:ride_relay/services/route_reshape_planner.dart';
import 'package:ride_relay/services/route_verification.dart';

/// What checking a planned route found is shown on its review, next to the
/// route it is about, and goes when the route does (#840, #858).
void main() {
  const track = RouteVerification(
    preferences: RoutePreferences.defaults,
    checked: true,
    concerns: [
      RouteConcern(
        kind: RouteConcernKind.unsurfaced,
        lengthMeters: 576,
        labels: ['track'],
      ),
    ],
    routeMeters: 1268,
    coveredMeters: 1268,
  );
  const clean = RouteVerification(
    preferences: RoutePreferences.defaults,
    checked: true,
    routeMeters: 2852,
    coveredMeters: 2852,
  );
  const trackNotice =
      'Uses 0.4 mi of unsurfaced track, although Avoid unsurfaced byways is on.';

  Future<void> show(
    WidgetTester tester, {
    RouteVerification? verification,
    List<String> warnings = const [],
    RouteReshapeCallback? onReshapeRoute,
    RouteAlternativeCallback? onGenerateAlternative,
    ImportedRoute? route,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: RouteReviewScreen(
          route: route ?? _route(),
          distanceUnit: DistanceUnit.miles,
          basemapConfiguration: const BasemapConfiguration(),
          warnings: warnings,
          verification: verification,
          onReshapeRoute: onReshapeRoute,
          canGenerateAlternative: onGenerateAlternative != null,
          onGenerateAlternative: onGenerateAlternative,
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('a track on the route is named, with its length', (tester) async {
    await show(tester, verification: track);

    expect(find.text(trackNotice), findsOneWidget);
  });

  testWidgets('a clean route has no notice', (tester) async {
    await show(tester, verification: clean);

    expect(find.textContaining('Uses '), findsNothing);
    expect(find.textContaining('Could not check'), findsNothing);
  });

  testWidgets('a route that was not checked says so', (tester) async {
    await show(
      tester,
      verification: const RouteVerification.unchecked(
        RoutePreferences.defaults,
      ),
    );

    expect(
      find.textContaining('Could not check this route against your road'),
      findsOneWidget,
    );
  });

  testWidgets('it sits beside the planner\'s own warnings, not instead', (
    tester,
  ) async {
    await show(
      tester,
      verification: track,
      warnings: const ['The destination had 3 possible matches.'],
    );

    expect(
      find.text('The destination had 3 possible matches.'),
      findsOneWidget,
    );
    expect(find.text(trackNotice), findsOneWidget);
  });

  testWidgets('reshaping the route replaces what was found about the old one', (
    tester,
  ) async {
    // Tall, so the list builds the adjustment chip below the warning cards.
    await tester.binding.setSurfaceSize(const Size(800, 2000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final route = _route().withShapingPoints(const [
      RouteShapingPoint(
        id: 'shape-one',
        legIndex: 0,
        point: GeoPoint(latitude: 51.001, longitude: -1.99),
      ),
    ]);
    await show(
      tester,
      route: route,
      verification: track,
      warnings: const ['The destination had 3 possible matches.'],
      onReshapeRoute: (candidate, shapingPoints) async => RouteReshapeResult(
        route: candidate.withShapingPoints(shapingPoints),
        distanceMeters: 2852,
        duration: const Duration(minutes: 8),
        verification: clean,
      ),
    );
    expect(find.text(trackNotice), findsOneWidget);

    tester
        .widget<InputChip>(
          find.byKey(const Key('route-shaping-point-shape-one')),
        )
        .onDeleted!();
    await tester.pumpAndSettle();

    expect(find.text(trackNotice), findsNothing);
    expect(
      find.text('The destination had 3 possible matches.'),
      findsOneWidget,
      reason: 'the planner\'s own warnings are not about the geometry',
    );
  });

  testWidgets('a reshape that is not checked does not keep the old notice', (
    tester,
  ) async {
    final route = _route().withShapingPoints(const [
      RouteShapingPoint(
        id: 'shape-one',
        legIndex: 0,
        point: GeoPoint(latitude: 51.001, longitude: -1.99),
      ),
    ]);
    await show(
      tester,
      route: route,
      verification: track,
      onReshapeRoute: (candidate, shapingPoints) async => RouteReshapeResult(
        route: candidate.withShapingPoints(shapingPoints),
        distanceMeters: 2852,
        duration: const Duration(minutes: 8),
      ),
    );

    tester
        .widget<InputChip>(
          find.byKey(const Key('route-shaping-point-shape-one')),
        )
        .onDeleted!();
    await tester.pumpAndSettle();

    expect(find.text(trackNotice), findsNothing);
  });

  testWidgets('Another shows what was found about the new route', (
    tester,
  ) async {
    await show(
      tester,
      verification: clean,
      onGenerateAlternative: () async => RouteReviewAlternative(
        route: _route(name: 'Second ride'),
        distanceMeters: 1268,
        duration: const Duration(minutes: 5),
        verification: track,
      ),
    );
    expect(find.text(trackNotice), findsNothing);

    await tester.tap(find.byKey(const Key('generate-another-route')));
    await tester.pumpAndSettle();

    expect(find.text(trackNotice), findsOneWidget);
  });
}

ImportedRoute _route({String name = 'Review route'}) => ImportedRoute(
  id: 'route-$name',
  name: name,
  importedAt: DateTime.utc(2026, 10, 4),
  sourceFileName: 'review.gpx',
  paths: const [
    RoutePath(
      kind: RoutePathKind.track,
      points: [
        GeoPoint(latitude: 51, longitude: -2),
        GeoPoint(latitude: 51, longitude: -1.98),
      ],
    ),
  ],
  waypoints: const [],
);
