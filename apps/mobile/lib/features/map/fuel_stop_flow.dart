/// Between the map's route types and the fuel stop search (#951).
///
/// The fuel services work in `domain/geo_point.dart`; the map and the plan
/// surface work in the route model's points. This is the one place the two
/// meet, so neither large file has to import both and rename one.
library;

import '../../domain/geo_point.dart' as geo;
import '../../domain/imported_route.dart';
import '../../domain/ride_plan.dart';
import '../../services/fuel_prices.dart';
import '../../services/fuel_station_catalogue.dart';
import '../../services/fuel_stop_finder.dart';
import '../../services/fuel_stop_ranking.dart';

/// The GPX symbol a fuel stop is saved with, so other navigation apps draw a
/// pump rather than a flag.
const fuelStopSymbol = 'Gas Station';

geo.GeoPoint _geo(GeoPoint point) =>
    geo.GeoPoint(latitude: point.latitude, longitude: point.longitude);

/// Where to search, from what the map knows.
///
/// [remainingPaths] is the route still to ride while navigating; it wins when
/// it has a line. Otherwise [routePath] is cut at the rider if they are on it,
/// or taken whole if they are not (a plan made from somewhere else). Without a
/// route, the search is around [rider]. Null when there is neither.
FuelStopQuery? fuelStopQueryFor({
  List<GeoPoint>? routePath,
  List<List<GeoPoint>>? remainingPaths,
  GeoPoint? rider,
}) {
  final origin = rider == null ? null : _geo(rider);
  final remaining = [
    for (final path in remainingPaths ?? const <List<GeoPoint>>[])
      for (final point in path) _geo(point),
  ];
  if (remaining.length >= 2) {
    return FuelStopQuery(routeAhead: remaining, origin: origin);
  }
  final path = [
    for (final point in routePath ?? const <GeoPoint>[]) _geo(point),
  ];
  if (path.length >= 2) {
    final ahead = origin == null ? null : routeAheadOf(path, origin);
    return FuelStopQuery(routeAhead: ahead ?? path, origin: origin);
  }
  if (origin == null) return null;
  return FuelStopQuery(origin: origin);
}

String _description(FuelStopOption option) {
  final station = option.station;
  return station.kind == FuelStationKind.charging
      ? 'Charger · ${station.chargerSummary}'
      : 'Fuel station';
}

/// The chosen station as a stop on a plan.
RidePlanPlace fuelStopPlace(FuelStopOption option) => RidePlanPlace(
  point: GeoPoint(
    latitude: option.station.point.latitude,
    longitude: option.station.point.longitude,
  ),
  label: option.label,
  description: _description(option),
  symbol: fuelStopSymbol,
);

/// The chosen station as a waypoint on a route being edited.
RouteWaypoint fuelStopWaypoint(FuelStopOption option) =>
    fuelStopPlace(option).toWaypoint(defaultSymbol: fuelStopSymbol);
