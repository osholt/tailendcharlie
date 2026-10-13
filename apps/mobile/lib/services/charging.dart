/// Capability-gated viewport reads. Offline OSM remains the fallback.
library;

import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../domain/geo_point.dart';
import '../internet/internet_relay_client.dart';
import 'charging_data.dart';
import 'fuel_preference.dart';
import 'fuel_prices.dart';
import 'fuel_station_catalogue.dart';
import 'geo_calculations.dart';

DateTime? _epoch(Object? value) =>
    value is num && value.isFinite && value > 0 && value < 4102444800
    ? DateTime.fromMillisecondsSinceEpoch((value * 1000).round(), isUtc: true)
    : null;

List<ChargerReading> parseChargers(Map<String, dynamic> data) {
  if (data['schemaVersion'] != 1 ||
      data['locations'] is! List ||
      data['sources'] is! List) {
    throw const FormatException('Unsupported charging response');
  }
  final locations = data['locations'] as List;
  if (locations.length > 300) throw const FormatException('Too many chargers');
  final sources = <String, String>{};
  for (final row in data['sources'] as List) {
    if (row is Map && row['id'] is String && row['attribution'] is String) {
      sources[row['id'] as String] = row['attribution'] as String;
    }
  }
  final result = <ChargerReading>[];
  for (final row in locations) {
    if (row is! Map) continue;
    final lat = row['lat'],
        lon = row['lon'],
        id = row['id'],
        source = row['source'];
    final checked = _epoch(row['checkedAt']);
    if (lat is! num ||
        lon is! num ||
        !lat.isFinite ||
        !lon.isFinite ||
        lat.abs() > 90 ||
        lon.abs() > 180 ||
        id is! String ||
        source is! String ||
        checked == null ||
        row['connectors'] is! List ||
        !sources.containsKey(source)) {
      continue;
    }
    final sockets = <ChargerSocket>[];
    for (final raw in (row['connectors'] as List).take(1000)) {
      if (raw is! Map) continue;
      final type = raw['type'],
          watts = raw['kilowatts'],
          price = raw['pencePerKwh'];
      if (type is! int || type < 0 || type > 15) continue;
      sockets.add(
        ChargerSocket(
          type: type,
          status: raw['status'] is String ? raw['status'] as String : 'UNKNOWN',
          kilowatts:
              watts is num && watts.isFinite && watts >= 0 && watts <= 2000
              ? watts.toDouble()
              : 0,
          pencePerKwh:
              price is num && price.isFinite && price >= 0 && price <= 2000
              ? price.toDouble()
              : null,
          priceCheckedAt: _epoch(raw['priceCheckedAt']),
        ),
      );
    }
    result.add(
      ChargerReading(
        id: id,
        name: row['name'] is String ? row['name'] as String : 'Charger',
        point: GeoPoint(latitude: lat.toDouble(), longitude: lon.toDouble()),
        source: source,
        attribution: sources[source]!,
        checkedAt: checked,
        sockets: sockets,
      ),
    );
  }
  return result;
}

class RelayChargingClient {
  RelayChargingClient({
    required this.configuration,
    required this.compatibility,
    http.Client? client,
    DateTime Function()? clock,
  }) : _client = client ?? http.Client(),
       _clock = clock ?? DateTime.now;
  final InternetRelayConfiguration configuration;
  final RelayCompatibilityApi? compatibility;
  final http.Client _client;
  final DateTime Function() _clock;
  final _cache = <FuelPriceTile, (DateTime, List<ChargerReading>)>{};
  static RelayChargingClient? _shared;
  static RelayChargingClient shared() => _shared ??= () {
    final config = InternetRelayConfiguration.fromEnvironment();
    return RelayChargingClient(
      configuration: config,
      compatibility: config.isConfigured
          ? HttpInternetRelayClient(
              configuration: config,
              client: http.Client(),
            )
          : null,
    );
  }();

