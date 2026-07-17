import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../domain/imported_route.dart';
import 'gpx_parser.dart';
import 'road_routing.dart';

class BundledDemoRouteLoader {
  const BundledDemoRouteLoader();

  Future<ImportedRoute> load() async {
    final data = await rootBundle.load('assets/demo_route.gpx');
    return const GpxParser().parse(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      routeId: const Uuid().v4(),
      sourceFileName: 'demo_route.gpx',
      importedAt: DateTime.now(),
    );
  }

  /// Navigation decisions bundled with the offline demo route. They were
  /// generated from OSRM steps for the same road-following route, so the demo
  /// does not need a network request before it can demonstrate a bike drop.
  Future<List<RoadRouteManeuver>> loadManeuvers() async {
    final data = await rootBundle.loadString(
      'assets/demo_route_maneuvers.json',
    );
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
          .where((maneuver) => maneuver.requiresSecondBikeDrop),
    );
  }
}
