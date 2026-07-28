import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/completed_ride.dart';
import 'package:ride_relay/domain/completed_ride_store.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/domain/recorded_route_store.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/services/stored_route_library.dart';

void main() {
  test('recorded routes and previous rides are both offered', () async {
    final recorded = InMemoryRecordedRouteStore();
    await recorded.save(_recordedRoute(id: 'scouted', name: 'Scouted loop'));
    final rides = InMemoryCompletedRideStore();
    await rides.save(
      _completedRide(
        rideId: 'ride-1',
        rideCode: 'AB12CD',
        plannedRoute: _recordedRoute(id: 'plan', name: 'Planned'),
        traveledRoute: _recordedRoute(id: 'track', name: 'Travelled'),
      ),
    );

    final candidates = await _library(recorded, rides).list();

    expect(candidates.map((candidate) => candidate.origin), [
      StoredRouteOrigin.recordedRoute,
      // The plan first: it is a better route than a recording of riding it.
      StoredRouteOrigin.previousRidePlan,
      StoredRouteOrigin.previousRideTrack,
    ]);
    expect(candidates.first.title, 'Scouted loop');
    expect(candidates[1].title, 'Sunday run');
    expect(candidates[1].rideCode, 'AB12CD');
    expect(candidates[1].isRecording, isFalse);
    expect(candidates[2].isRecording, isTrue);
  });

  test('a ride whose geometry is gone is not selectable', () async {
    final rides = InMemoryCompletedRideStore();
    await rides.save(
      _completedRide(rideId: 'kept', rideCode: 'KEEP01', traveledRoute: null),
    );
    await rides.save(
      _completedRide(
        rideId: 'single-fix',
        rideCode: 'ONEFIX',
        // A ride that produced one position is not a line anyone can ride.
        traveledRoute: ImportedRoute(
          id: 'single',
          name: 'One fix',
          importedAt: DateTime.utc(2026, 7, 20),
          sourceFileName: 'ride.gpx',
          paths: const [
            RoutePath(
              kind: RoutePathKind.track,
              points: [GeoPoint(latitude: 51.45, longitude: -2.59)],
            ),
          ],
          waypoints: const [],
        ),
      ),
    );

    final candidates = await _library(
      InMemoryRecordedRouteStore(),
      rides,
    ).list();

    expect(candidates, isEmpty);
  });

  test('a tidied recording keeps its kind and loses its stops', () async {
    final recorded = InMemoryRecordedRouteStore();
    await recorded.save(_stopStartRecording());
    final library = _library(recorded, InMemoryCompletedRideStore());
    final candidate = (await library.list()).single;

    final prepared = library.prepare(
      StoredRouteSelection(candidate: candidate),
    );

    expect(prepared.route.pathPointCount, lessThan(candidate.pointCount));
    // Still a track. Promoting it to a route would send it to the road matcher
    // as a handful of via points and redraw it somewhere else entirely.
    expect(prepared.route.paths.single.kind, RoutePathKind.track);
    expect(
      prepared.notes.single,
      allOf(contains('tidied recording'), contains('not a planned route')),
    );
  });

  test('the raw track is available unchanged', () async {
    final recorded = InMemoryRecordedRouteStore();
    final recording = _stopStartRecording();
    await recorded.save(recording);
    final library = _library(recorded, InMemoryCompletedRideStore());
    final candidate = (await library.list()).single;

    final prepared = library.prepare(
      StoredRouteSelection(
        candidate: candidate,
        variant: StoredRouteVariant.raw,
      ),
    );

    expect(prepared.route.pathPointCount, recording.paths.single.points.length);
    expect(prepared.notes.single, contains('raw recorded track'));
  });

  test('reversing runs the route the other way and drops its turns', () async {
    final rides = InMemoryCompletedRideStore();
    final planned = ImportedRoute(
      id: 'plan',
      name: 'Out',
      importedAt: DateTime.utc(2026, 7, 20),
      sourceFileName: 'plan.gpx',
      paths: const [
        RoutePath(
          kind: RoutePathKind.track,
          points: [
            GeoPoint(latitude: 51.45, longitude: -2.59),
            GeoPoint(latitude: 51.46, longitude: -2.58),
            GeoPoint(latitude: 51.47, longitude: -2.57),
          ],
        ),
      ],
      waypoints: const [
        RouteWaypoint(
          point: GeoPoint(latitude: 51.45, longitude: -2.59),
          name: 'Start',
        ),
        RouteWaypoint(
          point: GeoPoint(latitude: 51.47, longitude: -2.57),
          name: 'Finish',
        ),
      ],
      maneuvers: const [
        RouteManeuver(
          position: GeoPoint(latitude: 51.46, longitude: -2.58),
          type: 'turn',
          modifier: 'left',
        ),
      ],
    );
    await rides.save(
      _completedRide(
        rideId: 'ride-1',
        rideCode: 'AB12CD',
        plannedRoute: planned,
        traveledRoute: null,
      ),
    );
    final library = _library(InMemoryRecordedRouteStore(), rides);
    final candidate = (await library.list()).single;

    final prepared = library.prepare(
      StoredRouteSelection(candidate: candidate, reversed: true),
    );

    final points = prepared.route.paths.single.points;
    expect(points.first.latitude, 51.47);
    expect(points.last.latitude, 51.45);
    expect(prepared.route.waypoints.map((waypoint) => waypoint.name), [
      'Finish',
      'Start',
    ]);
    // A left turn read backwards is not a left turn.
    expect(prepared.route.maneuvers, isEmpty);
    expect(prepared.route.name, 'Sunday run (reversed)');
    expect(prepared.notes.last, contains('Reversed'));
  });

  test('a reversed track does not claim to travel back through time', () async {
    final recorded = InMemoryRecordedRouteStore();
    await recorded.save(_stopStartRecording());
    final library = _library(recorded, InMemoryCompletedRideStore());
    final candidate = (await library.list()).single;

    final prepared = library.prepare(
      StoredRouteSelection(
        candidate: candidate,
        variant: StoredRouteVariant.raw,
        reversed: true,
      ),
    );

    expect(
      prepared.route.paths.single.points.every(
        (point) => point.recordedAt == null,
      ),
      isTrue,
    );
  });

  test('a prepared route is a fresh route, not the stored one', () async {
    final recorded = InMemoryRecordedRouteStore();
    await recorded.save(_recordedRoute(id: 'scouted', name: 'Scouted loop'));
    final library = _library(recorded, InMemoryCompletedRideStore());
    final candidate = (await library.list()).single;

    final prepared = library.prepare(
      StoredRouteSelection(candidate: candidate),
    );

    // A new identity, so `RouteProgressTracker` restarts its progress rather
    // than carrying over the recording's.
    expect(prepared.route.id, 'prepared-route-id');
    expect(prepared.route.importedAt, DateTime.utc(2026, 7, 28));
    expect(prepared.route.name, 'Scouted loop');
    expect(prepared.route.sourceFileName, 'recorded-route');
  });
}

