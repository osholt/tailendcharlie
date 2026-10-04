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
}
