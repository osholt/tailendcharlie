/// Recorded router responses for the route-verification tests (#840).
///
/// Everything in `test/fixtures/route_verification/` was recorded from the live
/// services on 4 October 2026, and is **junction-local**: a few kilometres
/// around one place, never a rider's start, end or home.
///
/// - `*_track_*` is the approach to a canal-side wharf. OSRM and Valhalla both
///   route the last 650 m over an untagged `highway=track` with three gates
///   because it is shorter than the paved road beside it. `valhalla_track_avoided`
///   is Valhalla asked for the same trip with the track's edges excluded; it
///   goes round by the road and is 1.6 km longer.
/// - `trace_*` is Valhalla `trace_attributes` over the geometry of the route of
///   the same name: what each stretch of it is made of.
/// - `valhalla_other_trip` is a Valhalla route for a trip somewhere else
///   altogether, for the answer to an exclusion that comes back from nowhere near
///   the trip that was asked for.
/// - `valhalla_no_path` is the real error for a trip that cannot be routed
///   under the exclusions asked of it.
library;

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/services/road_routing.dart';

Map<String, Object?> routeVerificationFixture(String name) =>
    jsonDecode(
          File('test/fixtures/route_verification/$name').readAsStringSync(),
        )
        as Map<String, Object?>;

String routeVerificationFixtureText(String name) =>
    File('test/fixtures/route_verification/$name').readAsStringSync();

final planningConfiguration = RoutingConfiguration(
  routingBaseUrl: Uri.parse('https://osrm.example.test'),
  geocodingBaseUrl: Uri.parse('https://geocoder.example.test'),
  motorcycleRoutingUrl: Uri.parse('https://valhalla.example.test/route'),
  trackMatchingUrl: Uri.parse('https://valhalla.example.test/trace_route'),
);

/// A fake of every service one planned route can touch, answering from recorded
/// responses and remembering what it was asked.
class RecordedRouting {
  RecordedRouting({
    this.osrm,
    this.valhalla,
    this.valhallaExcluding,
    List<http.Response> traces = const [],
  }) : _traces = [...traces];

  /// What OSRM answers, if it is asked.
  final http.Response? osrm;

  /// What Valhalla answers a route request without exclusions.
  final http.Response? valhalla;

  /// What Valhalla answers a route request that excludes edges.
  final http.Response? valhallaExcluding;
  final List<http.Response> _traces;

  final osrmRequests = <Uri>[];
  final valhallaRequests = <Map<String, Object?>>[];
  final traceRequests = <Map<String, Object?>>[];

  http.Client get client => MockClient((request) async {
    final host = request.url.host;
    if (host == 'osrm.example.test') {
      osrmRequests.add(request.url);
      return osrm ?? http.Response('no OSRM response recorded', 500);
    }
    if (host == 'valhalla.example.test' &&
        request.url.path.endsWith('/trace_attributes')) {
      traceRequests.add(jsonDecode(request.body) as Map<String, Object?>);
      if (_traces.isEmpty) return http.Response('no trace recorded', 500);
      return _traces.removeAt(0);
    }
    if (host == 'valhalla.example.test') {
      final body =
          jsonDecode(request.url.queryParameters['json']!)
              as Map<String, Object?>;
      valhallaRequests.add(body);
      final excluding = body.containsKey('exclude_locations');
      return (excluding ? valhallaExcluding : valhalla) ??
          http.Response('no Valhalla response recorded', 500);
    }
    return http.Response('unexpected host $host', 500);
  });
}

http.Response jsonResponse(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: const {'content-type': 'application/json'},
);

http.Response fixtureResponse(String name, [int status = 200]) => http.Response(
  routeVerificationFixtureText(name),
  status,
  headers: const {'content-type': 'application/json'},
);

/// The geometry of a recorded OSRM response.
List<GeoPoint> osrmFixturePoints(String name) {
  final route =
      (routeVerificationFixture(name)['routes']! as List).first as Map;
  return [
    for (final coordinate in (route['geometry']! as Map)['coordinates'] as List)
      GeoPoint(
        latitude: (coordinate as List)[1] as double,
        longitude: coordinate[0] as double,
      ),
  ];
}
