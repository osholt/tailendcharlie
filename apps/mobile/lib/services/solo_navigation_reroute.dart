import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/distance_unit.dart';
import '../domain/geo_point.dart' as awareness;
import '../domain/imported_route.dart';
import '../domain/rider_location.dart';
import '../domain/route_alert.dart';
import 'route_deviation_detector.dart';
import 'route_progress.dart';
import 'route_rejoin_planner.dart';
import 'route_travel_alignment.dart';
import 'spoken_guidance_schedule.dart' show guidanceJunctionClearanceMeters;

/// Off-route rerouting for a rider navigating on their own (#940).
///
/// ## The defect
///
/// Every reroute fix so far (#102, #162, #444) was wired into the group ride
/// shell and nowhere else. Where To navigation runs on the home map, which had
/// no deviation detector, no rejoin planner and no route to hand the map. On
/// the 10 October ride the rider was off route twice, for four minutes and
/// then eight, and heard nothing, while the banner promised it was "finding
/// directions back".
///
/// ## What this does
///
/// The same pieces the group follower uses, with three differences a rider on
/// their own needs:
///
/// - **No leader bound.** The group planner only offers a long detour a route
///   that stays behind the leader. [RouteRejoinThresholds.solo] never promotes a
///   rider to that band, so a long detour still gets a route back.
/// - **Back on route means travelling along it.** A fix near the line but
///   heading across it does not count towards recovery
///   (`route_travel_alignment.dart`). A rider on another road at a junction
///   keeps the rejoin route's directions for that junction, not the planned
///   approach's (#941).
/// - **Never switched inside a junction.** A new rejoin route, or the return to
///   the planned route, waits until the rider is clear of the junction they are
///   in, the rule the group shell applies to a new rejoin route after ride
///   392725. A failed retry keeps the last rejoin route rather than taking
///   directions away.
///
/// Pure Dart: the home map feeds fixes in, and says and records what comes out.
class SoloNavigationReroute {
  SoloNavigationReroute({
    required this._planner,
    DateTime Function()? clock,
    this._onDispose,
  }) : _clock = clock ?? DateTime.now;

  /// Production: the documented OSRM service, with the planner owning its
  /// client.
  factory SoloNavigationReroute.osrm({
    required Uri routingBaseUrl,
    required DistanceUnit distanceUnit,
  }) {
    final managed = ManagedRouteRejoinPlanner.osrm(
      routingBaseUrl: routingBaseUrl,
      distanceUnit: distanceUnit,
      thresholds: RouteRejoinThresholds.solo,
    );
    return SoloNavigationReroute(
      planner: managed.planner,
      onDispose: managed.dispose,
    );
  }

  /// The planner keys its state by rider; there is only one here.
  static const riderId = 'solo';

  final RouteRejoinPlanner _planner;
  final DateTime Function() _clock;
  final VoidCallback? _onDispose;

  /// The rejoin route for the map to navigate by, or null to follow the
  /// planned route. Handed to `RideMapFeature.rejoinNavigationRoute`.
  final ValueNotifier<ImportedRoute?> route = ValueNotifier(null);

  String? _routeFingerprint;
  List<GeoPoint> _path = const [];
  List<awareness.GeoPoint> _awarenessPath = const [];
  RouteDeviationDetector? _detector;
  bool _offRoute = false;
  DateTime? _offRouteSince;
  RouteRejoinPlan? _lastPlan;
  int _generation = 0;
  bool _disposed = false;
  Future<void> _chain = Future<void>.value();

  /// Whether the rider is confirmed off the planned route.
  bool get offRoute => _offRoute;

  @visibleForTesting
  RouteRejoinPlanner get planner => _planner;

  /// Follows [planned], or stops when it is null. The same route again changes
  /// nothing, so a repeated notification cannot reset an episode.
  void setRoute(ImportedRoute? planned) {
    final fingerprint = planned == null
        ? null
        : RouteProgressTracker.fingerprint(planned);
    if (fingerprint == _routeFingerprint) return;
    _routeFingerprint = fingerprint;
    _generation += 1;
    _planner.reset();
    _offRoute = false;
    _offRouteSince = null;
    _lastPlan = null;
    if (!_disposed) route.value = null;
    if (planned == null) {
      _detector = null;
      _path = const [];
      _awarenessPath = const [];
      return;
    }
    _path = _primaryPath(planned);
    _awarenessPath = List.unmodifiable([
      for (final point in _path)
        awareness.GeoPoint(
          latitude: point.latitude,
          longitude: point.longitude,
        ),
    ]);
    _detector = RouteDeviationDetector(_awarenessPath);
  }

