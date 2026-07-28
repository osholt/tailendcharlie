import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/imported_route.dart';
import '../services/speed_limit.dart';

enum SpeedLimitDisplayStatus {
  disabled,

  /// Enabled, but no road has been confidently matched to the current position.
  ///
  /// Named for the condition rather than for a wait: this is a junction, a car
  /// park, a poor fix or parallel carriageways, and it resolves on the next
  /// better fix or as soon as the bike moves. It replaced a blanket
  /// wait-for-movement entry state, which made the feature look broken to a
  /// stationary rider (#126).
  unconfirmedRoad,
  checking,
  known,
  unavailable,
}

class SpeedLimitDisplayController extends ChangeNotifier {
  SpeedLimitDisplayController._({
    required this._preferences,
    required this._provider,
    required bool enabled,
    required this._clock,
  }) : _enabled = enabled,
       _status = enabled
           ? SpeedLimitDisplayStatus.unconfirmedRoad
           : SpeedLimitDisplayStatus.disabled;

  static const preferenceKey = 'posted-speed-limit-enabled-v1';

  /// On unless the rider has said otherwise.
  ///
  /// The preference is only ever written by an explicit toggle, so an absent key
  /// means "never chose" and takes this default, while a stored `false` is a
  /// rider who turned it off and stays off across the upgrade (#126).
  static const defaultEnabled = true;

  /// Minimum gap between lookups once a road is settled.
  static const lookupInterval = Duration(seconds: 15);

  /// How far the bike must travel before a settled limit is rechecked.
  static const minimumLookupMovementMeters = 25.0;

  /// How soon an unconfirmed road is retried without moving.
  ///
  /// Short, because this is the state a stationary rider is looking at: the
  /// honest low-confidence readout is meant to be brief, not the resting state.
  static const unconfirmedRetryInterval = Duration(seconds: 5);

  /// Movement that makes a two-fix trace worth sending.
  ///
  /// Below this the pair is GPS jitter rather than travel, so the lookup is sent
  /// with no origin fix and the provider resolves the road as a standstill rather
  /// than disambiguating on noise.
  static const minimumTraceMovementMeters = 4.0;

  /// One trace resolves the next kilometre densely enough not to step over a
  /// short urban road between two junctions.
  static const prefetchDistanceMeters = 1000.0;
  static const prefetchSampleSpacingMeters = 25.0;
  static const prefetchInterval = Duration(seconds: 30);
  static const minimumPrefetchMovementMeters = 150.0;

  /// A cached answer is used only while the bike is close to the route sample
  /// that established it and, where a course exists, travelling with that road.
  static const cachedAnchorToleranceMeters = 45.0;
  static const cachedHeadingToleranceDegrees = 50.0;

  static Future<SpeedLimitDisplayController> load({
    SpeedLimitProvider? provider,
    DateTime Function()? clock,
  }) async {
    final preferences = await SharedPreferences.getInstance();
    return SpeedLimitDisplayController._(
      preferences: preferences,
      provider:
          provider ??
          ValhallaSpeedLimitProvider(
            configuration: ValhallaSpeedLimitConfiguration.fromEnvironment(),
          ),
      enabled: preferences.getBool(preferenceKey) ?? defaultEnabled,
      clock: clock ?? DateTime.now,
    );
  }

  factory SpeedLimitDisplayController.inMemory({
    SpeedLimitProvider provider = const UnavailableSpeedLimitProvider(),
    bool enabled = defaultEnabled,
    DateTime Function()? clock,
  }) => SpeedLimitDisplayController._(
    preferences: null,
    provider: provider,
    enabled: enabled,
    clock: clock ?? DateTime.now,
  );

  final SharedPreferences? _preferences;
  final SpeedLimitProvider _provider;
  final DateTime Function() _clock;
  bool _enabled;
  SpeedLimitDisplayStatus _status;
  SpeedLimitLookupOutcome? _lastOutcome;
  PostedSpeedLimit? _limit;
  bool _hasResolved = false;

