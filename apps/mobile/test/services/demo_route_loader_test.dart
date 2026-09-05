import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/services/demo_route_loader.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('bundled demo follows the supplied French Day 3 route', () async {
    final route = await const BundledDemoRouteLoader().load();

    expect(route.name, 'Argentat to Saint-Privat — France');
    expect(route.pathPointCount, greaterThan(450));
    expect(route.waypoints, hasLength(3));
    expect(route.waypoints.first.name, 'Pont Henri IV, Argentat');
    expect(route.waypoints.last.name, 'Saint-Privat');
    expect(route.maneuvers, hasLength(4));

    final points = route.paths.single.points;
    expect(points.first.latitude, closeTo(45.09125, 0.00001));
    expect(points.first.longitude, closeTo(1.94011, 0.00001));
    expect(points.last.latitude, closeTo(45.13701, 0.00001));
    expect(points.last.longitude, closeTo(2.10279, 0.00001));
  });

  test(
    'bundled demo includes map-derived second-bike-drop decisions',
    () async {
      final maneuvers = await const BundledDemoRouteLoader().loadManeuvers();

      expect(maneuvers, hasLength(4));
      expect(maneuvers.first.type, 'turn');
      expect(
        maneuvers.map((maneuver) => maneuver.name),
        contains('Rue de Bellevue'),
      );
      expect(
        maneuvers.map((maneuver) => maneuver.type),
        contains('roundabout'),
      );
      expect(
        maneuvers.every((maneuver) => maneuver.drivingSide == 'right'),
        isTrue,
      );
      expect(
        maneuvers.every((maneuver) => maneuver.trafficSideConfirmed),
        isTrue,
      );
    },
  );
}
