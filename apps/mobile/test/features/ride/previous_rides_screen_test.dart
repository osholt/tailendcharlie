import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/completed_ride.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/features/ride/previous_rides_screen.dart';

void main() {
  test('archived map bounds include sparse and self-crossing geometry', () {
    final bounds = archivedRideBounds(const [
      GeoPoint(latitude: 54.1, longitude: -2.3),
      GeoPoint(latitude: 53.2, longitude: -0.8),
      GeoPoint(latitude: 54.1, longitude: -2.3),
      GeoPoint(latitude: 52.8, longitude: -1.4),
    ]);

    expect(bounds.southwest.latitude, 52.8);
    expect(bounds.southwest.longitude, closeTo(-2.3, 1e-9));
    expect(bounds.northeast.latitude, 54.1);
    expect(bounds.northeast.longitude, closeTo(-0.8, 1e-9));
  });

  test('archived map bounds retain a stationary single point', () {
    final bounds = archivedRideBounds(const [
      GeoPoint(latitude: 51.5074, longitude: -0.1278),
    ]);

    expect(bounds.southwest, bounds.northeast);
  });

  group('legend keys describe only the lines that are drawn (#211)', () {
    test('a ride with no planned route shows one key', () {
      final legend = archivedRideLegend(
        _ride(plannedRoute: null, traveledRoute: _line()),
      );

      expect(legend.planned, isFalse);
      expect(legend.traveled, isTrue);
    });

    test('a ride with no recorded trail shows one key', () {
      final legend = archivedRideLegend(
        _ride(plannedRoute: _line(), traveledRoute: null),
      );

      expect(legend.planned, isTrue);
      expect(legend.traveled, isFalse);
    });

    test('a ride with both shows both', () {
      final legend = archivedRideLegend(
        _ride(plannedRoute: _line(), traveledRoute: _line()),
      );

      expect(legend.planned, isTrue);
      expect(legend.traveled, isTrue);
    });

    // One fix is not a line. MapGeoJson.lines drops a path with fewer than two
    // points, so a key for it would describe nothing.
    test('a single recorded fix is not a drawable trail', () {
      final legend = archivedRideLegend(
        _ride(
          plannedRoute: null,
          traveledRoute: _line(const [GeoPoint(latitude: 53, longitude: -1)]),
        ),
      );

      expect(legend.traveled, isFalse);
    });

    test('an empty route shows no key', () {
      final legend = archivedRideLegend(
        _ride(plannedRoute: _line(const []), traveledRoute: null),
      );

      expect(legend.planned, isFalse);
      expect(legend.traveled, isFalse);
    });
  });
}

ImportedRoute _line([
  List<GeoPoint> points = const [
    GeoPoint(latitude: 53, longitude: -1),
    GeoPoint(latitude: 54, longitude: -2),
  ],
]) => ImportedRoute(
  id: 'route',
  name: 'Route',
  importedAt: DateTime.utc(2026, 7, 23, 14),
  sourceFileName: 'ride.gpx',
  paths: [RoutePath(kind: RoutePathKind.track, points: points)],
  waypoints: const [],
);

CompletedRide _ride({
  required ImportedRoute? plannedRoute,
  required ImportedRoute? traveledRoute,
}) => CompletedRide(
  rideId: 'ride-1',
  rideCode: '405400',
  rideName: null,
  localDisplayName: 'Oliver',
  localRole: RideRole.rider,
  startedAt: DateTime.utc(2026, 7, 27, 12),
  endedAt: DateTime.utc(2026, 7, 27, 13),
  archivedAt: DateTime.utc(2026, 7, 27, 13),
  riderCount: 3,
  eventCount: 12,
  totalDistanceMeters: 1300,
  markerSessions: const [],
  plannedRoute: plannedRoute,
  traveledRoute: traveledRoute,
);
