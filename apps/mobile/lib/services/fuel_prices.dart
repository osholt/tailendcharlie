/// Fuel prices from the relay, and the rules for presenting them (#951).
///
/// The relay fetches official sources (Fuel Finder in the UK, prix-carburants
/// in France) and answers small bounding boxes. Prices are shown only while the
/// relay advertises `fuel-prices-v1`, which the operator controls. The decision
/// record is `docs/fuel-and-charging-data-decision.md`.
///
/// The rule this file exists to keep: a price is never presented as current
/// when it might not be. [fuelPriceFreshness] decides, and [describeFuelPrice]
/// says it in words.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../domain/geo_point.dart';
import '../internet/internet_relay_client.dart';
import 'fuel_preference.dart';
import 'fuel_station_catalogue.dart';
import 'geo_calculations.dart';

/// One grade's price at one station, with the source's own timestamps.
@immutable
class FuelPriceQuote {
  const FuelPriceQuote({
    required this.minorPerLitre,
    this.reportedAt,
    this.effectiveAt,
  });

  /// Pence or cents per litre.
  final double minorPerLitre;

  /// When the source last had this price reported. Shown unaltered.
  final DateTime? reportedAt;

  /// When the price took effect, where the source says.
  final DateTime? effectiveAt;
}

@immutable
class FuelPriceSource {
  const FuelPriceSource({
    required this.id,
    required this.name,
    required this.attribution,
    required this.currency,
    this.checkedAt,
    this.reportErrorUrl,
  });

  final String id;
  final String name;
  final String attribution;
  final String currency;

  /// When the relay last confirmed this source. Null until it first has.
  final DateTime? checkedAt;
  final Uri? reportErrorUrl;
}

@immutable
class PricedFuelStation {
  const PricedFuelStation({
    required this.id,
    required this.sourceId,
    required this.point,
    required this.prices,
    this.name,
    this.brand,
    this.closed = false,
  });

  final String id;
  final String sourceId;
  final GeoPoint point;
  final String? name;
  final String? brand;
  final bool closed;
  final Map<FuelKind, FuelPriceQuote> prices;
}

@immutable
class FuelPriceSnapshot {
  const FuelPriceSnapshot({
    required this.sources,
    required this.stations,
    required this.fetchedAt,
  });

  static final empty = FuelPriceSnapshot(
    sources: const {},
    stations: const [],
    fetchedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
  );

  final Map<String, FuelPriceSource> sources;
  final List<PricedFuelStation> stations;

  /// When this phone received the answer.
  final DateTime fetchedAt;

  FuelPriceSnapshot merge(FuelPriceSnapshot other) => FuelPriceSnapshot(
    sources: {...sources, ...other.sources},
    stations: {
      for (final station in [...stations, ...other.stations])
        station.id: station,
    }.values.toList(growable: false),
    fetchedAt: fetchedAt.isBefore(other.fetchedAt)
        ? fetchedAt
        : other.fetchedAt,
  );
}

/// Reads the relay's `/api/v1/fuel/prices` response. Malformed stations and
/// grades the app does not offer are skipped; a malformed document is an error.
FuelPriceSnapshot parseFuelPriceResponse(
  Map<String, Object?> json, {
  required DateTime fetchedAt,
}) {
  if (json['schemaVersion'] != 1) {
    throw const FormatException('Unsupported fuel price response.');
  }
  final sources = <String, FuelPriceSource>{};
  for (final raw in json['sources'] as List<Object?>? ?? const []) {
    if (raw is! Map<String, Object?>) continue;
    final id = raw['id'];
    if (id is! String) continue;
    final report = raw['reportErrorUrl'];
    final reportUri = report is String ? Uri.tryParse(report) : null;
    sources[id] = FuelPriceSource(
      id: id,
      name: raw['name'] as String? ?? id,
      attribution: raw['attribution'] as String? ?? '',
      currency: raw['currency'] as String? ?? 'GBP',
      checkedAt: _time(raw['checkedAt']),
      reportErrorUrl: reportUri?.scheme == 'https' ? reportUri : null,
    );
  }
  final stations = <PricedFuelStation>[];
  for (final raw in json['stations'] as List<Object?>? ?? const []) {
    if (raw is! Map<String, Object?>) continue;
    final id = raw['id'];
    final source = raw['source'];
    final latitude = raw['lat'];
    final longitude = raw['lon'];
    if (id is! String || source is! String) continue;
    if (latitude is! num || longitude is! num) continue;
    if (latitude.abs() > 90 || longitude.abs() > 180) continue;
    final prices = <FuelKind, FuelPriceQuote>{};
    final rawPrices = raw['prices'];
    if (rawPrices is Map<String, Object?>) {
      for (final kind in FuelKind.values) {
        final quote = rawPrices[kind.apiValue];
        if (quote is! Map<String, Object?>) continue;
        final amount = quote['minorPerLitre'];
        if (amount is! num || amount <= 0) continue;
        prices[kind] = FuelPriceQuote(
          minorPerLitre: amount.toDouble(),
          reportedAt: _time(quote['reportedAt']),
          effectiveAt: _time(quote['effectiveAt']),
        );
      }
    }
    stations.add(
      PricedFuelStation(
        id: id,
        sourceId: source,
        point: GeoPoint(
          latitude: latitude.toDouble(),
          longitude: longitude.toDouble(),
        ),
        name: raw['name'] as String?,
        brand: raw['brand'] as String?,
        closed: raw['closed'] == true,
        prices: prices,
      ),
    );
  }
  return FuelPriceSnapshot(
    sources: sources,
    stations: stations,
    fetchedAt: fetchedAt,
  );
}

