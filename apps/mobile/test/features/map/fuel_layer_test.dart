import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ride_relay/domain/geo_point.dart' as geo;
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/domain/route_store.dart';
import 'package:ride_relay/features/map/discovery_layer_visibility.dart';
import 'package:ride_relay/features/map/ride_map_feature.dart';
import 'package:ride_relay/internet/internet_relay_client.dart';
import 'package:ride_relay/services/basemap_configuration.dart';
import 'package:ride_relay/services/biker_place_catalogue.dart';
import 'package:ride_relay/services/discovery_layer_preferences.dart';
import 'package:ride_relay/services/fuel_preference.dart';
import 'package:ride_relay/services/fuel_prices.dart';
import 'package:ride_relay/services/fuel_station_catalogue.dart';
import 'package:ride_relay/services/gpx_import_source.dart';
import 'package:ride_relay/services/motorcycle_discovery.dart';
import 'package:ride_relay/services/offline_tile_cache.dart';
import 'package:ride_relay/services/route_importer.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'maplibre_recording_harness.dart';

// Synthetic: a rider and two pumps nearby. No real place.
const _position = GeoPoint(latitude: 53.3, longitude: -1.8);

FuelStationCatalogue _catalogue() => FuelStationCatalogue.fromJson({
  'schemaVersion': 1,
  'attribution': '© OpenStreetMap contributors, ODbL',
  'fuel': [
    [5330400, -180000, 'North Pump', 5, 0],
    [5329600, -180000, 'South Pump', 5, 0],
    // Mapped as selling diesel and not E10: never drawn for an E10 rider.
    [5330000, -179300, 'Diesel Only', 4, 1],
  ],
  'charging': [
    [5330200, -180200, 'Corner Charger', 2, 50],
  ],
});

