import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../domain/geo_point.dart';
import '../domain/hazard.dart';
import '../domain/ride_event.dart';
import '../domain/ride_role.dart';
import '../domain/ride_session.dart';
import '../domain/rider_color.dart';
import '../domain/rider_location.dart';
import '../features/map/motorcycle_icon.dart';
import '../services/geo_calculations.dart';
import '../services/situation_event_factory.dart';
import 'situational_awareness_controller.dart';

enum RideSimulationState { ready, running, paused, completed }

/// The automatic second-bike-drop sequence shown by the Ride Lab.
enum SimulationMarkerPhase {
  riding,
  waitingForRiders,
  tecApproaching,
  readyToRideOff,
}

class SimulatedRiderSnapshot {
  const SimulatedRiderSnapshot({
    required this.id,
    required this.displayName,
    required this.role,
    required this.progress,
    required this.speedMetersPerSecond,
    required this.isLocal,
    required this.isOffRoute,
    required this.position,
    required this.headingDegrees,
    required this.offRouteTrail,
    required this.travelTrail,
    required this.motorcycleStyle,
    required this.riderColor,
  });

  final String id;
  final String displayName;
  final RideRole role;
  final double progress;
  final double speedMetersPerSecond;
  final bool isLocal;
  final bool isOffRoute;
  final GeoPoint position;
  final double headingDegrees;
  final MotorcycleIconStyle motorcycleStyle;
  final RiderColor riderColor;

  /// Ephemeral visual trace for the current simulation run. Keeping this out
  /// of the durable awareness history prevents an older demo route from being
  /// connected to the current one after the bundled route changes.
  final List<GeoPoint> offRouteTrail;

  /// Recent on-road positions, used to show the actual path ridden by the
  /// current leader without altering the planned route geometry.
  final List<GeoPoint> travelTrail;
}

/// Drives the production awareness pipeline with synthetic, authenticated GPS
/// fixes. The owning shell deliberately disables internet, nearby and device
/// location services for simulation sessions.
class RideSimulationController extends ChangeNotifier {
  RideSimulationController(
    this._awarenessController, {
    required RideSession session,
    required List<GeoPoint> route,
    List<GeoPoint> markerJunctions = const [],
    List<GeoPoint> fallbackJunctions = const [],
    this.tickInterval = const Duration(milliseconds: 100),
    this.eventInterval = const Duration(seconds: 2),
    this.riderCount = RideSession.defaultSimulationRiderCount,
  }) : assert(session.isSimulation),
       assert(route.length >= 2),
       assert(
         riderCount >= RideSession.minimumSimulationRiderCount &&
             riderCount <= RideSession.maximumSimulationRiderCount,
       ),
       _session = session,
       _routeSampler = _RouteSampler(route),
       _selectedLocalRole = session.role == RideRole.marker
           ? RideRole.rider
           : session.role {
    final leadStart = _routeSampler.totalDistanceMeters * 0.06;
    _agents = _buildAgents(leadStart);
    List<double> usableJunctions(List<GeoPoint> points) => _routeSampler
        .progressesFor(points)
        .where(
          (progress) =>
              progress > leadStart + 140 &&
              progress < _routeSampler.totalDistanceMeters - 240,
        )
        .toList(growable: false);
    final requestedJunctions = usableJunctions(markerJunctions);
    final derivedJunctions = requestedJunctions.isEmpty
        ? usableJunctions(fallbackJunctions)
        : const <double>[];
    final selectedJunctions = requestedJunctions.isNotEmpty
        ? requestedJunctions
        : derivedJunctions;
    _markerJunctionProgresses = selectedJunctions.isEmpty
        ? [
            math.min(
              _routeSampler.totalDistanceMeters - 240,
              _routeSampler.totalDistanceMeters * 0.22,
            ),
          ]
        : selectedJunctions;
  }

  static const offRouteRiderId = 'ride-lab-alex';
  static const tecRiderId = 'ride-lab-charlie';

