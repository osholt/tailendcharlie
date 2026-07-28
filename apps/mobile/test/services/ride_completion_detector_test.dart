import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/geo_point.dart';
import 'package:ride_relay/domain/imported_route.dart' as route_domain;
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/rider_location.dart';
import 'package:ride_relay/services/ride_completion_detector.dart';
import 'package:ride_relay/services/route_progress.dart';

void main() {
  const detector = RideCompletionDetector();
  final now = DateTime.utc(2026, 7, 17, 12);
  const destination = GeoPoint(latitude: 51.5, longitude: -2.5);

  test('ends only when every known rider is near the destination', () {
    final arrived = [
      _location('lead', RideRole.lead, destination, now),
      _location(
        'tec',
        RideRole.tailEndCharlie,
        const GeoPoint(latitude: 51.5003, longitude: -2.5),
        now,
      ),
    ];

    expect(
      detector.everyoneReachedDestination(
        destination: destination,
        riderLocations: arrived,
        now: now,
        routeProgressFraction: 1,
      ),
      isTrue,
    );
    expect(
      detector.everyoneReachedDestination(
        destination: destination,
        riderLocations: [
          ...arrived,
          _location(
            'rider',
            RideRole.rider,
            const GeoPoint(latitude: 51.51, longitude: -2.5),
            now,
          ),
        ],
        now: now,
        routeProgressFraction: 1,
      ),
      isFalse,
    );
  });

  test('keeps a ride open when any rider location is stale', () {
    expect(
      detector.everyoneReachedDestination(
        destination: destination,
        riderLocations: [
          _location('lead', RideRole.lead, destination, now),
          _location(
            'tec',
            RideRole.tailEndCharlie,
            destination,
            now.subtract(const Duration(minutes: 3)),
          ),
        ],
        now: now,
        routeProgressFraction: 1,
      ),
      isFalse,
    );
  });

  test('keeps a ride open while the route is still ahead of the group', () {
    final atDestination = [_location('lead', RideRole.lead, destination, now)];

    for (final fraction in [0.0, 0.02, 0.5, 0.89]) {
      expect(
        detector.everyoneReachedDestination(
          destination: destination,
          riderLocations: atDestination,
          now: now,
          routeProgressFraction: fraction,
        ),
        isFalse,
        reason: 'a group $fraction of the way round has not arrived',
      );
    }
  });

  test('a degenerate progress reading never ends a ride', () {
    for (final fraction in [double.nan, double.infinity, -1.0]) {
      expect(
        detector.everyoneReachedDestination(
          destination: destination,
          riderLocations: [_location('lead', RideRole.lead, destination, now)],
          now: now,
          routeProgressFraction: fraction,
        ),
        isFalse,
      );
    }
  });

  // The Isle of Man regression (#206). A day tour is a loop: it finishes at the
  // hotel it started from, so proximity to the finish is satisfied on the start
  // line. This drives the real progress tracker rather than a hand-picked
  // fraction, because the two components together are what has to be correct.
  group('a loop whose finish is its start', () {
    final loop = _route(const [
      route_domain.GeoPoint(latitude: 54.15, longitude: -4.48),
      route_domain.GeoPoint(latitude: 54.25, longitude: -4.48),
      route_domain.GeoPoint(latitude: 54.25, longitude: -4.38),
      route_domain.GeoPoint(latitude: 54.15, longitude: -4.48),
    ]);
    const start = route_domain.GeoPoint(latitude: 54.15, longitude: -4.48);
    const finish = GeoPoint(latitude: 54.15, longitude: -4.48);

    bool endsWith(List<route_domain.GeoPoint> riddenFixes) {
      final tracker = RouteProgressTracker();
      var geometry = tracker.update(loop, start);
      for (final fix in riddenFixes) {
        geometry = tracker.update(loop, fix);
      }
      return detector.everyoneReachedDestination(
        destination: finish,
        riderLocations: [_location('lead', RideRole.lead, finish, now)],
        now: now,
        routeProgressFraction: geometry.totalMeters <= 0
            ? 0
            : geometry.progressMeters / geometry.totalMeters,
      );
    }

    test('does not end on the start line', () {
      expect(endsWith(const []), isFalse);
    });

    test('does not end after only the first leg', () {
      expect(
        endsWith(const [
          route_domain.GeoPoint(latitude: 54.18, longitude: -4.48),
          route_domain.GeoPoint(latitude: 54.25, longitude: -4.48),
        ]),
        isFalse,
      );
    });

    test('ends once the loop has been ridden back to the finish', () {
      expect(
        endsWith(const [
          route_domain.GeoPoint(latitude: 54.25, longitude: -4.48),
          route_domain.GeoPoint(latitude: 54.25, longitude: -4.38),
          route_domain.GeoPoint(latitude: 54.20, longitude: -4.43),
          route_domain.GeoPoint(latitude: 54.15, longitude: -4.48),
        ]),
        isTrue,
      );
    });
  });
}

route_domain.ImportedRoute _route(List<route_domain.GeoPoint> points) =>
    route_domain.ImportedRoute(
      id: 'route',
      name: 'Route',
      importedAt: DateTime.utc(2026, 7, 17),
      sourceFileName: 'route.gpx',
      paths: [
        route_domain.RoutePath(
          kind: route_domain.RoutePathKind.track,
          points: points,
        ),
      ],
      waypoints: const [],
    );

RiderLocation _location(
  String id,
  RideRole role,
  GeoPoint point,
  DateTime recordedAt,
) => RiderLocation(
  riderId: id,
  displayName: id,
  role: role,
  sample: LocationSample(
    position: point,
    recordedAt: recordedAt,
    accuracyMeters: 5,
  ),
  receivedAt: recordedAt,
);
