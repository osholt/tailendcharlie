import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:ride_relay/domain/geo_point.dart';
import 'package:ride_relay/internet/internet_relay_client.dart';
import 'package:ride_relay/services/fuel_preference.dart';
import 'package:ride_relay/services/fuel_prices.dart';
import 'package:ride_relay/services/fuel_station_catalogue.dart';

final _now = DateTime.utc(2026, 10, 10, 13, 5);

Map<String, Object?> _response({
  String checkedAt = '2026-10-10T13:00:00Z',
  List<Map<String, Object?>>? stations,
}) => {
  'schemaVersion': 1,
  'generatedAt': '2026-10-10T13:01:00Z',
  'sources': [
    {
      'id': 'uk-fuel-finder',
      'name': 'Fuel Finder',
      'attribution': 'Contains public sector information (OGL v3.0).',
      'currency': 'GBP',
      'checkedAt': checkedAt,
      'reportErrorUrl': 'https://www.gov.uk/guidance/report',
    },
  ],
  'stations':
      stations ??
      [
        {
          'id': 'uk:0001',
          'source': 'uk-fuel-finder',
          'lat': 52.1,
          'lon': -1.9,
          'name': 'Example Services',
          'brand': 'EXAMPLE',
          'prices': {
            'e10': {
              'minorPerLitre': 142.9,
              'reportedAt': '2026-10-09T07:15:00Z',
              'effectiveAt': '2026-10-09T07:00:00Z',
            },
            'hvo': {'minorPerLitre': 190.0},
            'diesel': {'minorPerLitre': -1},
          },
        },
        {'id': 'broken', 'source': 'uk-fuel-finder', 'lat': 'north'},
      ],
  'truncated': false,
};

