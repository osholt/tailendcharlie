import 'dart:math' as math;

import '../domain/geo_point.dart';
import '../domain/rider_location.dart';
import '../domain/route_alert.dart';
import 'geo_calculations.dart';

class RouteDeviationConfig {
  const RouteDeviationConfig({
    this.enterOffRouteMeters = 120,
    this.exitOffRouteMeters = 60,
    this.samplesToConfirmOffRoute = 3,
    this.samplesToConfirmRecovery = 2,
    this.maxAcceptedAccuracyMeters = 75,
    this.staleAfter = const Duration(seconds: 30),
    this.coordinatorStaleAfter = const Duration(seconds: 90),
    this.criticalOffRouteAfter = const Duration(minutes: 3),
    this.leaderTrackCorridorMeters = 120,
  }) : assert(enterOffRouteMeters > exitOffRouteMeters),
       assert(samplesToConfirmOffRoute > 0),
       assert(samplesToConfirmRecovery > 0),
       assert(leaderTrackCorridorMeters > 0);

  final double enterOffRouteMeters;
  final double exitOffRouteMeters;
  final int samplesToConfirmOffRoute;
  final int samplesToConfirmRecovery;
  final double maxAcceptedAccuracyMeters;
  final Duration staleAfter;
  final Duration coordinatorStaleAfter;
  final Duration criticalOffRouteAfter;

  /// How close to the ride leader's *actual* recorded track a rider has to be
  /// to count as following the leader rather than as off course. Matched to
  /// [enterOffRouteMeters] so the leader's track is treated exactly as
  /// generously as the planned route is.
  final double leaderTrackCorridorMeters;
}

class RouteDeviationDetector {
  RouteDeviationDetector(
    List<GeoPoint> route, {
    this.config = const RouteDeviationConfig(),
    List<List<GeoPoint>>? routeSegments,
  }) : _routeSegments = _normalised(routeSegments ?? [route]);

  List<List<GeoPoint>> _routeSegments;
  final RouteDeviationConfig config;

  RouteTrackingState _stableState = RouteTrackingState.onRoute;
  int _outsideSamples = 0;
  int _insideSamples = 0;
  DateTime? _offRouteSince;

  /// Replaces the segments riders are compared against - e.g. once the ride
  /// leader's live trail has grown - without resetting the off-route/
  /// recovery hysteresis already in progress for this rider.
  void updateRouteSegments(List<List<GeoPoint>> routeSegments) {
    _routeSegments = _normalised(routeSegments);
  }

  static List<List<GeoPoint>> _normalised(List<List<GeoPoint>> segments) =>
      List.unmodifiable(
        segments.map((segment) => List<GeoPoint>.unmodifiable(segment)),
      );

  /// The stable state the hysteresis has settled on, before any caller-applied
  /// exemption. Exposed so a caller that overrides the verdict - the
  /// leader-follow exemption does - can still see what the geometry said.
  RouteTrackingState get stableState => _stableState;

  DateTime? get offRouteSince => _offRouteSince;

  /// Drops the off-route/recovery hysteresis and the off-route clock.
  ///
  /// Called when a rider is exempt from the planned-route comparison because
  /// they are following the ride leader's own track. Without this the detector
  /// would keep counting: a rider who spent twenty minutes behind the leader on
  /// a diversion would be an instant all-rider critical the moment they left
  /// the leader's track, instead of getting a fresh three-sample confirmation.
  void resetOffRouteHysteresis() {
    _stableState = RouteTrackingState.onRoute;
    _outsideSamples = 0;
    _insideSamples = 0;
    _offRouteSince = null;
  }

  /// The verdict for a rider inside the ride leader's live-track corridor.
  ///
  /// Such a rider is on route by definition, whatever the planned GPX says: the
  /// leader has physically ridden this road. Using one constructor for it keeps
  /// alert state, the leader's off-course count, the roster and the map in
  /// agreement.
  static RouteDeviationAssessment followingLeaderTrackAssessment({
    required DateTime evaluatedAt,
    double? distanceFromRouteMeters,
  }) => RouteDeviationAssessment(
    state: RouteTrackingState.onRoute,
    alertLevel: RouteAlertLevel.none,
    audience: RouteAlertAudience.rider,
    evaluatedAt: evaluatedAt,
    message: 'Following the ride leader\'s track.',
    distanceFromRouteMeters: distanceFromRouteMeters,
  );

