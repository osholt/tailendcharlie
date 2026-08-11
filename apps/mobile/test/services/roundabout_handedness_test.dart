import 'dart:convert';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/features/map/maneuver_symbol.dart';
import 'package:ride_relay/services/navigation_guidance.dart';
import 'package:ride_relay/services/road_routing.dart';

void main() {
  // The 10 August ride, twice: "2nd exit, straight on" and "3rd exit, right"
  // both drawn as though traffic circulates anticlockwise. The exit number and
  // the direction word were right each time, which is what made it look like a
  // drawing fault rather than a data one.
  //
  // It was a data one. The routing engine reported `driving_side: right` for a
  // UK roundabout, and the symbol mirrored itself to match.
  group('a roundabout is drawn for the traffic it is actually in (#427)', () {
    test('an engine claiming right-hand traffic does not mirror the ring', () {
      // The discriminator, in one number: keeping left, a right exit is three
      // quarters of the way round (270°); keeping right it is a quarter (90°).
      // The screenshots showed a quarter.
      //
      // What the engine said is still *carried* — the turn-detail sheet and the
      // diagnostics recorder both show it, and hiding it would make the next
      // occurrence harder to diagnose, not easier. It simply no longer decides
      // which way the ring is drawn.
      final decoded =
          jsonDecode(_osrmResponseSayingRightHandTraffic)
              as Map<String, dynamic>;
      final legs = (decoded['routes'] as List).first['legs'];
      final maneuvers = OsrmRoadRoutingService.parseManeuvers(legs);

      expect(maneuvers, isNotEmpty);
      expect(
        maneuvers.first.drivingSide,
        'right',
        reason: 'what the engine said is kept, so it can be diagnosed',
      );
      expect(
        collapseManeuvers(maneuvers).first.leftHandTraffic,
        isNot(false),
        reason: 'but it must not mirror the ring',
      );
    });

    test('an unstated driving side still circulates clockwise', () {
      // The default has always been correct and is what now applies: keeping
      // left means keeping the island on your right, which is clockwise.
      for (final direction in [
        ManeuverDirection.left,
        ManeuverDirection.straight,
        ManeuverDirection.right,
        ManeuverDirection.uTurn,
      ]) {
        final geometry = RoundaboutSymbolGeometry.of(
          RoundaboutSymbol(direction: direction, leftHandTraffic: null),
          const Size(200, 200),
        );

        expect(
          geometry.ringArcs.single.sweepDegrees,
          greaterThan(0),
          reason: '$direction must circulate clockwise',
        );
      }
    });

    test('a right exit sweeps three quarters, not a quarter', () {
      // The exact shape of what was on screen. A quarter-turn arc for a right
      // exit is the signature of the mirrored symbol.
      final geometry = RoundaboutSymbolGeometry.of(
        const RoundaboutSymbol(
          direction: ManeuverDirection.right,
          leftHandTraffic: null,
          exitNumber: 3,
        ),
        const Size(200, 200),
      );

      expect(geometry.ringArcs.single.sweepDegrees, closeTo(270, 1));
    });

    test('straight on sweeps half the ring', () {
      final geometry = RoundaboutSymbolGeometry.of(
        const RoundaboutSymbol(
          direction: ManeuverDirection.straight,
          leftHandTraffic: null,
          exitNumber: 2,
        ),
        const Size(200, 200),
      );

      expect(geometry.ringArcs.single.sweepDegrees, closeTo(180, 1));
    });
  });
}

/// An OSRM roundabout step carrying `driving_side: right`, which is what the
/// engine actually returned for the junctions in the screenshots.
const _osrmResponseSayingRightHandTraffic = '''
{
  "code": "Ok",
  "routes": [
    {
      "distance": 100.0,
      "duration": 30.0,
      "geometry": {
        "type": "LineString",
        "coordinates": [[-2.5079, 51.4870], [-2.5070, 51.4875]]
      },
      "legs": [
        {
          "steps": [
            {
              "name": "Tenniscourt Road",
              "driving_side": "right",
              "maneuver": {
                "type": "roundabout",
                "modifier": "right",
                "exit": 3,
                "location": [-2.5079, 51.4870],
                "bearing_before": 10,
                "bearing_after": 100
              },
              "intersections": []
            }
          ]
        }
      ]
    }
  ]
}
''';
