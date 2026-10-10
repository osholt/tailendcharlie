import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/distance_unit.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/domain/ride_plan.dart';
import 'package:ride_relay/features/map/fuel_stop_flow.dart';
import 'package:ride_relay/features/map/route_review_screen.dart';
import 'package:ride_relay/internet/internet_relay_client.dart';
import 'package:ride_relay/services/basemap_configuration.dart';
import 'package:ride_relay/services/biker_place_catalogue.dart';
import 'package:ride_relay/services/discovery_layer_preferences.dart';
import 'package:ride_relay/services/fuel_preference.dart';
import 'package:ride_relay/services/fuel_prices.dart';
import 'package:ride_relay/services/fuel_station_catalogue.dart';
import 'package:ride_relay/services/motorcycle_discovery.dart';
import 'package:ride_relay/services/ride_plan_router.dart';
import 'package:ride_relay/services/road_routing.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Synthetic: a straight line north, and two pumps beside it. No real place.
const _here = GeoPoint(latitude: 52.00, longitude: -1.00);
const _town = GeoPoint(latitude: 52.30, longitude: -1.00);

FuelStationCatalogue _catalogue() => FuelStationCatalogue.fromJson({
  'schemaVersion': 1,
  'attribution': '© OpenStreetMap contributors, ODbL',
  'fuel': [
    // 0.5 km east of the line, 11 km along it.
    [5210000, -99270, 'Near Pump', 1 | 4, 0],
    // On the line, 22 km along it.
    [5220000, -100000, 'Far Pump', 1 | 4, 0],
  ],
  'charging': [],
});

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FuelStationCatalogue.debugSetShared(_catalogue());
    FuelPreferenceController.debugSetShared(
      FuelPreferenceController.inMemory(),
    );
    // No relay in this build: prices are simply not offered.
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

  test('a rider on the route searches from where they are', () {
    final query = fuelStopQueryFor(
      routePath: const [
        GeoPoint(latitude: 52.0, longitude: -1.0),
        GeoPoint(latitude: 52.3, longitude: -1.0),
      ],
      rider: const GeoPoint(latitude: 52.15, longitude: -1.0),
    )!;

    expect(query.routeAhead!.first.latitude, closeTo(52.15, 1e-6));
    expect(query.routeAhead!.last.latitude, 52.3);
  });

  test('a rider off the route searches the whole route; none at all, '
      'around the rider', () {
    final planned = fuelStopQueryFor(
      routePath: const [
        GeoPoint(latitude: 52.0, longitude: -1.0),
        GeoPoint(latitude: 52.3, longitude: -1.0),
      ],
      rider: const GeoPoint(latitude: 51.0, longitude: -1.0),
    )!;
    expect(planned.routeAhead!.first.latitude, 52.0);

    final noRoute = fuelStopQueryFor(
      rider: const GeoPoint(latitude: 51.0, longitude: -1.0),
    )!;
    expect(noRoute.hasRoute, isFalse);
    expect(noRoute.origin!.latitude, 51.0);

    expect(fuelStopQueryFor(), isNull);
  });

  testWidgets('Navigate to fuel on the plan adds the chosen pump as a stop', (
    tester,
  ) async {
    final routing = _StraightRouting();
    final router = RidePlanRouter(routingService: routing);
    RidePlanOutcome? outcome;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                outcome = await RouteReviewScreen.showPlan(
                  context,
                  planning: RidePlanEditing(
                    plan: RidePlan.toDestination(
                      const RidePlanPlace(point: _town, label: 'Town'),
                    ),
                    route: (plan, location) =>
                        router.route(plan, currentLocation: location),
                    searchService: _NoSearch(),
                    currentLocation: ValueNotifier<GeoPoint?>(_here),
                    acquireCurrentLocation: () async => _here,
                    confirmLabel: (_) => 'Start',
                  ),
                  distanceUnit: DistanceUnit.kilometres,
                  basemapConfiguration: const BasemapConfiguration(),
                  pointOfInterestLoader: () async => BikerPlaceCatalogue.empty,
                  discoveryLoader: () async =>
                      const MotorcycleDiscoveryCatalogue([]),
                  discoveryPreferencesLoader: DiscoveryLayerPreferences.load,
                );
              },
              child: const Text('plan'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('plan'));
    await tester.pumpAndSettle();

    final button = find.byKey(const Key('fuel-stop-button'));
    final list = find
        .descendant(
          of: find.byType(ListView),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(button, 120, scrollable: list);
    expect(find.text('Navigate to fuel'), findsOneWidget);
    await tester.tap(button);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    expect(find.text('Fuel ahead on your route'), findsOneWidget);
    expect(
      find.text(
        'Prices are not available yet. Stations are ranked by distance.',
      ),
      findsOneWidget,
    );
    // 11 km plus a 1.3 km detour counted twice beats 22 km on the line.
    final first = find.byKey(const Key('fuel-stop-candidate-0'));
    expect(
      find.descendant(of: first, matching: find.text('Near Pump')),
      findsOneWidget,
    );
    await tester.tap(
      find.descendant(of: first, matching: find.text('Add stop')),
    );
    await tester.pumpAndSettle();

    final waypoints = routing.calls.last;
    expect(waypoints, hasLength(3));
    expect(waypoints[1].latitude, closeTo(52.1, 1e-6));

    await tester.tap(find.byKey(const Key('confirm-reviewed-route')));
    await tester.pumpAndSettle();
    final stop = outcome!.route.waypoints[1];
    expect(stop.name, 'Near Pump');
    expect(stop.symbol, fuelStopSymbol);
  });
}

class _StraightRouting
    implements RoadRoutingService, ShapingPointRoadRoutingService {
  final calls = <List<GeoPoint>>[];

  Future<RoadRouteResult> _route(List<GeoPoint> waypoints) async {
    calls.add(waypoints);
    return RoadRouteResult(
      points: waypoints,
      distanceMeters: 33000,
      duration: const Duration(minutes: 30),
      maneuvers: [RoadRouteManeuver(position: waypoints.last, type: 'arrive')],
    );
  }

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

class _NoSearch implements DestinationSearchService {
  @override
  Future<List<DestinationMatch>> search(String query) async => const [];
}
