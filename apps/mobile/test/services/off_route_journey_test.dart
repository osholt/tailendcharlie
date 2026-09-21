import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/services/route_progress.dart';
import 'package:ride_relay/services/route_journey_progress.dart';

void main() {
  final route = ImportedRoute(
    id: 'journey',
    name: 'Journey',
    importedAt: DateTime.utc(2026),
    sourceFileName: 'journey.gpx',
    paths: const [
      RoutePath(
        kind: RoutePathKind.route,
        points: [
          GeoPoint(latitude: 0, longitude: 0),
          GeoPoint(latitude: 0, longitude: .1),
        ],
      ),
    ],
    waypoints: const [],
    plannedDuration: const Duration(minutes: 20),
  );
  final start = DateTime.utc(2026);
  test(
    'off-route coffee stop and recreation preserve progress and actual distance',
    () {
      final tracker = RouteProgressTracker();
      tracker.update(
        route,
        const GeoPoint(latitude: 0, longitude: 0),
        recordedAt: start,
      );
      var geometry = const RouteProgressGeometry.empty();
      for (var i = 1; i <= 40; i++) {
        geometry = tracker.update(
          route,
          GeoPoint(latitude: 0, longitude: i * .001),
          recordedAt: start.add(Duration(seconds: i * 10)),
        );
      }
      final ridden = geometry.travelledMeters;
      final progress = geometry.progressMeters;
      geometry = tracker.update(
        route,
        const GeoPoint(latitude: .003, longitude: .04),
        recordedAt: start.add(const Duration(seconds: 420)),
      );
      expect(geometry.progressMeters, progress);
      expect(geometry.travelledMeters, greaterThan(ridden + 300));
      final checkpoint =
          jsonDecode(jsonEncode(tracker.checkpoint)) as Map<String, dynamic>;
      final restored = RouteProgressTracker()..restore(route, checkpoint);
      final stopped = restored.update(
        route,
        const GeoPoint(latitude: .003, longitude: .04),
        recordedAt: start.add(const Duration(minutes: 30)),
      );
      expect(stopped.progressMeters, closeTo(progress, .01));
      expect(stopped.travelledMeters, closeTo(geometry.travelledMeters, .01));
      final journey = RouteJourneyProgressTracker().update(
        route: route,
        geometry: stopped,
        speedMetersPerSecond: 0,
        now: start,
      )!;
      expect(
        journey.remainingDistanceMeters,
        closeTo(geometry.totalMeters - progress, 1),
      );
      expect(
        journey.remainingDistanceMeters,
        lessThan(geometry.totalMeters * .7),
      );
      expect(journey.awaitingRejoin, true);
      expect(journey.remainingTime, isNull);
      final returned = restored.update(
        route,
        const GeoPoint(latitude: 0, longitude: .04),
        recordedAt: start.add(const Duration(minutes: 30, seconds: 30)),
      );
      expect(
        returned.travelledMeters,
        greaterThan(stopped.travelledMeters + 300),
      );
      expect(returned.progressMeters, closeTo(progress, .01));
    },
  );
  test(
    'rejoin ETA includes the remaining original plan, without restarting it',
    () {
      final tracker = RouteProgressTracker();
      tracker.update(route, const GeoPoint(latitude: 0, longitude: .04));
      final geometry = tracker.update(
        route,
        const GeoPoint(latitude: .003, longitude: .04),
      );
      final connector = ImportedRoute(
        id: 'rejoin',
        name: 'Rejoin',
        importedAt: start,
        sourceFileName: 'rejoin',
        paths: const [
          RoutePath(
            kind: RoutePathKind.route,
            points: [
              GeoPoint(latitude: .003, longitude: .04),
              GeoPoint(latitude: 0, longitude: .05),
            ],
          ),
        ],
        waypoints: const [],
        plannedDuration: const Duration(minutes: 2),
      );
      final rejoin = RouteProgressTracker().update(
        connector,
        connector.paths.first.points.first,
      );
      final progress = RouteJourneyProgressTracker().update(
        route: route,
        geometry: geometry,
        speedMetersPerSecond: 10,
        now: start,
        rejoinRoute: connector,
        rejoinGeometry: rejoin,
      )!;
      expect(
        progress.remainingDistanceMeters,
        closeTo(geometry.totalMeters * .5 + rejoin.totalMeters, 2),
      );
      expect(progress.remainingTime!.inSeconds, closeTo(600 + 120, 1));
      expect(progress.nextWaypointArrivalTime, progress.arrivalTime);
      final onPlan = tracker.update(
        route,
        const GeoPoint(latitude: 0, longitude: .05),
      );
      final stale = RouteJourneyProgressTracker().update(
        route: route,
        geometry: onPlan,
        speedMetersPerSecond: 10,
        now: start,
        rejoinRoute: connector,
        rejoinGeometry: rejoin,
      )!;
      expect(
        stale.remainingDistanceMeters,
        closeTo(onPlan.totalMeters * .5, 2),
      );
    },
  );
  test('selecting a different route starts a new odometer', () {
    final tracker = RouteProgressTracker();
    tracker.update(
      route,
      const GeoPoint(latitude: 0, longitude: 0),
      recordedAt: start,
    );
    expect(
      tracker
          .update(
            route,
            const GeoPoint(latitude: 0, longitude: .001),
            recordedAt: start.add(const Duration(seconds: 10)),
          )
          .travelledMeters,
      greaterThan(100),
    );
    final other = ImportedRoute(
      id: 'other',
      name: 'Other',
      importedAt: start,
      sourceFileName: 'other',
      paths: route.paths,
      waypoints: const [],
    );
    expect(
      tracker
          .update(
            other,
            const GeoPoint(latitude: 0, longitude: .001),
            recordedAt: start.add(const Duration(seconds: 20)),
          )
          .travelledMeters,
      0,
    );
  });

  test(
    'duplicate fixes, poor accuracy, and tracking gaps do not inflate odometer',
    () {
      final tracker = RouteProgressTracker();
      final a = const GeoPoint(latitude: 0, longitude: 0);
      tracker.update(route, a, recordedAt: start);
      tracker.update(
        route,
        const GeoPoint(latitude: 0, longitude: .01),
        recordedAt: start,
        accuracyMeters: 5,
      );
      tracker.update(
        route,
        const GeoPoint(latitude: 0, longitude: .01),
        recordedAt: start.add(const Duration(seconds: 1)),
        accuracyMeters: 500,
      );
      tracker.update(
        route,
        const GeoPoint(latitude: 0, longitude: .01),
        recordedAt: start.add(const Duration(minutes: 10)),
      );
      expect(
        tracker
            .update(
              route,
              a,
              recordedAt: start.add(const Duration(minutes: 10, seconds: 1)),
            )
            .travelledMeters,
        0,
      );
    },
  );
}
