import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/speed_limit.dart';

enum SpeedLimitDisplayStatus {
  disabled,
  waitingForMovement,
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
           ? SpeedLimitDisplayStatus.waitingForMovement
           : SpeedLimitDisplayStatus.disabled;

  static const preferenceKey = 'posted-speed-limit-enabled-v1';
  static const lookupInterval = Duration(seconds: 15);
  static const minimumLookupMovementMeters = 25.0;

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
      enabled: preferences.getBool(preferenceKey) ?? false,
      clock: clock ?? DateTime.now,
    );
  }

  factory SpeedLimitDisplayController.inMemory({
    SpeedLimitProvider provider = const UnavailableSpeedLimitProvider(),
    bool enabled = false,
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
        ? SpeedLimitDisplayStatus.waitingForMovement
        : SpeedLimitDisplayStatus.disabled;
    notifyListeners();
    await _preferences?.setBool(preferenceKey, value);
  }

  void observe(SpeedLimitLocation location) {
    final previous = _previousLocation;
    if (previous != null && location.recordedAt.isBefore(previous.recordedAt)) {
      return;
    }
    _previousLocation = location;
    if (!_enabled) return;
    if (previous == null) {
      _lastLookupLocation = location;
      return;
    }
    final movement = _distanceMeters(previous, location);
    if (movement < 4) return;
    final now = _clock();
    final lastLookupAt = _lastLookupAt;
    final lookupAnchor = _lastLookupLocation ?? previous;
    if (_distanceMeters(lookupAnchor, location) < minimumLookupMovementMeters ||
        (lastLookupAt != null &&
            now.difference(lastLookupAt) < lookupInterval)) {
      return;
    }
    if (_lookupLoop != null) return;
    final loop = _lookup(
      previous: lookupAnchor,
      current: location,
      generation: _generation,
    );
    _lookupLoop = loop;
    unawaited(
      loop.whenComplete(() {
        if (identical(_lookupLoop, loop)) _lookupLoop = null;
      }),
    );
  }

  Future<void> _lookup({
    required SpeedLimitLocation previous,
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
    _status = result.limit == null
        ? SpeedLimitDisplayStatus.unavailable
        : SpeedLimitDisplayStatus.known;
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
