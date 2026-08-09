/// OSRM `route/v1` step fixtures for junctions that produced wrong or doubled
/// instructions in the field.
///
/// Every fixture uses the documented OSRM v5 response shape: a `roundabout` or
/// `rotary` step whose modifier describes *joining* the ring, an optional
/// `exit roundabout`/`exit rotary` step, and `bearing_before`/`bearing_after` in
/// degrees clockwise from true north. Coordinates are around Bristol, which is
/// the demo area used for field testing.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/services/road_routing.dart';

/// Ordered geometry for a fixture route, as `[longitude, latitude]` pairs.
typedef Coordinates = List<List<double>>;

/// Parses an OSRM response through the app's own client and saves it as a route,
/// so tests exercise the real request-to-persistence path.
Future<ImportedRoute> routeFromOsrmResponse(
  Map<String, Object?> response, {
  String id = 'fixture',
  Future<MappedMiniRoundaboutCatalogue> Function()? readMiniRoundabouts,
}) async {
  final service = OsrmRoadRoutingService(
    readMiniRoundabouts:
        readMiniRoundabouts ??
        (() async => MappedMiniRoundaboutCatalogue.empty),
    client: MockClient(
      (_) async => http.Response(
        jsonEncode(response),
        200,
        headers: const {'content-type': 'application/json'},
      ),
    ),
    baseUrl: Uri.parse('https://routing.example.test'),
  );
  final result = await service.routeThrough(const [
    GeoPoint(latitude: 51.4535, longitude: -2.5879),
    GeoPoint(latitude: 51.4900, longitude: -2.5430),
  ]);
  final route = ImportedRoute(
    id: id,
    name: 'Fixture route',
    importedAt: DateTime.utc(2026, 7, 25),
    sourceFileName: '$id.gpx',
    paths: [RoutePath(kind: RoutePathKind.track, points: result.points)],
    waypoints: const [],
    maneuvers: result.maneuvers,
  );
  // Prove the fixtures survive persistence: guidance must work offline after a
  // restart, from the stored route rather than a fresh routing call.
  return ImportedRoute.fromJsonString(route.toJsonString());
}

/// A UK roundabout ridden straight through, reported as two steps.
///
/// The entry modifier is `slight left` because joining a clockwise ring from the
/// south does bear left, and the exit modifier is `slight left` again relative to
/// travel around the ring. Announcing both is what produced "2 slight lefts" for
/// a manoeuvre that is straight on.
Map<String, Object?> ukRoundaboutStraightOnResponse() => _response(
  coordinates: [
    [-2.5879, 51.4535],
    [-2.5879, 51.4560],
    [-2.5878, 51.4566],
    [-2.5878, 51.4590],
    [-2.5877, 51.4640],
  ],
  distanceMeters: 1180,
  durationSeconds: 132,
  steps: [
    _step(
      name: 'Wells Road',
      ref: 'A37',
      drivingSide: 'left',
      type: 'depart',
      modifier: 'straight',
      bearingBefore: 0,
      bearingAfter: 1,
      location: [-2.5879, 51.4535],
    ),
    _step(
      name: 'Wells Road',
      ref: 'A37',
      drivingSide: 'left',
      type: 'roundabout',
      modifier: 'slight left',
      exit: 2,
      bearingBefore: 1,
      bearingAfter: 315,
      location: [-2.5879, 51.4560],
      lanes: [
        {
          'indications': ['left'],
          'valid': false,
        },
        {
          'indications': ['straight'],
          'valid': true,
        },
        {
          'indications': ['right'],
          'valid': false,
        },
      ],
    ),
    _step(
      name: 'Wells Road',
      ref: 'A37',
      drivingSide: 'left',
      type: 'exit roundabout',
      modifier: 'slight left',
      bearingBefore: 45,
      bearingAfter: 2,
      location: [-2.5878, 51.4566],
    ),
    _step(
      name: 'Wells Road',
      ref: 'A37',
      drivingSide: 'left',
      type: 'arrive',
      modifier: 'straight',
      bearingBefore: 2,
      bearingAfter: 0,
      location: [-2.5877, 51.4640],
    ),
  ],
);

