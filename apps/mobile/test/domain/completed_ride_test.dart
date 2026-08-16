import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/completed_rides_controller.dart';
import 'package:ride_relay/domain/completed_ride.dart';
import 'package:ride_relay/domain/completed_ride_store.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/domain/ride_role.dart';

void main() {
  test('completed ride round-trips summary and route geometry', () {
    final ride = _ride();

    final restored = CompletedRide.fromJson(ride.toJson());

    expect(restored.rideId, ride.rideId);
    expect(restored.localRole, RideRole.tailEndCharlie);
    expect(restored.traveledRoute?.pathPointCount, 2);
    expect(restored.mapPoints, hasLength(2));
  });

  test('damaged optional geometry does not discard summary metadata', () {
    final json = _ride().toJson()
      ..['traveledRoute'] = {
        'schemaVersion': 1,
        'id': 'broken',
        'paths': 'not-a-list',
      };

    final restored = CompletedRide.fromJson(json);

    expect(restored.title, 'Ride 123456');
    expect(restored.traveledRoute, isNull);
    expect(restored.riderCount, 4);
  });

  test(
    'Ride Library metadata persists and archive/trash remain recoverable',
    () async {
      final store = InMemoryCompletedRideStore();
      await store.save(_ride());
      final controller = await CompletedRidesController.load(store);

      await controller.rename('ride-1', '  Mendip favourite  ');
      await controller.rate('ride-1', 5);
      await controller.setNotes('ride-1', '  Best before breakfast.  ');
      await controller.archive('ride-1');

      expect(controller.rides, isEmpty);
      expect(controller.archivedRides.single.title, 'Mendip favourite');
      expect(controller.archivedRides.single.rating, 5);
      expect(controller.archivedRides.single.notes, 'Best before breakfast.');

      await controller.moveToTrash(
        'ride-1',
        deletedAt: DateTime.utc(2026, 8, 16, 12),
      );
      expect(controller.archivedRides, isEmpty);
      expect(controller.deletedRides.single.deletedAt, isNotNull);

      await controller.restore('ride-1');
      final restored = CompletedRide.fromJson(
        (await store.list()).single.toJson(),
      );
      expect(controller.rides.single.rideId, 'ride-1');
      expect(restored.libraryName, 'Mendip favourite');
      expect(restored.rating, 5);
      expect(restored.notes, 'Best before breakfast.');
      expect(restored.libraryStatus, RideLibraryStatus.active);
      expect(restored.deletedAt, isNull);
    },
  );
}

CompletedRide _ride() => CompletedRide(
  rideId: 'ride-1',
  rideCode: '123456',
  rideName: null,
  localDisplayName: 'Oliver',
  localRole: RideRole.tailEndCharlie,
  startedAt: DateTime.utc(2026, 7, 23, 12),
  endedAt: DateTime.utc(2026, 7, 23, 14),
  archivedAt: DateTime.utc(2026, 7, 23, 14),
  riderCount: 4,
  eventCount: 12,
  totalDistanceMeters: 42000,
  markerSessions: const [],
  plannedRoute: null,
  traveledRoute: ImportedRoute(
    id: 'trail',
    name: 'Recorded trail',
    importedAt: DateTime.utc(2026, 7, 23, 14),
    sourceFileName: 'ride.gpx',
    paths: const [
      RoutePath(
        kind: RoutePathKind.track,
        points: [
          GeoPoint(latitude: 53, longitude: -1),
          GeoPoint(latitude: 54, longitude: -2),
        ],
      ),
    ],
    waypoints: const [],
  ),
);