  final SituationalAwarenessController _awarenessController;
  final RideSession _session;
  final _RouteSampler _routeSampler;
  final Duration tickInterval;
  final Duration eventInterval;
  final int riderCount;
  late final List<_SimulatedAgent> _agents;
  late final List<double> _markerJunctionProgresses;
  RideRole _selectedLocalRole;
  Timer? _timer;
  RideSimulationState _state = RideSimulationState.ready;
  Duration _simulatedElapsed = Duration.zero;
  double _timeScale = 8;
  double _baseSpeedMetersPerSecond = 13.4;
  bool _tecDelayed = false;
  bool _emitting = false;
  bool _markerMode = false;
  Duration _eventElapsed = Duration.zero;
  int _eventSequence = 0;
  DateTime? _lastRecordedAt;
  int _nextMarkerJunctionIndex = 0;
  double? _activeMarkerProgressMeters;
  String? _activeMarkerRiderId;
  Set<String> _ridersExpectedToPass = const {};
  SimulationMarkerPhase _markerPhase = SimulationMarkerPhase.riding;
  Duration _tecApproachElapsed = Duration.zero;
  int _automaticMarkerActivation = 0;
  int _automaticMarkerRideOffActivation = 0;
  bool _lastAutomaticMarkerRideOffWasLocal = false;

  RideSimulationState get state => _state;
  Duration get simulatedElapsed => _simulatedElapsed;
  double get timeScale => _timeScale;
  double get baseSpeedMetersPerSecond => _baseSpeedMetersPerSecond;
  bool get tecDelayed => _tecDelayed;
  RideRole get localRole => _selectedLocalRole;
  bool get markerMode => _markerMode;
  SimulationMarkerPhase get markerPhase => _markerPhase;
  bool get automaticMarkerActive => _activeMarkerProgressMeters != null;
  bool get automaticMarkerIsLocal =>
      _activeMarkerRiderId == _session.localRiderId;
  String? get automaticMarkerRiderName => switch (_activeMarkerRiderId) {
    final String riderId => _agent(riderId).displayName,
    null => null,
  };
  bool get canRideOff =>
      _markerMode && _markerPhase == SimulationMarkerPhase.readyToRideOff;
  int get automaticMarkerActivation => _automaticMarkerActivation;
  int get automaticMarkerRideOffActivation => _automaticMarkerRideOffActivation;
  bool get lastAutomaticMarkerRideOffWasLocal =>
      _lastAutomaticMarkerRideOffWasLocal;
  int get ridersExpectedToPass => _ridersExpectedToPass.length;
  int get ridersPassedMarker {
    final markerProgress = _activeMarkerProgressMeters;
    if (markerProgress == null) return 0;
    return _ridersExpectedToPass
        .where(
          (id) =>
              _agent(id).progressMeters >= markerProgress + _markerPassMeters,
        )
        .length;
  }

  double? get tecDistanceToMarkerMeters {
    final markerProgress = _activeMarkerProgressMeters;
    if (markerProgress == null) return null;
    return math.max(0, markerProgress - _agent(tecRiderId).progressMeters);
  }

  String get markerInstruction => switch (_markerPhase) {
    SimulationMarkerPhase.riding =>
      'The simulated second bike will stop at the next route decision.',
    SimulationMarkerPhase.waitingForRiders =>
      ridersPassedMarker < ridersExpectedToPass
          ? '${_markerRiderSubject()} $_markerRiderPresentVerb holding the junction while riders pass '
                '($ridersPassedMarker/$ridersExpectedToPass).'
          : 'Riders are through. ${_markerRiderSubject()} $_markerRiderPresentVerb waiting for '
                'Tail End Charlie.',
    SimulationMarkerPhase.tecApproaching =>
      '${ridersPassedMarker < ridersExpectedToPass ? 'Traffic is still clearing. ' : 'All riders are through. '}TEC is approaching — '
          '${_markerRiderSubject().toLowerCase()} should get ready to ride off.',
    SimulationMarkerPhase.readyToRideOff =>
      'TEC has passed. ${_markerRiderSubject()} can ride off and return to '
          'navigation.',
  };
  bool get alexOffRoute => _agent(offRouteRiderId).isOffRoute;
  bool get isRunning => _state == RideSimulationState.running;
  double get routeDistanceMeters => _routeSampler.totalDistanceMeters;
  double get progress =>
      (_agents.first.progressMeters / routeDistanceMeters).clamp(0, 1);

