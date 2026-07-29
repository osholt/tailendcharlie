import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../domain/event_store.dart';
import '../domain/geo_point.dart';
import '../domain/hazard.dart';
import '../domain/ride_event.dart';
import '../domain/ride_role.dart';
import '../domain/ride_session.dart';
import '../domain/rider_location.dart';
import '../domain/route_alert.dart';
import '../relay/live_presence.dart';
import '../services/external_hazard_provider.dart';
import '../services/hazard_deduplicator.dart';
import '../services/route_deviation_detector.dart';
import '../services/leader_track_exemption.dart';
import '../services/situation_event_factory.dart';

class SituationalAwarenessController extends ChangeNotifier {
  SituationalAwarenessController(
    this._eventStore,
    this._session, {
    required List<GeoPoint> route,
    List<List<GeoPoint>>? routeSegments,
    List<ExternalHazardProvider> externalProviders = const [],
    SituationClock? clock,
    SituationIdFactory? idFactory,
    this.rideStarted = true,
    this.rideStartedAt,
    this.expiryPolicy = const HazardExpiryPolicy(),
    this.deduplicator = const HazardDeduplicator(),
    this.routeConfig = const RouteDeviationConfig(),
    this.freshnessPolicy = const PresenceFreshnessPolicy(),
  }) : _route = List.unmodifiable(route),
       _routeSegments = List.unmodifiable(
         (routeSegments ?? [route]).map(
           (segment) => List<GeoPoint>.unmodifiable(segment),
         ),
       ),
       _externalProviders = List.unmodifiable(externalProviders),
       _clock = clock ?? DateTime.now,
       _idFactory = idFactory ?? const Uuid().v7 {
    _eventFactory = SituationEventFactory(
      session: _session,
      clock: _clock,
      idFactory: _idFactory,
    );
  }

  final EventStore _eventStore;
  RideSession _session;
  final List<GeoPoint> _route;
  final List<List<GeoPoint>> _routeSegments;
  final List<ExternalHazardProvider> _externalProviders;
  final SituationClock _clock;
  final SituationIdFactory _idFactory;
  final bool rideStarted;
  final DateTime? rideStartedAt;
  final HazardExpiryPolicy expiryPolicy;
  final HazardDeduplicator deduplicator;
  final RouteDeviationConfig routeConfig;

  /// Documented age thresholds shared with the ephemeral presence channels, so
  /// the journal side and the presence side cannot disagree about whether a
  /// position is live, ageing or stale.
  final PresenceFreshnessPolicy freshnessPolicy;
  late SituationEventFactory _eventFactory;

  final Map<String, RiderLocation> _locations = {};
  final Map<String, RiderLocationEvidence> _locationEvidence = {};
  final Map<String, HazardReport> _hazards = {};
  final Map<String, RiderRouteAlert> _alerts = {};
  final Map<String, RouteDeviationDetector> _detectors = {};
  final Map<String, bool> _followingLeaderTrack = {};
  final List<({DateTime recordedAt, GeoPoint position})> _leaderTrail = [];
  bool _busy = false;
  bool _refreshingStaleness = false;
  String? _errorMessage;

  bool get busy => _busy;
  String? get errorMessage => _errorMessage;
  List<GeoPoint> get route => _route;

  /// The current ride leader's own recorded path so far - the group's live
  /// ground truth. Riders are judged against this (as well as the planned
  /// route, if any) so a leader's deliberate on-route deviation, such as a
  /// road-closure detour, doesn't read as the group having gone off course.
  List<GeoPoint> get leaderTrail => List.unmodifiable(_leaderTrailPoints);

  List<RiderLocation> get riderLocations {
    final values = _locations.values.toList(growable: false);
    values.sort(
      (first, second) => first.displayName.compareTo(second.displayName),
    );
    return List.unmodifiable(values);
  }

