import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/geo_point.dart';
import 'package:ride_relay/domain/hazard.dart';
import 'package:ride_relay/services/enforcement_alert_detector.dart';

void main() {
  final now = DateTime.utc(2026, 7, 25, 12);

  HazardReport hazard({
    required String id,
    required HazardType type,
    required GeoPoint position,
    DateTime? expiresAt,
    int confirmations = 1,
  }) => HazardReport(
    id: id,
    rideId: 'ride-1',
    type: type,
    severity: HazardSeverity.serious,
    position: position,
    reportedAt: now.subtract(const Duration(minutes: 2)),
    updatedAt: now.subtract(const Duration(minutes: 2)),
    expiresAt: expiresAt ?? now.add(const Duration(minutes: 20)),
    reporterId: 'relay-traffic',
    reporterName: 'Live UK traffic',
    source: HazardSource.externalProvider,
    providerId: 'relay-traffic',
    confirmations: confirmations,
  );

  // Roughly 0.001 degrees of latitude is 111 m, so these fixtures put hazards
  // at predictable distances north of the rider.
  const rider = GeoPoint(latitude: 51.5, longitude: -3.18);
  GeoPoint north(double metres) =>
      GeoPoint(latitude: 51.5 + metres / 111320, longitude: -3.18);

  test('targets thirty seconds of warning at urban speed', () {
    const detector = EnforcementAlertDetector();

    final within = detector.detect(
      position: rider,
      headingDegrees: 0,
      speedMetersPerSecond: 13.4112, // 30 mph: about 402 m in 30 seconds.
      hazards: [
        hazard(
          id: 'camera',
          type: HazardType.speedCamera,
          position: north(390),
        ),
      ],
      now: now,
    );
    final beyond = detector.detect(
      position: rider,
      headingDegrees: 0,
      speedMetersPerSecond: 13.4112,
      hazards: [
        hazard(
          id: 'camera',
          type: HazardType.speedCamera,
          position: north(450),
        ),
      ],
      now: now,
    );

    expect(within, isNotNull);
    expect(within!.hazard.id, 'camera');
    expect(within.distanceMeters, closeTo(390, 5));
    expect(beyond, isNull);
  });

  test('extends the same thirty-second warning at motorway speed', () {
    const detector = EnforcementAlertDetector();

    final within = detector.detect(
      position: rider,
      headingDegrees: 0,
      speedMetersPerSecond: 31.2928, // 70 mph: about 939 m in 30 seconds.
      hazards: [
        hazard(
          id: 'camera',
          type: HazardType.speedCamera,
          position: north(900),
        ),
      ],
      now: now,
    );
    final beyond = detector.detect(
      position: rider,
      headingDegrees: 0,
      speedMetersPerSecond: 31.2928,
      hazards: [
        hazard(
          id: 'camera',
          type: HazardType.speedCamera,
          position: north(980),
        ),
      ],
      now: now,
    );

    expect(within, isNotNull);
    expect(beyond, isNull);
  });

  test('an armed warning stays stable when the rider slows', () {
    const detector = EnforcementAlertDetector();
    final camera = hazard(
      id: 'camera',
      type: HazardType.speedCamera,
      position: north(700),
    );

    final alert = detector.detect(
      position: rider,
      headingDegrees: 0,
      speedMetersPerSecond: 2,
      activeHazardId: camera.id,
      hazards: [camera],
      now: now,
    );

    expect(alert?.hazard.id, camera.id);
    expect(alert!.distanceMeters, closeTo(700, 5));
  });

  test('a hazard already passed stops alerting', () {
    const detector = EnforcementAlertDetector();

    final alert = detector.detect(
      position: rider,
      headingDegrees: 0,
      hazards: [
        hazard(
          id: 'behind',
          type: HazardType.policeActivity,
          position: north(-400),
        ),
      ],
      now: now,
    );

    expect(alert, isNull);
  });

  test(
    'route position decides ahead or behind, not straight-line distance',
    () {
      const detector = EnforcementAlertDetector();
      final route = [
        const GeoPoint(latitude: 51.5, longitude: -3.18),
        north(600),
        north(1200),
      ];
      // Sitting at the second route point, a camera at the first is behind even
      // though it is well inside the warning radius.
      final alert = detector.detect(
        position: north(600),
        speedMetersPerSecond: 20,
        hazards: [
          hazard(id: 'behind', type: HazardType.speedCamera, position: rider),
          hazard(
            id: 'ahead',
            type: HazardType.speedCamera,
            position: north(1100),
          ),
        ],
        route: route,
        now: now,
      );

      expect(alert!.hazard.id, 'ahead');
      expect(alert.distanceMeters, closeTo(500, 20));
    },
  );

  test('a camera off the route corridor and behind is not announced', () {
    const detector = EnforcementAlertDetector();
    final route = [
      const GeoPoint(latitude: 51.5, longitude: -3.18),
      north(900),
    ];

    final alert = detector.detect(
      position: rider,
      headingDegrees: 0,
      hazards: [
        hazard(
          id: 'parallel-road',
          type: HazardType.speedCamera,
          // 1 km east and slightly south: outside the corridor, and behind the
          // northbound rider once the heading test applies.
          position: const GeoPoint(latitude: 51.4985, longitude: -3.166),
        ),
      ],
      route: route,
      now: now,
    );

    expect(alert, isNull);
  });

  test('non-enforcement and expired hazards never raise the alert', () {
    const detector = EnforcementAlertDetector();

    final alert = detector.detect(
      position: rider,
      headingDegrees: 0,
      hazards: [
        hazard(
          id: 'roadworks',
          type: HazardType.roadworks,
          position: north(500),
        ),
        hazard(
          id: 'stale-camera',
          type: HazardType.speedCamera,
          position: north(500),
          expiresAt: now.subtract(const Duration(minutes: 1)),
        ),
      ],
      now: now,
    );

    expect(alert, isNull);
  });

  test('a low-confidence report still warns, and the nearest one wins', () {
    const detector = EnforcementAlertDetector();

    final alert = detector.detect(
      position: rider,
      headingDegrees: 0,
      hazards: [
        hazard(
          id: 'far',
          type: HazardType.speedCamera,
          position: north(1200),
          confirmations: 9,
        ),
        hazard(
          id: 'near-unconfirmed',
          type: HazardType.policeActivity,
          position: north(300),
          confirmations: 1,
        ),
      ],
      now: now,
    );

    expect(alert!.hazard.id, 'near-unconfirmed');
  });

  test('a fix without a heading still warns rather than staying silent', () {
    const detector = EnforcementAlertDetector();

    final alert = detector.detect(
      position: rider,
      hazards: [
        hazard(
          id: 'camera',
          type: HazardType.speedCamera,
          position: north(350),
        ),
      ],
      now: now,
    );

    expect(alert!.hazard.id, 'camera');
  });

  // #849: the rider's alert joined the two kinds the detector already knew, and
  // the migration must have moved the behaviour #112, #135 and #471 built rather
  // than copied it. So the three are held to the same rules, one test each, and a
  // rule one of them stopped meeting would fail here by name.
  group('the alert and the two older kinds warn identically (#849)', () {
    const kinds = [
      HazardType.alert,
      HazardType.speedCamera,
      HazardType.policeActivity,
    ];

    HazardReport riderHazard(
      HazardType type, {
      required GeoPoint position,
      DateTime? expiresAt,
      String id = 'sighting',
    }) => HazardReport(
      id: id,
      rideId: 'ride-1',
      type: type,
      severity: HazardSeverity.serious,
      position: position,
      reportedAt: now.subtract(const Duration(minutes: 2)),
      updatedAt: now.subtract(const Duration(minutes: 2)),
      expiresAt: expiresAt ?? now.add(const Duration(minutes: 20)),
      reporterId: 'becks',
      reporterName: 'Becks',
      source: HazardSource.rider,
    );

    test('all three are the kinds the detector warns about', () {
      expect(enforcementHazardTypes, containsAll(kinds));
      // And nothing else is: a pothole is a road defect, not a warning.
      expect(enforcementHazardTypes, hasLength(kinds.length));
    });

    test('arm about thirty seconds out at urban speed', () {
      const detector = EnforcementAlertDetector();
      for (final type in kinds) {
        final within = detector.detect(
          position: rider,
          headingDegrees: 0,
          speedMetersPerSecond: 13.4112,
          hazards: [riderHazard(type, position: north(390))],
          now: now,
        );
        final beyond = detector.detect(
          position: rider,
          headingDegrees: 0,
          speedMetersPerSecond: 13.4112,
          hazards: [riderHazard(type, position: north(450))],
          now: now,
        );

        expect(within?.hazard.type, type, reason: type.name);
        expect(beyond, isNull, reason: type.name);
      }
    });

    test('arm further out at motorway speed', () {
      const detector = EnforcementAlertDetector();
      for (final type in kinds) {
        expect(
          detector.detect(
            position: rider,
            headingDegrees: 0,
            speedMetersPerSecond: 31.2928,
            hazards: [riderHazard(type, position: north(900))],
            now: now,
          ),
          isNotNull,
          reason: type.name,
        );
      }
    });

    test('stay armed when the rider slows', () {
      const detector = EnforcementAlertDetector();
      for (final type in kinds) {
        final sighting = riderHazard(type, position: north(700));
        expect(
          detector.detect(
            position: rider,
            headingDegrees: 0,
            speedMetersPerSecond: 2,
            activeHazardId: sighting.id,
            hazards: [sighting],
            now: now,
          ),
          isNotNull,
          reason: type.name,
        );
      }
    });

    test('stop warning once passed, and never warn about one behind', () {
      const detector = EnforcementAlertDetector();
      for (final type in kinds) {
        expect(
          detector.detect(
            position: rider,
            headingDegrees: 0,
            speedMetersPerSecond: 13.4,
            hazards: [riderHazard(type, position: north(-200))],
            now: now,
          ),
          isNull,
          reason: type.name,
        );
      }
    });

    test('stop warning at their documented expiry', () {
      const detector = EnforcementAlertDetector();
      for (final type in kinds) {
        expect(
          detector.detect(
            position: rider,
            headingDegrees: 0,
            hazards: [
              riderHazard(
                type,
                position: north(300),
                expiresAt: now.subtract(const Duration(seconds: 1)),
              ),
            ],
            now: now,
          ),
          isNull,
          reason: type.name,
        );
      }
    });

    test('an alert off the route corridor is still warned about', () {
      // A rider who has diverted is still the rider the alert is for. 0.004
      // degrees of longitude here is about 280 m, beyond the 250 m corridor, so
      // this falls through to the heading test; the alert is still inside the
      // thirty-second distance, about 340 m away on a bearing 54 degrees off the
      // rider's heading.
      const detector = EnforcementAlertDetector();
      final offRoute = GeoPoint(
        latitude: 51.5 + 200 / 111320,
        longitude: -3.176,
      );
      final alert = detector.detect(
        position: rider,
        headingDegrees: 0,
        speedMetersPerSecond: 13.4,
        route: [north(-500), north(500)],
        hazards: [riderHazard(HazardType.alert, position: offRoute)],
        now: now,
      );

      expect(alert, isNotNull);
      expect(alert!.hazard.type, HazardType.alert);
    });

    test('a road defect is not a warning', () {
      const detector = EnforcementAlertDetector();
      expect(
        detector.detect(
          position: rider,
          headingDegrees: 0,
          hazards: [riderHazard(HazardType.pothole, position: north(100))],
          now: now,
        ),
        isNull,
      );
    });
  });
}
