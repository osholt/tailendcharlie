import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/distance_unit.dart';
import 'package:ride_relay/domain/geo_point.dart' as awareness;
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/domain/rider_location.dart';
import 'package:ride_relay/services/road_routing.dart';
import 'package:ride_relay/services/route_rejoin_planner.dart';
import 'package:ride_relay/services/solo_navigation_reroute.dart';

/// #940. Where To had no reroute at all: on the 10 October ride the rider was
/// off route for four minutes and then eight and heard nothing. The geometry
/// here is synthetic, in metres east and north of a neutral origin: a planned
/// route running east, and a rider who leaves it northwards and comes back.
void main() {
  GeoPoint point(double east, double north) =>
      GeoPoint(latitude: north / 111195, longitude: east / 111195);

  final planned = ImportedRoute(
    id: 'where-to',
    name: 'Where To',
    importedAt: DateTime.utc(2026, 10, 10),
    sourceFileName: 'where-to.gpx',
    paths: [
      RoutePath(
        kind: RoutePathKind.route,
        points: [
          for (var east = 0.0; east <= 8000; east += 500) point(east, 0),
        ],
      ),
    ],
    waypoints: const [],
  );

  late DateTime now;
  late _LoopingRouting routing;
  late SoloNavigationReroute reroute;

  setUp(() {
    now = DateTime.utc(2026, 10, 10, 10);
    routing = _LoopingRouting(point);
    reroute = SoloNavigationReroute(
      planner: RouteRejoinPlanner(
        routingService: routing,
        thresholds: RouteRejoinThresholds.solo,
      ),
      clock: () => now,
    );
    reroute.setRoute(planned);
  });

  tearDown(() => reroute.dispose());

  Future<SoloRerouteUpdate> ride(
    double east,
    double north, {
    required double heading,
    double speed = 15,
    Duration after = const Duration(seconds: 10),
    double? distanceToManeuver,
  }) {
    now = now.add(after);
    return reroute.update(
      LocationSample(
        position: awareness.GeoPoint(
          latitude: north / 111195,
          longitude: east / 111195,
        ),
        recordedAt: now,
        accuracyMeters: 5,
        headingDegrees: heading,
        speedMetersPerSecond: speed,
      ),
      distanceToCurrentManeuverMeters: distanceToManeuver,
    );
  }

  /// On the route heading east, then three fixes leaving it northwards, the
  /// third of which confirms the rider off route.
  Future<List<SoloRerouteUpdate>> leaveTheRoute() async => [
    await ride(100, 0, heading: 90),
    await ride(200, 0, heading: 90),
    await ride(300, 0, heading: 90),
    await ride(320, 150, heading: 0),
    await ride(330, 300, heading: 0),
    await ride(340, 450, heading: 0),
  ];

  test(
    'a rider who leaves the route is told once and given a way back',
    () async {
      final updates = await leaveTheRoute();
      expect(updates.take(5).any((update) => update.leftRoute), isFalse);
      expect(updates.last.leftRoute, isTrue);
      expect(updates.last.attempt?.status, RouteRejoinStatus.routed);
      expect(reroute.route.value, isNotNull);
      expect(reroute.route.value!.maneuvers, isNotEmpty);
      // The request carried the rider's heading, so the way back starts forwards.
      expect(routing.originBearings.single, 0);

      final next = await ride(345, 600, heading: 0);
      expect(next.leftRoute, isFalse, reason: 'said once per episode');
      expect(next.attempt, isNull, reason: 'the recompute floor holds');
      expect(reroute.route.value, isNotNull);
    },
  );

  test('a long detour on your own still gets a way back', () async {
    await leaveTheRoute();
    // Two kilometres off and eleven minutes in: past both of the group
    // planner's "massively off route" limits, which need a leader's position.
    final far = await ride(
      600,
      2000,
      heading: 0,
      after: const Duration(minutes: 11),
    );
    expect(far.attempt?.status, RouteRejoinStatus.routed);
    expect(reroute.route.value, isNotNull);
  });

  test('production reroutes with the solo thresholds', () {
    final production = SoloNavigationReroute.osrm(
      routingBaseUrl: Uri.parse('https://routing.example.test'),
      distanceUnit: DistanceUnit.miles,
    );
    addTearDown(production.dispose);
    expect(
      production.planner.thresholds.massivelyOffRouteMeters,
      RouteRejoinThresholds.solo.massivelyOffRouteMeters,
    );
    expect(
      production.planner.thresholds.massivelyOffRouteAfter,
      RouteRejoinThresholds.solo.massivelyOffRouteAfter,
    );
  });

  test('crossing the planned line is not being back on it (#941)', () async {
    await leaveTheRoute();
    // On a road crossing the route, 43 m short of it and heading straight at
    // it, as on the 10 October ride's other arm: near, but not on it.
    final crossing = [
      await ride(1000, 43, heading: 180, after: const Duration(seconds: 50)),
      await ride(1000, 40, heading: 180, after: const Duration(seconds: 1)),
      await ride(1000, 38, heading: 180, after: const Duration(seconds: 1)),
    ];
    expect(crossing.any((update) => update.backOnRouteAfter != null), isFalse);
    expect(reroute.offRoute, isTrue);
    expect(reroute.route.value, isNotNull);

    // Through the junction and away along the route.
    await ride(1040, 5, heading: 90, after: const Duration(seconds: 3));
    final back = await ride(
      1100,
      5,
      heading: 90,
      after: const Duration(seconds: 4),
      distanceToManeuver: 400,
    );
    expect(back.backOnRouteAfter, isNotNull);
    expect(reroute.offRoute, isFalse);
    expect(reroute.route.value, isNull);
  });

  test('the way back is not taken away inside a junction', () async {
    await leaveTheRoute();
    await ride(1040, 5, heading: 90, after: const Duration(seconds: 50));
    final back = await ride(
      1100,
      5,
      heading: 90,
      after: const Duration(seconds: 4),
      distanceToManeuver: 30,
    );
    expect(back.backOnRouteAfter, isNotNull);
    expect(
      reroute.route.value,
      isNotNull,
      reason: 'the rider is 30 m from the junction the rejoin route describes',
    );

    await ride(1300, 5, heading: 90, distanceToManeuver: 400);
    expect(reroute.route.value, isNull);
  });

  test('a failed retry keeps the way back that still works', () async {
    await leaveTheRoute();
    final first = reroute.route.value;
    expect(first, isNotNull);
    routing.fail = true;
    final retry = await ride(
      600,
      900,
      heading: 0,
      after: const Duration(seconds: 50),
    );
    expect(retry.attempt?.status, RouteRejoinStatus.routingUnavailable);
    expect(reroute.route.value?.id, first!.id);
  });

  test('a new planned route ends the episode', () async {
    await leaveTheRoute();
    expect(reroute.route.value, isNotNull);
    reroute.setRoute(planned);
    expect(reroute.route.value, isNotNull, reason: 'the same route again');
    reroute.setRoute(
      ImportedRoute(
        id: 'replanned',
        name: 'Replanned',
        importedAt: DateTime.utc(2026, 10, 10, 11),
        sourceFileName: 'replanned.gpx',
        paths: planned.paths,
        waypoints: const [],
      ),
    );
    expect(reroute.route.value, isNull);
    expect(reroute.offRoute, isFalse);
  });
}

