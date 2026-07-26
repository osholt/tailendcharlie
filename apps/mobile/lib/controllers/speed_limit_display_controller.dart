import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  SpeedLimitLocation? _previousLocation;
  SpeedLimitLocation? _lastLookupLocation;
  DateTime? _lastLookupAt;
  Future<void>? _lookupLoop;
  int _generation = 0;
  bool _disposed = false;

  bool get enabled => _enabled;
  SpeedLimitDisplayStatus get status => _status;
  SpeedLimitLookupOutcome? get lastOutcome => _lastOutcome;
  PostedSpeedLimit? get limit => _limit;

  Future<void> setEnabled(bool value) async {
    if (_enabled == value) return;
    _generation += 1;
    _enabled = value;
    _limit = null;
    _lastOutcome = null;
    _previousLocation = null;
    _lastLookupLocation = null;
    _lastLookupAt = null;
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
    _status = SpeedLimitDisplayStatus.checking;
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
    if (_disposed || !_enabled || generation != _generation) return;
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
    notifyListeners();
  }

  @visibleForTesting
  Future<void> waitForIdle() async {
    while (true) {
      final loop = _lookupLoop;
      if (loop == null) break;
      await loop;
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
  const earthRadius = 6371000.0;
  final firstLat = first.point.latitude * math.pi / 180;
  final secondLat = second.point.latitude * math.pi / 180;
  final deltaLat =
      (second.point.latitude - first.point.latitude) * math.pi / 180;
  final deltaLon =
      (second.point.longitude - first.point.longitude) * math.pi / 180;
  final a =
      math.sin(deltaLat / 2) * math.sin(deltaLat / 2) +
      math.cos(firstLat) *
          math.cos(secondLat) *
          math.sin(deltaLon / 2) *
          math.sin(deltaLon / 2);
  return earthRadius * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}
