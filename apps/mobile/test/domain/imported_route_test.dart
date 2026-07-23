import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/imported_route.dart';

void main() {
  test('route JSON round-trip preserves geometry and metadata', () {
    final route = ImportedRoute(
      id: 'route-1',
      name: 'Saturday loop',
      description: 'Dry run',
      importedAt: DateTime.utc(2026, 7, 16, 9),
      sourceFileName: 'loop.gpx',
      paths: [
        RoutePath(
          kind: RoutePathKind.track,
          name: 'Track one',
          points: [
            GeoPoint(
              latitude: 53.1,
              longitude: -1.4,
              elevationMeters: 210,
              recordedAt: DateTime.utc(2026, 7, 16, 9, 1),
            ),
            const GeoPoint(latitude: 53.2, longitude: -1.5),
          ],
        ),
      ],
      waypoints: const [
        RouteWaypoint(
          point: GeoPoint(latitude: 53.3, longitude: -1.6),
          name: 'Fuel',
          description: 'Petrol station',
          symbol: 'Fuel',
        ),
      ],
      maneuvers: const [
        RouteManeuver(
          position: GeoPoint(latitude: 53.2, longitude: -1.5),
          type: 'turn',
          modifier: 'left',
          name: 'High Street',
          ref: 'A1',
        ),
      ],
    );

    final restored = ImportedRoute.fromJsonString(route.toJsonString());

    expect(restored.id, 'route-1');
    expect(restored.name, 'Saturday loop');
    expect(restored.pathPointCount, 2);
    expect(restored.paths.single.kind, RoutePathKind.track);
    expect(restored.paths.single.points.first.elevationMeters, 210);
    expect(restored.waypoints.single.name, 'Fuel');
    expect(restored.maneuvers.single.type, 'turn');
    expect(restored.maneuvers.single.modifier, 'left');
    expect(restored.maneuvers.single.name, 'High Street');
  });
}
