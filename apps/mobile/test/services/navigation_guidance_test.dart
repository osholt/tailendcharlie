import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/services/navigation_guidance.dart';

void main() {
  const planner = NavigationGuidancePlanner();

  test('selects the next useful maneuver by monotonic route progress', () {
    final route = _route();

    final beforeFirst = planner.plan(
      route: route,
      position: const GeoPoint(latitude: 0, longitude: 0.005),
      progressMeters: 556,
    );
    final afterFirst = planner.plan(
      route: route,
      position: const GeoPoint(latitude: 0, longitude: 0.012),
      progressMeters: 1334,
    );

    expect(beforeFirst?.maneuver.name, 'First Road');
    expect(beforeFirst?.distanceMeters, closeTo(556, 15));
    expect(afterFirst?.maneuver.name, 'Second Road');
    expect(afterFirst?.distanceMeters, closeTo(890, 20));
  });

  test('holds the current instruction briefly while crossing the turn', () {
    final guidance = planner.plan(
      route: _route(),
      position: const GeoPoint(latitude: 0, longitude: 0.0101),
      progressMeters: 1123,
    );

    expect(guidance?.maneuver.name, 'First Road');
    expect(guidance?.distanceMeters, 0);
  });

  test('hides guidance when the rider is clearly away from the route', () {
    final guidance = planner.plan(
      route: _route(),
      position: const GeoPoint(latitude: 0.01, longitude: 0.005),
      progressMeters: 556,
    );

    expect(guidance, isNull);
  });

  test('skips non-instructional route-engine steps', () {
    final route = ImportedRoute(
      id: 'route',
      name: 'Route',
      importedAt: DateTime.utc(2026, 7, 22),
      sourceFileName: 'route.gpx',
      paths: const [
        RoutePath(
          kind: RoutePathKind.track,
          points: [
            GeoPoint(latitude: 0, longitude: 0),
            GeoPoint(latitude: 0, longitude: 0.02),
          ],
        ),
      ],
      waypoints: const [],
      maneuvers: const [
        RouteManeuver(
          position: GeoPoint(latitude: 0, longitude: 0.002),
          type: 'depart',
          modifier: 'straight',
        ),
        RouteManeuver(
          position: GeoPoint(latitude: 0, longitude: 0.01),
          type: 'turn',
          modifier: 'left',
          ref: 'A420',
        ),
      ],
    );

    final guidance = planner.plan(
      route: route,
      position: const GeoPoint(latitude: 0, longitude: 0),
      progressMeters: 0,
    );

    expect(guidance?.maneuver.type, 'turn');
    expect(guidance?.roadLabel, 'A420');
  });
}

ImportedRoute _route() => ImportedRoute(
  id: 'route',
  name: 'Route',
  importedAt: DateTime.utc(2026, 7, 22),
  sourceFileName: 'route.gpx',
  paths: const [
    RoutePath(
      kind: RoutePathKind.track,
      points: [
        GeoPoint(latitude: 0, longitude: 0),
        GeoPoint(latitude: 0, longitude: 0.01),
        GeoPoint(latitude: 0, longitude: 0.02),
        GeoPoint(latitude: 0, longitude: 0.03),
      ],
    ),
  ],
  waypoints: const [],
  maneuvers: const [
    RouteManeuver(
      position: GeoPoint(latitude: 0, longitude: 0.01),
      type: 'turn',
      modifier: 'left',
      name: 'First Road',
    ),
    RouteManeuver(
      position: GeoPoint(latitude: 0, longitude: 0.02),
      type: 'turn',
      modifier: 'right',
      name: 'Second Road',
    ),
  ],
);
