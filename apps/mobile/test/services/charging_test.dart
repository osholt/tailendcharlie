import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ride_relay/domain/geo_point.dart';
import 'package:ride_relay/internet/internet_relay_client.dart';
import 'package:ride_relay/services/charging.dart';
import 'package:ride_relay/services/charging_data.dart';
import 'package:ride_relay/services/fuel_preference.dart';
import 'package:ride_relay/services/fuel_prices.dart';
import 'package:ride_relay/services/fuel_station_catalogue.dart';
import 'package:ride_relay/services/fuel_stop_ranking.dart';

final now = DateTime.utc(2026, 10, 13, 12);
const preference = FuelPreference(
  FuelKind.electric,
  connectors: {ChargerConnector.type2},
);
Map<String, dynamic> response() => {
  'schemaVersion': 1,
  'sources': [
    {'id': 'test', 'attribution': 'Synthetic operator'},
  ],
  'locations': [
    {
      'id': 'test:one',
      'source': 'test',
      'name': 'Synthetic charger',
      'lat': 51.0,
      'lon': -1.0,
      'checkedAt': now.millisecondsSinceEpoch / 1000,
      'connectors': [
        {
          'type': 1,
          'status': 'OUTOFORDER',
          'kilowatts': 22,
          'pencePerKwh': 60,
          'priceCheckedAt': now.millisecondsSinceEpoch / 1000,
        },
        {
          'type': 2,
          'status': 'AVAILABLE',
          'kilowatts': 50,
          'pencePerKwh': 70,
          'priceCheckedAt': now.millisecondsSinceEpoch / 1000,
        },
      ],
    },
  ],
};

void main() {
  test('status and price use requested connector', () {
    final reading = parseChargers(response()).single;
    expect(reading.available(preference, now), false);
    expect(reading.unusable(preference, now), true);
    expect(reading.describe(preference, now), contains('60.0p/kWh'));
    expect(reading.describe(preference, now), isNot(contains('70.0p/kWh')));
    expect(
      reading.available(
        const FuelPreference(
          FuelKind.electric,
          connectors: {ChargerConnector.ccs},
        ),
        now,
      ),
      true,
    );
  });
  test('old and future observations are not current', () {
    final reading = parseChargers(response()).single;
    for (final time in [
      now.add(const Duration(minutes: 3)),
      now.subtract(const Duration(seconds: 1)),
    ]) {
      expect(reading.available(preference, time), false);
      expect(reading.unusable(preference, time), false);
      expect(
        reading.describe(preference, time),
        contains('availability unknown'),
      );
    }
    expect(
      reading.describe(preference, now.add(const Duration(days: 2))),
      contains('Tariff unknown'),
    );
  });
  test('malformed coordinates, unknown source and schema are rejected', () {
    final data = response();
    (data['locations'] as List).first['lat'] = double.nan;
    expect(parseChargers(data), isEmpty);
    final unknown = response();
    unknown['sources'] = [];
    expect(parseChargers(unknown), isEmpty);
    expect(() => parseChargers({'schemaVersion': 2}), throwsFormatException);
  });
  test('provider-only chargers appear and unmatched OSM survives', () {
    const osm = FuelStation(
      id: 'osm',
      kind: FuelStationKind.charging,
      point: GeoPoint(latitude: 51, longitude: -1),
      label: 'Different operator',
      connectors: 1,
    );
    final options = attachChargers(
      stations: [osm],
      readings: parseChargers(response()),
      preference: preference,
    );
    expect(options.length, 2);
    expect(options.last.station.id, 'osm');
    final painted = fuelMapDrawOrder(options);
    expect(painted.first.station.id, 'osm');
    expect(painted.last.charging, isNotNull);
    expect(fuelPinLabel(painted.first, now)!.text, 'No live data');
    expect(fuelPinLabel(painted.last, now)!.text, startsWith('from 60.0p/kWh'));

    expect(fuelPinLabel(options.first, now)!.text, contains('Unavailable'));
    expect(
      fuelPinLabel(options.first, now.add(const Duration(minutes: 3)))!.current,
      false,
    );
  });
  test('available compatible charger outranks unavailable one', () {
    final bad = parseChargers(response()).single;
    final good = ChargerReading(
      id: 'good',
      name: 'Good',
      point: const GeoPoint(latitude: 51.001, longitude: -1),
      source: 'test',
      attribution: 'Synthetic',
      checkedAt: now,
      sockets: const [
        ChargerSocket(type: 1, status: 'AVAILABLE', kilowatts: 22),
      ],
    );
    final options = attachChargers(
      stations: [],
      readings: [bad, good],
      preference: preference,
    );
    final ranked = rankFuelStops(
      options: options,
      preference: preference,
      now: now,
      origin: const GeoPoint(latitude: 51, longitude: -1),
    );
    expect(ranked.first.option.charging!.id, 'good');
  });
  test('capability and cache preserve observation age on failure', () async {
    final config = InternetRelayConfiguration(
      baseUri: Uri.parse('https://relay.example/api'),
    );
    var enabled = true, fail = false, gets = 0;
    var clock = now;
    final compatibility = _Compatibility(() => enabled);
    final client = RelayChargingClient(
      configuration: config,
      compatibility: compatibility,
      clock: () => clock,
      client: MockClient((request) async {
        gets++;
        expect(request.url.path, '/api/v1/charging/locations');
        if (fail) return http.Response('unavailable', 503);
        return http.Response(jsonEncode(response()), 200);
      }),
    );
    const tiles = [
      FuelPriceTile(west: -1.1, south: 50.9, east: -0.9, north: 51.1),
    ];
    final first = await client.fetch(tiles);
    expect(first, hasLength(1));
    expect(gets, 1);
    await client.fetch(tiles);
    expect(gets, 1);
    clock = now.add(const Duration(minutes: 3));
    fail = true;
    final stale = await client.fetch(tiles);
    expect(stale.single.checkedAt, now);
    expect(stale.single.fresh(clock), false);
    enabled = false;
    expect(await client.fetch(tiles), isEmpty);
  });
}

class _Compatibility implements RelayCompatibilityApi {
  _Compatibility(this.enabled);
  final bool Function() enabled;
  @override
  Future<RelayCompatibilityResult> checkCompatibility() async =>
      RelayCompatibilityResult(
        disposition: RelayCompatibilityDisposition.compatible,
        serverProtocol: 1,
        minimumClientProtocol: 1,
        capabilities: enabled() ? {'charging-status-v1'} : {},
        checkedAt: now,
        validUntil: now.add(const Duration(minutes: 5)),
      );
  @override
  void close() {}
}