/// A rotary left by its third exit, turning the rider from east to south.
Map<String, Object?> roundaboutThirdExitRightResponse() => _response(
  coordinates: [
    [-2.6000, 51.4700],
    [-2.5960, 51.4700],
    [-2.5956, 51.4698],
    [-2.5956, 51.4650],
  ],
  distanceMeters: 860,
  durationSeconds: 96,
  steps: [
    _step(
      name: 'Bath Road',
      drivingSide: 'left',
      type: 'depart',
      modifier: 'straight',
      bearingBefore: 90,
      bearingAfter: 90,
      location: [-2.6000, 51.4700],
    ),
    _step(
      name: 'Temple Circus',
      drivingSide: 'left',
      type: 'rotary',
      modifier: 'slight left',
      exit: 3,
      bearingBefore: 90,
      bearingAfter: 20,
      location: [-2.5960, 51.4700],
    ),
    _step(
      name: 'Redcliffe Way',
      ref: 'A4',
      drivingSide: 'left',
      type: 'exit rotary',
      modifier: 'slight right',
      bearingBefore: 150,
      bearingAfter: 180,
      location: [-2.5956, 51.4698],
    ),
    _step(
      name: 'Redcliffe Way',
      ref: 'A4',
      drivingSide: 'left',
      type: 'arrive',
      bearingBefore: 180,
      bearingAfter: 0,
      location: [-2.5956, 51.4650],
    ),
  ],
);

/// A gyratory whose ring the engine splits into two adjacent `roundabout` steps.
///
/// Only the first ring carries an exit count, and the rider rides straight
/// through, so this must read as one instruction rather than three turns.
Map<String, Object?> gyratoryResponse() => _response(
  coordinates: [
    [-2.5800, 51.4580],
    [-2.5830, 51.4580],
    [-2.5832, 51.4581],
    [-2.5836, 51.4582],
    [-2.5900, 51.4583],
  ],
  distanceMeters: 940,
  durationSeconds: 118,
  steps: [
    _step(
      name: 'Old Market Street',
      drivingSide: 'left',
      type: 'depart',
      modifier: 'straight',
      bearingBefore: 270,
      bearingAfter: 270,
      location: [-2.5800, 51.4580],
    ),
    _step(
      name: 'Old Market Gyratory',
      drivingSide: 'left',
      type: 'roundabout',
      modifier: 'left',
      exit: 2,
      bearingBefore: 270,
      bearingAfter: 200,
      location: [-2.5830, 51.4580],
      lanes: [
        {
          'indications': ['straight'],
          'valid': true,
        },
        {
          'indications': ['straight', 'right'],
          'valid': true,
        },
      ],
    ),
    _step(
      name: 'Old Market Gyratory',
      drivingSide: 'left',
      type: 'roundabout',
      modifier: 'slight left',
      bearingBefore: 210,
      bearingAfter: 190,
      // About 12 m from the first ring step: the same gyratory.
      location: [-2.5832, 51.4581],
    ),
    _step(
      name: 'West Street',
      drivingSide: 'left',
      type: 'exit roundabout',
      modifier: 'slight right',
      bearingBefore: 190,
      bearingAfter: 265,
      location: [-2.5836, 51.4582],
    ),
    _step(
      name: 'West Street',
      drivingSide: 'left',
      type: 'arrive',
      bearingBefore: 265,
      bearingAfter: 0,
      location: [-2.5900, 51.4583],
    ),
  ],
);

/// Three separate urban roundabouts and a turn, the shape of a Bristol ring
/// road run. Each roundabout must stay its own single instruction.
Map<String, Object?> multiRoundaboutUrbanResponse() => _response(
  coordinates: [
    [-2.5500, 51.4800],
    [-2.5500, 51.4830],
    [-2.5500, 51.4832],
    [-2.5470, 51.4832],
    [-2.5468, 51.4832],
    [-2.5468, 51.4870],
    [-2.5468, 51.4872],
    [-2.5430, 51.4872],
    [-2.5430, 51.4900],
  ],
  distanceMeters: 2410,
  durationSeconds: 288,
  steps: [
    _step(
      name: 'Muller Road',
      drivingSide: 'left',
      type: 'depart',
      modifier: 'straight',
      bearingBefore: 0,
      bearingAfter: 0,
      location: [-2.5500, 51.4800],
    ),
    _step(
      name: 'Muller Road',
      drivingSide: 'left',
      type: 'roundabout',
      modifier: 'slight left',
      exit: 3,
      bearingBefore: 0,
      bearingAfter: 300,
      location: [-2.5500, 51.4830],
    ),
    _step(
      name: 'Filton Avenue',
      drivingSide: 'left',
      type: 'exit roundabout',
      modifier: 'slight right',
      bearingBefore: 60,
      bearingAfter: 90,
      location: [-2.5500, 51.4832],
    ),
    _step(
      name: 'Filton Avenue',
      drivingSide: 'left',
      type: 'roundabout',
      modifier: 'slight left',
      exit: 2,
      bearingBefore: 90,
      bearingAfter: 30,
      location: [-2.5470, 51.4832],
    ),
    _step(
      name: 'Gloucester Road',
      ref: 'A38',
      drivingSide: 'left',
      type: 'exit roundabout',
      modifier: 'slight left',
      bearingBefore: 350,
      bearingAfter: 358,
      location: [-2.5468, 51.4832],
    ),
    _step(
      name: 'Gloucester Road',
      ref: 'A38',
      drivingSide: 'left',
      type: 'roundabout',
      modifier: 'slight left',
      exit: 4,
      bearingBefore: 358,
      bearingAfter: 290,
      location: [-2.5468, 51.4870],
    ),
    _step(
      name: 'Wellington Hill',
      drivingSide: 'left',
      type: 'exit roundabout',
      modifier: 'sharp right',
      bearingBefore: 200,
      bearingAfter: 268,
      location: [-2.5468, 51.4872],
    ),
    _step(
      name: 'Kellaway Avenue',
      drivingSide: 'left',
      type: 'turn',
      modifier: 'right',
      bearingBefore: 268,
      bearingAfter: 0,
      location: [-2.5430, 51.4872],
    ),
    _step(
      name: 'Kellaway Avenue',
      drivingSide: 'left',
      type: 'arrive',
      bearingBefore: 0,
      bearingAfter: 0,
      location: [-2.5430, 51.4900],
    ),
  ],
);

