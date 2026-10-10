import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/geo_point.dart';
import 'package:ride_relay/services/fuel_preference.dart';
import 'package:ride_relay/services/fuel_prices.dart';
import 'package:ride_relay/services/fuel_station_catalogue.dart';
import 'package:ride_relay/services/fuel_stop_finder.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, Object?> _layer() => {
  'schemaVersion': 1,
  'attribution': '© OpenStreetMap contributors, ODbL',
  'extractDate': '2026-10-10',
  'boundedRegion': 'Test region',
  'coverageCaveat': 'Not every station is mapped.',
  'fuel': [
    [5210000, -190000, 'Example Garage', 1 | 4, 2],
    [5250000, -190000, 'Fuel station', 0, 0],
    ['bad', 0, 'Malformed', 0, 0],
  ],
  'charging': [
    [5212000, -190000, 'Example Charge', 2 | 1, 150],
    [5213000, -190000, 'Charger', 0, 0],
  ],
};

void main() {
  group('the bundled layer', () {
    test('reads compact rows and skips a malformed one', () {
      final catalogue = FuelStationCatalogue.fromJson(_layer());

      expect(catalogue.stations, hasLength(4));
      final garage = catalogue.stations.first;
      expect(garage.id, 'fuel:5210000:-190000');
      expect(garage.point, const GeoPoint(latitude: 52.1, longitude: -1.9));
      expect(garage.label, 'Example Garage');
      final charger = catalogue.stations.firstWhere(
        (station) => station.label == 'Example Charge',
      );
      expect(charger.kind, FuelStationKind.charging);
      expect(charger.chargerSummary, 'Type 2, CCS · 150 kW');
      expect(catalogue.stations.last.chargerSummary, 'Connectors not recorded');
      expect(catalogue.attribution, '© OpenStreetMap contributors, ODbL');
    });

    test('refuses a layer version it does not know', () {
      expect(
        () => FuelStationCatalogue.fromJson({..._layer(), 'schemaVersion': 2}),
        throwsFormatException,
      );
    });

    test('answers a box, by kind', () {
      final catalogue = FuelStationCatalogue.fromJson(_layer());

      final near = catalogue.within(
        west: -2.0,
        south: 52.05,
        east: -1.8,
        north: 52.15,
      );
      expect(near.map((station) => station.label), [
        'Example Garage',
        'Example Charge',
        'Charger',
      ]);
      expect(
        catalogue
            .within(
              west: -2.0,
              south: 52.0,
              east: -1.8,
              north: 52.6,
              kind: FuelStationKind.fuel,
            )
            .map((station) => station.label),
        ['Example Garage', 'Fuel station'],
      );
    });

    test('compatibility follows what is mapped', () {
      final catalogue = FuelStationCatalogue.fromJson(_layer());
      final garage = catalogue.stations[0];
      final unlisted = catalogue.stations[1];
      final charger = catalogue.stations[2];

      expect(
        garage.compatibilityWith(const FuelPreference(FuelKind.e10)),
        FuelCompatibility.known,
      );
      expect(
        garage.compatibilityWith(const FuelPreference(FuelKind.e5)),
        FuelCompatibility.incompatible,
      );
      expect(
        unlisted.compatibilityWith(const FuelPreference(FuelKind.diesel)),
        FuelCompatibility.unrecorded,
      );
      expect(
        garage.compatibilityWith(const FuelPreference(FuelKind.electric)),
        FuelCompatibility.incompatible,
      );
      expect(
        charger.compatibilityWith(
          const FuelPreference(
            FuelKind.electric,
            connectors: {ChargerConnector.chademo},
          ),
        ),
        FuelCompatibility.incompatible,
      );
      expect(
        charger.compatibilityWith(const FuelPreference(FuelKind.electric)),
        FuelCompatibility.known,
      );
    });

    test(
      'the bundled asset loads and labels nothing with an identifier',
      () async {
        TestWidgetsFlutterBinding.ensureInitialized();
        final catalogue = await FuelStationCatalogue.loadAsset();

        expect(
          catalogue.stations
              .where((s) => s.kind == FuelStationKind.fuel)
              .length,
          greaterThan(5000),
        );
        expect(
          catalogue.stations
              .where((s) => s.kind == FuelStationKind.charging)
              .length,
          greaterThan(1000),
        );
        expect(catalogue.attribution, contains('OpenStreetMap'));
        final identifier = RegExp(
          r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-|(?<![0-9A-Za-z])[0-9a-fA-F]{16,}',
        );
        expect(
          catalogue.stations.where((s) => identifier.hasMatch(s.label)),
          isEmpty,
        );
      },
    );
  });

  group('the fuel preference', () {
    test('round-trips through its stored form', () {
      for (final preference in const [
        FuelPreference(FuelKind.e10),
        FuelPreference(FuelKind.e5),
        FuelPreference(FuelKind.diesel),
        FuelPreference(FuelKind.electric),
        FuelPreference(
          FuelKind.electric,
          connectors: {ChargerConnector.ccs, ChargerConnector.type2},
        ),
      ]) {
        expect(FuelPreference.decode(preference.encode()), preference);
      }
      expect(FuelPreference.decode('hydrogen'), isNull);
      expect(
        const FuelPreference(
          FuelKind.electric,
          connectors: {ChargerConnector.ccs},
        ).searchLabel,
        'Navigate to charger',
      );
      expect(const FuelPreference(FuelKind.e5).searchLabel, 'Navigate to fuel');
    });

    test('is remembered on the phone', () async {
      SharedPreferences.setMockInitialValues({});
      final first = await FuelPreferenceController.load();
      expect(first.value, FuelPreferenceController.defaultPreference);

      await first.set(
        const FuelPreference(
          FuelKind.electric,
          connectors: {ChargerConnector.type2},
        ),
      );
      final second = await FuelPreferenceController.load();

      expect(second.value.kind, FuelKind.electric);
      expect(second.value.connectors, {ChargerConnector.type2});
    });
  });

  group('finding a stop', () {
    test('searches the layer, prices fuel and credits every source', () async {
      final requested = <List<FuelPriceTile>>[];
      final finder = FuelStopFinder(
        catalogue: () async => FuelStationCatalogue.fromJson(_layer()),
        preference: FuelPreferenceController.inMemory(),
        fetchPrices: (tiles) async {
          requested.add(tiles);
          return FuelPriceResult(
            FuelPriceAvailability.available,
            parseFuelPriceResponse({
              'schemaVersion': 1,
              'sources': [
                {
                  'id': 'uk-fuel-finder',
                  'attribution': 'OGL v3.0, Fuel Finder',
                  'currency': 'GBP',
                  'checkedAt': '2026-10-10T08:55:00Z',
                  'reportErrorUrl': 'https://www.gov.uk/report',
                },
              ],
              'stations': [
                {
                  'id': 'uk:1',
                  'source': 'uk-fuel-finder',
                  'lat': 52.1,
                  'lon': -1.9,
                  'prices': {
                    'e10': {'minorPerLitre': 141.9},
                  },
                },
              ],
            }, fetchedAt: DateTime.utc(2026, 10, 10, 9)),
          );
        },
        clock: () => DateTime.utc(2026, 10, 10, 9, 5),
      );

      final result = await finder.find(
        const FuelStopQuery(origin: GeoPoint(latitude: 52.0, longitude: -1.9)),
      );

      expect(requested, hasLength(1));
      expect(result.prices, FuelPriceAvailability.available);
      expect(result.alongRoute, isFalse);
      expect(result.candidates.first.option.station.label, 'Example Garage');
      expect(result.candidates.first.option.quote?.minorPerLitre, 141.9);
      expect(result.attributions, [
        '© OpenStreetMap contributors, ODbL',
        'OGL v3.0, Fuel Finder',
      ]);
      expect(result.reportErrorUrls, [Uri.parse('https://www.gov.uk/report')]);
    });

    test('a charger search asks for no fuel prices', () async {
      var asked = false;
      final finder = FuelStopFinder(
        catalogue: () async => FuelStationCatalogue.fromJson(_layer()),
        preference: FuelPreferenceController.inMemory(
          const FuelPreference(FuelKind.electric),
        ),
        fetchPrices: (tiles) async {
          asked = true;
          return FuelPriceResult(
            FuelPriceAvailability.available,
            FuelPriceSnapshot.empty,
          );
        },
      );

      final result = await finder.find(
        const FuelStopQuery(origin: GeoPoint(latitude: 52.1, longitude: -1.9)),
      );

      expect(asked, isFalse);
      expect(result.candidates.map((c) => c.option.station.label), [
        'Example Charge',
        'Charger',
      ]);
    });
  });
}
