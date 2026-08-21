import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/distance_unit.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/features/map/route_review_screen.dart';
import 'package:ride_relay/services/basemap_configuration.dart';
import 'package:ride_relay/services/biker_place_catalogue.dart';
import 'package:ride_relay/services/discovery_layer_preferences.dart';
import 'package:ride_relay/services/motorcycle_discovery.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ride_relay/services/route_reshape_planner.dart';

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

  testWidgets('the ride name has its own app bar line above the actions', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: RouteReviewScreen(
          route: _route(0.02, name: '80 mi north-west circular ride'),
          distanceUnit: DistanceUnit.miles,
          basemapConfiguration: const BasemapConfiguration(),
          canGenerateAlternative: true,
        ),
      ),
    );
    await tester.pump();

    final title = find.byKey(const Key('route-review-title'));
    final actions = find.byKey(const Key('route-review-actions'));
    expect(title, findsOneWidget);
    expect(actions, findsOneWidget);
    expect(
      tester.getBottomLeft(title).dy,
      lessThan(tester.getTopLeft(actions).dy),
    );
    expect(find.text('80 mi north-west circular ride'), findsOneWidget);
  });

  testWidgets('Another replaces the route without closing the review', (
    tester,
  ) async {
    final alternative = Completer<RouteReviewAlternative>();
    ImportedRoute? changedRoute;
    await tester.pumpWidget(
      MaterialApp(
        home: RouteReviewScreen(
          route: _route(0.02, name: 'First circular ride'),
          distanceUnit: DistanceUnit.miles,
          basemapConfiguration: const BasemapConfiguration(),
          canGenerateAlternative: true,
          onGenerateAlternative: () => alternative.future,
          onRouteChanged: (route) => changedRoute = route,
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('generate-another-route')));
    await tester.pump();

    expect(find.byType(RouteReviewScreen), findsOneWidget);
    expect(find.text('Creating…'), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(find.byKey(const Key('confirm-reviewed-route')))
          .onPressed,
      isNull,
    );

    final nextRoute = _route(0.04, name: 'Second circular ride');
    alternative.complete(
      RouteReviewAlternative(
        route: nextRoute,
        distanceMeters: 64000,
        duration: const Duration(hours: 2),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(RouteReviewScreen), findsOneWidget);
    expect(find.text('Second circular ride'), findsOneWidget);
    expect(changedRoute?.id, nextRoute.id);
    expect(find.text('Another'), findsOneWidget);
  });

  testWidgets('a long route can be confirmed without scrolling its points', (
    tester,
  ) async {
    final waypoints = [
      for (var index = 0; index < 102; index += 1)
        RouteWaypoint(
          point: GeoPoint(
            latitude: 51.46 + index * 0.0001,
            longitude: -2.5 + index * 0.0001,
          ),
          name: 'Point ${index + 1}',
        ),
    ];
    final route = ImportedRoute(
      id: 'long-review',
      name: 'Long review route',
      importedAt: DateTime.utc(2026, 7, 29),
      sourceFileName: 'long-review.gpx',
      paths: [
        RoutePath(
          kind: RoutePathKind.track,
          points: waypoints.map((waypoint) => waypoint.point).toList(),
        ),
      ],
      waypoints: waypoints,
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

    final confirm = find.byKey(const Key('confirm-reviewed-route'));
    expect(confirm, findsOneWidget);
    expect(tester.getTopLeft(confirm).dy, lessThan(120));
    expect(find.text('Route points (102)'), findsOneWidget);
    expect(
      find.byKey(const Key('route-review-waypoint-0')),
      findsNothing,
      reason: 'the long detail list starts collapsed',
    );

    await tester.tap(find.text('Route points (102)'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('route-review-waypoint-0')), findsOneWidget);
  });

  testWidgets(
    'route adjustments stay distinct from named stops and recalculate',
    (tester) async {
      final route = _route(0.02).withShapingPoints(const [
        RouteShapingPoint(
          id: 'shape-one',
          legIndex: 0,
          point: GeoPoint(latitude: 51.001, longitude: -1.99),
        ),
      ]);
      var reshapeCalls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: RouteReviewScreen(
            route: route,
            distanceUnit: DistanceUnit.miles,
            basemapConfiguration: const BasemapConfiguration(),
            onReshapeRoute: (candidate, shapingPoints) async {
              reshapeCalls += 1;
              return RouteReshapeResult(
                route: candidate.withShapingPoints(shapingPoints),
                distanceMeters: 1200,
                duration: const Duration(minutes: 4),
              );
            },
          ),
        ),
      );
      await tester.pump();

      expect(find.byKey(const Key('toggle-route-reshape')), findsOneWidget);
      expect(
        find.byKey(const Key('route-shaping-point-shape-one')),
        findsOneWidget,
      );
      expect(find.text('Adjustment 1'), findsOneWidget);
      expect(find.text('2 route points'), findsOneWidget);

      final chip = tester.widget<InputChip>(
        find.byKey(const Key('route-shaping-point-shape-one')),
      );
      chip.onDeleted!();
      await tester.pumpAndSettle();

      expect(reshapeCalls, 1);
      expect(
        find.byKey(const Key('route-shaping-point-shape-one')),
        findsNothing,
      );
    },
  );

  testWidgets('a mapped point of interest becomes a live route waypoint', (
    tester,
  ) async {
    ImportedRoute? recalculated;
    await tester.pumpWidget(
      MaterialApp(
        home: RouteReviewScreen(
          route: _route(0.02),
          distanceUnit: DistanceUnit.miles,
          basemapConfiguration: const BasemapConfiguration(),
          canEditStops: true,
          pointOfInterestLoader: () async => const BikerPlaceCatalogue(
            places: [
              BikerPlace(
                id: 'cafe-1',
                name: 'Rider Cafe',
                address: 'High Street',
                point: GeoPoint(latitude: 51.001, longitude: -1.99),
                source: 'Bike + Brew 2026',
              ),
            ],
          ),
          onReshapeRoute: (candidate, shapingPoints) async {
            recalculated = candidate;
            return RouteReshapeResult(
              route: candidate.withShapingPoints(shapingPoints),
              distanceMeters: 1800,
              duration: const Duration(minutes: 6),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Draw route around'), findsOneWidget);
    expect(
      tester
          .widget<FilterChip>(find.byKey(const Key('toggle-route-reshape')))
          .selected,
      isFalse,
      reason: 'the native map must receive drag and pinch gestures on entry',
    );
    expect(
      find.byKey(const Key('toggle-route-points-of-interest')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('route-point-of-interest-cafe-1')));
    await tester.pumpAndSettle();

    expect(find.text('Add as waypoint'), findsOneWidget);
    await tester.tap(find.byKey(const Key('add-point-of-interest-cafe-1')));
    await tester.pumpAndSettle();

    expect(recalculated, isNotNull);
    expect(recalculated!.waypoints.map((point) => point.name), [
      'Start',
      'Rider Cafe',
      'Destination',
    ]);
    await tester.scrollUntilVisible(
      find.text('Route points (3)'),
      160,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('Route points (3)'), findsOneWidget);
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
            GeoPoint(latitude: 52.005, longitude: -3.005),
          ],
        ),
      ],
      waypoints: const [],
      // Both manoeuvres sit on the first, longer path: the one the group rides.
      // They were on one path each until #179 stopped scoring manoeuvres that
      // lie off the ridden line - a road nobody on this ride will use cannot be
      // missed, so it earns no marking position. That rule is asserted directly
      // in test/services/route_marker_plan_test.dart; this test is about the two
      // paths staying visually separate, which they still are.
      maneuvers: const [
        RouteManeuver(
          position: GeoPoint(latitude: 51.005, longitude: -2.005),
          type: 'turn',
          modifier: 'left',
        ),
        RouteManeuver(
          position: GeoPoint(latitude: 51.0075, longitude: -2.0075),
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

  testWidgets('draws a road-matched candidate against the original line', (
    tester,
  ) async {
    final original = _route(0.02);
    final candidate = ImportedRoute(
      id: 'matched',
      name: 'Review route (navigable)',
      importedAt: DateTime.utc(2026, 8, 3),
      sourceFileName: 'matched-review.gpx',
      paths: const [
        RoutePath(
          kind: RoutePathKind.track,
          points: [
            GeoPoint(latitude: 51, longitude: -2),
            GeoPoint(latitude: 51.001, longitude: -1.99),
            GeoPoint(latitude: 51, longitude: -1.98),
          ],
        ),
      ],
      waypoints: const [],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: RouteReviewScreen(
          route: candidate,
          comparisonRoute: original,
          distanceUnit: DistanceUnit.kilometres,
          basemapConfiguration: const BasemapConfiguration(),
        ),
      ),
    );
    await tester.pump();

    final originalLayer = tester.widget<PolylineLayer>(
      find.byKey(const Key('route-review-original-line')),
    );
    expect(originalLayer.polylines, hasLength(1));
    expect(originalLayer.polylines.single.color, const Color(0xFFB8C0CC));
    final candidateLayer = tester
        .widgetList<PolylineLayer>(find.byType(PolylineLayer))
        .last;
    expect(candidateLayer.polylines.single.color, const Color(0xFF3478F6));
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

  testWidgets('a suggested marking position can be rejected and restored', (
    tester,
  ) async {
    final reviews = <MarkerPlanReview>[];
    await tester.pumpWidget(
      MaterialApp(
        home: RouteReviewScreen(
          route: _junctionRoute(),
          distanceUnit: DistanceUnit.kilometres,
          basemapConfiguration: const BasemapConfiguration(),
          onMarkerReviewChanged: reviews.add,
        ),
      ),
    );
    await tester.pump();

    final scrollable = find.byType(Scrollable).last;
    await tester.scrollUntilVisible(
      find.byKey(const Key('marker-plan-maneuver-0')),
      160,
      scrollable: scrollable,
    );
    expect(find.text('Turn left marker'), findsOneWidget);

    final reject = find.byKey(const Key('marker-plan-reject-maneuver-0'));
    await tester.scrollUntilVisible(reject, 120, scrollable: scrollable);
    await tester.ensureVisible(reject);
    await tester.pumpAndSettle();
    await tester.tap(reject);
    await tester.pump();

    expect(reviews.single.rejected.single.id, 'maneuver-0');
    expect(find.byKey(const Key('marker-plan-maneuver-0')), findsNothing);
    expect(
      find.byKey(const Key('marker-plan-rejected-maneuver-0')),
      findsOneWidget,
    );

    final restore = find.byKey(const Key('marker-plan-restore-maneuver-0'));
    await tester.scrollUntilVisible(restore, 120, scrollable: scrollable);
    await tester.ensureVisible(restore);
    await tester.pumpAndSettle();
    await tester.tap(restore);
    await tester.pump();

    expect(reviews.last.rejected, isEmpty);
    expect(find.byKey(const Key('marker-plan-maneuver-0')), findsOneWidget);
  });

  testWidgets('a junction the detector missed can be added by hand', (
    tester,
  ) async {
    final reviews = <MarkerPlanReview>[];
    await tester.pumpWidget(
      MaterialApp(
        home: RouteReviewScreen(
          route: _junctionRoute(),
          distanceUnit: DistanceUnit.kilometres,
          basemapConfiguration: const BasemapConfiguration(),
          onMarkerReviewChanged: reviews.add,
        ),
      ),
    );
    await tester.pump();

    final add = find.byKey(const Key('marker-plan-add'));
    await tester.scrollUntilVisible(
      add,
      160,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.ensureVisible(add);
    await tester.pump();
    await tester.tap(add);
    await tester.pumpAndSettle();

    final candidate = find
        .descendant(
          of: find.byKey(const Key('marker-plan-candidates')),
          matching: find.byType(ListTile),
        )
        .first;
    await tester.tap(candidate);
    await tester.pumpAndSettle();

    expect(reviews.single.added, hasLength(1));
    expect(reviews.single.added.single.label, contains('Orchard Close'));

    // The added position joins the plan even though the gates dropped it: the
    // person reviewing gets the last word about a junction the detector missed.
    await tester.scrollUntilVisible(
      find.byKey(Key('marker-plan-${reviews.single.added.single.id}')),
      160,
      scrollable: find.byType(Scrollable).last,
    );
    expect(
      find.text('Added during review because the detector missed it.'),
      findsOneWidget,
    );
  });
  // #578. The review screen is where a rider looks at a whole route and
  // decides whether it is the ride they want — and it was the one surface
  // that could not show them a good road or a café next to it.
  group('discovery layers on the review screen', () {
    ImportedRoute reviewRoute() => ImportedRoute(
      id: 'review',
      name: 'Review route',
      importedAt: DateTime.utc(2026, 8, 16),
      sourceFileName: 'review.gpx',
      paths: const [
        RoutePath(
          kind: RoutePathKind.track,
          points: [
            GeoPoint(latitude: 51.45, longitude: -2.55),
            GeoPoint(latitude: 51.48, longitude: -2.50),
          ],
        ),
      ],
      waypoints: const [],
    );

    const nearbyTwisty = MotorcycleDiscoveryFeature(
      id: 'twisty-1',
      category: MotorcycleDiscoveryCategory.twistyHighlight,
      name: 'Nearby twisty road',
      points: [
        GeoPoint(latitude: 51.46, longitude: -2.53),
        GeoPoint(latitude: 51.47, longitude: -2.52),
      ],
      sourceName: 'Test',
      sourceUrl: 'https://example.test/road',
      confidence: 'test',
      lastVerified: '2026-08-16',
      warning: 'Unsurfaced in places',
    );

    Future<void> pumpReview(
      WidgetTester tester, {
      required Set<MotorcycleDiscoveryCategory> enabled,
      List<MotorcycleDiscoveryFeature> features = const [nearbyTwisty],
    }) async {
      SharedPreferences.setMockInitialValues({
        for (final category in MotorcycleDiscoveryCategory.values)
          'map_layer_discovery_${category.apiValue}_visible': enabled.contains(
            category,
          ),
      });
      await tester.pumpWidget(
        MaterialApp(
          home: RouteReviewScreen(
            route: reviewRoute(),
            distanceUnit: DistanceUnit.kilometres,
            basemapConfiguration: const BasemapConfiguration(),
            canEditStops: true,
            onReshapeRoute: (route, _) async => RouteReshapeResult(
              route: route,
              distanceMeters: 5000,
              duration: const Duration(minutes: 8),
            ),
            pointOfInterestLoader: () async => BikerPlaceCatalogue.empty,
            discoveryLoader: () async => MotorcycleDiscoveryCatalogue(features),
            discoveryPreferencesLoader: DiscoveryLayerPreferences.load,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('a highlight the rider has switched on is offered', (
      tester,
    ) async {
      await pumpReview(
        tester,
        enabled: {MotorcycleDiscoveryCategory.twistyHighlight},
      );

      expect(
        find.byKey(const Key('toggle-route-discovery-layers')),
        findsOneWidget,
      );
      expect(find.textContaining('Good roads (1)'), findsOneWidget);
    });

    testWidgets('a layer the rider switched off in free roam stays off here', (
      tester,
    ) async {
      // The point is that this is the *same* preference, not a second one.
      await pumpReview(tester, enabled: const {});

      expect(
        find.byKey(const Key('toggle-route-discovery-layers')),
        findsNothing,
      );
    });

    testWidgets('a highlight far from the route is not offered', (
      tester,
    ) async {
      await pumpReview(
        tester,
        enabled: {MotorcycleDiscoveryCategory.twistyHighlight},
        features: const [
          MotorcycleDiscoveryFeature(
            id: 'far-away',
            category: MotorcycleDiscoveryCategory.twistyHighlight,
            name: 'Somewhere else entirely',
            points: [GeoPoint(latitude: 57.0, longitude: -4.0)],
            sourceName: 'Test',
            sourceUrl: 'https://example.test/far',
            confidence: 'test',
            lastVerified: '2026-08-16',
            warning: 'Test fixture',
          ),
        ],
      );

      expect(
        find.byKey(const Key('toggle-route-discovery-layers')),
        findsNothing,
      );
    });
  });
}

/// A route with one genuine left turn the group takes, plus a side road it rides
/// straight past. The straight-through junction is the review surface's "the
/// detector missed one" candidate.
ImportedRoute _junctionRoute() => ImportedRoute(
  id: 'junctions',
  name: 'Junction route',
  importedAt: DateTime.utc(2026, 7, 27),
  sourceFileName: 'junctions.gpx',
  paths: const [
    RoutePath(
      kind: RoutePathKind.track,
      points: [
        GeoPoint(latitude: 51.5, longitude: -2.5),
        GeoPoint(latitude: 51.502, longitude: -2.5),
        GeoPoint(latitude: 51.504, longitude: -2.5),
        GeoPoint(latitude: 51.504, longitude: -2.504),
      ],
    ),
  ],
  waypoints: const [],
  maneuvers: const [
    RouteManeuver(
      position: GeoPoint(latitude: 51.504, longitude: -2.5),
      type: 'turn',
      modifier: 'left',
      bearingBeforeDegrees: 0,
      bearingAfterDegrees: 270,
    ),
    RouteManeuver(
      position: GeoPoint(latitude: 51.502, longitude: -2.5),
      type: 'turn',
      modifier: 'right',
      name: 'Orchard Close',
      bearingBeforeDegrees: 0,
      bearingAfterDegrees: 1,
    ),
  ],
);

ImportedRoute _route(double longitudeDelta, {String name = 'Review route'}) =>
    ImportedRoute(
      id: 'route-$longitudeDelta',
      name: name,
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
