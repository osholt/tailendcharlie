import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../domain/imported_route.dart';
import 'gpx_parser.dart';
import 'road_routing.dart';

/// One of the routes bundled with the app for Ride Lab and the map's demo
/// action (#934).
///
/// Every route ships with its own navigation decisions, so choosing one never
/// needs a routing request, and each states which side of the road traffic
/// uses (the decisions are marked as confirmed, not inferred from a server).
class DemoRoute {
  const DemoRoute({
    required this.id,
    required this.title,
    required this.region,
    required this.summary,
    required this.gpxAsset,
    required this.maneuversAsset,
  });

  /// Stored as the rider's remembered choice. Never changes once shipped.
  final String id;

  /// The route's own name, as its GPX carries it.
  final String title;

  /// Where it is, for the chooser: the country and, at a glance, the side of
  /// the road traffic keeps to.
  final String region;
  final String summary;
  final String gpxAsset;
  final String maneuversAsset;

  /// The file name the loaded route carries, which is how a route in a ride is
  /// recognised as one of these without storing anything extra.
  String get sourceFileName =>
      gpxAsset.substring(gpxAsset.lastIndexOf('/') + 1);
}

/// The bundled demo routes.
abstract final class DemoRoutes {
  /// Public roads through the Cotswolds, driven on the left. Joins nobody's
  /// home or start point: it begins on a B-road junction and ends in a market
  /// town centre.
  static const cotswolds = DemoRoute(
    id: 'cotswolds-castle-combe-tetbury',
    title: 'Castle Combe to Tetbury — Cotswolds',
    region: 'United Kingdom · left-hand traffic',
    summary: '24.5 km of country roads into a market town',
    gpxAsset: 'assets/demo_route_cotswolds.gpx',
    maneuversAsset: 'assets/demo_route_cotswolds_maneuvers.json',
  );

  /// The original demo: a stretch of the D 980 ending at a French roundabout.
  static const france = DemoRoute(
    id: 'france-argentat-saint-privat',
    title: 'Argentat to Saint-Privat — France',
    region: 'France · right-hand traffic',
    summary: '17.9 km of the D 980, ending at a roundabout',
    gpxAsset: 'assets/demo_route.gpx',
    maneuversAsset: 'assets/demo_route_maneuvers.json',
  );

  /// In the order the chooser lists them.
  static const all = [cotswolds, france];

  /// What a rider who has never chosen gets: nearest to where this app's
  /// riders ride.
  static const fallback = cotswolds;

  static DemoRoute byId(String? id) =>
      all.firstWhere((route) => route.id == id, orElse: () => fallback);

  /// The bundled route a loaded route came from, or null for any other.
  static DemoRoute? forSourceFileName(String? fileName) {
    for (final route in all) {
      if (route.sourceFileName == fileName) return route;
    }
    return null;
  }
}

class BundledDemoRouteLoader {
  const BundledDemoRouteLoader(this.demo);

  final DemoRoute demo;

  Future<ImportedRoute> load() async {
    final data = await rootBundle.load(demo.gpxAsset);
    final route = const GpxParser().parse(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      routeId: const Uuid().v4(),
      sourceFileName: demo.sourceFileName,
      importedAt: DateTime.now(),
    );
    return ImportedRoute(
      id: route.id,
      name: route.name,
      description: route.description,
      importedAt: route.importedAt,
      sourceFileName: route.sourceFileName,
      paths: route.paths,
      waypoints: route.waypoints,
      maneuvers: await loadManeuvers(),
    );
  }

  /// Navigation decisions bundled with the offline demo route. They were
  /// generated from OSRM steps for the same road-following route, so the demo
  /// does not need a network request before it can demonstrate a bike drop.
  /// Each states which side of the road traffic keeps to, confirmed by hand
  /// for the country the route is in.
  Future<List<RoadRouteManeuver>> loadManeuvers() async {
    final data = await rootBundle.loadString(demo.maneuversAsset);
    final decoded = jsonDecode(data);
    if (decoded is! Map || decoded['maneuvers'] is! List) {
      throw const FormatException('Bundled demo manoeuvres are invalid.');
    }
    return List.unmodifiable(
      (decoded['maneuvers'] as List)
          .whereType<Map>()
          .map(
            (item) =>
                RoadRouteManeuver.fromJson(Map<String, Object?>.from(item)),
          )
          .toList(growable: false),
    );
  }
}