  /// The journal's contribution to the reconciled live-position model.
  ///
  /// This controller owns the durable side only. Callers merge it with the
  /// ephemeral presence channels through [LivePresenceReconciler] so one model
  /// spans both ride phases and both transports; doing the merge here would
  /// make an ephemeral snapshot look like ride history.
  List<LiveRiderPresence> livePresenceAt(DateTime now) =>
      LivePresenceReconciler(policy: freshnessPolicy).reconcile(
        now: now,
        localRiderId: _session.localRiderId,
        journal: _locations.values,
      );

  List<HazardReport> get activeHazards {
    final now = _clock();
    final values = _hazards.values
        .where((hazard) => hazard.isActiveAt(now))
        .toList();
    values.sort((first, second) {
      final bySeverity = second.severity.index.compareTo(first.severity.index);
      return bySeverity != 0
          ? bySeverity
          : second.updatedAt.compareTo(first.updatedAt);
    });
    return List.unmodifiable(values);
  }

  List<RiderRouteAlert> get routeAlerts {
    final values = _alerts.values
        .map(_exemptIfFollowingLeaderTrack)
        .where((alert) => alert.assessment.alertLevel != RouteAlertLevel.none)
        .toList();
    values.sort(
      (first, second) => second.assessment.alertLevel.index.compareTo(
        first.assessment.alertLevel.index,
      ),
    );
    return List.unmodifiable(values);
  }

  List<ExternalHazardProvider> get externalProviders => _externalProviders;

  RiderLocation? get localLocation => _locations[_session.localRiderId];

  List<RiderLocationEvidence> get authenticatedLocationEvidence =>
      List.unmodifiable(
        _locationEvidence.values.where((evidence) => evidence.authenticated),
      );

  RiderLocationEvidence? locationEvidenceFor(String riderId) =>
      _locationEvidence[riderId];

  RiderRouteAlert? alertFor(String riderId) {
    final alert = _alerts[riderId];
    return alert == null ? null : _exemptIfFollowingLeaderTrack(alert);
  }

  /// Whether [riderId]'s most recent fix was inside the ride leader's live
  /// track corridor. Such a rider is on route by definition.
  bool isFollowingLeaderTrack(String riderId) =>
      _followingLeaderTrack[riderId] ?? false;

  void updateLocalSession(RideSession session) {
    if (session.rideId != _session.rideId ||
        session.localRiderId != _session.localRiderId) {
      throw ArgumentError('Cannot replace awareness with another ride session');
    }
    _session = session;
    _eventFactory = SituationEventFactory(
      session: session,
      clock: _clock,
      idFactory: _idFactory,
    );
  }

  Future<void> initialize({Iterable<RideEvent>? restoredEvents}) async {
    final events =
        restoredEvents ?? await _eventStore.eventsForRide(_session.rideId);
    var replayed = 0;
    for (final event in events) {
      _applyEvent(event, replaying: true);
      replayed += 1;
      // A restored group ride can contain tens of thousands of positions. The
      // reducer remains ordered, but yields between bounded batches so Android
      // can draw and respond while the journal is projected into map state
      // (#209).
      if (replayed % 250 == 0) {
        await Future<void>.delayed(Duration.zero);
      }
    }
    _removeExpiredHazards();
    notifyListeners();
  }

  Future<void> recordLocalLocation(LocationSample sample) async {
    if (!rideStarted ||
        (rideStartedAt != null && sample.recordedAt.isBefore(rideStartedAt!))) {
      return;
    }
    final location = RiderLocation(
      riderId: _session.localRiderId,
      displayName: _session.displayName,
      role: _session.role,
      sample: sample,
      receivedAt: _clock(),
      motorcycleStyle: _session.motorcycleStyle,
      riderSymbol: _session.riderSymbol,
      riderColor: _session.riderColor,
    );
    await _run(() async {
      final previousAlert = _alerts[location.riderId]?.assessment;
      final event = _eventFactory.create(
        type: RideEventType.riderLocationUpdated,
        payload: {'location': location.toJson()},
        expiresAt: _clock().add(const Duration(minutes: 30)),
      );
      await _appendAndApply(event);
      final currentAlert = _alerts[location.riderId]?.assessment;
      if (previousAlert?.state != currentAlert?.state ||
          previousAlert?.alertLevel != currentAlert?.alertLevel ||
          previousAlert?.audience != currentAlert?.audience) {
        await _persistAlertTransition(location.riderId);
      }
    });
  }

