import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../domain/imported_route.dart';
import 'road_routing.dart';
import 'route_progress.dart';

/// A routed candidate made from an imported line, plus the evidence the rider
/// needs before deciding whether it still represents the intended route.
class ImportedTrackMatch {
  const ImportedTrackMatch({
    required this.route,
    required this.matchedLengthMeters,
    required this.originalLengthMeters,
    required this.meanDeviationMeters,
    required this.maximumDeviationMeters,
  });

  final ImportedRoute route;

  /// Length of the road geometry the matcher returned.
  final double matchedLengthMeters;

  /// Length of the imported line it was matched against.
  final double originalLengthMeters;

  /// How much of the imported line the match accounts for.
  ///
  /// This replaced a `confidence` figure taken from OSRM's `/match`. Valhalla
  /// does not report one, and inventing a number to fill the same field would
  /// be worse than not having it: the two lengths are measured, mean what they
  /// say, and are what a rider can actually judge.
  double get lengthRatio => originalLengthMeters <= 0
      ? 0
      : matchedLengthMeters / originalLengthMeters;

  List<String> get reviewWarnings => [
    'The original imported line is shown in grey and remains in Saved routes.',
    'Road match ${(lengthRatio * 100).round()}% of the imported length · '
        '${meanDeviationMeters.round()} m average deviation · '
        '${maximumDeviationMeters.round()} m maximum deviation.',
  ];

  final double meanDeviationMeters;
  final double maximumDeviationMeters;
}

abstract interface class ImportedTrackMatcher {
  Future<ImportedTrackMatch> match(ImportedRoute original);
}

/// Turns an imported GPX track into road geometry and genuine manoeuvres using
/// Valhalla's `trace_route` map-matching endpoint.
///
/// **This replaced an OSRM `/match` implementation that could never work.** The
/// configured routing service is the public demo server, and its match endpoint
/// accepts **ten** trace coordinates; the app sent ninety, so every attempt
/// returned `400 TooBig` and "Generate navigable route" had never once
/// succeeded in production (#575). Chunking OSRM was not the answer either:
/// matching a 333 km day run at a usable density needs thousands of points,
/// which at ten per request is hundreds of calls to a public instance.
///
/// Valhalla was already here — `trace_attributes` powers the speed-limit
/// lookups and `/route` powers motorcycle routing — and its limit is a
/// different shape entirely. Measured against the live instance:
///
/// - the whole 333 km track is refused for **path distance**, not point count:
///   `Path distance exceeds the max distance limit: 200000 meters`;
/// - a 180 km segment matched **all 5292 of its native points** in half a
///   second, returning 77 manoeuvres and 180.1 km of geometry against 179.9 km
///   of raw track.
///
/// So the trace is split by distance and sent at full density. Nothing is
/// downsampled to fit a point budget, because the point budget was the wrong
/// constraint: ninety points over 296 km is a 2.8 km gap between samples, which
/// is not a GPS trace and would not match meaningfully even if it were accepted.
class ValhallaImportedTrackMatcher implements ImportedTrackMatcher {
  const ValhallaImportedTrackMatcher({
    required this.client,
    required this.traceUrl,
    this.timeout = const Duration(seconds: 40),
    this.maximumResponseBytes = 8 * 1024 * 1024,
    this.maximumChunkMeters = 150000,
    this.maximumChunkPoints = 5000,
    this.maximumConsecutiveStalls = 24,
    this.minimumLengthRatio = 0.9,
    this.maximumLengthRatio = 1.15,
    this.maximumMeanDeviationMeters = 35,
    this.maximumPointDeviationMeters = 150,
    this.uuid = const Uuid(),
    this.readMiniRoundabouts = bundledMiniRoundabouts,
  }) : assert(maximumChunkMeters > 0 && maximumChunkMeters <= 190000),
       assert(maximumChunkPoints >= 2);

  final http.Client client;
  final Uri traceUrl;
  final Duration timeout;
  final int maximumResponseBytes;

  /// How much matched path one request may cover.
  ///
  /// The measured service limit is 200 km. 150 km leaves room for the matched
  /// road being longer than the straight-line-summed trace that chose the
  /// split — a match that follows a road around what the trace cut across is
  /// the normal case, not an exception.
  final double maximumChunkMeters;

