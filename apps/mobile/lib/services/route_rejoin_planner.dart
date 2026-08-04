import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../domain/distance_unit.dart';
import '../domain/geo_point.dart';
import '../domain/imported_route.dart' as route_domain;
import '../domain/rider_location.dart';
import '../domain/route_alert.dart';
import 'geo_calculations.dart';
import 'leader_ride_status.dart' show TecAvailability;
import 'measurement_formatter.dart';
import 'road_routing.dart'
    show OsrmRoadRoutingService, RoadRouteManeuver, RoadRoutingService;

/// Owns the HTTP client used by the active ride's OSRM rejoin planner.
///
/// A directly constructed [RouteRejoinPlanner] never owns its injected routing
/// service. This handle is the production convenience path: the client returned
/// by [clientFactory] belongs to the handle and is closed exactly once by
/// [dispose]. Keeping that distinction explicit avoids both leaking the active
/// ride client and double-closing clients supplied by tests or other features.
class ManagedRouteRejoinPlanner {
  factory ManagedRouteRejoinPlanner.osrm({
    required Uri routingBaseUrl,
    required DistanceUnit distanceUnit,
    http.Client Function()? clientFactory,
  }) {
    final client = clientFactory?.call() ?? http.Client();
    return ManagedRouteRejoinPlanner._(
      planner: RouteRejoinPlanner(
        routingService: OsrmRoadRoutingService(
          client: client,
          baseUrl: routingBaseUrl,
        ),
        distanceUnit: distanceUnit,
      ),
      client: client,
    );
  }

  ManagedRouteRejoinPlanner._({required this.planner, required this._client});

  final RouteRejoinPlanner planner;
  final http.Client _client;
  bool _disposed = false;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _client.close();
  }
}

/// The routing service speaks the route domain's point type; everything else
/// here speaks the situational-awareness one. Converting at this single
/// boundary keeps the planner's public API in one coordinate type.
route_domain.GeoPoint _toRouteDomain(GeoPoint point) =>
    route_domain.GeoPoint(latitude: point.latitude, longitude: point.longitude);

GeoPoint _fromRouteDomain(route_domain.GeoPoint point) =>
    GeoPoint(latitude: point.latitude, longitude: point.longitude);

/// How far off the planned route a rider is, in the two bands the ride lead
/// asked for: a rider who simply missed a turn and can rejoin, and a rider who
/// is far enough away that rejoining unaided would drop them into the group in
/// the wrong place.
enum RouteRejoinSeverity { onRoute, offRoute, massivelyOffRoute }

/// What a rejoin route is aimed at. [plannedRoute] is a point on the imported
/// GPX; the other two are live rider positions and therefore move.
enum RouteRejoinTarget { plannedRoute, tailEndCharlie, leader }

/// Why a rider has - or has not - been given a rejoin breadcrumb. Every value
/// other than [routed] must degrade to the plain "you are off route by X"
/// message: the app never draws geometry it did not receive from the routing
/// engine.
enum RouteRejoinStatus {
  /// The rider is on route, inside the leader's track corridor, or has no
  /// usable GPS fix. Nothing to draw.
  notRequired,

  /// A road route was returned and can be drawn as a breadcrumb.
  routed,

  /// No GPX/planned route is loaded, so there is nothing to rejoin.
  noPlannedRoute,

  /// The rider is massively off course and the leader's position is unknown,
  /// so the "never ahead of the leader" rule cannot be checked. We refuse to
  /// guess.
  leaderPositionUnknown,

  /// The only rejoin point near the rider lies ahead of the leader's progress.
  /// Stated rather than silently used.
  aheadOfLeaderOnly,

  /// No rejoin point is within the usable detour limit.
  noRejoinInRange,

  /// The routing provider failed, timed out, or is offline.
  routingUnavailable,
}