DateTime? _time(Object? value) =>
    value is String ? DateTime.tryParse(value)?.toUtc() : null;

enum FuelPriceFreshness {
  /// Confirmed recently enough to call it the price.
  current,

  /// The relay or this phone has not confirmed it for a while.
  stale,

  /// The source itself has not had this price reported for over a month.
  unconfirmed,
}

/// How long a confirmation stands. A UK forecourt must report a change within
/// 30 minutes; the relay checks every 15. An hour covers one missed check
/// without calling a price current that nobody has looked at since lunch.
const fuelPriceConfirmationWindow = Duration(hours: 1);

/// Past this, the source's own report is too old to stand for the price, even
/// with a fresh check: forecourts that stop reporting leave their last price
/// behind.
const fuelPriceReportCeiling = Duration(days: 30);

FuelPriceFreshness fuelPriceFreshness({
  required FuelPriceQuote quote,
  required DateTime? checkedAt,
  required DateTime fetchedAt,
  required DateTime now,
}) {
  final reported = quote.reportedAt;
  if (checkedAt == null) return FuelPriceFreshness.stale;
  if (reported != null &&
      checkedAt.difference(reported) > fuelPriceReportCeiling) {
    return FuelPriceFreshness.unconfirmed;
  }
  if (now.difference(checkedAt) > fuelPriceConfirmationWindow ||
      now.difference(fetchedAt) > fuelPriceConfirmationWindow) {
    return FuelPriceFreshness.stale;
  }
  return FuelPriceFreshness.current;
}

/// "142.9p" or "€2.389".
String formatFuelPrice(double minorPerLitre, String currency) =>
    switch (currency) {
      'EUR' => '€${(minorPerLitre / 100).toStringAsFixed(3)}',
      _ => '${minorPerLitre.toStringAsFixed(1)}p',
    };

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

String _clock(DateTime time) {
  final local = time.toLocal();
  return '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
}

String _day(DateTime time) {
  final local = time.toLocal();
  return '${local.day} ${_months[local.month - 1]}';
}

/// The words beside a price, per [fuelPriceFreshness]:
///
/// - current: "142.9p · as of 14:05" (the relay's check);
/// - stale: "142.9p on 3 Oct, may have changed";
/// - unconfirmed: "142.9p last reported 2 Aug".
String describeFuelPrice({
  required FuelPriceQuote quote,
  required FuelPriceSource source,
  required DateTime fetchedAt,
  required DateTime now,
}) {
  final price = formatFuelPrice(quote.minorPerLitre, source.currency);
  final checked = source.checkedAt;
  switch (fuelPriceFreshness(
    quote: quote,
    checkedAt: checked,
    fetchedAt: fetchedAt,
    now: now,
  )) {
    case FuelPriceFreshness.current:
      return '$price · as of ${_clock(checked!)}';
    case FuelPriceFreshness.stale:
      final asOf = checked == null
          ? fetchedAt
          : (checked.isBefore(fetchedAt) ? checked : fetchedAt);
      final sameDay =
          asOf.toLocal().year == now.toLocal().year &&
          asOf.toLocal().month == now.toLocal().month &&
          asOf.toLocal().day == now.toLocal().day;
      return '$price ${sameDay ? 'at ${_clock(asOf)}' : 'on ${_day(asOf)}'}, '
          'may have changed';
    case FuelPriceFreshness.unconfirmed:
      return '$price last reported ${_day(quote.reportedAt!)}';
  }
}

