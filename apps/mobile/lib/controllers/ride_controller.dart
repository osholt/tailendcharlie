import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';

import '../domain/event_store.dart';
import '../domain/ice_share.dart';
import '../domain/imported_route.dart';
import '../domain/join_invite.dart';
import '../domain/marker_assistance.dart';
import '../domain/quick_message.dart';
import '../domain/ride_event.dart';
import '../domain/ride_role.dart';
import '../domain/ride_session.dart';
import '../domain/rider_color.dart';
import '../domain/session_store.dart';
import '../features/map/motorcycle_icon.dart';
import '../services/nearby_bridge.dart';
import '../services/marker_statistics.dart';
import '../services/ride_event_authenticator.dart';
import '../services/ride_lifecycle.dart';
import '../services/ride_membership.dart';
import '../services/ride_route_reducer.dart';
import '../services/situation_event_factory.dart';
import '../internet/internet_relay_client.dart';

typedef Clock = DateTime Function();
typedef IdFactory = String Function();

class RideController extends ChangeNotifier {
  RideController(
    this._eventStore,
    this._sessionStore,
    this._nearbyBridge, {
    Clock? clock,
    IdFactory? idFactory,
    Random? random,
    RideCodeDirectory? rideCodeDirectory,
    this._installationId,
  }) : _clock = clock ?? DateTime.now,
       _idFactory = idFactory ?? const Uuid().v7,
       _random = random ?? Random.secure(),
       _rideCodeDirectory =
           rideCodeDirectory ?? HttpRideCodeDirectory.fromEnvironment();

  static const endedRideRecoveryWindow = Duration(hours: 24);

  final EventStore _eventStore;
  final SessionStore _sessionStore;
  final NearbyBridge _nearbyBridge;
  final Clock _clock;
  final IdFactory _idFactory;
  final Random _random;
  final String? _installationId;
  final RideCodeDirectory _rideCodeDirectory;

  RideSession? _session;
  List<RideEvent> _events = const [];
  NearbyCapabilities _nearbyCapabilities =
      const NearbyCapabilities.unavailable();
  bool _busy = false;
  String? _errorMessage;
  RideRole? _roleBeforeMarker;
  Timer? _endedRideCleanupTimer;
  RideLifecycle _lifecycle = const RideLifecycle();
  RideRouteState _routeState = const RideRouteState();
  final Map<String, Set<RideTransportEvidence>> _transportByEventId = {};

  /// ICE shares the local rider has acted on (called/texted the contact).
  /// Kept in memory only, for this session: it gates which received shares
  /// survive the ride-end purge, not a durable record of anyone's own.
  final Set<String> _usedIceShareEventIds = {};

  RideSession? get session => _session;
  EventStore get eventStore => _eventStore;
  List<RideEvent> get events => List.unmodifiable(_events);
  NearbyCapabilities get nearbyCapabilities => _nearbyCapabilities;
  bool get busy => _busy;
  String? get errorMessage => _errorMessage;
  bool get hasActiveRide => _session != null;

  bool get rideStarted => _lifecycle.started;
  DateTime? get rideStartedAt => _lifecycle.startedAt;
  bool get isLocalRideLeader =>
      _session?.role == RideRole.lead ||
      (markerActive && _roleBeforeMarker == RideRole.lead);
  RidePhase get ridePhase => rideEnded
      ? RidePhase.ended
      : rideStarted
      ? RidePhase.started
      : RidePhase.open;

  RideRouteState get authoritativeRouteState => _routeState;
  ImportedRoute? get authoritativeRoute => _routeState.route;

  List<RideParticipant> get participants {
    final activeSession = _session;
    if (activeSession == null) return const [];
    return const RideMembershipReducer().fromEvents(
      rideId: activeSession.rideId,
      inviteSecret: activeSession.inviteSecret,
      events: _events,
      now: _clock(),
      localRiderId: activeSession.localRiderId,
      localDisplayName: activeSession.displayName,
      localRole: activeSession.role,
      localJoinedAt: activeSession.joinedAt,
      localMotorcycleStyle: activeSession.motorcycleStyle,
      localRiderColor: activeSession.riderColor,
      rideStartedAt: rideStartedAt,
      rideEndedAt: _rideEndedAt,
      transportByEventId: _transportByEventId,
    );
  }

