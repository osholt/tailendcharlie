/// The bundled fuel station and charger layer, from OpenStreetMap (#951).
///
/// Bundled rather than fetched, so a rider without signal still finds the
/// nearest pump. Prices are not in it; they come from the relay and are joined
/// on at run time (see `fuel_prices.dart`).
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../domain/geo_point.dart';
import 'fuel_preference.dart';

enum FuelStationKind { fuel, charging }

/// Whether a station can serve the rider's fuel, as far as the map knows.
enum FuelCompatibility {
  /// Tagged as selling it, or with a matching connector.
  known,

  /// Nothing recorded either way. Kept, and said so.
  unrecorded,

  /// Tagged as not selling it, or a charger with none of the rider's
  /// connectors, or the wrong kind of station altogether.
  incompatible,
}

@immutable
class FuelStation {
  const FuelStation({
    required this.id,
    required this.kind,
    required this.point,
    required this.label,
    this.sells = 0,
    this.doesNotSell = 0,
    this.connectors = 0,
    this.maximumKilowatts = 0,
  });

  /// Stable across app launches for the same extract: the kind and position.
  final String id;
  final FuelStationKind kind;
  final GeoPoint point;

  /// Name, brand, operator or a generic word. Never an identifier (#860).
  final String label;

  /// Bit masks over [FuelKind.bit].
  final int sells;
  final int doesNotSell;

  /// Bit mask over [ChargerConnector.bit]; zero means none recorded.
  final int connectors;

  /// Highest tagged output, or zero when none is.
  final int maximumKilowatts;

  FuelCompatibility compatibilityWith(FuelPreference preference) {
    if (preference.isElectric) {
      if (kind != FuelStationKind.charging) {
        return FuelCompatibility.incompatible;
      }
      if (connectors == 0) return FuelCompatibility.unrecorded;
      final wanted = ChargerConnector.maskOf(preference.connectors);
      if (wanted == 0) return FuelCompatibility.known;
      return connectors & wanted != 0
          ? FuelCompatibility.known
          : FuelCompatibility.incompatible;
    }
    if (kind != FuelStationKind.fuel) return FuelCompatibility.incompatible;
    final bit = preference.kind.bit;
    if (sells & bit != 0) return FuelCompatibility.known;
    if (doesNotSell & bit != 0) return FuelCompatibility.incompatible;
    return FuelCompatibility.unrecorded;
  }

  /// "Type 2, CCS · 50 kW", or what is missing.
  String get chargerSummary {
    final names = ChargerConnector.fromMask(
      connectors,
    ).map((connector) => connector.label);
    final parts = [
      names.isEmpty ? 'Connectors not recorded' : names.join(', '),
      if (maximumKilowatts > 0) '$maximumKilowatts kW',
    ];
    return parts.join(' · ');
  }
}

class FuelStationCatalogue {
  FuelStationCatalogue({
    required List<FuelStation> stations,
    required this.attribution,
    required this.extractDate,
    required this.boundedRegion,
    required this.coverageCaveat,
  }) : stations = List.unmodifiable(stations),
       _cells = _index(stations);

  static final empty = FuelStationCatalogue(
    stations: const [],
    attribution: '',
    extractDate: '',
    boundedRegion: '',
    coverageCaveat: '',
  );

  static const assetKey = 'assets/fuel_stations.json';
  static const _cellDegrees = 0.1;

  final List<FuelStation> stations;
  final String attribution;
  final String extractDate;
  final String boundedRegion;
  final String coverageCaveat;
  final Map<(int, int), List<FuelStation>> _cells;

  static FuelStationCatalogue? _shared;
  static Future<FuelStationCatalogue>? _loading;

  /// The bundled layer, read once and shared by every map and search.
  ///
  /// The loaded catalogue is kept, not the future that loaded it, so each
  /// caller awaits a fresh future of its own.
  static Future<FuelStationCatalogue> shared({AssetBundle? bundle}) async {
    if (_shared case final catalogue?) return catalogue;
    try {
      return _shared = await (_loading ??= loadAsset(bundle: bundle));
    } finally {
      // A failed read is retried next time rather than cached as empty.
      _loading = null;
    }
  }