  /// Feeds one fix in. Fixes are handled one at a time, in order, so a slow
  /// routing request cannot overlap the next.
  ///
  /// [distanceToCurrentManeuverMeters] and [metersSincePreviousManeuver] are
  /// what the map's guidance currently says, and are only used to hold a switch
  /// of route until the rider is clear of a junction.
  Future<SoloRerouteUpdate> update(
    LocationSample sample, {
    double? distanceToCurrentManeuverMeters,
    double? metersSincePreviousManeuver,
  }) {
    final result = _chain.then(
      (_) => _update(
        sample,
        distanceToCurrentManeuverMeters: distanceToCurrentManeuverMeters,
        metersSincePreviousManeuver: metersSincePreviousManeuver,
      ),
    );
    _chain = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<SoloRerouteUpdate> _update(
    LocationSample sample, {
    required double? distanceToCurrentManeuverMeters,
    required double? metersSincePreviousManeuver,
  }) async {
    final detector = _detector;
    if (_disposed || detector == null) return const SoloRerouteUpdate();
    final generation = _generation;
    final now = _clock();
    final travel = routeTravel(
      position: GeoPoint(
        latitude: sample.position.latitude,
        longitude: sample.position.longitude,
      ),
      path: _path,
      headingDegrees: sample.headingDegrees,
      speedMetersPerSecond: sample.speedMetersPerSecond,
    );
    final assessment = detector.evaluate(
      sample,
      now,
      headingAcrossRoute: travel == RouteTravel.across,
    );

    var leftRoute = false;
    Duration? backOnRouteAfter;
    if (assessment.state == RouteTrackingState.offRoute && !_offRoute) {
      _offRoute = true;
      _offRouteSince = assessment.offRouteSince ?? now;
      leftRoute = true;
    } else if (assessment.state == RouteTrackingState.onRoute && _offRoute) {
      _offRoute = false;
      backOnRouteAfter = now.difference(_offRouteSince ?? now);
      _offRouteSince = null;
    }

    // Suspected, recovering and stale fixes leave everything as it is: none of
    // them is a verdict, and the planner reads anything but off route as on it.
    RouteRejoinPlan? attempt;
    if (assessment.state == RouteTrackingState.offRoute ||
        assessment.state == RouteTrackingState.onRoute) {
      final plan = await _planner.update(
        riderId: riderId,
        sample: sample,
        assessment: assessment,
        plannedRoute: _awarenessPath,
        now: now,
      );
      if (_disposed || generation != _generation) {
        return const SoloRerouteUpdate();
      }
      // A retained plan is the same object; anything else is a fresh attempt.
      if (plan.severity != RouteRejoinSeverity.onRoute &&
          !identical(plan, _lastPlan)) {
        attempt = plan;
      }
      _lastPlan = plan;
      final next = _offRoute
          ? rejoinNavigationRoute(plan) ?? route.value
          : null;
      if (next?.id != route.value?.id &&
          !_insideJunction(
            distanceToCurrentManeuverMeters: distanceToCurrentManeuverMeters,
            metersSincePreviousManeuver: metersSincePreviousManeuver,
          )) {
        route.value = next;
      }
    }

    return SoloRerouteUpdate(
      leftRoute: leftRoute,
      offRouteSince: _offRouteSince,
      backOnRouteAfter: backOnRouteAfter,
      attempt: attempt,
      distanceFromRouteMeters: assessment.distanceFromRouteMeters,
    );
  }

  /// Whether the rider is committed to the junction the current guidance
  /// describes, or still in the one they just passed.
  static bool _insideJunction({
    required double? distanceToCurrentManeuverMeters,
    required double? metersSincePreviousManeuver,
  }) {
    final current = distanceToCurrentManeuverMeters;
    if (current != null && current <= guidanceJunctionClearanceMeters) {
      return true;
    }
    final since = metersSincePreviousManeuver;
    return since != null && since < guidanceJunctionClearanceMeters;
  }

  static List<GeoPoint> _primaryPath(ImportedRoute route) {
    var selected = const <GeoPoint>[];
    var selectedLength = -1.0;
    for (final path in route.paths) {
      final points = path.points;
      final length = points.length < 2
          ? 0.0
          : RouteRejoinGeometry.totalLengthMeters([
              for (final point in points)
                awareness.GeoPoint(
                  latitude: point.latitude,
                  longitude: point.longitude,
                ),
            ]);
      if (length > selectedLength) {
        selected = points;
        selectedLength = length;
      }
    }
    return selected;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation += 1;
    route.dispose();
    _onDispose?.call();
  }
}

/// What one fix changed.
@immutable
class SoloRerouteUpdate {
  const SoloRerouteUpdate({
    this.leftRoute = false,
    this.offRouteSince,
    this.backOnRouteAfter,
    this.attempt,
    this.distanceFromRouteMeters,
  });

  /// The rider has just been confirmed off the planned route. Said once per
  /// episode: "Off route. Recalculating directions."
  final bool leftRoute;

  /// When the current off-route episode began, while there is one. Identifies
  /// the episode, so the announcement is not repeated within it.
  final DateTime? offRouteSince;

  /// Set on the fix that confirmed the rider back on the planned route.
  final Duration? backOnRouteAfter;

  /// A routing attempt made on this fix, whether or not it produced a route.
  final RouteRejoinPlan? attempt;

  final double? distanceFromRouteMeters;
}