  List<SimulatedRiderSnapshot> get riders => List.unmodifiable(
    _agents.map((agent) {
      final sampled = _sampleAgent(agent);
      return SimulatedRiderSnapshot(
        id: agent.id,
        displayName: agent.isLocal ? _localPerspectiveName : agent.displayName,
        role: agent.role,
        progress: (agent.progressMeters / routeDistanceMeters).clamp(0, 1),
        speedMetersPerSecond: _speedFor(agent),
        isLocal: agent.isLocal,
        isOffRoute: agent.isOffRoute,
        position: sampled.position,
        headingDegrees: sampled.headingDegrees,
        offRouteTrail: List.unmodifiable(agent.offRouteTrail),
        travelTrail: List.unmodifiable(_displayTrailFor(agent)),
        motorcycleStyle: agent.motorcycleStyle,
        riderColor: agent.riderColor,
      );
    }),
  );

  List<_SimulatedAgent> _buildAgents(double leadStart) {
    final trailingSpan = math.min(860, math.max(160, leadStart * 0.82));
    double initialProgress(int index) =>
        math.max(0, leadStart - trailingSpan * index / (riderCount - 1));
    // Cycles through the catalogues so a full Ride Lab group shows a variety
    // of silhouettes and colours without repeating the local rider's own
    // choices. Lead/TEC roles still override to their reserved colour when
    // rendered, so this only ever shows for plain riders.
    MotorcycleIconStyle demoStyleFor(int index) =>
        MotorcycleIconStyle.values[(index + 1) %
            MotorcycleIconStyle.values.length];
    RiderColor demoColorFor(int index) =>
        RiderColor.values[(index + 1) % RiderColor.values.length];
    _SimulatedAgent rider({
      required String id,
      required String displayName,
      required int index,
      required RideRole role,
      bool isLocal = false,
    }) => _SimulatedAgent(
      id: id,
      displayName: displayName,
      role: role,
      progressMeters: initialProgress(index),
      speedFactor: 1 - (0.2 * index / (riderCount - 1)),
      trafficPhaseSeconds: (3 + index * 12) % 58,
      isLocal: isLocal,
      motorcycleStyle: isLocal ? _session.motorcycleStyle : demoStyleFor(index),
      riderColor: isLocal ? _session.riderColor : demoColorFor(index),
    );

    final agents = <_SimulatedAgent>[
      rider(
        id: _session.localRiderId,
        displayName: _session.displayName,
        index: 0,
        role: _selectedLocalRole,
        isLocal: true,
      ),
      rider(
        id: 'ride-lab-maya',
        displayName: 'Maya',
        index: 1,
        role: _selectedLocalRole == RideRole.lead
            ? RideRole.rider
            : RideRole.lead,
      ),
      rider(
        id: offRouteRiderId,
        displayName: 'Alex',
        index: 2,
        role: RideRole.rider,
      ),
    ];
    var nextIndex = 3;
    if (riderCount >= 5) {
      agents.add(
        rider(
          id: 'ride-lab-jordan',
          displayName: 'Jordan',
          index: nextIndex++,
          role: RideRole.rider,
        ),
      );
    }
    var riderNumber = 1;
    while (agents.length < riderCount - 1) {
      agents.add(
        rider(
          id: 'ride-lab-rider-$riderNumber',
          displayName: 'Rider $riderNumber',
          index: nextIndex++,
          role: RideRole.rider,
        ),
      );
      riderNumber += 1;
    }
    agents.add(
      rider(
        id: tecRiderId,
        displayName: 'Charlie',
        index: riderCount - 1,
        role: _selectedLocalRole == RideRole.tailEndCharlie
            ? RideRole.rider
            : RideRole.tailEndCharlie,
      ),
    );
    return agents;
  }

  List<GeoPoint> _displayTrailFor(_SimulatedAgent agent) {
    if (agent.role != RideRole.lead) return agent.travelTrail;
    final tec = _agent(tecRiderId);
    final routeTrail = _routeSampler.pointsBetween(
      math.min(tec.progressMeters, agent.progressMeters),
      agent.progressMeters,
    );
    if (!agent.isOffRoute || agent.offRouteTrail.length < 2) {
      return routeTrail;
    }
    // Keep the planned path back to TEC, then show the actual deviation beyond
    // it so the leader trail remains useful during a prolonged off-course run.
    return [...routeTrail, ...agent.offRouteTrail];
  }

  Future<void> initialize() async {
    for (final agent in _agents) {
      _recordTravelTrail(agent);
    }
    await _emitPositions();
  }

  void start() {
    if (_state == RideSimulationState.completed || isRunning) return;
    _state = RideSimulationState.running;
    _timer ??= Timer.periodic(tickInterval, (_) {
      if (isRunning) unawaited(_tick(tickInterval));
    });
    notifyListeners();
  }

