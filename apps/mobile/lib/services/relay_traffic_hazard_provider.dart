import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../domain/geo_point.dart';
import '../domain/hazard.dart';
import '../internet/internet_relay_client.dart';
import 'external_hazard_provider.dart';

typedef TrafficHttpGet =
    Future<http.Response> Function(Uri uri, {Map<String, String>? headers});

class RelayTrafficHazardProvider implements ExternalHazardProvider {
  RelayTrafficHazardProvider({
    required this.configuration,
    TrafficHttpGet? httpGet,
    DateTime Function()? clock,
    this.maximumResponseBytes = 512 * 1024,
  }) : _httpGet = httpGet ?? http.get,
       _clock = clock ?? DateTime.now,
       _status = ExternalHazardProviderStatus(
         state: configuration.isConfigured
             ? ExternalHazardProviderState.configured
             : ExternalHazardProviderState.needsConfiguration,
         message:
             configuration.configurationError ??
             'Live UK traffic incidents are ready to refresh.',
       );

  final InternetRelayConfiguration configuration;
  final TrafficHttpGet _httpGet;
  final DateTime Function() _clock;
  final int maximumResponseBytes;

  ExternalHazardProviderStatus _status;

  @override
  String get id => 'tomtom-traffic';

  @override
  String get displayName => 'Live UK traffic';

  @override
  ExternalHazardProviderStatus get status => _status;

  @override
  Future<ExternalHazardFetchResult> fetch(ExternalHazardQuery query) async {
    if (!configuration.isConfigured || configuration.baseUri == null) {
      return ExternalHazardFetchResult(status: _status);
    }
    final route = query.route
        .where(_isWithinUkCoverage)
        .toList(growable: false);
    if (route.length < 2) {
      _status = ExternalHazardProviderStatus(
        state: ExternalHazardProviderState.ready,
        message: 'Live incidents are currently available for UK routes only.',
        lastUpdatedAt: _clock(),
      );
      return ExternalHazardFetchResult(status: _status);
    }

    _status = const ExternalHazardProviderStatus(
      state: ExternalHazardProviderState.loading,
      message: 'Refreshing route-relevant incidents…',
    );
    try {
      final responses = <Map<String, Object?>>[];
      DateTime? newestFetch;
      for (final bounds in _queryBounds(route, query.corridorMeters)) {
        final response = await _httpGet(
          _incidentUri(configuration.baseUri!, bounds),
          headers: {
            'accept': 'application/json',
            ...RelayClientDescriptor.current().headers,
          },
        ).timeout(configuration.headerTimeout + configuration.bodyTimeout);
        if (response.statusCode == 503) {
          final body = _jsonObject(response.bodyBytes);
          final code = body['code'];
          _status = ExternalHazardProviderStatus(
            state: code == 'traffic_provider_unconfigured'
                ? ExternalHazardProviderState.needsConfiguration
                : ExternalHazardProviderState.failed,
            message:
                body['message'] as String? ?? 'Live traffic is unavailable.',
          );
          return ExternalHazardFetchResult(status: _status);
        }
        if (response.statusCode != 200) {
          throw const FormatException('Live traffic could not be refreshed.');
        }
        if (response.bodyBytes.length > maximumResponseBytes) {
          throw const FormatException('Live traffic response was too large.');
        }
        final body = _jsonObject(response.bodyBytes);
        if (body['provider'] != 'tomtom-orbis' ||
            body['incidents'] is! List<Object?>) {
          throw const FormatException('Live traffic response was invalid.');
        }
        final fetchedAt = _parseDate(body['fetchedAt']) ?? _clock();
        if (newestFetch == null || fetchedAt.isAfter(newestFetch)) {
          newestFetch = fetchedAt;
        }
        responses.add(body);
      }

      final sampledRoute = _sampleRoute(route, maximumPoints: 800);
      final hazards = <String, HazardReport>{};
      for (final response in responses) {
        final fetchedAt = _parseDate(response['fetchedAt']) ?? _clock();
        for (final raw in response['incidents']! as List<Object?>) {
          final incident = _incidentMap(raw);
          if (incident == null) continue;
          final closest = _closestPointToRoute(incident.geometry, sampledRoute);
          if (closest == null ||
              closest.distanceMeters > query.corridorMeters) {
            continue;
          }
          final observedAt = incident.observedAt ?? fetchedAt;
          final expiresAt =
              incident.expiresAt ?? fetchedAt.add(const Duration(minutes: 10));
          if (!expiresAt.isAfter(query.requestedAt)) continue;
          hazards[incident.id] = HazardReport(
            id: 'tomtom-${incident.id}',
            rideId: query.rideId,
            type: incident.type,
            severity: incident.severity,
            position: closest.point,
            reportedAt: observedAt,
            updatedAt: fetchedAt,
            expiresAt: expiresAt,
            reporterId: id,
            reporterName: displayName,
            source: HazardSource.externalProvider,
            providerId: id,
            details:
                '${incident.description} · TomTom · '
                'updated ${_freshnessLabel(fetchedAt, query.requestedAt)}',
            confirmations: math.max(1, incident.reportCount ?? 1),
          );
        }
      }
      final updatedAt = newestFetch ?? _clock();
      _status = ExternalHazardProviderStatus(
        state: ExternalHazardProviderState.ready,
        message: hazards.isEmpty
            ? 'No current incidents intersect this route corridor.'
            : '${hazards.length} route-relevant '
                  '${hazards.length == 1 ? 'incident' : 'incidents'} · '
                  'TomTom',
        lastUpdatedAt: updatedAt,
      );
      return ExternalHazardFetchResult(
        status: _status,
        hazards: hazards.values.toList(growable: false),
      );
    } on Object {
      _status = ExternalHazardProviderStatus(
        state: ExternalHazardProviderState.failed,
        message:
            'Live traffic could not be refreshed. Existing reports remain '
            'until their stated expiry.',
      );
      return ExternalHazardFetchResult(status: _status);
    }
  }