  List<RideParticipant> get liveParticipants => participants
      .where((participant) => participant.isIncludedInLiveCount)
      .toList(growable: false);

  RideParticipant? participantFor(String riderId) => participants
      .where((participant) => participant.riderId == riderId)
      .firstOrNull;

  void noteTransportObservation(
    String eventId,
    RideTransportEvidence evidence,
  ) {
    if (evidence == RideTransportEvidence.localDevice ||
        evidence == RideTransportEvidence.journal) {
      return;
    }
    final values = _transportByEventId.putIfAbsent(eventId, () => {});
    if (values.add(evidence)) notifyListeners();
  }

  void refreshMembershipFreshness() => notifyListeners();

  bool get rideEnded {
    return _events.any((event) => event.type == RideEventType.rideEnded);
  }

  /// A lead-owned group coordination pause. It deliberately does not suppress
  /// GPS evidence: riders can still be found while the group is stopped.
  bool get ridePaused {
    if (!rideStarted) return false;
    RideEvent? latest;
    for (final event in _events) {
      if (event.type != RideEventType.ridePaused &&
          event.type != RideEventType.rideResumed) {
        continue;
      }
      // Local clocks can produce equal timestamps for back-to-back actions;
      // events are ordered by the durable store, so the later item wins ties.
      if (latest == null || !event.createdAt.isBefore(latest.createdAt)) {
        latest = event;
      }
    }
    return latest?.type == RideEventType.ridePaused;
  }

  bool get markerActive {
    final localDeviceId = _session?.localRiderId;
    if (localDeviceId == null) return false;
    var active = false;
    for (final event in _events) {
      if (event.deviceId != localDeviceId) continue;
      if (event.type == RideEventType.markerStarted) {
        active = true;
      } else if (event.type == RideEventType.markerEnded) {
        active = false;
      }
    }
    return active;
  }

  RideMarkingSummary get markingSummary => MarkerStatistics.fromEvents(
    _rideActivityEvents,
    asOf: _clock(),
    markerDeviceId: _session?.localRiderId,
    authenticatedLocationEvidence: _authenticatedLocationEvidence,
  );

  Map<String, String> get _authenticatedLocationEvidence {
    final activeSession = _session;
    final startedAt = rideStartedAt;
    if (activeSession == null || startedAt == null) return const {};
    final result = <String, String>{};
    for (final event in _events) {
      if (event.type != RideEventType.riderLocationUpdated ||
          event.createdAt.isBefore(startedAt) ||
          !SituationEventFactory.verify(event, activeSession.inviteSecret)) {
        continue;
      }
      final rawLocation = event.payload['location'];
      if (rawLocation is! Map) continue;
      final riderId = rawLocation['riderId'];
      final sample = rawLocation['sample'];
      final recordedAt = sample is Map
          ? DateTime.tryParse(sample['recordedAt'] as String? ?? '')
          : null;
      if (riderId is String && riderId == event.deviceId) {
        if (recordedAt != null && recordedAt.isBefore(startedAt)) continue;
        result[event.id] = riderId;
      }
    }
    return result;
  }

  MarkerSessionSummary? get currentMarkerSession =>
      markingSummary.activeSession;

  String? get currentMarkerSessionId => currentMarkerSession?.sessionId;

  int get markerPassCount {
    return currentMarkerSession?.uniquePassCount ?? 0;
  }

  int get verifiedMarkerPassCount =>
      currentMarkerSession?.verifiedPassCount ?? 0;

  bool get tecPassedCurrentMarker => currentMarkerSession?.tecPassedAt != null;

  int get pendingEventCount =>
      _events.where((event) => !event.acknowledged).length;

  /// ICE shares other riders have sent to me: either an explicit
  /// whole-group share, or an auto-share addressed to me while I hold the
  /// lead role. Purged from storage at ride-end unless marked used.
  List<IceShare> get receivedIceShares {
    final localId = _session?.localRiderId;
    if (localId == null) return const [];
    return _events
        .where(
          (event) =>
              event.type == RideEventType.iceInfoShared &&
              event.deviceId != localId &&
              _isAddressedToMe(event, localId),
        )
        .map(_iceShareFromEvent)
        .toList(growable: false);
  }

