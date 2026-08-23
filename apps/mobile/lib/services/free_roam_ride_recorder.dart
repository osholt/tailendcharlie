import 'package:uuid/uuid.dart';

import '../domain/completed_ride.dart';
import '../domain/geo_point.dart' as awareness_geo;
import '../domain/imported_route.dart';
import '../domain/ride_role.dart';
import 'geo_calculations.dart';
import 'rider_trail_recorder.dart';

/// Records one personal Where To navigation as a local completed ride.
///
/// Free roam deliberately has no group ride session (#600), but that must not
/// make its travelled history disposable. This recorder owns only the small
/// lifecycle it needs: a route becomes active, foreground fixes arrive, then
/// the route is cleared. It emits the same secret-free [CompletedRide] used by
/// My rides, so summary, GPX and recap exports need no free-roam variants.
class FreeRoamRideRecorder {
  FreeRoamRideRecorder({
    required this.localDisplayName,
    DateTime Function()? clock,
    String Function()? idFactory,
    RiderTrailRecorder? trailRecorder,
  }) : _clock = clock ?? (() => DateTime.now().toUtc()),
       _idFactory = idFactory ?? (() => const Uuid().v4()),
       _trailRecorder = trailRecorder ?? RiderTrailRecorder();

  static const _riderId = 'free-roam-local';

  final String localDisplayName;
  final DateTime Function() _clock;
  final String Function() _idFactory;
  final RiderTrailRecorder _trailRecorder;

  ImportedRoute? _plannedRoute;
  DateTime? _startedAt;
  GeoPoint? _lastAcceptedPoint;
  double _totalDistanceMeters = 0;
  int _sampleCount = 0;

  bool get active => _plannedRoute != null;

  /// Starts recording, or updates the plan without splitting an underway trip.
  void start(ImportedRoute route, {GeoPoint? initialPosition}) {
    if (!active) {
      _startedAt = _clock();
      _trailRecorder.clear();
      _lastAcceptedPoint = null;
      _totalDistanceMeters = 0;
      _sampleCount = 0;
    }
    _plannedRoute = route;
    if (initialPosition != null) record(initialPosition);
  }

  void record(GeoPoint point) {
    if (!active) return;
    final recorded = GeoPoint(
      latitude: point.latitude,
      longitude: point.longitude,
      elevationMeters: point.elevationMeters,
      recordedAt: point.recordedAt ?? _clock(),
    );
    final accepted = _trailRecorder.record(riderId: _riderId, point: recorded);
    if (!accepted) return;

    final previous = _lastAcceptedPoint;
    if (previous != null && _isContinuous(previous, recorded)) {
      _totalDistanceMeters += GeoCalculations.distanceMeters(
        awareness_geo.GeoPoint(
          latitude: previous.latitude,
          longitude: previous.longitude,
        ),
        awareness_geo.GeoPoint(
          latitude: recorded.latitude,
          longitude: recorded.longitude,
        ),
      );
    }
    _lastAcceptedPoint = recorded;
    _sampleCount += 1;
  }

  /// Finishes the active navigation and resets ready for the next one.
  CompletedRide? finish() {
    final plan = _plannedRoute;
    final startedAt = _startedAt;
    if (plan == null || startedAt == null) return null;
    final endedAt = _clock();
    final trail = _trailRecorder.trailFor(_riderId);
    final segments = _trailRecorder
        .continuousSegments(trail)
        .where((segment) => segment.length >= 2)
        .toList(growable: false);
    final id = 'free-roam-${_idFactory()}';
    final travelled = segments.isEmpty
        ? null
        : ImportedRoute(
            id: '$id-travelled',
            name: '${plan.name} travelled track',
            importedAt: endedAt,
            sourceFileName: 'personal-navigation.gpx',
            paths: [
              for (final segment in segments)
                RoutePath(kind: RoutePathKind.track, points: segment),
            ],
            waypoints: const [],
          );
    final completed = CompletedRide(
      rideId: id,
      rideCode: 'PERSONAL',
      rideName: plan.name,
      localDisplayName: localDisplayName.trim().isEmpty
          ? 'Rider'
          : localDisplayName.trim(),
      localRole: RideRole.rider,
      startedAt: startedAt,
      endedAt: endedAt,
      archivedAt: endedAt,
      riderCount: 1,
      eventCount: _sampleCount,
      totalDistanceMeters: _totalDistanceMeters,
      markerSessions: const [],
      plannedRoute: plan,
      traveledRoute: travelled,
    );
    _plannedRoute = null;
    _startedAt = null;
    _lastAcceptedPoint = null;
    _totalDistanceMeters = 0;
    _sampleCount = 0;
    _trailRecorder.clear();
    return completed;
  }

  static bool _isContinuous(GeoPoint previous, GeoPoint current) {
    final previousAt = previous.recordedAt;
    final currentAt = current.recordedAt;
    if (previousAt == null || currentAt == null) return true;
    final gap = currentAt.difference(previousAt);
    return !gap.isNegative &&
        gap <= RiderTrailRecorder.defaultMaximumContinuousGap;
  }
}
