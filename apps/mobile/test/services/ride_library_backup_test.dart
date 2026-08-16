import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/completed_ride.dart';
import 'package:ride_relay/domain/completed_ride_store.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/domain/recorded_route_store.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/services/ride_library_backup.dart';

void main() {
  test('backs up and restores rides, routes and local-only metadata', () async {
    final sourceRides = InMemoryCompletedRideStore();
    final sourceRoutes = InMemoryRecordedRouteStore();
    await sourceRides.save(_ride());
    await sourceRoutes.save(_route('recorded'));
    final source = RideLibraryBackupService(
      completedRides: sourceRides,
      recordedRoutes: sourceRoutes,
    );

    final targetRides = InMemoryCompletedRideStore();
    final targetRoutes = InMemoryRecordedRouteStore();
    final target = RideLibraryBackupService(
      completedRides: targetRides,
      recordedRoutes: targetRoutes,
    );
    final result = await target.restore(
      await source.encode(exportedAt: DateTime.utc(2026, 8, 16)),
    );

    expect(result.completedRideCount, 1);
    expect(result.recordedRouteCount, 1);
    final ride = (await targetRides.list()).single;
    expect(ride.libraryName, 'A favourite road');
    expect(ride.rating, 5);
    expect(ride.notes, 'Great in the morning.');
    expect(ride.libraryStatus, RideLibraryStatus.archived);
    expect((await targetRoutes.list()).single.id, 'recorded');

    final duplicate = await target.restore(
      await source.encode(exportedAt: DateTime.utc(2026, 8, 16)),
    );
    expect(duplicate.completedRideCount, 0);
    expect(duplicate.recordedRouteCount, 0);
    expect((await targetRides.list()).single.libraryName, 'A favourite road');
    expect((await targetRoutes.list()).single.id, 'recorded');
  });

  test('validates every entry before changing either store', () async {
    final rides = InMemoryCompletedRideStore();
    final routes = InMemoryRecordedRouteStore();
    final service = RideLibraryBackupService(
      completedRides: rides,
      recordedRoutes: routes,
    );

    await expectLater(
      service.restore(
        '{"schemaVersion":1,"completedRides":[{}],"recordedRoutes":[]}',
      ),
      throwsA(anything),
    );

    expect(await rides.list(), isEmpty);
    expect(await routes.list(), isEmpty);
  });

  test('rejects a legacy schema without changing the library', () async {
    final rides = InMemoryCompletedRideStore();
    final routes = InMemoryRecordedRouteStore();
    final service = RideLibraryBackupService(
      completedRides: rides,
      recordedRoutes: routes,
    );

    await expectLater(
      service.restore(
        '{"schemaVersion":0,"completedRides":[],"recordedRoutes":[]}',
      ),
      throwsFormatException,
    );

    expect(await rides.list(), isEmpty);
    expect(await routes.list(), isEmpty);
  });
}

CompletedRide _ride() => CompletedRide(
  rideId: 'ride-1',
  rideCode: '209271',
  rideName: null,
  libraryName: 'A favourite road',
  rating: 5,
  notes: 'Great in the morning.',
  libraryStatus: RideLibraryStatus.archived,
  localDisplayName: 'Oliver',
  localRole: RideRole.lead,
  startedAt: DateTime.utc(2026, 8, 15, 10),
  endedAt: DateTime.utc(2026, 8, 15, 11),
  archivedAt: DateTime.utc(2026, 8, 15, 11),
  riderCount: 1,
  eventCount: 10,
  totalDistanceMeters: 17000,
  markerSessions: const [],
  plannedRoute: null,
  traveledRoute: _route('trail'),
);

ImportedRoute _route(String id) => ImportedRoute(
  id: id,
  name: id,
  importedAt: DateTime.utc(2026, 8, 15),
  sourceFileName: '$id.gpx',
  paths: const [
    RoutePath(
      kind: RoutePathKind.track,
      points: [
        GeoPoint(latitude: 51.45, longitude: -2.52),
        GeoPoint(latitude: 51.46, longitude: -2.11),
      ],
    ),
  ],
  waypoints: const [],
);
