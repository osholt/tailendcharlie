import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/geo_point.dart';
import 'package:ride_relay/domain/hazard.dart';
import 'package:ride_relay/services/hazard_map_relevance.dart';

void main() {
  final now = DateTime.utc(2026, 7, 27, 12);
  const relevance = HazardMapRelevance();

  HazardReport report({
    required GeoPoint position,
    String id = 'camera',
    HazardType type = HazardType.speedCamera,
    DateTime? expiresAt,
  }) => HazardReport(
    id: id,
    rideId: 'ride-1',
    type: type,
    severity: HazardSeverity.serious,
    position: position,
    reportedAt: now.subtract(const Duration(minutes: 4)),
    updatedAt: now.subtract(const Duration(minutes: 4)),
    expiresAt: expiresAt ?? now.add(const Duration(hours: 1)),
    reporterId: 'rider-1',
    reporterName: 'Alex',
    source: HazardSource.rider,
  );

  // 0.001 degrees of latitude is 111 m; a degree of longitude at 51.5 N is
  // 69,297 m, so these put reports at predictable offsets from the rider.
  const riderLatitude = 51.5;
  const riderLongitude = -3.18;
  const rider = GeoPoint(latitude: riderLatitude, longitude: riderLongitude);
  GeoPoint at({double north = 0, double east = 0}) => GeoPoint(
    latitude: riderLatitude + north / 111320,
    longitude: riderLongitude + east / 69297,
  );

  HazardMapVisibility visibilityOf(
    HazardReport hazard, {
    double? headingDegrees,
    List<GeoPoint> route = const [],
    GeoPoint? position,
  }) => relevance
      .judge(
        report: hazard,
        riderPosition: position ?? rider,
        now: now,
        headingDegrees: headingDegrees,
        route: route,
      )
      .visibility;

  group('without a route', () {
    test('a camera in front of the rider is drawn, with its distance', () {
      final judgement = relevance.judge(
        report: report(position: at(north: 900)),
        riderPosition: rider,
        now: now,
        headingDegrees: 0,
      );

      expect(judgement.visibility, HazardMapVisibility.visible);
      expect(judgement.distanceAheadMeters, closeTo(900, 5));
    });

    test('one already ridden past is behind, not ahead', () {
      expect(
        visibilityOf(report(position: at(north: -400)), headingDegrees: 0),
        HazardMapVisibility.behind,
      );
    });

    test('one abeam on another carriageway is not drawn as ahead', () {
      // Due east of a northbound rider: 90 degrees off the direction of travel,
      // so it is beside the rider rather than in front.
      expect(
        visibilityOf(report(position: at(east: 300)), headingDegrees: 0),
        HazardMapVisibility.oppositeCarriageway,
      );
    });

    test('a fix with no heading still draws, rather than staying silent', () {
      // #112 settled this: no direction evidence must never lose a real sighting.
      expect(
        visibilityOf(report(position: at(north: -400))),
        HazardMapVisibility.visible,
      );
    });

    test('one beyond the visible range is held back', () {
      expect(
        visibilityOf(report(position: at(north: 6000)), headingDegrees: 0),
        HazardMapVisibility.beyondRange,
      );
    });

    test('the range reaches well past the distance #112 warns at', () {
      // The symbol has to be on the map before the full-screen warning fires.
      expect(relevance.visibilityRangeMeters, greaterThan(1609.344 * 2));
    });
  });

  group('with a route loaded', () {
    final straightRoute = [rider, at(north: 1000), at(north: 2000)];

    test('the route decides ahead, not straight-line distance', () {
      final judgement = relevance.judge(
        report: report(position: at(north: 1600)),
        riderPosition: at(north: 600),
        now: now,
        headingDegrees: 0,
        route: straightRoute,
      );

      expect(judgement.visibility, HazardMapVisibility.visible);
      expect(judgement.distanceAheadMeters, closeTo(1000, 20));
    });

    test('one behind along the route is behind', () {
      expect(
        visibilityOf(
          report(position: at(north: 200)),
          position: at(north: 900),
          headingDegrees: 0,
          route: straightRoute,
        ),
        HazardMapVisibility.behind,
      );
    });

    test('one off the corridor falls back to the heading test', () {
      // Off the route entirely, and well behind a northbound rider. A diverted
      // rider must still get one that is ahead, which is why this falls through
      // to the heading test rather than being dropped outright.
      expect(
        visibilityOf(
          report(position: at(north: -1000, east: 300)),
          headingDegrees: 0,
          route: straightRoute,
        ),
        HazardMapVisibility.behind,
      );
      expect(
        visibilityOf(
          report(position: at(north: 900, east: 1000)),
          headingDegrees: 0,
          route: straightRoute,
        ),
        HazardMapVisibility.visible,
      );
    });

    test('a report round a bend is still ahead', () {
      // A hairpin: the route runs north, turns back on itself, and the report
      // sits on the returning leg 300 m along. The leg runs against the rider,
      // but the report is plainly in front of them, so it must still be drawn -
      // otherwise a twisty road hides real sightings.
      final hairpin = [
        rider,
        at(north: 300),
        at(north: 300, east: 60),
        at(north: -100, east: 60),
      ];

      expect(
        visibilityOf(
          report(position: at(north: 250, east: 60)),
          headingDegrees: 0,
          route: hairpin,
        ),
        HazardMapVisibility.visible,
      );
    });
  });

  group('an out-and-back down the same road', () {
    // Out 2 km and back down the same geometry: every point on it is reached
    // twice, once northbound and once southbound.
    final outAndBack = [
      rider,
      at(north: 1000),
      at(north: 2000),
      at(north: 1000),
      rider,
    ];

    test('outbound, a report the rider has passed is not drawn as ahead', () {
      // The route reaches it again on the way home, so it is genuinely ahead
      // along the route - but it is behind the rider now, and drawing it as
      // though it were ahead is the thing #135 forbids.
      final judgement = relevance.judge(
        report: report(position: at(north: 1400)),
        riderPosition: at(north: 1600),
        now: now,
        headingDegrees: 0,
        route: outAndBack,
      );

      expect(judgement.isVisible, isFalse);
      expect(judgement.visibility, HazardMapVisibility.oppositeCarriageway);
    });

    test('homeward, the same report is drawn at its return-leg distance', () {
      // The bug this closes: the nearest projection onto the route lands on the
      // outbound leg, which puts a camera 200 m in front of the rider 1.2 km
      // behind them, and the map hides it.
      final judgement = relevance.judge(
        report: report(position: at(north: 1400)),
        riderPosition: at(north: 1600),
        now: now,
        headingDegrees: 180,
        route: outAndBack,
      );

      expect(judgement.visibility, HazardMapVisibility.visible);
      expect(judgement.distanceAheadMeters, closeTo(200, 30));
    });

    test('the heading is what places the rider on the right leg', () {
      final outbound = relevance.locateRider(
        riderPosition: at(north: 1600),
        route: outAndBack,
        headingDegrees: 0,
      );
      final homeward = relevance.locateRider(
        riderPosition: at(north: 1600),
        route: outAndBack,
        headingDegrees: 180,
      );

      expect(outbound!.distanceAlongRouteMeters, closeTo(1600, 30));
      expect(outbound.bearingDegrees, closeTo(0, 1));
      expect(homeward!.distanceAlongRouteMeters, closeTo(2400, 30));
      expect(homeward.bearingDegrees, closeTo(180, 1));
    });
  });

  group('freshness and expiry', () {
    test('a report past its expiry is not drawn at all', () {
      expect(
        visibilityOf(
          report(
            position: at(north: 500),
            expiresAt: now.subtract(const Duration(seconds: 1)),
          ),
          headingDegrees: 0,
        ),
        HazardMapVisibility.expired,
      );
    });

    test('a report expiring in a second is still drawn', () {
      expect(
        visibilityOf(
          report(
            position: at(north: 500),
            expiresAt: now.add(const Duration(seconds: 1)),
          ),
          headingDegrees: 0,
        ),
        HazardMapVisibility.visible,
      );
    });

    test('expiry is checked before anything else', () {
      // An expired report behind the rider reads as expired rather than behind,
      // so the reason a symbol vanished is never ambiguous.
      expect(
        visibilityOf(
          report(
            position: at(north: -900),
            expiresAt: now.subtract(const Duration(minutes: 5)),
          ),
          headingDegrees: 0,
        ),
        HazardMapVisibility.expired,
      );
    });
  });

  test('every report is judged, in the order it was given', () {
    final judgements = relevance.judgeAll(
      reports: [
        report(id: 'ahead', position: at(north: 800)),
        report(id: 'behind', position: at(north: -800)),
        report(
          id: 'gone',
          position: at(north: 400),
          expiresAt: now.subtract(const Duration(minutes: 1)),
        ),
      ],
      riderPosition: rider,
      now: now,
      headingDegrees: 0,
    );

    expect(judgements.map((judgement) => judgement.report.id), [
      'ahead',
      'behind',
      'gone',
    ]);
    expect(judgements.map((judgement) => judgement.visibility), [
      HazardMapVisibility.visible,
      HazardMapVisibility.behind,
      HazardMapVisibility.expired,
    ]);
  });

  test('a road defect is judged the same way as enforcement', () {
    // The map draws every kind of report, so the relevance rule cannot be an
    // enforcement-only special case.
    expect(
      visibilityOf(
        report(position: at(north: -600), type: HazardType.pothole),
        headingDegrees: 0,
      ),
      HazardMapVisibility.behind,
    );
    expect(
      visibilityOf(
        report(position: at(north: 600), type: HazardType.pothole),
        headingDegrees: 0,
      ),
      HazardMapVisibility.visible,
    );
  });

  test('no rider position draws everything active', () {
    // A static map has no direction to judge against.
    expect(
      relevance
          .judge(
            report: report(position: at(north: -9000)),
            riderPosition: null,
            now: now,
          )
          .visibility,
      HazardMapVisibility.visible,
    );
  });
}
