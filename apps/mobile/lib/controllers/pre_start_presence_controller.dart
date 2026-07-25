import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/rider_location.dart';
import '../domain/ride_session.dart';
import '../internet/internet_relay_client.dart';
import '../relay/relay_presence.dart';

/// Maintains one short-lived, non-journalled position per rider before start.
///
/// This controller deliberately has no [EventStore] dependency. Its snapshots
/// disappear when stale, when the controller stops, or when the process exits.
class PreStartPresenceController extends ChangeNotifier {
  PreStartPresenceController(
    this._api, {
    this.pollInterval = const Duration(seconds: 4),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final PreStartPresenceApi _api;
  final Duration pollInterval;
  final DateTime Function() _clock;
  RideSession? _session;
  RiderLocation? _localPosition;
  List<RiderLocation> _internetLocations = const [];
  final Map<String, RelayPresenceUpdate> _nearbyLocations = {};
  RelayPresenceGateway? _nearby;
  StreamSubscription<RelayPresenceUpdate>? _nearbySubscription;
  Duration _ttl = const Duration(seconds: 45);
  Timer? _timer;
  bool _active = false;
  bool _syncing = false;
  bool _closed = false;
  bool _clearOnNextSync = false;
  String? _statusMessage;

  bool get active => _active;
  bool get supported =>
      _nearby != null || _statusMessage != 'feature_unsupported';
  String? get statusMessage => _statusMessage;
  List<RiderLocation> get locations {
    final now = _clock();
    final latest = <String, RiderLocation>{};
    for (final location in _internetLocations) {
      if (now.difference(location.receivedAt) <= _ttl) {
        latest[location.riderId] = location;
      }
    }
    for (final update in _nearbyLocations.values) {
      final location = update.position;
      if (location == null || !update.expiresAt.isAfter(now)) continue;
      final previous = latest[location.riderId];
      if (previous == null ||
          location.sample.recordedAt.isAfter(previous.sample.recordedAt)) {
        latest[location.riderId] = location;
      }
    }
    return List.unmodifiable(
      latest.values.toList()
        ..sort((left, right) => left.riderId.compareTo(right.riderId)),
    );
  }

  Future<void> attachNearby(RelayPresenceGateway nearby) async {
    if (_closed) throw StateError('Pre-start presence controller is closed.');
    await _nearbySubscription?.cancel();
    _nearby = nearby;
    _nearbySubscription = nearby.presenceUpdates.listen(_onNearbyPresence);
    final localPosition = _localPosition;
    if (_active && localPosition != null) {
      await nearby.publishPresence(localPosition, ttl: _ttl);
    }
    notifyListeners();
  }

  Future<void> start(RideSession session) async {
    if (_closed) throw StateError('Pre-start presence controller is closed.');
    _session = session;
    _active = true;
    _statusMessage = null;
    await synchronizeNow();
  }

  void updateLocalPosition(RiderLocation location) {
    final session = _session;
    if (!_active ||
        session == null ||
        location.riderId != session.localRiderId) {
      return;
    }
    _localPosition = location;
    _internetLocations = [
      ..._internetLocations.where((value) => value.riderId != location.riderId),
      location,
    ];
    _nearbyLocations[location.riderId] = RelayPresenceUpdate(
      riderId: location.riderId,
      sentAt: location.receivedAt,
      expiresAt: location.receivedAt.add(_ttl),
      clear: false,
      position: location,
    );
    notifyListeners();
    unawaited(_publishNearby(location));
    wake();
  }

  Future<void> clearLocalPosition() async {
    final localId = _session?.localRiderId;
    _localPosition = null;
    if (localId != null) {
      _internetLocations = _internetLocations
          .where((location) => location.riderId != localId)
          .toList(growable: false);
      _nearbyLocations.remove(localId);
    }
    _clearOnNextSync = true;
    notifyListeners();
    await Future.wait([
      synchronizeNow(),
      if (_nearby != null)
        _nearby!.publishPresence(null, clear: true, ttl: _ttl),
    ]);
  }

  Future<void> synchronizeNow() async {
    final session = _session;
    if (!_active || _closed || _syncing || session == null) return;
    _timer?.cancel();
    _timer = null;
    _syncing = true;
    try {
      final result = await _api.synchronizePreStartPresence(
        session: session,
        position: _clearOnNextSync ? null : _localPosition,
        clear: _clearOnNextSync,
      );
      if (!_active || _closed || !identical(session, _session)) return;
      _clearOnNextSync = false;
      _ttl = result.ttl;
      _internetLocations = result.locations;
      _statusMessage = null;
      notifyListeners();
    } on InternetRelayException catch (error) {
      if (!_active || _closed || !identical(session, _session)) return;
      _statusMessage = error.code ?? error.message;
      notifyListeners();
    } finally {
      _syncing = false;
      if (_active && !_closed) {
        _timer = Timer(pollInterval, () => unawaited(synchronizeNow()));
      }
    }
  }

  void wake() {
    if (!_active || _closed || _syncing || _timer == null) return;
    _timer?.cancel();
    _timer = null;
    unawaited(synchronizeNow());
  }

  Future<void> stop({bool clearRemote = true}) async {
    if (!_active) {
      _internetLocations = const [];
      _nearbyLocations.clear();
      return;
    }
    _timer?.cancel();
    _timer = null;
    final session = _session;
    _active = false;
    _internetLocations = const [];
    _nearbyLocations.clear();
    notifyListeners();
    if (clearRemote) {
      await Future.wait([
        if (session != null) _clearInternetPresence(session),
        if (_nearby != null) _clearNearbyPresence(),
      ]);
    }
    _localPosition = null;
    _clearOnNextSync = false;
  }

  Future<void> close() async {
    if (_closed) return;
    await stop();
    await _nearbySubscription?.cancel();
    _nearbySubscription = null;
    _nearby = null;
    _closed = true;
    _session = null;
    _api.close();
    dispose();
  }

  void _onNearbyPresence(RelayPresenceUpdate update) {
    if (!_active || _closed) return;
    final previous = _nearbyLocations[update.riderId];
    if (previous != null && !update.sentAt.isAfter(previous.sentAt)) return;
    if (update.clear || !update.expiresAt.isAfter(_clock())) {
      _nearbyLocations.remove(update.riderId);
    } else {
      _nearbyLocations[update.riderId] = update;
    }
    notifyListeners();
  }

  Future<void> _publishNearby(RiderLocation location) async {
    try {
      await _nearby?.publishPresence(location, ttl: _ttl);
    } on Object {
      // Internet presence and the next GPS fix remain independent fallbacks.
    }
  }

  Future<void> _clearInternetPresence(RideSession session) async {
    try {
      await _api.synchronizePreStartPresence(
        session: session,
        position: null,
        clear: true,
      );
    } on Object {
      // The shared server TTL remains the bounded cleanup fallback.
    }
  }

  Future<void> _clearNearbyPresence() async {
    try {
      await _nearby?.publishPresence(null, clear: true, ttl: _ttl);
    } on Object {
      // Nearby snapshots expire independently on every peer.
    }
  }
}
