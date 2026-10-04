import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../domain/imported_route.dart';
import 'road_routing.dart';
import 'route_verification.dart';

/// A planned route looked up edge by edge: what each stretch of it is.
class RouteTrace {
  const RouteTrace({
    required this.edges,
    required this.shape,
    required this.submittedMeters,
    required this.routeMeters,
  });

  final List<RouteEdge> edges;

  /// The shape the edges' indexes refer to.
  final List<GeoPoint> shape;

  /// How much of the route was sent to be looked up.
  final double submittedMeters;

  /// The whole route. More than [submittedMeters] when the route was longer
  /// than the service will look up in one request.
  final double routeMeters;

  double get coveredMeters =>
      edges.fold(0.0, (total, edge) => total + edge.lengthMeters);
}

/// The lookup could not be made or its answer could not be read.
class RouteAttributeException implements Exception {
  const RouteAttributeException(this.message);

  final String message;

  @override
  String toString() => 'RouteAttributeException: $message';
}

abstract interface class RouteAttributeProvider {
  /// Looks [route] up in a road graph. Throws [RouteAttributeException] when it
  /// cannot be done; never returns a guess.
  Future<RouteTrace> trace(List<GeoPoint> route);
}

/// Valhalla `trace_attributes`, which says what a line is made of: the OSM way,
/// its use (road, track, ramp, footway), its surface and its road class.
///
/// The same service that already answers the speed-limit lookups, asked once
/// per planned route rather than once per fix. It is asked with
/// `shape_match: map_snap` because the line being checked usually came from a
/// different engine (OSRM) over different map data, so it is *matched* to this
/// graph rather than assumed to be made of its edges.
///
/// Measured against the live instance on 4 October 2026:
///
/// - a 190 km route sent as 400 points was answered in 0.3 s, and 52 km as 1078
///   points in 0.4 s;
/// - a route over 200 km is refused outright - `Path distance exceeds the max
///   distance limit: 200000 meters` - however few points it is sent as, because
///   the limit is on the length of the line and not on how finely it is sampled.
///   So one request covers the first [maximumRequestMeters] of a longer route
///   and the rest is reported as unchecked. It is not split into more requests:
///   this is a shared public instance, and a planned route is looked up once.
class ValhallaRouteAttributeProvider implements RouteAttributeProvider {
  const ValhallaRouteAttributeProvider({
    required this.client,
    required this.endpoint,
    this.timeout = const Duration(seconds: 12),
    this.maximumResponseBytes = 4 * 1024 * 1024,
    this.maximumRequestMeters = 190000,
    this.maximumPoints = 1500,
  });

  final http.Client client;
  final Uri endpoint;
  final Duration timeout;
  final int maximumResponseBytes;

  /// How much of a route one request may cover. The service's own limit is
  /// 200 km of path; this leaves room for the matched road being a little
  /// longer than the line that was sent.
  final double maximumRequestMeters;

  /// A ceiling on points per request. Not a limit the service imposes: a
  /// bound on how much one planned route can push in one body.
  final int maximumPoints;

  static const _headers = {
    'accept': 'application/json',
    'content-type': 'application/json',
    'user-agent':
        'TailEndCharlie/1.0 (https://github.com/osholt/tailendcharlie)',
  };

  /// What is asked for and nothing else. `shape` is the matched line, which the
  /// edges' `begin_shape_index`/`end_shape_index` point into.
  static const requestedAttributes = [
    'edge.way_id',
    'edge.names',
    'edge.use',
    'edge.unpaved',
    'edge.surface',
    'edge.road_class',
    'edge.length',
    'edge.begin_shape_index',
    'edge.end_shape_index',
    'matched.type',
    'shape',
  ];

