import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/completed_ride.dart';
import 'package:ride_relay/domain/completed_ride_store.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/domain/recorded_route_store.dart';
import 'package:ride_relay/services/completed_ride_plan_link.dart';
import 'package:ride_relay/services/free_roam_ride_recorder.dart';
import 'package:ride_relay/services/stored_route_library.dart';

void main() {
  test(
    'library reuse preserves source identity and provider duration',
    () async {
      final library = InMemoryRecordedRouteStore();
      await library.save(plan());
      final service = StoredRouteLibrary(
        recordedRoutes: library,
        completedRides: InMemoryCompletedRideStore(),
      );
      final candidate = (await service.list()).single;
      final prepared = service
          .prepare(StoredRouteSelection(candidate: candidate))
          .route;
      final persisted = ImportedRoute.fromJson(prepared.toJson());
      expect(persisted.id, isNot('original'));
      expect(persisted.sourceRouteId, 'original');
      expect(persisted.plannedDuration, const Duration(hours: 1));
      expect(
        persisted.withLibraryDetails(name: 'Renamed').sourceRouteId,
        'original',
      );
      expect(
        service
            .prepare(StoredRouteSelection(candidate: candidate, reversed: true))
            .route
            .plannedDuration,
        isNull,
      );
    },
  );

  test(
    'original GPX snapshot survives binning, replay and library removal',
    () async {
      final library = InMemoryRecordedRouteStore();
      await library.save(plan());
      final recorder = FreeRoamRideRecorder(localDisplayName: 'Rider');
      recorder.start(plan(id: 'matched', source: 'original'));
      final ride = recorder.checkpoint()!;
      final linked = await completeRidePlanLink(ride, library: library);
      expect(linked.sourceRoute?.id, 'original');
      final restored = CompletedRide.fromJson(linked.toJson()).copyWith(
        libraryName: 'My edit',
        libraryStatus: RideLibraryStatus.deleted,
        rating: 5,
      );
      await library.delete('original');
      final replay = await completeRidePlanLink(
        ride,
        existing: restored,
        library: library,
      );
      expect(replay.comparisonPlan?.id, 'original');
      expect(replay.title, 'My edit');
      expect(replay.rating, 5);
      expect(replay.libraryStatus, RideLibraryStatus.deleted);
      expect(replay.plannedRoute?.id, 'matched');
    },
  );

  test(
    'similar route names never imply a link and failed lookup saves actual',
    () async {
      final recorder = FreeRoamRideRecorder(localDisplayName: 'Rider');
      recorder.start(plan(id: 'different'));
      final ride = recorder.checkpoint()!;
      final library = InMemoryRecordedRouteStore();
      await library.save(plan());
      expect(
        (await completeRidePlanLink(ride, library: library)).sourceRoute,
        isNull,
      );
      expect(
        (await completeRidePlanLink(ride, library: FailingLibrary())).rideId,
        ride.rideId,
      );
    },
  );
}

ImportedRoute plan({String id = 'original', String? source}) => ImportedRoute(
  id: id,
  name: 'Original plan',
  sourceRouteId: source,
  importedAt: DateTime.utc(2026),
  sourceFileName: 'plan.gpx',
  plannedDuration: const Duration(hours: 1),
  paths: const [
    RoutePath(
      kind: RoutePathKind.track,
      points: [
        GeoPoint(latitude: 50, longitude: 1),
        GeoPoint(latitude: 50.1, longitude: 1),
      ],
    ),
  ],
  waypoints: const [],
);

class FailingLibrary extends InMemoryRecordedRouteStore {
  @override
  Future<List<ImportedRoute>> list() async => throw StateError('unreadable');
}
