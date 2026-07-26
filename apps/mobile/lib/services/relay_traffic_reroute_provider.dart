import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../domain/hazard.dart';
import '../domain/imported_route.dart';
import '../internet/internet_relay_client.dart';
import 'enforcement_alert_detector.dart';

typedef TrafficHttpPost =
    Future<http.Response> Function(
      Uri uri, {
      Map<String, String>? headers,
      Object? body,
      Encoding? encoding,
    });

class TrafficReroutePreview {
  const TrafficReroutePreview({
    required this.route,
    required this.incidentIds,
    required this.provider,
    required this.calculatedAt,
    required this.referenceDistanceMeters,
    required this.referenceDuration,
    required this.alternativeDistanceMeters,
    required this.alternativeDuration,
    required this.trafficDelaySaved,
  });

  final ImportedRoute route;
  final List<String> incidentIds;
  final String provider;
  final DateTime calculatedAt;
  final double referenceDistanceMeters;
  final Duration referenceDuration;
  final double alternativeDistanceMeters;
  final Duration alternativeDuration;
  final Duration trafficDelaySaved;

  double get distanceDeltaMeters =>
      alternativeDistanceMeters - referenceDistanceMeters;

  Duration get durationDelta => alternativeDuration - referenceDuration;
}

class TrafficRerouteSuppression {
  const TrafficRerouteSuppression({
    required this.incidentFingerprint,
    required this.until,
  });

  factory TrafficRerouteSuppression.forHazards(List<HazardReport> hazards) {
    if (hazards.isEmpty) {
      throw ArgumentError.value(
        hazards,
        'hazards',
        'Cannot suppress no hazards',
      );
    }
    return TrafficRerouteSuppression(
      incidentFingerprint: trafficIncidentFingerprint(hazards)!,
      until: hazards
          .map((hazard) => hazard.expiresAt)
          .reduce((first, second) => first.isAfter(second) ? first : second),
    );
  }

  final String incidentFingerprint;
  final DateTime until;

  bool suppresses(List<HazardReport> hazards, DateTime now) =>
      until.isAfter(now) &&
      incidentFingerprint == trafficIncidentFingerprint(hazards);

  String encode() => jsonEncode({
    'fingerprint': incidentFingerprint,
    'until': until.toUtc().toIso8601String(),
  });

  static TrafficRerouteSuppression? tryDecode(String value) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is! Map) return null;
      final fingerprint = decoded['fingerprint'];
      final until = DateTime.tryParse('${decoded['until'] ?? ''}');
      if (fingerprint is! String || fingerprint.isEmpty || until == null) {
        return null;
      }
      return TrafficRerouteSuppression(
        incidentFingerprint: fingerprint,
        until: until,
      );
    } on Object {
      return null;
    }
  }
}

String? trafficIncidentFingerprint(List<HazardReport> hazards) {
  if (hazards.isEmpty) return null;
  final ids = hazards.map((hazard) => hazard.id).toSet().toList()..sort();
  return ids.join('|');
}

class RelayTrafficRerouteProvider {
  RelayTrafficRerouteProvider({
    required this.configuration,
    TrafficHttpPost? httpPost,
    DateTime Function()? clock,
    String Function()? idFactory,
    this.maximumResponseBytes = 1024 * 1024,
  }) : _httpPost = httpPost ?? http.post,
       _clock = clock ?? DateTime.now,
       _idFactory = idFactory ?? const Uuid().v7;

  final InternetRelayConfiguration configuration;
  final TrafficHttpPost _httpPost;
  final DateTime Function() _clock;
  final String Function() _idFactory;
  final int maximumResponseBytes;

