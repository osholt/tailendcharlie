import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/distance_unit.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/domain/ride_plan.dart';
import 'package:ride_relay/features/map/route_review_screen.dart';
import 'package:ride_relay/services/basemap_configuration.dart';
import 'package:ride_relay/services/biker_place_catalogue.dart';
import 'package:ride_relay/services/discovery_layer_preferences.dart';
import 'package:ride_relay/services/motorcycle_discovery.dart';
import 'package:ride_relay/services/place_memory.dart';
import 'package:ride_relay/services/ride_plan_router.dart';
import 'package:ride_relay/services/road_routing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #937 through the real plan surface: places chosen there are remembered,
/// saved places are offered in its pickers, and a stop or dropped pin can be
/// saved from its row. Synthetic coordinates; none is a rider's home.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  const here = GeoPoint(latitude: 52.00, longitude: -1.00);
  const cafe = GeoPoint(latitude: 52.10, longitude: -1.00);
  const town = GeoPoint(latitude: 52.30, longitude: -1.00);
  const pin = GeoPoint(latitude: 52.20, longitude: -1.05);

  Future<_Search> open(WidgetTester tester, RidePlan plan) async {
    final search = _Search();
    final router = RidePlanRouter(routingService: _Routing());
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => RouteReviewScreen.showPlan(
                context,
                planning: RidePlanEditing(
                  plan: plan,
                  route: (plan, location) =>
                      router.route(plan, currentLocation: location),
                  searchService: search,
                  currentLocation: ValueNotifier<GeoPoint?>(here),
                ),
                distanceUnit: DistanceUnit.kilometres,
                basemapConfiguration: const BasemapConfiguration(),
                pointOfInterestLoader: () async => BikerPlaceCatalogue.empty,
                discoveryLoader: () async =>
                    const MotorcycleDiscoveryCatalogue([]),
                discoveryPreferencesLoader: DiscoveryLayerPreferences.load,
              ),
              child: const Text('plan'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('plan'));
    await tester.pumpAndSettle();
    return search;
  }

  Future<void> tapVisible(WidgetTester tester, Key key) async {
    final finder = find.byKey(key);
    await tester.scrollUntilVisible(
      finder,
      200,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  testWidgets('a stop chosen on the plan is remembered', (tester) async {
    final search = await open(
      tester,
      const RidePlan(
        destination: RidePlanPlace(point: town, label: 'Town'),
      ),
    );
    search.results['cafe'] = [
      const DestinationMatch(label: 'Cafe, Shire, England', point: cafe),
    ];

    await tapVisible(tester, const Key('ride-plan-add-stop'));
    await tester.enterText(find.byKey(const Key('place-search-field')), 'cafe');
    await tester.tap(find.byKey(const Key('place-search-submit')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('place-search-result-Cafe, Shire, England')),
    );
    await tester.pumpAndSettle();

    final memory = await PlaceMemory.open();
    addTearDown(memory.dispose);
    expect(memory.recents.single.label, 'Cafe');
    expect(memory.recents.single.point.latitude, 52.10);
  });

  testWidgets('Home is offered when changing the destination, and goes onto '
      'the plan named Home', (tester) async {
    final seeded = await PlaceMemory.open();
    await seeded.setHome(
      const RidePlanPlace(
        point: cafe,
        label: '12 Example Road',
        description: '12 Example Road, Shire, England',
      ),
    );
    seeded.dispose();
    await open(
      tester,
      const RidePlan(
        destination: RidePlanPlace(point: town, label: 'Town'),
      ),
    );

    await tapVisible(tester, const Key('ride-plan-change-destination'));
    await tester.tap(find.byKey(const Key('place-search-saved-home')));
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byKey(const Key('ride-plan-destination')),
        matching: find.text('Home'),
      ),
      findsOneWidget,
    );
  });

  for (final row in [
    'ride-plan-change-start',
    'ride-plan-change-destination',
    'ride-plan-add-stop',
  ]) {
    testWidgets('$row: Work can be set from the rider\'s location, not only '
        'from a search', (tester) async {
      await open(
        tester,
        const RidePlan(
          destination: RidePlanPlace(point: town, label: 'Town'),
        ),
      );

      await tapVisible(tester, Key(row));
      await tester.tap(find.byKey(const Key('place-search-add-work')));
      await tester.pumpAndSettle();
      // A start picker has "Your location" of its own beneath the one in the
      // picker that chooses where Work is.
      final offered = find.byKey(const Key('place-search-current-location'));
      expect(
        offered,
        row == 'ride-plan-change-start' ? findsNWidgets(2) : findsOneWidget,
      );
      await tester.tap(offered.last);
      await tester.pumpAndSettle();

      final memory = await PlaceMemory.open();
      addTearDown(memory.dispose);
      expect(memory.work!.point.latitude, here.latitude);
      expect(memory.work!.point.longitude, here.longitude);
    });
  }

  testWidgets('a pin dropped on the plan can be saved as Work from its row', (
    tester,
  ) async {
    await open(
      tester,
      RidePlan(
        destination: RidePlanPlace(
          point: pin,
          label: RidePlanPlace.droppedPinLabel,
        ),
      ),
    );

    await tapVisible(tester, const Key('ride-plan-save-destination'));
    expect(find.byKey(const Key('save-place-chooser')), findsOneWidget);
    await tester.tap(find.byKey(const Key('save-place-as-work')));
    await tester.pumpAndSettle();

    expect(find.text('Saved as Work'), findsOneWidget);
    final memory = await PlaceMemory.open();
    addTearDown(memory.dispose);
    expect(memory.work!.point.latitude, 52.20);
    expect(memory.work!.point.longitude, -1.05);
    expect(memory.work!.description, isNull, reason: 'a pin has no address');
    expect(memory.recents, isEmpty, reason: 'saving is not choosing');
  });
}

class _Search implements DestinationSearchService {
  final results = <String, List<DestinationMatch>>{};

  @override
  Future<List<DestinationMatch>> search(String query) async =>
      results[query.toLowerCase()] ?? const [];
}

class _Routing implements RoadRoutingService, ShapingPointRoadRoutingService {
  Future<RoadRouteResult> _route(List<GeoPoint> waypoints) async =>
      RoadRouteResult(
        points: waypoints,
        distanceMeters: 20000,
        duration: const Duration(minutes: 30),
        maneuvers: [
          RoadRouteManeuver(position: waypoints.last, type: 'arrive'),
        ],
      );

  @override
  Future<RoadRouteResult> routeThrough(
    List<GeoPoint> waypoints, {
    RoutePreferences? preferences,
    double? originBearingDegrees,
  }) => _route(waypoints);

  @override
  Future<RoadRouteResult> routeThroughShapingPoints(
    List<GeoPoint> waypoints, {
    required Set<int> shapingPointIndexes,
    double shapingPointSearchRadiusMeters = 0,
    RoutePreferences? preferences,
    RoadRoutingCosting costing = RoadRoutingCosting.preferred,
    double? originBearingDegrees,
  }) => _route(waypoints);
}
