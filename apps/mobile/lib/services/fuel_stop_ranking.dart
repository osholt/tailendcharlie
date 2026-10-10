/// Which fuel stops to offer, best first (#951).
///
/// Pure: given stations, an optional route ahead and the rider's position, it
/// answers the same way every time. The rule is written out in
/// `docs/fuel-and-charging-data-decision.md` ("Navigate to fuel"):
///
/// ```
/// cost = distance to reach it      (along the route, or straight-line × 1.3)
///      + 2 × detour                (there and back off the route line, × 1.3)
///      + 500 m per penny a litre above the cheapest current price offered
///      + 1 km when the map does not record that it sells super unleaded or
///        has the rider's connector (E10 and diesel are near universal)
/// ```
///
/// Brand never enters into it. The Fuel Finder Fair Use terms forbid favouring
/// suppliers, and a rider low on fuel wants the nearest sensible pump.
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../domain/geo_point.dart';
import 'fuel_preference.dart';
import 'fuel_prices.dart';
import 'fuel_station_catalogue.dart';
import 'geo_calculations.dart';

@immutable
class FuelStopRankingRules {
  const FuelStopRankingRules({
    this.corridorMetres = 3000,
    this.lookAheadMetres = 80000,
    this.radiusMetres = 25000,
    this.roadFactor = 1.3,
    this.detourWeight = 2,
    this.metresPerPenny = 500,
    this.unrecordedPenaltyMetres = 1000,
    this.limit = 5,
  });

  /// How far off the route line a station may be.
  final double corridorMetres;

  /// How far ahead along the route to look.
  final double lookAheadMetres;

  /// How far from the rider to look when there is no route.
  final double radiusMetres;

  /// Roads are longer than straight lines. 1.3 is the usual UK figure for
  /// short rural distances.
  final double roadFactor;

  /// A detour is riding away from where the rider is going, so it counts for
  /// more than the same distance along the way.
  final double detourWeight;

  /// What a penny a litre is worth in extra riding. A station 4p a litre
  /// cheaper is worth 2 km more.
  final double metresPerPenny;

  /// A station whose grades or connectors are not mapped might not have the
  /// rider's. It is kept, and ranked as if a kilometre further away, unless
  /// the rider's fuel is one nearly every forecourt sells
  /// ([FuelKind.commonlyStocked]).
  final double unrecordedPenaltyMetres;

  final int limit;
}

@immutable
class FuelStopCandidate {
  const FuelStopCandidate({
    required this.option,
    required this.compatibility,
    required this.reachMetres,
    required this.detourMetres,
    required this.priceDifference,
    required this.costMetres,
    required this.alongRoute,
  });

  final FuelStopOption option;
  final FuelCompatibility compatibility;

  /// Riding distance to get level with it: along the route, or estimated from
  /// the straight line without one.
  final double reachMetres;

  /// Extra riding to leave the route, reach it and come back. Zero without a
  /// route.
  final double detourMetres;

  /// Pence (or cents) a litre above the cheapest current price offered, or
  /// null when this one has no current price.
  final double? priceDifference;

  final double costMetres;
  final bool alongRoute;
}

/// The best [FuelStopRankingRules.limit] stops for [preference].
///
/// With a [routeAhead] (the part of the route still to ride, rider first) a
/// station counts if it lies within the corridor and the look-ahead; a route
/// that passes it twice uses the first pass. Without one, stations within the
/// radius of [origin]. Closed and incompatible stations are never offered.
List<FuelStopCandidate> rankFuelStops({
  required Iterable<FuelStopOption> options,
  required FuelPreference preference,
  required DateTime now,
  List<GeoPoint>? routeAhead,
  GeoPoint? origin,
  FuelStopRankingRules rules = const FuelStopRankingRules(),
}) {
  final route = routeAhead != null && routeAhead.length >= 2
      ? routeAhead
      : null;
  if (route == null && origin == null) return const [];
  final reachable = <_Reach>[];
  for (final option in options) {
    if (option.closed) continue;
    final compatibility = option.station.compatibilityWith(preference);
    if (compatibility == FuelCompatibility.incompatible) continue;
    final reach = route != null
        ? _alongRoute(option.station.point, route, rules)
        : _aroundRider(option.station.point, origin!, rules);
    if (reach == null) continue;
    reachable.add(_Reach(option, compatibility, reach.$1, reach.$2));
  }
  final prices = [for (final item in reachable) ?item.option.currentPrice(now)];
  final cheapest = prices.isEmpty
      ? null
      : prices.reduce((a, b) => a < b ? a : b);
  final candidates = [
    for (final item in reachable)
      () {
        final price = item.option.currentPrice(now);
        final difference = price == null || cheapest == null
            ? null
            : price - cheapest;
        final cost =
            item.reachMetres +
            rules.detourWeight * item.detourMetres +
            (difference ?? 0) * rules.metresPerPenny +
            (item.compatibility == FuelCompatibility.unrecorded &&
                    !preference.kind.commonlyStocked
                ? rules.unrecordedPenaltyMetres
                : 0);
        return FuelStopCandidate(
          option: item.option,
          compatibility: item.compatibility,
          reachMetres: item.reachMetres,
          detourMetres: item.detourMetres,
          priceDifference: difference,
          costMetres: cost,
          alongRoute: route != null,
        );
      }(),
  ];
  candidates.sort((a, b) {
    final byCost = a.costMetres.compareTo(b.costMetres);
    return byCost != 0
        ? byCost
        : a.option.station.id.compareTo(b.option.station.id);
  });
  return candidates.take(rules.limit).toList(growable: false);
}