  @visibleForTesting
  static void debugSetShared(FuelStationCatalogue? catalogue) {
    _shared = catalogue;
    _loading = null;
  }

  static Future<FuelStationCatalogue> loadAsset({AssetBundle? bundle}) async {
    final text = await (bundle ?? rootBundle).loadString(assetKey);
    return FuelStationCatalogue.fromJson(
      jsonDecode(text) as Map<String, Object?>,
    );
  }

  factory FuelStationCatalogue.fromJson(Map<String, Object?> json) {
    if (json['schemaVersion'] != 1) {
      throw const FormatException('Unsupported fuel station layer version.');
    }
    final stations = <FuelStation>[];
    for (final row in json['fuel'] as List<Object?>? ?? const []) {
      final station = _row(row, FuelStationKind.fuel);
      if (station != null) stations.add(station);
    }
    for (final row in json['charging'] as List<Object?>? ?? const []) {
      final station = _row(row, FuelStationKind.charging);
      if (station != null) stations.add(station);
    }
    return FuelStationCatalogue(
      stations: stations,
      attribution: json['attribution'] as String? ?? '',
      extractDate: json['extractDate'] as String? ?? '',
      boundedRegion: json['boundedRegion'] as String? ?? '',
      coverageCaveat: json['coverageCaveat'] as String? ?? '',
    );
  }

  /// One compact row: `[lat_e5, lon_e5, label, a, b]`, where `a`/`b` are the
  /// sells/does-not-sell masks for fuel and connectors/kW for chargers. A
  /// malformed row is skipped rather than failing the whole layer.
  static FuelStation? _row(Object? row, FuelStationKind kind) {
    if (row is! List || row.length < 5) return null;
    final [latitude, longitude, label, first, second, ...] = row;
    if (latitude is! int || longitude is! int || label is! String) return null;
    if (first is! int || second is! int) return null;
    final lat = latitude / 100000;
    final lon = longitude / 100000;
    if (lat < -90 || lat > 90 || lon < -180 || lon > 180) return null;
    final prefix = kind == FuelStationKind.fuel ? 'fuel' : 'charger';
    return FuelStation(
      id: '$prefix:$latitude:$longitude',
      kind: kind,
      point: GeoPoint(latitude: lat, longitude: lon),
      label: label,
      sells: kind == FuelStationKind.fuel ? first : 0,
      doesNotSell: kind == FuelStationKind.fuel ? second : 0,
      connectors: kind == FuelStationKind.charging ? first : 0,
      maximumKilowatts: kind == FuelStationKind.charging ? second : 0,
    );
  }

  static Map<(int, int), List<FuelStation>> _index(List<FuelStation> stations) {
    final cells = <(int, int), List<FuelStation>>{};
    for (final station in stations) {
      cells.putIfAbsent(_cell(station.point), () => []).add(station);
    }
    return cells;
  }

  static (int, int) _cell(GeoPoint point) => (
    (point.latitude / _cellDegrees).floor(),
    (point.longitude / _cellDegrees).floor(),
  );

  /// Every station inside the box, of [kind] when given.
  Iterable<FuelStation> within({
    required double west,
    required double south,
    required double east,
    required double north,
    FuelStationKind? kind,
  }) sync* {
    final (southRow, westColumn) = _cell(
      GeoPoint(latitude: math.max(-90, south), longitude: math.max(-180, west)),
    );
    final (northRow, eastColumn) = _cell(
      GeoPoint(latitude: math.min(90, north), longitude: math.min(180, east)),
    );
    for (var row = southRow; row <= northRow; row++) {
      for (var column = westColumn; column <= eastColumn; column++) {
        for (final station in _cells[(row, column)] ?? const <FuelStation>[]) {
          if (kind != null && station.kind != kind) continue;
          final point = station.point;
          if (point.latitude < south || point.latitude > north) continue;
          if (point.longitude < west || point.longitude > east) continue;
          yield station;
        }
      }
    }
  }
}