/// A box the relay will answer.
@immutable
class FuelPriceTile {
  const FuelPriceTile({
    required this.west,
    required this.south,
    required this.east,
    required this.north,
  });

  final double west;
  final double south;
  final double east;
  final double north;

  @override
  bool operator ==(Object other) =>
      other is FuelPriceTile &&
      other.west == west &&
      other.south == south &&
      other.east == east &&
      other.north == north;

  @override
  int get hashCode => Object.hash(west, south, east, north);
}

/// The relay's box limits are 0.5° by 0.8°. Tiles are a fixed 0.25° grid
/// grouped two by three, so the same area always asks the same questions and
/// a repeat is answered from the cache.
const _tileLatitude = 0.5;
const _tileLongitude = 0.75;

/// The tiles covering a box, at most [limit] of them, nearest its centre first.
List<FuelPriceTile> fuelPriceTiles({
  required double west,
  required double south,
  required double east,
  required double north,
  int limit = 6,
}) {
  final tiles = <FuelPriceTile>[];
  for (
    var row = (south / _tileLatitude).floor();
    row <= (north / _tileLatitude).floor();
    row++
  ) {
    for (
      var column = (west / _tileLongitude).floor();
      column <= (east / _tileLongitude).floor();
      column++
    ) {
      tiles.add(
        FuelPriceTile(
          west: column * _tileLongitude,
          south: row * _tileLatitude,
          east: (column + 1) * _tileLongitude,
          north: (row + 1) * _tileLatitude,
        ),
      );
    }
  }
  final centreLatitude = (south + north) / 2;
  final centreLongitude = (west + east) / 2;
  double distance(FuelPriceTile tile) =>
      math.pow((tile.south + tile.north) / 2 - centreLatitude, 2).toDouble() +
      math.pow((tile.west + tile.east) / 2 - centreLongitude, 2);
  tiles.sort((a, b) => distance(a).compareTo(distance(b)));
  return tiles.take(limit).toList(growable: false);
}

/// A rider is waiting on a search; a slow relay leaves the list unpriced
/// rather than holding it up.
const fuelPriceRequestTimeout = Duration(seconds: 8);

typedef FuelPriceHttpGet =
    Future<http.Response> Function(Uri uri, {Map<String, String>? headers});

/// Why there are no prices, when there are none.
enum FuelPriceAvailability {
  available,

  /// This build has no relay, or the relay does not offer prices. Normal until
  /// the operator registers with Fuel Finder.
  notOffered,

  /// The relay could not be reached or did not answer usefully.
  unavailable,
}

@immutable
class FuelPriceResult {
  const FuelPriceResult(this.availability, this.snapshot);

  final FuelPriceAvailability availability;
  final FuelPriceSnapshot snapshot;
}

/// Fetches prices from the relay, tile by tile, with a short in-memory cache.
class RelayFuelPriceClient {
  RelayFuelPriceClient({
    required this.configuration,
    this.compatibility,
    FuelPriceHttpGet? httpGet,
    DateTime Function()? clock,
    this.cacheFor = const Duration(minutes: 10),
    this.maximumResponseBytes = 512 * 1024,
  }) : _httpGet = httpGet ?? http.get,
       _clock = clock ?? DateTime.now;

  final InternetRelayConfiguration configuration;
  final RelayCompatibilityApi? compatibility;
  final FuelPriceHttpGet _httpGet;
  final DateTime Function() _clock;
  final Duration cacheFor;
  final int maximumResponseBytes;
  final _cache = <FuelPriceTile, FuelPriceSnapshot>{};

  static RelayFuelPriceClient? _shared;

  /// The app's client, against the relay this build was configured with.
  static RelayFuelPriceClient shared() => _shared ??= () {
    final configuration = InternetRelayConfiguration.fromEnvironment();
    return RelayFuelPriceClient(
      configuration: configuration,
      compatibility: configuration.isConfigured
          ? HttpInternetRelayClient(
              configuration: configuration,
              client: http.Client(),
            )
          : null,
    );
  }();

  @visibleForTesting
  static void debugSetShared(RelayFuelPriceClient? client) => _shared = client;

  /// The cached prices for [tiles], without asking the relay. For drawing.
  FuelPriceSnapshot cached(Iterable<FuelPriceTile> tiles) {
    var snapshot = FuelPriceSnapshot.empty;
    var first = true;
    for (final tile in tiles) {
      final hit = _cache[tile];
      if (hit == null) continue;
      snapshot = first ? hit : snapshot.merge(hit);
      first = false;
    }
    return snapshot;
  }