class _Reach {
  _Reach(this.option, this.compatibility, this.reachMetres, this.detourMetres);

  final FuelStopOption option;
  final FuelCompatibility compatibility;
  final double reachMetres;
  final double detourMetres;
}

(double, double)? _alongRoute(
  GeoPoint station,
  List<GeoPoint> route,
  FuelStopRankingRules rules,
) {
  final passes = GeoCalculations.passesNear(
    station,
    route,
    corridorMeters: rules.corridorMetres,
  );
  if (passes.isEmpty) return null;
  final first = passes.reduce(
    (a, b) => a.distanceAlongRouteMeters <= b.distanceAlongRouteMeters ? a : b,
  );
  if (first.distanceAlongRouteMeters > rules.lookAheadMetres) return null;
  return (
    first.distanceAlongRouteMeters,
    2 * first.distanceFromRouteMeters * rules.roadFactor,
  );
}

(double, double)? _aroundRider(
  GeoPoint station,
  GeoPoint origin,
  FuelStopRankingRules rules,
) {
  final metres = GeoCalculations.distanceMeters(origin, station);
  if (metres > rules.radiusMetres) return null;
  return (metres * rules.roadFactor, 0);
}

/// The box worth reading stations and prices for: the route ahead within the
/// look-ahead, or the radius around the rider, plus the corridor.
({double west, double south, double east, double north})? fuelSearchBounds({
  List<GeoPoint>? routeAhead,
  GeoPoint? origin,
  FuelStopRankingRules rules = const FuelStopRankingRules(),
}) {
  final points = <GeoPoint>[];
  double margin;
  if (routeAhead != null && routeAhead.length >= 2) {
    var travelled = 0.0;
    points.add(routeAhead.first);
    for (var index = 1; index < routeAhead.length; index++) {
      travelled += GeoCalculations.distanceMeters(
        routeAhead[index - 1],
        routeAhead[index],
      );
      points.add(routeAhead[index]);
      if (travelled > rules.lookAheadMetres) break;
    }
    margin = rules.corridorMetres;
  } else if (origin != null) {
    points.add(origin);
    margin = rules.radiusMetres;
  } else {
    return null;
  }
  var west = points.first.longitude;
  var east = west;
  var south = points.first.latitude;
  var north = south;
  for (final point in points) {
    if (point.longitude < west) west = point.longitude;
    if (point.longitude > east) east = point.longitude;
    if (point.latitude < south) south = point.latitude;
    if (point.latitude > north) north = point.latitude;
  }
  final latitudeMargin = margin / 111320;
  final longitudeMargin =
      margin /
      (111320 * math.cos((south + north) / 2 * math.pi / 180).clamp(0.2, 1.0));
  return (
    west: west - longitudeMargin,
    south: south - latitudeMargin,
    east: east + longitudeMargin,
    north: north + latitudeMargin,
  );
}

/// The part of [path] still ahead of [rider]: from the point on the path
/// nearest them to its end. Null when the rider is further than
/// [withinMetres] from the path, in which case the whole path is ahead of
/// them as far as a plan is concerned.
List<GeoPoint>? routeAheadOf(
  List<GeoPoint> path,
  GeoPoint rider, {
  double withinMetres = 3000,
}) {
  if (path.length < 2) return null;
  final projection = GeoCalculations.projectOntoPolyline(rider, path);
  if (projection.distanceFromRouteMeters > withinMetres) return null;
  var travelled = 0.0;
  for (var index = 0; index < path.length - 1; index++) {
    final segment = GeoCalculations.distanceMeters(
      path[index],
      path[index + 1],
    );
    if (travelled + segment >= projection.distanceAlongRouteMeters) {
      final fraction = segment == 0
          ? 0.0
          : ((projection.distanceAlongRouteMeters - travelled) / segment).clamp(
              0.0,
              1.0,
            );
      final start = path[index];
      final end = path[index + 1];
      return [
        GeoPoint(
          latitude: start.latitude + (end.latitude - start.latitude) * fraction,
          longitude:
              start.longitude + (end.longitude - start.longitude) * fraction,
        ),
        ...path.sublist(index + 1),
      ];
    }
    travelled += segment;
  }
  return [path.last];
}