  /// A ceiling on points per request, independent of distance.
  ///
  /// Not a limit the service imposes — 5292 native points matched fine — but a
  /// bound on how much a pathological file can push in one body.
  final int maximumChunkPoints;

  /// How many trace points in a row may fail to match before giving up.
  ///
  /// A break is stepped over one point at a time; this bounds how long that
  /// can go on, so an unmatchable file ends rather than walking its whole
  /// length one request at a time.
  final int maximumConsecutiveStalls;

  /// How much of the imported line the match must account for.
  ///
  /// Both ends matter. Far short means the matcher lost the line; far over
  /// means it went somewhere the rider did not.
  final double minimumLengthRatio;
  final double maximumLengthRatio;

  final double maximumMeanDeviationMeters;
  final double maximumPointDeviationMeters;
  final Uuid uuid;

  /// Reads the bundled mini-roundabout layer; see [bundledMiniRoundabouts].
  final Future<MappedMiniRoundaboutCatalogue> Function() readMiniRoundabouts;

  @override
  Future<ImportedTrackMatch> match(ImportedRoute original) async {
    final sourcePaths = original.paths
        .where((path) => path.kind == RoutePathKind.track)
        .where((path) => path.points.length >= 2)
        .toList(growable: false);
    if (sourcePaths.isEmpty) {
      throw const FormatException(
        'This route does not contain a track that can be road matched.',
      );
    }
    if (traceUrl.scheme != 'https') {
      throw const FormatException('Road matching requires an HTTPS service.');
    }

    final miniRoundabouts = await readMiniRoundabouts();
    final matchedPaths = <RoutePath>[];
    final maneuvers = <RouteManeuver>[];
    final samples = <GeoPoint>[];
    var matchedLength = 0.0;
    var originalLength = 0.0;

    for (final sourcePath in sourcePaths) {
      samples.addAll(sourcePath.points);
      originalLength += polylineLengthMeters(sourcePath.points);

      final pathPoints = <GeoPoint>[];
      final pathManeuvers = <RoadRouteManeuver>[];
      // Walked rather than pre-chunked, because a recorded track contains
      // points map matching cannot get past and the service does not say so
      // — it silently returns the part it managed. Measured on the Scenic
      // day run: a 150 km window came back as 47.3 km, and the same 47.3 km
      // whether 50, 75 or 150 km was sent, so the stop is a place in the
      // track rather than anything about the request. Pre-chunking by
      // distance alone therefore loses whatever follows the first obstacle
      // in each chunk.
      //
      // So: match a window, work out how far along the trace the match
      // actually reached, and start the next window there — stepping over the
      // obstacle when no progress was made. No knowledge of *what* the
      // obstacle is, and none of where; a break is found by measurement.
      var index = 0;
      var stalls = 0;
      while (index < sourcePath.points.length - 1) {
        final window = _window(sourcePath.points, index);
        if (window.length < 2) break;
        final result = await _matchChunk(window);
        final reached = _traceIndexNearest(window, result.points.last);
        if (result.points.length >= 2 && reached >= 1) {
          matchedLength += result.distanceMeters;
          pathManeuvers.addAll(result.maneuvers);
          pathPoints.addAll(
            pathPoints.isEmpty ? result.points : result.points.skip(1),
          );
        }
        if (reached >= 1) {
          // Resume *on* the point the match reached, not past it: the next
          // window starts where this one stopped, so nothing between them is
          // dropped. Skipping one here as well cost a trace point per window,
          // which is invisible over a 150 km window and ruinous over a short
          // one.
          index += reached;
          stalls = 0;
        } else {
          // The window's very first points could not be matched. Step past
          // them rather than asking the same question again forever.
          index += 1;
          stalls += 1;
          if (stalls > maximumConsecutiveStalls) break;
        }
      }
      if (pathPoints.length < 2) {
        throw const FormatException(
          'The road match returned no usable geometry. '
          'The original line is unchanged.',
        );
      }
      matchedPaths.add(
        RoutePath(
          // Resolved road geometry. `route` means raw GPX points still needing
          // ordinary endpoint routing; `track` stops RouteGeometryEnricher
          // recalculating this reviewed match a second time.
          kind: RoutePathKind.track,
          name: sourcePath.name,
          points: List.unmodifiable(pathPoints),
        ),
      );
      maneuvers.addAll(
        miniRoundabouts.enrich(route: pathPoints, maneuvers: pathManeuvers),
      );
    }

    final ratio = originalLength <= 0 ? 0.0 : matchedLength / originalLength;
    if (ratio < minimumLengthRatio || ratio > maximumLengthRatio) {
      throw FormatException(
        'The road match came out ${(ratio * 100).round()}% of the imported '
        'length, which is too far from it to trust. '
        'The original line is unchanged.',
      );
    }

    final candidate = ImportedRoute(
      id: uuid.v4(),
      name: '${original.name} (navigable)',
      description: [
        if (original.description?.trim() case final description?
            when description.isNotEmpty)
          description,
        'Road-matched from ${original.sourceFileName}.',
      ].join('\n'),
      importedAt: DateTime.now().toUtc(),
      sourceFileName: 'matched-${original.sourceFileName}',
      paths: List.unmodifiable(matchedPaths),
      waypoints: original.waypoints,
      maneuvers: List.unmodifiable(maneuvers),
      preferences: original.preferences,
    );
    final deviations = [
      for (final point in samples) distanceToRouteMeters(candidate, point),
    ];
    final meanDeviation =
        deviations.fold<double>(0, (sum, value) => sum + value) /
        deviations.length;
    final maximumDeviation = deviations.reduce(math.max);
    if (meanDeviation > maximumMeanDeviationMeters ||
        maximumDeviation > maximumPointDeviationMeters) {
      throw FormatException(
        'The road route moved too far from the imported line '
        '(${meanDeviation.round()} m average, '
        '${maximumDeviation.round()} m maximum). '
        'The original line is unchanged.',
      );
    }

    return ImportedTrackMatch(
      route: candidate,
      matchedLengthMeters: matchedLength,
      originalLengthMeters: originalLength,
      meanDeviationMeters: meanDeviation,
      maximumDeviationMeters: maximumDeviation,
    );
  }

