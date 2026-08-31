import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/completed_rides_controller.dart';
import 'package:ride_relay/controllers/personal_ride_heatmap_controller.dart';
import 'package:ride_relay/domain/completed_ride.dart';
import 'package:ride_relay/domain/completed_ride_store.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(const {}));

  test('uses travelled tracks and never planned routes', () {
    final heatmap = const PersonalRideHeatmapBuilder().build([
      _ride(
        'one',
        planned: _route([_path(51.0, -3.0, 51.01, -3.01)]),
        travelled: _route([_path(51.45, -2.59, 51.46, -2.58)]),
      ),
    ]);

    expect(heatmap.cells, isNotEmpty);
    expect(
      heatmap.cells.every((cell) => cell.centre.latitude > 51.4),
      isTrue,
      reason: 'the planned route must not enter private coverage',
    );
  });

  test('repeated rides increase intensity', () {
    final route = _route([_path(51.45, -2.59, 51.451, -2.589)]);
    final once = const PersonalRideHeatmapBuilder().build([
      _ride('one', travelled: route),
    ]);
    final twice = const PersonalRideHeatmapBuilder().build([
      _ride('one', travelled: route),
      _ride('two', travelled: route),
    ]);

    expect(once.cells.map((cell) => cell.visits), everyElement(1));
    expect(twice.cells.map((cell) => cell.visits), everyElement(2));
    expect(twice.cells.first.weight, greaterThan(once.cells.first.weight));
  });

  test('a loop records a later return to a covered cell', () {
    final heatmap = const PersonalRideHeatmapBuilder().build([
      _ride(
        'loop',
        travelled: _route([
          const RoutePath(
            kind: RoutePathKind.track,
            points: [
              GeoPoint(latitude: 51.4500, longitude: -2.5900),
              GeoPoint(latitude: 51.4510, longitude: -2.5800),
              GeoPoint(latitude: 51.4500, longitude: -2.5900),
            ],
          ),
        ]),
      ),
    ]);

    expect(heatmap.cells.any((cell) => cell.visits >= 2), isTrue);
  });

  test('separate recorded paths do not draw across a GPS gap', () {
    final heatmap = const PersonalRideHeatmapBuilder().build([
      _ride(
        'gapped',
        travelled: _route([
          _path(51.45, -2.59, 51.4501, -2.5899),
          _path(52.45, -1.59, 52.4501, -1.5899),
        ]),
      ),
    ]);

    expect(heatmap.cells.length, lessThan(10));
  });

  test('empty archives stay empty', () {
    expect(const PersonalRideHeatmapBuilder().build(const []).cells, isEmpty);
  });

  test('adjacent coverage cells share a complete edge (#661)', () {
    const left = PersonalRideHeatmapCell(
      x: 64600,
      y: 43500,
      visits: 1,
      weight: 0.4,
    );
    const right = PersonalRideHeatmapCell(
      x: 64601,
      y: 43500,
      visits: 2,
      weight: 0.7,
    );

    expect(left.polygon[1].latitude, right.polygon[0].latitude);
    expect(left.polygon[1].longitude, right.polygon[0].longitude);
    expect(left.polygon[2].latitude, right.polygon[3].latitude);
    expect(left.polygon[2].longitude, right.polygon[3].longitude);

    final geoJson = const PersonalRideHeatmap(
      cells: [left, right],
      inputPointCount: 2,
      truncated: false,
    ).toCellGeoJson();
    final features = geoJson['features']! as List;
    final ring =
        ((features.first as Map)['geometry'] as Map)['coordinates'] as List;
    final points = ring.single as List;
    expect(points, hasLength(5));
    expect(points.first, points.last, reason: 'GeoJSON polygon rings close');
  });

  test('coverage cells stay granular at street scale', () {
    const cell = PersonalRideHeatmapCell(
      x: 258400,
      y: 174000,
      visits: 1,
      weight: 0.4,
    );

    final longitudeSpan = cell.polygon[1].longitude - cell.polygon[0].longitude;
    expect(
      longitudeSpan,
      lessThan(0.001),
      reason:
          'a personal heatmap cell should be under about 70 metres wide at UK latitudes',
    );
  });

  test(
    'visibility is on by default and an explicit off choice persists',
    () async {
      final store = InMemoryCompletedRideStore();
      await store.save(
        _ride('one', travelled: _route([_path(51.45, -2.59, 51.46, -2.58)])),
      );
      final controller = await PersonalRideHeatmapController.load(store: store);
      addTearDown(controller.dispose);

      expect(controller.visible, isTrue);
      expect(controller.heatmap.cells, isNotEmpty);

      await controller.setVisible(false);
      expect(controller.heatmap.cells, isNotEmpty);

      final reloaded = await PersonalRideHeatmapController.load(store: store);
      addTearDown(reloaded.dispose);
      expect(reloaded.visible, isFalse);
      expect(reloaded.heatmap.cells, isNotEmpty);
    },
  );

  test('saving and trashing rides rebuilds visible coverage', () async {
    final rides = await CompletedRidesController.load(
      InMemoryCompletedRideStore(),
    );
    addTearDown(rides.dispose);
    final controller = await PersonalRideHeatmapController.load(store: rides);
    addTearDown(controller.dispose);
    await controller.setVisible(true);

    await rides.save(
      _ride('one', travelled: _route([_path(51.45, -2.59, 51.46, -2.58)])),
    );
    await _settleAsyncRefresh();
    expect(controller.heatmap.cells, isNotEmpty);

    await rides.moveToTrash('one');
    await _settleAsyncRefresh();
    expect(controller.heatmap.cells, isEmpty);
  });

  test('100,000 archived fixes are reduced to a bounded spatial index', () {
    final rides = [
      for (var ride = 0; ride < 100; ride += 1)
        _ride(
          '$ride',
          travelled: _route([
            RoutePath(
              kind: RoutePathKind.track,
              points: [
                for (var point = 0; point < 1000; point += 1)
                  GeoPoint(
                    latitude: 50.5 + ride * 0.001,
                    longitude: -4 + point * 0.00001,
                  ),
              ],
            ),
          ]),
        ),
    ];
    final stopwatch = Stopwatch()..start();

    final heatmap = const PersonalRideHeatmapBuilder(
      maximumCells: 20000,
    ).build(rides);
    stopwatch.stop();

    expect(heatmap.inputPointCount, 100000);
    expect(heatmap.cells.length, lessThanOrEqualTo(20000));
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
  });
}