  void pause() {
    if (!isRunning) return;
    _state = RideSimulationState.paused;
    notifyListeners();
  }

  void setTimeScale(double value) {
    final next = value.clamp(1, 16).toDouble();
    if (next == _timeScale) return;
    _timeScale = next;
    notifyListeners();
  }

  void setBaseSpeedMetersPerSecond(double value) {
    final next = value.clamp(4, 25).toDouble();
    if (next == _baseSpeedMetersPerSecond) return;
    _baseSpeedMetersPerSecond = next;
    notifyListeners();
  }

  void setAlexOffRoute(bool value) {
    final alex = _agent(offRouteRiderId);
    if (alex.isOffRoute == value) return;
    alex.isOffRoute = value;
    alex.offRouteTrail.clear();
    if (value) _recordOffRouteTrail(alex);
    notifyListeners();
  }

  void setTecDelayed(bool value) {
    if (_tecDelayed == value) return;
    _tecDelayed = value;
    notifyListeners();
  }

  void setLocalRole(RideRole role) {
    if (role == RideRole.marker || role == _selectedLocalRole) return;
    // The virtual viewpoint can safely change while another rider is holding a
    // junction. It remains locked only when this device is the marker.
    if (_markerMode &&
        (_activeMarkerRiderId == null || automaticMarkerIsLocal)) {
      return;
    }
    _selectedLocalRole = role;
    _assignPerspectiveRoles();
    if (_activeMarkerRiderId case final markerRiderId?) {
      _agent(markerRiderId).role = RideRole.marker;
    }
    _positionFleetForPerspective();
    _skipJunctionsBehindLocalRider();
    for (final agent in _agents) {
      agent.travelTrail.clear();
      _recordTravelTrail(agent);
    }
    notifyListeners();
  }

  void setMarkerMode(bool value) {
    if (_markerMode == value) return;
    _markerMode = value;
    if (value) {
      _agents.first.role = RideRole.marker;
    } else {
      _finishMarkerMode();
      _assignPerspectiveRoles();
    }
    notifyListeners();
  }

  /// Leaves a completed automatic marker stop and resumes the navigation
  /// simulation. The owning shell records the matching marker-ended event.
  void rideOff() {
    if (!canRideOff) return;
    setMarkerMode(false);
  }

  Future<void> reportRoadworks() async {
    final lead = _agents.firstWhere(
      (agent) => agent.role == RideRole.lead,
      orElse: () => _agents.first,
    );
    final hazardPoint = _routeSampler
        .sampleAt(math.min(routeDistanceMeters, lead.progressMeters + 450))
        .point;
    await _awarenessController.reportHazard(
      type: HazardType.roadworks,
      severity: HazardSeverity.caution,
      position: hazardPoint,
      details: 'Synthetic Ride Lab hazard',
    );
  }

  Future<void> _tick(Duration realElapsed) async {
    if (_state == RideSimulationState.completed) return;
    _advanceMotion(realElapsed);
    _eventElapsed += realElapsed;
    notifyListeners();
    if (_eventElapsed < eventInterval || _emitting) return;
    _eventElapsed = Duration.zero;
    await _emitPositions();
  }

  /// Advances virtual time and emits one GPS fix per rider. Public so tests and
  /// scripted demos can progress deterministically without waiting for timers.
  Future<void> advance(Duration realElapsed) async {
    if (_state == RideSimulationState.completed || _emitting) return;
    _advanceMotion(realElapsed);
    _eventElapsed = Duration.zero;
    await _emitPositions();
    notifyListeners();
  }

