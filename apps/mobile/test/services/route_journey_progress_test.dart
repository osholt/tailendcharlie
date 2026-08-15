import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/services/route_journey_progress.dart';
import 'package:ride_relay/services/route_progress.dart';

void main() {
  final route = ImportedRoute(
    id: 'stops',
    name: 'Three stops',
    importedAt: DateTime.utc(2026, 8, 14),
    sourceFileName: 'stops.gpx',
    paths: const [
      RoutePath(
        kind: RoutePathKind.track,
        points: [
          GeoPoint(latitude: 0, longitude: 0),
          GeoPoint(latitude: 0, longitude: 0.009),
          GeoPoint(latitude: 0, longitude: 0.018),
        ],
      ),
    ],
    waypoints: const [
      RouteWaypoint(point: GeoPoint(latitude: 0, longitude: 0), name: 'Start'),
      RouteWaypoint(
        point: GeoPoint(latitude: 0, longitude: 0.009),
        name: 'Fuel stop',
      ),
      RouteWaypoint(
        point: GeoPoint(latitude: 0, longitude: 0.018),
        name: 'Finish',
      ),
    ],
    plannedDuration: const Duration(seconds: 200),
  );

  test('shows route remaining and the next deliberate stop', () {
    final tracker = RouteJourneyProgressTracker();
    final now = DateTime.utc(2026, 8, 14, 12);
    final progress = tracker.update(
      route: route,
      geometry: const RouteProgressGeometry(
        riddenPaths: [],
        remainingPaths: [],
        progressMeters: 300,
        totalMeters: 2001.5,
      ),
      speedMetersPerSecond: 10,
      now: now,
    )!;

    expect(progress.remainingDistanceMeters, closeTo(1701.5, 0.1));
    expect(progress.remainingTime, const Duration(seconds: 170));
    expect(progress.arrivalTime, now.add(const Duration(seconds: 170)));
    expect(progress.nextWaypointName, 'Fuel stop');
    expect(progress.nextWaypointDistanceMeters, closeTo(700.8, 2));
    expect(
      progress.nextWaypointArrivalTime,
      now.add(const Duration(seconds: 70)),
    );
  });

  test('holds the moving estimate through a stop instead of saying now', () {
    final tracker = RouteJourneyProgressTracker();
    final now = DateTime.utc(2026, 8, 14, 12);
    tracker.update(
      route: route,
      geometry: const RouteProgressGeometry(
        riddenPaths: [],
        remainingPaths: [],
        progressMeters: 300,
        totalMeters: 2001.5,
      ),
      speedMetersPerSecond: 10,
      now: now,
    );

    final stopped = tracker.update(
      route: route,
      geometry: const RouteProgressGeometry(
        riddenPaths: [],
        remainingPaths: [],
        progressMeters: 300,
        totalMeters: 2001.5,
      ),
      speedMetersPerSecond: 0,
      now: now.add(const Duration(minutes: 1)),
    )!;

    expect(stopped.remainingTime, const Duration(seconds: 170));
    expect(
      stopped.arrivalTime,
      now.add(const Duration(minutes: 1, seconds: 170)),
    );
  });

  test('uses planned route timing before there is a useful moving fix', () {
    final progress = RouteJourneyProgressTracker().update(
      route: route,
      geometry: const RouteProgressGeometry(
        riddenPaths: [],
        remainingPaths: [],
        progressMeters: 300,
        totalMeters: 2001.5,
      ),
      speedMetersPerSecond: 1,
      now: DateTime.utc(2026, 8, 14, 12),
    )!;

    expect(progress.remainingDistanceMeters, greaterThan(0));
    expect(progress.remainingTime, const Duration(seconds: 170));
    expect(progress.arrivalTime, DateTime.utc(2026, 8, 14, 12, 2, 50));
    expect(
      progress.nextWaypointArrivalTime,
      DateTime.utc(2026, 8, 14, 12, 1, 10),
    );
  });

  test('keeps imported untimed routes honest until movement', () {
    final untimed = ImportedRoute(
      id: route.id,
      name: route.name,
      importedAt: route.importedAt,
      sourceFileName: 'imported.gpx',
      paths: route.paths,
      waypoints: route.waypoints,
    );
    final progress = RouteJourneyProgressTracker().update(
      route: untimed,
      geometry: const RouteProgressGeometry(
        riddenPaths: [],
        remainingPaths: [],
        progressMeters: 300,
        totalMeters: 2001.5,
      ),
      speedMetersPerSecond: 1,
      now: DateTime.utc(2026, 8, 14, 12),
    )!;

    expect(progress.remainingTime, isNull);
    expect(progress.arrivalTime, isNull);
  });

  test('moves to the following stop after passing a waypoint', () {
    final progress = RouteJourneyProgressTracker().update(
      route: route,
      geometry: const RouteProgressGeometry(
        riddenPaths: [],
        remainingPaths: [],
        progressMeters: 1100,
        totalMeters: 2001.5,
      ),
      speedMetersPerSecond: 10,
      now: DateTime.utc(2026, 8, 14, 12),
    )!;

    expect(progress.nextWaypointName, 'Finish');
    expect(progress.nextWaypointDistanceMeters, closeTo(901.5, 2));
  });
}
