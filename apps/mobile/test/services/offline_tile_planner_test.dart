import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/services/offline_tile_planner.dart';

void main() {
  const planner = OfflineTilePlanner();

  test('selects a buffered, de-duplicated route corridor', () {
    final tiles = planner.planRouteCorridor(
      _route(const [
        GeoPoint(latitude: 53.3431, longitude: -1.7769),
        GeoPoint(latitude: 53.3496, longitude: -1.8138),
      ]),
      minimumZoom: 12,
      maximumZoom: 12,
      corridorTileRadius: 1,
      maximumTiles: 100,
    );

    expect(tiles, isNotEmpty);
    expect(tiles.every((tile) => tile.zoom == 12), isTrue);
    expect(tiles.toSet(), hasLength(tiles.length));
  });

  test('fails before an unbounded corridor can be planned', () {
    expect(
      () => planner.planRouteCorridor(
        _route(const [
          GeoPoint(latitude: 50, longitude: -5),
          GeoPoint(latitude: 58, longitude: 1),
        ]),
        minimumZoom: 14,
        maximumZoom: 14,
        maximumTiles: 20,
      ),
      throwsA(isA<OfflineTileLimitException>()),
    );
  });
}

ImportedRoute _route(List<GeoPoint> points) => ImportedRoute(
  id: 'route',
  name: 'Route',
  importedAt: DateTime.utc(2026),
  sourceFileName: 'route.gpx',
  paths: [RoutePath(kind: RoutePathKind.track, points: points)],
  waypoints: const [],
);
