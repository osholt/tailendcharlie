import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../domain/imported_route.dart';

enum SpeedLimitLookupOutcome {
  known,
  noTaggedLimit,
  poorAccuracy,
  poorMatch,
  unsupportedRegion,
  unavailable,
}

class SpeedLimitLocation {
  const SpeedLimitLocation({
    required this.point,
    required this.recordedAt,
    this.accuracyMeters,
    this.headingDegrees,
  });

  final GeoPoint point;
  final DateTime recordedAt;
  final double? accuracyMeters;
  final double? headingDegrees;
}

class PostedSpeedLimit {
  const PostedSpeedLimit({
    required this.milesPerHour,
    required this.source,
    required this.checkedAt,
    required this.matchDistanceMeters,
    this.roadName,
  });

  final int milesPerHour;
  final String source;
  final DateTime checkedAt;
  final double matchDistanceMeters;
  final String? roadName;
}

class SpeedLimitLookupResult {
  const SpeedLimitLookupResult._(this.outcome, this.limit);

  const SpeedLimitLookupResult.known(PostedSpeedLimit limit)
    : this._(SpeedLimitLookupOutcome.known, limit);

  const SpeedLimitLookupResult.unknown(SpeedLimitLookupOutcome lookupOutcome)
    : assert(lookupOutcome != SpeedLimitLookupOutcome.known),
      outcome = lookupOutcome,
      limit = null;

  final SpeedLimitLookupOutcome outcome;
  final PostedSpeedLimit? limit;
}

abstract interface class SpeedLimitProvider {
  Future<SpeedLimitLookupResult> lookup({
    required SpeedLimitLocation previous,
    required SpeedLimitLocation current,
  });

  void close();
}

class UnavailableSpeedLimitProvider implements SpeedLimitProvider {
  const UnavailableSpeedLimitProvider();

  @override
  Future<SpeedLimitLookupResult> lookup({
    required SpeedLimitLocation previous,
    required SpeedLimitLocation current,
  }) async =>
      const SpeedLimitLookupResult.unknown(SpeedLimitLookupOutcome.unavailable);

  @override
  void close() {}
}

class ValhallaSpeedLimitConfiguration {
  const ValhallaSpeedLimitConfiguration({
    required this.lookupUri,
    this.timeout = const Duration(seconds: 8),
  });

  factory ValhallaSpeedLimitConfiguration.fromEnvironment() {
    const raw = String.fromEnvironment(
      'RIDE_RELAY_SPEED_LIMIT_URL',
      defaultValue: 'https://valhalla1.openstreetmap.de/trace_attributes',
    );
    final parsed = Uri.tryParse(raw.trim());
    return ValhallaSpeedLimitConfiguration(
      lookupUri:
          parsed != null &&
              parsed.scheme == 'https' &&
              parsed.host.isNotEmpty &&
              parsed.userInfo.isEmpty &&
              !parsed.hasQuery &&
              !parsed.hasFragment
          ? parsed
          : null,
    );
  }

  final Uri? lookupUri;
  final Duration timeout;
}