  Future<TrafficReroutePreview> preview({
    required ImportedRoute route,
    required GeoPoint? currentPosition,
    required List<HazardReport> hazards,
  }) async {
    final baseUri = configuration.baseUri;
    if (!configuration.isConfigured || baseUri == null) {
      throw FormatException(
        configuration.configurationError ??
            'Live UK traffic rerouting is not configured.',
      );
    }
    final relevant = hazards
        .where(
          (hazard) =>
              hazard.source == HazardSource.externalProvider &&
              hazard.providerId == 'tomtom-traffic' &&
              // Enforcement reports warn the rider; they never justify
              // recalculating the group's route around them.
              !enforcementHazardTypes.contains(hazard.type) &&
              hazard.isActiveAt(_clock()) &&
              hazard.severity.index >= HazardSeverity.serious.index,
        )
        .take(10)
        .toList(growable: false);
    if (relevant.isEmpty) {
      throw const FormatException(
        'No current serious route incident needs an alternative.',
      );
    }
    final path = _remainingPath(route, currentPosition);
    if (path.length < 2) {
      throw const FormatException(
        'The remaining route is too short to calculate an alternative.',
      );
    }
    final sampledPath = _samplePath(path, maximumPoints: 800);
    final incidentIds = relevant.map((hazard) => hazard.id).toList()..sort();
    final payload = jsonEncode({
      'path': [
        for (final point in sampledPath)
          {'latitude': point.latitude, 'longitude': point.longitude},
      ],
      'avoidAreas': [
        for (final hazard in relevant)
          _avoidArea(
            latitude: hazard.position.latitude,
            longitude: hazard.position.longitude,
          ),
      ],
      'incidentIds': incidentIds,
    });
    if (utf8.encode(payload).length > configuration.maximumRequestBytes) {
      throw const FormatException(
        'The remaining route is too large for one traffic review.',
      );
    }

    final response = await _httpPost(
      _rerouteUri(baseUri),
      headers: {
        'accept': 'application/json',
        'content-type': 'application/json',
        ...RelayClientDescriptor.current().headers,
      },
      body: payload,
    ).timeout(configuration.headerTimeout + configuration.bodyTimeout);
    if (response.bodyBytes.length > maximumResponseBytes) {
      throw const FormatException('Traffic reroute response was too large.');
    }
    final body = _jsonObject(response.bodyBytes);
    if (response.statusCode != 200) {
      throw FormatException(
        body['message'] as String? ??
            body['error'] as String? ??
            'No traffic-aware alternative is currently available.',
      );
    }
    return _previewFromResponse(
      body,
      original: route,
      expectedIncidentIds: incidentIds,
    );
  }

  TrafficReroutePreview _previewFromResponse(
    Map<String, Object?> body, {
    required ImportedRoute original,
    required List<String> expectedIncidentIds,
  }) {
    final provider = body['provider'];
    final calculatedAt = DateTime.tryParse('${body['calculatedAt'] ?? ''}');
    final responseIncidentIds = (body['incidentIds'] as List?)
        ?.whereType<String>()
        .toList(growable: false);
    final reference = _routeSummary(body['reference']);
    final alternative = _routeSummary(body['alternative']);
    if (provider is! String ||
        provider != 'tomtom-orbis' ||
        calculatedAt == null ||
        responseIncidentIds == null ||
        !_sameValues(responseIncidentIds, expectedIncidentIds) ||
        reference == null ||
        alternative == null) {
      throw const FormatException('Traffic reroute response was invalid.');
    }
    final now = calculatedAt.toUtc();
    final destination = original.waypoints.lastOrNull;
    final destinationPoint = alternative.points.last;
    final route = ImportedRoute(
      id: _idFactory(),
      name: '${original.name} · traffic alternative',
      description:
          'Leader-reviewed TomTom traffic alternative calculated '
          '${now.toIso8601String()}.',
      importedAt: now,
      sourceFileName: 'tail-end-charlie-traffic-${_idFactory()}.gpx',
      paths: [
        RoutePath(
          kind: RoutePathKind.route,
          name: 'Traffic-aware alternative',
          points: alternative.points,
        ),
      ],
      waypoints: [
        RouteWaypoint(
          point: alternative.points.first,
          name: 'Alternative start',
          symbol: 'Flag, Blue',
        ),
        RouteWaypoint(
          point: destinationPoint,
          name: destination?.name ?? 'Destination',
          description: destination?.description,
          symbol: 'Flag, Red',
        ),
      ],
      maneuvers: alternative.maneuvers,
    );
    final delaySavedSeconds = math.max(
      0,
      reference.trafficDelaySeconds - alternative.trafficDelaySeconds,
    );
    return TrafficReroutePreview(
      route: route,
      incidentIds: List.unmodifiable(responseIncidentIds),
      provider: provider,
      calculatedAt: now,
      referenceDistanceMeters: reference.distanceMeters,
      referenceDuration: Duration(seconds: reference.durationSeconds),
      alternativeDistanceMeters: alternative.distanceMeters,
      alternativeDuration: Duration(seconds: alternative.durationSeconds),
      trafficDelaySaved: Duration(seconds: delaySavedSeconds),
    );
  }

  static Uri _rerouteUri(Uri baseUri) {
    final basePath = baseUri.path.replaceFirst(RegExp(r'/$'), '');
    return baseUri.replace(
      path: '$basePath/v1/traffic/reroutes',
      queryParameters: null,
      fragment: null,
    );
  }
}

class _TrafficRouteSummary {
  const _TrafficRouteSummary({
    required this.distanceMeters,
    required this.durationSeconds,
    required this.trafficDelaySeconds,
    required this.points,
    required this.maneuvers,
  });

  final double distanceMeters;
  final int durationSeconds;
  final int trafficDelaySeconds;
  final List<GeoPoint> points;
  final List<RouteManeuver> maneuvers;
}

