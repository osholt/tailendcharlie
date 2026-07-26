import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/geo_point.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/rider_location.dart';
import 'package:ride_relay/domain/route_alert.dart';
import 'package:ride_relay/services/leader_ride_status.dart';

void main() {
  final now = DateTime.utc(2026, 7, 17, 10);

  test('leader receives along-route TEC distance and estimated time gap', () {
    final status = const LeaderRideStatusCalculator().calculate(
      localRole: RideRole.lead,
      localRiderId: 'lead',
      localLocation: _location(
        id: 'lead',
        name: 'Lead',
        role: RideRole.lead,
        longitude: 0.015,
        speed: 10,
        at: now,
      ),
      riderLocations: [
        _location(
          id: 'tec',
          name: 'Charlie',
          role: RideRole.tailEndCharlie,
          longitude: 0.005,
          speed: 10,
          at: now,
        ),
      ],
      routeAlerts: const [],
      route: const [
        GeoPoint(latitude: 0, longitude: 0),
        GeoPoint(latitude: 0, longitude: 0.02),
      ],
      now: now,
    );

    expect(status, isNotNull);
    expect(status!.tecName, 'Charlie');
    expect(status.tecAvailability, TecAvailability.tracking);
    expect(status.tecRiderId, 'tec');
    expect(status.distanceToTecMeters, closeTo(1112, 10));
    expect(status.estimatedTimeToTec!.inSeconds, inInclusiveRange(105, 115));
  });

  group('the three TEC states stay distinct from an absent TEC', () {
    LeaderRideStatus? statusFor({
      List<RiderLocation> riderLocations = const [],
      Iterable<String> registeredTecRiderIds = const [],
    }) => const LeaderRideStatusCalculator().calculate(
      localRole: RideRole.lead,
      localRiderId: 'lead',
      localLocation: _location(
        id: 'lead',
        name: 'Lead',
        role: RideRole.lead,
        longitude: 0.015,
        speed: 10,
        at: now,
      ),
      riderLocations: riderLocations,
      routeAlerts: const [],
      route: const [
        GeoPoint(latitude: 0, longitude: 0),
        GeoPoint(latitude: 0, longitude: 0.02),
      ],
      registeredTecRiderIds: registeredTecRiderIds,
      now: now,
    );

    RiderLocation tecAt(DateTime recordedAt) => _location(
      id: 'tec',
      name: 'Charlie',
      role: RideRole.tailEndCharlie,
      longitude: 0.005,
      speed: 10,
      at: recordedAt,
    );

    test('no registered TEC reports nothing to show and nothing to aim at', () {
      final status = statusFor(
        riderLocations: [
          _location(
            id: 'alex',
            name: 'Alex',
            role: RideRole.rider,
            longitude: 0.01,
            speed: 10,
            at: now,
          ),
        ],
      );

      expect(status!.tecAvailability, TecAvailability.none);
      expect(status.hasRegisteredTec, isFalse);
      expect(status.tecRiderId, isNull);
      expect(status.tecName, isNull);
      expect(status.distanceToTecMeters, isNull);
      expect(status.estimatedTimeToTec, isNull);
      expect(status.tecLocationAge, isNull);
    });

    test('a registered TEC with no position yet is a waiting state', () {
      final status = statusFor(registeredTecRiderIds: const ['tec']);

      expect(status!.tecAvailability, TecAvailability.awaitingLocation);
      expect(status.hasRegisteredTec, isTrue);
      expect(status.tecRiderId, 'tec');
      // Nothing is known about where this TEC is, so no surface may date-stamp
      // or measure a position it has never received.
      expect(status.tecName, isNull);
      expect(status.tecLocationAge, isNull);
      expect(status.distanceToTecMeters, isNull);
      expect(status.estimatedTimeToTec, isNull);
    });

    test('a stale TEC position reports its age and withholds the gap', () {
      final status = statusFor(
        riderLocations: [tecAt(now.subtract(const Duration(minutes: 9)))],
        registeredTecRiderIds: const ['tec'],
      );

      expect(status!.tecAvailability, TecAvailability.stale);
      expect(status.tecRiderId, 'tec');
      expect(status.tecName, 'Charlie');
      expect(status.tecLocationAge, const Duration(minutes: 9));
      expect(status.distanceToTecMeters, isNull);
      expect(status.estimatedTimeToTec, isNull);
    });

    test('a fresh TEC position reports the measured gap', () {
      final status = statusFor(
        riderLocations: [tecAt(now)],
        registeredTecRiderIds: const ['tec'],
      );

      expect(status!.tecAvailability, TecAvailability.tracking);
      expect(status.tecRiderId, 'tec');
      expect(status.tecName, 'Charlie');
      expect(status.tecLocationAge, Duration.zero);
      expect(status.distanceToTecMeters, closeTo(1112, 10));
      expect(status.estimatedTimeToTec, isNotNull);
    });

    test('a TEC known only from a location snapshot still counts', () {
      final status = statusFor(riderLocations: [tecAt(now)]);

      expect(status!.tecAvailability, TecAvailability.tracking);
      expect(status.tecRiderId, 'tec');
    });

    test('assigning and then removing the role mid-ride flips the state', () {
      expect(statusFor()!.tecAvailability, TecAvailability.none);
      expect(
        statusFor(registeredTecRiderIds: const ['tec'])!.tecAvailability,
        TecAvailability.awaitingLocation,
      );
      expect(
        statusFor(
          riderLocations: [tecAt(now)],
          registeredTecRiderIds: const ['tec'],
        )!.tecAvailability,
        TecAvailability.tracking,
      );
      // The TEC leaves, or their role is reassigned: the surface must vanish
      // again without waiting for a restart.
      final afterRemoval = statusFor();
      expect(afterRemoval!.tecAvailability, TecAvailability.none);
      expect(afterRemoval.hasRegisteredTec, isFalse);
    });

    test('the leader is never their own TEC', () {
      final status = statusFor(registeredTecRiderIds: const ['lead']);

      expect(status!.tecAvailability, TecAvailability.none);
    });
  });

  test('a fresh TEC without a leader fix keeps the age but not the gap', () {
    final status = const LeaderRideStatusCalculator().calculate(
      localRole: RideRole.lead,
      localRiderId: 'lead',
      localLocation: null,
      riderLocations: [
        _location(
          id: 'tec',
          name: 'Charlie',
          role: RideRole.tailEndCharlie,
          longitude: 0.005,
          speed: 10,
          at: now,
        ),
      ],
      routeAlerts: const [],
      route: const [],
      registeredTecRiderIds: const ['tec'],
      now: now,
    );

    expect(status!.tecAvailability, TecAvailability.tracking);
    expect(status.tecName, 'Charlie');
    expect(status.tecLocationAge, Duration.zero);
    expect(status.distanceToTecMeters, isNull);
  });

  test('closed loop uses the short gap across its start and finish', () {
    final status = const LeaderRideStatusCalculator().calculate(
      localRole: RideRole.lead,
      localRiderId: 'lead',
      localLocation: _location(
        id: 'lead',
        name: 'Lead',
        role: RideRole.lead,
        longitude: 0,
        speed: 10,
        at: now,
      ),
      riderLocations: [
        RiderLocation(
          riderId: 'tec',
          displayName: 'Charlie',
          role: RideRole.tailEndCharlie,
          sample: LocationSample(
            position: const GeoPoint(latitude: 0.005, longitude: 0),
            recordedAt: now,
            accuracyMeters: 5,
            speedMetersPerSecond: 10,
          ),
          receivedAt: now,
        ),
      ],
      routeAlerts: const [],
      route: const [
        GeoPoint(latitude: 0, longitude: 0),
        GeoPoint(latitude: 0, longitude: 0.02),
        GeoPoint(latitude: 0.02, longitude: 0.02),
        GeoPoint(latitude: 0.02, longitude: 0),
        GeoPoint(latitude: 0, longitude: 0),
      ],
      now: now,
    );

    expect(status!.distanceToTecMeters, closeTo(556, 15));
  });

  test('leader receives simple unacknowledged off-course alerts', () {
    final status = const LeaderRideStatusCalculator().calculate(
      localRole: RideRole.lead,
      localRiderId: 'lead',
      localLocation: null,
      riderLocations: [
        _location(
          id: 'rider',
          name: 'Alex',
          role: RideRole.rider,
          longitude: 0.01,
          speed: 10,
          at: now,
        ),
      ],
      routeAlerts: [
        RiderRouteAlert(
          riderId: 'rider',
          displayName: 'Alex',
          assessment: RouteDeviationAssessment(
            state: RouteTrackingState.offRoute,
            alertLevel: RouteAlertLevel.urgent,
            audience: RouteAlertAudience.coordinators,
            evaluatedAt: now,
            message: 'Off route',
            distanceFromRouteMeters: 240,
          ),
        ),
      ],
      route: const [],
      now: now,
    );

    expect(status!.offCourseAlerts.single.displayName, 'Alex');
    expect(status.offCourseAlerts.single.distanceFromRouteMeters, 240);
  });

  test(
    'off-course total excludes stale states and riders outside the roster',
    () {
      RiderRouteAlert alert({
        required String riderId,
        required String name,
        required RouteTrackingState state,
        DateTime? evaluatedAt,
      }) => RiderRouteAlert(
        riderId: riderId,
        displayName: name,
        assessment: RouteDeviationAssessment(
          state: state,
          alertLevel: RouteAlertLevel.urgent,
          audience: RouteAlertAudience.coordinators,
          evaluatedAt: evaluatedAt ?? now,
          message: 'Coordinator alert',
          distanceFromRouteMeters: state == RouteTrackingState.offRoute
              ? 240
              : null,
        ),
      );

      final status = const LeaderRideStatusCalculator().calculate(
        localRole: RideRole.lead,
        localRiderId: 'lead',
        localLocation: null,
        riderLocations: [
          _location(
            id: 'current-off-route',
            name: 'Alex',
            role: RideRole.rider,
            longitude: 0.01,
            speed: 10,
            at: now,
          ),
          _location(
            id: 'current-stale',
            name: 'Sam',
            role: RideRole.rider,
            longitude: 0.012,
            speed: 0,
            at: now.subtract(const Duration(minutes: 3)),
          ),
        ],
        routeAlerts: [
          alert(
            riderId: 'current-off-route',
            name: 'Alex',
            state: RouteTrackingState.offRoute,
          ),
          alert(
            riderId: 'current-off-route',
            name: 'Alex duplicate',
            state: RouteTrackingState.offRoute,
            evaluatedAt: now.subtract(const Duration(seconds: 1)),
          ),
          alert(
            riderId: 'current-stale',
            name: 'Sam',
            state: RouteTrackingState.gpsStale,
          ),
          for (var index = 0; index < 5; index += 1)
            alert(
              riderId: 'ghost-$index',
              name: 'Ghost $index',
              state: RouteTrackingState.offRoute,
            ),
        ],
        route: const [],
        now: now,
      );

      expect(status!.offCourseAlerts, hasLength(1));
      expect(status.offCourseAlerts.single.riderId, 'current-off-route');
      expect(status.offCourseAlerts.single.displayName, 'Alex');
    },
  );

  test('a rider on the leader\'s own track is not counted as off course', () {
    RiderRouteAlert offCourse(String riderId, String name) => RiderRouteAlert(
      riderId: riderId,
      displayName: name,
      assessment: RouteDeviationAssessment(
        state: RouteTrackingState.offRoute,
        alertLevel: RouteAlertLevel.urgent,
        audience: RouteAlertAudience.coordinators,
        evaluatedAt: now,
        message: 'Off route',
        distanceFromRouteMeters: 2400,
      ),
    );

    // Both riders are far from the planned GPX and both have an off-route alert
    // raised by another device. Only the one who is not on the leader's actual
    // track should reach the leader's count.
    final status = const LeaderRideStatusCalculator().calculate(
      localRole: RideRole.lead,
      localRiderId: 'lead',
      localLocation: null,
      riderLocations: [
        _location(
          id: 'follower',
          name: 'Alex',
          role: RideRole.rider,
          longitude: 0.01,
          speed: 10,
          at: now,
        ),
        RiderLocation(
          riderId: 'stray',
          displayName: 'Sam',
          role: RideRole.rider,
          sample: LocationSample(
            position: const GeoPoint(latitude: 0.05, longitude: 0.01),
            recordedAt: now,
            accuracyMeters: 5,
          ),
          receivedAt: now,
        ),
      ],
      routeAlerts: [offCourse('follower', 'Alex'), offCourse('stray', 'Sam')],
      route: const [
        GeoPoint(latitude: 0.02, longitude: 0),
        GeoPoint(latitude: 0.02, longitude: 0.02),
      ],
      // The leader abandoned the GPX and rode along latitude 0, where the
      // follower now is.
      leaderTrail: const [
        GeoPoint(latitude: 0, longitude: 0),
        GeoPoint(latitude: 0, longitude: 0.02),
      ],
      now: now,
    );

    expect(status!.offCourseAlerts, hasLength(1));
    expect(status.offCourseAlerts.single.riderId, 'stray');
  });

  test('non-leaders do not receive leader map status', () {
    final status = const LeaderRideStatusCalculator().calculate(
      localRole: RideRole.rider,
      localRiderId: 'rider',
      localLocation: null,
      riderLocations: const [],
      routeAlerts: const [],
      route: const [],
      now: now,
    );

    expect(status, isNull);
  });

  group('resolveTecTarget', () {
    const calculator = LeaderRideStatusCalculator();

    TecTarget resolve({
      List<RiderLocation> riderLocations = const [],
      Iterable<String> registered = const [],
      DateTime? at,
    }) => calculator.resolveTecTarget(
      localRiderId: 'lead',
      riderLocations: riderLocations,
      registeredTecRiderIds: registered,
      now: at ?? now,
    );

    test('no back-marker at all reports none and offers no target', () {
      final target = resolve();

      expect(target.availability, TecAvailability.none);
      expect(target.hasRegisteredTec, isFalse);
      expect(target.navigableLocation, isNull);
    });

    test('a registered TEC with no position yet is not navigable', () {
      final target = resolve(registered: const ['tec']);

      expect(target.availability, TecAvailability.awaitingLocation);
      expect(target.hasRegisteredTec, isTrue);
      expect(target.riderId, 'tec');
      expect(target.navigableLocation, isNull);
    });

    test('a stale fix is kept but withheld from navigation', () {
      final target = resolve(
        riderLocations: [
          _location(
            id: 'tec',
            name: 'Charlie',
            role: RideRole.tailEndCharlie,
            longitude: 0.005,
            speed: 10,
            at: now.subtract(const Duration(minutes: 5)),
          ),
        ],
      );

      expect(target.availability, TecAvailability.stale);
      expect(target.location, isNotNull);
      expect(target.navigableLocation, isNull);
    });

    test('a fresh fix is navigable', () {
      final target = resolve(
        riderLocations: [
          _location(
            id: 'tec',
            name: 'Charlie',
            role: RideRole.tailEndCharlie,
            longitude: 0.005,
            speed: 10,
            at: now,
          ),
        ],
      );

      expect(target.availability, TecAvailability.tracking);
      expect(target.navigableLocation?.riderId, 'tec');
    });

    test('a rider is never their own back-marker', () {
      final target = calculator.resolveTecTarget(
        localRiderId: 'tec',
        riderLocations: [
          _location(
            id: 'tec',
            name: 'Charlie',
            role: RideRole.tailEndCharlie,
            longitude: 0.005,
            speed: 10,
            at: now,
          ),
        ],
        registeredTecRiderIds: const ['tec'],
        now: now,
      );

      expect(target.availability, TecAvailability.none);
    });

    test('agrees with the availability the leader card reports', () {
      // One model, two consumers: the leader's TEC card and rejoin routing must
      // never disagree about whether there is a usable back-marker.
      for (final scenario in [
        (<RiderLocation>[], const <String>[]),
        (<RiderLocation>[], const ['tec']),
        (
          [
            _location(
              id: 'tec',
              name: 'Charlie',
              role: RideRole.tailEndCharlie,
              longitude: 0.005,
              speed: 10,
              at: now.subtract(const Duration(minutes: 5)),
            ),
          ],
          const <String>[],
        ),
        (
          [
            _location(
              id: 'tec',
              name: 'Charlie',
              role: RideRole.tailEndCharlie,
              longitude: 0.005,
              speed: 10,
              at: now,
            ),
          ],
          const <String>[],
        ),
      ]) {
        final status = calculator.calculate(
          localRole: RideRole.lead,
          localRiderId: 'lead',
          localLocation: _location(
            id: 'lead',
            name: 'Lead',
            role: RideRole.lead,
            longitude: 0,
            speed: 10,
            at: now,
          ),
          riderLocations: scenario.$1,
          routeAlerts: const [],
          route: const [],
          registeredTecRiderIds: scenario.$2,
          now: now,
        );
        final target = resolve(
          riderLocations: scenario.$1,
          registered: scenario.$2,
        );

        expect(status!.tecAvailability, target.availability);
        expect(status.hasRegisteredTec, target.hasRegisteredTec);
      }
    });
  });
}

RiderLocation _location({
  required String id,
  required String name,
  required RideRole role,
  required double longitude,
  required double speed,
  required DateTime at,
}) => RiderLocation(
  riderId: id,
  displayName: name,
  role: role,
  sample: LocationSample(
    position: GeoPoint(latitude: 0, longitude: longitude),
    recordedAt: at,
    accuracyMeters: 5,
    speedMetersPerSecond: speed,
  ),
  receivedAt: at,
);
