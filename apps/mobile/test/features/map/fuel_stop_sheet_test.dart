import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/distance_unit.dart';
import 'package:ride_relay/domain/geo_point.dart';
import 'package:ride_relay/features/home/home_destination_search.dart';
import 'package:ride_relay/features/map/fuel_stop_flow.dart';
import 'package:ride_relay/features/map/fuel_stop_sheet.dart';
import 'package:ride_relay/features/settings/fuel_preference_settings.dart';
import 'package:ride_relay/services/fuel_preference.dart';
import 'package:ride_relay/services/fuel_prices.dart';
import 'package:ride_relay/services/fuel_station_catalogue.dart';
import 'package:ride_relay/services/fuel_stop_finder.dart';
import 'package:ride_relay/services/fuel_stop_ranking.dart';
import 'package:ride_relay/services/road_routing.dart';

final _now = DateTime.utc(2026, 10, 10, 9, 5);

FuelStopCandidate _candidate({
  required String label,
  double reach = 4200,
  double detour = 600,
  bool alongRoute = true,
  FuelPriceQuote? quote,
  DateTime? checkedAt,
  FuelStationKind kind = FuelStationKind.fuel,
  int sells = 1,
}) => FuelStopCandidate(
  option: FuelStopOption(
    station: FuelStation(
      id: 'fuel:$label',
      kind: kind,
      point: const GeoPoint(latitude: 52.1, longitude: -1.9),
      label: label,
      sells: sells,
    ),
    quote: quote,
    source: quote == null
        ? null
        : FuelPriceSource(
            id: 'uk-fuel-finder',
            name: 'Fuel Finder',
            attribution: 'OGL',
            currency: 'GBP',
            checkedAt: checkedAt,
          ),
    fetchedAt: quote == null ? null : _now,
  ),
  compatibility: sells == 0
      ? FuelCompatibility.unrecorded
      : FuelCompatibility.known,
  reachMetres: reach,
  detourMetres: detour,
  priceDifference: null,
  costMetres: reach + 2 * detour,
  alongRoute: alongRoute,
);

FuelStopSearchResult _result(
  List<FuelStopCandidate> candidates, {
  FuelPriceAvailability prices = FuelPriceAvailability.available,
  FuelPreference preference = const FuelPreference(FuelKind.e10),
  bool alongRoute = true,
}) => FuelStopSearchResult(
  preference: preference,
  candidates: candidates,
  prices: prices,
  attributions: const ['© OpenStreetMap contributors, ODbL', 'OGL'],
  reportErrorUrls: prices == FuelPriceAvailability.available
      ? [Uri.parse('https://www.gov.uk/report')]
      : const [],
  alongRoute: alongRoute,
);

Future<FuelStopOption?> _open(
  WidgetTester tester,
  FuelStopSearchResult result,
) async {
  FuelStopOption? chosen;
  var closed = false;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              chosen = await showModalBottomSheet<FuelStopOption>(
                context: context,
                isScrollControlled: true,
                builder: (_) => FuelStopSheet(
                  search: Future.value(result),
                  distanceUnit: DistanceUnit.miles,
                  actionLabel: 'Add stop',
                  clock: () => _now,
                ),
              );
              closed = true;
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return closed ? chosen : null;
}