class ValhallaSpeedLimitProvider implements SpeedLimitProvider {
  ValhallaSpeedLimitProvider({
    required this.configuration,
    http.Client? client,
    DateTime Function()? clock,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       _clock = clock ?? DateTime.now;

  static const sourceLabel = 'OpenStreetMap via Valhalla';
  static const _maximumResponseBytes = 256 * 1024;
  static const _acceptedUkLimitsMph = {20, 30, 40, 50, 60, 70};

  final ValhallaSpeedLimitConfiguration configuration;
  final http.Client _client;
  final bool _ownsClient;
  final DateTime Function() _clock;

  @override
  Future<SpeedLimitLookupResult> lookup({
    required SpeedLimitLocation previous,
    required SpeedLimitLocation current,
  }) async {
    final endpoint = configuration.lookupUri;
    if (endpoint == null) {
      return const SpeedLimitLookupResult.unknown(
        SpeedLimitLookupOutcome.unavailable,
      );
    }
    if (!_isInUnitedKingdom(previous.point) ||
        !_isInUnitedKingdom(current.point)) {
      return const SpeedLimitLookupResult.unknown(
        SpeedLimitLookupOutcome.unsupportedRegion,
      );
    }
    final accuracy = current.accuracyMeters;
    if (accuracy != null &&
        (!accuracy.isFinite || accuracy < 0 || accuracy > 50)) {
      return const SpeedLimitLookupResult.unknown(
        SpeedLimitLookupOutcome.poorAccuracy,
      );
    }
    if (_distanceMeters(previous.point, current.point) < 4) {
      return const SpeedLimitLookupResult.unknown(
        SpeedLimitLookupOutcome.poorMatch,
      );
    }

    try {
      final response = await _client
          .post(
            endpoint,
            headers: const {
              'accept': 'application/json',
              'content-type': 'application/json',
              'user-agent': 'TailEndCharlie/0.1 speed-limit-display',
              'x-client-id': 'tailendcharlie.app',
            },
            body: jsonEncode({
              'shape': [
                {
                  'lat': previous.point.latitude,
                  'lon': previous.point.longitude,
                },
                {'lat': current.point.latitude, 'lon': current.point.longitude},
              ],
              'costing': 'motorcycle',
              'shape_match': 'map_snap',
              'trace_options': {
                'gps_accuracy': (accuracy ?? 15).clamp(5, 50),
                'search_radius': ((accuracy ?? 15) * 1.8).clamp(20, 60),
              },
              'filters': {
                'action': 'include',
                'attributes': [
                  'edge.names',
                  'edge.speed_limit',
                  'edge.speed_type',
                  'edge.begin_heading',
                  'edge.end_heading',
                  'node.admin_index',
                  'admin.country_code',
                  'matched.edge_index',
                  'matched.distance_from_trace_point',
                  'matched.type',
                ],
              },
            }),
          )
          .timeout(configuration.timeout);
      if (response.statusCode < 200 ||
          response.statusCode >= 300 ||
          response.bodyBytes.length > _maximumResponseBytes) {
        return const SpeedLimitLookupResult.unknown(
          SpeedLimitLookupOutcome.unavailable,
        );
      }
      return _parse(
        jsonDecode(utf8.decode(response.bodyBytes)),
        previous: previous,
        current: current,
      );
    } on Object {
      return const SpeedLimitLookupResult.unknown(
        SpeedLimitLookupOutcome.unavailable,
      );
    }
  }

  SpeedLimitLookupResult _parse(
    Object? decoded, {
    required SpeedLimitLocation previous,
    required SpeedLimitLocation current,
  }) {
    if (decoded is! Map ||
        decoded['edges'] is! List ||
        decoded['admins'] is! List ||
        decoded['matched_points'] is! List ||
        decoded['units'] != 'kilometers') {
      return const SpeedLimitLookupResult.unknown(
        SpeedLimitLookupOutcome.unavailable,
      );
    }
    final edges = decoded['edges'] as List;
    final admins = decoded['admins'] as List;
    final matches = decoded['matched_points'] as List;
    if (edges.isEmpty || matches.isEmpty || matches.last is! Map) {
      return const SpeedLimitLookupResult.unknown(
        SpeedLimitLookupOutcome.poorMatch,
      );
    }
    final match = matches.last as Map;
    final edgeIndex = match['edge_index'];
    final matchDistance = match['distance_from_trace_point'];
    if (match['type'] != 'matched' ||
        edgeIndex is! num ||
        matchDistance is! num ||
        edgeIndex.toInt() < 0 ||
        edgeIndex.toInt() >= edges.length ||
        edges[edgeIndex.toInt()] is! Map) {
      return const SpeedLimitLookupResult.unknown(
        SpeedLimitLookupOutcome.poorMatch,
      );
    }
    final maximumMatchDistance = math.min(
      40.0,
      math.max(15.0, (current.accuracyMeters ?? 15) * 1.5),
    );
    if (!matchDistance.toDouble().isFinite ||
        matchDistance.toDouble() < 0 ||
        matchDistance.toDouble() > maximumMatchDistance) {
      return const SpeedLimitLookupResult.unknown(
        SpeedLimitLookupOutcome.poorMatch,
      );
    }
    final edge = edges[edgeIndex.toInt()] as Map;
    final endNode = edge['end_node'];
    final adminIndex = endNode is Map ? endNode['admin_index'] : null;
    if (adminIndex is! num ||
        adminIndex.toInt() < 0 ||
        adminIndex.toInt() >= admins.length ||
        admins[adminIndex.toInt()] is! Map) {
      return const SpeedLimitLookupResult.unknown(
        SpeedLimitLookupOutcome.unavailable,
      );
    }
    final admin = admins[adminIndex.toInt()] as Map;
    if (admin['country_code'] != 'GB') {
      return const SpeedLimitLookupResult.unknown(
        SpeedLimitLookupOutcome.unsupportedRegion,
      );
    }
    if (edge['speed_type'] != 'tagged') {
      return const SpeedLimitLookupResult.unknown(
        SpeedLimitLookupOutcome.noTaggedLimit,
      );
    }
    final speedLimitKph = edge['speed_limit'];
    if (speedLimitKph is! num ||
        !speedLimitKph.toDouble().isFinite ||
        speedLimitKph <= 0) {
      return const SpeedLimitLookupResult.unknown(
        SpeedLimitLookupOutcome.noTaggedLimit,
      );
    }
    final suppliedHeading = current.headingDegrees;
    final travelHeading = suppliedHeading != null && suppliedHeading.isFinite
        ? suppliedHeading
        : _bearingDegrees(previous.point, current.point);
    final edgeHeading = edge['end_heading'] ?? edge['begin_heading'];
    if (edgeHeading is! num ||
        !edgeHeading.toDouble().isFinite ||
        _headingDifference(travelHeading, edgeHeading.toDouble()) > 50) {
      return const SpeedLimitLookupResult.unknown(
        SpeedLimitLookupOutcome.poorMatch,
      );
    }
    final milesPerHour = (speedLimitKph.toDouble() / 1.609344).round();
    if (!_acceptedUkLimitsMph.contains(milesPerHour)) {
      return const SpeedLimitLookupResult.unknown(
        SpeedLimitLookupOutcome.noTaggedLimit,
      );
    }
    final names = edge['names'];
    final roadName = names is List
        ? names
              .whereType<String>()
              .map((value) => value.trim())
              .where((value) => value.isNotEmpty && value.length <= 100)
              .firstOrNull
        : null;
    return SpeedLimitLookupResult.known(
      PostedSpeedLimit(
        milesPerHour: milesPerHour,
        roadName: roadName,
        source: sourceLabel,
        checkedAt: _clock().toUtc(),
        matchDistanceMeters: matchDistance.toDouble(),
      ),
    );
  }

  @override
  void close() {
    if (_ownsClient) _client.close();
  }
}

bool _isInUnitedKingdom(GeoPoint point) =>
    point.latitude >= 49.8 &&
    point.latitude <= 60.95 &&
    point.longitude >= -8.7 &&
    point.longitude <= 1.9;

double _distanceMeters(GeoPoint first, GeoPoint second) {
  const earthRadius = 6371000.0;
  final firstLat = first.latitude * math.pi / 180;
  final secondLat = second.latitude * math.pi / 180;
  final deltaLat = (second.latitude - first.latitude) * math.pi / 180;
  final deltaLon = (second.longitude - first.longitude) * math.pi / 180;
  final a =
      math.sin(deltaLat / 2) * math.sin(deltaLat / 2) +
      math.cos(firstLat) *
          math.cos(secondLat) *
          math.sin(deltaLon / 2) *
          math.sin(deltaLon / 2);
  return earthRadius * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}

double _bearingDegrees(GeoPoint first, GeoPoint second) {
  final firstLat = first.latitude * math.pi / 180;
  final secondLat = second.latitude * math.pi / 180;
  final deltaLon = (second.longitude - first.longitude) * math.pi / 180;
  final y = math.sin(deltaLon) * math.cos(secondLat);
  final x =
      math.cos(firstLat) * math.sin(secondLat) -
      math.sin(firstLat) * math.cos(secondLat) * math.cos(deltaLon);
  return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
}

double _headingDifference(double first, double second) {
  final difference = (first - second).abs() % 360;
  return math.min(difference, 360 - difference);
}
