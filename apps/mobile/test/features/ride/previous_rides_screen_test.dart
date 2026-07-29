import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/completed_rides_controller.dart';
import 'package:ride_relay/controllers/distance_unit_controller.dart';
import 'package:ride_relay/domain/completed_ride.dart';
import 'package:ride_relay/domain/completed_ride_store.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/features/ride/previous_rides_screen.dart';
import 'package:ride_relay/services/stored_route_library.dart';

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

  testWidgets('Ride again returns the existing planned-route selection path', (
    tester,
  ) async {
    final ride = _ride(plannedRoute: _line(), traveledRoute: _line());
    final store = InMemoryCompletedRideStore();
    await store.save(ride);
    final completed = await CompletedRidesController.load(store);
    final distance = DistanceUnitController.forLocale(const Locale('en', 'GB'));
    StoredRouteSelection? result;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () async {
                result = await Navigator.of(context).push(
                  MaterialPageRoute<StoredRouteSelection>(
                    builder: (_) => PreviousRideDetailScreen(
                      ride: ride,
                      completedRides: completed,
                      distanceUnits: distance,
                    ),
                  ),
                );
              },
              child: const Text('Open ride'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open ride'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(const Key('archived-ride-again')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('archived-ride-again')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('archived-ride-again')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byKey(const Key('ride-again-previousRidePlan')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byKey(const Key('stored-route-reverse')));
    await tester.tap(find.byKey(const Key('use-stored-route')));
    await tester.pump(const Duration(milliseconds: 300));

    expect(result, isNotNull);
    expect(result!.candidate.origin, StoredRouteOrigin.previousRidePlan);
    expect(result!.reversed, isTrue);
  });

  testWidgets('an archived ride names and preserves a recording gap', (
    tester,
  ) async {
    final ride = _ride(plannedRoute: null, traveledRoute: _splitLine());
    final store = InMemoryCompletedRideStore();
    await store.save(ride);
    final completed = await CompletedRidesController.load(store);
    final distance = DistanceUnitController.forLocale(const Locale('en', 'GB'));

    await tester.pumpWidget(
      MaterialApp(
        home: PreviousRideDetailScreen(
          ride: ride,
          completedRides: completed,
          distanceUnits: distance,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(ride.hasRecordingGaps, isTrue);
    expect(
      find.byKey(const Key('archived-ride-recording-gap')),
      findsOneWidget,
    );
    expect(find.text('This recording has gaps'), findsOneWidget);
    expect(find.textContaining('left blank'), findsOneWidget);
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

ImportedRoute _splitLine() => ImportedRoute(
  id: 'route-with-gap',
  name: 'Route with gap',
  importedAt: DateTime.utc(2026, 7, 29, 14),
  sourceFileName: 'ride.gpx',
  paths: const [
    RoutePath(
      kind: RoutePathKind.track,
      points: [
        GeoPoint(latitude: 53, longitude: -1),
        GeoPoint(latitude: 53.001, longitude: -1),
      ],
    ),
    RoutePath(
      kind: RoutePathKind.track,
      points: [
        GeoPoint(latitude: 54, longitude: -2),
        GeoPoint(latitude: 54.001, longitude: -2),
      ],
    ),
  ],
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