  /// True while a lookup is in flight. Deliberately not a [status]: the sign has
  /// three states and a spinner is not one of them (#164). Surfaces may use this
  /// to say a reading is being rechecked without replacing the reading.
  bool _refreshing = false;
  SpeedLimitLocation? _previousLocation;
  SpeedLimitLocation? _lastLookupLocation;
  DateTime? _lastLookupAt;
  Future<void>? _lookupLoop;
  final Map<String, List<PrefetchedSpeedLimit>> _prefetchedByRoad = {};
  SpeedLimitLocation? _lastPrefetchLocation;
  DateTime? _lastPrefetchAt;
  Future<void>? _prefetchLoop;
  int _generation = 0;
  bool _disposed = false;

  bool get enabled => _enabled;
  SpeedLimitDisplayStatus get status => _status;
  SpeedLimitLookupOutcome? get lastOutcome => _lastOutcome;
  PostedSpeedLimit? get limit => _limit;

  /// Whether a fresh lookup is in flight behind whatever is currently shown.
  bool get refreshing => _refreshing;

  Future<void> setEnabled(bool value) async {
    if (_enabled == value) return;
    _generation += 1;
    _enabled = value;
    _limit = null;
    _hasResolved = false;
    _refreshing = false;
    _lastOutcome = null;
    _previousLocation = null;
    _lastLookupLocation = null;
    _lastLookupAt = null;
    _prefetchedByRoad.clear();
    _lastPrefetchLocation = null;
    _lastPrefetchAt = null;
    _status = value
        ? SpeedLimitDisplayStatus.unconfirmedRoad
        : SpeedLimitDisplayStatus.disabled;
    notifyListeners();
    // Written on every explicit toggle, including off, so [defaultEnabled] can
    // tell "never chose" from "chose no".
    await _preferences?.setBool(preferenceKey, value);
  }

  void observe(SpeedLimitLocation location) {
    final previous = _previousLocation;
    if (previous != null && location.recordedAt.isBefore(previous.recordedAt)) {
      return;
    }
    _previousLocation = location;
    if (!_enabled || _lookupLoop != null) return;

    // A prefetched road answer was map-matched while signal was available. Use
    // it synchronously at the transition, before deciding whether another
    // network lookup is due. This is the part that makes a route transition
    // number/dash/infinity-to-number/dash/infinity rather than a wait (#164).
    final cached = _cachedResultAt(location);
    if (cached != null) {
      _lastLookupLocation = location;
      _lastLookupAt = _clock();
      _applyResult(cached, rememberAtCurrent: false);
      return;
    }

    final anchor = _lastLookupLocation;
    if (anchor == null) {
      // Nothing has been looked up yet, so resolve the road the rider is
      // standing on from this single fix. Requiring movement first was the whole
      // reason the readout sat at a dash on a stationary bike (#126).
      _beginLookup(previous: null, current: location, generation: _generation);
      return;
    }

    final travelled = _distanceMeters(anchor, location);
    final moved = travelled >= minimumLookupMovementMeters;
    if (!moved && !_retryWhileStationary) return;
    final interval = moved ? lookupInterval : _stationaryRetryInterval;
    final lastLookupAt = _lastLookupAt;
    if (lastLookupAt != null && _clock().difference(lastLookupAt) < interval) {
      return;
    }
    _beginLookup(
      // Once the bike has genuinely moved, the previous lookup point gives the
      // travel heading that separates parallel carriageways - the one case where
      // movement really does help. Stationary, there is no heading to give, and
      // the provider compares the roads around the fix instead of inventing one.
      previous: travelled >= minimumTraceMovementMeters ? anchor : null,
      current: location,
      generation: _generation,
    );
  }