  /// ICE shares I have sent, with read-receipt state if a recipient has
  /// opened one.
  List<IceShare> get sentIceShares {
    final localId = _session?.localRiderId;
    if (localId == null) return const [];
    return _events
        .where(
          (event) =>
              event.type == RideEventType.iceInfoShared &&
              event.deviceId == localId,
        )
        .map((event) {
          final share = _iceShareFromEvent(event);
          final view = _events
              .where(
                (candidate) =>
                    candidate.type == RideEventType.iceInfoViewed &&
                    candidate.payload['sharedEventId'] == event.id,
              )
              .fold<RideEvent?>(
                null,
                (earliest, candidate) =>
                    earliest == null ||
                        candidate.createdAt.isBefore(earliest.createdAt)
                    ? candidate
                    : earliest,
              );
          if (view == null) return share;
          return IceShare(
            eventId: share.eventId,
            sharedByRiderId: share.sharedByRiderId,
            sharedByDisplayName: share.sharedByDisplayName,
            contactName: share.contactName,
            contactPhone: share.contactPhone,
            medicalNotes: share.medicalNotes,
            sharedAt: share.sharedAt,
            toWholeGroup: share.toWholeGroup,
            viewedAt: view.createdAt,
            viewedByRiderId: view.deviceId,
          );
        })
        .toList(growable: false);
  }

  bool _isAddressedToMe(RideEvent event, String localId) {
    final recipients = event.payload['recipientRiderIds'];
    if (recipients is! List) return true;
    return recipients.contains(localId);
  }

  IceShare _iceShareFromEvent(RideEvent event) => IceShare(
    eventId: event.id,
    sharedByRiderId: event.deviceId,
    sharedByDisplayName: event.payload['sharedByDisplayName'] as String? ?? '',
    contactName: event.payload['contactName'] as String? ?? '',
    contactPhone: event.payload['contactPhone'] as String? ?? '',
    medicalNotes: event.payload['medicalNotes'] as String? ?? '',
    sharedAt: event.createdAt,
    toWholeGroup: event.payload['recipientRiderIds'] == null,
  );

  String get rideCodeShareText {
    final activeSession = _requireSession();
    final name = activeSession.rideName;
    final group = name == null ? 'my Tail End Charlie group' : '"$name"';
    final invite = joinInviteText(
      activeSession.rideCode,
      activeSession.joinToken,
    );
    return 'Join $group. Enter ride code ${activeSession.rideCode} in the '
        'app, or paste this invite: $invite.';
  }

  Future<void> initialize() async {
    _nearbyCapabilities = await _nearbyBridge.capabilities();
    _session = await _sessionStore.load();
    final activeSession = _session;
    if (activeSession != null) {
      _events = await _eventStore.eventsForRide(activeSession.rideId);
      _rebuildLifecycle();
      await _expireEndedRideIfDue();
      await _purgeUnusedIceSharesIfEnded();
      _roleBeforeMarker = _activeMarkerPreviousRole();
    }
    notifyListeners();
  }

  Future<void> reloadEvents() async {
    final activeSession = _session;
    if (activeSession == null) {
      return;
    }
    _events = await _eventStore.eventsForRide(activeSession.rideId);
    _rebuildLifecycle();
    await _expireEndedRideIfDue();
    await _purgeUnusedIceSharesIfEnded();
    notifyListeners();
  }

  Future<void> createRide(
    String displayName, {
    MotorcycleIconStyle motorcycleStyle = motorcycleIconStyleDefault,
    RiderColor riderColor = riderColorDefault,
    String? rideName,
  }) async {
    await _run(() async {
      await _createRide(
        displayName: displayName,
        motorcycleStyle: motorcycleStyle,
        riderColor: riderColor,
        rideName: rideName,
      );
    });
  }

  Future<void> createSimulationRide({
    int riderCount = RideSession.defaultSimulationRiderCount,
    MotorcycleIconStyle motorcycleStyle = motorcycleIconStyleDefault,
    RiderColor riderColor = riderColorDefault,
  }) async {
    await _run(() async {
      await _createRide(
        displayName: 'Demo Lead',
        isSimulation: true,
        simulationRiderCount: _validatedSimulationRiderCount(riderCount),
        motorcycleStyle: motorcycleStyle,
        riderColor: riderColor,
      );
    });
  }

