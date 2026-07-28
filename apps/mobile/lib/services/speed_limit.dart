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
    this.roadId,
  }) : unlimited = false;

  const PostedSpeedLimit.unlimited({
    required this.source,
    required this.checkedAt,
    required this.matchDistanceMeters,
    this.roadName,
    this.roadId,
  }) : milesPerHour = null,
       unlimited = true;

  final int? milesPerHour;
  final bool unlimited;
  final String source;
  final DateTime checkedAt;
  final double matchDistanceMeters;
  final String? roadName;

  /// Stable OSM/Valhalla road identity, including travel direction where known.
  ///
  /// It is deliberately not shown to the rider. The look-ahead cache uses it so
  /// several sampled positions on the same road share one answer (#164).
  final String? roadId;
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

/// A road answer resolved before the rider reaches [anchor].
class PrefetchedSpeedLimit {
  const PrefetchedSpeedLimit({
    required this.roadId,
    required this.anchor,
    required this.headingDegrees,
    required this.result,
  });

  final String roadId;
  final GeoPoint anchor;
  final double? headingDegrees;
  final SpeedLimitLookupResult result;
}

/// Optional provider capability used to resolve a route or heading in one pass.
abstract interface class SpeedLimitPrefetchProvider {
  Future<List<PrefetchedSpeedLimit>> prefetch({
    required List<SpeedLimitLocation> locations,
  });
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

  /// The same service's `locate` endpoint.
  ///
  /// `trace_attributes` reports only the single edge it matched, so a rider
  /// standing in a car park is told about the aisle under their wheels and never
  /// about the road 15 metres away. `locate` takes one point and lists every
  /// nearby edge with its own distance, road class and posted limit, which is
  /// what the road-class preference in #145 needs. It is derived from the
  /// configured endpoint rather than separately configurable so a self-hosted
  /// deployment cannot end up with the two halves on different hosts.
  Uri? get candidateUri {
    final base = lookupUri;
    if (base == null || base.pathSegments.isEmpty) return null;
    return base.replace(
      pathSegments: [
        ...base.pathSegments.take(base.pathSegments.length - 1),
        'locate',
      ],
    );
  }
}