  /// The next slice to ask about, bounded by both service limits.
  List<GeoPoint> _window(List<GeoPoint> points, int start) {
    final window = <GeoPoint>[points[start]];
    var travelled = 0.0;
    for (var index = start + 1; index < points.length; index += 1) {
      travelled += metersBetween(points[index - 1], points[index]);
      if (travelled > maximumChunkMeters ||
          window.length >= maximumChunkPoints) {
        break;
      }
      window.add(points[index]);
    }
    return window;
  }

  /// Which point of [window] the matched geometry reached.
  ///
  /// The service reports no such index, so it is measured: the trace point
  /// closest to where the matched line stopped. That is what turns "it
  /// returned less than I sent" into "resume from here".
  static int _traceIndexNearest(List<GeoPoint> window, GeoPoint end) {
    var best = 0;
    var bestDistance = double.infinity;
    for (var index = 0; index < window.length; index += 1) {
      final distance = metersBetween(window[index], end);
      if (distance < bestDistance) {
        bestDistance = distance;
        best = index;
      }
    }
    return best;
  }

  Future<RoadRouteResult> _matchChunk(List<GeoPoint> shape) async {
    final response = await client
        .post(
          traceUrl,
          headers: const {
            'Accept': 'application/json',
            'Content-Type': 'application/json',
            'User-Agent': 'TailEndCharlie/1.0 (route matching)',
          },
          body: jsonEncode({
            'shape': [
              for (final point in shape)
                {'lat': point.latitude, 'lon': point.longitude},
            ],
            'costing': 'motorcycle',
            'shape_match': 'map_snap',
            'units': 'kilometers',
            'directions_options': {'units': 'kilometers'},
          }),
        )
        .timeout(timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      // Valhalla says why in the body. A bare status code is what sent a
      // rider "Road matching failed (400)" with nothing to act on (#575).
      throw FormatException(
        _serviceMessage(response.bodyBytes, response.statusCode),
      );
    }
    if (response.bodyBytes.length > maximumResponseBytes) {
      throw const FormatException('Road matching response is too large.');
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    final trip = decoded is Map ? decoded['trip'] : null;
    if (trip is! Map || trip['legs'] is! List) {
      throw FormatException(_serviceMessage(response.bodyBytes, null));
    }

    final points = <GeoPoint>[];
    final legShapeOffsets = <int>[];
    final rawLegManeuvers = <List<Object?>>[];
    for (final leg in trip['legs'] as List) {
      if (leg is! Map) continue;
      final legShape = ValhallaMotorcycleRoutingService.decodeValhallaShape(
        leg['shape'],
      );
      legShapeOffsets.add(points.isEmpty ? 0 : points.length - 1);
      rawLegManeuvers.add(
        leg['maneuvers'] is List ? leg['maneuvers'] as List : const [],
      );
      points.addAll(points.isEmpty ? legShape : legShape.skip(1));
    }
    if (points.length < 2) {
      throw const FormatException(
        'No road match was found. The original line is unchanged.',
      );
    }
    final summary = trip['summary'];
    final lengthKm = summary is Map ? summary['length'] : null;
    final seconds = summary is Map ? summary['time'] : null;
    return RoadRouteResult(
      points: List.unmodifiable(points),
      distanceMeters: lengthKm is num
          ? lengthKm.toDouble() * 1000
          : polylineLengthMeters(points),
      duration: Duration(
        milliseconds: seconds is num ? (seconds.toDouble() * 1000).round() : 0,
      ),
      maneuvers: ValhallaMotorcycleRoutingService.parseManeuvers(
        route: points,
        legManeuvers: rawLegManeuvers,
        legShapeOffsets: legShapeOffsets,
      ),
    );
  }

  /// The service's own words when it has any, so a failure is actionable.
  static String _serviceMessage(List<int> body, int? statusCode) {
    try {
      final decoded = jsonDecode(utf8.decode(body));
      if (decoded is Map) {
        final error = decoded['error'];
        if (error is String && error.trim().isNotEmpty) {
          return 'Road matching failed: ${error.trim()}';
        }
      }
    } on Object {
      // Fall through to the status code below.
    }
    return statusCode == null
        ? 'No road match was found. The original line is unchanged.'
        : 'Road matching failed ($statusCode).';
  }
}

/// Splits a trace into pieces the matching service will accept.
///
/// Consecutive chunks **share a point**: the last of one is the first of the
/// next, so the matched geometry joins without a gap and without a duplicate
/// when the caller skips the repeated head.
///
/// Bounded by distance first because that is the limit the service actually
/// imposes (200 km of path), and by point count second as a guard against a
/// pathological file rather than a service rule.
@visibleForTesting
List<List<GeoPoint>> chunkTrace(
  List<GeoPoint> points, {
  required double maximumMeters,
  required int maximumPoints,
}) {
  if (points.length < 2) return [List.unmodifiable(points)];
  final chunks = <List<GeoPoint>>[];
  var current = <GeoPoint>[points.first];
  var travelled = 0.0;
  for (var index = 1; index < points.length; index += 1) {
    final step = metersBetween(points[index - 1], points[index]);
    final wouldExceed =
        travelled + step > maximumMeters || current.length >= maximumPoints;
    if (wouldExceed && current.length >= 2) {
      chunks.add(List.unmodifiable(current));
      // Shared boundary point, so the next chunk starts where this one ended.
      current = <GeoPoint>[points[index - 1]];
      travelled = 0;
    }
    current.add(points[index]);
    travelled += step;
  }
  if (current.length >= 2) chunks.add(List.unmodifiable(current));
  return List.unmodifiable(chunks);
}

/// Great-circle distance in metres.
@visibleForTesting
double metersBetween(GeoPoint a, GeoPoint b) {
  const earthRadiusMeters = 6371000.0;
  final lat1 = a.latitude * math.pi / 180;
  final lat2 = b.latitude * math.pi / 180;
  final deltaLat = lat2 - lat1;
  final deltaLon = (b.longitude - a.longitude) * math.pi / 180;
  final h =
      math.sin(deltaLat / 2) * math.sin(deltaLat / 2) +
      math.cos(lat1) *
          math.cos(lat2) *
          math.sin(deltaLon / 2) *
          math.sin(deltaLon / 2);
  return 2 * earthRadiusMeters * math.asin(math.min(1, math.sqrt(h)));
}

/// Summed length of a polyline in metres.
@visibleForTesting
double polylineLengthMeters(List<GeoPoint> points) {
  var total = 0.0;
  for (var index = 1; index < points.length; index += 1) {
    total += metersBetween(points[index - 1], points[index]);
  }
  return total;
}
