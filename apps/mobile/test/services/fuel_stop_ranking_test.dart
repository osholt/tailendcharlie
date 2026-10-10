import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/geo_point.dart';
import 'package:ride_relay/services/fuel_preference.dart';
import 'package:ride_relay/services/fuel_prices.dart';
import 'package:ride_relay/services/fuel_station_catalogue.dart';
import 'package:ride_relay/services/fuel_stop_ranking.dart';

/// A straight route due north from (52.0, -1.5), 100 km long, one point per
/// kilometre. Synthetic: no real road or place.
final _route = [
  for (var km = 0; km <= 100; km++)
    GeoPoint(latitude: 52.0 + km / 111.32, longitude: -1.5),
];

/// A point [km] along [_route] and [eastMetres] east of it.
GeoPoint _beside(double km, {double eastMetres = 0}) => GeoPoint(
  latitude: 52.0 + km / 111.32,
  longitude: -1.5 + eastMetres / (111320 * 0.6157),
);

final _now = DateTime.utc(2026, 10, 10, 9);

const _source = FuelPriceSource(
  id: 'uk-fuel-finder',
  name: 'Fuel Finder',
  attribution: 'OGL',
  currency: 'GBP',
);

FuelStopOption _fuel(
  String id,
  GeoPoint point, {
  int sells = 1 | 4,
  int doesNotSell = 0,
  double? price,
  DateTime? checkedAt,
  bool closed = false,
  String label = 'Example',
}) {
  final station = FuelStation(
    id: id,
    kind: FuelStationKind.fuel,
    point: point,
    label: label,
    sells: sells,
    doesNotSell: doesNotSell,
  );
  if (price == null) return FuelStopOption(station: station);
  return FuelStopOption(
    station: station,
    priced: PricedFuelStation(
      id: 'uk:$id',
      sourceId: _source.id,
      point: point,
      prices: const {},
      closed: closed,
    ),
    quote: FuelPriceQuote(
      minorPerLitre: price,
      reportedAt: DateTime.utc(2026, 10, 9),
    ),
    source: FuelPriceSource(
      id: _source.id,
      name: _source.name,
      attribution: _source.attribution,
      currency: _source.currency,
      checkedAt: checkedAt ?? _now.subtract(const Duration(minutes: 10)),
    ),
    fetchedAt: _now.subtract(const Duration(minutes: 5)),
  );
}

const _e10 = FuelPreference(FuelKind.e10);

List<String> _ids(List<FuelStopCandidate> candidates) =>
    candidates.map((candidate) => candidate.option.station.id).toList();

