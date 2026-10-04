import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/services/gpx_parser.dart';
import 'package:ride_relay/services/navigation_guidance.dart';
import 'package:ride_relay/services/road_jurisdiction.dart';
import 'package:ride_relay/services/road_routing.dart';
import 'package:ride_relay/services/route_geometry_enricher.dart';
import 'package:ride_relay/services/route_reshape_planner.dart';

/// #839: shaping points were announced as destinations. Live OSRM, asked to
/// route Usk to Chepstow through one control, returns two legs and an arrival
/// at the control; the same request with `waypoints=0;2` returns one leg and
/// one arrival. The app sent every reshaping control and every GPX route point
/// the first way.
void main() {
  const start = GeoPoint(latitude: 51.700, longitude: -2.900);
  const shaping = GeoPoint(latitude: 51.700, longitude: -2.890);
  const cafe = GeoPoint(latitude: 51.700, longitude: -2.880);
  const finish = GeoPoint(latitude: 51.700, longitude: -2.870);

  ImportedRoute plannedRoute({List<RouteManeuver> maneuvers = const []}) =>
      ImportedRoute(
        id: 'planned',
        name: 'To Chepstow',
        importedAt: DateTime.utc(2026, 10, 4),
        sourceFileName: 'planned.gpx',
        paths: const [
          RoutePath(
            kind: RoutePathKind.track,
            points: [start, shaping, cafe, finish],
          ),
        ],
        waypoints: const [
          RouteWaypoint(point: start, name: 'Start'),
          RouteWaypoint(point: cafe, name: 'Penelope\'s Café'),
          RouteWaypoint(point: finish, name: 'Chepstow'),
        ],
        maneuvers: maneuvers,
      );

  List<String> arrivals(ImportedRoute route) =>
      const NavigationGuidancePlanner()
          .instructions(route)
          .where((step) => step.instruction.kind == ManeuverKind.arrive)
          .map((step) => step.instruction.standaloneText)
          .toList();

  group('a reshaped route passes through its shaping point (#839)', () {
    test('OSRM is told the shaping point is not a stop', () async {
      Uri? requested;
      final osrm = OsrmRoadRoutingService(
        client: MockClient((request) async {
          requested = request.url;
          return http.Response(
            jsonEncode(_twoLegResponse(start, cafe, finish)),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }),
        baseUrl: Uri.parse('https://routing.example.test'),
        readMiniRoundabouts: () async => MappedMiniRoundaboutCatalogue.empty,
        readRoadJurisdictions: () async => RoadJurisdictionCatalogue.empty,
      );

      final result = await RouteReshapePlanner(routingService: osrm).reshape(
        plannedRoute(),
        const [RouteShapingPoint(id: 'shape', point: shaping, legIndex: 0)],
      );

      // Four controls; only the start, the café and the finish end a leg.
      expect(requested!.path, endsWith(';-2.87,51.7'));
      expect(requested!.pathSegments.last.split(';'), hasLength(4));
      expect(requested!.queryParameters['waypoints'], '0;2;3');
      expect(arrivals(result.route), [
        'Arrive at Penelope\'s Café',
        'Arrive at the destination',
      ]);
      expect(result.route.waypoints, hasLength(3));
      expect(result.route.shapingPoints.single.point, shaping);
    });

    test('Valhalla is told to pass through it', () async {
      Map<String, Object?>? request;
      final valhalla = ValhallaMotorcycleRoutingService(
        client: MockClient((call) async {
          request = Map<String, Object?>.from(
            jsonDecode(call.url.queryParameters['json']!) as Map,
          );
          return http.Response('{}', 400);
        }),
        routeUrl: Uri.parse('https://valhalla.example.test/route'),
        readMiniRoundabouts: () async => MappedMiniRoundaboutCatalogue.empty,
        readRoadJurisdictions: () async => RoadJurisdictionCatalogue.empty,
      );
      await expectLater(
        RouteReshapePlanner(routingService: valhalla).reshape(
          plannedRoute(),
          const [RouteShapingPoint(id: 'shape', point: shaping, legIndex: 0)],
        ),
        throwsA(isA<RoadRoutingException>()),
      );
      final types = [
        for (final location in request!['locations'] as List)
          (location as Map)['type'],
      ];
      expect(types, ['break', 'through', 'break', 'break']);
    });

    test(
      'an engine that cannot pass through still loses that arrival',
      () async {
        final routing = _StopOnlyRoutingService([
          _maneuver('depart', start),
          _maneuver('arrive', shaping),
          _maneuver('depart', shaping),
          _maneuver('turn', const GeoPoint(latitude: 51.7, longitude: -2.885)),
          _maneuver('arrive', cafe),
          _maneuver('depart', cafe),
          _maneuver('arrive', finish),
        ]);

        final result = await RouteReshapePlanner(routingService: routing)
            .reshape(plannedRoute(), const [
              RouteShapingPoint(id: 'shape', point: shaping, legIndex: 0),
            ]);

        expect(result.route.maneuvers.map((maneuver) => maneuver.type), [
          'depart',
          'turn',
          'arrive',
          'depart',
          'arrive',
        ]);
        expect(arrivals(result.route), [
          'Arrive at Penelope\'s Café',
          'Arrive at the destination',
        ]);
      },
    );
  });

  test('a saved route never announces a leg end that is not a stop', () {
    // Saved before #839: the engine was asked to stop at the shaping point and
    // reported an arrival there, as it does for any leg end.
    final route = plannedRoute(
      maneuvers: [
        _maneuver('depart', start),
        _maneuver('arrive', shaping),
        _maneuver('depart', shaping),
        _maneuver(
          'arrive',
          const GeoPoint(latitude: 51.7004, longitude: -2.88),
        ),
        _maneuver('depart', cafe),
        _maneuver('arrive', finish),
      ],
    );
    expect(arrivals(route), [
      'Arrive at Penelope\'s Café',
      'Arrive at the destination',
    ]);
  });

  test('a stop without a name is arrived at as a stop, not the end', () {
    final route = ImportedRoute(
      id: 'unnamed',
      name: 'Unnamed stop',
      importedAt: DateTime.utc(2026, 10, 4),
      sourceFileName: 'unnamed.gpx',
      paths: const [
        RoutePath(kind: RoutePathKind.track, points: [start, cafe, finish]),
      ],
      waypoints: const [
        RouteWaypoint(point: start),
        RouteWaypoint(point: cafe),
        RouteWaypoint(point: finish),
      ],
      maneuvers: [
        _maneuver('depart', start),
        _maneuver('arrive', cafe),
        _maneuver('depart', cafe),
        _maneuver('arrive', finish),
      ],
    );
    expect(arrivals(route), [
      'Arrive at your stop',
      'Arrive at the destination',
    ]);
  });

  group('an imported GPX shaping point behaves the same (#839)', () {
    ImportedRoute imported() => const GpxParser().parse(
      Uint8List.fromList(utf8.encode(_gpxWithShapingAndVia)),
      routeId: 'gpx',
      sourceFileName: 'gpx.gpx',
      importedAt: DateTime.utc(2026, 10, 4),
    );

    test('it is a shaping point, never a stop', () {
      final route = imported();
      expect(route.waypoints.map((waypoint) => waypoint.name), [
        'Usk',
        'Penelope\'s Café',
        'Chepstow',
      ]);
      expect(route.shapingPoints, hasLength(2));
      expect(route.shapingPoints.map((point) => point.legIndex), [0, 1]);
    });

    test('routing its line passes through everything but the stops', () async {
      final routing = _RecordingShapingRoutingService();
      final enriched = await RouteGeometryEnricher(
        routingService: routing,
      ).enrich(imported());

      expect(enriched.snappedPathCount, 1);
      // Usk, shaping, plain route point, Garmin shape vertex, café, shaping,
      // Chepstow: the via points at 0, 4 and 6 are the only leg ends.
      expect(routing.controls, hasLength(7));
      expect(routing.shapingPointIndexes, {1, 2, 3, 5});
      expect(enriched.route.shapingPoints, hasLength(2));
    });

    test('a route saved with them as waypoints is read the new way', () {
      final saved = imported();
      final legacy = ImportedRoute(
        id: saved.id,
        name: saved.name,
        importedAt: saved.importedAt,
        sourceFileName: saved.sourceFileName,
        paths: saved.paths,
        waypoints: const [
          RouteWaypoint(point: start, name: 'Usk', symbol: 'Via point'),
          RouteWaypoint(
            point: shaping,
            description: 'Soft route shaping point',
            symbol: 'Shaping point',
          ),
          RouteWaypoint(point: cafe, name: 'Café', symbol: 'Via point'),
          RouteWaypoint(
            point: GeoPoint(latitude: 51.7, longitude: -2.875),
            description: 'Soft route shaping point',
            symbol: 'Shaping point',
          ),
          RouteWaypoint(point: finish, name: 'Chepstow', symbol: 'Via point'),
        ],
      );
      final reloaded = ImportedRoute.fromJsonString(legacy.toJsonString());
      expect(reloaded.waypoints.map((waypoint) => waypoint.name), [
        'Usk',
        'Café',
        'Chepstow',
      ]);
      expect(reloaded.shapingPoints.map((point) => point.legIndex), [0, 1]);
      expect(
        reloaded.shapingPoints.map((point) => point.id).toSet(),
        hasLength(2),
      );
    });
  });

  test('a waypoint-only route is routed through its shaping points', () async {
    final routing = _RecordingShapingRoutingService();
    final route = ImportedRoute(
      id: 'waypoints',
      name: 'Waypoints only',
      importedAt: DateTime.utc(2026, 10, 4),
      sourceFileName: 'waypoints.gpx',
      paths: const [],
      waypoints: const [
        RouteWaypoint(point: start, name: 'Usk'),
        RouteWaypoint(point: finish, name: 'Chepstow'),
      ],
      shapingPoints: const [
        RouteShapingPoint(id: 'shape', point: shaping, legIndex: 0),
      ],
    );
    await RouteGeometryEnricher(routingService: routing).enrich(route);
    expect(routing.controls, [start, shaping, finish]);
    expect(routing.shapingPointIndexes, {1});
  });
}

RoadRouteManeuver _maneuver(String type, GeoPoint position) =>
    RoadRouteManeuver(position: position, type: type);

Map<String, Object?> _twoLegResponse(
  GeoPoint start,
  GeoPoint cafe,
  GeoPoint finish,
) {
  List<double> at(GeoPoint point) => [point.longitude, point.latitude];
  Map<String, Object?> step(String type, GeoPoint point) => {
    'name': '',
    'maneuver': {
      'type': type,
      'bearing_before': 90,
      'bearing_after': 90,
      'location': at(point),
    },
    'intersections': [
      {'location': at(point)},
    ],
  };
  return {
    'code': 'Ok',
    'routes': [
      {
        'distance': 2100,
        'duration': 150,
        'geometry': {
          'coordinates': [at(start), at(cafe), at(finish)],
        },
        'legs': [
          {
            'steps': [step('depart', start), step('arrive', cafe)],
          },
          {
            'steps': [step('depart', cafe), step('arrive', finish)],
          },
        ],
      },
    ],
  };
}

/// An engine with no way to pass through a control: every control is a stop.
class _StopOnlyRoutingService implements RoadRoutingService {
  _StopOnlyRoutingService(this.maneuvers);

  final List<RoadRouteManeuver> maneuvers;

  @override
  Future<RoadRouteResult> routeThrough(
    List<GeoPoint> waypoints, {
    RoutePreferences? preferences,
    double? originBearingDegrees,
  }) async => RoadRouteResult(
    points: waypoints,
    distanceMeters: 2100,
    duration: const Duration(minutes: 3),
    maneuvers: maneuvers,
  );
}

class _RecordingShapingRoutingService
    implements RoadRoutingService, ShapingPointRoadRoutingService {
  List<GeoPoint>? controls;
  Set<int>? shapingPointIndexes;

  @override
  Future<RoadRouteResult> routeThrough(
    List<GeoPoint> waypoints, {
    RoutePreferences? preferences,
    double? originBearingDegrees,
  }) async {
    controls = waypoints;
    shapingPointIndexes = const {};
    return _result(waypoints);
  }

  @override
  Future<RoadRouteResult> routeThroughShapingPoints(
    List<GeoPoint> waypoints, {
    required Set<int> shapingPointIndexes,
    double shapingPointSearchRadiusMeters = 0,
    RoutePreferences? preferences,
    RoadRoutingCosting costing = RoadRoutingCosting.preferred,
    double? originBearingDegrees,
  }) async {
    controls = waypoints;
    this.shapingPointIndexes = shapingPointIndexes;
    return _result(waypoints);
  }

  RoadRouteResult _result(List<GeoPoint> waypoints) => RoadRouteResult(
    points: waypoints,
    distanceMeters: 2100,
    duration: const Duration(minutes: 3),
  );
}

/// A MyRoute-app style trip: via points at the start, the café and the finish,
/// shaping points between them, plus a plain route point and a Garmin shape
/// vertex that only describe the line.
const _gpxWithShapingAndVia = '''
<gpx version="1.1" creator="test"
     xmlns="http://www.topografix.com/GPX/1/1"
     xmlns:trp="http://www.garmin.com/xmlschemas/TripExtensions/v1"
     xmlns:gpxx="http://www.garmin.com/xmlschemas/GpxExtensions/v3">
  <rte><name>Usk to Chepstow</name>
    <rtept lat="51.700" lon="-2.900"><name>Usk</name>
      <extensions><trp:ViaPoint/></extensions></rtept>
    <rtept lat="51.700" lon="-2.890">
      <extensions><trp:ShapingPoint/></extensions></rtept>
    <rtept lat="51.700" lon="-2.886">
      <extensions><gpxx:RoutePointExtension>
        <gpxx:rpt lat="51.700" lon="-2.883"/>
      </gpxx:RoutePointExtension></extensions></rtept>
    <rtept lat="51.700" lon="-2.880"><name>Penelope's Café</name>
      <extensions><trp:ViaPoint/></extensions></rtept>
    <rtept lat="51.700" lon="-2.875">
      <extensions><trp:ShapingPoint/></extensions></rtept>
    <rtept lat="51.700" lon="-2.870"><name>Chepstow</name>
      <extensions><trp:ViaPoint/></extensions></rtept>
  </rte>
</gpx>
''';