  Future<FuelPriceResult> fetch(List<FuelPriceTile> tiles) async {
    final base = configuration.baseUri;
    if (!configuration.isConfigured || base == null) {
      return FuelPriceResult(
        FuelPriceAvailability.notOffered,
        FuelPriceSnapshot.empty,
      );
    }
    final compatibility = this.compatibility;
    if (compatibility != null) {
      try {
        final result = await compatibility.checkCompatibility();
        if (!result.supports(RelayProtocolCapabilities.fuelPrices)) {
          return FuelPriceResult(
            FuelPriceAvailability.notOffered,
            FuelPriceSnapshot.empty,
          );
        }
      } on Object {
        return FuelPriceResult(
          FuelPriceAvailability.unavailable,
          FuelPriceSnapshot.empty,
        );
      }
    }
    var snapshot = FuelPriceSnapshot.empty;
    var any = false;
    var failed = false;
    for (final tile in tiles) {
      final now = _clock();
      var answer = _cache[tile];
      if (answer == null || now.difference(answer.fetchedAt) > cacheFor) {
        try {
          answer = await _fetchTile(base, tile);
          _cache[tile] = answer;
        } on _NotOffered {
          return FuelPriceResult(
            FuelPriceAvailability.notOffered,
            FuelPriceSnapshot.empty,
          );
        } on Object {
          failed = true;
          // A cached answer, however old, is still labelled by its own times.
          answer = _cache[tile];
          if (answer == null) continue;
        }
      }
      snapshot = any ? snapshot.merge(answer) : answer;
      any = true;
    }
    if (_cache.length > 64) {
      final oldest = _cache.entries.reduce(
        (a, b) => a.value.fetchedAt.isBefore(b.value.fetchedAt) ? a : b,
      );
      _cache.remove(oldest.key);
    }
    return FuelPriceResult(
      failed && !any
          ? FuelPriceAvailability.unavailable
          : FuelPriceAvailability.available,
      snapshot,
    );
  }

  Future<FuelPriceSnapshot> _fetchTile(Uri base, FuelPriceTile tile) async {
    final basePath = base.path.endsWith('/')
        ? base.path.substring(0, base.path.length - 1)
        : base.path;
    final uri = base.replace(
      path: '$basePath/v1/fuel/prices',
      queryParameters: {
        'west': tile.west.toStringAsFixed(4),
        'south': tile.south.toStringAsFixed(4),
        'east': tile.east.toStringAsFixed(4),
        'north': tile.north.toStringAsFixed(4),
      },
    );
    final response = await _httpGet(
      uri,
      headers: {
        'accept': 'application/json',
        ...RelayClientDescriptor.current().headers,
      },
    ).timeout(fuelPriceRequestTimeout);
    if (response.statusCode == 503) {
      final body = _decode(response);
      if (body?['code'] == 'fuel_prices_unconfigured') {
        throw const _NotOffered();
      }
    }
    if (response.statusCode != 200) {
      throw http.ClientException('Fuel prices answered ${response.statusCode}');
    }
    if (response.bodyBytes.length > maximumResponseBytes) {
      throw const FormatException('Fuel price response too large.');
    }
    final body = _decode(response);
    if (body == null) throw const FormatException('Malformed fuel prices.');
    return parseFuelPriceResponse(body, fetchedAt: _clock().toUtc());
  }

  static Map<String, Object?>? _decode(http.Response response) {
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      return decoded is Map<String, Object?> ? decoded : null;
    } on Object {
      return null;
    }
  }
}

class _NotOffered implements Exception {
  const _NotOffered();
}

/// How close a priced forecourt must be to a mapped station to be the same
/// one. Forecourt coordinates are where the operator put the pin; a large
/// motorway services can be 60 m across.
const fuelPriceMatchMetres = 75.0;

/// A station as a rider is offered it: the mapped station, with a price where
/// the relay has one.
@immutable
class FuelStopOption {
  const FuelStopOption({
    required this.station,
    this.priced,
    this.quote,
    this.source,
    this.fetchedAt,
  });

  final FuelStation station;
  final PricedFuelStation? priced;
  final FuelPriceQuote? quote;
  final FuelPriceSource? source;
  final DateTime? fetchedAt;

  bool get closed => priced?.closed ?? false;

  /// The name to show: the source's trading name for a priced forecourt with
  /// no better one mapped, otherwise the map's.
  String get label {
    final mapped = station.label;
    if (mapped != 'Fuel station' && mapped != 'Charger') return mapped;
    return priced?.name ?? priced?.brand ?? mapped;
  }

