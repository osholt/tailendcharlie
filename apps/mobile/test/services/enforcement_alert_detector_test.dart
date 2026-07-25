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

  test('warns about a camera a mile ahead and ignores one further out', () {
    const detector = EnforcementAlertDetector();

    final within = detector.detect(
      position: rider,
      headingDegrees: 0,
      hazards: [
        hazard(
          id: 'camera',
          type: HazardType.speedCamera,
          position: north(1400),
        ),
      ],
      now: now,
    );
    final beyond = detector.detect(
      position: rider,
      headingDegrees: 0,
      hazards: [
        hazard(
          id: 'camera',
          type: HazardType.speedCamera,
          position: north(2400),
        ),
      ],
      now: now,
    );

    expect(within, isNotNull);
    expect(within!.hazard.id, 'camera');
    expect(within.distanceMeters, closeTo(1400, 5));
    expect(beyond, isNull);
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
          position: north(800),
        ),
      ],
      now: now,
    );

    expect(alert!.hazard.id, 'camera');
  });
}