  Future<void> restartSimulationRide({int? riderCount}) async {
    await _run(() async {
      final activeSession = _requireSession();
      if (!activeSession.isSimulation) {
        throw const FormatException('Only a simulated ride can be restarted.');
      }
      await _eventStore.deleteRide(activeSession.rideId);
      await _sessionStore.clear();
      _session = null;
      _events = const [];
      _roleBeforeMarker = null;
      await _createRide(
        displayName: 'Demo Lead',
        isSimulation: true,
        simulationRiderCount: _validatedSimulationRiderCount(
          riderCount ?? activeSession.simulationRiderCount,
        ),
        motorcycleStyle: activeSession.motorcycleStyle,
        riderColor: activeSession.riderColor,
        rideName: activeSession.rideName,
      );
    });
  }

  /// Publishes the leader's short code once the optional internet relay is
  /// reachable. The code only resolves the bootstrap credentials; subsequent
  /// event traffic continues to use the authenticated relay protocols.
  Future<void> publishRideCode() async {
    final activeSession = _requireSession();
    if (activeSession.isSimulation || activeSession.role != RideRole.lead) {
      return;
    }
    var session = activeSession;
    for (var attempt = 0; attempt < 8; attempt++) {
      try {
        await _rideCodeDirectory.register(session);
        return;
      } on RideCodeDirectoryException catch (error) {
        if (!error.codeConflict || attempt == 7) rethrow;
        session = session.copyWith(rideCode: _generateCode());
        _session = session;
        await _sessionStore.save(session);
        notifyListeners();
      }
    }
  }

  Future<void> joinRide(
    String rideCode,
    String displayName, {
    MotorcycleIconStyle motorcycleStyle = motorcycleIconStyleDefault,
    RiderColor riderColor = riderColorDefault,
    String? joinToken,
  }) async {
    await _run(() async {
      final normalisedCode = rideCode.trim();
      if (!RegExp(r'^\d{6}$').hasMatch(normalisedCode)) {
        throw const FormatException('Enter a valid six-digit ride code.');
      }
      final credentials = await _rideCodeDirectory.resolve(
        normalisedCode,
        joinToken: joinToken,
      );
      final now = _clock();
      final session = RideSession(
        rideId: credentials.rideId,
        rideCode: credentials.rideCode,
        inviteSecret: credentials.inviteSecret,
        joinToken: credentials.joinToken,
        localRiderId: _localRiderIdForRide(credentials.rideId),
        displayName: _normaliseName(displayName),
        role: RideRole.rider,
        joinedAt: now,
        motorcycleStyle: motorcycleStyle,
        riderColor: riderColor,
      );
      _session = session;
      await _sessionStore.save(session);
      _events = await _eventStore.eventsForRide(session.rideId);
      _rebuildLifecycle();
      await _record(
        type: RideEventType.riderJoined,
        payload: {
          'displayName': session.displayName,
          'role': session.role.name,
          'motorcycleStyle': session.motorcycleStyle.name,
          'riderColor': session.riderColor.name,
        },
      );
    });
  }

  Future<void> setRole(RideRole role) async {
    await _run(() async {
      final activeSession = _requireSession();
      final updated = activeSession.copyWith(role: role);
      _session = updated;
      await _sessionStore.save(updated);
      await _record(
        type: RideEventType.roleChanged,
        payload: {'role': role.name},
      );
    });
  }

  Future<void> sendQuickMessage(
    QuickMessage message, {
    Iterable<String> recipientRiderIds = const [],
  }) async {
    await _run(() async {
      final recipients = recipientRiderIds.toSet().toList(growable: false);
      await _record(
        type: RideEventType.statusMessage,
        priority: message.priority,
        expiresAt: _clock().add(const Duration(hours: 2)),
        payload: {
          'message': message.name,
          'label': message.label,
          if (recipients.isNotEmpty) 'recipientRiderIds': recipients,
        },
      );
    });
  }

  /// Shares ICE (in-case-of-emergency) info into the ride. Pass an empty
  /// [recipientRiderIds] to share with the whole group (an explicit rider
  /// action); pass the current leader's rider id to share with just them
  /// (the opt-in default-share-on-emergency setting). The caller resolves
  /// who "the leader" currently is, the same way it already resolves
  /// emergency-alert recipients.
  Future<void> shareEmergencyInfo({
    required String contactName,
    required String contactPhone,
    required String medicalNotes,
    required Iterable<String> recipientRiderIds,
  }) async {
    await _run(() async {
      final activeSession = _requireSession();
      final recipients = recipientRiderIds.toSet().toList(growable: false);
      await _record(
        type: RideEventType.iceInfoShared,
        priority: EventPriority.critical,
        expiresAt: _clock().add(const Duration(hours: 2)),
        payload: {
          'contactName': contactName,
          'contactPhone': contactPhone,
          'medicalNotes': medicalNotes,
          'sharedByDisplayName': activeSession.displayName,
          if (recipients.isNotEmpty) 'recipientRiderIds': recipients,
        },
      );
    });
  }

