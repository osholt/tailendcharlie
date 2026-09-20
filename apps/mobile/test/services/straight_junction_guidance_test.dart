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

  List<RoadRouteManeuver> parse({
    double other = 35,
    bool allowed = true,
    bool topology = true,
    String type = 'depart',
    double junction = 0.002,
  }) => OsrmRoadRoutingService.parseManeuvers([
    {
      'steps': [
        {
          'name': 'D road',
          'maneuver': {
            'type': type,
            'location': [0, 0],
          },
          'intersections': [
            {
              'location': [0, junction],
              if (topology) ...{
                'bearings': [0, other, 180],
                'entry': [true, allowed, false],
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

  test(
    'a hidden competing forward branch gets one straight fork instruction',
    () {
      final steps = collapseManeuvers(parse());
      expect(steps.map((step) => step.kind), [
        ManeuverKind.depart,
        ManeuverKind.fork,
        ManeuverKind.arrive,
      ]);
      expect(steps[1].text, 'At the fork, continue straight on');
      expect(steps[1].isGuidance, isTrue);
      expect(steps[1].roadName, 'D road');
    },
  );

  test(
    'obvious side roads, incoming-only arms and incomplete topology stay quiet',
    () {
      for (final route in [
        parse(other: 90),
        parse(allowed: false),
        parse(topology: false),
        parse(type: 'roundabout'),
        parse(junction: 0.00001),
      ]) {
        expect(route.where((step) => step.type == 'fork'), isEmpty);
      }
    },
  );
}
