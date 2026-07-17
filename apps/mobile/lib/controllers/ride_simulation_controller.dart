import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../domain/geo_point.dart';
import '../domain/hazard.dart';
import '../domain/ride_event.dart';
import '../domain/ride_role.dart';
import '../domain/ride_session.dart';
import '../domain/rider_location.dart';
import '../services/geo_calculations.dart';
import '../services/situation_event_factory.dart';
import 'situational_awareness_controller.dart';

enum RideSimulationState { ready, running, paused, completed }

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
}

/// Drives the production awareness pipeline with synthetic, authenticated GPS
/// fixes. The owning shell deliberately disables internet, nearby and device
/// location services for simulation sessions.
class RideSimulationController extends ChangeNotifier {
  RideSimulationController(
    this._awarenessController, {
    required RideSession session,
    required List<GeoPoint> route,
    this.tickInterval = const Duration(milliseconds: 100),
    this.eventInterval = const Duration(milliseconds: 500),
  }) : assert(session.isSimulation),
       assert(route.length >= 2),
       _session = session,
       _routeSampler = _RouteSampler(route),
       _selectedLocalRole = session.role == RideRole.marker
           ? RideRole.rider
           : session.role {
    final leadStart = _routeSampler.totalDistanceMeters * 0.06;
    _agents = [
      _SimulatedAgent(
        id: session.localRiderId,
        displayName: session.displayName,
        role: _selectedLocalRole,
        progressMeters: leadStart,
        speedFactor: 1,
        isLocal: true,
      ),
      _SimulatedAgent(
        id: 'ride-lab-maya',
        displayName: 'Maya',
        role: _selectedLocalRole == RideRole.lead
            ? RideRole.rider
            : RideRole.lead,
        progressMeters: math.max(0, leadStart - 60),
        speedFactor: 1,
      ),
      _SimulatedAgent(
        id: offRouteRiderId,
        displayName: 'Alex',
        role: RideRole.rider,
        progressMeters: math.max(0, leadStart - 100),
        speedFactor: 0.995,
      ),
      _SimulatedAgent(
        id: 'ride-lab-jordan',
        displayName: 'Jordan',
        role: RideRole.rider,
        progressMeters: math.max(0, leadStart - 180),
        speedFactor: 0.99,
      ),
      _SimulatedAgent(
        id: tecRiderId,
        displayName: 'Charlie',
        role: _selectedLocalRole == RideRole.tailEndCharlie
            ? RideRole.rider
            : RideRole.tailEndCharlie,
        progressMeters: math.max(0, leadStart - 620),
        speedFactor: 0.96,
      ),
    ];
  }

  static const offRouteRiderId = 'ride-lab-alex';
  static const tecRiderId = 'ride-lab-charlie';

  final SituationalAwarenessController _awarenessController;
  final RideSession _session;
  final _RouteSampler _routeSampler;
  final Duration tickInterval;
  final Duration eventInterval;
  late final List<_SimulatedAgent> _agents;
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

  RideSimulationState get state => _state;
  Duration get simulatedElapsed => _simulatedElapsed;
  double get timeScale => _timeScale;
  double get baseSpeedMetersPerSecond => _baseSpeedMetersPerSecond;
  bool get tecDelayed => _tecDelayed;
  RideRole get localRole => _selectedLocalRole;
  bool get markerMode => _markerMode;
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
        displayName: agent.displayName,
        role: agent.role,
        progress: (agent.progressMeters / routeDistanceMeters).clamp(0, 1),
        speedMetersPerSecond: _speedFor(agent),
        isLocal: agent.isLocal,
        isOffRoute: agent.isOffRoute,
        position: sampled.position,
        headingDegrees: sampled.headingDegrees,
      );
    }),
  );

  Future<void> initialize() => _emitPositions();

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
    notifyListeners();
  }

  void setTecDelayed(bool value) {
    if (_tecDelayed == value) return;
    _tecDelayed = value;
    notifyListeners();
  }

  void setLocalRole(RideRole role) {
    if (role == RideRole.marker || role == _selectedLocalRole) return;
    _selectedLocalRole = role;
    if (!_markerMode) _assignPerspectiveRoles();
    notifyListeners();
  }

  void setMarkerMode(bool value) {
    if (_markerMode == value) return;
    _markerMode = value;
    if (value) {
      _agents.first.role = RideRole.marker;
    } else {
      _assignPerspectiveRoles();
    }
    notifyListeners();
  }

  Future<void> reportRoadworks() async {
    final lead = _agents.first;
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
    for (final agent in _agents) {
      if (agent.isLocal && _markerMode) continue;
      agent.progressMeters = math.min(
        routeDistanceMeters,
        agent.progressMeters + _speedFor(agent) * seconds,
      );
    }
    final completed = _agents.first.progressMeters >= routeDistanceMeters;
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
          idFactory: () => 'ride-lab-${agent.id}-${_eventSequence++}',
        ).create(
          type: RideEventType.riderLocationUpdated,
          payload: {'location': location.toJson()},
          expiresAt: recordedAt.add(const Duration(minutes: 30)),
        );
    await _awarenessController.ingestRemoteEvent(event);
  }

  double _speedFor(_SimulatedAgent agent) {
    if (_state == RideSimulationState.completed) return 0;
    if (agent.isLocal && _markerMode) return 0;
    if (agent.id == tecRiderId && _tecDelayed) {
      return _baseSpeedMetersPerSecond * 0.45;
    }
    return _baseSpeedMetersPerSecond * agent.speedFactor;
  }

  _SimulatedAgent _agent(String id) =>
      _agents.firstWhere((agent) => agent.id == id);

  _SimulatedPosition _sampleAgent(_SimulatedAgent agent) {
    final sampled = _routeSampler.sampleAt(agent.progressMeters);
    return _SimulatedPosition(
      position: agent.isOffRoute
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
    this.isLocal = false,
  });

  final String id;
  final String displayName;
  RideRole role;
  double progressMeters;
  final double speedFactor;
  final bool isLocal;
  bool isOffRoute = false;
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
