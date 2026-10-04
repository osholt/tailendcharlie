import 'package:http/http.dart' as http;

import '../domain/imported_route.dart';
import 'road_routing.dart';
import 'route_attribute_provider.dart';
import 'route_verification.dart';

/// Asks for the same route again without the given edges.
typedef ExclusionReplan =
    Future<RoadRouteResult> Function(List<GeoPoint> excludeLocations);

/// Checks a planned route against what the rider asked for, and re-plans once
/// when it breaks a preference (#840).
///
/// The routing engines cannot be trusted to have honoured the preferences they
/// were sent. OSRM's driving profile cannot express them and the public Valhalla
/// motorcycle costing ignores `exclude_unpaved`, so a canal-side `highway=track`
/// was routed under "avoid unsurfaced byways". The check does not depend on
/// which engine answered: it looks the geometry up once, edge by edge, and
/// compares.
///
/// A concern - a track, a footpath - is excluded by position and the route is
/// asked for again, once. The new route is used only if it is checked and has at
/// most half as much of the offending road in it, and only if it still starts
/// and ends where the first one did: an exclusion that moved the destination to
/// the next paved road is not an answer. Otherwise the original route is kept
/// and the concern is reported, with its length, for the rider to see on the
/// review. Nothing here ever hides a violation.
class RouteVerifier {
  const RouteVerifier({
    required this.attributes,
    this.maximumExclusions = 32,
    this.maximumEndpointShiftMeters = 150,
    this.minimumCoverage = 0.5,
    this.maximumOvershoot = 1.25,
    this.requiredImprovement = 0.5,
  });

  /// The checker every rider-facing planner uses.
  factory RouteVerifier.production({
    required http.Client client,
    required RoutingConfiguration configuration,
  }) => RouteVerifier(
    attributes: ValhallaRouteAttributeProvider(
      client: client,
      endpoint: configuration.routeAttributesUrl,
    ),
  );

  final RouteAttributeProvider attributes;

  /// Most edges excluded in one re-plan. Valhalla's public instance accepts
  /// at least 50; a motorway is dozens of edges and does not need them all.
  final int maximumExclusions;

  /// How far a re-planned route's start or end may differ from the original's.
  final double maximumEndpointShiftMeters;

  /// The matched road must account for at least this much of the line that was
  /// sent. Less means the line was not matched, and nothing can be said of it.
  final double minimumCoverage;

  /// More than this means the matcher went somewhere the route did not, so what
  /// it found may not be on the route at all.
  final double maximumOvershoot;

  /// A re-planned route is used only when what is left of the offending road is
  /// at most this fraction of what the first route had.
  final double requiredImprovement;

  /// Looks [points] up and classifies them against [preferences], without
  /// re-planning. One request. Never throws: a route that could not be checked
  /// is reported as unchecked, which is not the same as clean.
  Future<RouteVerification> inspect(
    List<GeoPoint> points,
    RoutePreferences? preferences,
  ) async {
    final resolved = preferences ?? RoutePreferences.defaults;
    final RouteTrace trace;
    try {
      trace = await attributes.trace(points);
    } on Object {
      return RouteVerification.unchecked(
        resolved,
        routeMeters: _length(points),
      );
    }
    final covered = trace.coveredMeters;
    if (trace.edges.isEmpty ||
        trace.submittedMeters <= 0 ||
        covered < trace.submittedMeters * minimumCoverage ||
        covered > trace.submittedMeters * maximumOvershoot) {
      return RouteVerification.unchecked(
        resolved,
        routeMeters: trace.routeMeters,
      );
    }
    return RouteVerification(
      preferences: resolved,
      checked: true,
      concerns: classifyRouteEdges(trace.edges, trace.shape, resolved),
      routeMeters: trace.routeMeters,
      coveredMeters: covered,
    );
  }

  /// Checks [route] and, if a hard preference is broken and [replan] is given,
  /// re-plans once. The result carries what was found.
  Future<RoadRouteResult> verify(
    RoadRouteResult route, {
    RoutePreferences? preferences,
    ExclusionReplan? replan,
  }) async {
    final first = await inspect(route.points, preferences);
    if (!first.checked || !first.hasConcerns || replan == null) {
      return route.withVerification(first);
    }
    final exclusions = selectExclusionLocations(
      first.concerns,
      maximumExclusions,
    );
    if (exclusions.isEmpty) return route.withVerification(first);
    final failed = first.copyWith(replan: RouteReplanOutcome.failed);
    final RoadRouteResult replanned;
    try {
      replanned = await replan(exclusions);
    } on Object {
      return route.withVerification(failed);
    }
    if (!_sameEnds(route.points, replanned.points)) {
      return route.withVerification(failed);
    }
    final second = await inspect(replanned.points, preferences);
    if (second.checked &&
        second.concernMeters <= first.concernMeters * requiredImprovement) {
      return replanned.withVerification(
        second.copyWith(
          replan: RouteReplanOutcome.adopted,
          avoided: first.concerns,
        ),
      );
    }
    return route.withVerification(failed);
  }