_TrafficRouteSummary? _routeSummary(Object? raw) {
  if (raw is! Map) return null;
  final map = Map<String, Object?>.from(raw);
  final distance = map['distanceMeters'];
  final duration = map['travelDurationSeconds'];
  final delay = map['trafficDelaySeconds'];
  final rawPoints = map['points'];
  final rawManeuvers = map['maneuvers'];
  if (distance is! num ||
      duration is! num ||
      delay is! num ||
      rawPoints is! List ||
      rawManeuvers is! List) {
    return null;
  }
  try {
    final points = rawPoints
        .whereType<Map>()
        .map((point) => GeoPoint.fromJson(Map<String, Object?>.from(point)))
        .toList(growable: false);
    final maneuvers = rawManeuvers
        .whereType<Map>()
        .map(
          (maneuver) =>
              RouteManeuver.fromJson(Map<String, Object?>.from(maneuver)),
        )
        .toList(growable: false);
    if (points.length < 2) return null;
    return _TrafficRouteSummary(
      distanceMeters: distance.toDouble(),
      durationSeconds: duration.toInt(),
      trafficDelaySeconds: delay.toInt(),
      points: points,
      maneuvers: maneuvers,
    );
  } on Object {
    return null;
  }
}

List<GeoPoint> _remainingPath(ImportedRoute route, GeoPoint? currentPosition) {
  final candidates = route.paths
      .where((path) => path.points.length >= 2)
      .toList(growable: false);
  if (candidates.isEmpty) return const [];
  final path = candidates.reduce(
    (current, next) =>
        next.points.length > current.points.length ? next : current,
  );
  if (currentPosition == null) return path.points;
  var nearestIndex = 0;
  var nearestDistance = double.infinity;
  for (var index = 0; index < path.points.length; index += 1) {
    final distance = _distanceMeters(currentPosition, path.points[index]);
    if (distance < nearestDistance) {
      nearestDistance = distance;
      nearestIndex = index;
    }
  }
  final remaining = path.points.sublist(nearestIndex);
  if (remaining.length < 2) return remaining;
  if (_distanceMeters(currentPosition, remaining.first) < 5) return remaining;
  return [currentPosition, ...remaining];
}

List<GeoPoint> _samplePath(List<GeoPoint> path, {required int maximumPoints}) {
  if (path.length <= maximumPoints) return path;
  final stride = (path.length / maximumPoints).ceil();
  final sampled = <GeoPoint>[
    for (var index = 0; index < path.length; index += stride) path[index],
  ];
  if (sampled.last != path.last) sampled.add(path.last);
  return sampled;
}

Map<String, double> _avoidArea({
  required double latitude,
  required double longitude,
}) {
  // The signed event deliberately stores only the route-correlated point,
  // rather than redistributing a provider's full incident geometry.
  // A compact rectangle gives the server routing request a bounded exclusion.
  const paddingMeters = 150.0;
  final latitudePadding = paddingMeters / 111320;
  final longitudePadding =
      latitudePadding / math.max(0.2, math.cos(latitude * math.pi / 180).abs());
  return {
    'west': longitude - longitudePadding,
    'south': latitude - latitudePadding,
    'east': longitude + longitudePadding,
    'north': latitude + latitudePadding,
  };
}

double _distanceMeters(GeoPoint first, GeoPoint second) {
  const earthRadiusMeters = 6371000.0;
  final latitude1 = first.latitude * math.pi / 180;
  final latitude2 = second.latitude * math.pi / 180;
  final latitudeDelta = (second.latitude - first.latitude) * math.pi / 180;
  final longitudeDelta = (second.longitude - first.longitude) * math.pi / 180;
  final haversine =
      math.sin(latitudeDelta / 2) * math.sin(latitudeDelta / 2) +
      math.cos(latitude1) *
          math.cos(latitude2) *
          math.sin(longitudeDelta / 2) *
          math.sin(longitudeDelta / 2);
  return earthRadiusMeters *
      2 *
      math.atan2(math.sqrt(haversine), math.sqrt(1 - haversine));
}

Map<String, Object?> _jsonObject(List<int> bytes) {
  try {
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is Map) return Map<String, Object?>.from(decoded);
  } on Object {
    // Converted to one bounded user-facing error below.
  }
  throw const FormatException('Traffic reroute response was invalid.');
}

bool _sameValues(List<String> first, List<String> second) {
  final firstSorted = [...first]..sort();
  final secondSorted = [...second]..sort();
  if (firstSorted.length != secondSorted.length) return false;
  for (var index = 0; index < firstSorted.length; index += 1) {
    if (firstSorted[index] != secondSorted[index]) return false;
  }
  return true;
}