  /// Resolves and caches the road ahead along [routeAhead], or along the current
  /// heading when there is no active route.
  ///
  /// The optional capability keeps simple/test providers unchanged. Valhalla
  /// answers every sampled road in one trace request, keyed by OSM way and
  /// direction, so repeated samples do not become per-position cache entries.
  void prefetchAhead({
    required SpeedLimitLocation current,
    List<GeoPoint> routeAhead = const [],
  }) {
    if (!_enabled ||
        _prefetchLoop != null ||
        _provider is! SpeedLimitPrefetchProvider) {
      return;
    }
    final lastAt = _lastPrefetchAt;
    final lastLocation = _lastPrefetchLocation;
    if (lastAt != null &&
        lastLocation != null &&
        _clock().difference(lastAt) < prefetchInterval &&
        _distanceMeters(lastLocation, current) <
            minimumPrefetchMovementMeters) {
      return;
    }
    final locations = _lookAheadLocations(
      current: current,
      routeAhead: routeAhead,
      maximumDistanceMeters: prefetchDistanceMeters,
      spacingMeters: prefetchSampleSpacingMeters,
    );
    if (locations.length < 2) return;
    _lastPrefetchAt = _clock();
    _lastPrefetchLocation = current;
    final generation = _generation;
    final provider = _provider as SpeedLimitPrefetchProvider;
    final loop = () async {
      List<PrefetchedSpeedLimit> readings;
      try {
        readings = await provider.prefetch(locations: locations);
      } on Object {
        readings = const [];
      }
      if (_disposed || !_enabled || generation != _generation) return;
      for (final reading in readings) {
        final road = _prefetchedByRoad.putIfAbsent(
          reading.roadId,
          () => <PrefetchedSpeedLimit>[],
        );
        road.removeWhere(
          (existing) =>
              _distancePoints(existing.anchor, reading.anchor) <
              prefetchSampleSpacingMeters / 2,
        );
        road.add(reading);
        if (road.length > 64) road.removeRange(0, road.length - 64);
      }
      // Bound a long ride without throwing away the newest roads.
      while (_prefetchedByRoad.length > 256) {
        _prefetchedByRoad.remove(_prefetchedByRoad.keys.first);
      }
    }();
    _prefetchLoop = loop;
    unawaited(
      loop.whenComplete(() {
        if (identical(_prefetchLoop, loop)) _prefetchLoop = null;
      }),
    );
  }

  SpeedLimitLookupResult? _cachedResultAt(SpeedLimitLocation location) {
    final candidates =
        <({PrefetchedSpeedLimit reading, double distanceMeters})>[];
    for (final readings in _prefetchedByRoad.values) {
      for (final reading in readings) {
        // Avoid a haversine calculation for the thousands of old anchors a long
        // ride may retain. These bounds are deliberately much wider than the
        // 45 m acceptance circle everywhere in the supported region.
        if ((location.point.latitude - reading.anchor.latitude).abs() > 0.001 ||
            (location.point.longitude - reading.anchor.longitude).abs() >
                0.002) {
          continue;
        }
        final distance = _distancePoints(location.point, reading.anchor);
        if (distance > cachedAnchorToleranceMeters) continue;
        final currentHeading = location.headingDegrees;
        final roadHeading = reading.headingDegrees;
        if (currentHeading != null &&
            currentHeading.isFinite &&
            roadHeading != null &&
            roadHeading.isFinite &&
            _headingDifference(currentHeading, roadHeading) >
                cachedHeadingToleranceDegrees) {
          continue;
        }
        candidates.add((reading: reading, distanceMeters: distance));
      }
    }
    if (candidates.isEmpty) return null;
    candidates.sort(
      (first, second) => first.distanceMeters.compareTo(second.distanceMeters),
    );
    final nearest = candidates.first;
    // Two different roads are commonly close at a junction or on parallel
    // carriageways. If they disagree and distance cannot separate them, the
    // cache refuses to guess; the ordinary current-road lookup produces the
    // honest dash/unconfirmed state.
    for (final candidate in candidates.skip(1)) {
      if (candidate.reading.roadId == nearest.reading.roadId) continue;
      if (candidate.distanceMeters > nearest.distanceMeters + 20) break;
      if (!_sameAnswer(candidate.reading.result, nearest.reading.result)) {
        return null;
      }
    }
    return nearest.reading.result;
  }