/// The live default-route response from BS15 1UJ toward Chippenham, reduced to
/// the New Cheltenham Road corridor.
///
/// OSRM reports both OSM mini-roundabout nodes as ordinary intersections inside
/// one 1,136 m `new name` step. There is no manoeuvre at either coordinate. The
/// next manoeuvre is the separate third-exit roundabout near Tenniscourt Road.
Map<String, Object?> newCheltenhamRoadOmittedRoundaboutsResponse() => _response(
  coordinates: [
    [-2.5061000, 51.4677300],
    [-2.5048780, 51.4676080],
    [-2.5023880, 51.4673440],
    [-2.5010632, 51.4672133],
    [-2.5005026, 51.4670501],
    [-2.4998010, 51.4666450],
    [-2.4894250, 51.4676490],
    [-2.4890410, 51.4675390],
    [-2.4850000, 51.4650000],
  ],
  distanceMeters: 2100,
  durationSeconds: 210,
  steps: [
    _step(
      name: 'Syston Way',
      drivingSide: 'left',
      type: 'depart',
      modifier: 'right',
      bearingBefore: 0,
      bearingAfter: 99,
      location: [-2.5061000, 51.4677300],
    ),
    _step(
      name: 'New Cheltenham Road',
      drivingSide: 'left',
      type: 'new name',
      modifier: 'straight',
      bearingBefore: 98,
      bearingAfter: 98,
      location: [-2.5048780, 51.4676080],
      intersections: [
        {
          'location': [-2.5010632, 51.4672133],
          'in': 2,
          'out': 1,
          'bearings': [0, 135, 270],
          'entry': [true, true, false],
        },
        {
          'location': [-2.5005026, 51.4670501],
          'in': 2,
          'out': 1,
          'bearings': [30, 150, 285],
          'entry': [true, true, true],
        },
      ],
    ),
    _step(
      name: 'Tenniscourt Road',
      drivingSide: 'left',
      type: 'roundabout',
      modifier: 'straight',
      exit: 3,
      bearingBefore: 56,
      bearingAfter: 47,
      location: [-2.4894250, 51.4676490],
    ),
    _step(
      name: 'Tenniscourt Road',
      drivingSide: 'left',
      type: 'exit roundabout',
      modifier: 'straight',
      exit: 3,
      bearingBefore: 185,
      bearingAfter: 174,
      location: [-2.4890410, 51.4675390],
    ),
    _step(
      name: 'Tenniscourt Road',
      drivingSide: 'left',
      type: 'arrive',
      bearingBefore: 150,
      bearingAfter: 0,
      location: [-2.4850000, 51.4650000],
    ),
  ],
);

Map<String, Object?> _response({
  required Coordinates coordinates,
  required double distanceMeters,
  required double durationSeconds,
  required List<Map<String, Object?>> steps,
}) => {
  'code': 'Ok',
  'routes': [
    {
      'distance': distanceMeters,
      'duration': durationSeconds,
      'geometry': {'coordinates': coordinates},
      'legs': [
        {'steps': steps},
      ],
    },
  ],
};

Map<String, Object?> _step({
  required String type,
  required List<double> location,
  required double bearingBefore,
  required double bearingAfter,
  String? name,
  String? ref,
  String? modifier,
  String? drivingSide,
  int? exit,
  List<Map<String, Object?>>? lanes,
  List<Map<String, Object?>>? intersections,
}) => {
  'name': ?name,
  'ref': ?ref,
  'driving_side': ?drivingSide,
  'maneuver': {
    'type': type,
    'modifier': ?modifier,
    'exit': ?exit,
    'bearing_before': bearingBefore,
    'bearing_after': bearingAfter,
    'location': location,
  },
  'intersections':
      intersections ??
      [
        {'location': location, 'lanes': ?lanes},
      ],
};