/// Distance and time thresholds separating "rejoin the route" from "massively
/// off course", plus the geometry limits used to pick a rejoin point.
///
/// Defaults, and why:
///
/// * [massivelyOffRouteMeters] 1500 m. The deviation detector enters off-route
///   at 120 m, which covers GPS error, dual carriageways and parallel lanes. A
///   missed turn typically strands a rider a few hundred metres away and the
///   next junction gets them back. Past ~1.5 km the rider is on a different
///   road, not in the wrong lane, and an unconstrained rejoin can drop them
///   into the group ahead of the leader. 1.5 km is roughly one minute at UK
///   national-limit speeds.
/// * [massivelyOffRouteAfter] 10 minutes. A time catch for the rider who is
///   not far from the line but has been away long enough to be a long way from
///   the group - for example following a parallel road. The existing
///   all-rider critical escalation is 3 minutes, so 10 minutes is comfortably
///   after coordinators have already been told.
/// * Either condition promotes a rider; they are not required together.
/// * [minimumForwardRejoinMeters] 150 m. Rejoining 20 m ahead of where a rider
///   left the route is not a usable instruction and is inside GPS noise.
/// * [forwardSearchMeters] 10 km, [candidateSpacingMeters] 250 m. Enough
///   forward route to find a junction on a fast road without turning the
///   search into a whole-route scan.
/// * [maximumRejoinDetourMeters] 25 km. Beyond this a "rejoin here" instruction
///   is not advice, it is a second ride.
///
/// These numbers are development-alpha defaults. They have not been calibrated
/// against recorded field data and must be before any safety claim.
@immutable
class RouteRejoinThresholds {
  const RouteRejoinThresholds({
    this.massivelyOffRouteMeters = 1500,
    this.massivelyOffRouteAfter = const Duration(minutes: 10),
    this.matchedCorridorMeters = 120,
    this.minimumForwardRejoinMeters = 150,
    this.forwardSearchMeters = 10000,
    this.candidateSpacingMeters = 250,
    this.maximumRejoinDetourMeters = 25000,
    this.leaderProgressToleranceMeters = 100,
  }) : assert(massivelyOffRouteMeters > matchedCorridorMeters),
       assert(minimumForwardRejoinMeters > 0),
       assert(candidateSpacingMeters > 0),
       assert(forwardSearchMeters >= candidateSpacingMeters);

  final double massivelyOffRouteMeters;
  final Duration massivelyOffRouteAfter;

  /// How close to the planned route a fix has to be for its progress to be
  /// recorded as the rider's last matched position.
  final double matchedCorridorMeters;

  final double minimumForwardRejoinMeters;
  final double forwardSearchMeters;
  final double candidateSpacingMeters;
  final double maximumRejoinDetourMeters;

  /// Slack applied to the leader's progress before a rejoin point counts as
  /// "ahead of the leader". Absorbs GPS error on the leader's own fix so a
  /// rider is not sent backwards for the sake of a few metres.
  final double leaderProgressToleranceMeters;
}

/// Bounds on how often a rejoin route may be recalculated.
///
/// [minimumInterval] is a hard floor in every case. On top of it at least one
/// of the following must be true: the rider has moved [minimumMovementMeters]
/// since the last successful calculation; a moving target (TEC or leader) has
/// moved [minimumTargetMovementMeters]; or the severity/target has changed,
/// which is a state change rather than drift.
///
/// Defaults, and why: 45 s and 250 m. The interval is what bounds the worst
/// case - at 90 km/h a rider covers 250 m in 10 s, so the movement gate would
/// not restrain them; 45 s caps a moving rider at 80 provider calls per hour.
/// The movement gate removes the rest: a rider parked at a junction, or
/// circling a village tighter than 250 m, makes no further calls at all. That
/// is the pathological case in the field report. Consecutive failures back off
/// geometrically to [maximumFailureBackoff] so an offline phone does not retry
/// every 45 s.
@immutable
class RouteRejoinRecomputePolicy {
  const RouteRejoinRecomputePolicy({
    this.minimumInterval = const Duration(seconds: 45),
    this.minimumMovementMeters = 250,
    this.minimumTargetMovementMeters = 400,
    this.maximumFailureBackoff = const Duration(minutes: 6),
  }) : assert(minimumMovementMeters > 0),
       assert(minimumTargetMovementMeters > 0);

  final Duration minimumInterval;
  final double minimumMovementMeters;
  final double minimumTargetMovementMeters;
  final Duration maximumFailureBackoff;

  Duration backoffAfterFailures(int consecutiveFailures) {
    if (consecutiveFailures <= 0) return minimumInterval;
    final multiplier = math.min(1 << math.min(consecutiveFailures, 8), 16);
    final scaled = minimumInterval * multiplier;
    return scaled > maximumFailureBackoff ? maximumFailureBackoff : scaled;
  }
}

