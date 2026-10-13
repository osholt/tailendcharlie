/// Observations from public charging feeds; never a promise that a socket is free.
library;

import '../domain/geo_point.dart';
import 'fuel_preference.dart';

class ChargerSocket {
  const ChargerSocket({
    required this.type,
    required this.status,
    required this.kilowatts,
    this.pencePerKwh,
    this.priceCheckedAt,
  });
  final int type;
  final String status;
  final double kilowatts;
  final double? pencePerKwh;
  final DateTime? priceCheckedAt;
}

class ChargerReading {
  const ChargerReading({
    required this.id,
    required this.name,
    required this.point,
    required this.source,
    required this.attribution,
    required this.checkedAt,
    required this.sockets,
  });
  final String id, name, source, attribution;
  final GeoPoint point;
  final DateTime checkedAt;
  final List<ChargerSocket> sockets;

  List<ChargerSocket> matching(FuelPreference preference) {
    final mask = ChargerConnector.maskOf(preference.connectors);
    return sockets.where((s) => mask == 0 || (s.type & mask) != 0).toList();
  }

  bool fresh(DateTime now) {
    final age = now.difference(checkedAt);
    return !age.isNegative && age <= const Duration(minutes: 2);
  }

  bool available(FuelPreference preference, DateTime now) =>
      fresh(now) && matching(preference).any((s) => s.status == 'AVAILABLE');

  bool unusable(FuelPreference preference, DateTime now) {
    final matches = matching(preference);
    return fresh(now) &&
        matches.isNotEmpty &&
        matches.every(
          (s) =>
              const {'INOPERATIVE', 'OUTOFORDER', 'BLOCKED'}.contains(s.status),
        );
  }

  String describe(FuelPreference preference, DateTime now) {
    final matches = matching(preference);
    final age = now.difference(checkedAt);
    final ageText = age.isNegative
        ? 'observation time uncertain'
        : age.inMinutes < 1
        ? 'checked just now'
        : 'checked ${age.inMinutes} min ago';
    final availableCount = matches.where((s) => s.status == 'AVAILABLE').length;
    final String status;
    if (!fresh(now)) {
      status = 'Status stale; availability unknown';
    } else if (matches.isEmpty) {
      status = 'Compatible socket availability unknown';
    } else if (availableCount > 0) {
      status =
          '$availableCount compatible connector${availableCount == 1 ? '' : 's'} observed available';
    } else if (unusable(preference, now)) {
      status = 'Compatible connectors reported unavailable';
    } else if (matches.every(
      (s) => const {'CHARGING', 'RESERVED'}.contains(s.status),
    )) {
      status = 'Compatible connectors occupied or reserved';
    } else {
      status = 'Availability unknown';
    }
    final pricedSockets = matches
        .where(
          (s) =>
              s.pencePerKwh != null &&
              s.priceCheckedAt != null &&
              !now.difference(s.priceCheckedAt!).isNegative &&
              now.difference(s.priceCheckedAt!) <= const Duration(hours: 24),
        )
        .toList();
    final prices = pricedSockets.map((s) => s.pencePerKwh!).toList()..sort();
    final priceAge = pricedSockets.isEmpty
        ? null
        : pricedSockets
              .map((s) => now.difference(s.priceCheckedAt!).inMinutes)
              .reduce((a, b) => a > b ? a : b);
    final price = prices.isEmpty
        ? 'Tariff unknown'
        : '${prices.length == matches.length && prices.first == prices.last ? '' : 'From '}'
              '${prices.first.toStringAsFixed(1)}p/kWh incl. VAT (tariff checked $priceAge min ago)';
    return '$status · $ageText. $price. Reliability not yet measured.';
  }
}