  Future<HazardReport?> reportHazard({
    required HazardType type,
    required HazardSeverity severity,
    GeoPoint? position,
    String? details,
  }) async {
    if (!type.isRiderReportable) {
      throw const FormatException('That hazard type cannot be reported.');
    }
    HazardReport? result;
    await _run(() async {
      final reportPosition = position ?? localLocation?.sample.position;
      if (reportPosition == null) {
        throw const FormatException(
          'A current location is required to report a hazard.',
        );
      }
      final now = _clock();
      final trimmedDetails = details?.trim();
      final incoming = HazardReport(
        id: _idFactory(),
        rideId: _session.rideId,
        type: type,
        severity: severity,
        position: reportPosition,
        reportedAt: now,
        updatedAt: now,
        expiresAt: now.add(expiryPolicy.durationFor(type, severity)),
        reporterId: _session.localRiderId,
        reporterName: _session.displayName,
        source: HazardSource.rider,
        details: trimmedDetails == null || trimmedDetails.isEmpty
            ? null
            : trimmedDetails.substring(
                0,
                trimmedDetails.length > 160 ? 160 : trimmedDetails.length,
              ),
      );
      result = deduplicator.mergeOrAdd(incoming, activeHazards);
      final event = _eventFactory.create(
        type: RideEventType.hazardReported,
        payload: {'hazard': result!.toJson()},
        priority: _priorityForSeverity(result!.severity),
        expiresAt: result!.expiresAt,
      );
      await _appendAndApply(event);
    });
    return result;
  }

  Future<void> clearHazard(String hazardId, {String reason = 'cleared'}) async {
    if (!_hazards.containsKey(hazardId)) {
      return;
    }
    await _run(() async {
      final event = _eventFactory.create(
        type: RideEventType.hazardCleared,
        payload: {'hazardId': hazardId, 'reason': reason},
        priority: EventPriority.important,
      );
      await _appendAndApply(event);
    });
  }

  Future<void> acknowledgeAlert(String riderId) async {
    final alert = _alerts[riderId];
    if (alert == null || alert.acknowledged) {
      return;
    }
    await _run(() async {
      final acknowledgedAt = _clock();
      final updated = alert.copyWithAcknowledgement(
        acknowledgedBy: _session.localRiderId,
        acknowledgedAt: acknowledgedAt,
      );
      final event = _eventFactory.create(
        type: RideEventType.routeAlertAcknowledged,
        payload: {'alert': updated.toJson()},
        priority: EventPriority.important,
      );
      await _appendAndApply(event);
    });
  }

  Future<void> ingestRemoteEvent(RideEvent event) async {
    if (event.rideId != _session.rideId ||
        !_supportedSituationalEventTypes.contains(event.type)) {
      throw const FormatException('Event is not valid for this ride.');
    }
    if (!SituationEventFactory.verify(event, _session.inviteSecret)) {
      throw const FormatException('Event signature is invalid.');
    }
    await _eventStore.append(event);
    _applyEvent(event);
    notifyListeners();
  }

  Future<void> refreshExternalHazards() async {
    if (_route.isEmpty) {
      return;
    }
    await _run(() async {
      for (final provider in _externalProviders) {
        if (!provider.status.canFetch) {
          continue;
        }
        final result = await provider.fetch(
          ExternalHazardQuery(
            rideId: _session.rideId,
            route: _route,
            requestedAt: _clock(),
          ),
        );
        for (final hazard in result.hazards) {
          if (hazard.source != HazardSource.externalProvider ||
              hazard.providerId != provider.id ||
              hazard.rideId != _session.rideId) {
            continue;
          }
          final existingProviderIncident = _hazards[hazard.id];
          final merged =
              existingProviderIncident?.source ==
                      HazardSource.externalProvider &&
                  existingProviderIncident?.providerId == provider.id
              ? hazard
              : deduplicator.mergeOrAdd(hazard, activeHazards);
          final event = _eventFactory.create(
            type: RideEventType.hazardReported,
            payload: {'hazard': merged.toJson()},
            priority: _priorityForSeverity(merged.severity),
            expiresAt: merged.expiresAt,
          );
          await _appendAndApply(event);
        }
      }
    });
  }