/// A point on the planned route a rider could be sent back to.
@immutable
class RouteRejoinCandidate {
  const RouteRejoinCandidate({
    required this.point,
    required this.progressMeters,
    required this.straightLineDistanceMeters,
    required this.requiresBacktracking,
  });

  final GeoPoint point;

  /// Distance along the planned route, from its start, of [point].
  final double progressMeters;

  /// Straight-line distance from the rider to [point]. Used only to rank
  /// candidates; the ridden distance always comes from the routing engine.
  final double straightLineDistanceMeters;

  final bool requiresBacktracking;
}

/// The outcome of a rejoin selection: either a candidate, or the reason there
/// isn't one.
@immutable
class RouteRejoinSelection {
  const RouteRejoinSelection._({this.candidate, required this.status});

  const RouteRejoinSelection.selected(RouteRejoinCandidate candidate)
    : this._(candidate: candidate, status: RouteRejoinStatus.routed);

  const RouteRejoinSelection.rejected(RouteRejoinStatus status)
    : this._(status: status);

  final RouteRejoinCandidate? candidate;

  /// [RouteRejoinStatus.routed] here means "a candidate was found"; whether a
  /// road route exists is decided later by the routing engine.
  final RouteRejoinStatus status;
}

/// Pure planned-route geometry. Separated from the planner so the forward
/// preference, the backtrack fallback and the never-ahead-of-the-leader rule
/// are all testable without a routing provider.
abstract final class RouteRejoinGeometry {
  /// Cumulative along-route distance for each point of [route].
  static List<double> cumulativeDistances(List<GeoPoint> route) {
    final cumulative = List<double>.filled(route.length, 0);
    for (var index = 1; index < route.length; index += 1) {
      cumulative[index] =
          cumulative[index - 1] +
          GeoCalculations.distanceMeters(route[index - 1], route[index]);
    }
    return cumulative;
  }

  static double totalLengthMeters(List<GeoPoint> route) =>
      route.length < 2 ? 0 : cumulativeDistances(route).last;

  /// The point [progressMeters] along [route], interpolated within the segment
  /// it falls in. Clamped to the route's own ends.
  static GeoPoint pointAtProgress(
    List<GeoPoint> route,
    double progressMeters,
  ) => _pointAtProgress(route, cumulativeDistances(route), progressMeters);

  /// [cumulative] must be [cumulativeDistances] for [route]. Taking it as an
  /// argument keeps a whole candidate sweep at one pass over the route instead
  /// of one pass per candidate - this runs on a phone on a bike.
  static GeoPoint _pointAtProgress(
    List<GeoPoint> route,
    List<double> cumulative,
    double progressMeters,
  ) {
    if (route.isEmpty) {
      throw ArgumentError.value(route, 'route', 'Route has no points');
    }
    if (route.length == 1) return route.single;
    final clamped = progressMeters.clamp(0.0, cumulative.last);
    for (var index = 1; index < route.length; index += 1) {
      if (cumulative[index] < clamped) continue;
      final segmentLength = cumulative[index] - cumulative[index - 1];
      if (segmentLength <= 0) return route[index];
      final fraction = (clamped - cumulative[index - 1]) / segmentLength;
      final start = route[index - 1];
      final end = route[index];
      return GeoPoint(
        latitude: start.latitude + (end.latitude - start.latitude) * fraction,
        longitude:
            start.longitude + (end.longitude - start.longitude) * fraction,
      );
    }
    return route.last;
  }

