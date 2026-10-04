import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/services/navigation_guidance.dart';
import 'package:ride_relay/services/road_jurisdiction.dart';
import 'package:ride_relay/services/road_routing.dart';

import 'osrm_maneuver_fixtures.dart';

/// #853: leaving Usk, the route joins the A472 dual carriageway and leaves it
/// almost at once by the B4235 slip on the left. It was announced "Continue
/// straight on".
void main() {
  group('a diverge is announced with its side (#853)', () {
    test('the recorded Usk junction keeps left, not straight on', () async {
      final route = await routeFromOsrmResponse(uskB4235DivergeResponse());
      final slip = const NavigationGuidancePlanner()
          .instructions(route)
          .map((step) => step.instruction)
          .singleWhere((instruction) => instruction.maneuver.type == 'turn');

      // The engine's own words survive persistence untouched...
      expect(slip.maneuver.type, 'turn');
      expect(slip.maneuver.modifier, 'left');
      expect(maneuverHeadingChangeDegrees(slip.maneuver), closeTo(-4, 0.01));
      // ...and so does the junction that explains them.
      final junction = slip.maneuver.junction!;
      expect(junction.bearingsDegrees, [89, 97, 274]);
      expect(junction.enterable, [true, true, false]);
      expect(junction.takenIndex, 0);
      expect(junction.approachIndex, 2);

      expect(slip.kind, ManeuverKind.fork);
      expect(slip.direction, ManeuverDirection.slightLeft);
      expect(slip.text, 'Keep left');
      expect(slip.standaloneText, 'Keep left');
      expect(slip.text, isNot(contains('straight')));
    });

    test('the side comes from where the other road lies', () {
      // Mirror image of Usk: the other road leaves eight degrees to the left.
      final instruction = _instruction(
        modifier: 'right',
        before: 88,
        after: 92,
        junction: RouteJunction.tryCreate(
          bearingsDegrees: const [91, 83, 274],
          enterable: const [true, true, false],
          takenIndex: 0,
          approachIndex: 2,
        ),
      );
      expect(instruction.direction, ManeuverDirection.slightRight);
      expect(instruction.text, 'Keep right');
    });

    test('a slip road the engine called straight on still names its side', () {
      // Live OSRM, A4042 to the M4: `off ramp` `straight`, 78 then 85 degrees,
      // with the A4042 carrying on at 75 and the slip leaving at 90.
      final instruction = _instruction(
        type: 'off ramp',
        modifier: 'straight',
        before: 78,
        after: 85,
        junction: RouteJunction.tryCreate(
          bearingsDegrees: const [75, 90, 255],
          enterable: const [true, true, false],
          takenIndex: 1,
          approachIndex: 2,
        ),
      );
      expect(instruction.kind, ManeuverKind.offRamp);
      expect(instruction.direction, ManeuverDirection.slightRight);
      expect(instruction.text, 'Take the exit slip road slight right');
    });

    test('roads beside the route on both sides claim no side', () {
      final instruction = _instruction(
        modifier: 'left',
        before: 92,
        after: 88,
        junction: RouteJunction.tryCreate(
          bearingsDegrees: const [89, 97, 70, 274],
          enterable: const [true, true, true, false],
          takenIndex: 0,
          approachIndex: 3,
        ),
      );
      // The middle of three: the existing rules decide, as before.
      expect(instruction.kind, ManeuverKind.turn);
      expect(instruction.direction, ManeuverDirection.straight);
    });

    test('a turn into one of two side roads is still a turn', () {
      // Two roads leave left twenty degrees apart. The route takes one of
      // them, which is a left turn, not a fork in the road ahead.
      final instruction = _instruction(
        modifier: 'left',
        before: 90,
        after: 0,
        junction: RouteJunction.tryCreate(
          bearingsDegrees: const [0, 20, 270],
          enterable: const [true, true, false],
          takenIndex: 0,
          approachIndex: 2,
        ),
      );
      expect(instruction.kind, ManeuverKind.turn);
      expect(instruction.direction, ManeuverDirection.left);
      expect(instruction.text, 'Turn left');
    });

    test('a side road beyond the diverge band leaves the turn alone', () {
      // Straight on past a side road at right angles is not a fork.
      final straightOn = _instruction(
        modifier: 'straight',
        before: 90,
        after: 95,
        junction: RouteJunction.tryCreate(
          bearingsDegrees: const [95, 180, 270],
          enterable: const [true, true, false],
          takenIndex: 0,
          approachIndex: 2,
        ),
      );
      expect(straightOn.kind, ManeuverKind.turn);
      expect(straightOn.direction, ManeuverDirection.straight);
      expect(straightOn.text, 'Continue straight on');
      final instruction = _instruction(
        modifier: 'slight right',
        before: 90,
        after: 115,
        junction: RouteJunction.tryCreate(
          bearingsDegrees: const [115, 180, 270],
          enterable: const [true, true, false],
          takenIndex: 0,
          approachIndex: 2,
        ),
      );
      expect(instruction.kind, ManeuverKind.turn);
      expect(instruction.text, 'Turn slight right');
    });

    test('a stated side is never turned into the opposite side', () {
      // The engine says left; the only nearby road is also on the left, which
      // would make this "keep right". The two disagree, so the junction does
      // not get the casting vote and the ordinary rules stand.
      final instruction = _instruction(
        modifier: 'left',
        before: 92,
        after: 88,
        junction: RouteJunction.tryCreate(
          bearingsDegrees: const [89, 80, 274],
          enterable: const [true, true, false],
          takenIndex: 0,
          approachIndex: 2,
        ),
      );
      expect(instruction.direction.side, isNot(ManeuverSide.right));
    });

    test('a road the route may not enter is not a choice', () {
      final instruction = _instruction(
        modifier: 'left',
        before: 92,
        after: 88,
        junction: RouteJunction.tryCreate(
          bearingsDegrees: const [89, 97, 274],
          enterable: const [true, false, false],
          takenIndex: 0,
          approachIndex: 2,
        ),
      );
      expect(instruction.kind, ManeuverKind.turn);
    });

    test('without a junction the #302 rule is unchanged', () {
      // Routes saved before the junction was kept still read their bearings.
      final instruction = _instruction(modifier: 'left', before: 92, after: 88);
      expect(instruction.direction, ManeuverDirection.straight);
      expect(instruction.text, 'Continue straight on');
    });
  });

  group('the junction is kept with the route', () {
    test('OSRM parsing keeps the manoeuvre\'s own intersection', () {
      final maneuvers = OsrmRoadRoutingService.parseManeuvers([
        {
          'steps': [
            {
              'name': 'B4235',
              'maneuver': {
                'type': 'turn',
                'modifier': 'left',
                'bearing_before': 92,
                'bearing_after': 88,
                'location': [-2.877573, 51.705375],
              },
              'intersections': [
                {
                  'location': [-2.877573, 51.705375],
                  'bearings': [89, 97, 274],
                  'entry': [true, true, false],
                  'in': 2,
                  'out': 0,
                },
              ],
            },
          ],
        },
      ]);
      final junction = maneuvers.single.junction!;
      expect(junction.takenBearingDegrees, 89);
      expect(junction.approachHeadingDegrees, 94);
      expect(junction.alternativeBearingsDegrees, [97]);
    });

    test('it survives the JSON a route is saved and shared as', () {
      final maneuver = RouteManeuver(
        position: const GeoPoint(latitude: 51.705375, longitude: -2.877573),
        type: 'turn',
        modifier: 'left',
        junction: RouteJunction.tryCreate(
          bearingsDegrees: const [89, 97, 274],
          enterable: const [true, true, false],
          takenIndex: 0,
          approachIndex: 2,
        ),
      );
      final restored = RouteManeuver.fromJson(maneuver.toJson());
      expect(restored.junction!.toJson(), maneuver.junction!.toJson());
      // A depart has no road it arrived on.
      final depart = RouteJunction.fromJson({
        'bearings': [80],
        'entry': [true],
        'out': 0,
      });
      expect(depart!.approachIndex, isNull);
      expect(depart.approachHeadingDegrees, isNull);
    });

    test('a junction that does not hang together is dropped, not fatal', () {
      for (final broken in <Object?>[
        null,
        'junction',
        {'bearings': [], 'entry': [], 'out': 0},
        {
          'bearings': [10, 20],
          'entry': [true],
          'out': 0,
        },
        {
          'bearings': [10, 20],
          'entry': [true, true],
          'out': 2,
        },
        {
          'bearings': [10, 20],
          'entry': [true, true],
          'out': 1,
          'in': 1,
        },
        {
          'bearings': [10, 'east'],
          'entry': [true, true],
          'out': 1,
        },
      ]) {
        expect(RouteJunction.fromJson(broken), isNull, reason: '$broken');
      }
      final saved = RouteManeuver.fromJson({
        'latitude': 51.7,
        'longitude': -2.8,
        'type': 'turn',
        'junction': {
          'bearings': [10, 20],
          'entry': [true, true],
          'out': 5,
        },
      });
      expect(saved.junction, isNull);
      expect(saved.type, 'turn');
    });

    test('confirming the traffic side keeps the junction', () {
      final maneuvers = OsrmRoadRoutingService.parseManeuvers([
        {
          'steps': [
            {
              'maneuver': {
                'type': 'turn',
                'modifier': 'left',
                'location': [-2.877573, 51.705375],
              },
              'intersections': [
                {
                  'location': [-2.877573, 51.705375],
                  'bearings': [89, 97, 274],
                  'entry': [true, true, false],
                  'in': 2,
                  'out': 0,
                },
              ],
            },
          ],
        },
      ]);
      final confirmed = confirmTrafficSides(
        maneuvers,
        RoadJurisdictionCatalogue.parse(_everywhereLeftHandTraffic),
      );
      expect(confirmed.single.trafficSideConfirmed, isTrue);
      expect(
        confirmed.single.junction?.toJson(),
        maneuvers.single.junction!.toJson(),
      );
    });
  });

  test('long-baseline line bearings are only ever read at a roundabout', () {
    // #853 asked whether the roundabout's averaged geometry had leaked into
    // ordinary junctions. It has not: an ordinary turn's direction does not
    // depend on the route line at all, however that line bends.
    const turn = RouteManeuver(
      position: GeoPoint(latitude: 51.705375, longitude: -2.877573),
      type: 'turn',
      modifier: 'left',
      bearingBeforeDegrees: 92,
      bearingAfterDegrees: 88,
    );
    final withoutLine = collapseManeuvers(const [turn]).single;
    final withBendingLine = collapseManeuvers(
      const [turn],
      path: const [
        GeoPoint(latitude: 51.7040, longitude: -2.8840),
        GeoPoint(latitude: 51.7053, longitude: -2.8776),
        GeoPoint(latitude: 51.7120, longitude: -2.8770),
      ],
    ).single;
    expect(withBendingLine.direction, withoutLine.direction);
    expect(withBendingLine.text, withoutLine.text);
  });

  test('a merge followed by the diverge is two decisions, both shown', () {
    // Join the dual carriageway, then keep left 105 m later: the banner shows
    // the second while the first is still ahead.
    final route = ImportedRoute(
      id: 'merge-then-diverge',
      name: 'Merge then diverge',
      importedAt: DateTime.utc(2026, 10, 4),
      sourceFileName: 'merge-then-diverge.gpx',
      waypoints: const [],
      paths: const [
        RoutePath(
          kind: RoutePathKind.track,
          points: [
            GeoPoint(latitude: 51.70500, longitude: -2.88300),
            GeoPoint(latitude: 51.70533, longitude: -2.87906),
            GeoPoint(latitude: 51.70537, longitude: -2.87757),
            GeoPoint(latitude: 51.70610, longitude: -2.87320),
          ],
        ),
      ],
      maneuvers: [
        const RouteManeuver(
          position: GeoPoint(latitude: 51.70533, longitude: -2.87906),
          type: 'merge',
          modifier: 'slight right',
          bearingBeforeDegrees: 80,
          bearingAfterDegrees: 88,
        ),
        RouteManeuver(
          position: const GeoPoint(latitude: 51.70537, longitude: -2.87757),
          type: 'turn',
          modifier: 'left',
          ref: 'B4235',
          bearingBeforeDegrees: 92,
          bearingAfterDegrees: 88,
          junction: RouteJunction.tryCreate(
            bearingsDegrees: const [89, 97, 274],
            enterable: const [true, true, false],
            takenIndex: 0,
            approachIndex: 2,
          ),
        ),
      ],
    );
    final guidance = const NavigationGuidancePlanner().plan(
      route: route,
      position: const GeoPoint(latitude: 51.70510, longitude: -2.88200),
      progressMeters: 70,
    )!;
    expect(guidance.instruction.kind, ManeuverKind.merge);
    expect(guidance.followingInstruction?.text, 'Keep left');
    expect(guidance.followingDistanceMeters, closeTo(103, 5));
  });
}

ManeuverInstruction _instruction({
  String type = 'turn',
  required String? modifier,
  required double before,
  required double after,
  RouteJunction? junction,
}) => collapseManeuvers([
  RouteManeuver(
    position: const GeoPoint(latitude: 51.7, longitude: -2.8),
    type: type,
    modifier: modifier,
    bearingBeforeDegrees: before,
    bearingAfterDegrees: after,
    junction: junction,
  ),
]).single;

/// One left-hand-traffic polygon covering the whole map, so confirming the
/// traffic side always succeeds.
const _everywhereLeftHandTraffic = '''
{
  "type": "FeatureCollection",
  "features": [
    {
      "type": "Feature",
      "properties": {
        "countryCode": "GB",
        "name": "Everywhere",
        "drivingSide": "left",
        "distanceUnit": "miles"
      },
      "geometry": {
        "type": "Polygon",
        "coordinates": [[[-179, -89], [179, -89], [179, 89], [-179, 89], [-179, -89]]]
      }
    }
  ]
}
''';
