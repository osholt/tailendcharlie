/// The fuel a rider's bike takes, which decides what "Navigate to fuel" looks
/// for and which price the map shows (#951).
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What goes in the tank. The bit values are shared with the bundled station
/// layer (`tools/discovery/generate_fuel_stations.py`, `fuelGradeBits`).
enum FuelKind {
  e10(bit: 1, apiValue: 'e10', label: 'Unleaded (E10)'),
  e5(bit: 2, apiValue: 'e5', label: 'Super unleaded (E5)'),
  diesel(bit: 4, apiValue: 'diesel', label: 'Diesel'),
  electric(bit: 0, apiValue: 'electric', label: 'Electric');

  const FuelKind({
    required this.bit,
    required this.apiValue,
    required this.label,
  });

  /// The grade's bit in the station layer's masks. Electric has none: a
  /// charger is a different kind of station altogether.
  final int bit;

  /// The grade's name in the relay's price response.
  final String apiValue;

  final String label;

  /// Sold by nearly every forecourt: standard unleaded and diesel. A station
  /// whose map entry does not list its grades is taken to sell these. Super
  /// unleaded is not universal, so an unlisted station is ranked lower and
  /// marked for it, as is a charger whose connectors are not mapped.
  bool get commonlyStocked => this == e10 || this == diesel;
}

/// A charging connector. The bit values are shared with the bundled station
/// layer (`connectorBits`). A tethered Type 2 cable counts as Type 2: it serves
/// the same vehicles.
enum ChargerConnector {
  type2(bit: 1, label: 'Type 2'),
  ccs(bit: 2, label: 'CCS'),
  chademo(bit: 4, label: 'CHAdeMO'),
  threePin(bit: 8, label: 'UK 3-pin');

  const ChargerConnector({required this.bit, required this.label});

  final int bit;
  final String label;

  static int maskOf(Iterable<ChargerConnector> connectors) =>
      connectors.fold(0, (mask, connector) => mask | connector.bit);

  static List<ChargerConnector> fromMask(int mask) => [
    for (final connector in values)
      if (mask & connector.bit != 0) connector,
  ];
}

@immutable
class FuelPreference {
  const FuelPreference(this.kind, {this.connectors = const {}});

  final FuelKind kind;

  /// The connectors the bike takes. Only meaningful for [FuelKind.electric];
  /// empty there means "any connector".
  final Set<ChargerConnector> connectors;

  bool get isElectric => kind == FuelKind.electric;

  /// The search action's wording.
  String get searchLabel =>
      isElectric ? 'Navigate to charger' : 'Navigate to fuel';

  String get summary {
    if (!isElectric || connectors.isEmpty) return kind.label;
    final names = [
      for (final connector in ChargerConnector.values)
        if (connectors.contains(connector)) connector.label,
    ];
    return '${kind.label} · ${names.join(', ')}';
  }

  /// Stored as `e10`, `diesel`, `electric:type2,ccs` and so on.
  String encode() {
    if (!isElectric || connectors.isEmpty) return kind.apiValue;
    final names = [
      for (final connector in ChargerConnector.values)
        if (connectors.contains(connector)) connector.name,
    ];
    return '${kind.apiValue}:${names.join(',')}';
  }

  /// The stored value, or null when it is not one this build understands.
  static FuelPreference? decode(String? value) {
    if (value == null || value.isEmpty) return null;
    final parts = value.split(':');
    final kind = FuelKind.values
        .where((kind) => kind.apiValue == parts.first)
        .firstOrNull;
    if (kind == null) return null;
    if (kind != FuelKind.electric || parts.length < 2) {
      return FuelPreference(kind);
    }
    return FuelPreference(
      kind,
      connectors: {
        for (final name in parts[1].split(','))
          ?ChargerConnector.values.where((c) => c.name == name).firstOrNull,
      },
    );
  }

  @override
  bool operator ==(Object other) =>
      other is FuelPreference &&
      other.kind == kind &&
      setEquals(other.connectors, connectors);

  @override
  int get hashCode => Object.hash(kind, Object.hashAllUnordered(connectors));
}

/// The rider's saved fuel preference.
///
/// One instance for the whole app ([shared]), so the map, the search and
/// Settings never disagree about it.
class FuelPreferenceController extends ChangeNotifier {
  FuelPreferenceController._(this._preferences, this._value);

  /// Kept in memory only, for tests and previews.
  factory FuelPreferenceController.inMemory([
    FuelPreference value = defaultPreference,
  ]) => FuelPreferenceController._(null, value);

  static const preferenceKey = 'fuel_preference_v1';

  /// UK standard unleaded has been E10 since September 2021, and is what most
  /// bikes on the road take.
  static const defaultPreference = FuelPreference(FuelKind.e10);

  final SharedPreferences? _preferences;
  FuelPreference _value;

  FuelPreference get value => _value;

  static Future<FuelPreferenceController> load() async {
    final preferences = await SharedPreferences.getInstance();
    return FuelPreferenceController._(
      preferences,
      FuelPreference.decode(preferences.getString(preferenceKey)) ??
          defaultPreference,
    );
  }

  static FuelPreferenceController? _shared;
  static Future<FuelPreferenceController>? _loading;

  /// The app's one controller, loaded on first use.
  ///
  /// The loaded controller is kept, not the future that loaded it, so each
  /// caller awaits a fresh future of its own.
  static Future<FuelPreferenceController> shared() async {
    if (_shared case final controller?) return controller;
    try {
      return _shared = await (_loading ??= load());
    } finally {
      // A failed read is retried next time rather than remembered.
      _loading = null;
    }
  }

  @visibleForTesting
  static void debugSetShared(FuelPreferenceController? controller) {
    _shared = controller;
    _loading = null;
  }

  Future<void> set(FuelPreference value) async {
    if (value == _value) return;
    _value = value;
    notifyListeners();
    await _preferences?.setString(preferenceKey, value.encode());
  }
}