  /// Picks where to send a rider back to the planned route.
  ///
  /// Forward candidates - progress greater than
  /// [lastMatchedProgressMeters] - are preferred so the rider does not ride the
  /// route backwards. Backtracking is used only when no forward candidate is
  /// admissible, and the caller is expected to say so.
  ///
  /// When [massivelyOffRoute] is true the admissible window is capped at
  /// [leaderProgressMeters]: such a rider is never given a rejoin point ahead
  /// of the leader. If the only candidates within
  /// [RouteRejoinThresholds.maximumRejoinDetourMeters] are ahead of the leader
  /// the selection is rejected with [RouteRejoinStatus.aheadOfLeaderOnly]
  /// rather than quietly used.
  static RouteRejoinSelection selectRejoin({
    required List<GeoPoint> route,
    required GeoPoint riderPosition,
    required double lastMatchedProgressMeters,
    double? leaderProgressMeters,
    bool massivelyOffRoute = false,
    RouteRejoinThresholds thresholds = const RouteRejoinThresholds(),
  }) {
    if (route.length < 2) {
      return const RouteRejoinSelection.rejected(
        RouteRejoinStatus.noPlannedRoute,
      );
    }
    if (massivelyOffRoute && leaderProgressMeters == null) {
      return const RouteRejoinSelection.rejected(
        RouteRejoinStatus.leaderPositionUnknown,
      );
    }

    final cumulative = cumulativeDistances(route);
    final total = cumulative.last;
    final matched = lastMatchedProgressMeters.clamp(0.0, total);
    final ceiling = massivelyOffRoute
        ? math.min(
            total,
            leaderProgressMeters! + thresholds.leaderProgressToleranceMeters,
          )
        : total;

    final forward = <RouteRejoinCandidate>[];
    final backward = <RouteRejoinCandidate>[];
    var aheadOfLeaderInRange = false;

    void consider(double progress) {
      final bounded = progress.clamp(0.0, total);
      final point = _pointAtProgress(route, cumulative, bounded);
      final straightLine = GeoCalculations.distanceMeters(riderPosition, point);
      if (straightLine > thresholds.maximumRejoinDetourMeters) return;
      if (bounded > ceiling) {
        aheadOfLeaderInRange = true;
        return;
      }
      final candidate = RouteRejoinCandidate(
        point: point,
        progressMeters: bounded,
        straightLineDistanceMeters: straightLine,
        requiresBacktracking: bounded < matched,
      );
      if (candidate.requiresBacktracking) {
        backward.add(candidate);
      } else {
        forward.add(candidate);
      }
    }

    // Forward sweep first, from the earliest usable rejoin.
    final firstForward = matched + thresholds.minimumForwardRejoinMeters;
    for (
      var progress = firstForward;
      progress <= math.min(total, matched + thresholds.forwardSearchMeters);
      progress += thresholds.candidateSpacingMeters
    ) {
      consider(progress);
    }
    // The very end of the route is a legitimate rejoin even when the stride
    // steps past it.
    if (total >= firstForward) consider(total);

    // Backward sweep, used only as a fallback but measured now so the reason
    // for rejecting a selection is honest.
    for (
      var progress = matched - thresholds.candidateSpacingMeters;
      progress >= 0;
      progress -= thresholds.candidateSpacingMeters
    ) {
      consider(progress);
    }
    consider(0);

    RouteRejoinCandidate? nearest(List<RouteRejoinCandidate> candidates) {
      if (candidates.isEmpty) return null;
      return candidates.reduce(
        (best, candidate) =>
            candidate.straightLineDistanceMeters <
                best.straightLineDistanceMeters
            ? candidate
            : best,
      );
    }

    final chosen = nearest(forward) ?? nearest(backward);
    if (chosen != null) return RouteRejoinSelection.selected(chosen);
    if (aheadOfLeaderInRange) {
      return const RouteRejoinSelection.rejected(
        RouteRejoinStatus.aheadOfLeaderOnly,
      );
    }
    return const RouteRejoinSelection.rejected(
      RouteRejoinStatus.noRejoinInRange,
    );
  }
}

/// Advisory guidance for one rider. [breadcrumb] is empty unless
/// [status] is [RouteRejoinStatus.routed]; it is only ever the geometry the
/// routing engine returned.
@immutable
class RouteRejoinPlan {
  const RouteRejoinPlan({
    required this.riderId,
    required this.severity,
    required this.status,
    required this.computedAt,
    required this.guidance,
    this.target,
    this.breadcrumb = const [],
    this.maneuvers = const [],
    this.rejoinPoint,
    this.distanceMeters,
    this.duration,
    this.requiresBacktracking = false,
    this.distanceFromRouteMeters,
    this.timeOffRoute,
  });

  final String riderId;
  final RouteRejoinSeverity severity;
  final RouteRejoinStatus status;
  final RouteRejoinTarget? target;
  final DateTime computedAt;

  /// Rider-facing text. Safe to show verbatim: it never names a manoeuvre and
  /// says plainly when routing is unavailable.
  final String guidance;