  Future<void> refreshStaleness() async {
    if (_refreshingStaleness) return;
    _refreshingStaleness = true;
    try {
      _removeExpiredHazards();
      final locations = List<RiderLocation>.of(_locations.values);
      for (final location in locations) {
        final previous = _alerts[location.riderId]?.assessment;
        _evaluateLocation(location);
        final current = _alerts[location.riderId]?.assessment;
        if (previous?.state != current?.state ||
            previous?.alertLevel != current?.alertLevel ||
            previous?.audience != current?.audience) {
          await _persistAlertTransition(location.riderId);
        }
      }
      notifyListeners();
    } finally {
      _refreshingStaleness = false;
    }
  }

  void clearError() {
    _errorMessage = null;
    notifyListeners();
  }

  Future<void> _persistAlertTransition(String riderId) async {
    final alert = _alerts[riderId];
    if (alert == null) {
      return;
    }
    final event = _eventFactory.create(
      type: RideEventType.routeDeviationChanged,
      payload: {'alert': alert.toJson()},
      priority: _priorityForAlert(alert.assessment.alertLevel),
      expiresAt: _clock().add(const Duration(hours: 2)),
    );
    await _eventStore.append(event);
  }

  Future<void> _appendAndApply(RideEvent event) async {
    await _eventStore.append(event);
    _applyEvent(event);
  }

  void _applyEvent(RideEvent event, {bool replaying = false}) {
    if (event.rideId != _session.rideId) {
      return;
    }
    if (_isRideActivityEvent(event.type) && !_isWithinRideActivity(event)) {
      return;
    }
    switch (event.type) {
      case RideEventType.riderLocationUpdated:
        final location = RiderLocation.fromJson(
          _mapPayload(event.payload['location']),
        );
        if (rideStartedAt != null &&
            location.sample.recordedAt.isBefore(rideStartedAt!)) {
          break;
        }
        final previous = _locations[location.riderId];
        if (previous == null ||
            !location.sample.recordedAt.isBefore(previous.sample.recordedAt)) {
          _locations[location.riderId] = location;
          _locationEvidence[location.riderId] = RiderLocationEvidence(
            location: location,
            eventId: event.id,
            eventCreatedAt: event.createdAt,
            authenticated:
                event.deviceId == location.riderId &&
                SituationEventFactory.verify(event, _session.inviteSecret),
          );
          _evaluateLocation(location);
        }
        break;
      case RideEventType.hazardReported:
        final hazard = HazardReport.fromJson(
          _mapPayload(event.payload['hazard']),
        );
        if (hazard.rideId == _session.rideId && hazard.isActiveAt(_clock())) {
          _hazards[hazard.id] = hazard;
        }
        break;
      case RideEventType.hazardCleared:
        _hazards.remove(event.payload['hazardId']);
        break;
      case RideEventType.routeDeviationChanged:
      case RideEventType.routeAlertAcknowledged:
        final alert = RiderRouteAlert.fromJson(
          _mapPayload(event.payload['alert']),
        );
        final current = _alerts[alert.riderId];
        if (current == null ||
            !alert.assessment.evaluatedAt.isBefore(
              current.assessment.evaluatedAt,
            )) {
          _alerts[alert.riderId] = alert;
        }
        break;
      case RideEventType.routeRevisionChunk:
      case RideEventType.routeRevisionPublished:
      case RideEventType.routeCleared:
      case RideEventType.rideCreated:
      case RideEventType.riderJoined:
      case RideEventType.riderLeft:
      case RideEventType.roleChanged:
      case RideEventType.rideStarted:
      case RideEventType.markerStarted:
      case RideEventType.markerPass:
      case RideEventType.markerEnded:
      case RideEventType.statusMessage:
      case RideEventType.ridePaused:
      case RideEventType.rideResumed:
      case RideEventType.rideEnded:
      case RideEventType.rideReopened:
      case RideEventType.iceInfoShared:
      case RideEventType.iceInfoViewed:
      // Leader-issued TEC requests and relayed rejoin routes (#128) are
      // reconciled by their own reducers from the durable journal, not by this
      // controller. They are listed rather than defaulted so a future event
      // type still has to be considered here.
      case RideEventType.tecRoleRequested:
      case RideEventType.tecRoleResponded:
      case RideEventType.rejoinRouteShared:
      case RideEventType.riderContactShared:
        break;
    }
    if (!replaying) {
      _removeExpiredHazards();
    }
  }

