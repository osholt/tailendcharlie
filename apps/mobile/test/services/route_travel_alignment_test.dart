import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/services/navigation_guidance.dart';
import 'package:ride_relay/services/route_travel_alignment.dart';

/// #941, from the 10 October ride. The geometry is the junction's own shape,
/// re-centred on a neutral origin: the planned line came into a roundabout
/// heading 178.5° and left it at 167°; the rider arrived on another arm, 43 m
/// east of the planned line, heading 268.7° at 17.9 m/s. Guidance resumed with
/// "take the exit straight on", which from that arm is the first exit, a left;
/// the rider went straight ahead of themselves and was off route for 8 minutes.
void main() {
  // Metres east and north of the ring entry, near the equator so a degree is
  // the same length both ways.
  GeoPoint point(double east, double north) =>
      GeoPoint(latitude: north / 111195, longitude: east / 111195);

  GeoPoint along(GeoPoint from, double bearing, double meters) => point(
    from.longitude * 111195 + meters * math.sin(bearing * math.pi / 180),
    from.latitude * 111195 + meters * math.cos(bearing * math.pi / 180),
  );

  final entry = point(0, 0);
  // The planned approach: 400 m in, heading 178.5°.
  final approachStart = along(entry, 178.5 + 180, 400);
  // A 20 m ring, clockwise as on the left-hand side of the road.
  final ring = [
    entry,
    point(14.1, -5.9),
    point(20, -20),
    point(14.1, -34.1),
    point(0, -40),
  ];
  final exitEnd = along(ring.last, 167, 600);
  final path = [
    approachStart,
    along(entry, 178.5 + 180, 200),
    ...ring,
    along(ring.last, 167, 300),
    exitEnd,
  ];

  // Where the rider was when guidance came back: 54 m north and 43 m east of
  // the ring entry, on the arm that meets the ring from the east.
  final crossingRider = point(43, 54);
  const crossingHeading = 268.7;
  const crossingSpeed = 17.9;

  group('which way a rider is going relative to the line', () {
    test('the rider on the other arm is heading across the route', () {
      expect(
        routeTravel(
          position: crossingRider,
          path: path,
          headingDegrees: crossingHeading,
          speedMetersPerSecond: crossingSpeed,
        ),
        RouteTravel.across,
      );
    });

    test('the same place heading the route\'s way is along it', () {
      // A parallel road, or the far carriageway, going the same way.
      expect(
        routeTravel(
          position: crossingRider,
          path: path,
          headingDegrees: 180,
          speedMetersPerSecond: crossingSpeed,
        ),
        RouteTravel.along,
      );
    });

    test('heading back up the route is not along it', () {
      expect(
        routeTravel(
          position: crossingRider,
          path: path,
          headingDegrees: 358,
          speedMetersPerSecond: crossingSpeed,
        ),
        RouteTravel.across,
      );
    });

    test('a heading below the speed floor says nothing', () {
      expect(
        routeTravel(
          position: crossingRider,
          path: path,
          headingDegrees: crossingHeading,
          speedMetersPerSecond: 2.9,
        ),
        RouteTravel.unknown,
      );
      expect(
        routeTravel(
          position: crossingRider,
          path: path,
          headingDegrees: null,
          speedMetersPerSecond: crossingSpeed,
        ),
        RouteTravel.unknown,
      );
    });

    test('on the line, heading never takes a rider off it', () {
      // On the ring, with the course still saying where they came from.
      expect(
        routeTravel(
          position: point(19, -20),
          path: path,
          headingDegrees: crossingHeading,
          speedMetersPerSecond: 8,
        ),
        RouteTravel.along,
      );
    });

    test('a road used twice counts in either direction', () {
      // Out and back along the same line: northbound then southbound.
      final outAndBack = [point(0, 0), point(0, 500), point(0.5, 0)];
      for (final heading in [0.0, 180.0]) {
        expect(
          routeTravel(
            position: point(40, 250),
            path: outAndBack,
            headingDegrees: heading,
            speedMetersPerSecond: 12,
          ),
          RouteTravel.along,
          reason: 'heading $heading',
        );
      }
    });
  });

  group('guidance is not given to a rider crossing the route', () {
    const planner = NavigationGuidancePlanner();
    final route = ImportedRoute(
      id: 'junction-excerpt',
      name: 'Junction excerpt',
      importedAt: DateTime.utc(2026, 10, 10),
      sourceFileName: 'excerpt.gpx',
      paths: [RoutePath(kind: RoutePathKind.track, points: path)],
      waypoints: const [],
      maneuvers: [
        RouteManeuver(
          position: entry,
          type: 'roundabout',
          bearingBeforeDegrees: 178.5,
          drivingSide: 'left',
        ),
        RouteManeuver(
          position: ring.last,
          type: 'exit roundabout',
          bearingAfterDegrees: 167,
          drivingSide: 'left',
        ),
        RouteManeuver(position: exitEnd, type: 'arrive'),
      ],
    );
    // The rider's progress as the tracker had it: projected onto the planned
    // approach, 54 m before the ring.
    const progress = 346.0;

    NavigationGuidanceAssessment assessAt(
      GeoPoint position, {
      double? heading,
      double? speed,
    }) => planner.assess(
      route: route,
      position: position,
      progressMeters: progress,
      headingDegrees: heading,
      speedMetersPerSecond: speed,
    );

    test('the rider on the other arm is off route, with no instruction', () {
      final assessment = assessAt(
        crossingRider,
        heading: crossingHeading,
        speed: crossingSpeed,
      );
      expect(assessment.state, NavigationGuidanceState.offRoute);
      expect(assessment.guidance, isNull);
    });

    test('without a heading the old distance-only answer stands', () {
      final assessment = assessAt(crossingRider);
      expect(assessment.state, NavigationGuidanceState.active);
      expect(assessment.guidance?.instruction.maneuver.type, 'roundabout');
    });

    test('a rider on the planned approach is given the roundabout', () {
      final assessment = assessAt(
        along(entry, 178.5 + 180, 54),
        heading: 178.5,
        speed: crossingSpeed,
      );
      expect(assessment.state, NavigationGuidanceState.active);
      expect(assessment.guidance?.instruction.maneuver.type, 'roundabout');
    });

    test('a parallel road going the same way keeps its guidance', () {
      final assessment = assessAt(
        crossingRider,
        heading: 180,
        speed: crossingSpeed,
      );
      expect(assessment.state, NavigationGuidanceState.active);
    });
  });
}