  bool _sameEnds(List<GeoPoint> first, List<GeoPoint> second) =>
      first.isNotEmpty &&
      second.isNotEmpty &&
      routeDistanceMeters(first.first, second.first) <=
          maximumEndpointShiftMeters &&
      routeDistanceMeters(first.last, second.last) <=
          maximumEndpointShiftMeters;

  static double _length(List<GeoPoint> points) {
    var total = 0.0;
    for (var index = 1; index < points.length; index += 1) {
      total += routeDistanceMeters(points[index - 1], points[index]);
    }
    return total;
  }
}

/// A routing service whose answers have been checked against the preferences
/// they were asked for.
///
/// One check per call: a planner makes one call per plan, so a route is looked
/// up once and, when it breaks a hard preference, once more after a re-plan. It
/// is **not** for `CircularRidePlanner`, which makes several calls to find one
/// loop and so checks only the loop it settles on, and not for the short legs a
/// ride makes to rejoin or reach its start, which are not planning decisions.
///
/// It deliberately offers neither of the motorcycle- or standard-costing
/// capabilities: a caller that tests for them is making the choices this class
/// would otherwise repeat on every call.
class VerifiedRoadRoutingService
    implements RoadRoutingService, ShapingPointRoadRoutingService {
  const VerifiedRoadRoutingService({
    required this.routing,
    required this.verifier,
  });

  final RoadRoutingService routing;
  final RouteVerifier verifier;

  @override
  Future<RoadRouteResult> routeThrough(
    List<GeoPoint> waypoints, {
    RoutePreferences? preferences,
    double? originBearingDegrees,
  }) async => verifier.verify(
    await routing.routeThrough(
      waypoints,
      preferences: preferences,
      originBearingDegrees: originBearingDegrees,
    ),
    preferences: preferences,
    replan: _replan(
      waypoints,
      preferences: preferences,
      originBearingDegrees: originBearingDegrees,
    ),
  );

  @override
  Future<RoadRouteResult> routeThroughShapingPoints(
    List<GeoPoint> waypoints, {
    required Set<int> shapingPointIndexes,
    double shapingPointSearchRadiusMeters = 0,
    RoutePreferences? preferences,
    RoadRoutingCosting costing = RoadRoutingCosting.preferred,
    double? originBearingDegrees,
  }) async {
    final service = routing;
    final result = service is ShapingPointRoadRoutingService
        ? await (service as ShapingPointRoadRoutingService)
              .routeThroughShapingPoints(
                waypoints,
                shapingPointIndexes: shapingPointIndexes,
                shapingPointSearchRadiusMeters: shapingPointSearchRadiusMeters,
                preferences: preferences,
                costing: costing,
                originBearingDegrees: originBearingDegrees,
              )
        : await service.routeThrough(
            waypoints,
            preferences: preferences,
            originBearingDegrees: originBearingDegrees,
          );
    return verifier.verify(
      result,
      preferences: preferences,
      replan: _replan(
        waypoints,
        shapingPointIndexes: shapingPointIndexes,
        shapingPointSearchRadiusMeters: shapingPointSearchRadiusMeters,
        preferences: preferences,
        originBearingDegrees: originBearingDegrees,
      ),
    );
  }

  /// Null when the wrapped service cannot exclude roads, in which case a
  /// concern can only be reported.
  ExclusionReplan? _replan(
    List<GeoPoint> waypoints, {
    Set<int>? shapingPointIndexes,
    double shapingPointSearchRadiusMeters = 0,
    RoutePreferences? preferences,
    double? originBearingDegrees,
  }) {
    final service = routing;
    if (service is! ExclusionRoadRoutingService) return null;
    final excluding = service as ExclusionRoadRoutingService;
    return (excluded) => excluding.routeThroughExcluding(
      waypoints,
      excludeLocations: excluded,
      shapingPointIndexes: shapingPointIndexes,
      shapingPointSearchRadiusMeters: shapingPointSearchRadiusMeters,
      preferences: preferences,
      originBearingDegrees: originBearingDegrees,
    );
  }
}

/// The routing every rider-facing planner uses: OSRM or Valhalla by what the
/// preferences need, with the result checked against them.
///
/// One definition, because every place that built its own is a place that can
/// forget the preferences. The Home destination search built OSRM alone, which
/// cannot express any of them and has no way to be told to avoid a road, so a
/// route it planned could neither honour a preference nor be re-planned around
/// a track.
RoadRoutingService buildPlanningRoutingService({
  required http.Client client,
  required RoutingConfiguration configuration,
}) => VerifiedRoadRoutingService(
  routing: PreferenceAwareRoadRoutingService(
    osrm: OsrmRoadRoutingService(
      client: client,
      baseUrl: configuration.routingBaseUrl,
    ),
    motorcycle: ValhallaMotorcycleRoutingService(
      client: client,
      routeUrl: configuration.motorcycleRoutingUrl,
    ),
  ),
  verifier: RouteVerifier.production(
    client: client,
    configuration: configuration,
  ),
);
