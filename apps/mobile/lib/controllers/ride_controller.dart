import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';

import '../domain/event_store.dart';
import '../domain/geo_point.dart' as awareness_geo;
import '../domain/ice_share.dart';
import '../domain/imported_route.dart';
import '../domain/completed_ride_store.dart';
import '../domain/join_invite.dart';
import '../domain/marker_assistance.dart';
import '../domain/quick_message.dart';
import '../domain/ride_event.dart';
import '../domain/ride_role.dart';
import '../domain/ride_session.dart';
import '../domain/rider_color.dart';
import '../domain/session_store.dart';
import '../features/map/motorcycle_icon.dart';
import '../relay/live_presence.dart';
import '../services/nearby_bridge.dart';
import '../services/completed_ride_archiver.dart';
import '../services/marker_statistics.dart';
import '../services/ride_event_authenticator.dart';
import '../services/ride_lifecycle.dart';
import '../services/ride_membership.dart';
import '../services/received_quick_message.dart';
import '../services/ride_route_reducer.dart';
import '../services/rejoin_route_share.dart';
import '../services/rider_contact_share.dart';
import '../services/situation_event_factory.dart';
import '../services/tec_role_assignment.dart';
import '../internet/internet_relay_client.dart';

typedef Clock = DateTime Function();
typedef IdFactory = String Function();

/// Why a leader's Tail End Charlie request did or did not go out.
///
/// Every value other than [sent] is something the leader is told in words: the
/// one outcome this feature must never have is appearing to have asked somebody
/// who was never asked.
enum TecRoleRequestOutcome {
  sent,

  /// Only the current leader may ask.
  notLeader,

  /// No such rider in the live roster, or the leader picked themselves.
  invalidTarget,

  /// That rider already holds the role, so there is nothing to ask.
  alreadyTailEndCharlie,

  /// The negotiated relay cannot carry the request, so nothing was recorded.
  relayUnsupported,

  /// The journal write failed. [RideController.errorMessage] carries the reason.
  failed,
}