  static Uri _incidentUri(Uri baseUri, _TrafficBounds bounds) {
    final basePath = baseUri.path.replaceFirst(RegExp(r'/$'), '');
    return baseUri.replace(
      path: '$basePath/v1/traffic/incidents',
      queryParameters: {
        'west': _coordinate(bounds.west),
        'south': _coordinate(bounds.south),
        'east': _coordinate(bounds.east),
        'north': _coordinate(bounds.north),
      },
    );
  }
}

class _TrafficIncident {
  const _TrafficIncident({
    required this.id,
    required this.type,
    required this.severity,
    required this.description,
    required this.geometry,
    this.observedAt,
    this.expiresAt,
    this.reportCount,
  });

  final String id;
  final HazardType type;
  final HazardSeverity severity;
  final String description;
  final List<GeoPoint> geometry;
  final DateTime? observedAt;
  final DateTime? expiresAt;
  final int? reportCount;
}

class _ClosestPoint {
  const _ClosestPoint(this.point, this.distanceMeters);

  final GeoPoint point;
  final double distanceMeters;
}

class _TrafficBounds {
  const _TrafficBounds(this.west, this.south, this.east, this.north);

  final double west;
  final double south;
  final double east;
  final double north;

  double get areaSquareKilometers {
    final latitudeKm = (north - south) * 111.32;
    final longitudeKm =
        (east - west) *
        111.32 *
        math.cos(((south + north) / 2) * math.pi / 180);
    return latitudeKm * longitudeKm;
  }
}

Map<String, Object?> _jsonObject(List<int> bytes) {
  final decoded = jsonDecode(utf8.decode(bytes));
  if (decoded is! Map<String, Object?>) {
    throw const FormatException('Expected a JSON object.');
  }
  return decoded;
}

_TrafficIncident? _incidentMap(Object? raw) {
  if (raw is! Map<String, Object?>) return null;
  final id = raw['id'];
  final type = raw['type'];
  final severity = raw['severity'];
  final description = raw['description'];
  final geometry = raw['geometry'];
  if (id is! String ||
      type is! String ||
      severity is! String ||
      description is! String ||
      geometry is! List<Object?>) {
    return null;
  }
  final points = geometry
      .map((item) {
        if (item is! Map<String, Object?>) return null;
        final latitude = item['latitude'];
        final longitude = item['longitude'];
        if (latitude is! num || longitude is! num) return null;
        try {
          return GeoPoint(
            latitude: latitude.toDouble(),
            longitude: longitude.toDouble(),
          );
        } on ArgumentError {
          return null;
        }
      })
      .whereType<GeoPoint>()
      .toList(growable: false);
  if (points.isEmpty) return null;
  HazardType hazardType;
  HazardSeverity hazardSeverity;
  try {
    hazardType = HazardType.values.byName(type);
    hazardSeverity = HazardSeverity.values.byName(severity);
  } on ArgumentError {
    return null;
  }
  return _TrafficIncident(
    id: id,
    type: hazardType,
    severity: hazardSeverity,
    description: description,
    geometry: points,
    observedAt: _parseDate(raw['observedAt']),
    expiresAt: _parseDate(raw['expiresAt']),
    reportCount: (raw['reportCount'] as num?)?.toInt(),
  );
}