  void _advanceMotion(Duration realElapsed) {
    final simulatedMicroseconds = (realElapsed.inMicroseconds * _timeScale)
        .round();
    final simulatedDelta = Duration(microseconds: simulatedMicroseconds);
    _simulatedElapsed += simulatedDelta;
    final seconds =
        simulatedDelta.inMicroseconds / Duration.microsecondsPerSecond;
    final secondBike = _secondBikeFollowingLead();
    final lead = _leadAgent();
    final projectedLeadProgress = _isStoppedAtMarker(lead)
        ? lead.progressMeters
        : math.min(
            routeDistanceMeters,
            lead.progressMeters + _speedFor(lead) * seconds,
          );
    for (final agent in _agents) {
      if (_isStoppedAtMarker(agent)) continue;
      final nextProgress = math.min(
        routeDistanceMeters,
        agent.progressMeters + _speedFor(agent) * seconds,
      );
      if (agent.id == secondBike?.id &&
          _shouldStartAutomaticMarker(
            agent,
            nextProgress,
            projectedLeadProgress,
          )) {
        agent.progressMeters =
            _markerJunctionProgresses[_nextMarkerJunctionIndex];
        _startAutomaticMarker(agent);
        continue;
      }
      agent.progressMeters = nextProgress;
    }
    _keepFollowerBehindLeader();
    for (final agent in _agents) {
      _recordTravelTrail(agent);
      if (agent.isOffRoute) _recordOffRouteTrail(agent);
    }
    _updateAutomaticMarkerPhase(realElapsed);
    final completed = _agents.every(
      (agent) => agent.progressMeters >= routeDistanceMeters,
    );
    if (completed) _state = RideSimulationState.completed;
    if (completed) {
      _timer?.cancel();
      _timer = null;
    }
  }

  Future<void> _emitPositions() async {
    if (_emitting) return;
    _emitting = true;
    try {
      final recordedAt = _nextRecordedAt();
      final samples = [
        for (final agent in _agents)
          (agent: agent, sampled: _sampleAgent(agent)),
      ];
      for (final entry in samples) {
        final agent = entry.agent;
        final sampled = entry.sampled;
        final sample = LocationSample(
          position: sampled.position,
          recordedAt: recordedAt,
          accuracyMeters: 4,
          speedMetersPerSecond: _speedFor(agent),
          headingDegrees: sampled.headingDegrees,
        );
        if (agent.isLocal) {
          await _awarenessController.recordLocalLocation(sample);
        } else {
          await _emitRemoteLocation(agent, sample, recordedAt);
        }
      }
    } finally {
      _emitting = false;
    }
  }

  Future<void> _emitRemoteLocation(
    _SimulatedAgent agent,
    LocationSample sample,
    DateTime recordedAt,
  ) async {
    final remoteSession = RideSession(
      rideId: _session.rideId,
      rideCode: _session.rideCode,
      inviteSecret: _session.inviteSecret,
      joinToken: _session.joinToken,
      localRiderId: agent.id,
      displayName: agent.displayName,
      role: agent.role,
      joinedAt: _session.joinedAt,
      isSimulation: true,
    );
    final location = RiderLocation(
      riderId: agent.id,
      displayName: agent.displayName,
      role: agent.role,
      sample: sample,
      receivedAt: recordedAt,
    );
    final event =
        SituationEventFactory(
          session: remoteSession,
          clock: () => recordedAt,
          idFactory: () =>
              'ride-lab-${agent.id}-${recordedAt.microsecondsSinceEpoch}-${_eventSequence++}',
        ).create(
          type: RideEventType.riderLocationUpdated,
          payload: {'location': location.toJson()},
          expiresAt: recordedAt.add(const Duration(minutes: 30)),
        );
    await _awarenessController.ingestRemoteEvent(event);
  }

  double _speedFor(_SimulatedAgent agent) {
    if (_state == RideSimulationState.completed) return 0;
    if (_isStoppedAtMarker(agent)) return 0;
    if (agent.id == tecRiderId && _tecDelayed) {
      return _baseSpeedMetersPerSecond * 0.45;
    }
    final elapsedSeconds =
        _simulatedElapsed.inMicroseconds / Duration.microsecondsPerSecond;
    final trafficCycle = (elapsedSeconds + agent.trafficPhaseSeconds) % 58;
    // Staggered traffic-light waits let the virtual group spread naturally
    // rather than moving as a rigid five-bike line.
    final trafficFactor = trafficCycle < 4
        ? 0.08
        : 0.74 +
              0.22 *
                  ((math.sin(elapsedSeconds / 8 + agent.trafficPhaseSeconds) +
                          1) /
                      2);
    return _baseSpeedMetersPerSecond * agent.speedFactor * trafficFactor;
  }

  _SimulatedAgent _agent(String id) =>
      _agents.firstWhere((agent) => agent.id == id);

  void _recordOffRouteTrail(_SimulatedAgent agent) {
    final point = _sampleAgent(agent).position;
    final trail = agent.offRouteTrail;
    if (trail.isEmpty ||
        GeoCalculations.distanceMeters(trail.last, point) >= 2) {
      trail.add(point);
      if (trail.length > 600) trail.removeRange(0, trail.length - 600);
    }
  }