  /// Whether a stationary rider is still owed another attempt.
  ///
  /// An unconfirmed road resolves on a better fix and an unreachable service
  /// recovers on its own, so both keep trying where they stand. A road with no
  /// mapped limit, or a position outside the supported region, cannot change
  /// until the bike does.
  bool get _retryWhileStationary => switch (_lastOutcome) {
    null ||
    SpeedLimitLookupOutcome.poorAccuracy ||
    SpeedLimitLookupOutcome.poorMatch ||
    SpeedLimitLookupOutcome.unavailable => true,
    SpeedLimitLookupOutcome.known ||
    SpeedLimitLookupOutcome.noTaggedLimit ||
    SpeedLimitLookupOutcome.unsupportedRegion => false,
  };

  Duration get _stationaryRetryInterval =>
      _status == SpeedLimitDisplayStatus.unconfirmedRoad
      ? unconfirmedRetryInterval
      : lookupInterval;

  void _beginLookup({
    required SpeedLimitLocation? previous,
    required SpeedLimitLocation current,
    required int generation,
  }) {
    final loop = _lookup(
      previous: previous,
      current: current,
      generation: generation,
    );
    _lookupLoop = loop;
    unawaited(
      loop.whenComplete(() {
        if (identical(_lookupLoop, loop)) _lookupLoop = null;
      }),
    );
  }

  Future<void> _lookup({
    required SpeedLimitLocation? previous,
    required SpeedLimitLocation current,
    required int generation,
  }) async {
    // Only the *first* resolution shows as checking. Setting it on every lookup
    // threw away a perfectly good reading and put a spinner in the sign each
    // time the rider moved far enough to trigger another one, which on a moving
    // ride is most of the time:
    //
    //   "The speed limit display was showing a loading animation a lot of the
    //    time. It should always show a speed limit and it should buffer ahead to
    //    avoid this issue."
    //
    // A limit already resolved stays on screen while the next one is fetched.
    // It carries its own "checked HH:MM" provenance, so a reading a few seconds
    // old is visibly a reading a few seconds old rather than a claim about the
    // road the rider is on right now (#164, and #145's honesty rule).
    _refreshing = true;
    if (!_hasResolved) _status = SpeedLimitDisplayStatus.checking;
    if (!_disposed) notifyListeners();
    _lastLookupAt = _clock();
    _lastLookupLocation = current;
    SpeedLimitLookupResult result;
    try {
      result = await _provider.lookup(previous: previous, current: current);
    } on Object {
      result = const SpeedLimitLookupResult.unknown(
        SpeedLimitLookupOutcome.unavailable,
      );
    }
    _refreshing = false;
    if (_disposed || !_enabled || generation != _generation) return;
    _applyResult(result);
  }

  void _applyResult(
    SpeedLimitLookupResult result, {
    bool rememberAtCurrent = true,
  }) {
    _hasResolved = true;
    _lastOutcome = result.outcome;
    _limit = result.limit;
    _status = switch (result.outcome) {
      SpeedLimitLookupOutcome.known when result.limit != null =>
        SpeedLimitDisplayStatus.known,
      // Say the road is not confirmed rather than silently withholding: these
      // are the ambiguous cases, and they are expected to be brief (#126).
      SpeedLimitLookupOutcome.known ||
      SpeedLimitLookupOutcome.poorAccuracy ||
      SpeedLimitLookupOutcome.poorMatch =>
        SpeedLimitDisplayStatus.unconfirmedRoad,
      // Settled negatives: this road carries no mapped limit, the position is
      // outside the supported region, or the service did not answer.
      SpeedLimitLookupOutcome.noTaggedLimit ||
      SpeedLimitLookupOutcome.unsupportedRegion ||
      SpeedLimitLookupOutcome.unavailable =>
        SpeedLimitDisplayStatus.unavailable,
    };
    final roadId = result.limit?.roadId;
    final location = _lastLookupLocation;
    if (rememberAtCurrent && roadId != null && location != null) {
      final road = _prefetchedByRoad.putIfAbsent(
        roadId,
        () => <PrefetchedSpeedLimit>[],
      );
      road.add(
        PrefetchedSpeedLimit(
          roadId: roadId,
          anchor: location.point,
          headingDegrees: location.headingDegrees,
          result: result,
        ),
      );
    }
    notifyListeners();
  }