  /// Records that the local rider has opened a share sent to them, so the
  /// original sharer can see it was seen. A no-op if already recorded.
  Future<void> markIceInfoViewed(String sharedEventId) async {
    final localId = _session?.localRiderId;
    if (localId == null) return;
    final alreadyViewed = _events.any(
      (event) =>
          event.type == RideEventType.iceInfoViewed &&
          event.deviceId == localId &&
          event.payload['sharedEventId'] == sharedEventId,
    );
    if (alreadyViewed) return;
    await _run(() async {
      await _record(
        type: RideEventType.iceInfoViewed,
        payload: {'sharedEventId': sharedEventId},
      );
    });
  }

  /// Marks a received ICE share as acted on (called or texted the
  /// contact), exempting it from the ride-end purge below.
  void markIceShareUsed(String eventId) {
    if (_usedIceShareEventIds.add(eventId)) {
      notifyListeners();
    }
  }

  Future<void> pauseRide() => _setRidePaused(true);

  Future<void> resumeRide() => _setRidePaused(false);

  Future<void> startRide() async {
    if (rideStarted || rideEnded) return;
    await _run(() async {
      final session = _requireSession();
      if (session.role != RideRole.lead) {
        throw const FormatException('Only the ride leader can start the ride.');
      }
      await _record(
        type: RideEventType.rideStarted,
        priority: EventPriority.important,
        payload: {
          'leaderRiderId': session.localRiderId,
          'leaderDisplayName': session.displayName,
        },
      );
    });
  }

  Future<void> publishRoute(ImportedRoute route) async {
    await _run(() async {
      final session = _requireSession();
      if (!isLocalRideLeader) {
        throw const FormatException(
          'Only the ride leader can change the group route.',
        );
      }
      final encoded = const RideRouteEncoder().encode(route);
      final revisionId = _idFactory();
      final revisionNumber = _routeState.revisionNumber + 1;
      for (var index = 0; index < encoded.chunks.length; index += 1) {
        await _record(
          type: RideEventType.routeRevisionChunk,
          priority: EventPriority.important,
          payload: {
            'revisionId': revisionId,
            'revisionNumber': revisionNumber,
            'leaderRiderId': session.localRiderId,
            'index': index,
            'data': encoded.chunks[index],
          },
        );
      }
      await _record(
        type: RideEventType.routeRevisionPublished,
        priority: EventPriority.important,
        payload: {
          'revisionId': revisionId,
          'revisionNumber': revisionNumber,
          'leaderRiderId': session.localRiderId,
          'chunkCount': encoded.chunks.length,
          'compressedBytes': encoded.compressedBytes,
          'sha256': encoded.sha256Digest,
          'routeName': route.name,
        },
      );
    });
  }

  Future<void> clearRoute() async {
    await _run(() async {
      final session = _requireSession();
      if (!isLocalRideLeader) {
        throw const FormatException(
          'Only the ride leader can clear the group route.',
        );
      }
      await _record(
        type: RideEventType.routeCleared,
        priority: EventPriority.important,
        payload: {
          'revisionId': _idFactory(),
          'revisionNumber': _routeState.revisionNumber + 1,
          'leaderRiderId': session.localRiderId,
        },
      );
    });
  }

  Future<void> _setRidePaused(bool paused) async {
    if (ridePaused == paused) return;
    await _run(() async {
      final session = _requireSession();
      if (!rideStarted) {
        throw const FormatException('Start the ride before pausing it.');
      }
      if (session.role != RideRole.lead) {
        throw const FormatException(
          'Only the ride leader can pause the group.',
        );
      }
      await _record(
        type: paused ? RideEventType.ridePaused : RideEventType.rideResumed,
        priority: EventPriority.important,
        payload: const {},
      );
    });
  }