  void _recordTravelTrail(_SimulatedAgent agent) {
    final point = _sampleAgent(agent).position;
    final trail = agent.travelTrail;
    if (trail.isEmpty ||
        GeoCalculations.distanceMeters(trail.last, point) >= 2) {
      trail.add(point);
      if (trail.length > 180) trail.removeRange(0, trail.length - 180);
    }
  }

  bool _shouldStartAutomaticMarker(
    _SimulatedAgent candidate,
    double nextProgress,
    double projectedLeadProgress,
  ) {
    if (_markerMode ||
        _nextMarkerJunctionIndex >= _markerJunctionProgresses.length) {
      return false;
    }
    final markerProgress = _markerJunctionProgresses[_nextMarkerJunctionIndex];
    return candidate.id != _leadAgent().id &&
        projectedLeadProgress >= markerProgress + _leaderClearanceMeters &&
        nextProgress >= markerProgress;
  }

  void _startAutomaticMarker(_SimulatedAgent marker) {
    final markerProgress = _markerJunctionProgresses[_nextMarkerJunctionIndex];
    final lead = _leadAgent();
    _markerMode = true;
    _activeMarkerProgressMeters = markerProgress;
    _activeMarkerRiderId = marker.id;
    _markerPhase = SimulationMarkerPhase.waitingForRiders;
    marker.role = RideRole.marker;
    _ridersExpectedToPass = {
      for (final agent in _agents)
        if (agent.id != marker.id &&
            agent.id != lead.id &&
            agent.id != tecRiderId &&
            agent.progressMeters <= markerProgress + _markerPassMeters)
          agent.id,
    };
    _lastAutomaticMarkerRideOffWasLocal = false;
    _automaticMarkerActivation += 1;
  }

  void _updateAutomaticMarkerPhase(Duration realElapsed) {
    final markerProgress = _activeMarkerProgressMeters;
    if (!_markerMode || markerProgress == null) return;
    final tec = _agent(tecRiderId);
    final distance = markerProgress - tec.progressMeters;
    if (distance <= _tecRideOffMeters) {
      _lastAutomaticMarkerRideOffWasLocal = automaticMarkerIsLocal;
      _automaticMarkerRideOffActivation += 1;
      setMarkerMode(false);
      return;
    }
    if (distance <= _tecApproachMeters) {
      _markerPhase = SimulationMarkerPhase.tecApproaching;
      return;
    }
    final ridersAreThrough = ridersPassedMarker >= ridersExpectedToPass;
    if (!ridersAreThrough) {
      _markerPhase = SimulationMarkerPhase.waitingForRiders;
      _tecApproachElapsed = Duration.zero;
      return;
    }
    if (tec.progressMeters >= markerProgress + _markerPassMeters) {
      _markerPhase = SimulationMarkerPhase.tecApproaching;
      _tecApproachElapsed += realElapsed;
      if (_tecApproachElapsed >= const Duration(seconds: 2)) {
        _markerPhase = SimulationMarkerPhase.readyToRideOff;
      }
      return;
    }
    _markerPhase = SimulationMarkerPhase.waitingForRiders;
    _tecApproachElapsed = Duration.zero;
  }

  void _finishMarkerMode() {
    if (_activeMarkerProgressMeters != null &&
        _nextMarkerJunctionIndex < _markerJunctionProgresses.length) {
      _nextMarkerJunctionIndex += 1;
    }
    _activeMarkerProgressMeters = null;
    _activeMarkerRiderId = null;
    _ridersExpectedToPass = const {};
    _markerPhase = SimulationMarkerPhase.riding;
    _tecApproachElapsed = Duration.zero;
  }

  void _positionFleetForPerspective() {
    final local = _agents.first;
    if (_selectedLocalRole == RideRole.tailEndCharlie) {
      final lastRemoteProgress = _agents
          .where((agent) => !agent.isLocal)
          .map((agent) => agent.progressMeters)
          .reduce(math.min);
      local.progressMeters = math.max(0, lastRemoteProgress - 160);
      return;
    }
    if (_selectedLocalRole != RideRole.rider) return;
    final maya = _agent('ride-lab-maya');
    maya.progressMeters = math.min(
      routeDistanceMeters,
      math.max(maya.progressMeters, local.progressMeters + _followerGapMeters),
    );
  }