class ValhallaSpeedLimitProvider
    implements SpeedLimitProvider, SpeedLimitPrefetchProvider {
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
  static const _supportedCountryCodes = {'GB', 'IM'};

  /// Below this the two fixes are jitter, not travel, so the pair carries no
  /// usable heading and the trace is sent as the current fix twice.
  static const _minimumTraceMeters = 4.0;

  /// Accuracy a fix must beat to be matched at all.
  ///
  /// A travelled trace is corroborated by two fixes and a heading that has to
  /// agree with the matched road, so it tolerates the looser bound. A stationary
  /// fix has neither and used to be held to 25 m, which refused most of the
  /// fixes a phone reports at a standstill between buildings - exactly where a
  /// ride starts (#145). The caution belongs in the snap test below, which is
  /// measured against the road actually found, rather than in a bound that stops
  /// the app from looking at all.
  static const _movingAccuracyCeilingMeters = 50.0;
  static const _stationaryAccuracyCeilingMeters = 40.0;

  /// How far the matched road may lie from a stationary fix.
  ///
  /// 25 m. A phone standing still beside buildings, in a car park or a lay-by is
  /// routinely displaced 10-25 m by multipath, and the rider is plainly on the
  /// road they are parked beside, so anything tighter reports nothing in the one
  /// place riders look first (#145). It is not widened past that because UK roads
  /// carrying different limits are rarely within 25 m of one another; the notable
  /// exception is a service road alongside a main road, which the road-class
  /// preference below is there to resolve rather than to guess at.
  static const _stationaryMatchCeilingMeters = 25.0;

  /// How far the matched road may lie from a fix the bike has travelled to.
  ///
  /// Looser than the stationary bound because a heading has to agree with the
  /// road before the limit is shown, but no longer tighter than it for a good
  /// fix: a moving rider was previously held to as little as 15 m.
  static const _movingMatchFloorMeters = 25.0;
  static const _movingMatchCeilingMeters = 40.0;

  /// Radius asked of the service, which must exceed the app's own tolerance or
  /// the road the rider is beside is never a candidate. Valhalla documents a
  /// 100 m maximum for `search_radius` and warns that performance falls off as
  /// it rises, so this stays only as wide as the 25/40 m tests need.
  static const _minimumSearchRadiusMeters = 40.0;
  static const _maximumSearchRadiusMeters = 80.0;

  /// Valhalla road classes, highest first, as documented for
  /// `search_filter.min_road_class`.
  static const _roadClassesHighestFirst = [
    'motorway',
    'trunk',
    'primary',
    'secondary',
    'tertiary',
    'unclassified',
    'residential',
    'service_other',
  ];

  /// Valhalla `use` values that are not a carriageway a posted limit belongs to.
  ///
  /// A car park aisle, a driveway or a footpath is where a ride starts, not what
  /// the rider is about to ride at a posted limit.
  static const _nonCarriagewayUses = {
    'parking_aisle',
    'driveway',
    'alley',
    'drive_through',
    'emergency_access',
    'cycleway',
    'footway',
    'steps',
    'path',
    'pedestrian',
    'bridleway',
    'track',
    'service_road',
    'rest_area',
    'service_area',
    'construction',
  };

  /// Most `locate` candidates worth reading before giving up on the list.
  static const _maximumCandidates = 64;

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
    // A pair this close together is noise. Discarding the earlier fix resolves the
    // road the rider is on now without pretending to know which way they point.
    final travelled = previous == null
        ? 0.0
        : _distanceMeters(previous.point, current.point);
    final origin = travelled >= _minimumTraceMeters ? previous : null;
    if (!_isInSupportedBounds(current.point) ||
        (origin != null && !_isInSupportedBounds(origin.point))) {
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

    // A stationary rider is the reported case (#145), and it is the case a single
    // map-matched edge cannot answer: the nearest edge to a bike at a ride start
    // is the car park aisle it is parked on, and nothing in the match says what
    // else is within reach. `locate` lists every nearby road, so the preference
    // and the ambiguity test below have something to work with. Once the bike is
    // moving, the travelled pair and its heading are the better evidence and the
    // map match is used as before.
    if (origin == null) {
      return _resolveStationary(current);
    }
    return (await _traceAttributes(
      origin: origin,
      current: current,
      accuracy: accuracy,
    )).result;
  }

  @override
  Future<List<PrefetchedSpeedLimit>> prefetch({
    required List<SpeedLimitLocation> locations,
  }) async {
    if (locations.length < 2 ||
        locations.any((location) => !_isInSupportedBounds(location.point))) {
      return const [];
    }
    final decoded = await _requestTrace(locations);
    if (decoded is! Map ||
        decoded['edges'] is! List ||
        decoded['admins'] is! List ||
        decoded['matched_points'] is! List ||
        decoded['units'] != 'kilometers') {
      return const [];
    }
    final edges = decoded['edges'] as List;
    final admins = decoded['admins'] as List;
    final matches = decoded['matched_points'] as List;
    final prefetched = <PrefetchedSpeedLimit>[];
    for (
      var index = 0;
      index < math.min(locations.length, matches.length);
      index += 1
    ) {
      final match = matches[index];
      if (match is! Map ||
          match['type'] != 'matched' ||
          match['edge_index'] is! num ||
          match['distance_from_trace_point'] is! num) {
        continue;
      }
      final edgeIndex = (match['edge_index'] as num).toInt();
      final distance = (match['distance_from_trace_point'] as num).toDouble();
      if (edgeIndex < 0 ||
          edgeIndex >= edges.length ||
          edges[edgeIndex] is! Map ||
          !distance.isFinite ||
          distance < 0 ||
          distance > _movingMatchCeilingMeters) {
        continue;
      }
      final edge = edges[edgeIndex] as Map;
      final endNode = edge['end_node'];
      final adminIndex = endNode is Map ? endNode['admin_index'] : null;
      if (adminIndex is! num ||
          adminIndex.toInt() < 0 ||
          adminIndex.toInt() >= admins.length ||
          admins[adminIndex.toInt()] is! Map ||
          !_supportedCountryCodes.contains(
            (admins[adminIndex.toInt()] as Map)['country_code'],
          )) {
        continue;
      }
      final edgeHeading = edge['end_heading'] ?? edge['begin_heading'];
      final expectedHeading = locations[index].headingDegrees;
      if (expectedHeading != null &&
          (edgeHeading is! num ||
              !edgeHeading.toDouble().isFinite ||
              _headingDifference(expectedHeading, edgeHeading.toDouble()) >
                  50)) {
        continue;
      }
      final roadId = _roadId(edge['way_id'], edgeHeading);
      if (roadId == null) continue;
      final mapped = _mappedSpeedLimit(edge['speed_limit']);
      final names = edge['names'];
      final result = mapped == null
          ? const SpeedLimitLookupResult.unknown(
              SpeedLimitLookupOutcome.noTaggedLimit,
            )
          : SpeedLimitLookupResult.known(
              mapped.toPosted(
                roadName: names is List ? _firstRoadName(names) : null,
                roadId: roadId,
                checkedAt: _clock().toUtc(),
                matchDistanceMeters: distance,
              ),
            );
      prefetched.add(
        PrefetchedSpeedLimit(
          roadId: roadId,
          anchor: locations[index].point,
          headingDegrees: edgeHeading is num
              ? edgeHeading.toDouble()
              : expectedHeading,
          result: result,
        ),
      );
    }
    return List.unmodifiable(prefetched);
  }

  /// Resolves the road under a bike that has not moved.
  ///
  /// `locate` chooses the road; `trace_attributes` is then asked to confirm the
  /// country, and only when a number is actually about to be shown. That ordering
  /// keeps #84's administrative-region requirement without spending a request
  /// on a position that has nothing to display anyway, and it keeps the retry a
  /// stationary rider sits through down to one request.
  Future<SpeedLimitLookupResult> _resolveStationary(
    SpeedLimitLocation current,
  ) async {
    final chosen = await _preferredNeighbour(current);
    if (chosen == null) {
      return const SpeedLimitLookupResult.unknown(
        SpeedLimitLookupOutcome.unavailable,
      );
    }
    final limit = chosen.limit;
    final correlatedPoint = chosen.correlatedPoint;
    if (limit == null || correlatedPoint == null) return chosen.result;
    // Confirmed at the chosen road's own snapped position rather than at the fix,
    // so the country that comes back belongs to the road about to be displayed
    // and not to whichever edge a map match happened to prefer.
    final confirmation = await _traceAttributes(
      origin: null,
      current: SpeedLimitLocation(
        point: correlatedPoint,
        recordedAt: current.recordedAt,
        accuracyMeters: current.accuracyMeters,
      ),
      accuracy: current.accuracyMeters,
    );
    if (!confirmation.regionIsSupported) return confirmation.result;
    return SpeedLimitLookupResult.known(limit);
  }

  Future<_TraceOutcome> _traceAttributes({
    required SpeedLimitLocation? origin,
    required SpeedLimitLocation current,
    required double? accuracy,
  }) async {
    final decoded = await _requestTrace([
      origin ?? current,
      current,
    ], accuracy: accuracy);
    if (decoded == null) {
      return _TraceOutcome.unknown(SpeedLimitLookupOutcome.unavailable);
    }
    return _parse(decoded, origin: origin, current: current);
  }

  Future<Object?> _requestTrace(
    List<SpeedLimitLocation> locations, {
    double? accuracy,
  }) async {
    final endpoint = configuration.lookupUri;
    if (endpoint == null || locations.length < 2) return null;
    final effectiveAccuracy =
        accuracy ??
        locations
            .map((location) => location.accuracyMeters)
            .whereType<double>()
            .where((value) => value.isFinite && value >= 0)
            .fold<double>(15, math.max);
    final searchRadius = (effectiveAccuracy * 2).clamp(
      _minimumSearchRadiusMeters,
      _maximumSearchRadiusMeters,
    );
    try {
      final response = await _client
          .post(
            endpoint,
            headers: _headers,
            body: jsonEncode({
              // Valhalla needs at least two shape points. A stationary lookup
              // deliberately supplies the same fix twice; a prefetch supplies
              // sampled points along the remaining route or current heading.
              'shape': [
                for (final location in locations)
                  {
                    'lat': location.point.latitude,
                    'lon': location.point.longitude,
                  },
              ],
              'costing': 'motorcycle',
              'shape_match': 'map_snap',
              'trace_options': {
                'gps_accuracy': effectiveAccuracy.clamp(5, 50),
                'search_radius': searchRadius,
              },
              'filters': {
                'action': 'include',
                'attributes': [
                  'edge.names',
                  'edge.way_id',
                  'edge.speed_limit',
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
        return null;
      }
      return jsonDecode(utf8.decode(response.bodyBytes));
    } on Object {
      return null;
    }
  }

  static const _headers = {
    'accept': 'application/json',
    'content-type': 'application/json',
    'user-agent': 'TailEndCharlie/0.1 speed-limit-display',
    'x-client-id': 'tailendcharlie.app',
  };

  /// Asks `locate` for every road near a stationary fix and picks the one the
  /// rider is most likely about to ride, or reports the ambiguity honestly.
  ///
  /// Returns null only when the service could not be read at all, which is the
  /// one case the caller reports as unavailable rather than as an answer.
  Future<_NeighbourChoice?> _preferredNeighbour(
    SpeedLimitLocation current,
  ) async {
    final endpoint = configuration.candidateUri;
    if (endpoint == null) return null;
    final List<_RoadCandidate> candidates;
    try {
      final response = await _client
          .post(
            endpoint,
            headers: _headers,
            body: jsonEncode({
              'locations': [
                {
                  'lat': current.point.latitude,
                  'lon': current.point.longitude,
                  // Valhalla documents that it returns the closest candidate
                  // anyway when nothing falls inside the radius, so the app's own
                  // tolerance is still applied to each distance below.
                  'radius': _stationaryMatchCeilingMeters + 5,
                },
              ],
              'costing': 'motorcycle',
              'verbose': true,
              // `locate` does not echo its units, so they are stated. A limit
              // wrongly read as mph would fail the UK-value test below rather
              // than reach the sign.
              'directions_options': {'units': 'kilometers'},
            }),
          )
          .timeout(configuration.timeout);
      if (response.statusCode < 200 ||
          response.statusCode >= 300 ||
          response.bodyBytes.length > _maximumResponseBytes) {
        return null;
      }
      candidates = _parseCandidates(
        jsonDecode(utf8.decode(response.bodyBytes)),
      );
    } on Object {
      return null;
    }

    final withinTolerance = candidates
        .where(
          (candidate) =>
              candidate.distanceMeters <= _stationaryMatchCeilingMeters,
        )
        .toList();
    if (withinTolerance.isEmpty) {
      // Nothing is close enough to be the road the rider is on. Not a dead end:
      // the controller retries where it stands and on movement.
      return _NeighbourChoice.unknown(SpeedLimitLookupOutcome.poorMatch);
    }
    final posted = withinTolerance
        .where((candidate) => candidate.limit != null)
        .toList();
    if (posted.isEmpty) {
      // Roads are here, none of them carries a mapped limit. Settled until the
      // bike moves, rather than retried on the spot.
      return _NeighbourChoice.unknown(SpeedLimitLookupOutcome.noTaggedLimit);
    }

    // Judgement, not a fact (#145): a rider setting off is on the road, not on
    // the alley beside it, so a carriageway outranks a service way even when the
    // service way is the nearer of the two. Where carriageways themselves
    // disagree the higher road class is preferred on the same reasoning - the main
    // road rather than the side street touching it - and if that still leaves two
    // answers the ambiguity is reported instead of one of them being chosen.
    final carriageways = posted
        .where((candidate) => !candidate.isServiceWay)
        .toList();
    final pool = carriageways.isEmpty ? posted : carriageways;
    final topRank = pool
        .map((candidate) => candidate.classRank)
        .reduce(math.min);
    final best = pool
        .where((candidate) => candidate.classRank == topRank)
        .toList();
    final limits = best.map((candidate) => candidate.limit).toSet();
    if (limits.length != 1) {
      return _NeighbourChoice.unknown(SpeedLimitLookupOutcome.poorMatch);
    }
    final nearest = best.reduce(
      (a, b) => a.distanceMeters <= b.distanceMeters ? a : b,
    );
    final selected = limits.single!;
    return _NeighbourChoice.resolved(
      correlatedPoint: nearest.correlatedPoint,
      limit: selected.toPosted(
        roadName: best
            .map((candidate) => candidate.roadName)
            .whereType<String>()
            .firstOrNull,
        roadId: nearest.roadId,
        checkedAt: _clock().toUtc(),
        matchDistanceMeters: nearest.distanceMeters,
      ),
    );
  }

  List<_RoadCandidate> _parseCandidates(Object? decoded) {
    if (decoded is! List || decoded.isEmpty) return const [];
    final first = decoded.first;
    if (first is! Map || first['edges'] is! List) return const [];
    final candidates = <_RoadCandidate>[];
    for (final entry in (first['edges'] as List).take(_maximumCandidates)) {
      if (entry is! Map) continue;
      final distance = entry['distance'];
      if (distance is! num ||
          !distance.toDouble().isFinite ||
          distance.toDouble() < 0) {
        continue;
      }
      final info = entry['edge_info'];
      final edge = entry['edge'];
      final classification = edge is Map ? edge['classification'] : null;
      final latitude = entry['correlated_lat'];
      final longitude = entry['correlated_lon'];
      if (info is! Map ||
          classification is! Map ||
          latitude is! num ||
          longitude is! num ||
          !latitude.toDouble().isFinite ||
          !longitude.toDouble().isFinite) {
        continue;
      }
      final roadClass = classification['classification'];
      final use = classification['use'];
      final names = info['names'];
      candidates.add(
        _RoadCandidate(
          distanceMeters: distance.toDouble(),
          correlatedPoint: GeoPoint(
            latitude: latitude.toDouble(),
            longitude: longitude.toDouble(),
          ),
          classRank: _roadClassesHighestFirst.indexOf(
            roadClass is String ? roadClass : '',
          ),
          isServiceWay:
              roadClass == 'service_other' ||
              (use is String && _nonCarriagewayUses.contains(use)),
          limit: _mappedSpeedLimit(info['speed_limit']),
          roadName: names is List ? _firstRoadName(names) : null,
          roadId: _roadId(info['way_id'], entry['heading']),
        ),
      );
    }
    // An unrecognised road class must not outrank a known one.
    return candidates
        .where((candidate) => candidate.classRank >= 0)
        .toList(growable: false);
  }

  _TraceOutcome _parse(
    Object? decoded, {
    required SpeedLimitLocation? origin,
    required SpeedLimitLocation current,
  }) {
    if (decoded is! Map ||
        decoded['edges'] is! List ||
        decoded['admins'] is! List ||
        decoded['matched_points'] is! List ||
        decoded['units'] != 'kilometers') {
      return _TraceOutcome.unknown(SpeedLimitLookupOutcome.unavailable);
    }
    final edges = decoded['edges'] as List;
    final admins = decoded['admins'] as List;
    final matches = decoded['matched_points'] as List;
    if (edges.isEmpty || matches.isEmpty || matches.last is! Map) {
      return _TraceOutcome.unknown(SpeedLimitLookupOutcome.poorMatch);
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
      return _TraceOutcome.unknown(SpeedLimitLookupOutcome.poorMatch);
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
    // A stationary snap has no heading to corroborate it, so the distance is the
    // whole confidence test and it is stated outright rather than scaled down to
    // single figures by a good accuracy reading: see
    // [_stationaryMatchCeilingMeters] for why 25 m. A travelled trace is also
    // held to at least that, having previously been stricter than a standstill.
    final maximumMatchDistance = travelHeading == null
        ? _stationaryMatchCeilingMeters
        : math.min(
            _movingMatchCeilingMeters,
            math.max(
              _movingMatchFloorMeters,
              (current.accuracyMeters ?? 15) * 1.5,
            ),
          );
    if (!matchDistance.toDouble().isFinite ||
        matchDistance.toDouble() < 0 ||
        matchDistance.toDouble() > maximumMatchDistance) {
      return _TraceOutcome.unknown(SpeedLimitLookupOutcome.poorMatch);
    }
    final edge = edges[edgeIndex.toInt()] as Map;
    final endNode = edge['end_node'];
    final adminIndex = endNode is Map ? endNode['admin_index'] : null;
    if (adminIndex is! num ||
        adminIndex.toInt() < 0 ||
        adminIndex.toInt() >= admins.length ||
        admins[adminIndex.toInt()] is! Map) {
      return _TraceOutcome.unknown(SpeedLimitLookupOutcome.unavailable);
    }
    final admin = admins[adminIndex.toInt()] as Map;
    if (!_supportedCountryCodes.contains(admin['country_code'])) {
      return _TraceOutcome.unknown(SpeedLimitLookupOutcome.unsupportedRegion);
    }
    // Valhalla documents `speed_limit` as "the posted speed limit, if available"
    // and as the attribute a navigation application should display; it is set
    // only from an OpenStreetMap `maxspeed` tag, so an untagged road simply omits
    // it and stays unknown. `speed_type` is a different thing - it says whether
    // the edge's *base routing speed* came from a tag or from the road class -
    // and gating on it was rejecting every genuine posted limit on the live
    // service, which reports `classified` alongside a perfectly good
    // `speed_limit` (#145).
    final mappedLimit = _mappedSpeedLimit(edge['speed_limit']);
    if (mappedLimit == null) {
      return _TraceOutcome.unknown(
        SpeedLimitLookupOutcome.noTaggedLimit,
        regionIsSupported: true,
      );
    }
    if (travelHeading != null) {
      final edgeHeading = edge['end_heading'] ?? edge['begin_heading'];
      if (edgeHeading is! num ||
          !edgeHeading.toDouble().isFinite ||
          _headingDifference(travelHeading, edgeHeading.toDouble()) > 50) {
        return _TraceOutcome.unknown(SpeedLimitLookupOutcome.poorMatch);
      }
    }
    final names = edge['names'];
    return _TraceOutcome(
      SpeedLimitLookupResult.known(
        mappedLimit.toPosted(
          roadName: names is List ? _firstRoadName(names) : null,
          roadId: _roadId(
            edge['way_id'],
            edge['end_heading'] ?? edge['begin_heading'],
          ),
          checkedAt: _clock().toUtc(),
          matchDistanceMeters: matchDistance.toDouble(),
        ),
      ),
      regionIsSupported: true,
    );
  }

  @override
  void close() {
    if (_ownsClient) _client.close();
  }
}

/// What a `trace_attributes` response established about the road under the fix.
///
/// Carries one thing beyond the answer itself: whether the service confirmed the
/// position is in GB or the Isle of Man, which is what the stationary path asks
/// a trace for because `locate` reports no country of its own.
class _TraceOutcome {
  const _TraceOutcome(this.result, {this.regionIsSupported = false});

  _TraceOutcome.unknown(
    SpeedLimitLookupOutcome outcome, {
    this.regionIsSupported = false,
  }) : result = SpeedLimitLookupResult.unknown(outcome);

  final SpeedLimitLookupResult result;
  final bool regionIsSupported;
}

/// One road near a fix, as reported by `locate`.
class _RoadCandidate {
  const _RoadCandidate({
    required this.distanceMeters,
    required this.correlatedPoint,
    required this.classRank,
    required this.isServiceWay,
    required this.limit,
    required this.roadName,
    required this.roadId,
  });

  final double distanceMeters;

  /// Where on this road the fix snaps to, which is the position the country
  /// confirmation is asked about.
  final GeoPoint correlatedPoint;

  /// Index into the documented highest-to-lowest road class list, so a smaller
  /// rank is a bigger road.
  final int classRank;
  final bool isServiceWay;
  final _MappedSpeedLimit? limit;
  final String? roadName;
  final String? roadId;
}

/// The road chosen from a `locate` list, or the reason none was.
class _NeighbourChoice {
  const _NeighbourChoice.resolved({
    required GeoPoint this.correlatedPoint,
    required PostedSpeedLimit this.limit,
  }) : outcome = SpeedLimitLookupOutcome.known;

  const _NeighbourChoice.unknown(this.outcome)
    : correlatedPoint = null,
      limit = null;

  /// Where on the chosen road the fix snaps to, and so the position whose country
  /// is confirmed before a number is displayed.
  final GeoPoint? correlatedPoint;

  /// The limit found, or null when [outcome] explains why there is none.
  final PostedSpeedLimit? limit;
  final SpeedLimitLookupOutcome outcome;

  /// Only meaningful when [limit] is null.
  SpeedLimitLookupResult get result => SpeedLimitLookupResult.unknown(outcome);
}

class _MappedSpeedLimit {
  const _MappedSpeedLimit.numeric(this.milesPerHour) : unlimited = false;

  const _MappedSpeedLimit.unlimited() : milesPerHour = null, unlimited = true;

  final int? milesPerHour;
  final bool unlimited;

  PostedSpeedLimit toPosted({
    required DateTime checkedAt,
    required double matchDistanceMeters,
    String? roadName,
    String? roadId,
  }) => unlimited
      ? PostedSpeedLimit.unlimited(
          source: ValhallaSpeedLimitProvider.sourceLabel,
          checkedAt: checkedAt,
          matchDistanceMeters: matchDistanceMeters,
          roadName: roadName,
          roadId: roadId,
        )
      : PostedSpeedLimit(
          milesPerHour: milesPerHour!,
          source: ValhallaSpeedLimitProvider.sourceLabel,
          checkedAt: checkedAt,
          matchDistanceMeters: matchDistanceMeters,
          roadName: roadName,
          roadId: roadId,
        );

  @override
  bool operator ==(Object other) =>
      other is _MappedSpeedLimit &&
      other.milesPerHour == milesPerHour &&
      other.unlimited == unlimited;

  @override
  int get hashCode => Object.hash(milesPerHour, unlimited);
}

/// Parses Valhalla's posted-limit field without confusing two different absences.
///
/// The live service serialises OSM `maxspeed=none` as the string `unlimited`.
/// An untagged road omits `speed_limit` altogether. Only the former earns the
/// infinity sign; null remains the honest unknown-road dash (#164).
_MappedSpeedLimit? _mappedSpeedLimit(Object? speedLimit) {
  if (speedLimit == 'unlimited') {
    return const _MappedSpeedLimit.unlimited();
  }
  final milesPerHour = _ukMilesPerHour(speedLimit);
  return milesPerHour == null ? null : _MappedSpeedLimit.numeric(milesPerHour);
}

/// Converts a Valhalla posted limit in km/h to a UK sign value, or null.
///
/// Only the six limits a UK sign carries are accepted. That keeps an inferred or
/// foreign value off the sign, and it also fails safe if a service ever reported
/// mph where km/h was asked for: every UK limit read the wrong way round falls
/// outside the set rather than showing a plausible wrong number.
int? _ukMilesPerHour(Object? speedLimitKph) {
  if (speedLimitKph is! num ||
      !speedLimitKph.toDouble().isFinite ||
      speedLimitKph <= 0) {
    return null;
  }
  final milesPerHour = (speedLimitKph.toDouble() / 1.609344).round();
  return ValhallaSpeedLimitProvider._acceptedUkLimitsMph.contains(milesPerHour)
      ? milesPerHour
      : null;
}

String? _roadId(Object? wayId, Object? heading) {
  if (wayId is! num || wayId < 0) return null;
  // Directional limits share an OSM way id. Four heading quadrants keep the
  // cache road-based while preventing a value from the opposite carriageway
  // direction being reused.
  final direction = heading is num && heading.toDouble().isFinite
      ? ((heading.toDouble() % 360 + 360) % 360 / 90).round() % 4
      : 0;
  return '${wayId.toInt()}:$direction';
}

String? _firstRoadName(List names) => names
    .whereType<String>()
    .map((value) => value.trim())
    .where((value) => value.isNotEmpty && value.length <= 100)
    .firstOrNull;

bool _isInSupportedBounds(GeoPoint point) =>
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