  Future<void> startMarker({
    String mode = 'manual',
    String? decisionPointId,
  }) async {
    if (markerActive) {
      return;
    }
    await _run(() async {
      if (!rideStarted) {
        throw const FormatException('Start the ride before using marker mode.');
      }
      final activeSession = _requireSession();
      _roleBeforeMarker = activeSession.role;
      final markerSessionId = _idFactory();
      final updated = activeSession.copyWith(role: RideRole.marker);
      _session = updated;
      await _sessionStore.save(updated);
      await _record(
        type: RideEventType.markerStarted,
        priority: EventPriority.important,
        payload: {
          'mode': mode,
          'markerSessionId': markerSessionId,
          'decisionPointId': ?decisionPointId,
          'previousRole': activeSession.role.name,
        },
      );
    });
  }

  Future<void> recordMarkerPass(
    String riderId, {
    String? evidenceEventId,
    RideRole? riderRole,
    DateTime? observedAt,
  }) async {
    final markerSession = currentMarkerSession;
    if (!markerActive ||
        markerSession == null ||
        markerSession.uniqueRiderIds.contains(riderId)) {
      return;
    }
    await _run(() async {
      await _record(
        type: RideEventType.markerPass,
        payload: {
          'riderId': riderId,
          'markerSessionId': markerSession.sessionId,
          'authenticated': evidenceEventId != null,
          'evidenceEventId': ?evidenceEventId,
          'role': ?riderRole?.name,
          'observedAt': ?observedAt?.toUtc().toIso8601String(),
        },
      );
    });
  }

  Future<void> endMarker() async {
    if (!markerActive) {
      return;
    }
    await _run(() async {
      final current = currentMarkerSession;
      final roleAfterMarker =
          _roleBeforeMarker ?? _activeMarkerPreviousRole() ?? RideRole.rider;
      await _record(
        type: RideEventType.markerEnded,
        priority: EventPriority.important,
        payload: {
          'markerSessionId': current?.sessionId,
          'uniquePasses': current?.uniquePassCount ?? 0,
          'verifiedPasses': current?.verifiedPassCount ?? 0,
          'tecPassed': current?.tecPassedAt != null,
        },
      );
      final activeSession = _requireSession();
      final updated = activeSession.copyWith(role: roleAfterMarker);
      _session = updated;
      _roleBeforeMarker = null;
      await _sessionStore.save(updated);
    });
  }

  Future<void> endRide() async {
    if (rideEnded) return;
    await _run(() async {
      _requireSession();
      if (!isLocalRideLeader) {
        throw const FormatException('Only the ride leader can end the ride.');
      }
      if (markerActive) {
        final current = currentMarkerSession;
        await _record(
          type: RideEventType.markerEnded,
          priority: EventPriority.important,
          payload: {
            'markerSessionId': current?.sessionId,
            'uniquePasses': current?.uniquePassCount ?? 0,
            'verifiedPasses': current?.verifiedPassCount ?? 0,
            'tecPassed': current?.tecPassedAt != null,
            'reason': 'ride-ended',
          },
        );
      }
      final summary = markingSummary;
      await _record(
        type: RideEventType.rideEnded,
        priority: EventPriority.important,
        payload: {'markingSummary': summary.toJson()},
      );
      _roleBeforeMarker = null;
      await _purgeUnusedIceSharesIfEnded();
      await _expireEndedRideIfDue();
    });
  }

  Future<void> clearEndedRide() async {
    if (!rideEnded) return;
    await _run(() async {
      await _removeRideData();
    });
  }

  Future<void> leaveRide({
    Future<void> Function(RideEvent departure)? publishDeparture,
  }) async {
    await _run(() async {
      final session = _requireSession();
      final departure = await _record(
        type: RideEventType.riderLeft,
        priority: EventPriority.important,
        expiresAt: _clock().add(const Duration(hours: 24)),
        payload: {
          'riderId': session.localRiderId,
          'displayName': session.displayName,
          'reason': 'left',
        },
      );
      if (publishDeparture != null) {
        try {
          await publishDeparture(departure);
        } on Object catch (error, stackTrace) {
          if (kDebugMode) {
            debugPrint('Departure remains queued locally: $error\n$stackTrace');
          }
        }
      }
      await _removeRideData(deleteEvents: false);
    });
  }

  void clearError() {
    _errorMessage = null;
    notifyListeners();
  }