  @override
  Future<RouteTrace> trace(List<GeoPoint> route) async {
    if (endpoint.scheme != 'https' || endpoint.host.isEmpty) {
      throw const RouteAttributeException(
        'Route checking must use a configured HTTPS service.',
      );
    }
    final prepared = prepareRouteTraceShape(
      route,
      maximumMeters: maximumRequestMeters,
      maximumPoints: maximumPoints,
    );
    if (prepared.points.length < 2) {
      throw const RouteAttributeException('The route has no length to check.');
    }
    final http.Response response;
    try {
      response = await client
          .post(
            endpoint,
            headers: _headers,
            body: jsonEncode({
              'shape': [
                for (final point in prepared.points)
                  {'lat': point.latitude, 'lon': point.longitude},
              ],
              'costing': 'motorcycle',
              'shape_match': 'map_snap',
              'filters': {
                'action': 'include',
                'attributes': requestedAttributes,
              },
            }),
          )
          .timeout(timeout);
    } on Object catch (error) {
      throw RouteAttributeException('Route check failed: $error');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw RouteAttributeException(
        'Route check failed (${response.statusCode}).',
      );
    }
    if (response.bodyBytes.length > maximumResponseBytes) {
      throw const RouteAttributeException('Route check response is too large.');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw const RouteAttributeException('Route check response is invalid.');
    }
    return parseRouteTrace(
      decoded,
      submittedMeters: prepared.sentMeters,
      routeMeters: prepared.routeMeters,
    );
  }

  /// Reads a `trace_attributes` response. Exposed so a recorded response can be
  /// read without a request.
  static RouteTrace parseRouteTrace(
    Object? decoded, {
    required double submittedMeters,
    required double routeMeters,
  }) {
    if (decoded is! Map || decoded['edges'] is! List) {
      final error = decoded is Map ? decoded['error'] : null;
      throw RouteAttributeException(
        error is String && error.isNotEmpty
            ? 'Route check failed: $error'
            : 'Route check response is invalid.',
      );
    }
    final factor = switch (decoded['units']) {
      null || 'kilometers' => 1000.0,
      'miles' => 1609.344,
      final other => throw RouteAttributeException(
        'Route check answered in unknown units ($other).',
      ),
    };
    final List<GeoPoint> shape;
    try {
      shape = ValhallaMotorcycleRoutingService.decodeValhallaShape(
        decoded['shape'],
      );
    } on FormatException {
      throw const RouteAttributeException('Route check shape is invalid.');
    }
    final edges = <RouteEdge>[];
    for (final raw in decoded['edges'] as List) {
      if (raw is! Map || raw['length'] is! num) continue;
      final length = (raw['length'] as num).toDouble() * factor;
      if (!length.isFinite || length < 0) continue;
      final names = raw['names'];
      edges.add(
        RouteEdge(
          lengthMeters: length,
          beginShapeIndex: (raw['begin_shape_index'] as num?)?.toInt() ?? 0,
          endShapeIndex: (raw['end_shape_index'] as num?)?.toInt() ?? 0,
          wayId: (raw['way_id'] as num?)?.toInt(),
          use: raw['use'] as String?,
          unpaved: raw['unpaved'] == true,
          surface: raw['surface'] as String?,
          roadClass: raw['road_class'] as String?,
          names: names is List
              ? List.unmodifiable(names.whereType<String>())
              : const [],
        ),
      );
    }
    return RouteTrace(
      edges: List.unmodifiable(edges),
      shape: List.unmodifiable(shape),
      submittedMeters: submittedMeters,
      routeMeters: routeMeters,
    );
  }
}