void main() {
  group('along a route', () {
    test('offers only stations ahead, within the corridor and look-ahead', () {
      final ranked = rankFuelStops(
        options: [
          _fuel('ahead', _beside(10, eastMetres: 100)),
          _fuel('too-far-off', _beside(12, eastMetres: 3500)),
          _fuel('beyond-look-ahead', _beside(90)),
          _fuel('behind', _beside(-5)),
        ],
        preference: _e10,
        now: _now,
        routeAhead: _route,
      );

      expect(_ids(ranked), ['ahead']);
      expect(ranked.single.reachMetres, closeTo(10000, 50));
      expect(ranked.single.detourMetres, closeTo(2 * 100 * 1.3, 5));
      expect(ranked.single.alongRoute, isTrue);
    });

    test('a detour counts twice: a station on the route a little further on '
        'beats one off it a little nearer', () {
      final ranked = rankFuelStops(
        options: [
          _fuel('off-route', _beside(5, eastMetres: 1500)),
          _fuel('on-route', _beside(9.5)),
        ],
        preference: _e10,
        now: _now,
        routeAhead: _route,
      );

      // 5 km + 2 × 3.9 km = 12.8 km against 9.5 km. Counted once, the detour
      // would make it 8.9 km and win.
      expect(_ids(ranked), ['on-route', 'off-route']);
    });

    test('a route that passes a station twice uses the first pass', () {
      final outAndBack = [
        ..._route.take(21),
        ..._route.take(21).toList().reversed,
      ];
      final ranked = rankFuelStops(
        options: [_fuel('pump', _beside(15))],
        preference: _e10,
        now: _now,
        routeAhead: outAndBack,
      );

      expect(ranked.single.reachMetres, closeTo(15000, 50));
    });
  });

  group('price', () {
    test('a current price worth more than the extra riding wins', () {
      final ranked = rankFuelStops(
        options: [
          _fuel('near-dear', _beside(5), price: 152.9),
          _fuel('further-cheap', _beside(9), price: 142.9),
        ],
        preference: _e10,
        now: _now,
        routeAhead: _route,
      );

      // 10p a litre is worth 5 km: 5 + 5 = 10 km against 9 km.
      expect(_ids(ranked), ['further-cheap', 'near-dear']);
      expect(ranked.first.priceDifference, 0);
      expect(ranked.last.priceDifference, closeTo(10, 1e-9));
    });

    test('a stale price steers nothing', () {
      final stale = _now.subtract(const Duration(hours: 3));
      final ranked = rankFuelStops(
        options: [
          _fuel('near-dear', _beside(5), price: 152.9),
          _fuel(
            'further-cheap-but-stale',
            _beside(9),
            price: 120.9,
            checkedAt: stale,
          ),
        ],
        preference: _e10,
        now: _now,
        routeAhead: _route,
      );

      expect(_ids(ranked), ['near-dear', 'further-cheap-but-stale']);
      expect(ranked.last.priceDifference, isNull);
    });

    test('brand never enters the ranking', () {
      final first = rankFuelStops(
        options: [
          _fuel('a', _beside(5), label: 'Brand One'),
          _fuel('b', _beside(5), label: 'Brand Two'),
        ],
        preference: _e10,
        now: _now,
        routeAhead: _route,
      );
      final swapped = rankFuelStops(
        options: [
          _fuel('a', _beside(5), label: 'Brand Two'),
          _fuel('b', _beside(5), label: 'Brand One'),
        ],
        preference: _e10,
        now: _now,
        routeAhead: _route,
      );

      expect(_ids(first), _ids(swapped));
    });
  });

  group('what may be offered', () {
    test('closed and incompatible stations are never offered', () {
      final ranked = rankFuelStops(
        options: [
          _fuel('closed', _beside(2), price: 140, closed: true),
          _fuel('no-e10', _beside(3), sells: 4, doesNotSell: 1),
          _fuel('open', _beside(6)),
        ],
        preference: _e10,
        now: _now,
        routeAhead: _route,
      );

      expect(_ids(ranked), ['open']);
    });

    test('an unlisted station is assumed to sell E10 but ranked down for '
        'super unleaded', () {
      final options = [
        _fuel('unlisted', _beside(5), sells: 0),
        _fuel('listed', _beside(5.5), sells: 1 | 2 | 4),
      ];

      final forE10 = rankFuelStops(
        options: options,
        preference: _e10,
        now: _now,
        routeAhead: _route,
      );
      final forE5 = rankFuelStops(
        options: options,
        preference: const FuelPreference(FuelKind.e5),
        now: _now,
        routeAhead: _route,
      );

      expect(_ids(forE10), ['unlisted', 'listed']);
      expect(_ids(forE5), ['listed', 'unlisted']);
      expect(forE5.last.compatibility, FuelCompatibility.unrecorded);
    });

    test('a charger needs one of the rider connectors, or none recorded', () {
      FuelStopOption charger(String id, int connectors, double km) =>
          FuelStopOption(
            station: FuelStation(
              id: id,
              kind: FuelStationKind.charging,
              point: _beside(km),
              label: 'Charger',
              connectors: connectors,
            ),
          );
      final ranked = rankFuelStops(
        options: [
          charger('chademo-only', ChargerConnector.chademo.bit, 1),
          charger('ccs', ChargerConnector.ccs.bit, 4),
          charger('unrecorded', 0, 4),
          _fuel('petrol', _beside(2)),
        ],
        preference: const FuelPreference(
          FuelKind.electric,
          connectors: {ChargerConnector.ccs, ChargerConnector.type2},
        ),
        now: _now,
        routeAhead: _route,
      );

      expect(_ids(ranked), ['ccs', 'unrecorded']);
    });

    test('at most five, cheapest cost first', () {
      final ranked = rankFuelStops(
        options: [
          for (var km = 10; km > 0; km--)
            _fuel('km-$km', _beside(km.toDouble())),
        ],
        preference: _e10,
        now: _now,
        routeAhead: _route,
      );

      expect(_ids(ranked), ['km-1', 'km-2', 'km-3', 'km-4', 'km-5']);
    });
  });

  group('without a route', () {
    test('stations within the radius of the rider, by road estimate', () {
      final ranked = rankFuelStops(
        options: [_fuel('near', _beside(2)), _fuel('far', _beside(30))],
        preference: _e10,
        now: _now,
        origin: _beside(0),
      );

      expect(_ids(ranked), ['near']);
      expect(ranked.single.reachMetres, closeTo(2000 * 1.3, 10));
      expect(ranked.single.detourMetres, 0);
      expect(ranked.single.alongRoute, isFalse);
    });

    test('nothing to search from is an empty answer', () {
      expect(
        rankFuelStops(
          options: [_fuel('x', _beside(1))],
          preference: _e10,
          now: _now,
        ),
        isEmpty,
      );
    });
  });

  group('routeAheadOf', () {
    test('starts at the rider and runs to the end', () {
      final ahead = routeAheadOf(_route, _beside(10.5, eastMetres: 40))!;

      expect(ahead.first.latitude, closeTo(_beside(10.5).latitude, 1e-5));
      expect(ahead.last, _route.last);
      expect(ahead.length, 91);
    });

    test('is null for a rider nowhere near the route', () {
      expect(routeAheadOf(_route, _beside(10, eastMetres: 5000)), isNull);
    });
  });

  test('the search box covers the look-ahead and the corridor', () {
    final bounds = fuelSearchBounds(routeAhead: _route)!;

    expect(bounds.south, lessThan(52.0));
    // 80 km ahead plus the 3 km corridor, not the whole 100 km.
    expect(bounds.north, closeTo(52.0 + 83 / 111.32, 0.02));
    expect(
      bounds.east - bounds.west,
      closeTo(2 * 3000 / (111320 * 0.6157), 0.01),
    );
  });
}
