import 'dart:convert';

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
    required this.confidence,
    required this.traceCoverage,
    required this.meanDeviationMeters,
    required this.maximumDeviationMeters,
  });

  final ImportedRoute route;
  final double confidence;
  final double traceCoverage;
  final double meanDeviationMeters;
  final double maximumDeviationMeters;

  List<String> get reviewWarnings => [
    'The original imported line is shown in grey and remains in Saved routes.',
    'Road match ${(confidence * 100).round()}% confidence · '
        '${(traceCoverage * 100).round()}% points matched · '
        '${meanDeviationMeters.round()} m average deviation · '
        '${maximumDeviationMeters.round()} m maximum deviation.',
  ];
}

abstract interface class ImportedTrackMatcher {
  Future<ImportedTrackMatch> match(ImportedRoute original);
}

/// Uses OSRM's Match service to turn a bounded sample of a GPX track into road
/// geometry and genuine routing manoeuvres.
///
/// Matching is deliberately stricter than drawing a line. A split, missing
/// tracepoints, low provider confidence or excessive movement from the source
/// is rejected before a candidate can reach the active route store.
class OsrmImportedTrackMatcher implements ImportedTrackMatcher {
  const OsrmImportedTrackMatcher({
    required this.client,
    required this.baseUrl,
    this.timeout = const Duration(seconds: 20),
    this.maximumResponseBytes = 4 * 1024 * 1024,
    this.maximumTracePoints = 90,
    this.minimumConfidence = 0.7,
    this.minimumTraceCoverage = 0.9,
    this.maximumMeanDeviationMeters = 35,
    this.maximumPointDeviationMeters = 150,
    this.uuid = const Uuid(),
    this.miniRoundabouts = MappedMiniRoundaboutCatalogue.fieldRegressions,
  }) : assert(maximumTracePoints >= 2 && maximumTracePoints <= 100),
       assert(minimumConfidence >= 0 && minimumConfidence <= 1),
       assert(minimumTraceCoverage >= 0 && minimumTraceCoverage <= 1);

  final http.Client client;
  final Uri baseUrl;
  final Duration timeout;
  final int maximumResponseBytes;
  final int maximumTracePoints;
  final double minimumConfidence;
  final double minimumTraceCoverage;
  final double maximumMeanDeviationMeters;
  final double maximumPointDeviationMeters;
  final Uuid uuid;
  final MappedMiniRoundaboutCatalogue miniRoundabouts;

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
    if (baseUrl.scheme != 'https') {
      throw const FormatException('Road matching requires an HTTPS service.');
    }

    final matchedPaths = <RoutePath>[];
    final maneuvers = <RouteManeuver>[];
    final samples = <GeoPoint>[];
    var confidence = 1.0;
    var matchedTracepoints = 0;

    for (final sourcePath in sourcePaths) {
      final pathSamples = _boundedSamples(
        sourcePath.points,
        maximumTracePoints,
      );
      samples.addAll(pathSamples);
      final response = await _matchPath(pathSamples);
      confidence = confidence < response.confidence
          ? confidence
          : response.confidence;
      matchedTracepoints += response.matchedTracepoints;
      matchedPaths.add(
        RoutePath(
          // This is now resolved road geometry. `route` means raw GPX route
          // points still needing ordinary endpoint routing; using `track`
          // prevents RouteGeometryEnricher from recalculating this reviewed
          // match a second time.
          kind: RoutePathKind.track,
          name: sourcePath.name,
          points: response.result.points,
        ),
      );
      maneuvers.addAll(
        miniRoundabouts.enrich(
          route: response.result.points,
          maneuvers: response.result.maneuvers,
        ),
      );
    }

    final coverage = matchedTracepoints / samples.length;
    if (confidence < minimumConfidence) {
      throw FormatException(
        'The road match was not confident enough '
        '(${(confidence * 100).round()}%). The original line is unchanged.',
      );
    }
    if (coverage < minimumTraceCoverage) {
      throw FormatException(
        'Too little of the imported line matched the road network '
        '(${(coverage * 100).round()}%). The original line is unchanged.',
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
    final maximumDeviation = deviations.reduce(
      (first, second) => first > second ? first : second,
    );
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
      confidence: confidence,
      traceCoverage: coverage,
      meanDeviationMeters: meanDeviation,
      maximumDeviationMeters: maximumDeviation,
    );
  }

  Future<({RoadRouteResult result, double confidence, int matchedTracepoints})>
  _matchPath(List<GeoPoint> samples) async {
    final coordinates = samples
        .map((point) => '${point.longitude},${point.latitude}')
        .join(';');
    final basePath = baseUrl.path == '/'
        ? ''
        : baseUrl.path.endsWith('/')
        ? baseUrl.path.substring(0, baseUrl.path.length - 1)
        : baseUrl.path;
    final uri = baseUrl.replace(
      path: '$basePath/match/v1/driving/$coordinates',
      queryParameters: {
        'overview': 'full',
        'geometries': 'geojson',
        'steps': 'true',
        'gaps': 'split',
        'tidy': 'true',
        'waypoints': '0;${samples.length - 1}',
      },
    );
    final response = await client
        .get(
          uri,
          headers: const {
            'Accept': 'application/json',
            'User-Agent': 'TailEndCharlie/1.0 (route matching)',
          },
        )
        .timeout(timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw FormatException('Road matching failed (${response.statusCode}).');
    }
    if (response.bodyBytes.length > maximumResponseBytes) {
      throw const FormatException('Road matching response is too large.');
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map || decoded['code'] != 'Ok') {
      final message = decoded is Map ? decoded['message'] : null;
      throw FormatException(
        message is String && message.trim().isNotEmpty
            ? message
            : 'No road match was found. The original line is unchanged.',
      );
    }
    final matchings = decoded['matchings'];
    if (matchings is! List || matchings.isEmpty) {
      throw const FormatException(
        'No road match was found. The original line is unchanged.',
      );
    }
    if (matchings.length != 1 || matchings.single is! Map) {
      throw const FormatException(
        'The road match split into separate routes. '
        'The original line is unchanged.',
      );
    }
    final rawMatching = Map<String, dynamic>.from(matchings.single as Map);
    final rawConfidence = rawMatching['confidence'];
    final tracepoints = decoded['tracepoints'];
    if (rawConfidence is! num ||
        tracepoints is! List ||
        tracepoints.length != samples.length) {
      throw const FormatException('The road match response was incomplete.');
    }
    return (
      result: OsrmRoadRoutingService.parseRoute(rawMatching),
      confidence: rawConfidence.toDouble().clamp(0, 1).toDouble(),
      matchedTracepoints: tracepoints.whereType<Map>().length,
    );
  }
}

List<GeoPoint> _boundedSamples(List<GeoPoint> points, int maximum) {
  if (points.length <= maximum) return List.unmodifiable(points);
  return List.unmodifiable([
    for (var index = 0; index < maximum; index += 1)
      points[((points.length - 1) * index / (maximum - 1)).round()],
  ]);
}