  Future<RideEvent> _record({
    required RideEventType type,
    required Map<String, Object?> payload,
    EventPriority priority = EventPriority.routine,
    DateTime? expiresAt,
  }) async {
    final activeSession = _requireSession();
    final now = _clock();
    final id = _idFactory();
    final unsignedEvent = RideEvent(
      id: id,
      rideId: activeSession.rideId,
      deviceId: activeSession.localRiderId,
      type: type,
      priority: priority,
      createdAt: now,
      expiresAt: expiresAt,
      payload: payload,
      signature: '',
    );
    final event = RideEvent(
      id: unsignedEvent.id,
      rideId: unsignedEvent.rideId,
      deviceId: unsignedEvent.deviceId,
      type: unsignedEvent.type,
      priority: unsignedEvent.priority,
      createdAt: unsignedEvent.createdAt,
      expiresAt: unsignedEvent.expiresAt,
      payload: unsignedEvent.payload,
      signature: RideEventAuthenticator.sign(
        unsignedEvent,
        activeSession.inviteSecret,
      ),
    );
    await _eventStore.append(event);
    _events = [..._events, event];
    _rebuildLifecycle();
    return event;
  }

  Future<void> _createRide({
    required String displayName,
    bool isSimulation = false,
    int simulationRiderCount = RideSession.defaultSimulationRiderCount,
    MotorcycleIconStyle motorcycleStyle = motorcycleIconStyleDefault,
    RiderColor riderColor = riderColorDefault,
    String? rideName,
  }) async {
    final now = _clock();
    final normalisedRideName = rideName?.trim();
    final rideId = _idFactory();
    final session = RideSession(
      rideId: rideId,
      rideCode: _generateCode(),
      inviteSecret: _generateInviteSecret(),
      joinToken: _generateJoinToken(),
      localRiderId: _localRiderIdForRide(rideId),
      displayName: _normaliseName(displayName),
      role: RideRole.lead,
      joinedAt: now,
      isSimulation: isSimulation,
      simulationRiderCount: simulationRiderCount,
      motorcycleStyle: motorcycleStyle,
      riderColor: riderColor,
      rideName: normalisedRideName == null || normalisedRideName.isEmpty
          ? null
          : normalisedRideName,
    );
    _session = session;
    await _sessionStore.save(session);
    await _record(
      type: RideEventType.rideCreated,
      payload: {
        'displayName': session.displayName,
        'role': session.role.name,
        if (isSimulation) 'simulation': true,
        'motorcycleStyle': session.motorcycleStyle.name,
        'riderColor': session.riderColor.name,
        if (session.rideName != null) 'rideName': session.rideName,
      },
    );
    if (isSimulation) {
      await _record(
        type: RideEventType.rideStarted,
        priority: EventPriority.important,
        payload: {
          'leaderRiderId': session.localRiderId,
          'leaderDisplayName': session.displayName,
          'simulation': true,
        },
      );
    }
  }

  int _validatedSimulationRiderCount(int value) {
    if (value < RideSession.minimumSimulationRiderCount ||
        value > RideSession.maximumSimulationRiderCount) {
      throw FormatException(
        'Choose between ${RideSession.minimumSimulationRiderCount} and '
        '${RideSession.maximumSimulationRiderCount} simulated riders.',
      );
    }
    return value;
  }