/// A stand-in for OSRM that answers the way a road network would: forwards
/// along the rider's heading for 100 m, across, then onto the planned route at
/// the rejoin point heading south, so it neither starts nor ends with a U-turn.
class _LoopingRouting implements RoadRoutingService {
  _LoopingRouting(this.point);

  final GeoPoint Function(double east, double north) point;
  final List<double> originBearings = [];
  bool fail = false;

  @override
  Future<RoadRouteResult> routeThrough(
    List<GeoPoint> waypoints, {
    RoutePreferences? preferences,
    double? originBearingDegrees,
  }) async {
    if (originBearingDegrees != null) originBearings.add(originBearingDegrees);
    if (fail) throw const FormatException('Routing is unavailable.');
    final from = waypoints.first;
    final to = waypoints.last;
    double east(GeoPoint p) => p.longitude * 111195;
    double north(GeoPoint p) => p.latitude * 111195;
    final turn = point(east(from), north(from) + 100);
    final across = point(east(to), north(from) + 100);
    return RoadRouteResult(
      points: [from, turn, across, to],
      distanceMeters: 1000,
      duration: const Duration(minutes: 2),
      maneuvers: [
        RoadRouteManeuver(position: turn, type: 'turn', modifier: 'right'),
        RoadRouteManeuver(position: across, type: 'turn', modifier: 'right'),
        RoadRouteManeuver(position: to, type: 'arrive'),
      ],
    );
  }
}
