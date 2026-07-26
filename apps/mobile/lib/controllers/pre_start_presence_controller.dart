import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/ride_role.dart';
import '../domain/rider_location.dart';
import '../domain/ride_session.dart';
import '../internet/internet_relay_client.dart';
import '../relay/live_presence.dart';
import '../relay/relay_presence.dart';

/// Maintains one short-lived, non-journalled position per rider for the whole
/// ride.
///
/// This controller deliberately has no [EventStore] dependency. Its snapshots
/// disappear when stale, when the controller stops, or when the process exits.
/// The durable journal remains the only record of where the group has been;
/// this is only the answer to "where is everyone right now".
///
/// It runs across the `rideStarted` transition on purpose. Stopping at start
/// left two disconnected channels with no continuity, so a rider visible before
/// the start vanished at start, and a rider joining an already-started ride was
/// never visible at all until a journal round-trip completed.
class PreStartPresenceController extends ChangeNotifier {
  PreStartPresenceController(
    this._api, {
    this.pollInterval = const Duration(seconds: 4),
    this.freshnessPolicy = const PresenceFreshnessPolicy(),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final PreStartPresenceApi _api;
  final Duration pollInterval;
  final PresenceFreshnessPolicy freshnessPolicy;
  final DateTime Function() _clock;
  RideSession? _session;
  RiderLocation? _localPosition;
  final Map<String, RiderLocation> _internetLocations = {};
  final Map<String, RelayPresenceUpdate> _nearbyLocations = {};
  final Map<String, PresenceRosterMember> _roster = {};
  Set<String> _legacyPeerRiderIds = const {};
  Duration _relayClockOffset = Duration.zero;
  int _unreadablePositionCount = 0;
  RelayPresenceGateway? _nearby;
  StreamSubscription<RelayPresenceUpdate>? _nearbySubscription;
  Duration _ttl = const Duration(seconds: 45);
  Timer? _timer;
  bool _active = false;
  bool _syncing = false;
  bool _closed = false;
  bool _clearOnNextSync = false;
  PresenceAvailability _availability = PresenceAvailability.stopped;
  RidePresencePhase _phase = RidePresencePhase.unknown;

  bool get active => _active;

  /// The named availability of the internet presence channel. Replaces the
  /// previous string comparison against a server status code, which turned a
  /// capability refusal into a silent shrug.
  PresenceAvailability get availability => _availability;

  /// True when at least one presence channel can carry positions.
  bool get supported =>
      _nearby != null ||
      _availability != PresenceAvailability.serviceUnsupported;

  /// Plain-language reason, or null when presence is working.
  String? get unavailableReason => switch (_availability) {
    PresenceAvailability.live || PresenceAvailability.starting => null,
    PresenceAvailability.stopped => null,
    PresenceAvailability.serviceUnsupported =>
      PresenceLimitation.serviceCapabilityMissing.message,
    PresenceAvailability.serviceUnauthorized =>
      PresenceLimitation.serviceUnauthorized.message,
    PresenceAvailability.clientUpdateRequired =>
      PresenceLimitation.clientUpdateRequired.message,
    PresenceAvailability.serviceUpgradeRequired =>
      PresenceLimitation.serviceUpgradeRequired.message,
    PresenceAvailability.serviceUnreachable =>
      PresenceLimitation.serviceUnreachable.message,
  };

  /// Retained so existing callers keep compiling; prefer [unavailableReason].
  String? get statusMessage => unavailableReason;

  /// The phase the relay reports for this ride, which is what makes presence
  /// continuous rather than something the client has to infer from its own
  /// cursor.
  RidePresencePhase get phase => _phase;

  /// Riders the relay has seen, independent of the bulk event batch.
  List<PresenceRosterMember> get roster =>
      List.unmodifiable(_roster.values.toList()..sort(_byJoinedAt));

  /// The relay's clock minus this device's, from the last successful sync.
  ///
  /// Zero until the relay reports its own time. A peer's position is aged
  /// against the relay's clock rather than this phone's, because that is the
  /// only clock the two phones share.
  Duration get relayClockOffset => _relayClockOffset;

  /// Every named degradation currently affecting live positions.
  List<PresenceLimitation> get limitations {
    final channel = switch (_availability) {
      PresenceAvailability.serviceUnsupported =>
        PresenceLimitation.serviceCapabilityMissing,
      PresenceAvailability.serviceUnauthorized =>
        PresenceLimitation.serviceUnauthorized,
      PresenceAvailability.clientUpdateRequired =>
        PresenceLimitation.clientUpdateRequired,
      PresenceAvailability.serviceUpgradeRequired =>
        PresenceLimitation.serviceUpgradeRequired,
      PresenceAvailability.serviceUnreachable =>
        PresenceLimitation.serviceUnreachable,
      _ => null,
    };
    final result = <PresenceLimitation>[?channel];
    if (_unreadablePositionCount > 0) {
      result.add(
        PresenceLimitation.positionsUnreadable(_unreadablePositionCount),
      );
    }
    for (final riderId in _legacyPeerRiderIds) {
      if (riderId == _session?.localRiderId) continue;
      final name =
          _roster[riderId]?.displayName ??
          _internetLocations[riderId]?.displayName;
      if (name == null) continue;
      result.add(
        PresenceLimitation.peerAppOlder(riderId: riderId, displayName: name),
      );
    }
    // A rider whose own clock disagrees with the relay is named rather than
    // quietly aged out. Their position is still live: it is timed by the relay.
    for (final presence in presenceAt(_clock())) {
      final offset = presence.publisherClockOffset;
      if (offset == null || presence.isLocal) continue;
      result.add(
        PresenceLimitation.riderClockUntrusted(
          riderId: presence.riderId,
          displayName: presence.displayName,
          offset: offset,
        ),
      );
    }
    return List.unmodifiable(result);
  }

  /// The freshest retained position per rider across both presence channels.
  ///
  /// Positions past [PresenceFreshnessPolicy.retainFor] are dropped so nothing
  /// is drawn as if current; between the TTL and that threshold they survive so
  /// they can be visibly demoted to ageing and then stale.
  List<RiderLocation> get locations => [
    for (final presence in presenceAt(_clock())) ?presence.location,
  ];

  /// Retained positions from the internet presence channel only, so a caller
  /// merging in the journal can still attribute each source correctly.
  List<RiderLocation> get internetLocations =>
      List.unmodifiable(_retainedInternet(_clock()));

  /// Retained positions from the nearby presence channel only.
  List<RiderLocation> get nearbyLocations {
    final now = _clock();
    return List.unmodifiable(_retained(_nearbyPositions(now), now));
  }

  /// The reconciled per-rider state, including riders the roster names but who
  /// have no position yet.
  List<LiveRiderPresence> presenceAt(DateTime now) =>
      LivePresenceReconciler(policy: freshnessPolicy).reconcile(
        now: now,
        localRiderId: _session?.localRiderId ?? '',
        internetPresence: _retainedInternet(now),
        nearbyPresence: _retained(_nearbyPositions(now), now),
        roster: _roster.values,
        relayClockOffset: _relayClockOffset,
      );

  Iterable<RiderLocation> _retained(
    Iterable<RiderLocation> locations,
    DateTime now,
  ) => locations.where(
    (location) => location.sample.ageAt(now) <= freshnessPolicy.retainFor,
  );

  /// Retention for the internet channel is measured on the relay's clock for a
  /// peer, because their position carries the relay's arrival stamp. Measuring it
  /// against their own timestamp discarded riders whose phone clock was wrong
  /// while they were still reporting every few seconds.
  Iterable<RiderLocation> _retainedInternet(DateTime now) {
    final localRiderId = _session?.localRiderId;
    final relayNow = now.add(_relayClockOffset);
    return _internetLocations.values.where((location) {
      if (location.riderId == localRiderId) {
        return location.sample.ageAt(now) <= freshnessPolicy.retainFor;
      }
      final relayAge = relayNow.difference(location.receivedAt);
      return (relayAge.isNegative ? Duration.zero : relayAge) <=
          freshnessPolicy.retainFor;
    });
  }

  Iterable<RiderLocation> _nearbyPositions(DateTime now) => [
    for (final update in _nearbyLocations.values)
      if (update.position case final position?)
        if (update.expiresAt.isAfter(now) ||
            position.sample.ageAt(now) <= freshnessPolicy.retainFor)
          position,
  ];

  Future<void> attachNearby(RelayPresenceGateway nearby) async {
    if (_closed) throw StateError('Live presence controller is closed.');
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
    if (_closed) throw StateError('Live presence controller is closed.');
    _session = session;
    _active = true;
    _availability = PresenceAvailability.starting;
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
    _offerInternet(location);
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
      _internetLocations.remove(localId);
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
      _phase = result.phase;
      final serverTime = result.serverTime;
      if (serverTime != null) {
        _relayClockOffset = serverTime.difference(_clock());
      }
      _unreadablePositionCount = result.unreadablePositionCount;
      _applyInternetResult(result, session);
      _availability = PresenceAvailability.live;
      notifyListeners();
    } on InternetRelayException catch (error) {
      if (!_active || _closed || !identical(session, _session)) return;
      _availability = _availabilityFor(error);
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
      _internetLocations.clear();
      _nearbyLocations.clear();
      _roster.clear();
      return;
    }
    _timer?.cancel();
    _timer = null;
    final session = _session;
    _active = false;
    _availability = PresenceAvailability.stopped;
    _internetLocations.clear();
    _nearbyLocations.clear();
    _roster.clear();
    _legacyPeerRiderIds = const {};
    _relayClockOffset = Duration.zero;
    _unreadablePositionCount = 0;
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

  void _applyInternetResult(
    PreStartPresenceResult result,
    RideSession session,
  ) {
    // An out-of-order or duplicated reply must never rewind a rider to an older
    // coordinate.
    for (final location in result.locations) {
      _offerInternet(location);
    }
    final localPosition = _localPosition;
    if (localPosition != null) _offerInternet(localPosition);
    _legacyPeerRiderIds = result.legacyPeerRiderIds;
    _roster
      ..clear()
      ..addEntries(
        result.roster.map(
          (entry) => MapEntry(
            entry.riderId,
            PresenceRosterMember(
              riderId: entry.riderId,
              displayName: entry.displayName,
              role: _roleFor(entry.role),
              joinedAt: entry.joinedAt,
              left: entry.left,
              leftAt: entry.leftAt,
            ),
          ),
        ),
      );
    // A rider missing from the relay's list has stopped reporting; that is
    // shown by demoting their last position to ageing and then stale, not by
    // deleting it, because a marker that silently vanishes is indistinguishable
    // from one that was never there. Only an explicit departure removes a
    // rider, and only [PresenceFreshnessPolicy.retainFor] drops the position.
    final now = _clock();
    final departed = {
      for (final entry in result.roster)
        if (entry.left) entry.riderId,
    };
    final retained = _retainedInternet(
      now,
    ).map((location) => location.riderId).toSet();
    _internetLocations.removeWhere(
      (riderId, location) =>
          (departed.contains(riderId) && riderId != session.localRiderId) ||
          !retained.contains(riderId),
    );
    _nearbyLocations.removeWhere((riderId, update) {
      final position = update.position;
      return (departed.contains(riderId) && riderId != session.localRiderId) ||
          position == null ||
          position.sample.ageAt(now) > freshnessPolicy.retainFor;
    });
  }

  void _offerInternet(RiderLocation location) {
    final previous = _internetLocations[location.riderId];
    if (previous != null &&
        !location.sample.recordedAt.isAfter(previous.sample.recordedAt)) {
      return;
    }
    _internetLocations[location.riderId] = location;
  }

  static PresenceAvailability _availabilityFor(InternetRelayException error) {
    if (error.code == 'feature_unsupported') {
      return PresenceAvailability.serviceUnsupported;
    }
    if (error.code == 'update_required') {
      return PresenceAvailability.clientUpdateRequired;
    }
    if (error.code == 'server_upgrade_required') {
      return PresenceAvailability.serviceUpgradeRequired;
    }
    if (error.unauthorized) return PresenceAvailability.serviceUnauthorized;
    return PresenceAvailability.serviceUnreachable;
  }

  static RideRole _roleFor(String value) {
    for (final role in RideRole.values) {
      if (role.name == value) return role;
    }
    // An unknown future role must not drop the rider from the roster.
    return RideRole.rider;
  }

  static int _byJoinedAt(
    PresenceRosterMember left,
    PresenceRosterMember right,
  ) {
    final byJoin = left.joinedAt.compareTo(right.joinedAt);
    return byJoin != 0 ? byJoin : left.riderId.compareTo(right.riderId);
  }

  void _onNearbyPresence(RelayPresenceUpdate update) {
    if (!_active || _closed) return;
    final previous = _nearbyLocations[update.riderId];
    if (previous != null && !update.sentAt.isAfter(previous.sentAt)) return;
    if (update.clear) {
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

/// Why live positions are or are not flowing over the internet presence
/// channel. Every value is a state a rider can be told about.
enum PresenceAvailability {
  stopped,
  starting,
  live,
  serviceUnsupported,
  serviceUnauthorized,
  serviceUnreachable,
  clientUpdateRequired,
  serviceUpgradeRequired,
}