  Future<List<ChargerReading>> fetch(List<FuelPriceTile> tiles) async {
    if (!configuration.isConfigured || compatibility == null) return const [];
    try {
      final capabilities = await compatibility!.checkCompatibility();
      if (!capabilities.supports(RelayProtocolCapabilities.chargingStatus)) {
        return const [];
      }
    } on Object {
      return _cached(tiles);
    }
    final result = <String, ChargerReading>{};
    for (final tile in tiles.take(8)) {
      var hit = _cache[tile];
      if (hit == null ||
          _clock().difference(hit.$1) > const Duration(seconds: 60)) {
        try {
          final base = configuration.baseUri!;
          final path = base.path.endsWith('/')
              ? base.path.substring(0, base.path.length - 1)
              : base.path;
          final uri = base.replace(
            path: '$path/v1/charging/locations',
            queryParameters: {
              'west': '${tile.west}',
              'south': '${tile.south}',
              'east': '${tile.east}',
              'north': '${tile.north}',
            },
          );
          final request = http.Request('GET', uri)
            ..followRedirects = false
            ..headers.addAll(RelayClientDescriptor.current().headers);
          final response = await _client
              .send(request)
              .timeout(const Duration(seconds: 12));
          if (response.statusCode != 200) {
            await response.stream.listen((_) {}).cancel();
            throw const FormatException('Charging unavailable');
          }
          final bytes = <int>[];
          await for (final chunk in response.stream.timeout(
            const Duration(seconds: 12),
          )) {
            if (bytes.length + chunk.length > 2 * 1024 * 1024) {
              throw const FormatException('Charging response too large');
            }
            bytes.addAll(chunk);
          }
          final decoded = jsonDecode(utf8.decode(bytes));
          if (decoded is! Map<String, dynamic>) {
            throw const FormatException('Charging response invalid');
          }
          hit = (_clock(), parseChargers(decoded));
          _cache[tile] = hit;
          while (_cache.length > 64) {
            _cache.remove(_cache.keys.first);
          }
        } on Object {
          /* Retain original observation ages, never invent freshness. */
        }
      }
      for (final reading in hit?.$2 ?? <ChargerReading>[]) {
        if (_clock().difference(reading.checkedAt) <=
            const Duration(hours: 48)) {
          result[reading.id] = reading;
        }
      }
    }
    return result.values.toList();
  }

  List<ChargerReading> _cached(List<FuelPriceTile> tiles) => [
    for (final tile in tiles.take(8))
      for (final reading in _cache[tile]?.$2 ?? <ChargerReading>[])
        if (_clock().difference(reading.checkedAt) <= const Duration(hours: 48))
          reading,
  ];
}

List<FuelStopOption> attachChargers({
  required Iterable<FuelStation> stations,
  required List<ChargerReading> readings,
  required FuelPreference preference,
}) {
  final remaining = stations.toList();
  final result = <FuelStopOption>[];
  String normalized(String value) =>
      value.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');
  for (final reading in readings) {
    // Do not merge adjacent unrelated operators merely because they are close.
    remaining.removeWhere(
      (s) =>
          s.kind == FuelStationKind.charging &&
          s.label != 'Charger' &&
          normalized(s.label) == normalized(reading.name) &&
          GeoCalculations.distanceMeters(s.point, reading.point) < 40,
    );
    var mask = 0;
    var power = 0;
    for (final socket in reading.sockets) {
      mask |= socket.type;
      if (socket.kilowatts > power) power = socket.kilowatts.floor();
    }
    final station = FuelStation(
      id: 'live:${reading.id}',
      kind: FuelStationKind.charging,
      point: reading.point,
      label: reading.name,
      connectors: mask,
      maximumKilowatts: power,
    );
    if (station.compatibilityWith(preference) ==
        FuelCompatibility.incompatible) {
      continue;
    }
    result.add(
      FuelStopOption(
        station: station,
        charging: reading,
        chargingPreference: preference,
      ),
    );
  }
  result.addAll(remaining.map((s) => FuelStopOption(station: s)));
  return result;
}