  final List<GeoPoint> breadcrumb;
  final List<RoadRouteManeuver> maneuvers;
  final GeoPoint? rejoinPoint;
  final double? distanceMeters;
  final Duration? duration;
  final bool requiresBacktracking;
  final double? distanceFromRouteMeters;
  final Duration? timeOffRoute;

  bool get hasBreadcrumb =>
      status == RouteRejoinStatus.routed && breadcrumb.length >= 2;

  /// True when the rider is off course but no route could be offered, so the
  /// UI must fall back to the plain distance-from-route message.
  bool get degraded =>
      severity != RouteRejoinSeverity.onRoute &&
      status != RouteRejoinStatus.routed;
}

/// Adapts a routed rejoin response to the same immutable route model the live
/// turn-by-turn planner already consumes.
///
/// The rejoin breadcrumb has always reached the map, but its routing-engine
/// manoeuvres used to stop at [RouteRejoinPlan]. That drew a useful line while
/// leaving the guidance banner on the original route. Keeping this adapter here
/// makes geometry and directions one indivisible result.
route_domain.ImportedRoute? rejoinNavigationRoute(RouteRejoinPlan? plan) {
  if (plan == null || !plan.hasBreadcrumb || plan.maneuvers.isEmpty) {
    return null;
  }
  return route_domain.ImportedRoute(
    id:
        'rejoin-${plan.riderId}-'
        '${plan.computedAt.microsecondsSinceEpoch}',
    name: 'Advisory rejoin route',
    description: plan.guidance,
    importedAt: plan.computedAt.toUtc(),
    sourceFileName: 'advisory-rejoin.gpx',
    paths: [
      route_domain.RoutePath(
        kind: route_domain.RoutePathKind.track,
        points: [for (final point in plan.breadcrumb) _toRouteDomain(point)],
      ),
    ],
    waypoints: const [],
    maneuvers: plan.maneuvers,
  );
}

/// Computes rejoin routes for riders who have left the planned route.
///
/// Deliberately advisory: every drawn metre comes from [routingService]. When
/// routing fails the planner reports [RouteRejoinStatus.routingUnavailable] and
/// the existing "you are off route by X" message, which is what the
/// offline-first model has to fall back to.
class RouteRejoinPlanner {
  RouteRejoinPlanner({
    required this.routingService,
    this.thresholds = const RouteRejoinThresholds(),
    this.recomputePolicy = const RouteRejoinRecomputePolicy(),
    this.distanceUnit = DistanceUnit.kilometres,
  });

  final RoadRoutingService routingService;
  final RouteRejoinThresholds thresholds;
  final RouteRejoinRecomputePolicy recomputePolicy;
  final DistanceUnit distanceUnit;

  final Map<String, _RiderRejoinState> _states = {};

  /// Number of routing calls made. Exposed so recompute bounding is testable
  /// rather than asserted by eye.
  int get routingCallCount => _routingCallCount;
  int _routingCallCount = 0;

  RouteRejoinPlan? planFor(String riderId) => _states[riderId]?.plan;

  Map<String, RouteRejoinPlan> get plans => Map.unmodifiable({
    for (final entry in _states.entries)
      if (entry.value.plan != null) entry.key: entry.value.plan!,
  });

  void forget(String riderId) => _states.remove(riderId);

  void reset() => _states.clear();