void main() {
  testWidgets('lists stops with distance, detour and a dated price, and '
      'credits every source', (tester) async {
    await _open(
      tester,
      _result([
        _candidate(
          label: 'Example Services',
          quote: const FuelPriceQuote(minorPerLitre: 142.9),
          checkedAt: _now.subtract(const Duration(minutes: 5)),
        ),
        _candidate(label: 'Example Garage', reach: 8000, detour: 100),
      ]),
    );

    expect(find.text('Fuel ahead on your route'), findsOneWidget);
    expect(find.byKey(const Key('fuel-stop-candidate-0')), findsOneWidget);
    expect(find.textContaining('2.6 mi ahead · 0.4 mi detour'), findsOneWidget);
    expect(find.textContaining('142.9p · as of'), findsOneWidget);
    expect(find.textContaining('5.0 mi ahead · on the route'), findsOneWidget);
    expect(find.text('© OpenStreetMap contributors, ODbL'), findsOneWidget);
    expect(find.byKey(const Key('fuel-stop-report-error-0')), findsOneWidget);
    expect(find.byKey(const Key('fuel-stop-price-note')), findsNothing);
  });

  testWidgets('says plainly when prices are not available yet', (tester) async {
    await _open(
      tester,
      _result([
        _candidate(label: 'Example Garage'),
      ], prices: FuelPriceAvailability.notOffered),
    );

    expect(
      find.text(
        'Prices are not available yet. Stations are ranked by distance.',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('fuel-stop-report-error-0')), findsNothing);
  });

  testWidgets('a stale price is shown as dated, never as current', (
    tester,
  ) async {
    await _open(
      tester,
      _result([
        _candidate(
          label: 'Example Services',
          quote: const FuelPriceQuote(minorPerLitre: 142.9),
          checkedAt: _now.subtract(const Duration(hours: 3)),
        ),
      ]),
    );

    expect(find.textContaining('may have changed'), findsOneWidget);
    expect(find.textContaining('as of'), findsNothing);
  });

  testWidgets('says what is missing when nothing is in reach', (tester) async {
    await _open(
      tester,
      _result(
        const [],
        preference: const FuelPreference(FuelKind.electric),
        alongRoute: false,
      ),
    );

    expect(
      find.text('No charger is mapped within 25 km of you.'),
      findsOneWidget,
    );
  });

  testWidgets('choosing one returns it', (tester) async {
    FuelStopOption? chosen;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                chosen = await showModalBottomSheet<FuelStopOption>(
                  context: context,
                  builder: (_) => FuelStopSheet(
                    search: Future.value(
                      _result([_candidate(label: 'Example Garage')]),
                    ),
                    distanceUnit: DistanceUnit.kilometres,
                    actionLabel: 'Add stop',
                    clock: () => _now,
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add stop'));
    await tester.pumpAndSettle();

    expect(chosen?.station.label, 'Example Garage');
    final place = fuelStopPlace(chosen!);
    expect(place.label, 'Example Garage');
    expect(place.symbol, fuelStopSymbol);
  });

  testWidgets('a charger says its connectors and that tariffs are not shown', (
    tester,
  ) async {
    await _open(
      tester,
      _result([
        FuelStopCandidate(
          option: const FuelStopOption(
            station: FuelStation(
              id: 'charger:1',
              kind: FuelStationKind.charging,
              point: GeoPoint(latitude: 52.1, longitude: -1.9),
              label: 'Example Charge',
              connectors: 2,
              maximumKilowatts: 150,
            ),
          ),
          compatibility: FuelCompatibility.known,
          reachMetres: 1000,
          detourMetres: 0,
          priceDifference: null,
          costMetres: 1000,
          alongRoute: false,
        ),
      ], preference: const FuelPreference(FuelKind.electric)),
    );

    expect(
      find.textContaining('CCS · 150 kW · Tariff and availability not shown'),
      findsOneWidget,
    );
  });

  testWidgets('Where to? offers the fuel search under the rider\'s wording', (
    tester,
  ) async {
    HomeSearchOutcome? outcome;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                outcome = await HomeDestinationSearchSheet.show(
                  context,
                  searchService: _NoSearch(),
                  fuelSearchLabel: 'Navigate to charger',
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Navigate to charger'), findsOneWidget);
    await tester.tap(find.byKey(const Key('home-search-fuel-stop')));
    await tester.pumpAndSettle();

    expect(
      outcome,
      isA<HomeSearchHandoff>().having(
        (handoff) => handoff.kind,
        'kind',
        HomeSearchHandoffKind.fuelStop,
      ),
    );
  });

  testWidgets('Settings changes the fuel and the connectors', (tester) async {
    final controller = FuelPreferenceController.inMemory();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: FuelPreferenceTile(controller: controller)),
      ),
    );

    expect(find.textContaining('Unleaded (E10)'), findsOneWidget);
    await tester.tap(find.byKey(const Key('fuel-preference-tile')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('fuel-preference-electric')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('fuel-preference-connector-ccs')));
    await tester.pumpAndSettle();

    expect(
      controller.value,
      const FuelPreference(
        FuelKind.electric,
        connectors: {ChargerConnector.ccs},
      ),
    );
    await tester.tap(find.byKey(const Key('fuel-preference-diesel')));
    await tester.pumpAndSettle();
    expect(controller.value, const FuelPreference(FuelKind.diesel));
  });
}

class _NoSearch implements DestinationSearchService {
  @override
  Future<List<DestinationMatch>> search(String query) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
