import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/services/route_progress.dart';

void main() {
  test('loop waypoint progress puts a coincident finish at the route end', () {
    final route = ImportedRoute(
      id: 'loop',
      name: 'Loop',
      importedAt: DateTime.utc(2026, 8, 14),
      sourceFileName: 'loop.gpx',
      paths: const [
        RoutePath(
          kind: RoutePathKind.track,
          points: [
            GeoPoint(latitude: 0, longitude: 0),
            GeoPoint(latitude: 0, longitude: 0.01),
            GeoPoint(latitude: 0.01, longitude: 0.01),
            GeoPoint(latitude: 0.01, longitude: 0),
            GeoPoint(latitude: 0, longitude: 0),
          ],
        ),
      ],
      waypoints: const [
        RouteWaypoint(
          point: GeoPoint(latitude: 0, longitude: 0),
          name: 'Start',
        ),
        RouteWaypoint(
          point: GeoPoint(latitude: 0.01, longitude: 0.01),
          name: 'Coffee',
        ),
        RouteWaypoint(
          point: GeoPoint(latitude: 0, longitude: 0),
          name: 'Finish',
        ),
      ],
    );

    final progress = routeWaypointProgressMeters(route);

    expect(progress, hasLength(3));
    expect(progress.first, 0);
    expect(progress[1], greaterThan(2000));
    expect(progress.last, greaterThan(4000));
  });

  test('splits the route into solid ridden and remaining geometry', () {
    final tracker = RouteProgressTracker();

    final geometry = tracker.update(
      _route(const [
        GeoPoint(latitude: 0, longitude: 0),
        GeoPoint(latitude: 0, longitude: 0.01),
        GeoPoint(latitude: 0, longitude: 0.02),
      ]),
      const GeoPoint(latitude: 0, longitude: 0.012),
    );

    expect(geometry.riddenPaths, hasLength(1));
    expect(geometry.remainingPaths, hasLength(1));
    expect(geometry.riddenPaths.single.last.longitude, closeTo(0.012, 1e-6));
    expect(
      geometry.remainingPaths.single.first.longitude,
      closeTo(0.012, 1e-6),
    );
    expect(geometry.progressMeters, closeTo(1334, 15));
  });

  test('closed route starts at zero instead of its coincident finish', () {
    final tracker = RouteProgressTracker();
    final geometry = tracker.update(
      _route(const [
        GeoPoint(latitude: 0, longitude: 0),
        GeoPoint(latitude: 0, longitude: 0.01),
        GeoPoint(latitude: 0.01, longitude: 0.01),
        GeoPoint(latitude: 0, longitude: 0),
      ]),
      const GeoPoint(latitude: 0, longitude: 0),
    );

    expect(geometry.progressMeters, 0);
    expect(geometry.riddenPaths, isEmpty);
    expect(geometry.remainingPaths.single, hasLength(4));
  });

  test('progress is monotonic and ignores positions clearly off route', () {
    final tracker = RouteProgressTracker(maximumTrackingDistanceMeters: 100);
    final route = _route(const [
      GeoPoint(latitude: 0, longitude: 0),
      GeoPoint(latitude: 0, longitude: 0.02),
    ]);

    final forward = tracker.update(
      route,
      const GeoPoint(latitude: 0, longitude: 0.015),
    );
    final backwards = tracker.update(
      route,
      const GeoPoint(latitude: 0, longitude: 0.005),
    );
    final offRoute = tracker.update(
      route,
      const GeoPoint(latitude: 0.02, longitude: 0.019),
    );

    expect(backwards.progressMeters, forward.progressMeters);
    expect(offRoute.progressMeters, forward.progressMeters);
  });

  test('distance to a sparse route measures its segments, not only points', () {
    final route = _route(const [
      GeoPoint(latitude: 0, longitude: 0),
      GeoPoint(latitude: 0, longitude: 0.2),
    ]);

    expect(
      distanceToRouteMeters(
        route,
        const GeoPoint(latitude: 0.0001, longitude: 0.1),
      ),
      lessThan(12),
    );
    expect(
      distanceToRouteMeters(
        route,
        const GeoPoint(latitude: 0.05, longitude: 0.1),
      ),
      greaterThan(5000),
    );
  });
}

ImportedRoute _route(List<GeoPoint> points) => ImportedRoute(
  id: 'route',
  name: 'Route',
  importedAt: DateTime.utc(2026, 7, 17),
  sourceFileName: 'route.gpx',
  paths: [RoutePath(kind: RoutePathKind.track, points: points)],
  waypoints: const [],
);