void main() {
  group('the visibility rule', () {
    test('follows the discovery layers, except when the rider asked', () {
      for (final context in DiscoveryLayerContext.values) {
        final browsing = discoveryLayersShownIn(context);
        expect(
          fuelLayerShownIn(
            context,
            layerEnabled: true,
            riderAskedForFuel: false,
          ),
          browsing,
          reason: '$context',
        );
        expect(
          fuelLayerShownIn(
            context,
            layerEnabled: false,
            riderAskedForFuel: false,
          ),
          isFalse,
          reason: 'switched off in $context',
        );
        expect(
          fuelLayerShownIn(
            context,
            layerEnabled: false,
            riderAskedForFuel: true,
          ),
          isTrue,
          reason: 'asked for fuel in $context',
        );
      }
    });
  });

  group('the pin label', () {
    final now = DateTime(2026, 10, 10, 14, 10).toUtc();
    FuelStopOption priced({required DateTime checkedAt, DateTime? reported}) =>
        FuelStopOption(
          station: const FuelStation(
            id: 'fuel:1',
            kind: FuelStationKind.fuel,
            point: geo.GeoPoint(latitude: 53.3, longitude: -1.8),
            label: 'Pump',
          ),
          quote: FuelPriceQuote(minorPerLitre: 142.9, reportedAt: reported),
          source: FuelPriceSource(
            id: 'uk-fuel-finder',
            name: 'Fuel Finder',
            attribution: 'OGL',
            currency: 'GBP',
            checkedAt: checkedAt,
          ),
          fetchedAt: checkedAt.add(const Duration(minutes: 1)),
        );

    test('a current price carries the time it was confirmed', () {
      final label = fuelPinLabel(
        priced(checkedAt: DateTime(2026, 10, 10, 14, 5).toUtc()),
        now,
      )!;
      expect(label.text, '142.9p · 14:05');
      expect(label.current, isTrue);
    });

    test('a stale price carries its date and is not current', () {
      final label = fuelPinLabel(
        priced(checkedAt: DateTime(2026, 10, 3, 9).toUtc()),
        now,
      )!;
      expect(label.text, '142.9p · 3 Oct');
      expect(label.current, isFalse);
    });

    test('an unconfirmed price is not put on the map', () {
      expect(
        fuelPinLabel(
          priced(
            checkedAt: DateTime(2026, 10, 10, 14, 5).toUtc(),
            reported: DateTime(2026, 8, 1).toUtc(),
          ),
          now,
        ),
        isNull,
      );
    });
  });

  test('the layer switch is remembered and on by default', () async {
    SharedPreferences.setMockInitialValues({});
    final first = await DiscoveryLayerPreferences.load();
    expect(first.fuelStationsVisible, isTrue);
    await first.setFuelStationsVisible(false);
    expect(
      (await DiscoveryLayerPreferences.load()).fuelStationsVisible,
      isFalse,
    );
  });

  group('on the map', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      FuelStationCatalogue.debugSetShared(_catalogue());
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

    testWidgets('flutter_map draws pumps for the rider fuel, not chargers', (
      tester,
    ) async {
      final cache = _cache(const BasemapConfiguration());
      addTearDown(cache.dispose);
      final position = ValueNotifier<GeoPoint?>(_position);
      addTearDown(position.dispose);
      await tester.pumpWidget(
        _screen(cache: cache, position: position, rideStarted: false),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('fuel-stations-layer')), findsOneWidget);
      expect(
        find.bySemanticsLabel(RegExp('^Fuel station: ')),
        findsNWidgets(2),
      );
      expect(find.bySemanticsLabel(RegExp('^Charger: ')), findsNothing);
      expect(find.bySemanticsLabel(RegExp('Diesel Only')), findsNothing);

      // Navigating, the pumps are hidden like the other discovery pins.
      await tester.pumpWidget(
        _screen(cache: cache, position: position, rideStarted: true),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('fuel-stations-layer')), findsNothing);
    });

    testWidgets('a rider on electric sees chargers instead', (tester) async {
      FuelPreferenceController.debugSetShared(
        FuelPreferenceController.inMemory(
          const FuelPreference(FuelKind.electric),
        ),
      );
      final cache = _cache(const BasemapConfiguration());
      addTearDown(cache.dispose);
      final position = ValueNotifier<GeoPoint?>(_position);
      addTearDown(position.dispose);
      await tester.pumpWidget(
        _screen(cache: cache, position: position, rideStarted: false),
      );
      await tester.pumpAndSettle();

      expect(find.bySemanticsLabel(RegExp('^Charger: ')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('^Fuel station: ')), findsNothing);
    });

    testWidgets('switched off in the layer menu, they are not drawn', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        DiscoveryLayerPreferences.fuelStationsKey: false,
      });
      final cache = _cache(const BasemapConfiguration());
      addTearDown(cache.dispose);
      final position = ValueNotifier<GeoPoint?>(_position);
      addTearDown(position.dispose);
      await tester.pumpWidget(
        _screen(cache: cache, position: position, rideStarted: false),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('fuel-stations-layer')), findsNothing);
    });

    testWidgets(
      'MapLibre hides the pumps while navigating, and shows them again while '
      'the rider is choosing fuel',
      (tester) async {
        final cache = _cache(
          const BasemapConfiguration(
            styleUrl: 'https://tiles.example.com/styles/liberty',
            attribution: 'Example contributors',
          ),
        );
        addTearDown(cache.dispose);
        final position = ValueNotifier<GeoPoint?>(_position);
        addTearDown(position.dispose);

        final calls = await recordMapLibreStyleSetUp(
          tester,
          _screen(cache: cache, position: position, rideStarted: false),
        );
        Future<void> until(bool Function() condition) async {
          final deadline = DateTime.now().add(const Duration(seconds: 20));
          while (!condition() && DateTime.now().isBefore(deadline)) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 20)),
            );
            await tester.pump(const Duration(milliseconds: 20));
          }
        }

        int features() {
          final writes = [
            for (final call in calls)
              if ((call.method == 'source#addGeoJson' ||
                      call.method == 'source#setGeoJson') &&
                  (call.arguments as Map)['sourceId'] ==
                      'ride-relay-fuel-points')
                call,
          ];
          if (writes.isEmpty) return -1;
          final geoJson =
              jsonDecode((writes.last.arguments as Map)['geojson'] as String)
                  as Map;
          return (geoJson['features'] as List).length;
        }

        await until(() => features() == 2);
        expect(features(), 2);

        await tester.pumpWidget(
          _screen(cache: cache, position: position, rideStarted: true),
        );
        await until(() => features() == 0);
        expect(features(), 0);

        // The rider asks for fuel mid-ride: the pumps come back while they
        // choose.
        await tester.pumpWidget(
          _screen(
            cache: cache,
            position: position,
            rideStarted: true,
            fuelStopRequestToken: Object(),
          ),
        );
        await until(() => features() == 2);
        expect(features(), 2);
        await until(() => find.text('Fuel near you').evaluate().isNotEmpty);
        expect(find.text('Fuel near you'), findsOneWidget);

        // Closing the list without choosing hides them again.
        Navigator.of(tester.element(find.text('Fuel near you'))).pop();
        await until(() => features() == 0);
        expect(features(), 0);

        await tester.pump(const Duration(seconds: 2));
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 11));
        await tester.pump();
      },
    );
  });
}

OfflineTileCache _cache(BasemapConfiguration configuration) {
  final directory = Directory.systemTemp.createTempSync('fuel-layer');
  addTearDown(() => directory.deleteSync(recursive: true));
  return OfflineTileCache(
    rootDirectory: directory,
    configuration: configuration,
    httpClient: MockClient((_) async => http.Response('', 404)),
  );
}

Widget _screen({
  required OfflineTileCache cache,
  required ValueNotifier<GeoPoint?> position,
  required bool rideStarted,
  Object? fuelStopRequestToken,
}) => MaterialApp(
  home: RideMapScreen(
    routeStore: InMemoryRouteStore(),
    routeImporter: RouteImporter(source: const _NoFileSource()),
    offlineTileCache: cache,
    currentPosition: position,
    rideStarted: rideStarted,
    discoveryCatalogueLoader: () async =>
        const MotorcycleDiscoveryCatalogue([]),
    bikerPlaceCatalogueLoader: () async => BikerPlaceCatalogue.empty,
    fuelStopRequestToken: fuelStopRequestToken,
  ),
);

class _NoFileSource implements GpxImportSource {
  const _NoFileSource();

  @override
  Future<PickedGpxFile?> pickGpxFile() async => null;
}