  Future<void> _run(Future<void> Function() operation) async {
    if (_busy) {
      return;
    }
    _busy = true;
    _errorMessage = null;
    notifyListeners();
    try {
      await operation();
    } on FormatException catch (error) {
      _errorMessage = error.message;
    } on RideCodeDirectoryException catch (error) {
      _errorMessage = error.message;
    } on Object catch (error, stackTrace) {
      _errorMessage = 'That action could not be saved. Please try again.';
      if (kDebugMode) {
        debugPrint('Ride action failed: $error\n$stackTrace');
      }
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  RideSession _requireSession() {
    final activeSession = _session;
    if (activeSession == null) {
      throw StateError('No active ride');
    }
    return activeSession;
  }

  String _normaliseName(String value) {
    final name = value.trim();
    if (name.isEmpty) {
      throw const FormatException('Enter a rider name.');
    }
    return name.length <= 24 ? name : name.substring(0, 24);
  }

  String _generateCode() => List.generate(6, (_) => _random.nextInt(10)).join();

  String _generateInviteSecret() => base64Url
      .encode(List<int>.generate(32, (_) => _random.nextInt(256)))
      .replaceAll('=', '');

  static const _joinTokenAlphabet =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';

  String _generateJoinToken() => List.generate(
    24,
    (_) => _joinTokenAlphabet[_random.nextInt(_joinTokenAlphabet.length)],
  ).join();

  String _localRiderIdForRide(String rideId) {
    final installationId = _installationId;
    if (installationId == null || installationId.isEmpty) {
      return _idFactory();
    }
    final digest = sha256.convert(
      utf8.encode('tail-end-charlie-rider-v1\n$installationId\n$rideId'),
    );
    return 'rider-${base64Url.encode(digest.bytes).replaceAll('=', '')}';
  }

  DateTime? get _rideEndedAt {
    for (final event in _events.reversed) {
      if (event.type == RideEventType.rideEnded) return event.createdAt;
    }
    return null;
  }

  Future<void> _expireEndedRideIfDue() async {
    _endedRideCleanupTimer?.cancel();
    _endedRideCleanupTimer = null;
    final endedAt = _rideEndedAt;
    if (endedAt == null || _session == null) return;
    final expiresAt = endedAt.add(endedRideRecoveryWindow);
    final delay = expiresAt.difference(_clock());
    if (delay <= Duration.zero) {
      await _removeRideData();
      notifyListeners();
      return;
    }
    _endedRideCleanupTimer = Timer(delay, () {
      unawaited(_expireEndedRideIfDue());
    });
  }

  /// Removes ICE shares this device received (not ones it sent) as soon as
  /// the ride ends, unless the recipient acted on them - so a leader's app
  /// doesn't go on holding another rider's phone number and medical notes
  /// once the ride is over, but can still follow up on one they actually
  /// used.
  Future<void> _purgeUnusedIceSharesIfEnded() async {
    final activeSession = _session;
    if (activeSession == null || !rideEnded) return;
    final localId = activeSession.localRiderId;
    final toRemove = _events
        .where(
          (event) =>
              event.type == RideEventType.iceInfoShared &&
              event.deviceId != localId &&
              _isAddressedToMe(event, localId) &&
              !_usedIceShareEventIds.contains(event.id),
        )
        .map((event) => event.id)
        .toList(growable: false);
    if (toRemove.isEmpty) return;
    await _eventStore.deleteEvents(activeSession.rideId, toRemove);
    final removed = toRemove.toSet();
    _events = _events.where((event) => !removed.contains(event.id)).toList();
  }

  Future<void> _removeRideData({bool deleteEvents = true}) async {
    _endedRideCleanupTimer?.cancel();
    _endedRideCleanupTimer = null;
    final rideId = _requireSession().rideId;
    if (deleteEvents) await _eventStore.deleteRide(rideId);
    await _sessionStore.clear();
    _session = null;
    _events = const [];
    _lifecycle = const RideLifecycle();
    _routeState = const RideRouteState();
    _roleBeforeMarker = null;
    _usedIceShareEventIds.clear();
    _transportByEventId.clear();
  }

  RideRole? _activeMarkerPreviousRole() {
    final localDeviceId = _session?.localRiderId;
    if (localDeviceId == null || !markerActive) return null;
    for (final event in _events.reversed) {
      if (event.deviceId != localDeviceId ||
          event.type != RideEventType.markerStarted) {
        continue;
      }
      final value = event.payload['previousRole'];
      if (value is! String) return null;
      try {
        return RideRole.values.byName(value);
      } on ArgumentError {
        return null;
      }
    }
    return null;
  }

  Iterable<RideEvent> get _rideActivityEvents {
    final startedAt = rideStartedAt;
    if (startedAt == null) return const [];
    return _events.where((event) => !event.createdAt.isBefore(startedAt));
  }

  void _rebuildLifecycle() {
    final activeSession = _session;
    if (activeSession == null) {
      _lifecycle = const RideLifecycle();
      _routeState = const RideRouteState();
      return;
    }
    _lifecycle = RideLifecycleReducer.fromEvents(
      rideId: activeSession.rideId,
      inviteSecret: activeSession.inviteSecret,
      events: _events,
    );
    _routeState = const RideRouteReducer().fromEvents(
      rideId: activeSession.rideId,
      inviteSecret: activeSession.inviteSecret,
      events: _events,
    );
  }

  @override
  void dispose() {
    _endedRideCleanupTimer?.cancel();
    _rideCodeDirectory.close();
    _eventStore.close();
    super.dispose();
  }
}