  @visibleForTesting
  Future<void> waitForIdle() async {
    while (true) {
      final lookup = _lookupLoop;
      final prefetch = _prefetchLoop;
      if (lookup == null && prefetch == null) break;
      await Future.wait([?lookup, ?prefetch]);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _provider.close();
    super.dispose();
  }
}

double _distanceMeters(SpeedLimitLocation first, SpeedLimitLocation second) {
  return _distancePoints(first.point, second.point);
}

double _distancePoints(GeoPoint first, GeoPoint second) {
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

List<SpeedLimitLocation> _lookAheadLocations({
  required SpeedLimitLocation current,
  required List<GeoPoint> routeAhead,
  required double maximumDistanceMeters,
  required double spacingMeters,
}) {
  final points = <GeoPoint>[];
  final routeIsClose =
      routeAhead.isNotEmpty &&
      _distancePoints(current.point, routeAhead.first) <= 150;
  if (routeIsClose) {
    for (final point in routeAhead) {
      if (points.isEmpty || _distancePoints(points.last, point) >= 1) {
        points.add(point);
      }
    }
  } else {
    final heading = current.headingDegrees;
    if (heading == null || !heading.isFinite) return const [];
    for (
      var distance = 0.0;
      distance <= maximumDistanceMeters;
      distance += spacingMeters
    ) {
      points.add(_destinationPoint(current.point, heading, distance));
    }
  }
  if (points.length < 2) return const [];

  final sampled = <GeoPoint>[points.first];
  var target = spacingMeters;
  var travelled = 0.0;
  for (var index = 0; index < points.length - 1; index += 1) {
    final start = points[index];
    final end = points[index + 1];
    final segment = _distancePoints(start, end);
    if (segment <= 0) continue;
    while (target <= math.min(maximumDistanceMeters, travelled + segment)) {
      final fraction = (target - travelled) / segment;
      sampled.add(
        GeoPoint(
          latitude: start.latitude + (end.latitude - start.latitude) * fraction,
          longitude:
              start.longitude + (end.longitude - start.longitude) * fraction,
        ),
      );
      target += spacingMeters;
    }
    travelled += segment;
    if (travelled >= maximumDistanceMeters) break;
  }
  if (sampled.length < 2 && points.length >= 2) sampled.add(points[1]);

  return [
    for (var index = 0; index < sampled.length; index += 1)
      SpeedLimitLocation(
        point: sampled[index],
        recordedAt: current.recordedAt,
        accuracyMeters: current.accuracyMeters,
        headingDegrees: sampled.length == 1
            ? current.headingDegrees
            : index < sampled.length - 1
            ? _bearingDegrees(sampled[index], sampled[index + 1])
            : _bearingDegrees(sampled[index - 1], sampled[index]),
      ),
  ];
}

GeoPoint _destinationPoint(
  GeoPoint origin,
  double headingDegrees,
  double distanceMeters,
) {
  const earthRadius = 6371000.0;
  final bearing = headingDegrees * math.pi / 180;
  final angularDistance = distanceMeters / earthRadius;
  final latitude = origin.latitude * math.pi / 180;
  final longitude = origin.longitude * math.pi / 180;
  final destinationLatitude = math.asin(
    math.sin(latitude) * math.cos(angularDistance) +
        math.cos(latitude) * math.sin(angularDistance) * math.cos(bearing),
  );
  final destinationLongitude =
      longitude +
      math.atan2(
        math.sin(bearing) * math.sin(angularDistance) * math.cos(latitude),
        math.cos(angularDistance) -
            math.sin(latitude) * math.sin(destinationLatitude),
      );
  return GeoPoint(
    latitude: destinationLatitude * 180 / math.pi,
    longitude: destinationLongitude * 180 / math.pi,
  );
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
  final difference = ((first - second) % 360 + 360) % 360;
  return math.min(difference, 360 - difference);
}

bool _sameAnswer(SpeedLimitLookupResult first, SpeedLimitLookupResult second) =>
    first.outcome == second.outcome &&
    first.limit?.unlimited == second.limit?.unlimited &&
    first.limit?.milesPerHour == second.limit?.milesPerHour;