List<_TrafficBounds> _queryBounds(List<GeoPoint> route, double corridorMeters) {
  final paddingLatitude = corridorMeters / 111320;
  final result = <_TrafficBounds>[];
  var chunk = <GeoPoint>[];
  for (final point in route) {
    final candidate = [...chunk, point];
    final bounds = _boundsFor(candidate, paddingLatitude);
    if (chunk.length >= 2 && bounds.areaSquareKilometers > 9000) {
      result.add(_boundsFor(chunk, paddingLatitude));
      chunk = [chunk.last, point];
    } else {
      chunk = candidate;
    }
  }
  if (chunk.length >= 2) result.add(_boundsFor(chunk, paddingLatitude));
  if (result.length > 8) {
    throw const FormatException(
      'The route is too large for one live incident refresh.',
    );
  }
  return result;
}

_TrafficBounds _boundsFor(List<GeoPoint> points, double paddingLatitude) {
  var west = points.first.longitude;
  var east = west;
  var south = points.first.latitude;
  var north = south;
  for (final point in points.skip(1)) {
    west = math.min(west, point.longitude);
    east = math.max(east, point.longitude);
    south = math.min(south, point.latitude);
    north = math.max(north, point.latitude);
  }
  final midpointLatitude = (south + north) / 2;
  final longitudeScale = math.max(
    0.2,
    math.cos(midpointLatitude * math.pi / 180),
  );
  final paddingLongitude = paddingLatitude / longitudeScale;
  return _TrafficBounds(
    math.max(-11.5, west - paddingLongitude),
    math.max(49.0, south - paddingLatitude),
    math.min(3.0, east + paddingLongitude),
    math.min(61.5, north + paddingLatitude),
  );
}

List<GeoPoint> _sampleRoute(
  List<GeoPoint> route, {
  required int maximumPoints,
}) {
  if (route.length <= maximumPoints) return route;
  final stride = (route.length / maximumPoints).ceil();
  final sampled = <GeoPoint>[
    for (var index = 0; index < route.length; index += stride) route[index],
  ];
  if (sampled.last != route.last) sampled.add(route.last);
  return sampled;
}

_ClosestPoint? _closestPointToRoute(
  List<GeoPoint> incident,
  List<GeoPoint> route,
) {
  if (route.length < 2) return null;
  _ClosestPoint? closest;
  for (final point in incident) {
    for (var index = 1; index < route.length; index++) {
      final distance = _pointToSegmentMeters(
        point,
        route[index - 1],
        route[index],
      );
      if (closest == null || distance < closest.distanceMeters) {
        closest = _ClosestPoint(point, distance);
      }
    }
  }
  return closest;
}

double _pointToSegmentMeters(GeoPoint point, GeoPoint start, GeoPoint end) {
  const earthRadius = 6371000.0;
  final referenceLatitude =
      ((point.latitude + start.latitude + end.latitude) / 3) * math.pi / 180;
  ({double x, double y}) project(GeoPoint value) => (
    x:
        value.longitude *
        math.pi /
        180 *
        earthRadius *
        math.cos(referenceLatitude),
    y: value.latitude * math.pi / 180 * earthRadius,
  );
  final projectedPoint = project(point);
  final projectedStart = project(start);
  final projectedEnd = project(end);
  final dx = projectedEnd.x - projectedStart.x;
  final dy = projectedEnd.y - projectedStart.y;
  final lengthSquared = dx * dx + dy * dy;
  final fraction = lengthSquared == 0
      ? 0.0
      : ((projectedPoint.x - projectedStart.x) * dx +
                (projectedPoint.y - projectedStart.y) * dy) /
            lengthSquared;
  final clamped = fraction.clamp(0.0, 1.0);
  final nearestX = projectedStart.x + clamped * dx;
  final nearestY = projectedStart.y + clamped * dy;
  return math.sqrt(
    math.pow(projectedPoint.x - nearestX, 2) +
        math.pow(projectedPoint.y - nearestY, 2),
  );
}

bool _isWithinUkCoverage(GeoPoint point) =>
    point.longitude >= -11.5 &&
    point.longitude <= 3.0 &&
    point.latitude >= 49.0 &&
    point.latitude <= 61.5;

DateTime? _parseDate(Object? value) {
  if (value is! String || value.isEmpty) return null;
  return DateTime.tryParse(value)?.toLocal();
}

String _coordinate(double value) =>
    value.toStringAsFixed(6).replaceFirst(RegExp(r'\.?0+$'), '');

String _freshnessLabel(DateTime fetchedAt, DateTime now) {
  final age = now.difference(fetchedAt);
  if (age.inMinutes < 1) return 'just now';
  if (age.inHours < 1) return '${age.inMinutes} min ago';
  return '${age.inHours} h ago';
}
