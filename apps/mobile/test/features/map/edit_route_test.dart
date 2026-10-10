import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/domain/ride_plan.dart';
import 'package:ride_relay/domain/route_store.dart';
import 'package:ride_relay/features/map/ride_map_feature.dart';
import 'package:ride_relay/services/basemap_configuration.dart';
import 'package:ride_relay/services/gpx_import_source.dart';
import 'package:ride_relay/services/offline_tile_cache.dart';
import 'package:ride_relay/services/ride_plan_router.dart';
import 'package:ride_relay/services/road_routing.dart';
import 'package:ride_relay/services/route_importer.dart';
import 'package:ride_relay/services/route_preferences_memory.dart';
import 'package:ride_relay/services/route_waypoint_editor.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Synthetic places; none is a rider's start, finish or home.
const _start = GeoPoint(latitude: 52.00, longitude: -1.00);
const _cafe = GeoPoint(latitude: 52.10, longitude: -1.00);
const _pass = GeoPoint(latitude: 52.20, longitude: -1.00);
const _town = GeoPoint(latitude: 52.30, longitude: -1.00);

/// Confirming a route is not final (#847).
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<ImportedRoute> confirmedRoute() async =>
      (await RidePlanRouter(
            routingService: _StraightRouting(),
            idFactory: () => 'confirmed',
          ).route(
            RidePlan.toDestination(
              const RidePlanPlace(point: _town, label: 'Town'),
            ).addStop(const RidePlanPlace(point: _cafe, label: 'Cafe')),
            currentLocation: _start,
          ))
          .route;

  Future<InMemoryRouteStore> pumpMap(
    WidgetTester tester, {
    ImportedRoute? route,
    Object? editRouteRequestToken,
    Object? changeRouteRequestToken,
    bool rideStarted = false,
    ValueListenable<GeoPoint?>? currentPosition,
  }) async {
    final directory = Directory.systemTemp.createTempSync('edit-route');
    addTearDown(() => directory.deleteSync(recursive: true));
    final cache = OfflineTileCache(
      rootDirectory: directory,
      configuration: const BasemapConfiguration(),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );
    addTearDown(cache.dispose);
    final store = InMemoryRouteStore(route);
    await tester.pumpWidget(
      MaterialApp(
        home: RideMapScreen(
          routeStore: store,
          routeImporter: RouteImporter(source: const _NoFileSource()),
          offlineTileCache: cache,
          rideStarted: rideStarted,
          currentPosition: currentPosition,
          acquireCurrentPosition: () async => _start,
          destinationRoutePlanner: DestinationRoutePlanner(
            searchService: const _PassSearch(),
            routingService: _StraightRouting(),
          ),
          editRouteRequestToken: editRouteRequestToken,
          changeRouteRequestToken: changeRouteRequestToken,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return store;
  }

  testWidgets('a confirmed route reopens with its stops and is updated', (
    tester,
  ) async {
    final route = await confirmedRoute();
    final store = await pumpMap(
      tester,
      route: route,
      editRouteRequestToken: Object(),
    );

    expect(find.byKey(const Key('ride-plan-itinerary')), findsOneWidget);
    // Another app is offered from the plan, not only after confirming (#895).
    expect(find.byKey(const Key('ride-plan-open-with')), findsOneWidget);
    expect(find.byKey(const Key('ride-plan-stop-0')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('ride-plan-stop-0')),
        matching: find.text('Cafe'),
      ),
      findsOneWidget,
    );

    await tester.ensureVisible(find.byKey(const Key('ride-plan-add-stop')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('ride-plan-add-stop')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('place-search-field')), 'pass');
    await tester.tap(find.byKey(const Key('place-search-submit')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('place-search-result-Pass, Shire')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-reviewed-route')));
    await tester.pumpAndSettle();

    final saved = await store.loadActiveRoute();
    expect(saved?.id, route.id, reason: 'an edit keeps the route identity');
    expect(saved?.waypoints.map((waypoint) => waypoint.name), [
      'Start',
      'Cafe',
      'Pass',
      'Town',
    ]);
  });

  testWidgets(
    'an edit under way re-plans from here and drops the ridden part',
    (tester) async {
      final route = await confirmedRoute();
      // Past the cafe, on the line to town.
      const here = GeoPoint(latitude: 52.15, longitude: -1.00);
      final position = ValueNotifier<GeoPoint?>(here);
      addTearDown(position.dispose);
      final store = await pumpMap(
        tester,
        route: route,
        rideStarted: true,
        currentPosition: position,
        editRouteRequestToken: Object(),
      );

      expect(find.byKey(const Key('ride-plan-itinerary')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('ride-plan-start')),
          matching: find.text('Your location'),
        ),
        findsOneWidget,
      );
      // The cafe is behind the rider.
      expect(find.byKey(const Key('ride-plan-stop-0')), findsNothing);

      await tester.tap(find.byKey(const Key('confirm-reviewed-route')));
      await tester.pumpAndSettle();

      final saved = await store.loadActiveRoute();
      expect(saved?.id, route.id, reason: 'a revision of the same route');
      expect(saved?.waypoints.map((waypoint) => waypoint.name), [
        'Start',
        'Town',
      ]);
      expect(saved?.waypoints.first.point, here);
      expect(saved?.allPoints.first, here);
    },
  );

  testWidgets('before the first stop, an edit under way still starts here', (
    tester,
  ) async {
    final route = await confirmedRoute();
    // Ridden part of the way to the cafe: every stop is still ahead, so the
    // plan has as many places as the route, and is re-planned all the same.
    const here = GeoPoint(latitude: 52.05, longitude: -1.00);
    final position = ValueNotifier<GeoPoint?>(here);
    addTearDown(position.dispose);
    final store = await pumpMap(
      tester,
      route: route,
      rideStarted: true,
      currentPosition: position,
      editRouteRequestToken: Object(),
    );

    expect(find.byKey(const Key('ride-plan-stop-0')), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirm-reviewed-route')));
    await tester.pumpAndSettle();

    final saved = await store.loadActiveRoute();
    expect(saved?.waypoints.map((waypoint) => waypoint.name), [
      'Start',
      'Cafe',
      'Town',
    ]);
    expect(saved?.allPoints.first, here);
  });

  testWidgets('a new destination starts with the last confirmed options', (
    tester,
  ) async {
    const remembered = RoutePreferences(avoidTolls: true);
    SharedPreferences.setMockInitialValues({});
    await const RoutePreferencesMemory().remember(remembered);
    await pumpMap(tester, editRouteRequestToken: Object());

    // No route to edit: Edit route is a new plan, through a place search.
    await tester.enterText(find.byKey(const Key('place-search-field')), 'pass');
    await tester.tap(find.byKey(const Key('place-search-submit')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('place-search-result-Pass, Shire')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('ride-plan-itinerary')), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text(remembered.summary),
      120,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text(remembered.summary), findsOneWidget);
  });

  testWidgets('replacing the route offers editing it first', (tester) async {
    await pumpMap(
      tester,
      route: await confirmedRoute(),
      changeRouteRequestToken: Object(),
    );

    expect(find.byKey(const Key('edit-route-sheet-item')), findsOneWidget);
    expect(find.text('Edit this route'), findsOneWidget);
  });

  test('a café added from the map is a stop, not a new destination', () async {
    final route = await confirmedRoute();

    final plan = RidePlan.fromRoute(
      insertRouteWaypoint(
        route,
        const RouteWaypoint(
          point: GeoPoint(latitude: 52.25, longitude: -1.01),
          name: 'Biker cafe',
          symbol: 'Restaurant',
        ),
      ),
    );

    expect(plan.destination?.label, 'Town');
    expect(plan.stops.map((stop) => stop.label), ['Cafe', 'Biker cafe']);
    expect(plan.startsAtCurrentLocation, isTrue);
  });
}

class _StraightRouting implements RoadRoutingService {
  @override
  Future<RoadRouteResult> routeThrough(
    List<GeoPoint> waypoints, {
    RoutePreferences? preferences,
    double? originBearingDegrees,
  }) async => RoadRouteResult(
    points: waypoints,
    distanceMeters: 30000,
    duration: const Duration(minutes: 35),
    maneuvers: [RoadRouteManeuver(position: waypoints.last, type: 'arrive')],
  );
}

class _PassSearch implements DestinationSearchService {
  const _PassSearch();

  @override
  Future<List<DestinationMatch>> search(String query) async => const [
    DestinationMatch(label: 'Pass, Shire', point: _pass),
  ];
}

class _NoFileSource implements GpxImportSource {
  const _NoFileSource();

  @override
  Future<PickedGpxFile?> pickGpxFile() async => null;
}
