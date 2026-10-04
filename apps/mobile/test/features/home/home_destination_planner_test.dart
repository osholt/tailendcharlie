import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/distance_unit.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/features/home/home_screen.dart';
import 'package:ride_relay/services/road_routing.dart';
import 'package:ride_relay/services/route_verification.dart';

import '../../services/route_verification_fixtures.dart';

/// "Where are you going?" on Home planned with OSRM alone: no route preference
/// could reach a router that understood it, and a route that broke one could be
/// neither checked nor re-planned. The routes here are recorded responses for
/// the approach to a canal-side wharf, where both routers take a gated track.
void main() {
  const start = GeoPoint(latitude: 51.747143, longitude: -2.986532);
  const wharf = GeoPoint(latitude: 51.752096, longitude: -2.9971343);

  // A short run on and off the M5, which both routers take by motorway.
  const motorwayStart = GeoPoint(latitude: 51.5460, longitude: -2.5900);
  const motorwayEnd = GeoPoint(latitude: 51.6385, longitude: -2.4893);

  Future<DestinationRoutePlan> planMotorway(
    RecordedRouting routing,
    RoutePreferences preferences,
  ) =>
      HomeScreen.defaultDestinationPlanner(
        client: routing.client,
        configuration: planningConfiguration,
      ).planForReview(
        origin: motorwayStart,
        query: 'Falfield',
        selectedDestination: const DestinationMatch(
          label: 'Falfield',
          point: motorwayEnd,
        ),
        preferences: preferences,
      );

  Future<DestinationRoutePlan> plan(
    RecordedRouting routing,
    RoutePreferences preferences,
  ) =>
      HomeScreen.defaultDestinationPlanner(
        client: routing.client,
        configuration: planningConfiguration,
      ).planForReview(
        origin: start,
        query: 'Wharf',
        selectedDestination: const DestinationMatch(
          label: 'Wharf',
          point: wharf,
        ),
        preferences: preferences,
      );

  test('a route over a track is re-planned around it', () async {
    final routing = RecordedRouting(
      osrm: fixtureResponse('osrm_track_approach.json'),
      valhallaExcluding: fixtureResponse('valhalla_track_avoided.json'),
      traces: [
        fixtureResponse('trace_track_approach.json'),
        fixtureResponse('trace_track_avoided.json'),
      ],
    );

    final planned = await plan(routing, RoutePreferences.defaults);

    expect(routing.osrmRequests, hasLength(1));
    expect(routing.valhallaRequests, hasLength(1));
    expect(
      routing.valhallaRequests.single.containsKey('exclude_locations'),
      isTrue,
      reason:
          'Home could not exclude a road before it used the same routing '
          'as the map',
    );
    expect(planned.distanceMeters, closeTo(2852, 1));
    expect(planned.verification!.replan, RouteReplanOutcome.adopted);
    expect(planned.verification!.notices(DistanceUnit.miles), isEmpty);
  });

  test(
    'a track that cannot be avoided reaches the review with its length',
    () async {
      final routing = RecordedRouting(
        osrm: fixtureResponse('osrm_track_approach.json'),
        valhallaExcluding: fixtureResponse('valhalla_no_path.json', 400),
        traces: [fixtureResponse('trace_track_approach.json')],
      );

      final planned = await plan(routing, RoutePreferences.defaults);

      expect(planned.verification!.notices(DistanceUnit.miles), [
        'Uses 0.4 mi of unsurfaced track, although Avoid unsurfaced byways is '
            'on. No road route that avoids it was found.',
      ]);
    },
  );

  test(
    'a rider who allows byways is planned on the motorcycle router',
    () async {
      final routing = RecordedRouting(
        valhalla: fixtureResponse('valhalla_track_approach.json'),
        traces: [fixtureResponse('trace_track_approach.json')],
      );

      final planned = await plan(
        routing,
        const RoutePreferences(
          bywaySurface: BywaySurfacePreference.allowUnsurfaced,
        ),
      );

      expect(routing.osrmRequests, isEmpty, reason: 'OSRM cannot seek byways');
      expect(routing.valhallaRequests, hasLength(1));
      expect(planned.verification!.isClean, isTrue);
    },
  );

  // Avoid motorways, and what Home did with it (#858).
  test('Avoid motorways reaches the router that can honour it', () async {
    final routing = RecordedRouting(
      valhalla: fixtureResponse('valhalla_m5_avoided.json'),
      traces: [fixtureResponse('trace_m5_avoided.json')],
    );

    final planned = await planMotorway(
      routing,
      const RoutePreferences(avoidMotorways: true, avoidMajorRoads: true),
    );

    expect(routing.osrmRequests, isEmpty, reason: 'OSRM would have dropped it');
    expect(routing.valhallaRequests, hasLength(1));
    final costing =
        (routing.valhallaRequests.single['costing_options']!
                as Map)['motorcycle']!
            as Map;
    expect(costing['exclude_highways'], isTrue);
    expect(costing['use_highways'], 0.08);
    expect(planned.distanceMeters, closeTo(16930, 1));
    expect(planned.route.preferences?.avoidMotorways, isTrue);
  });

  test('the route Becks was shown is caught when it is shown again', () async {
    // The motorway-routed answer, from a provider that ignored the request.
    final routing = RecordedRouting(
      valhalla: fixtureResponse('valhalla_m5_stretch.json'),
      valhallaExcluding: fixtureResponse('valhalla_no_path.json', 400),
      traces: [fixtureResponse('trace_m5_stretch.json')],
    );

    final planned = await planMotorway(
      routing,
      const RoutePreferences(avoidMotorways: true),
    );

    expect(planned.distanceMeters, closeTo(18805, 1));
    expect(planned.verification!.notices(DistanceUnit.miles), [
      'Uses 7.8 mi of motorway (M5), although Avoid motorways is on. No '
          'motorway-free route was found.',
    ]);
  });

  test('a rider who asked for nothing is still planned on OSRM', () async {
    final routing = RecordedRouting(
      osrm: fixtureResponse('osrm_m5_stretch.json'),
      traces: [fixtureResponse('trace_m5_stretch.json')],
    );

    final planned = await planMotorway(routing, RoutePreferences.defaults);

    expect(routing.osrmRequests, hasLength(1));
    expect(routing.valhallaRequests, isEmpty);
    expect(planned.verification!.isClean, isTrue);
  });
}
