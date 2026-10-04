import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/services/navigation_guidance.dart';
import 'package:ride_relay/services/road_routing.dart';

void main() {
  test(
    'an explicit straight instruction survives while a name change stays quiet',
    () {
      for (final type in ['continue', 'new name', 'notification']) {
        final instruction = collapseManeuvers([
          const RouteManeuver(
            position: GeoPoint(latitude: 0, longitude: 0),
            type: 'depart',
          ),
          RouteManeuver(
            position: const GeoPoint(latitude: 0, longitude: 0.001),
            type: type,
            modifier: 'straight',
          ),
        ]).last;
        expect(instruction.isGuidance, type == 'continue');
      }
      final valhalla = ValhallaMotorcycleRoutingService.parseManeuvers(
        route: const [
          GeoPoint(latitude: 0, longitude: 0),
          GeoPoint(latitude: 0, longitude: 0.001),
        ],
        legManeuvers: [
          [
            {'type': 8, 'begin_shape_index': 1},
          ],
        ],
        legShapeOffsets: [0],
      );
      expect(collapseManeuvers(valhalla).single.isGuidance, isTrue);
    },
  );

  /// One step heading north whose middle intersection has the route carrying
  /// straight on at 0 degrees and another road leaving at [other].
  List<RoadRouteManeuver> parse({
    double other = 20,
    double? alsoOther,
    bool allowed = true,
    bool topology = true,
    String type = 'depart',
    double junction = 0.002,
    String? name,
    String? ref,
  }) => OsrmRoadRoutingService.parseManeuvers([
    {
      'steps': [
        {
          'name': ?name,
          'ref': ?ref,
          'maneuver': {
            'type': type,
            'location': [0, 0],
          },
          'intersections': [
            {
              'location': [0, junction],
              if (topology) ...{
                'bearings': [0, other, 180, ?alsoOther],
                'entry': [true, allowed, false, if (alsoOther != null) true],
                'in': 2,
                'out': 0,
              },
            },
          ],
        },
        {
          'maneuver': {
            'type': 'arrive',
            'location': [0, 0.004],
          },
        },
      ],
    },
  ]);

  group('a fork the engine left silent (#774, #851)', () {
    test(
      'two unnamed roads that look alike are announced with the side to keep',
      () {
        // #774's intent: the rider must choose between two similar branches
        // and nothing says which is the way on.
        final right = collapseManeuvers(parse(other: 20));
        expect(right.map((step) => step.kind), [
          ManeuverKind.depart,
          ManeuverKind.fork,
          ManeuverKind.arrive,
        ]);
        expect(right[1].text, 'Keep left');
        expect(right[1].isGuidance, isTrue);
        expect(right[1].roadLabel, isEmpty);

        final left = collapseManeuvers(parse(other: 340));
        expect(left[1].text, 'Keep right');
      },
    );

    test('the middle of three similar branches is said as straight on', () {
      final steps = collapseManeuvers(parse(other: 20, alsoOther: 340));
      expect(steps[1].kind, ManeuverKind.fork);
      expect(steps[1].text, 'At the fork, continue straight on');
    });

    test('a road that carries a name or number on is followed silently', () {
      // #851: the 4 Oct ride heard "At the fork, continue straight on" at
      // every motorway exit from Aust to Bristol and at ten minor junctions on
      // the B4235. A numbered or named road carrying on through the junction
      // is the way on, which is why the engine said nothing.
      for (final route in [
        parse(name: 'D road'),
        parse(ref: 'B4235'),
        parse(ref: 'M48', other: 354),
        parse(name: 'Castle Parade', ref: 'A472', other: 330),
      ]) {
        expect(route.where((step) => step.type == 'fork'), isEmpty);
      }
    });

    test(
      'obvious side roads, incoming-only arms and incomplete topology stay quiet',
      () {
        for (final route in [
          parse(other: 90),
          // A side road 35 degrees off is a side road, not a similar branch.
          parse(other: 35),
          parse(other: 45),
          parse(allowed: false),
          parse(topology: false),
          parse(type: 'roundabout'),
          parse(junction: 0.00001),
        ]) {
          expect(route.where((step) => step.type == 'fork'), isEmpty);
        }
      },
    );

    test('a restored fork keeps its junction, and claims no road name', () {
      final fork = parse(other: 20).singleWhere((step) => step.type == 'fork');
      expect(fork.junction?.bearingsDegrees, [0, 20, 180]);
      expect(fork.name, isNull);
      expect(fork.ref, isNull);
      final restored = RoadRouteManeuver.fromJson(fork.toJson());
      expect(restored.junction?.toJson(), fork.junction?.toJson());
    });
  });
}