class RideController extends ChangeNotifier {
  RideController(
    this._eventStore,
    this._sessionStore,
    this._nearbyBridge, {
    Clock? clock,
    IdFactory? idFactory,
    Random? random,
    RideCodeDirectory? rideCodeDirectory,
    this._completedRideStore,
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
  final CompletedRideStore? _completedRideStore;
  final String? _installationId;
  final RideCodeDirectory _rideCodeDirectory;

  RideSession? _session;
  List<RideEvent> _events = const [];
  NearbyCapabilities _nearbyCapabilities =
      const NearbyCapabilities.unavailable();
  bool _busy = false;
  String? _errorMessage;
  bool _errorIsRetryable = false;
  RideRole? _roleBeforeMarker;
  Timer? _endedRideCleanupTimer;
  bool _endedRideSetAside = false;
  RideLifecycle _lifecycle = const RideLifecycle();
  RideRouteState _routeState = const RideRouteState();
  final Map<String, Set<RideTransportEvidence>> _transportByEventId = {};
  List<LiveRiderPresence> _livePresence = const [];

  /// The relay's cursor-independent roster, including the riders it reports as
  /// having left. Live presence drops a departed rider — they are not there —
  /// so this is what keeps their roster record when their membership events
  /// never reached this phone's journal (#144).
  List<PresenceRosterMember> _presenceRoster = const [];

  /// True when this device cannot currently receive live positions at all, so a
  /// missing position is attributed to the transport rather than to the rider.
  bool _positionChannelUnavailable = false;

  /// Personal-detail shares the local rider has acted on: an ICE contact they
  /// called or texted, or a rider's own number they dialled. Kept in memory
  /// only, for this session: it gates which received shares survive the
  /// ride-end purge, not a durable record of anyone's own.
  ///
  /// One set, because event ids are unique across types and the exemption rule
  /// is identical — a share you actually used may be followed up on.
  final Set<String> _usedIceShareEventIds = {};

  RideSession? get session => _session;
  EventStore get eventStore => _eventStore;
  List<RideEvent> get events => List.unmodifiable(_events);
  NearbyCapabilities get nearbyCapabilities => _nearbyCapabilities;
  bool get busy => _busy;
  String? get errorMessage => _errorMessage;

  /// True when the failure behind [errorMessage] is worth simply trying again —
  /// a connection or service problem rather than something the rider typed.
  ///
  /// Surfaced so the join form can offer a retry instead of leaving a rider
  /// staring at a sentence about a relay handshake with nothing to press (#208).
  bool get errorIsRetryable => _errorMessage != null && _errorIsRetryable;
  bool get hasActiveRide => _session != null;

  /// True when the rider has stepped away from an ended ride without filing it.
  ///
  /// Purely a navigation state: the session, the journal, the archived copy and
  /// relay recovery are all untouched. It exists because the ride-ended screen
  /// replaced the entire app and its only exit filed the ride, which stops this
  /// phone waiting for other riders' final events — so a rider who ended up
  /// there by accident had to choose between staying stuck and giving something
  /// up (#207). Two testers hit that within half an hour.
  ///
  /// Derived rather than stored so it cannot outlive the ride it refers to: a new
  /// ride clears `rideEnded`, and the flag with it.
  bool get endedRideSetAside => _endedRideSetAside && rideEnded;

  /// Steps away from an ended ride, keeping it and all of its data intact.
  void setEndedRideAside() {
    if (!rideEnded || _endedRideSetAside) return;
    _endedRideSetAside = true;
    notifyListeners();
  }

  /// Re-opens an ended ride the rider stepped away from.
  void reopenEndedRide() {
    if (!_endedRideSetAside) return;
    _endedRideSetAside = false;
    notifyListeners();
  }

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

  /// The reconciled live presence most recently observed, keyed by rider.
  List<LiveRiderPresence> get livePresence => List.unmodifiable(_livePresence);

  /// The one reconciled live model. The rider count, the roster, the main map
  /// and the mini-map all derive from this, so no two of them can disagree about
  /// whether a rider is present or where they are (#132).
  RideLiveView get liveView => RideLiveView.reconcile(
    participants: _participantsFromEvents(),
    presence: _livePresence,
    positionChannelUnavailable: _positionChannelUnavailable,
  );

  List<RideParticipant> get participants => liveView.participants;

  /// Whether this phone can receive live positions at all.
  ///
  /// Exposed so one surface can reconcile it with the event batch's own status
  /// instead of two cards contradicting each other (#174).
  bool get positionChannelUnavailable => _positionChannelUnavailable;

  List<RideParticipant> _participantsFromEvents() {
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
      livePresence: _livePresence,
      presenceRoster: _presenceRoster,
    );
  }

  /// Records what the live-presence channels can currently see.
  ///
  /// This is how a join reaches the roster and the map without waiting for the
  /// bulk event batch: presence is a separate request with no cursor, so a
  /// wedged or backed-off journal sync cannot hide a reachable participant.
  /// The durable journal stays authoritative — a rider who has left is never
  /// resurrected by presence.
  ///
  /// [roster] is the relay's own membership list, which unlike [presence] still
  /// names the riders who have left. It is what keeps a departed rider's roster
  /// record for the rest of the ride (#144); it never adds anybody to the live
  /// count, because a departed rider is not counted anywhere.
  void observeLivePresence(
    Iterable<LiveRiderPresence> presence, {
    Iterable<PresenceRosterMember> roster = const [],
    bool positionChannelUnavailable = false,
  }) {
    final next = presence.toList(growable: false);
    final nextRoster = roster.toList(growable: false);
    if (_isSamePresence(_livePresence, next) &&
        _isSameRoster(_presenceRoster, nextRoster) &&
        positionChannelUnavailable == _positionChannelUnavailable) {
      return;
    }
    _livePresence = next;
    _presenceRoster = nextRoster;
    _positionChannelUnavailable = positionChannelUnavailable;
    notifyListeners();
  }

  /// A departure that arrives on the roster alone still has to reach the UI, so
  /// the no-churn check covers the roster as well as the positions.
  static bool _isSameRoster(
    List<PresenceRosterMember> current,
    List<PresenceRosterMember> next,
  ) {
    if (current.length != next.length) return false;
    for (var index = 0; index < current.length; index += 1) {
      final left = current[index];
      final right = next[index];
      if (left.riderId != right.riderId ||
          left.displayName != right.displayName ||
          left.role != right.role ||
          left.joinedAt != right.joinedAt ||
          left.left != right.left ||
          left.leftAt != right.leftAt) {
        return false;
      }
    }
    return true;
  }

  static bool _isSamePresence(
    List<LiveRiderPresence> current,
    List<LiveRiderPresence> next,
  ) {
    if (current.length != next.length) return false;
    for (var index = 0; index < current.length; index += 1) {
      final left = current[index];
      final right = next[index];
      if (left.riderId != right.riderId ||
          left.freshness != right.freshness ||
          left.displayName != right.displayName ||
          left.role != right.role ||
          !setEquals(left.sources, right.sources) ||
          left.location?.sample.recordedAt !=
              right.location?.sample.recordedAt) {
        return false;
      }
    }
    return true;
  }

  List<RideParticipant> get liveParticipants => liveView.liveParticipants;

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

  /// Cached against the journal it was derived from.
  ///
  /// This walk parses a timestamp and authenticates a signature for every
  /// position fix in the ride, and it is reached from [markingSummary], which
  /// the dashboard reads during build. Recomputing it per build is what made
  /// rotating and opening a menu cost over a second at the end of a long ride
  /// (#165). `_events` is replaced wholesale whenever the journal changes, so
  /// its identity is a sound cache key, and the result depends on nothing else
  /// that varies - notably not on the clock.
  List<RideEvent>? _evidenceJournal;
  Map<String, String>? _evidence;

  Map<String, String> get _authenticatedLocationEvidence {
    if (identical(_evidenceJournal, _events) && _evidence != null) {
      return _evidence!;
    }
    final computed = _computeAuthenticatedLocationEvidence();
    _evidenceJournal = _events;
    _evidence = computed;
    return computed;
  }

  Map<String, String> _computeAuthenticatedLocationEvidence() {
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
      await _archiveCurrentRideIfComplete();
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
    await _archiveCurrentRideIfComplete();
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

  // ---------------------------------------------------------------------------
  // Issue #128 part 1 - a leader can ask a named rider to be Tail End Charlie.
  //
  // Deliberately a request, not an assignment. Roles stay self-selected: the
  // target's acceptance records their own `roleChanged`, so the membership
  // reducer, the session's own role and every TEC surface keep exactly one
  // source of truth. These two events carry only who was asked and what they
  // answered, which is what lets the leader see pending versus accepted instead
  // of believing the back is covered when nobody is watching it.
  // ---------------------------------------------------------------------------

  /// Every leader-issued TEC request in this ride, reconciled from the journal.
  TecRoleAssignmentState get tecRoleAssignments {
    final activeSession = _session;
    if (activeSession == null) return const TecRoleAssignmentState();
    return const TecRoleAssignmentReducer().fromEvents(
      rideId: activeSession.rideId,
      inviteSecret: activeSession.inviteSecret,
      events: _events,
      now: _clock(),
    );
  }

  /// The unanswered request addressed to this phone, if any.
  TecRoleAssignment? get pendingTecRoleRequestForLocalRider {
    final localRiderId = _session?.localRiderId;
    if (localRiderId == null) return null;
    return tecRoleAssignments.pendingFor(localRiderId);
  }

  /// The rider currently holding [RideRole.lead] in the reconciled roster.
  ///
  /// Used to address a leader-only event. Null when the leader has left or is
  /// not yet known, in which case the caller must not send rather than
  /// broadcasting to the group.
  String? get leaderRiderId => liveParticipants
      .where((participant) => participant.role == RideRole.lead)
      .map((participant) => participant.riderId)
      .firstOrNull;

  /// True when a running ride has nobody holding the lead role.
  ///
  /// A leader who leaves takes the group's pace, the line the TEC is following
  /// and the route authority with them, and until #176 nothing said so: a tester
  /// left as leader to see what would happen and the ride carried on, with the
  /// remaining riders untold and nobody offered the role.
  ///
  /// Only while the ride is running. Before the start there is always a creator
  /// holding lead, and after the end there is nothing left to lead.
  bool get rideHasNoLeader =>
      rideStarted && !rideEnded && leaderRiderId == null;

  /// Asks [targetRiderId] to take the Tail End Charlie role.
  ///
  /// [relayCanCarryRequest] is the negotiated `tec-role-assignment-v1`
  /// capability. When it is false nothing is recorded at all: a request that
  /// cannot leave this phone must not sit on the leader's screen looking sent.
  Future<TecRoleRequestOutcome> requestTecRole({
    required String targetRiderId,
    required String targetDisplayName,
    bool relayCanCarryRequest = true,
  }) async {
    final activeSession = _session;
    if (activeSession == null || !isLocalRideLeader) {
      return TecRoleRequestOutcome.notLeader;
    }
    if (targetRiderId == activeSession.localRiderId) {
      return TecRoleRequestOutcome.invalidTarget;
    }
    final target = participantFor(targetRiderId);
    if (target == null || !target.isIncludedInLiveCount) {
      return TecRoleRequestOutcome.invalidTarget;
    }
    if (target.role == RideRole.tailEndCharlie) {
      return TecRoleRequestOutcome.alreadyTailEndCharlie;
    }
    if (!relayCanCarryRequest) {
      return TecRoleRequestOutcome.relayUnsupported;
    }
    await _run(() async {
      await _record(
        type: RideEventType.tecRoleRequested,
        priority: EventPriority.important,
        // Outlives the reducer's ten-minute pending window so the answer and
        // the question are never orphaned from each other in the journal.
        expiresAt: _clock().add(const Duration(hours: 2)),
        payload: TecRoleAssignmentReducer.requestPayload(
          requestId: _idFactory(),
          leaderRiderId: activeSession.localRiderId,
          targetRiderId: targetRiderId,
          targetDisplayName: targetDisplayName,
        ),
      );
    });
    return _errorMessage == null
        ? TecRoleRequestOutcome.sent
        : TecRoleRequestOutcome.failed;
  }

  /// Answers the request addressed to this phone.
  ///
  /// Accepting records the answer **and** the local rider's own
  /// [RideEventType.roleChanged], in that order, so a peer that reads only one
  /// of the two still converges: the role change alone is the existing
  /// self-selection, and the answer alone leaves the leader's view honest.
  Future<bool> respondToTecRoleRequest({
    required String requestId,
    required bool accepted,
  }) async {
    final activeSession = _session;
    if (activeSession == null) return false;
    final pending = tecRoleAssignments.pendingFor(activeSession.localRiderId);
    if (pending == null || pending.requestId != requestId) return false;
    await _run(() async {
      await _record(
        type: RideEventType.tecRoleResponded,
        priority: EventPriority.important,
        expiresAt: _clock().add(const Duration(hours: 2)),
        payload: TecRoleAssignmentReducer.responsePayload(
          requestId: requestId,
          targetRiderId: activeSession.localRiderId,
          accepted: accepted,
        ),
      );
      if (!accepted) return;
      final updated = activeSession.copyWith(role: RideRole.tailEndCharlie);
      _session = updated;
      await _sessionStore.save(updated);
      await _record(
        type: RideEventType.roleChanged,
        payload: {'role': RideRole.tailEndCharlie.name},
      );
    });
    return _errorMessage == null;
  }

  // ---------------------------------------------------------------------------
  // Issue #128 part 2 - a separated rider's rejoin route, for the leader only.
  // ---------------------------------------------------------------------------

  /// Rejoin routes other riders have shared with this phone, still live.
  ///
  /// Empty for everyone who is not the addressed leader, empty once the route
  /// revision moves on, and empty once the ride ends.
  Map<String, SharedRejoinRoute> get sharedRejoinRoutes {
    final activeSession = _session;
    if (activeSession == null) return const {};
    return const SharedRejoinRouteReducer().fromEvents(
      rideId: activeSession.rideId,
      inviteSecret: activeSession.inviteSecret,
      events: _events,
      localRiderId: activeSession.localRiderId,
      routeRevisionNumber: _routeState.revisionNumber,
      now: _clock(),
      departedRiderIds: participants
          .where((participant) => !participant.isIncludedInLiveCount)
          .map((participant) => participant.riderId),
      rideEnded: rideEnded,
    );
  }

  /// Relays [share] to the current leader, and to nobody else.
  ///
  /// Returns false without recording anything when there is no known leader or
  /// the negotiated relay cannot carry it — the rider keeps their own guidance
  /// either way, and the caller names the limitation.
  Future<bool> shareRejoinRoute(
    SharedRejoinRoute share, {
    bool relayCanCarryShare = true,
  }) async {
    final activeSession = _session;
    if (activeSession == null || !relayCanCarryShare) return false;
    if (share.riderId != activeSession.localRiderId) return false;
    final leader = leaderRiderId;
    if (leader == null || leader == activeSession.localRiderId) return false;
    await _run(() async {
      await _record(
        type: RideEventType.rejoinRouteShared,
        // The same retention band as a location event: this is where a rider is
        // about to be, so it is treated as perishable as where they are.
        expiresAt: share.expiresAt,
        payload: SharedRejoinRouteReducer.payload(
          share: share,
          leaderRiderId: leader,
        ),
      );
    });
    return _errorMessage == null;
  }

  /// Raises a quick message into the ride.
  ///
  /// [position] is where the sender is standing. It is relayed with the message
  /// because "Bill needs fuel" is not actionable without "1.2 miles back"
  /// (#151), and because a stopped rider's own location events age out of the
  /// 30-minute retention band while the message itself lives for two hours.
  /// [senderDisplayName] comes from the session for the same reason
  /// `iceInfoShared` carries it: the recipient may not have this rider in their
  /// roster yet.
  Future<void> sendQuickMessage(
    QuickMessage message, {
    Iterable<String> recipientRiderIds = const [],
    awareness_geo.GeoPoint? position,
  }) async {
    await _run(() async {
      final activeSession = _requireSession();
      final recipients = recipientRiderIds.toSet().toList(growable: false);
      await _record(
        type: RideEventType.statusMessage,
        priority: message.priority,
        expiresAt: _clock().add(const Duration(hours: 2)),
        payload: {
          'message': message.name,
          'label': message.label,
          'senderDisplayName': activeSession.displayName,
          if (position != null) 'position': position.toJson(),
          if (recipients.isNotEmpty) 'recipientRiderIds': recipients,
        },
      );
    });
  }

  /// Quick messages this phone should be presenting, most urgent first.
  ///
  /// Includes this rider's own outstanding messages, so a sender can be shown
  /// that theirs was seen — the whole point of raising one. Callers separate the
  /// two on [ReceivedQuickMessage.raisedFromLocalRider].
  List<ReceivedQuickMessage> get quickMessages {
    final activeSession = _session;
    if (activeSession == null) return const [];
    return const ReceivedQuickMessageReducer().fromEvents(
      rideId: activeSession.rideId,
      inviteSecret: activeSession.inviteSecret,
      events: _events,
      localRiderId: activeSession.localRiderId,
      now: _clock(),
      displayNames: {
        for (final participant in participants)
          participant.riderId: participant.displayName,
      },
      departedRiderIds: participants
          .where((participant) => !participant.isIncludedInLiveCount)
          .map((participant) => participant.riderId),
      rideEnded: rideEnded,
    );
  }

  /// Records that this rider has seen [message], so its sender is told.
  ///
  /// A no-op when already recorded, the same guard [markIceInfoViewed] keeps: a
  /// second tap must not put a second acknowledgement into the journal.
  Future<void> acknowledgeQuickMessage(ReceivedQuickMessage message) async {
    final localId = _session?.localRiderId;
    if (localId == null || message.acknowledgedBy(localId)) return;
    await _run(() async {
      await _record(
        type: RideEventType.statusMessage,
        priority: EventPriority.important,
        expiresAt: _clock().add(const Duration(hours: 2)),
        payload: {
          ...ReceivedQuickMessageReducer.acknowledgementPayload(
            message: message,
          ),
          'senderDisplayName': _requireSession().displayName,
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

  /// Shares the local rider's **own** phone number into the ride (issue #188).
  ///
  /// Nothing here touches ICE. [phoneNumber] is the rider's own number, and
  /// [recipients] is resolved by [RiderContactRecipients] — the leader and TEC
  /// for an ordinary rider, the ride for whoever holds a coordination role,
  /// because a contact for the role is useless addressed to the other
  /// role-holder.
  ///
  /// Returns false without recording anything when the number is not dialable
  /// or there is nobody to address it to, so the caller can say so rather than
  /// letting a rider believe a number went out.
  Future<bool> shareOwnContactNumber({
    required String phoneNumber,
    required RiderContactRecipients recipients,
  }) async {
    final activeSession = _session;
    final normalised = RiderContactShare.normalisePhoneNumber(phoneNumber);
    if (activeSession == null || normalised == null || recipients.isEmpty) {
      return false;
    }
    await _run(() async {
      final share = RiderContactShare(
        // Filled in by the journal; the payload never carries an event id.
        eventId: '',
        riderId: activeSession.localRiderId,
        displayName: activeSession.displayName,
        phoneNumber: normalised,
        sharedAt: _clock(),
        sharedByRole: activeSession.role,
        toRideGroup: recipients.toRideGroup,
      );
      await _record(
        type: RideEventType.riderContactShared,
        // Important rather than critical: this is a contact detail, not an
        // alert. The emergency alert is the critical event, and it does not
        // depend on a number existing.
        priority: EventPriority.important,
        // The same retention band as an ICE share, and the ride-end purge
        // normally gets there first.
        expiresAt: _clock().add(riderContactShareLifetime),
        payload: RiderContactShareReducer.payload(
          share: share,
          recipients: recipients,
        ),
      );
    });
    return _errorMessage == null;
  }

  /// Numbers other riders have shared with the local rider, keyed by rider id.
  ///
  /// Empty once the ride has ended, and never includes the local rider's own.
  /// This is the only source the dial controls read: nothing derives a number
  /// from the roster, a location event or a presence row.
  Map<String, RiderContactShare> get receivedRiderContacts {
    final activeSession = _session;
    if (activeSession == null) return const {};
    return const RiderContactShareReducer().fromEvents(
      rideId: activeSession.rideId,
      inviteSecret: activeSession.inviteSecret,
      events: _events,
      localRiderId: activeSession.localRiderId,
      now: _clock(),
      departedRiderIds: participants
          .where((participant) => !participant.isIncludedInLiveCount)
          .map((participant) => participant.riderId),
      rideEnded: rideEnded,
    );
  }

  /// Whether this rider's own number is already in the journal for this ride, so
  /// the share control can say "shared" instead of recording it twice.
  bool get hasSharedOwnContactNumber {
    final localId = _session?.localRiderId;
    if (localId == null) return false;
    return _events.any(
      (event) =>
          event.type == RideEventType.riderContactShared &&
          event.deviceId == localId,
    );
  }

  /// Marks a received number as dialled, exempting it from the ride-end purge
  /// for the same reason a used ICE share is exempt: a rider who has just phoned
  /// somebody may need to phone them again.
  void markRiderContactUsed(String eventId) => markIceShareUsed(eventId);

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
      await _archiveCurrentRideIfComplete();
      _roleBeforeMarker = null;
      await _purgeUnusedIceSharesIfEnded();
      await _expireEndedRideIfDue();
    });
  }

  Future<void> clearEndedRide() async {
    if (!rideEnded) return;
    await _run(() async {
      await _archiveCurrentRideIfComplete();
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
      await _archiveCurrentRideIfComplete(force: true);
      await _removeRideData(deleteEvents: false);
    });
  }

  void clearError() {
    _errorMessage = null;
    _errorIsRetryable = false;
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
    _errorIsRetryable = false;
    notifyListeners();
    try {
      await operation();
    } on FormatException catch (error) {
      // The rider's own input. Retrying it unchanged would fail identically.
      _errorMessage = error.message;
    } on RideCodeDirectoryException catch (error) {
      _errorMessage = error.message;
      _errorIsRetryable = error.retryable;
    } on Object catch (error, stackTrace) {
      _errorMessage = 'That action could not be saved. Please try again.';
      _errorIsRetryable = true;
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
      await _archiveCurrentRideIfComplete();
      await _removeRideData();
      notifyListeners();
      return;
    }
    _endedRideCleanupTimer = Timer(delay, () {
      unawaited(_expireEndedRideIfDue());
    });
  }

  Future<void> _archiveCurrentRideIfComplete({bool force = false}) async {
    final store = _completedRideStore;
    final activeSession = _session;
    if (store == null ||
        activeSession == null ||
        activeSession.isSimulation ||
        (!force && !rideEnded) ||
        (force && !rideStarted && !rideEnded)) {
      return;
    }
    final archivedAt = _rideEndedAt ?? _clock();
    final snapshot = const CompletedRideArchiver().create(
      session: activeSession,
      events: _events,
      archivedAt: archivedAt,
      plannedRoute: _routeState.route,
    );
    await store.save(snapshot);
  }

  /// Removes personal-detail shares this device received (not ones it sent) as
  /// soon as the ride ends, unless the recipient acted on them - so a leader's
  /// app doesn't go on holding another rider's phone number and medical notes
  /// once the ride is over, but can still follow up on one they actually
  /// used.
  ///
  /// Both share types are purged together and on the same rule: an ICE contact
  /// ([RideEventType.iceInfoShared]) and a rider's own number
  /// ([RideEventType.riderContactShared], issue #188). They are separate
  /// consents and separate fields, but identical retention - the second was
  /// added here rather than beside here precisely so it cannot be forgotten.
  Future<void> _purgeUnusedIceSharesIfEnded() async {
    final activeSession = _session;
    if (activeSession == null || !rideEnded) return;
    final localId = activeSession.localRiderId;
    final toRemove = _events
        .where(
          (event) =>
              (event.type == RideEventType.iceInfoShared ||
                  event.type == RideEventType.riderContactShared) &&
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
    _endedRideSetAside = false;
    final rideId = _requireSession().rideId;
    if (deleteEvents) await _eventStore.deleteRide(rideId);
    await _sessionStore.clear();
    _session = null;
    _events = const [];
    _evidenceJournal = null;
    _evidence = null;
    _lifecycle = const RideLifecycle();
    _routeState = const RideRouteState();
    _roleBeforeMarker = null;
    _usedIceShareEventIds.clear();
    _transportByEventId.clear();
    _livePresence = const [];
    _presenceRoster = const [];
    _positionChannelUnavailable = false;
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
