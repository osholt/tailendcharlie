import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/services/route_origin_bearing.dart';

void main() {
  group('the reroute is told which way the rider is pointing (#444)', () {
    test('a moving rider contributes their heading', () {
      expect(
        rejoinOriginBearing(headingDegrees: 270, speedMetersPerSecond: 20),
        270,
      );
    });

    test('a stationary rider contributes nothing', () {
      // "A heading from a stationary or nearly-stationary rider is noise. Using
      // it would produce a confidently wrong first instruction, which is the
      // defect this is about."
      for (final speed in [0.0, 0.5, 2.9]) {
        expect(
          rejoinOriginBearing(headingDegrees: 270, speedMetersPerSecond: speed),
          isNull,
          reason: '$speed m/s',
        );
      }
    });

    test('the floor is the one used everywhere else', () {
      // Shared with the stopped-speed readout (#445) and the CarPlay estimate
      // (#452). Two numbers for one idea is how they drift apart.
      expect(rejoinBearingMinimumSpeedMetersPerSecond, 3.0);
    });

    test('a missing or nonsense heading contributes nothing', () {
      expect(
        rejoinOriginBearing(headingDegrees: null, speedMetersPerSecond: 20),
        isNull,
      );
      for (final heading in [-1.0, 360.0, 400.0, double.nan]) {
        expect(
          rejoinOriginBearing(
            headingDegrees: heading,
            speedMetersPerSecond: 20,
          ),
          isNull,
          reason: '$heading',
        );
      }
    });
  });

  group('the OSRM parameter is shaped the way OSRM demands', () {
    test('one entry per coordinate, only the first constrained', () {
      // OSRM rejects a bearings list whose length does not match the
      // coordinates, so the empty entries are not cosmetic.
      expect(
        osrmBearings(originBearingDegrees: 90, waypointCount: 3),
        '90,60;;',
      );
      expect(
        osrmBearings(originBearingDegrees: 90, waypointCount: 2),
        '90,60;',
      );
    });

    test('no bearing means no parameter at all', () {
      // Rather than a list of empties, which would be a request that says
      // nothing in more bytes.
      expect(
        osrmBearings(originBearingDegrees: null, waypointCount: 3),
        isNull,
      );
    });

    test('the tolerance excludes the opposite carriageway', () {
      // Wide enough for GPS heading error and a leaning bike; narrow enough that
      // a road running back the way the rider came cannot be chosen, which is
      // the whole point.
      expect(rejoinBearingToleranceDegrees, lessThan(90));
      expect(rejoinBearingToleranceDegrees, greaterThanOrEqualTo(45));
    });

    test('the bearing is rounded, not printed as a float', () {
      expect(
        osrmBearings(originBearingDegrees: 89.6, waypointCount: 2),
        '90,60;',
      );
    });
  });

  group('the request and the planner actually use it', () {
    test('OSRM sends a bearings parameter', () {
      final source = File('lib/services/road_routing.dart').readAsStringSync();

      expect(source, contains("'bearings':"));
      expect(source, contains('originBearingDegrees: originBearingDegrees'));
    });

    test('the rejoin planner supplies the rider heading and speed', () {
      // The parameter can exist and be threaded correctly while nothing ever
      // passes a heading — which would leave the defect exactly as it was.
      final source = File(
        'lib/services/route_rejoin_planner.dart',
      ).readAsStringSync();

      expect(source, contains('final originBearing = rejoinOriginBearing('));
      expect(source, contains('originBearingDegrees: originBearing'));
      expect(source, contains('headingDegrees: sample.headingDegrees'));
      expect(
        source,
        contains('speedMetersPerSecond: sample.speedMetersPerSecond'),
      );
    });
  });
}