  /// Feeds one rider's latest fix in and returns their current guidance.
  ///
  /// [assessment] is the deviation detector's verdict; the planner does not
  /// second-guess it. [followingLeaderTrack] is the leader-follow exemption:
  /// when true the rider is on route by definition and no rejoin is computed.
  ///
  /// [tecAvailability] is the one TEC model from `leader_ride_status.dart`, not
  /// a null check on [tecPosition]. A massively off-course rider is sent to the
  /// TEC only when it is [TecAvailability.tracking]; `none` (nobody holds the
  /// role), `awaitingLocation` (registered but never reported) and `stale` (a
  /// fix that can no longer be trusted to say where they are) all fall back to
  /// the ride leader rather than a null or guessed target.
  Future<RouteRejoinPlan> update({
    required String riderId,
    required LocationSample sample,
    required RouteDeviationAssessment assessment,
    required List<GeoPoint> plannedRoute,
    bool followingLeaderTrack = false,
    GeoPoint? leaderPosition,
    TecAvailability tecAvailability = TecAvailability.none,
    GeoPoint? tecPosition,
    DateTime? now,
  }) async {
    final evaluatedAt = now ?? assessment.evaluatedAt;
    final state = _states.putIfAbsent(riderId, _RiderRejoinState.new);

    // Remember the rider's progress whenever they are genuinely on the planned
    // route. A fix taken far away must never overwrite it: projecting a distant
    // position onto a folded route can land anywhere along it, and that value
    // is what decides which way the rider gets sent.
    if (plannedRoute.length >= 2) {
      final projection = GeoCalculations.projectOntoPolyline(
        sample.position,
        plannedRoute,
      );
      if (projection.distanceFromRouteMeters <=
          thresholds.matchedCorridorMeters) {
        state.lastMatchedProgressMeters = projection.distanceAlongRouteMeters;
      }
      state.lastProjection = projection;
    } else {
      state.lastProjection = null;
    }

    final severity = classify(
      assessment: assessment,
      followingLeaderTrack: followingLeaderTrack,
      distanceFromRouteMeters:
          state.lastProjection?.distanceFromRouteMeters ??
          assessment.distanceFromRouteMeters,
      now: evaluatedAt,
    );

    if (severity == RouteRejoinSeverity.onRoute) {
      // Back on route (or exempt): forget the throttle so a fresh deviation
      // gets a route immediately rather than waiting out the old interval. The
      // recorded last-matched progress is deliberately kept.
      state.resetRecompute();
      return state.plan = RouteRejoinPlan(
        riderId: riderId,
        severity: RouteRejoinSeverity.onRoute,
        status: RouteRejoinStatus.notRequired,
        computedAt: evaluatedAt,
        guidance: followingLeaderTrack
            ? 'Following the ride leader\'s track. On route.'
            : 'On route.',
      );
    }

    final massivelyOffRoute = severity == RouteRejoinSeverity.massivelyOffRoute;
    final distanceFromRoute =
        state.lastProjection?.distanceFromRouteMeters ??
        assessment.distanceFromRouteMeters;
    final timeOffRoute = assessment.offRouteSince == null
        ? null
        : evaluatedAt.difference(assessment.offRouteSince!);

    RouteRejoinPlan degrade(RouteRejoinStatus status, String detail) =>
        state.plan = RouteRejoinPlan(
          riderId: riderId,
          severity: severity,
          status: status,
          computedAt: evaluatedAt,
          guidance: _degradedGuidance(distanceFromRoute, detail),
          distanceFromRouteMeters: distanceFromRoute,
          timeOffRoute: timeOffRoute,
        );

    if (plannedRoute.length < 2) {
      return degrade(
        RouteRejoinStatus.noPlannedRoute,
        'No route is loaded, so there is nothing to rejoin.',
      );
    }
    if (massivelyOffRoute && leaderPosition == null) {
      return degrade(
        RouteRejoinStatus.leaderPositionUnknown,
        'The ride leader\'s position is unknown, so a rejoin point cannot be '
        'checked against it.',
      );
    }

    final leaderProgress = leaderPosition == null
        ? null
        : GeoCalculations.projectOntoPolyline(
            leaderPosition,
            plannedRoute,
          ).distanceAlongRouteMeters;

    // A massively off-course rider is sent to the TEC when there is a usable
    // one, and to the leader otherwise. Two independent gates: the TEC's
    // position must be believable at all (tracking), and it must not project
    // further along the route than the leader - a wild fix that does would send
    // the rider past the group, which is the one thing this must never do.
    final trackedTec = tecAvailability == TecAvailability.tracking
        ? tecPosition
        : null;
    final tecProgress = trackedTec == null || !massivelyOffRoute
        ? null
        : GeoCalculations.projectOntoPolyline(
            trackedTec,
            plannedRoute,
          ).distanceAlongRouteMeters;
    final tecIsBehindLeader =
        tecProgress != null &&
        leaderProgress != null &&
        tecProgress <=
            leaderProgress + thresholds.leaderProgressToleranceMeters;
    final target = !massivelyOffRoute
        ? RouteRejoinTarget.plannedRoute
        : tecIsBehindLeader
        ? RouteRejoinTarget.tailEndCharlie
        : RouteRejoinTarget.leader;
    final targetPosition = switch (target) {
      RouteRejoinTarget.tailEndCharlie => trackedTec,
      RouteRejoinTarget.leader => leaderPosition,
      RouteRejoinTarget.plannedRoute => null,
    };

    // Checked before the candidate sweep: when the recompute policy says no, the
    // retained plan is what the rider keeps seeing and there is nothing to
    // recalculate.
    if (!_shouldRecompute(
      state: state,
      now: evaluatedAt,
      riderPosition: sample.position,
      severity: severity,
      target: target,
      targetPosition: targetPosition,
    )) {
      final retained = state.plan;
      if (retained != null) return retained;
    }

    final selection = RouteRejoinGeometry.selectRejoin(
      route: plannedRoute,
      riderPosition: sample.position,
      lastMatchedProgressMeters:
          state.lastMatchedProgressMeters ??
          state.lastProjection?.distanceAlongRouteMeters ??
          0,
      leaderProgressMeters: leaderProgress,
      massivelyOffRoute: massivelyOffRoute,
      thresholds: thresholds,
    );
    final candidate = selection.candidate;
    if (candidate == null) {
      return degrade(selection.status, switch (selection.status) {
        RouteRejoinStatus.aheadOfLeaderOnly =>
          'The only way back onto the route from here is ahead of the ride '
              'leader, so no rejoin route is being offered. Hold position and '
              'contact the leader.',
        RouteRejoinStatus.noRejoinInRange =>
          'No usable rejoin point is within range.',
        RouteRejoinStatus.leaderPositionUnknown =>
          'The ride leader\'s position is unknown, so a rejoin point cannot be '
              'checked against it.',
        _ => 'No rejoin point could be selected.',
      });
    }

    state.lastAttemptAt = evaluatedAt;
    state.lastSeverity = severity;
    state.lastTarget = target;
    state.lastOrigin = sample.position;
    state.lastTargetPosition = targetPosition;

    // Rider, then the chosen rejoin point, then the moving target when it is
    // somewhere other than the rejoin point itself.
    final waypoints = <GeoPoint>[
      sample.position,
      candidate.point,
      if (targetPosition != null &&
          GeoCalculations.distanceMeters(candidate.point, targetPosition) > 50)
        targetPosition,
    ];

    try {
      _routingCallCount += 1;
      final result = await routingService.routeThrough(
        waypoints.map(_toRouteDomain).toList(growable: false),
      );
      if (result.points.length < 2) {
        throw const FormatException(
          'Road routing returned no usable geometry.',
        );
      }
      state.consecutiveFailures = 0;
      return state.plan = RouteRejoinPlan(
        riderId: riderId,
        severity: severity,
        status: RouteRejoinStatus.routed,
        target: target,
        computedAt: evaluatedAt,
        guidance: _routedGuidance(
          severity: severity,
          target: target,
          requiresBacktracking: candidate.requiresBacktracking,
          distanceMeters: result.distanceMeters,
          distanceFromRoute: distanceFromRoute,
        ),
        breadcrumb: List.unmodifiable(result.points.map(_fromRouteDomain)),
        maneuvers: List.unmodifiable(result.maneuvers),
        rejoinPoint: candidate.point,
        distanceMeters: result.distanceMeters,
        duration: result.duration,
        requiresBacktracking: candidate.requiresBacktracking,
        distanceFromRouteMeters: distanceFromRoute,
        timeOffRoute: timeOffRoute,
      );
    } on Object catch (error, stackTrace) {
      state.consecutiveFailures += 1;
      if (kDebugMode) {
        debugPrint('Rejoin routing failed for $riderId: $error\n$stackTrace');
      }
      return degrade(
        RouteRejoinStatus.routingUnavailable,
        'Rejoin routing is unavailable, so no route back is being drawn.',
      );
    }
  }