void main() {
  group('reading the relay', () {
    test('keeps the grades the app offers and the source times unaltered', () {
      final snapshot = parseFuelPriceResponse(_response(), fetchedAt: _now);

      final source = snapshot.sources['uk-fuel-finder']!;
      expect(source.checkedAt, DateTime.utc(2026, 10, 10, 13));
      expect(
        source.reportErrorUrl,
        Uri.parse('https://www.gov.uk/guidance/report'),
      );
      final station = snapshot.stations.single;
      expect(station.name, 'Example Services');
      expect(station.prices.keys, [FuelKind.e10]);
      expect(
        station.prices[FuelKind.e10]!.reportedAt,
        DateTime.utc(2026, 10, 9, 7, 15),
      );
      expect(
        station.prices[FuelKind.e10]!.effectiveAt,
        DateTime.utc(2026, 10, 9, 7),
      );
    });

    test('refuses a document it does not understand', () {
      expect(
        () => parseFuelPriceResponse({'schemaVersion': 2}, fetchedAt: _now),
        throwsFormatException,
      );
    });
  });

  group('freshness', () {
    FuelPriceFreshness freshness({
      DateTime? checkedAt,
      DateTime? fetchedAt,
      DateTime? reportedAt,
      DateTime? now,
    }) => fuelPriceFreshness(
      quote: FuelPriceQuote(minorPerLitre: 142.9, reportedAt: reportedAt),
      checkedAt: checkedAt,
      fetchedAt: fetchedAt ?? _now,
      now: now ?? _now,
    );

    test('current while both checks are within the hour', () {
      expect(
        freshness(checkedAt: _now.subtract(const Duration(minutes: 59))),
        FuelPriceFreshness.current,
      );
    });

    test('stale once the relay has not confirmed it for over an hour', () {
      expect(
        freshness(checkedAt: _now.subtract(const Duration(minutes: 61))),
        FuelPriceFreshness.stale,
      );
    });

    test('stale once this phone has not refreshed it for over an hour', () {
      expect(
        freshness(
          checkedAt: _now.subtract(const Duration(minutes: 70)),
          fetchedAt: _now.subtract(const Duration(minutes: 65)),
          now: _now,
        ),
        FuelPriceFreshness.stale,
      );
      expect(
        freshness(
          checkedAt: _now,
          fetchedAt: _now,
          now: _now.add(const Duration(minutes: 61)),
        ),
        FuelPriceFreshness.stale,
      );
    });

    test('a phone clock behind the relay still ages its own copy', () {
      // The relay's check time reads as the future on this phone, so only the
      // phone's own fetch time can say the copy is old.
      expect(
        freshness(
          checkedAt: _now.add(const Duration(hours: 2)),
          fetchedAt: _now.subtract(const Duration(minutes: 61)),
        ),
        FuelPriceFreshness.stale,
      );
    });

    test('a price set weeks ago is still current under the reporting duty', () {
      expect(
        freshness(
          checkedAt: _now,
          reportedAt: _now.subtract(const Duration(days: 29)),
        ),
        FuelPriceFreshness.current,
      );
    });

    test(
      'a report older than a month is unconfirmed, however fresh the check',
      () {
        expect(
          freshness(
            checkedAt: _now,
            reportedAt: _now.subtract(const Duration(days: 31)),
          ),
          FuelPriceFreshness.unconfirmed,
        );
      },
    );

    test('never confirmed is never current', () {
      expect(freshness(), FuelPriceFreshness.stale);
    });
  });

  group('wording', () {
    const source = FuelPriceSource(
      id: 'uk-fuel-finder',
      name: 'Fuel Finder',
      attribution: '',
      currency: 'GBP',
    );
    FuelPriceSource checked(DateTime at) => FuelPriceSource(
      id: source.id,
      name: source.name,
      attribution: source.attribution,
      currency: source.currency,
      checkedAt: at,
    );

    test('formats pence and euros', () {
      expect(formatFuelPrice(142.9, 'GBP'), '142.9p');
      expect(formatFuelPrice(238.9, 'EUR'), '€2.389');
    });

    test('a current price says when it was confirmed', () {
      final text = describeFuelPrice(
        quote: const FuelPriceQuote(minorPerLitre: 142.9),
        source: checked(DateTime(2026, 10, 10, 14, 5).toUtc()),
        fetchedAt: DateTime(2026, 10, 10, 14, 6).toUtc(),
        now: DateTime(2026, 10, 10, 14, 10).toUtc(),
      );
      expect(text, '142.9p · as of 14:05');
    });

    test('a stale price says when, and that it may have changed', () {
      final text = describeFuelPrice(
        quote: const FuelPriceQuote(minorPerLitre: 142.9),
        source: checked(DateTime(2026, 10, 3, 9).toUtc()),
        fetchedAt: DateTime(2026, 10, 3, 9, 1).toUtc(),
        now: DateTime(2026, 10, 10, 14).toUtc(),
      );
      expect(text, '142.9p on 3 Oct, may have changed');
      final sameDay = describeFuelPrice(
        quote: const FuelPriceQuote(minorPerLitre: 142.9),
        source: checked(DateTime(2026, 10, 10, 9).toUtc()),
        fetchedAt: DateTime(2026, 10, 10, 9, 1).toUtc(),
        now: DateTime(2026, 10, 10, 14).toUtc(),
      );
      expect(sameDay, '142.9p at 09:00, may have changed');
    });

    test('an unconfirmed price says when it was last reported', () {
      final text = describeFuelPrice(
        quote: FuelPriceQuote(
          minorPerLitre: 142.9,
          reportedAt: DateTime(2026, 8, 2, 12).toUtc(),
        ),
        source: checked(DateTime(2026, 10, 10, 14).toUtc()),
        fetchedAt: DateTime(2026, 10, 10, 14).toUtc(),
        now: DateTime(2026, 10, 10, 14, 1).toUtc(),
      );
      expect(text, '142.9p last reported 2 Aug');
    });
  });

  test('tiles fit the relay limits and repeat for the same area', () {
    final tiles = fuelPriceTiles(
      west: -2.1,
      south: 51.9,
      east: -1.2,
      north: 52.6,
    );
    for (final tile in tiles) {
      expect(tile.north - tile.south, lessThanOrEqualTo(0.5));
      expect(tile.east - tile.west, lessThanOrEqualTo(0.8));
    }
    expect(tiles.length, lessThanOrEqualTo(6));
    expect(
      fuelPriceTiles(west: -2.09, south: 51.91, east: -1.21, north: 52.59),
      tiles,
    );
  });

  group('the relay client', () {
    final configuration = InternetRelayConfiguration(
      baseUri: Uri.parse('https://relay.example.test/api'),
    );
    final tile = fuelPriceTiles(
      west: -2.0,
      south: 52.0,
      east: -1.9,
      north: 52.1,
    ).first;

    test('asks for nothing when the relay does not offer prices', () async {
      var requests = 0;
      final client = RelayFuelPriceClient(
        configuration: configuration,
        compatibility: _Compatibility(const {}),
        httpGet: (uri, {headers}) async {
          requests++;
          return http.Response('{}', 200);
        },
      );

      final result = await client.fetch([tile]);

      expect(result.availability, FuelPriceAvailability.notOffered);
      expect(requests, 0);
    });

    test('reads a tile and answers a repeat from its cache', () async {
      final uris = <Uri>[];
      var clock = _now;
      final client = RelayFuelPriceClient(
        configuration: configuration,
        compatibility: _Compatibility({RelayProtocolCapabilities.fuelPrices}),
        clock: () => clock,
        httpGet: (uri, {headers}) async {
          uris.add(uri);
          expect(headers?['accept'], 'application/json');
          return http.Response(jsonEncode(_response()), 200);
        },
      );

      final first = await client.fetch([tile]);
      clock = clock.add(const Duration(minutes: 5));
      final second = await client.fetch([tile]);
      clock = clock.add(const Duration(minutes: 6));
      await client.fetch([tile]);

      expect(first.availability, FuelPriceAvailability.available);
      expect(first.snapshot.stations, hasLength(1));
      expect(second.snapshot.stations, hasLength(1));
      expect(uris, hasLength(2));
      expect(uris.first.path, '/api/v1/fuel/prices');
      expect(uris.first.queryParameters.keys, [
        'west',
        'south',
        'east',
        'north',
      ]);
    });

    test('an unconfigured relay is "not offered", not a failure', () async {
      final client = RelayFuelPriceClient(
        configuration: configuration,
        compatibility: _Compatibility({RelayProtocolCapabilities.fuelPrices}),
        httpGet: (uri, {headers}) async => http.Response(
          jsonEncode({'code': 'fuel_prices_unconfigured'}),
          503,
        ),
      );

      expect(
        (await client.fetch([tile])).availability,
        FuelPriceAvailability.notOffered,
      );
    });

    test('an unreachable relay is unavailable', () async {
      final client = RelayFuelPriceClient(
        configuration: configuration,
        compatibility: _Compatibility({RelayProtocolCapabilities.fuelPrices}),
        httpGet: (uri, {headers}) async => throw http.ClientException('down'),
      );

      expect(
        (await client.fetch([tile])).availability,
        FuelPriceAvailability.unavailable,
      );
    });
  });

  group('joining prices to mapped stations', () {
    final snapshot = parseFuelPriceResponse(
      _response(
        stations: [
          {
            'id': 'uk:near',
            'source': 'uk-fuel-finder',
            'lat': 52.1003,
            'lon': -1.9,
            'name': 'Trading Name',
            'prices': {
              'e10': {'minorPerLitre': 142.9},
            },
          },
          {
            'id': 'uk:unmapped',
            'source': 'uk-fuel-finder',
            'lat': 52.3,
            'lon': -1.9,
            'name': 'Unmapped Forecourt',
            'prices': {
              'e10': {'minorPerLitre': 139.9},
            },
          },
        ],
      ),
      fetchedAt: _now,
    );
    const mapped = FuelStation(
      id: 'fuel:5210000:-190000',
      kind: FuelStationKind.fuel,
      point: GeoPoint(latitude: 52.1, longitude: -1.9),
      label: 'Fuel station',
    );
    const distant = FuelStation(
      id: 'fuel:5220000:-190000',
      kind: FuelStationKind.fuel,
      point: GeoPoint(latitude: 52.2, longitude: -1.9),
      label: 'Mapped Name',
    );

    test('within 75 m it is the same forecourt; otherwise it is added', () {
      final options = attachFuelPrices(
        stations: [mapped, distant],
        snapshot: snapshot,
        preference: const FuelPreference(FuelKind.e10),
      );

      final joined = options.firstWhere((o) => o.station.id == mapped.id);
      expect(joined.quote!.minorPerLitre, 142.9);
      // The map had only a generic word; the source's name is better.
      expect(joined.label, 'Trading Name');
      expect(
        options.firstWhere((o) => o.station.id == distant.id).quote,
        isNull,
      );
      final added = options.firstWhere(
        (o) => o.station.id == 'priced:uk:unmapped',
      );
      expect(added.label, 'Unmapped Forecourt');
      expect(added.quote!.minorPerLitre, 139.9);
      expect(options, hasLength(3));
    });

    test('just over the match distance is a different forecourt', () {
      final options = attachFuelPrices(
        stations: [mapped],
        snapshot: snapshot,
        preference: const FuelPreference(FuelKind.e10),
        matchMetres: 30,
      );
      expect(
        options.firstWhere((o) => o.station.id == mapped.id).quote,
        isNull,
      );
    });

    test('a rider on electric gets no fuel prices', () {
      final options = attachFuelPrices(
        stations: [mapped],
        snapshot: snapshot,
        preference: const FuelPreference(FuelKind.electric),
      );
      expect(options.single.quote, isNull);
    });
  });
}

class _Compatibility implements RelayCompatibilityApi {
  _Compatibility(this.capabilities);

  final Set<String> capabilities;

  @override
  Future<RelayCompatibilityResult> checkCompatibility() async =>
      RelayCompatibilityResult(
        disposition: RelayCompatibilityDisposition.compatible,
        serverProtocol: 1,
        minimumClientProtocol: 1,
        capabilities: capabilities,
        checkedAt: _now,
        validUntil: _now.add(const Duration(minutes: 5)),
      );

  @override
  void close() {}
}
