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
import 'package:ride_relay/services/road_jurisdiction.dart';
import 'package:ride_relay/services/road_routing.dart';

/// Ordered geometry for a fixture route, as `[longitude, latitude]` pairs.
typedef Coordinates = List<List<double>>;

/// Parses an OSRM response through the app's own client and saves it as a route,
/// so tests exercise the real request-to-persistence path.
Future<ImportedRoute> routeFromOsrmResponse(
  Map<String, Object?> response, {
  String id = 'fixture',
  Future<MappedMiniRoundaboutCatalogue> Function()? readMiniRoundabouts,
  Future<RoadJurisdictionCatalogue> Function()? readRoadJurisdictions,
}) async {
  final service = OsrmRoadRoutingService(
    readMiniRoundabouts:
        readMiniRoundabouts ??
        (() async => MappedMiniRoundaboutCatalogue.empty),
    readRoadJurisdictions:
        readRoadJurisdictions ?? (() async => RoadJurisdictionCatalogue.empty),
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

/// Leaving Usk on the A472, the route keeps left onto the B4235 slip (#853).
///
/// Junction-local steps from the live OSRM demo `driving` response of 4 October
/// 2026: about 430 m of the A472 approach, the recorded `turn` step and its
/// first two intersections, and 300 m of the slip. Only the depart and arrive
/// at the window's ends are added. The engine said `turn left` with bearings 92
/// then 88; the junction it reported has the A472 continuing at 97 degrees,
/// eight degrees to the right of the slip at 89. `driving_side` is copied as
/// OSRM sent it, including its usual `right` for a UK road.
Map<String, Object?> uskB4235DivergeResponse() => _response(
  coordinates: const [
    [-2.883752, 51.704842],
    [-2.880504, 51.705208],
    [-2.87959, 51.705294],
    [-2.879061, 51.70533],
    [-2.878684, 51.705379],
    [-2.87834, 51.705388],
    [-2.877949, 51.70539],
    [-2.877573, 51.705375],
    [-2.877341, 51.705379],
    [-2.877089, 51.705406],
    [-2.876858, 51.705461],
    [-2.8767, 51.705533],
    [-2.876655, 51.705621],
    [-2.876505, 51.705741],
    [-2.876341, 51.705804],
    [-2.876167, 51.70583],
    [-2.875941, 51.705853],
    [-2.875737, 51.705874],
    [-2.875535, 51.705899],
    [-2.875322, 51.705928],
    [-2.874379, 51.706033],
    [-2.873556, 51.706122],
  ],
  distanceMeters: 730,
  durationSeconds: 52,
  steps: [
    _step(
      name: 'Castle Parade',
      ref: 'A472',
      drivingSide: 'right',
      type: 'depart',
      bearingBefore: 0,
      bearingAfter: 80,
      location: [-2.883752, 51.704842],
    ),
    _step(
      name: '',
      ref: 'B4235',
      drivingSide: 'right',
      type: 'turn',
      modifier: 'left',
      bearingBefore: 92,
      bearingAfter: 88,
      location: [-2.877573, 51.705375],
      intersections: [
        {
          'out': 0,
          'in': 2,
          'entry': [true, true, false],
          'bearings': [89, 97, 274],
          'location': [-2.877573, 51.705375],
        },
        {
          'out': 0,
          'in': 2,
          'entry': [true, true, false],
          'bearings': [15, 195, 240],
          'location': [-2.8767, 51.705533],
        },
      ],
    ),
    _step(
      name: '',
      ref: 'B4235',
      drivingSide: 'right',
      type: 'arrive',
      bearingBefore: 83,
      bearingAfter: 0,
      location: [-2.873556, 51.706122],
    ),
  ],
);

/// Leaving Aust services towards the M48 (#851).
///
/// Junction-local steps from the live OSRM demo response that reproduces the
/// 4 Oct diagnostics: the recorded unnamed `turn slight right` step, with all
/// five of its intersections, and the `new name` step onto Sandy Lane. The ride
/// was told "At the fork, continue straight on" at the intersections at
/// 51.604228,-2.620230 and 51.603037,-2.618555, where the engine had said
/// nothing; its other roads leave 45 and 75 degrees from the one taken.
Map<String, Object?> austServicesExitResponse() => _response(
  coordinates: const [
    [-2.620667, 51.603075],
    [-2.620772, 51.603206],
    [-2.620981, 51.603565],
    [-2.620984, 51.603604],
    [-2.620978, 51.603644],
    [-2.620955, 51.603726],
    [-2.620898, 51.60384],
    [-2.620845, 51.603913],
    [-2.620758, 51.603984],
    [-2.620498, 51.604111],
    [-2.62023, 51.604228],
    [-2.619977, 51.60432],
    [-2.619634, 51.604333],
    [-2.619312, 51.604273],
    [-2.619094, 51.604151],
    [-2.61895, 51.603984],
    [-2.618879, 51.603367],
    [-2.618854, 51.603311],
    [-2.618808, 51.603246],
    [-2.618735, 51.603168],
    [-2.61865, 51.603103],
    [-2.618555, 51.603037],
    [-2.618355, 51.602979],
    [-2.618285, 51.602961],
    [-2.618093, 51.602929],
    [-2.617963, 51.602935],
    [-2.617671, 51.602945],
    [-2.617462, 51.602929],
    [-2.617261, 51.602889],
    [-2.617149, 51.602847],
    [-2.617059, 51.602801],
    [-2.616974, 51.602746],
  ],
  distanceMeters: 493,
  durationSeconds: 60,
  steps: [
    _step(
      name: '',
      drivingSide: 'right',
      type: 'turn',
      modifier: 'slight right',
      bearingBefore: 296,
      bearingAfter: 333,
      location: [-2.620667, 51.603075],
      intersections: [
        {
          'out': 2,
          'in': 0,
          'entry': [false, true, true],
          'bearings': [120, 300, 330],
          'location': [-2.620667, 51.603075],
        },
        {
          'out': 0,
          'in': 1,
          'entry': [true, false, false],
          'bearings': [60, 225, 285],
          'location': [-2.620498, 51.604111],
        },
        {
          'out': 0,
          'in': 2,
          'entry': [true, true, false, false],
          'bearings': [60, 105, 240, 285],
          'location': [-2.62023, 51.604228],
        },
        {
          'out': 0,
          'in': 2,
          'entry': [true, true, false],
          'bearings': [120, 195, 315],
          'location': [-2.618555, 51.603037],
        },
        {
          'out': 0,
          'in': 1,
          'entry': [true, false, true],
          'bearings': [105, 300, 345],
          'location': [-2.618355, 51.602979],
        },
      ],
    ),
    _step(
      name: 'Sandy Lane',
      drivingSide: 'right',
      type: 'new name',
      modifier: 'straight',
      bearingBefore: 104,
      bearingAfter: 85,
      location: [-2.618093, 51.602929],
      intersections: [
        {
          'out': 0,
          'in': 2,
          'entry': [true, true, false],
          'bearings': [90, 255, 285],
          'location': [-2.618093, 51.602929],
        },
      ],
    ),
    _step(
      name: 'Sandy Lane',
      drivingSide: 'right',
      type: 'arrive',
      bearingBefore: 136,
      bearingAfter: 0,
      location: [-2.616974, 51.602746],
    ),
  ],
);

/// On the M48 past the exit slip at its junction with the M4 (#851).
///
/// The recorded intersection from the live OSRM demo response that reproduces
/// the 4 Oct diagnostics, with about 300 m of motorway either side. The route
/// stays on the main line at 157 degrees; the slip leaves at 151, the
/// geometrically straighter of the two, and the ride was told "At the fork,
/// continue straight on" there although the engine had said nothing.
Map<String, Object?> m48PastExitSlipResponse() => _response(
  coordinates: const [
    [-2.55933, 51.559685],
    [-2.558708, 51.559155],
    [-2.55754, 51.558018],
    [-2.55679, 51.557187],
    [-2.556334, 51.55653],
    [-2.554445, 51.554066],
  ],
  distanceMeters: 712,
  durationSeconds: 24,
  steps: [
    _step(
      name: '',
      ref: 'M48',
      drivingSide: 'right',
      type: 'depart',
      bearingBefore: 0,
      bearingAfter: 144,
      location: [-2.55933, 51.559685],
      intersections: [
        {
          'out': 0,
          'entry': [true],
          'bearings': [144],
          'location': [-2.55933, 51.559685],
        },
        {
          'out': 1,
          'in': 2,
          'entry': [true, true, false],
          'bearings': [151, 157, 331],
          'location': [-2.55679, 51.557187],
        },
      ],
    ),
    _step(
      name: '',
      ref: 'M48',
      drivingSide: 'right',
      type: 'arrive',
      bearingBefore: 155,
      bearingAfter: 0,
      location: [-2.554445, 51.554066],
    ),
  ],
);

/// Joining the M32 and staying on it past the next split (#851).
///
/// The recorded `merge` step from the live OSRM demo response that reproduces
/// the 4 Oct diagnostics, with its three intersections. At the second the
/// route stays on the M32 at 210 degrees while another road leaves at 180, and
/// the ride was told "At the fork, continue straight on" there.
Map<String, Object?> m32AfterMergeResponse() => _response(
  coordinates: const [
    [-2.518295, 51.514269],
    [-2.517624, 51.513436],
    [-2.517392, 51.51326],
    [-2.517271, 51.513232],
    [-2.517149, 51.513189],
    [-2.517065, 51.513149],
    [-2.516984, 51.513105],
    [-2.516905, 51.513042],
    [-2.516829, 51.512968],
    [-2.516795, 51.512911],
    [-2.516766, 51.512848],
    [-2.51675, 51.512765],
    [-2.516749, 51.512695],
    [-2.516758, 51.512634],
    [-2.51678, 51.51257],
    [-2.516816, 51.512516],
    [-2.516866, 51.512451],
    [-2.516998, 51.512341],
    [-2.517099, 51.512284],
    [-2.517256, 51.512221],
    [-2.517842, 51.512071],
    [-2.518024, 51.512047],
    [-2.518237, 51.512043],
    [-2.518478, 51.512068],
    [-2.518659, 51.512113],
    [-2.518847, 51.512138],
    [-2.519058, 51.512143],
    [-2.519273, 51.512118],
    [-2.519492, 51.512064],
    [-2.519741, 51.511973],
  ],
  distanceMeters: 460,
  durationSeconds: 30,
  steps: [
    _step(
      name: '',
      ref: 'M4',
      drivingSide: 'right',
      type: 'depart',
      bearingBefore: 0,
      bearingAfter: 153,
      location: [-2.518295, 51.514269],
    ),
    _step(
      name: '',
      ref: 'M32',
      drivingSide: 'right',
      type: 'merge',
      modifier: 'slight right',
      bearingBefore: 139,
      bearingAfter: 109,
      location: [-2.517392, 51.51326],
      intersections: [
        {
          'out': 0,
          'in': 2,
          'entry': [true, false, false],
          'bearings': [105, 285, 315],
          'location': [-2.517392, 51.51326],
        },
        {
          'out': 2,
          'in': 0,
          'entry': [false, true, true],
          'bearings': [30, 180, 210],
          'location': [-2.516866, 51.512451],
        },
        {
          'out': 2,
          'in': 0,
          'entry': [false, false, true],
          'bearings': [105, 120, 300],
          'location': [-2.518478, 51.512068],
        },
      ],
    ),
    _step(
      name: '',
      ref: 'M32',
      drivingSide: 'right',
      type: 'arrive',
      bearingBefore: 240,
      bearingAfter: 0,
      location: [-2.519741, 51.511973],
    ),
  ],
);

/// The engine's own fork where the M48 leaves the M4 (#851).
///
/// The recorded `fork` step from two live OSRM demo responses through the same
/// junction, with about 300 m of motorway either side: [staysOnM4] keeps to
/// the M4 at 90 degrees, and otherwise the route takes the M48 at 75. The M4
/// carrying on is the major road and is followed; leaving it is a direction.
Map<String, Object?> m4M48ForkResponse({required bool staysOnM4}) => _response(
  coordinates: staysOnM4
      ? const [
          [-2.82002, 51.586982],
          [-2.817068, 51.587261],
          [-2.815579, 51.58737],
          [-2.813276, 51.58749],
          [-2.810855, 51.5876],
          [-2.810166, 51.587618],
          [-2.808844, 51.587653],
        ]
      : const [
          [-2.82002, 51.586982],
          [-2.817068, 51.587261],
          [-2.815579, 51.58737],
          [-2.813276, 51.58749],
          [-2.811212, 51.587663],
          [-2.808844, 51.587845],
        ],
  distanceMeters: 777,
  durationSeconds: 26,
  steps: [
    _step(
      name: '',
      ref: 'M4',
      drivingSide: 'right',
      type: 'depart',
      bearingBefore: 0,
      bearingAfter: 81,
      location: [-2.82002, 51.586982],
    ),
    _step(
      name: '',
      ref: staysOnM4 ? 'M4' : 'M48',
      drivingSide: 'right',
      type: 'fork',
      modifier: staysOnM4 ? 'slight right' : 'slight left',
      bearingBefore: 84,
      bearingAfter: staysOnM4 ? 85 : 81,
      location: [-2.813276, 51.58749],
      intersections: [
        {
          'out': staysOnM4 ? 1 : 0,
          'in': 2,
          'entry': [true, true, false],
          'bearings': [75, 90, 270],
          'location': [-2.813276, 51.58749],
        },
      ],
    ),
    _step(
      name: '',
      ref: staysOnM4 ? 'M4' : 'M48',
      drivingSide: 'right',
      type: 'arrive',
      bearingBefore: staysOnM4 ? 88 : 83,
      bearingAfter: 0,
      location: staysOnM4 ? [-2.808844, 51.587653] : [-2.808844, 51.587845],
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
