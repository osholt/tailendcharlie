import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/services/ride_plan_remaining.dart';
import 'package:ride_relay/services/route_progress.dart';

// Synthetic places on a straight line running north. None is anybody's start,
// finish or home.
const _meet = GeoPoint(latitude: 52.00, longitude: -1.00);
const _cafe = GeoPoint(latitude: 52.10, longitude: -1.00);
const _pass = GeoPoint(latitude: 52.20, longitude: -1.00);
const _town = GeoPoint(latitude: 52.30, longitude: -1.00);

const _beforeCafe = RouteShapingPoint(
  id: 'before-cafe',
  point: GeoPoint(latitude: 52.05, longitude: -1.00),
  legIndex: 0,
);
const _beforePass = RouteShapingPoint(
  id: 'before-pass',
  point: GeoPoint(latitude: 52.15, longitude: -1.00),
  legIndex: 1,
);
const _afterPass = RouteShapingPoint(
  id: 'after-pass',
  point: GeoPoint(latitude: 52.25, longitude: -1.00),
  legIndex: 2,
);

ImportedRoute _route({
  List<GeoPoint> line = const [_meet, _cafe, _pass, _town],
  List<RouteWaypoint>? waypoints,
}) => ImportedRoute(
  id: 'ride-route',
  name: 'To Town',
  importedAt: DateTime.utc(2026, 10, 9),
  sourceFileName: 'ride-route.gpx',
  paths: [RoutePath(kind: RoutePathKind.track, points: _densified(line))],
  waypoints:
      waypoints ??
      const [
        RouteWaypoint(point: _meet, name: 'Meeting point'),
        RouteWaypoint(point: _cafe, name: 'Cafe'),
        RouteWaypoint(point: _pass, name: 'Pass'),
        RouteWaypoint(point: _town, name: 'Town'),
      ],
  shapingPoints: const [_beforeCafe, _beforePass, _afterPass],
);

/// A point every ~1.1 km, so progress has a line to be measured on.
List<GeoPoint> _densified(List<GeoPoint> line) => [
  for (var index = 0; index < line.length - 1; index += 1)
    for (var step = 0; step < 10; step += 1)
      GeoPoint(
        latitude:
            line[index].latitude +
            (line[index + 1].latitude - line[index].latitude) * step / 10,
        longitude:
            line[index].longitude +
            (line[index + 1].longitude - line[index].longitude) * step / 10,
      ),
  line.last,
];

double _progressAt(ImportedRoute route, GeoPoint position) =>
    RouteProgressTracker().update(route, position).progressMeters;

void main() {
  test(
    'past the cafe: from here, through the pass, without the ridden part',
    () {
      final route = _route();
      const here = GeoPoint(latitude: 52.17, longitude: -1.00);

      final plan = remainingRidePlan(
        route,
        progressMeters: _progressAt(route, here),
        position: here,
      );

      expect(plan.startsAtCurrentLocation, isTrue);
      expect(plan.stops.map((stop) => stop.label), ['Pass']);
      expect(plan.destination!.label, 'Town');
      // The adjustment before the cafe and the one this rider has just passed
      // are behind them; the one after the pass is on the leg after it.
      expect(
        {for (final point in plan.shapingPoints) point.id: point.legIndex},
        {'after-pass': 1},
      );
      expect(plan.controls(currentLocation: here)!.points, [
        here,
        _pass,
        _afterPass.point,
        _town,
      ]);
    },
  );

  test('between the cafe and an adjustment, the adjustment stays ahead', () {
    final route = _route();
    const here = GeoPoint(latitude: 52.12, longitude: -1.00);

    final plan = remainingRidePlan(
      route,
      progressMeters: _progressAt(route, here),
      position: here,
    );

    expect(plan.stops.map((stop) => stop.label), ['Pass']);
    expect(
      {for (final point in plan.shapingPoints) point.id: point.legIndex},
      {'before-pass': 0, 'after-pass': 1},
    );
  });

  test('at the start, the plan starts here and keeps every stop', () {
    final route = _route();

    final plan = remainingRidePlan(
      route,
      progressMeters: _progressAt(route, _meet),
      position: _meet,
    );

    expect(plan.startsAtCurrentLocation, isTrue);
    expect(plan.stops.map((stop) => stop.label), ['Cafe', 'Pass']);
    expect(plan.shapingPoints, hasLength(3));
  });

  test('still on the way to the start, the group\'s meeting point is kept', () {
    final route = _route();
    const awayFromRoute = GeoPoint(latitude: 51.95, longitude: -1.10);

    final plan = remainingRidePlan(
      route,
      progressMeters: 0,
      position: awayFromRoute,
    );

    expect(plan.startsAtCurrentLocation, isFalse);
    expect(plan.resolvedStart()!.label, 'Meeting point');
    expect(plan.stops, hasLength(2));
  });

  test('on a loop, a rider near the end has passed every stop', () {
    // Out along the line and back to the meeting point.
    const back = GeoPoint(latitude: 52.0, longitude: -1.02);
    final route = _route(
      line: const [_meet, _cafe, _pass, back, _meet],
      waypoints: const [
        RouteWaypoint(point: _meet, name: 'Meeting point'),
        RouteWaypoint(point: _cafe, name: 'Cafe'),
        RouteWaypoint(point: _pass, name: 'Pass'),
        RouteWaypoint(point: _meet, name: 'Home again'),
      ],
    );
    final tracker = RouteProgressTracker();
    // Ridden in order, as the navigation tracker sees it.
    var progress = 0.0;
    for (final point in _densified(const [_meet, _cafe, _pass, back])) {
      progress = tracker.update(route, point).progressMeters;
    }

    final plan = remainingRidePlan(
      route,
      progressMeters: progress,
      position: back,
    );

    expect(plan.stops, isEmpty);
    expect(plan.destination!.label, 'Home again');
  });
}
