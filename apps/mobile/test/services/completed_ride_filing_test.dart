import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/completed_ride.dart';
import 'package:ride_relay/domain/completed_ride_store.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/services/completed_ride_filing.dart';

final _morning = DateTime.utc(2026, 10, 4, 9);

ImportedRoute _track(String id, List<GeoPoint> points) => ImportedRoute(
  id: id,
  name: id,
  importedAt: _morning,
  sourceFileName: '$id.gpx',
  paths: [RoutePath(kind: RoutePathKind.track, points: points)],
  waypoints: const [],
);

CompletedRide _ride(
  String id, {
  required int startHour,
  required double meters,
  int riders = 1,
  String? name,
  String? continues,
  String code = 'PERSONAL',
}) => CompletedRide(
  rideId: id,
  rideCode: code,
  rideName: name,
  localDisplayName: 'Oliver',
  localRole: RideRole.rider,
  startedAt: _morning.add(Duration(hours: startHour)),
  endedAt: _morning.add(Duration(hours: startHour + 1)),
  archivedAt: _morning.add(Duration(hours: startHour + 1)),
  riderCount: riders,
  eventCount: 10,
  totalDistanceMeters: meters,
  markerSessions: const [],
  plannedRoute: null,
  traveledRoute: _track('$id-track', [
    GeoPoint(latitude: 52 + startHour / 10, longitude: -1),
    GeoPoint(latitude: 52.05 + startHour / 10, longitude: -1),
  ]),
  continuesRideId: continues,
);

void main() {
  test('a ride that continued nothing is filed as it is', () async {
    final store = InMemoryCompletedRideStore();

    await fileCompletedRide(store, _ride('solo', startHour: 0, meters: 1000));

    expect((await store.list()).single.legs, hasLength(1));
  });

  test('solo then group is one ride, with both legs', () async {
    final store = InMemoryCompletedRideStore();
    await fileCompletedRide(
      store,
      _ride('solo', startHour: 0, meters: 12000, name: 'To Town'),
    );

    final filed = await fileCompletedRide(
      store,
      _ride(
        'group',
        startHour: 1,
        meters: 30000,
        riders: 5,
        code: '123456',
        continues: 'solo',
      ),
    );

    final stored = await store.list();
    expect(stored, hasLength(1));
    expect(stored.single.rideId, 'group');
    expect(filed.legs.map((leg) => leg.rideId), ['solo', 'group']);
    expect(filed.totalDistanceMeters, 42000);
    expect(filed.startedAt, _morning);
    expect(filed.endedAt, _morning.add(const Duration(hours: 2)));
    expect(filed.riderCount, 5);
    expect(filed.rideCode, '123456');
    // The group ride had no name of its own; the ride keeps the solo one.
    expect(filed.title, 'To Town');
    // Both tracks, as separate paths: the gap is not drawn as a road.
    expect(filed.traveledRoute!.paths, hasLength(2));
  });

  test('a later leg saved again keeps the earlier leg', () async {
    final store = InMemoryCompletedRideStore();
    await fileCompletedRide(store, _ride('group', startHour: 0, meters: 30000));
    await fileCompletedRide(
      store,
      _ride('alone', startHour: 1, meters: 1000, continues: 'group'),
    );

    // A checkpoint: the same navigation, further along.
    await fileCompletedRide(
      store,
      _ride('alone', startHour: 1, meters: 9000, continues: 'group'),
    );

    final stored = (await store.list()).single;
    expect(stored.legs.map((leg) => leg.rideId), ['group', 'alone']);
    expect(stored.totalDistanceMeters, 39000);
  });

  test(
    'an earlier leg replayed after it was joined is not filed twice',
    () async {
      final store = InMemoryCompletedRideStore();
      await fileCompletedRide(
        store,
        _ride('group', startHour: 0, meters: 30000),
      );
      await fileCompletedRide(
        store,
        _ride('alone', startHour: 1, meters: 9000, continues: 'group'),
      );

      // The group ride's ended journal, replayed after a restart.
      await fileCompletedRide(
        store,
        _ride('group', startHour: 0, meters: 30000),
      );

      final stored = await store.list();
      expect(stored, hasLength(1));
      expect(stored.single.rideId, 'alone');
    },
  );

  test('library edits survive the next save of the joined ride', () async {
    final store = InMemoryCompletedRideStore();
    await fileCompletedRide(store, _ride('solo', startHour: 0, meters: 1000));
    final joined = await fileCompletedRide(
      store,
      _ride('group', startHour: 1, meters: 2000, continues: 'solo'),
    );
    await store.save(joined.copyWith(libraryName: 'Coast day', rating: 5));

    await fileCompletedRide(
      store,
      _ride('group', startHour: 1, meters: 2000, continues: 'solo'),
    );

    final stored = (await store.list()).single;
    expect(stored.title, 'Coast day');
    expect(stored.rating, 5);
    expect(stored.legs, hasLength(2));
  });

  test('solo, group, then alone again is still one ride', () async {
    final store = InMemoryCompletedRideStore();
    await fileCompletedRide(store, _ride('solo', startHour: 0, meters: 1000));
    await fileCompletedRide(
      store,
      _ride('group', startHour: 1, meters: 2000, continues: 'solo'),
    );
    await fileCompletedRide(
      store,
      _ride('alone', startHour: 2, meters: 4000, continues: 'group'),
    );

    final stored = (await store.list()).single;
    expect(stored.legs.map((leg) => leg.rideId), ['solo', 'group', 'alone']);
    expect(stored.totalDistanceMeters, 7000);
    expect(stored.traveledRoute!.paths, hasLength(3));
  });

  test('a joined ride reads back with its legs', () async {
    final joined = CompletedRide.joined(
      _ride('solo', startHour: 0, meters: 1000),
      _ride('group', startHour: 1, meters: 2000, continues: 'solo'),
    );

    final read = CompletedRide.fromJson(joined.toJson());

    expect(read.continuesRideId, 'solo');
    expect(read.legs.map((leg) => leg.rideId), ['solo', 'group']);
    expect(read.totalDistanceMeters, 3000);
  });
}