  void _keepFollowerBehindLeader() {
    if (_selectedLocalRole != RideRole.rider) return;
    final local = _agents.first;
    final lead = _leadAgent();
    if (lead.id == local.id) return;
    local.progressMeters = math.min(
      local.progressMeters,
      math.max(0, lead.progressMeters - _followerGapMeters),
    );
  }

  void _skipJunctionsBehindLocalRider() {
    while (_nextMarkerJunctionIndex < _markerJunctionProgresses.length &&
        _markerJunctionProgresses[_nextMarkerJunctionIndex] <=
            _agents.first.progressMeters + 20) {
      _nextMarkerJunctionIndex += 1;
    }
  }

  _SimulatedPosition _sampleAgent(_SimulatedAgent agent) {
    final sampled = _routeSampler.sampleAt(agent.progressMeters);
    // The synthetic off-route scenario must recover at the destination so the
    // same completion rule used by a live ride can end the demo naturally.
    final recoveredAtDestination =
        agent.progressMeters >= routeDistanceMeters - 45;
    return _SimulatedPosition(
      position: agent.isOffRoute && !recoveredAtDestination
          ? _offsetPoint(sampled.point, sampled.headingDegrees, 220)
          : sampled.point,
      headingDegrees: sampled.headingDegrees,
    );
  }

  void _assignPerspectiveRoles() {
    for (final agent in _agents) {
      agent.role = RideRole.rider;
    }
    _agents.first.role = _selectedLocalRole;
    if (_selectedLocalRole != RideRole.lead) {
      _agent('ride-lab-maya').role = RideRole.lead;
    }
    if (_selectedLocalRole != RideRole.tailEndCharlie) {
      _agent(tecRiderId).role = RideRole.tailEndCharlie;
    }
  }

  static const _markerPassMeters = 35.0;
  static const _tecApproachMeters = 260.0;
  static const _tecRideOffMeters = 55.0;
  static const _followerGapMeters = 180.0;
  static const _leaderClearanceMeters = 18.0;

  bool _isStoppedAtMarker(_SimulatedAgent agent) =>
      _markerMode &&
      (_activeMarkerRiderId == agent.id ||
          (_activeMarkerRiderId == null && agent.isLocal));

  _SimulatedAgent _leadAgent() => _agents.firstWhere(
    (agent) => agent.role == RideRole.lead,
    orElse: () => _agents.first,
  );

  _SimulatedAgent? _secondBikeFollowingLead() {
    final lead = _leadAgent();
    final following =
        _agents
            .where(
              (agent) =>
                  agent.id != lead.id &&
                  agent.progressMeters <= lead.progressMeters,
            )
            .toList(growable: false)
          ..sort(
            (first, second) =>
                second.progressMeters.compareTo(first.progressMeters),
          );
    return following.isEmpty ? null : following.first;
  }

  String _markerRiderSubject() => automaticMarkerIsLocal
      ? 'You'
      : (automaticMarkerRiderName ?? 'The rider');

  String get _markerRiderPresentVerb => automaticMarkerIsLocal ? 'are' : 'is';

  String get _localPerspectiveName => switch (_selectedLocalRole) {
    RideRole.lead => _session.displayName,
    RideRole.rider => 'You · Follower',
    RideRole.tailEndCharlie => 'You · TEC',
    RideRole.marker => 'You · Marker',
  };

  DateTime _nextRecordedAt() {
    final now = DateTime.now();
    final previous = _lastRecordedAt;
    final result = previous == null || now.isAfter(previous)
        ? now
        : previous.add(const Duration(milliseconds: 1));
    _lastRecordedAt = result;
    return result;
  }