  RouteDeviationAssessment evaluate(LocationSample sample, DateTime now) {
    final usableSegments = _routeSegments
        .where((segment) => segment.length >= 2)
        .toList(growable: false);
    if (usableSegments.isEmpty) {
      return RouteDeviationAssessment(
        state: RouteTrackingState.unavailable,
        alertLevel: RouteAlertLevel.none,
        audience: RouteAlertAudience.rider,
        evaluatedAt: now,
        message: 'No route is loaded.',
      );
    }

    final age = sample.ageAt(now);
    if (age > config.staleAfter ||
        sample.accuracyMeters > config.maxAcceptedAccuracyMeters) {
      final coordinatorAlert = age > config.coordinatorStaleAfter;
      return RouteDeviationAssessment(
        state: RouteTrackingState.gpsStale,
        alertLevel: coordinatorAlert
            ? RouteAlertLevel.urgent
            : RouteAlertLevel.watch,
        audience: coordinatorAlert
            ? RouteAlertAudience.coordinators
            : RouteAlertAudience.rider,
        evaluatedAt: now,
        message: sample.accuracyMeters > config.maxAcceptedAccuracyMeters
            ? 'GPS accuracy is too low for route alerts.'
            : 'No recent GPS position is available.',
        offRouteSince: _offRouteSince,
      );
    }

    final distance = usableSegments
        .map(
          (segment) => GeoCalculations.distanceToPolylineMeters(
            sample.position,
            segment,
          ),
        )
        .reduce(math.min);
    final confidentlyOutside =
        math.max(0, distance - sample.accuracyMeters) >
        config.enterOffRouteMeters;
    final confidentlyInside =
        distance + sample.accuracyMeters < config.exitOffRouteMeters;

    if (_stableState == RouteTrackingState.offRoute) {
      if (confidentlyInside) {
        _insideSamples += 1;
        if (_insideSamples >= config.samplesToConfirmRecovery) {
          _stableState = RouteTrackingState.onRoute;
          _insideSamples = 0;
          _outsideSamples = 0;
          _offRouteSince = null;
          return _assessment(
            state: RouteTrackingState.onRoute,
            now: now,
            distance: distance,
            message: 'Back on route.',
          );
        }
        return _assessment(
          state: RouteTrackingState.recovering,
          now: now,
          distance: distance,
          message: 'Route recovery is being confirmed.',
        );
      }
      _insideSamples = 0;
      return _offRouteAssessment(now, distance);
    }

    if (confidentlyOutside) {
      _outsideSamples += 1;
      if (_outsideSamples >= config.samplesToConfirmOffRoute) {
        _stableState = RouteTrackingState.offRoute;
        _offRouteSince ??= now;
        _insideSamples = 0;
        return _offRouteAssessment(now, distance);
      }
      return _assessment(
        state: RouteTrackingState.suspectedOffRoute,
        now: now,
        distance: distance,
        message: 'Possible route deviation; waiting for another GPS sample.',
      );
    }

    _outsideSamples = 0;
    return _assessment(
      state: RouteTrackingState.onRoute,
      now: now,
      distance: distance,
      message: 'On route.',
    );
  }

  RouteDeviationAssessment _offRouteAssessment(DateTime now, double distance) {
    final since = _offRouteSince ?? now;
    final critical = now.difference(since) >= config.criticalOffRouteAfter;
    return RouteDeviationAssessment(
      state: RouteTrackingState.offRoute,
      alertLevel: critical ? RouteAlertLevel.critical : RouteAlertLevel.urgent,
      audience: critical
          ? RouteAlertAudience.allRiders
          : RouteAlertAudience.coordinators,
      evaluatedAt: now,
      message: critical
          ? 'Rider remains off route; immediate follow-up required.'
          : 'Rider is confirmed off route. Lead and TEC should check in.',
      distanceFromRouteMeters: distance,
      offRouteSince: since,
    );
  }

  RouteDeviationAssessment _assessment({
    required RouteTrackingState state,
    required DateTime now,
    required double distance,
    required String message,
  }) => RouteDeviationAssessment(
    state: state,
    alertLevel:
        state == RouteTrackingState.suspectedOffRoute ||
            state == RouteTrackingState.recovering
        ? RouteAlertLevel.watch
        : RouteAlertLevel.none,
    audience: RouteAlertAudience.rider,
    evaluatedAt: now,
    message: message,
    distanceFromRouteMeters: distance,
    offRouteSince: _offRouteSince,
  );
}