  /// Bands a rider by distance from the planned route and time off it. Either
  /// threshold alone promotes to [RouteRejoinSeverity.massivelyOffRoute].
  RouteRejoinSeverity classify({
    required RouteDeviationAssessment assessment,
    bool followingLeaderTrack = false,
    double? distanceFromRouteMeters,
    DateTime? now,
  }) {
    if (followingLeaderTrack) return RouteRejoinSeverity.onRoute;
    if (assessment.state != RouteTrackingState.offRoute) {
      return RouteRejoinSeverity.onRoute;
    }
    final distance =
        distanceFromRouteMeters ?? assessment.distanceFromRouteMeters;
    if (distance != null && distance >= thresholds.massivelyOffRouteMeters) {
      return RouteRejoinSeverity.massivelyOffRoute;
    }
    final since = assessment.offRouteSince;
    if (since != null) {
      final elapsed = (now ?? assessment.evaluatedAt).difference(since);
      if (elapsed >= thresholds.massivelyOffRouteAfter) {
        return RouteRejoinSeverity.massivelyOffRoute;
      }
    }
    return RouteRejoinSeverity.offRoute;
  }

  bool _shouldRecompute({
    required _RiderRejoinState state,
    required DateTime now,
    required GeoPoint riderPosition,
    required RouteRejoinSeverity severity,
    required RouteRejoinTarget? target,
    required GeoPoint? targetPosition,
  }) {
    final lastAttemptAt = state.lastAttemptAt;
    if (lastAttemptAt == null) return true;
    // The interval is a floor in every case, including a changed severity and
    // including a retry after failure.
    final floor = state.consecutiveFailures > 0
        ? recomputePolicy.backoffAfterFailures(state.consecutiveFailures)
        : recomputePolicy.minimumInterval;
    if (now.difference(lastAttemptAt) < floor) return false;
    if (state.lastSeverity != severity || state.lastTarget != target) {
      return true;
    }
    if (state.plan == null) return true;
    final origin = state.lastOrigin;
    if (origin == null ||
        GeoCalculations.distanceMeters(origin, riderPosition) >=
            recomputePolicy.minimumMovementMeters) {
      return true;
    }
    final previousTarget = state.lastTargetPosition;
    if (targetPosition != null &&
        previousTarget != null &&
        GeoCalculations.distanceMeters(previousTarget, targetPosition) >=
            recomputePolicy.minimumTargetMovementMeters) {
      return true;
    }
    return false;
  }