StoredRouteLibrary _library(
  RecordedRouteStore recorded,
  CompletedRideStore rides,
) => StoredRouteLibrary(
  recordedRoutes: recorded,
  completedRides: rides,
  idFactory: () => 'prepared-route-id',
  clock: () => DateTime.utc(2026, 7, 28),
);

ImportedRoute _recordedRoute({required String id, required String name}) =>
    ImportedRoute(
      id: id,
      name: name,
      importedAt: DateTime.utc(2026, 7, 26),
      sourceFileName: 'recorded.gpx',
      paths: const [
        RoutePath(
          kind: RoutePathKind.track,
          points: [
            GeoPoint(latitude: 51.45, longitude: -2.59),
            GeoPoint(latitude: 51.46, longitude: -2.58),
          ],
        ),
      ],
      waypoints: const [],
    );

/// A recording of riding 200 m north, waiting at a junction with the fix
/// wandering, then 200 m east.
ImportedRoute _stopStartRecording() {
  const metresPerDegreeLatitude = 111132.0;
  const metresPerDegreeLongitude = 69400.0;
  GeoPoint at(double northMeters, double eastMeters, int second) => GeoPoint(
    latitude: 51.45 + northMeters / metresPerDegreeLatitude,
    longitude: -2.59 + eastMeters / metresPerDegreeLongitude,
    recordedAt: DateTime.utc(2026, 7, 26, 9, 0, second),
  );
  return ImportedRoute(
    id: 'stop-start',
    name: 'Stop-start recording',
    importedAt: DateTime.utc(2026, 7, 26),
    sourceFileName: 'recorded.gpx',
    paths: [
      RoutePath(
        kind: RoutePathKind.track,
        points: [
          for (var index = 0; index < 20; index += 1) at(index * 10, 0, index),
          for (var index = 0; index < 12; index += 1)
            at(200, index.isEven ? 6 : -6, 20 + index),
          for (var index = 1; index <= 20; index += 1)
            at(200, index * 10, 32 + index),
        ],
      ),
    ],
    waypoints: const [],
  );
}

CompletedRide _completedRide({
  required String rideId,
  required String rideCode,
  ImportedRoute? plannedRoute,
  ImportedRoute? traveledRoute,
}) => CompletedRide(
  rideId: rideId,
  rideCode: rideCode,
  rideName: 'Sunday run',
  localDisplayName: 'Alex',
  localRole: RideRole.lead,
  startedAt: DateTime.utc(2026, 7, 26, 9),
  endedAt: DateTime.utc(2026, 7, 26, 12),
  archivedAt: DateTime.utc(2026, 7, 26, 12, 5),
  riderCount: 3,
  eventCount: 40,
  totalDistanceMeters: 42000,
  markerSessions: const [],
  plannedRoute: plannedRoute,
  traveledRoute: traveledRoute,
);