  FuelPriceFreshness? freshness(DateTime now) {
    final quote = this.quote;
    final fetchedAt = this.fetchedAt;
    if (quote == null || fetchedAt == null) return null;
    return fuelPriceFreshness(
      quote: quote,
      checkedAt: source?.checkedAt,
      fetchedAt: fetchedAt,
      now: now,
    );
  }

  /// The price, only when it may be called current. Ranking uses nothing else.
  double? currentPrice(DateTime now) =>
      freshness(now) == FuelPriceFreshness.current
      ? quote?.minorPerLitre
      : null;

  String? priceText(DateTime now) {
    final quote = this.quote;
    final source = this.source;
    final fetchedAt = this.fetchedAt;
    if (quote == null || source == null || fetchedAt == null) return null;
    return describeFuelPrice(
      quote: quote,
      source: source,
      fetchedAt: fetchedAt,
      now: now,
    );
  }
}

/// Joins prices onto mapped stations for the rider's fuel.
///
/// Each priced forecourt goes to the nearest mapped fuel station within
/// [fuelPriceMatchMetres], and each mapped station takes at most one. A priced
/// forecourt with no mapped match is still offered, at the relay's position:
/// the government list is the more complete of the two.
List<FuelStopOption> attachFuelPrices({
  required Iterable<FuelStation> stations,
  required FuelPriceSnapshot snapshot,
  required FuelPreference preference,
  double matchMetres = fuelPriceMatchMetres,
}) {
  final options = <FuelStation, FuelStopOption>{
    for (final station in stations) station: FuelStopOption(station: station),
  };
  if (preference.isElectric) return options.values.toList(growable: false);
  final fuelStations = options.keys
      .where((station) => station.kind == FuelStationKind.fuel)
      .toList(growable: false);
  final claimed = <FuelStation>{};
  final extra = <FuelStopOption>[];
  for (final priced in snapshot.stations) {
    final quote = priced.prices[preference.kind];
    final source = snapshot.sources[priced.sourceId];
    FuelStation? nearest;
    var nearestMetres = matchMetres;
    for (final station in fuelStations) {
      if (claimed.contains(station)) continue;
      // A cheap bounding check before the trigonometry.
      if ((station.point.latitude - priced.point.latitude).abs() > 0.002) {
        continue;
      }
      final metres = GeoCalculations.distanceMeters(
        station.point,
        priced.point,
      );
      if (metres <= nearestMetres) {
        nearest = station;
        nearestMetres = metres;
      }
    }
    if (nearest != null) {
      claimed.add(nearest);
      options[nearest] = FuelStopOption(
        station: nearest,
        priced: priced,
        quote: quote,
        source: source,
        fetchedAt: snapshot.fetchedAt,
      );
    } else if (quote != null) {
      extra.add(
        FuelStopOption(
          station: FuelStation(
            id: 'priced:${priced.id}',
            kind: FuelStationKind.fuel,
            point: priced.point,
            label: priced.name ?? priced.brand ?? 'Fuel station',
            sells: preference.kind.bit,
          ),
          priced: priced,
          quote: quote,
          source: source,
          fetchedAt: snapshot.fetchedAt,
        ),
      );
    }
  }
  return [...options.values, ...extra];
}

/// The short label under a map pin: the price and how old it is, or nothing.
///
/// "142.9p · 14:05" while current, the time being the relay's confirmation;
/// "142.9p · 3 Oct" once stale, which the map draws dimmed. A price whose own
/// report is over a month old is not put on the map at all: the pin's detail
/// says when it was last reported instead.
({String text, bool current})? fuelPinLabel(
  FuelStopOption option,
  DateTime now,
) {
  final quote = option.quote;
  final source = option.source;
  final fetchedAt = option.fetchedAt;
  if (quote == null || source == null || fetchedAt == null) return null;
  final price = formatFuelPrice(quote.minorPerLitre, source.currency);
  switch (option.freshness(now)) {
    case FuelPriceFreshness.current:
      return (text: '$price · ${_clock(source.checkedAt!)}', current: true);
    case FuelPriceFreshness.stale:
      final checked = source.checkedAt;
      final asOf = checked == null || fetchedAt.isBefore(checked)
          ? fetchedAt
          : checked;
      return (text: '$price · ${_day(asOf)}', current: false);
    case FuelPriceFreshness.unconfirmed:
    case null:
      return null;
  }
}