  static GeoPoint _offsetPoint(
    GeoPoint point,
    double headingDegrees,
    double offsetMeters,
  ) {
    final direction = (headingDegrees + 90) * math.pi / 180;
    final northMeters = math.cos(direction) * offsetMeters;
    final eastMeters = math.sin(direction) * offsetMeters;
    final latitude = point.latitude + northMeters / 111320;
    final longitude =
        point.longitude +
        eastMeters / (111320 * math.cos(point.latitude * math.pi / 180).abs());
    return GeoPoint(latitude: latitude, longitude: longitude);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

class _SimulatedAgent {
  _SimulatedAgent({
    required this.id,
    required this.displayName,
    required this.role,
    required this.progressMeters,
    required this.speedFactor,
    required this.trafficPhaseSeconds,
    required this.motorcycleStyle,
    required this.riderColor,
    this.isLocal = false,
  });

  final String id;
  final String displayName;
  RideRole role;
  double progressMeters;
  final double speedFactor;
  final double trafficPhaseSeconds;
  final MotorcycleIconStyle motorcycleStyle;
  final RiderColor riderColor;
  final bool isLocal;
  bool isOffRoute = false;
  final List<GeoPoint> offRouteTrail = [];
  final List<GeoPoint> travelTrail = [];
}

class _SimulatedPosition {
  const _SimulatedPosition({
    required this.position,
    required this.headingDegrees,
  });

  final GeoPoint position;
  final double headingDegrees;
}

class _RouteSampler {
  _RouteSampler(List<GeoPoint> route) : _route = List.unmodifiable(route) {
    _cumulativeDistances = [0];
    for (var index = 1; index < _route.length; index += 1) {
      _cumulativeDistances.add(
        _cumulativeDistances.last +
            GeoCalculations.distanceMeters(_route[index - 1], _route[index]),
      );
    }
    totalDistanceMeters = _cumulativeDistances.last;
    if (totalDistanceMeters <= 0) {
      throw ArgumentError('Simulation route must contain distinct points.');
    }
  }

  final List<GeoPoint> _route;
  late final List<double> _cumulativeDistances;
  late final double totalDistanceMeters;

  List<double> progressesFor(List<GeoPoint> points) {
    final values =
        points
            .map((point) => GeoCalculations.projectOntoPolyline(point, _route))
            .where((projection) => projection.distanceFromRouteMeters <= 120)
            .map((projection) => projection.distanceAlongRouteMeters)
            .toList()
          ..sort();
    final unique = <double>[];
    for (final value in values) {
      if (unique.isEmpty || value - unique.last >= 120) unique.add(value);
    }
    return List.unmodifiable(unique);
  }

  List<GeoPoint> pointsBetween(double fromMeters, double toMeters) {
    final start = fromMeters.clamp(0, totalDistanceMeters).toDouble();
    final end = toMeters.clamp(0, totalDistanceMeters).toDouble();
    if (end <= start) return [sampleAt(start).point];
    // Keep the leader trace continuous enough to read on the map without
    // sending every GPS tick through the overlay source.
    final stepMeters = math.max(20, (end - start) / 750);
    final segmentCount = ((end - start) / stepMeters).ceil();
    return List.unmodifiable([
      for (var index = 0; index <= segmentCount; index += 1)
        sampleAt(start + (end - start) * index / segmentCount).point,
    ]);
  }

  _SampledRoutePoint sampleAt(double distanceMeters) {
    final target = distanceMeters.clamp(0, totalDistanceMeters).toDouble();
    var index = 0;
    while (index < _route.length - 2 &&
        _cumulativeDistances[index + 1] < target) {
      index += 1;
    }
    final start = _route[index];
    final end = _route[index + 1];
    final segmentLength =
        _cumulativeDistances[index + 1] - _cumulativeDistances[index];
    final fraction = segmentLength == 0
        ? 0.0
        : ((target - _cumulativeDistances[index]) / segmentLength).clamp(
            0.0,
            1.0,
          );
    return _SampledRoutePoint(
      point: GeoPoint(
        latitude: start.latitude + (end.latitude - start.latitude) * fraction,
        longitude:
            start.longitude + (end.longitude - start.longitude) * fraction,
      ),
      headingDegrees: _bearingDegrees(start, end),
    );
  }

  static double _bearingDegrees(GeoPoint start, GeoPoint end) {
    final latitude1 = start.latitude * math.pi / 180;
    final latitude2 = end.latitude * math.pi / 180;
    final longitudeDelta = (end.longitude - start.longitude) * math.pi / 180;
    final y = math.sin(longitudeDelta) * math.cos(latitude2);
    final x =
        math.cos(latitude1) * math.sin(latitude2) -
        math.sin(latitude1) * math.cos(latitude2) * math.cos(longitudeDelta);
    return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
  }
}

class _SampledRoutePoint {
  const _SampledRoutePoint({required this.point, required this.headingDegrees});

  final GeoPoint point;
  final double headingDegrees;
}