Future<void> _settleAsyncRefresh() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

CompletedRide _ride(
  String id, {
  ImportedRoute? planned,
  ImportedRoute? travelled,
}) => CompletedRide(
  rideId: id,
  rideCode: id.padLeft(6, '0'),
  rideName: null,
  localDisplayName: 'Oliver',
  localRole: RideRole.lead,
  startedAt: DateTime.utc(2026, 8, 12, 9),
  endedAt: DateTime.utc(2026, 8, 12, 10),
  archivedAt: DateTime.utc(2026, 8, 12, 10, 1),
  riderCount: 1,
  eventCount: 0,
  totalDistanceMeters: 0,
  markerSessions: const [],
  plannedRoute: planned,
  traveledRoute: travelled,
);

ImportedRoute _route(List<RoutePath> paths) => ImportedRoute(
  id: 'route',
  name: 'Route',
  importedAt: DateTime.utc(2026, 8, 12),
  sourceFileName: 'local',
  paths: paths,
  waypoints: const [],
);

RoutePath _path(
  double startLatitude,
  double startLongitude,
  double endLatitude,
  double endLongitude,
) => RoutePath(
  kind: RoutePathKind.track,
  points: [
    GeoPoint(latitude: startLatitude, longitude: startLongitude),
    GeoPoint(latitude: endLatitude, longitude: endLongitude),
  ],
);