/// A route's line, cut to what one request may cover and thinned to a size a
/// request body can reasonably be.
///
/// Cut at [maximumMeters] of path, exactly, so the part that was sent is a true
/// prefix of the route. Then simplified, which keeps every bend and drops the
/// points a straight road does not need, and finally given back an intermediate
/// point wherever a gap would be wider than [maximumGapMeters]: a map matcher
/// chooses the best path *between* the points it is given, and two points three
/// kilometres apart on a dual carriageway leave it free to choose the road beside
/// it.
({List<GeoPoint> points, double sentMeters, double routeMeters})
prepareRouteTraceShape(
  List<GeoPoint> route, {
  required double maximumMeters,
  required int maximumPoints,
  double maximumGapMeters = 250,
}) {
  if (route.length < 2) {
    return (points: route, sentMeters: 0, routeMeters: 0);
  }
  final cut = <GeoPoint>[route.first];
  var travelled = 0.0;
  var routeMeters = 0.0;
  var cutDone = false;
  for (var index = 1; index < route.length; index += 1) {
    final length = routeDistanceMeters(route[index - 1], route[index]);
    routeMeters += length;
    if (cutDone) continue;
    if (travelled + length > maximumMeters && length > 0) {
      final fraction = (maximumMeters - travelled) / length;
      final from = route[index - 1];
      final to = route[index];
      cut.add(
        GeoPoint(
          latitude: from.latitude + (to.latitude - from.latitude) * fraction,
          longitude:
              from.longitude + (to.longitude - from.longitude) * fraction,
        ),
      );
      travelled = maximumMeters;
      cutDone = true;
    } else {
      cut.add(route[index]);
      travelled += length;
    }
  }
  var tolerance = 3.0;
  var points = _densify(_simplify(cut, tolerance), maximumGapMeters);
  for (
    var attempt = 0;
    attempt < 8 && points.length > maximumPoints;
    attempt++
  ) {
    tolerance *= 2;
    points = _densify(_simplify(cut, tolerance), maximumGapMeters);
  }
  if (points.length > maximumPoints) {
    points = [
      for (var index = 0; index < maximumPoints; index += 1)
        points[(index * (points.length - 1) / (maximumPoints - 1)).round()],
    ];
  }
  return (points: points, sentMeters: travelled, routeMeters: routeMeters);
}

/// Douglas-Peucker, with the tolerance in metres on a local flat projection.
List<GeoPoint> _simplify(List<GeoPoint> points, double toleranceMeters) {
  if (points.length < 3) return points;
  const earthRadius = 6371008.8;
  final scale = math.cos(points.first.latitude * math.pi / 180);
  final xs = [
    for (final point in points)
      point.longitude * math.pi / 180 * scale * earthRadius,
  ];
  final ys = [
    for (final point in points) point.latitude * math.pi / 180 * earthRadius,
  ];
  final keep = List<bool>.filled(points.length, false);
  keep[0] = true;
  keep[points.length - 1] = true;
  final spans = <(int, int)>[(0, points.length - 1)];
  while (spans.isNotEmpty) {
    final (first, last) = spans.removeLast();
    var farthest = 0.0;
    var farthestIndex = -1;
    for (var index = first + 1; index < last; index += 1) {
      final distance = _distanceToSegment(
        xs[index],
        ys[index],
        xs[first],
        ys[first],
        xs[last],
        ys[last],
      );
      if (distance > farthest) {
        farthest = distance;
        farthestIndex = index;
      }
    }
    if (farthestIndex != -1 && farthest > toleranceMeters) {
      keep[farthestIndex] = true;
      spans
        ..add((first, farthestIndex))
        ..add((farthestIndex, last));
    }
  }
  return [
    for (var index = 0; index < points.length; index += 1)
      if (keep[index]) points[index],
  ];
}

double _distanceToSegment(
  double x,
  double y,
  double startX,
  double startY,
  double endX,
  double endY,
) {
  final deltaX = endX - startX;
  final deltaY = endY - startY;
  final lengthSquared = deltaX * deltaX + deltaY * deltaY;
  final fraction = lengthSquared <= 0
      ? 0.0
      : (((x - startX) * deltaX + (y - startY) * deltaY) / lengthSquared).clamp(
          0.0,
          1.0,
        );
  final nearestX = startX + deltaX * fraction;
  final nearestY = startY + deltaY * fraction;
  return math.sqrt(
    (x - nearestX) * (x - nearestX) + (y - nearestY) * (y - nearestY),
  );
}

List<GeoPoint> _densify(List<GeoPoint> points, double maximumGapMeters) {
  final result = <GeoPoint>[points.first];
  for (var index = 1; index < points.length; index += 1) {
    final from = points[index - 1];
    final to = points[index];
    final gap = routeDistanceMeters(from, to);
    final pieces = (gap / maximumGapMeters).ceil();
    for (var piece = 1; piece < pieces; piece += 1) {
      final fraction = piece / pieces;
      result.add(
        GeoPoint(
          latitude: from.latitude + (to.latitude - from.latitude) * fraction,
          longitude:
              from.longitude + (to.longitude - from.longitude) * fraction,
        ),
      );
    }
    result.add(to);
  }
  return result;
}