  bool _isWithinRideActivity(RideEvent event) {
    if (!rideStarted) return false;
    final startedAt = rideStartedAt;
    return startedAt == null || !event.createdAt.isBefore(startedAt);
  }

  static bool _isRideActivityEvent(RideEventType type) => switch (type) {
    RideEventType.riderLocationUpdated ||
    RideEventType.routeDeviationChanged ||
    RideEventType.routeAlertAcknowledged => true,
    _ => false,
  };

  void _evaluateLocation(RiderLocation location) {
    if (location.role == RideRole.lead) {
      _recordLeaderTrailPoint(location.sample);
    }
    // Per-role, and re-applied on every fix so a hand-over mid-ride moves both
    // riders onto the right comparison without resetting their hysteresis.
    final segments = _routeSegmentsFor(location.role);
    final detector = _detectors.putIfAbsent(
      location.riderId,
      () => RouteDeviationDetector(
        _route,
        config: routeConfig,
        routeSegments: segments,
      ),
    );
    detector.updateRouteSegments(segments);
    final assessment = _applyLeaderFollowExemption(
      location,
      detector,
      detector.evaluate(location.sample, _clock()),
    );
    // Always replaced, not only when the state changes. The stored assessment is
    // what the rider is told - "you are off route by X" - and what the rejoin
    // planner reads, so keeping the one from the last state *transition* froze
    // the distance and the timestamp for as long as a rider stayed off route
    // (#162). Callers that need to know whether anything meaningful changed
    // compare state, level and audience themselves.
    _alerts[location.riderId] = RiderRouteAlert(
      riderId: location.riderId,
      displayName: location.displayName,
      assessment: assessment,
    );
  }

  /// Inserts in chronological order (by [LocationSample.recordedAt], not
  /// arrival order) since relayed and replayed events are not guaranteed to
  /// arrive in the order they were recorded. Duplicate/older-or-equal
  /// timestamps are dropped rather than reordering an already-recorded point.
  void _recordLeaderTrailPoint(LocationSample sample) {
    var index = _leaderTrail.length;
    while (index > 0 &&
        _leaderTrail[index - 1].recordedAt.isAfter(sample.recordedAt)) {
      index -= 1;
    }
    if (index > 0 &&
        !_leaderTrail[index - 1].recordedAt.isBefore(sample.recordedAt)) {
      return;
    }
    _leaderTrail.insert(index, (
      recordedAt: sample.recordedAt,
      position: sample.position,
    ));
  }

  List<GeoPoint> get _leaderTrailPoints => [
    for (final point in _leaderTrail) point.position,
  ];

  /// What a rider of [role] is compared against.
  ///
  /// A **follower** is compared against the planned route *and* the leader's
  /// live trail: a rider near either is on route, so followers keep matching an
  /// abandoned GPX until the leader has actually diverged from it.
  ///
  /// The **leader** is compared against the planned route alone. Their own live
  /// position is by definition the endpoint of their own trail, so including it
  /// measures the leader against themselves and returns approximately zero from
  /// anywhere on earth. That is why the leader was never once flagged off route
  /// in the field, never got a reroute, and never got told why turn instructions
  /// had stopped (#162). `_applyLeaderFollowExemption` already refuses to exempt
  /// the leader for exactly this reason - but the exemption never had to fire,
  /// because the geometry it guards had already been given the answer.
  List<List<GeoPoint>> _routeSegmentsFor(RideRole role) {
    if (role == RideRole.lead) return _routeSegments;
    final leaderPoints = _leaderTrailPoints;
    return [..._routeSegments, if (leaderPoints.length >= 2) leaderPoints];
  }

