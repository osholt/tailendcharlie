import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/domain/ride_plan.dart';
import 'package:ride_relay/domain/route_store.dart';
import 'package:ride_relay/features/map/fuel_stop_flow.dart';
import 'package:ride_relay/features/map/ride_map_feature.dart';
import 'package:ride_relay/internet/internet_relay_client.dart';
import 'package:ride_relay/services/basemap_configuration.dart';
import 'package:ride_relay/services/fuel_preference.dart';
import 'package:ride_relay/services/fuel_prices.dart';
import 'package:ride_relay/services/fuel_station_catalogue.dart';
import 'package:ride_relay/services/gpx_import_source.dart';
import 'package:ride_relay/services/offline_tile_cache.dart';
import 'package:ride_relay/services/ride_plan_router.dart';
import 'package:ride_relay/services/road_routing.dart';
import 'package:ride_relay/services/route_importer.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Synthetic: a straight line north and two pumps. No real place or rider.
const _start = GeoPoint(latitude: 52.00, longitude: -1.00);
const _town = GeoPoint(latitude: 52.30, longitude: -1.00);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FuelStationCatalogue.debugSetShared(
      FuelStationCatalogue.fromJson({
        'schemaVersion': 1,
        'attribution': '© OpenStreetMap contributors, ODbL',
        'fuel': [
          // Behind a rider at 52.15 on the route: never offered.
          [5205000, -100000, 'Behind Pump', 5, 0],
          [5220000, -100000, 'Ahead Pump', 5, 0],
        ],
        'charging': [],
      }),
    );
    FuelPreferenceController.debugSetShared(
      FuelPreferenceController.inMemory(),
    );
    RelayFuelPriceClient.debugSetShared(
      RelayFuelPriceClient(
        configuration: const InternetRelayConfiguration(baseUri: null),
      ),
    );
  });
  tearDown(() {
    FuelStationCatalogue.debugSetShared(null);
    FuelPreferenceController.debugSetShared(null);
    RelayFuelPriceClient.debugSetShared(null);
  });

  Future<InMemoryRouteStore> pumpMap(
    WidgetTester tester, {
    ImportedRoute? route,
    Object? fuelStopRequestToken,
    ValueListenable<GeoPoint?>? currentPosition,
  }) async {
    final directory = Directory.systemTemp.createTempSync('fuel-stop');
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
          currentPosition: currentPosition,
          acquireCurrentPosition: () async => currentPosition?.value,
          destinationRoutePlanner: DestinationRoutePlanner(
            searchService: const _NoSearch(),
            routingService: _StraightRouting(),
          ),
          fuelStopRequestToken: fuelStopRequestToken,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return store;
  }

  testWidgets('asking for fuel on a route offers what is ahead and adds the '
      'choice as a stop', (tester) async {
    final route =
        (await RidePlanRouter(
              routingService: _StraightRouting(),
              idFactory: () => 'confirmed',
            ).route(
              RidePlan.toDestination(
                const RidePlanPlace(point: _town, label: 'Town'),
              ),
              currentLocation: _start,
            ))
            .route;
    final position = ValueNotifier<GeoPoint?>(
      const GeoPoint(latitude: 52.15, longitude: -1.00),
    );
    addTearDown(position.dispose);

    final store = await pumpMap(
      tester,
      route: route,
      currentPosition: position,
      fuelStopRequestToken: Object(),
    );

    expect(find.text('Fuel ahead on your route'), findsOneWidget);
    expect(find.text('Ahead Pump'), findsOneWidget);
    expect(find.text('Behind Pump'), findsNothing);

    await tester.tap(find.text('Add stop'));
    await tester.pumpAndSettle();
    // The changed route is seen on the plan surface before it is used.
    expect(find.byKey(const Key('ride-plan-itinerary')), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirm-reviewed-route')));
    await tester.pumpAndSettle();

    final saved = await store.loadActiveRoute();
    final stop = saved!.waypoints[1];
    expect(stop.name, 'Ahead Pump');
    expect(stop.symbol, fuelStopSymbol);
  });

  testWidgets('without a route or a position there is nothing to search from', (
    tester,
  ) async {
    await pumpMap(tester, fuelStopRequestToken: Object());

    expect(find.text('Fuel ahead on your route'), findsNothing);
    expect(
      find.text(
        'Your location is not known yet, so there is nowhere to search from.',
      ),
      findsOneWidget,
    );
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
    distanceMeters: 33000,
    duration: const Duration(minutes: 35),
    maneuvers: [RoadRouteManeuver(position: waypoints.last, type: 'arrive')],
  );
}

class _NoSearch implements DestinationSearchService {
  const _NoSearch();

  @override
  Future<List<DestinationMatch>> search(String query) async => const [];
}

class _NoFileSource implements GpxImportSource {
  const _NoFileSource();

  @override
  Future<PickedGpxFile?> pickGpxFile() async => null;
}
