/// Finding a fuel stop: the bundled stations, the relay's prices where it has
/// them, and the ranking (#951).
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/geo_point.dart';
import 'fuel_preference.dart';
import 'fuel_prices.dart';
import 'fuel_station_catalogue.dart';
import 'fuel_stop_ranking.dart';

/// Where to look: along the route still to ride, or around the rider.
@immutable
class FuelStopQuery {
  const FuelStopQuery({this.routeAhead, this.origin});

  /// The route still to ride, rider first. Fewer than two points means none.
  final List<GeoPoint>? routeAhead;
  final GeoPoint? origin;

  bool get hasRoute => (routeAhead?.length ?? 0) >= 2;
}

@immutable
class FuelStopSearchResult {
  const FuelStopSearchResult({
    required this.preference,
    required this.candidates,
    required this.prices,
    required this.attributions,
    required this.alongRoute,
    this.reportErrorUrls = const [],
    this.coverageCaveat = '',
  });

  final FuelPreference preference;
  final List<FuelStopCandidate> candidates;
  final FuelPriceAvailability prices;

  /// Every source the rider is shown data from, map and prices both.
  final List<String> attributions;
  final List<Uri> reportErrorUrls;
  final String coverageCaveat;
  final bool alongRoute;
}

typedef FuelStationCatalogueLoader = Future<FuelStationCatalogue> Function();
typedef FuelPriceFetch = Future<FuelPriceResult> Function(List<FuelPriceTile>);

class FuelStopFinder {
  FuelStopFinder({
    required this.catalogue,
    required this.preference,
    required this.fetchPrices,
    DateTime Function()? clock,
    this.rules = const FuelStopRankingRules(),
  }) : _clock = clock ?? DateTime.now;

  /// The app's finder: the bundled layer, the saved preference and the relay.
  static Future<FuelStopFinder> shared() async => FuelStopFinder(
    catalogue: FuelStationCatalogue.shared,
    preference: await FuelPreferenceController.shared(),
    fetchPrices: RelayFuelPriceClient.shared().fetch,
  );

  final FuelStationCatalogueLoader catalogue;
  final FuelPreferenceController preference;
  final FuelPriceFetch fetchPrices;
  final FuelStopRankingRules rules;
  final DateTime Function() _clock;

  Future<FuelStopSearchResult> find(FuelStopQuery query) async {
    final wanted = preference.value;
    final bounds = fuelSearchBounds(
      routeAhead: query.routeAhead,
      origin: query.origin,
      rules: rules,
    );
    final layer = await catalogue();
    if (bounds == null) {
      return FuelStopSearchResult(
        preference: wanted,
        candidates: const [],
        prices: FuelPriceAvailability.notOffered,
        attributions: [if (layer.attribution.isNotEmpty) layer.attribution],
        alongRoute: query.hasRoute,
        coverageCaveat: layer.coverageCaveat,
      );
    }
    final stations = layer
        .within(
          west: bounds.west,
          south: bounds.south,
          east: bounds.east,
          north: bounds.north,
          kind: wanted.isElectric
              ? FuelStationKind.charging
              : FuelStationKind.fuel,
        )
        .toList(growable: false);
    var prices = FuelPriceResult(
      FuelPriceAvailability.notOffered,
      FuelPriceSnapshot.empty,
    );
    // Chargers have no price source yet (see the decision record).
    if (!wanted.isElectric) {
      prices = await fetchPrices(
        fuelPriceTiles(
          west: bounds.west,
          south: bounds.south,
          east: bounds.east,
          north: bounds.north,
        ),
      );
    }
    final options = attachFuelPrices(
      stations: stations,
      snapshot: prices.snapshot,
      preference: wanted,
    );
    final candidates = rankFuelStops(
      options: options,
      preference: wanted,
      now: _clock(),
      routeAhead: query.routeAhead,
      origin: query.origin,
      rules: rules,
    );
    final usedSources = {
      for (final candidate in candidates) ?candidate.option.source,
    };
    return FuelStopSearchResult(
      preference: wanted,
      candidates: candidates,
      prices: prices.availability,
      attributions: [
        if (layer.attribution.isNotEmpty) layer.attribution,
        for (final source in usedSources) source.attribution,
      ],
      reportErrorUrls: [
        for (final source in usedSources) ?source.reportErrorUrl,
      ],
      alongRoute: query.hasRoute,
      coverageCaveat: layer.coverageCaveat,
    );
  }
}
