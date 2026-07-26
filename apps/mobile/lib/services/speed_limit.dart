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
  /// Matches [current] to a road and reports its mapped limit.
  ///
  /// [previous] is an earlier fix the bike has genuinely travelled from, and is
  /// null when there is none: a first fix, or a stationary rider. It is not a
  /// precondition - a stationary fix resolves the current road too - but it is
  /// what supplies a travel heading, so a null one means an implementation must
  /// establish its confidence some other way rather than guess a direction
  /// (#126).
  Future<SpeedLimitLookupResult> lookup({
    required SpeedLimitLocation current,
    SpeedLimitLocation? previous,
  });

  void close();
}

class UnavailableSpeedLimitProvider implements SpeedLimitProvider {
  const UnavailableSpeedLimitProvider();

  @override
  Future<SpeedLimitLookupResult> lookup({
    required SpeedLimitLocation current,
    SpeedLimitLocation? previous,
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

  /// Below this the two fixes are jitter, not travel, so the pair carries no
  /// usable heading and the trace is sent as the single current fix.
  static const _minimumTraceMeters = 4.0;

  /// Accuracy a fix must beat to be matched at all.
  ///
  /// A travelled trace is corroborated by two fixes and a heading that has to
  /// agree with the matched road, so it tolerates the looser bound. A single
  /// stationary fix has neither, so it is held to a tighter one: the caution the
  /// original wait-for-movement rule was reaching for belongs here, as a
  /// confidence test, rather than as a blanket delay (#126).
  static const _movingAccuracyCeilingMeters = 50.0;
  static const _stationaryAccuracyCeilingMeters = 25.0;

  final ValhallaSpeedLimitConfiguration configuration;
  final http.Client _client;
  final bool _ownsClient;
  final DateTime Function() _clock;

  @override
  Future<SpeedLimitLookupResult> lookup({
    required SpeedLimitLocation current,
    SpeedLimitLocation? previous,
  }) async {
    final endpoint = configuration.lookupUri;
    if (endpoint == null) {
      return const SpeedLimitLookupResult.unknown(
        SpeedLimitLookupOutcome.unavailable,
      );
    }
    // A pair this close together is noise. Dropping back to the single current
    // fix matches the road the rider is on now without pretending to know which
    // way they are pointing.
    final travelled = previous == null
        ? 0.0
        : _distanceMeters(previous.point, current.point);
    final origin = travelled >= _minimumTraceMeters ? previous : null;
    if (!_isInUnitedKingdom(current.point) ||
        (origin != null && !_isInUnitedKingdom(origin.point))) {
      return const SpeedLimitLookupResult.unknown(
        SpeedLimitLookupOutcome.unsupportedRegion,
      );
    }
    final accuracy = current.accuracyMeters;
    final accuracyCeiling = origin == null
        ? _stationaryAccuracyCeilingMeters
        : _movingAccuracyCeilingMeters;
    if (accuracy != null &&
        (!accuracy.isFinite || accuracy < 0 || accuracy > accuracyCeiling)) {
      return const SpeedLimitLookupResult.unknown(
        SpeedLimitLookupOutcome.poorAccuracy,
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
                if (origin != null)
                  {'lat': origin.point.latitude, 'lon': origin.point.longitude},
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
        origin: origin,
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
    required SpeedLimitLocation? origin,
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
    final suppliedHeading = current.headingDegrees;
    // Heading is what separates the two carriageways of a dual carriageway, and
    // it exists only once the bike has actually travelled. A stationary GPS
    // course is noise - the same reason `NavigationHeadingSmoother` refuses it
    // below 1.5 m/s - so a lookup with no travelled origin has no heading at
    // all, whatever the platform reports, and earns its confidence from the
    // tighter match bound below instead.
    final travelHeading = origin == null
        ? null
        : suppliedHeading != null && suppliedHeading.isFinite
        ? suppliedHeading
        : _bearingDegrees(origin.point, current.point);
    // With no heading to corroborate it, the snap itself has to be convincing:
    // a match this close to the fix is on the road the rider is standing on, not
    // the carriageway or slip road beside it. A wrong limit is worse than none,
    // so the ambiguous case is reported as such and retried.
    final maximumMatchDistance = travelHeading == null
        ? math.min(18.0, math.max(8.0, (current.accuracyMeters ?? 15) * 0.9))
        : math.min(40.0, math.max(15.0, (current.accuracyMeters ?? 15) * 1.5));
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
    if (travelHeading != null) {
      final edgeHeading = edge['end_heading'] ?? edge['begin_heading'];
      if (edgeHeading is! num ||
          !edgeHeading.toDouble().isFinite ||
          _headingDifference(travelHeading, edgeHeading.toDouble()) > 50) {
        return const SpeedLimitLookupResult.unknown(
          SpeedLimitLookupOutcome.poorMatch,
        );
      }
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