  String _degradedGuidance(double? distanceFromRoute, String detail) {
    final formatter = MeasurementFormatter(distanceUnit);
    final distance = distanceFromRoute == null
        ? 'You are off route.'
        : 'You are off route by ${formatter.distance(distanceFromRoute)}.';
    return '$distance $detail';
  }

  String _routedGuidance({
    required RouteRejoinSeverity severity,
    required RouteRejoinTarget target,
    required bool requiresBacktracking,
    required double distanceMeters,
    required double? distanceFromRoute,
  }) {
    final formatter = MeasurementFormatter(distanceUnit);
    final length = formatter.distance(distanceMeters);
    final lead = distanceFromRoute == null
        ? 'You are off route.'
        : 'You are off route by ${formatter.distance(distanceFromRoute)}.';
    final direction = requiresBacktracking
        ? 'No rejoin ahead of you was usable, so this route doubles back along '
              'the planned route.'
        : 'Rejoining ahead of where you left the route.';
    final destination = switch (target) {
      RouteRejoinTarget.plannedRoute => 'Advisory rejoin route of $length.',
      RouteRejoinTarget.tailEndCharlie =>
        'Advisory route of $length back to the route and on to Tail End '
            'Charlie, who is behind the leader. It updates as they move.',
      // Deliberately does not claim there is no TEC: the leader is also used
      // when a TEC's own fix cannot be trusted to be behind the leader.
      RouteRejoinTarget.leader =>
        'Advisory route of $length back to the route and on to the ride '
            'leader. It updates as they move.',
    };
    final caution = severity == RouteRejoinSeverity.massivelyOffRoute
        ? ' You are a long way off course; this rejoin stays behind the leader.'
        : '';
    return '$lead $direction $destination Follow the road signs and only the '
        'turns shown.$caution';
  }
}

class _RiderRejoinState {
  RouteRejoinPlan? plan;
  double? lastMatchedProgressMeters;
  PolylineProjection? lastProjection;
  DateTime? lastAttemptAt;
  RouteRejoinSeverity? lastSeverity;
  RouteRejoinTarget? lastTarget;
  GeoPoint? lastOrigin;
  GeoPoint? lastTargetPosition;
  int consecutiveFailures = 0;

  void resetRecompute() {
    plan = null;
    lastAttemptAt = null;
    lastSeverity = null;
    lastTarget = null;
    lastOrigin = null;
    lastTargetPosition = null;
    consecutiveFailures = 0;
  }
}