  // ---------------------------------------------------------------------------
  // Issue #102 - leader-follow exemption. Deliberately the only place this rule
  // is decided, so the alert state, the relayed deviation event, the roster, the
  // map and the leader's off-course count cannot disagree.
  //
  // A rider inside the corridor of the leader's ACTUAL recorded track is on
  // route whatever the planned GPX says - including when the leader has
  // abandoned the GPX themselves. Applied at both ends: when this device
  // evaluates a fix, and when a deviation alert arrives from another device that
  // had not yet seen the leader's trail.
  // ---------------------------------------------------------------------------

  RouteDeviationAssessment _applyLeaderFollowExemption(
    RiderLocation location,
    RouteDeviationDetector detector,
    RouteDeviationAssessment assessment,
  ) {
    // The leader is always the end of their own trail, so exempting them says
    // nothing; leave their verdict to the geometry.
    final exempt =
        location.role != RideRole.lead &&
        LeaderTrackExemption.isFollowingLeaderTrack(
          position: location.sample.position,
          accuracyMeters: location.sample.accuracyMeters,
          leaderTrack: _leaderTrailPoints,
          corridorMeters: routeConfig.leaderTrackCorridorMeters,
        );
    _followingLeaderTrack[location.riderId] = exempt;
    // A stale or inaccurate fix is a GPS problem, not a route problem, and must
    // keep reporting as one.
    if (!exempt || assessment.state == RouteTrackingState.gpsStale) {
      return assessment;
    }
    detector.resetOffRouteHysteresis();
    return RouteDeviationDetector.followingLeaderTrackAssessment(
      evaluatedAt: assessment.evaluatedAt,
      distanceFromRouteMeters: assessment.distanceFromRouteMeters,
    );
  }

  RiderRouteAlert _exemptIfFollowingLeaderTrack(RiderRouteAlert alert) {
    if (!isFollowingLeaderTrack(alert.riderId) ||
        alert.assessment.state == RouteTrackingState.gpsStale ||
        alert.assessment.alertLevel == RouteAlertLevel.none) {
      return alert;
    }
    return RiderRouteAlert(
      riderId: alert.riderId,
      displayName: alert.displayName,
      assessment: RouteDeviationDetector.followingLeaderTrackAssessment(
        evaluatedAt: alert.assessment.evaluatedAt,
        distanceFromRouteMeters: alert.assessment.distanceFromRouteMeters,
      ),
      acknowledged: alert.acknowledged,
      acknowledgedBy: alert.acknowledgedBy,
      acknowledgedAt: alert.acknowledgedAt,
    );
  }

  void _removeExpiredHazards() {
    final now = _clock();
    _hazards.removeWhere((_, hazard) => !hazard.isActiveAt(now));
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
    } on Object catch (error, stackTrace) {
      _errorMessage = 'Situational awareness could not be updated.';
      if (kDebugMode) {
        debugPrint('Situational awareness failed: $error\n$stackTrace');
      }
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  static Map<String, Object?> _mapPayload(Object? value) =>
      Map<String, Object?>.from(value! as Map);

  static EventPriority _priorityForSeverity(HazardSeverity severity) =>
      switch (severity) {
        HazardSeverity.advisory => EventPriority.routine,
        HazardSeverity.caution ||
        HazardSeverity.serious => EventPriority.important,
        HazardSeverity.critical => EventPriority.critical,
      };

  static EventPriority _priorityForAlert(RouteAlertLevel level) =>
      switch (level) {
        RouteAlertLevel.none || RouteAlertLevel.watch => EventPriority.routine,
        RouteAlertLevel.urgent => EventPriority.important,
        RouteAlertLevel.critical => EventPriority.critical,
      };

  static const _supportedSituationalEventTypes = {
    RideEventType.riderLocationUpdated,
    RideEventType.hazardReported,
    RideEventType.hazardCleared,
    RideEventType.routeDeviationChanged,
    RideEventType.routeAlertAcknowledged,
  };
}
