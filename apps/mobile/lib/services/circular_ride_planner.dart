import 'dart:async';
import 'dart:math' as math;

import '../domain/imported_route.dart';
import '../domain/recorded_route_store.dart';
import 'road_routing.dart';
import 'route_twistiness.dart';

enum CircularRideDirection {
  north('N', 0),
  northEast('NE', 45),
  east('E', 90),
  southEast('SE', 135),
  south('S', 180),
  southWest('SW', 225),
  west('W', 270),
  northWest('NW', 315);

  const CircularRideDirection(this.label, this.bearingDegrees);

  final String label;
  final double bearingDegrees;
}

enum RideDayLength {
  custom('Custom distance', null),
  halfDay('Half day', Duration(hours: 4)),
  fullDay('Full day', Duration(hours: 8));

  const RideDayLength(this.label, this.duration);

  final String label;
  final Duration? duration;
}

enum CircularRideStopKind { fuel, comfort, meal }

enum CircularRideHeatmapPreference {
  none('Do not prefer familiar roads'),
  personal('Prefer roads from my rides'),
  global('Prefer popular public roads');

  const CircularRideHeatmapPreference(this.label);
  final String label;
}

class CircularRideHeatCell {
  const CircularRideHeatCell({required this.point, required this.weight});
  final GeoPoint point;
  final double weight;
}

class ScheduledCircularRideStop {
  const ScheduledCircularRideStop({required this.after, required this.kinds});

  final Duration after;
  final Set<CircularRideStopKind> kinds;
}

class CircularRideRequest {
  const CircularRideRequest({
    required this.start,
    required this.distanceMeters,
    required this.direction,
    required this.preferences,
    this.variant = 0,
    this.dayLength = RideDayLength.custom,
    this.fuelEvery = const Duration(hours: 2),
    this.comfortEvery = const Duration(minutes: 90),
    this.mealAfter = const Duration(hours: 3),
    this.plannedStops = const [],
    this.heatmapPreference = CircularRideHeatmapPreference.none,
    this.heatmapCells = const [],
  });

  final GeoPoint start;
  final double distanceMeters;
  final CircularRideDirection direction;
  final RoutePreferences preferences;
  final int variant;
  final RideDayLength dayLength;
  final Duration fuelEvery;
  final Duration comfortEvery;
  final Duration mealAfter;
  final List<CircularRideStop> plannedStops;
  final CircularRideHeatmapPreference heatmapPreference;
  final List<CircularRideHeatCell> heatmapCells;

  CircularRideRequest another() => CircularRideRequest(
    start: start,
    distanceMeters: distanceMeters,
    direction: direction,
    preferences: preferences,
    variant: variant + 1,
    dayLength: dayLength,
    fuelEvery: fuelEvery,
    comfortEvery: comfortEvery,
    mealAfter: mealAfter,
    plannedStops: plannedStops,
    heatmapPreference: heatmapPreference,
    heatmapCells: heatmapCells,
  );

  CircularRideRequest withVariant(int value) => CircularRideRequest(
    start: start,
    distanceMeters: distanceMeters,
    direction: direction,
    preferences: preferences,
    variant: value,
    dayLength: dayLength,
    fuelEvery: fuelEvery,
    comfortEvery: comfortEvery,
    mealAfter: mealAfter,
    plannedStops: plannedStops,
    heatmapPreference: heatmapPreference,
    heatmapCells: heatmapCells,
  );

  CircularRideRequest withPlannedStops(List<CircularRideStop> stops) =>
      CircularRideRequest(
        start: start,
        distanceMeters: distanceMeters,
        direction: direction,
        preferences: preferences,
        variant: variant,
        dayLength: dayLength,
        fuelEvery: fuelEvery,
        comfortEvery: comfortEvery,
        mealAfter: mealAfter,
        plannedStops: List.unmodifiable(stops),
        heatmapPreference: heatmapPreference,
        heatmapCells: heatmapCells,
      );
}

class CircularRideStop {
  const CircularRideStop({
    required this.fraction,
    required this.waypoint,
    this.kinds = const {CircularRideStopKind.comfort},
    this.scheduledAfter,
  });

  final double fraction;
  final RouteWaypoint waypoint;
  final Set<CircularRideStopKind> kinds;
  final Duration? scheduledAfter;
}

class CircularRidePlan {
  const CircularRidePlan({
    required this.route,
    required this.request,
    required this.requestedDistanceMeters,
    required this.actualDistanceMeters,
    required this.duration,
    required this.twistinessScore,
    this.warnings = const [],
    this.motorwayAvoidanceRelaxed = false,
    this.motorwayAvoidanceRelaxedSections = 0,
    this.standardRoutingFallbackSections = 0,
    this.routeSectionCount = 0,
  });

  final ImportedRoute route;
  final CircularRideRequest request;
  final double requestedDistanceMeters;
  final double actualDistanceMeters;
  final Duration duration;
  final double? twistinessScore;
  final List<String> warnings;
  final bool motorwayAvoidanceRelaxed;
  final int motorwayAvoidanceRelaxedSections;
  final int standardRoutingFallbackSections;
  final int routeSectionCount;
}

String circularRideMotorwayFallbackWarning({
  required int relaxedSectionCount,
  required int routeSectionCount,
}) {
  final noun = routeSectionCount == 1 ? 'section' : 'sections';
  return 'Avoid motorways was relaxed for $relaxedSectionCount of '
      '$routeSectionCount route $noun because the motorway-free path was '
      'unavailable or excessively indirect there. Only those sections may use '
      'motorways; review them carefully before accepting.';
}

String circularRideStandardRoutingFallbackWarning({
  required int fallbackSectionCount,
  required int routeSectionCount,
  required RoutePreferences requestedPreferences,
}) {
  final unavailableSettings = [
    if (requestedPreferences.avoidMotorways) 'Avoid motorways',
    if (requestedPreferences.avoidMajorRoads) 'Prefer quieter roads',
    if (requestedPreferences.avoidTolls) 'Avoid tolls',
    if (requestedPreferences.avoidFerries) 'Avoid ferries',
    if (!requestedPreferences.bywaySurface.avoidsUnsurfaced)
      'Allow unsurfaced byways',
  ];
  final affected = fallbackSectionCount == 1
      ? 'that section'
      : 'those sections';
  final limitation = unavailableSettings.isEmpty
      ? ''
      : ' ${unavailableSettings.join(', ')} could not be guaranteed on '
            '$affected.';
  return 'Motorcycle routing timed out, so $fallbackSectionCount of '
      '$routeSectionCount route sections used standard road routing.'
      '$limitation The selected road-character bias was kept; review '
      '$affected carefully before accepting.';
}

/// Generates a road-routed loop from three non-stopping shaping controls.
///
/// The controls form a broad diamond in the requested compass direction. A
/// variant changes its handedness and angle, so “another route” makes a
/// materially different request rather than asking the router the same thing.
class CircularRidePlanner {
  const CircularRidePlanner({required this.routingService});

  static const _maximumCandidateVariants = 4;

  final RoadRoutingService routingService;

  Future<CircularRidePlan> generate(CircularRideRequest request) async {
    if (!request.distanceMeters.isFinite ||
        request.distanceMeters < 8_000 ||
        request.distanceMeters > 800_000) {
      throw const FormatException(
        'Circular rides must be between 8 km and 800 km.',
      );
    }
    if ([request.fuelEvery, request.comfortEvery].any(
          (interval) =>
              interval < const Duration(minutes: 30) ||
              interval > const Duration(hours: 4),
        ) ||
        request.mealAfter < const Duration(hours: 1) ||
        request.mealAfter > const Duration(hours: 6)) {
      throw const FormatException(
        'Fuel and comfort intervals must be 30 minutes to 4 hours, and meal time 1 to 6 hours.',
      );
    }

    final failures = <_CircularRideCandidateFailureKind>[];
    final routingFallback = _CircularRideRoutingFallbackState();
    final candidate = await _tryCandidateVariants(
      request,
      failures: failures,
      routingFallback: routingFallback,
    );
    if (candidate == null) {
      throw FormatException(_circularRideFailureMessage(request, failures));
    }

    final selectedRequest = candidate.request;
    final controls = candidate.controls;
    final result = candidate.result;
    final motorwayAvoidanceRelaxedSections =
        candidate.motorwayAvoidanceRelaxedSections +
        (selectedRequest.preferences.avoidMotorways
            ? candidate.standardRoutingFallbackSections
            : 0);
    final motorwayAvoidanceRelaxed = motorwayAvoidanceRelaxedSections > 0;
    final motorwayWarning = candidate.motorwayAvoidanceRelaxedSections > 0
        ? circularRideMotorwayFallbackWarning(
            relaxedSectionCount: candidate.motorwayAvoidanceRelaxedSections,
            routeSectionCount: candidate.routeSectionCount,
          )
        : null;
    final standardRoutingWarning = candidate.standardRoutingFallbackSections > 0
        ? circularRideStandardRoutingFallbackWarning(
            fallbackSectionCount: candidate.standardRoutingFallbackSections,
            routeSectionCount: candidate.routeSectionCount,
            requestedPreferences: selectedRequest.preferences,
          )
        : null;
    final warnings = [?motorwayWarning, ?standardRoutingWarning];
    final now = DateTime.now().toUtc();
    final route = ImportedRoute(
      id: 'circular-${now.microsecondsSinceEpoch}-${selectedRequest.variant}',
      name: _routeName(selectedRequest),
      description: _description(
        selectedRequest,
        candidate.preferences,
        warnings: warnings,
      ),
      importedAt: now,
      sourceFileName: 'circular-planner',
      paths: [
        RoutePath(
          kind: RoutePathKind.route,
          name: 'Circular road route',
          points: result.points,
        ),
      ],
      waypoints: [
        RouteWaypoint(point: selectedRequest.start, name: 'Start and finish'),
        ...selectedRequest.plannedStops.map((stop) => stop.waypoint),
        RouteWaypoint(point: selectedRequest.start, name: 'Finish'),
      ],
      shapingPoints: [
        for (final (index, point) in controls.indexed)
          RouteShapingPoint(
            id: 'loop-${selectedRequest.variant}-$index',
            point: point,
            legIndex: selectedRequest.plannedStops
                .where((stop) => stop.fraction < (index + 1) / 4)
                .length,
          ),
      ],
      maneuvers: result.maneuvers,
      preferences: candidate.preferences,
      plannedDuration: result.duration,
    );
    return CircularRidePlan(
      route: route,
      request: selectedRequest,
      requestedDistanceMeters: selectedRequest.distanceMeters,
      actualDistanceMeters: result.distanceMeters,
      duration: result.duration,
      twistinessScore: result.twistinessScore,
      warnings: List.unmodifiable(warnings),
      motorwayAvoidanceRelaxed: motorwayAvoidanceRelaxed,
      motorwayAvoidanceRelaxedSections: motorwayAvoidanceRelaxedSections,
      standardRoutingFallbackSections:
          candidate.standardRoutingFallbackSections,
      routeSectionCount: candidate.routeSectionCount,
    );
  }

  Future<_CircularRideCandidate?> _tryCandidateVariants(
    CircularRideRequest request, {
    required List<_CircularRideCandidateFailureKind> failures,
    required _CircularRideRoutingFallbackState routingFallback,
  }) async {
    for (var offset = 0; offset < _maximumCandidateVariants; offset += 1) {
      final candidateRequest = request.withVariant(request.variant + offset);
      try {
        return await _generateCandidate(
          candidateRequest,
          request.preferences,
          routingFallback: routingFallback,
        );
      } on _CircularRideCandidateFailure catch (failure) {
        failures.add(failure.kind);
      }
    }
    return null;
  }

  Future<_CircularRideCandidate> _generateCandidate(
    CircularRideRequest request,
    RoutePreferences preferences, {
    required _CircularRideRoutingFallbackState routingFallback,
  }) async {
    var shapingDistance = request.distanceMeters;
    for (var attempt = 0; attempt < 3; attempt += 1) {
      final controls = circularRideShapingPoints(
        request,
        shapingDistanceMeters: shapingDistance,
      );
      final orderedControls =
          <({double fraction, GeoPoint point, bool isStop})>[
            for (final (index, point) in controls.indexed)
              (fraction: (index + 1) / 4, point: point, isStop: false),
            for (final stop in request.plannedStops)
              (
                fraction: stop.fraction,
                point: stop.waypoint.point,
                isStop: true,
              ),
          ]..sort((first, second) => first.fraction.compareTo(second.fraction));
      late final RoadRouteResult result;
      late final _CircularRideSections sections;
      try {
        final waypoints = [
          request.start,
          ...orderedControls.map((control) => control.point),
          request.start,
        ];
        sections = await _routeSections(
          waypoints,
          preserveInternalBoundary: [
            for (final control in orderedControls) control.isStop,
          ],
          preferences: preferences,
          routingFallback: routingFallback,
        );
        result = sections.result;
      } on RoadRoutingException catch (error) {
        if (!error.routeNotFound) rethrow;
        throw const _CircularRideCandidateFailure(
          _CircularRideCandidateFailureKind.noRoute,
        );
      }
      if (!_isClosedRoute(request.start, result)) {
        throw const _CircularRideCandidateFailure(
          _CircularRideCandidateFailureKind.notClosed,
        );
      }
      if (_hasUTurn(result)) {
        throw const _CircularRideCandidateFailure(
          _CircularRideCandidateFailureKind.uTurn,
        );
      }
      if (circularRideDistanceWithinTolerance(
        requestedMeters: request.distanceMeters,
        actualMeters: result.distanceMeters,
      )) {
        return _CircularRideCandidate(
          request: request,
          preferences: preferences,
          controls: controls,
          result: result,
          motorwayAvoidanceRelaxedSections:
              sections.motorwayAvoidanceRelaxedSections,
          standardRoutingFallbackSections:
              sections.standardRoutingFallbackSections,
          routeSectionCount: sections.routeSectionCount,
        );
      }
      if (attempt == 2 ||
          !result.distanceMeters.isFinite ||
          result.distanceMeters <= 0) {
        throw const _CircularRideCandidateFailure(
          _CircularRideCandidateFailureKind.distanceMismatch,
        );
      }
      shapingDistance =
          (shapingDistance * request.distanceMeters / result.distanceMeters)
              .clamp(request.distanceMeters * 0.4, request.distanceMeters * 1.8)
              .toDouble();
    }
    throw const _CircularRideCandidateFailure(
      _CircularRideCandidateFailureKind.distanceMismatch,
    );
  }

  Future<_CircularRideSections> _routeSections(
    List<GeoPoint> waypoints, {
    required List<bool> preserveInternalBoundary,
    required RoutePreferences preferences,
    required _CircularRideRoutingFallbackState routingFallback,
  }) async {
    // Let the first section establish whether motorcycle routing is healthy.
    // Once that is known, the remaining sections can run concurrently without
    // turning a provider outage into four independent timeout waits.
    final sections = <_CircularRideSection>[
      await _routeSection(
        waypoints.first,
        waypoints[1],
        preferences: preferences,
        routingFallback: routingFallback,
      ),
    ];
    sections.addAll(
      await Future.wait([
        for (var index = 1; index < waypoints.length - 1; index += 1)
          _routeSection(
            waypoints[index],
            waypoints[index + 1],
            preferences: preferences,
            routingFallback: routingFallback,
          ),
      ]),
    );
    final points = <GeoPoint>[];
    final maneuvers = <RoadRouteManeuver>[];
    var distanceMeters = 0.0;
    var durationMicroseconds = 0;
    var relaxedSectionCount = 0;
    var standardRoutingFallbackCount = 0;
    for (final (index, section) in sections.indexed) {
      final result = section.result;
      points.addAll(points.isEmpty ? result.points : result.points.skip(1));
      distanceMeters += result.distanceMeters;
      durationMicroseconds += result.duration.inMicroseconds;
      if (section.motorwayAvoidanceRelaxed) relaxedSectionCount += 1;
      if (section.standardRoutingFallback) {
        standardRoutingFallbackCount += 1;
      }
      final preserveStart = index > 0 && preserveInternalBoundary[index - 1];
      final preserveEnd =
          index < sections.length - 1 && preserveInternalBoundary[index];
      maneuvers.addAll(
        result.maneuvers.where(
          (maneuver) =>
              (index == 0 || preserveStart || maneuver.type != 'depart') &&
              (index == sections.length - 1 ||
                  preserveEnd ||
                  maneuver.type != 'arrive'),
        ),
      );
    }
    return _CircularRideSections(
      result: RoadRouteResult(
        points: List.unmodifiable(points),
        distanceMeters: distanceMeters,
        duration: Duration(microseconds: durationMicroseconds),
        maneuvers: List.unmodifiable(maneuvers),
        twistinessScore: RouteTwistiness.score(
          points,
          distanceMeters: distanceMeters,
        ),
        preferences: preferences,
      ),
      motorwayAvoidanceRelaxedSections: relaxedSectionCount,
      standardRoutingFallbackSections: standardRoutingFallbackCount,
      routeSectionCount: sections.length,
    );
  }

  Future<_CircularRideSection> _routeSection(
    GeoPoint start,
    GeoPoint finish, {
    required RoutePreferences preferences,
    required _CircularRideRoutingFallbackState routingFallback,
  }) async {
    final waypoints = [start, finish];
    final standardService = routingService is StandardCostingRoadRoutingService
        ? routingService as StandardCostingRoadRoutingService
        : null;
    if (routingFallback.standardRoutingOnly && standardService != null) {
      return _routeStandardSection(
        standardService,
        waypoints,
        requestedPreferences: preferences,
      );
    }
    try {
      final result = await routingService.routeThrough(
        waypoints,
        preferences: preferences,
      );
      if (!preferences.avoidMotorways ||
          !_hasExcessiveSectionDetour(start, finish, result)) {
        return _CircularRideSection(result: result);
      }
      try {
        final relaxedResult = await _routeWithMotorwaysAllowed(
          waypoints,
          preferences: preferences,
        );
        if (_motorwayFallbackImprovesSection(result, relaxedResult)) {
          return _CircularRideSection(
            result: relaxedResult,
            motorwayAvoidanceRelaxed: true,
          );
        }
      } on TimeoutException {
        // The avoidance route is usable, so an optional comparison timing out
        // is not a reason to discard the candidate.
      } on RoadRoutingException {
        // Keep the usable avoidance route if allowing motorways does not route.
      } on FormatException {
        // A malformed optional comparison cannot invalidate the usable route.
      }
      return _CircularRideSection(result: result);
    } on TimeoutException {
      if (standardService == null) rethrow;
      routingFallback.standardRoutingOnly = true;
      return _routeStandardSection(
        standardService,
        waypoints,
        requestedPreferences: preferences,
      );
    } on RoadRoutingException catch (error) {
      if (!error.routeNotFound || !preferences.avoidMotorways) rethrow;
      return _CircularRideSection(
        result: await _routeWithMotorwaysAllowed(
          waypoints,
          preferences: preferences,
        ),
        motorwayAvoidanceRelaxed: true,
      );
    }
  }

  Future<RoadRouteResult> _routeWithMotorwaysAllowed(
    List<GeoPoint> waypoints, {
    required RoutePreferences preferences,
  }) {
    final relaxed = preferences.copyWith(avoidMotorways: false);
    final service = routingService;
    return service is MotorcycleCostingRoadRoutingService
        ? (service as MotorcycleCostingRoadRoutingService)
              .routeThroughMotorcycle(waypoints, preferences: relaxed)
        : service.routeThrough(waypoints, preferences: relaxed);
  }

  Future<_CircularRideSection> _routeStandardSection(
    StandardCostingRoadRoutingService service,
    List<GeoPoint> waypoints, {
    required RoutePreferences requestedPreferences,
  }) async {
    final standardPreferences = RoutePreferences(
      style: requestedPreferences.style,
    );
    return _CircularRideSection(
      result: await service.routeThroughStandard(
        waypoints,
        preferences: standardPreferences,
      ),
      standardRoutingFallback: true,
    );
  }

  static String _routeName(CircularRideRequest request) {
    final miles = (request.distanceMeters / 1609.344).round();
    return switch (request.dayLength) {
      RideDayLength.custom => '$miles mi ${request.direction.label} loop',
      RideDayLength.halfDay => '${request.direction.label} half-day ride',
      RideDayLength.fullDay => '${request.direction.label} day ride',
    };
  }

  static String _description(
    CircularRideRequest request,
    RoutePreferences preferences, {
    required List<String> warnings,
  }) {
    return 'Generated ${request.direction.label} circular ride; '
        '${preferences.summary} Fuel every ${request.fuelEvery.inMinutes} min, '
        'comfort every ${request.comfortEvery.inMinutes} min, meal after '
        '${request.mealAfter.inMinutes} min. '
        '${request.heatmapPreference == CircularRideHeatmapPreference.none ? 'No heatmap preference.' : 'Soft preference: ${request.heatmapPreference.label.toLowerCase()}.'}'
        '${warnings.isEmpty ? '' : ' ${warnings.join(' ')}'}';
  }
}

enum _CircularRideCandidateFailureKind {
  noRoute,
  uTurn,
  notClosed,
  distanceMismatch,
}

class _CircularRideCandidateFailure implements Exception {
  const _CircularRideCandidateFailure(this.kind);

  final _CircularRideCandidateFailureKind kind;
}

class _CircularRideCandidate {
  const _CircularRideCandidate({
    required this.request,
    required this.preferences,
    required this.controls,
    required this.result,
    required this.motorwayAvoidanceRelaxedSections,
    required this.standardRoutingFallbackSections,
    required this.routeSectionCount,
  });

  final CircularRideRequest request;
  final RoutePreferences preferences;
  final List<GeoPoint> controls;
  final RoadRouteResult result;
  final int motorwayAvoidanceRelaxedSections;
  final int standardRoutingFallbackSections;
  final int routeSectionCount;
}

class _CircularRideSection {
  const _CircularRideSection({
    required this.result,
    this.motorwayAvoidanceRelaxed = false,
    this.standardRoutingFallback = false,
  });

  final RoadRouteResult result;
  final bool motorwayAvoidanceRelaxed;
  final bool standardRoutingFallback;
}

class _CircularRideSections {
  const _CircularRideSections({
    required this.result,
    required this.motorwayAvoidanceRelaxedSections,
    required this.standardRoutingFallbackSections,
    required this.routeSectionCount,
  });

  final RoadRouteResult result;
  final int motorwayAvoidanceRelaxedSections;
  final int standardRoutingFallbackSections;
  final int routeSectionCount;
}

class _CircularRideRoutingFallbackState {
  bool standardRoutingOnly = false;
}

String _circularRideFailureMessage(
  CircularRideRequest request,
  List<_CircularRideCandidateFailureKind> failures,
) {
  if (failures.isNotEmpty &&
      failures.every(
        (failure) => failure == _CircularRideCandidateFailureKind.uTurn,
      )) {
    return 'No circular route without a U-turn could be found after trying '
        'different loop shapes. Try another direction or adjust the distance.';
  }
  if (request.preferences.avoidMotorways) {
    return 'No usable circular route could be found after trying different '
        'loop shapes and allowing motorways only on blocked sections. Try '
        'another direction or adjust the distance.';
  }
  const lead = 'No circular route could be found with those settings.';
  if (request.preferences.avoidMajorRoads ||
      request.preferences.avoidTolls ||
      request.preferences.avoidFerries) {
    return '$lead Try relaxing a road exclusion, choosing another direction, '
        'or reducing the distance.';
  }
  return '$lead Try choosing another direction or reducing the distance.';
}

const circularRideDistanceTolerance = 0.30;
const circularRideClosureToleranceMeters = 500.0;

// A hard exclusion can still produce a nominal route by sending a section far
// around a barrier. For a circular ride that is no more usable than "no path":
// it makes the distance corrector oscillate and can introduce a U-turn. Both a
// proportional and absolute bound are required so ordinary local detours do not
// relax a rider's motorway preference.
const _circularRideMaximumSectionDetourRatio = 1.8;
const _circularRideMinimumSectionDetourMeters = 20_000.0;
const _circularRideMinimumFallbackSavingRatio = 0.15;
const _circularRideMinimumFallbackSavingMeters = 10_000.0;

bool circularRideDistanceWithinTolerance({
  required double requestedMeters,
  required double actualMeters,
}) {
  if (!requestedMeters.isFinite ||
      !actualMeters.isFinite ||
      requestedMeters <= 0 ||
      actualMeters <= 0) {
    return false;
  }
  return ((actualMeters - requestedMeters).abs() / requestedMeters) <=
      circularRideDistanceTolerance;
}

bool _isClosedRoute(GeoPoint start, RoadRouteResult result) =>
    result.points.length >= 2 &&
    _distanceMetres(start, result.points.first) <=
        circularRideClosureToleranceMeters &&
    _distanceMetres(start, result.points.last) <=
        circularRideClosureToleranceMeters;

bool _hasUTurn(RoadRouteResult result) => result.maneuvers.any((maneuver) {
  final modifier = maneuver.modifier?.trim().toLowerCase().replaceAll('-', ' ');
  return modifier == 'uturn' || modifier == 'u turn';
});

bool _hasExcessiveSectionDetour(
  GeoPoint start,
  GeoPoint finish,
  RoadRouteResult result,
) {
  final directDistance = _distanceMetres(start, finish);
  if (!directDistance.isFinite || directDistance <= 0) return false;
  return result.distanceMeters >=
          directDistance * _circularRideMaximumSectionDetourRatio &&
      result.distanceMeters - directDistance >=
          _circularRideMinimumSectionDetourMeters;
}

bool _motorwayFallbackImprovesSection(
  RoadRouteResult avoided,
  RoadRouteResult relaxed,
) {
  if (!relaxed.distanceMeters.isFinite || relaxed.distanceMeters <= 0) {
    return false;
  }
  final saving = avoided.distanceMeters - relaxed.distanceMeters;
  if (saving <= 0 || _hasUTurn(relaxed)) return false;
  if (_hasUTurn(avoided)) return true;
  return saving >= _circularRideMinimumFallbackSavingMeters &&
      saving / avoided.distanceMeters >=
          _circularRideMinimumFallbackSavingRatio;
}

Future<void> saveCircularRideToLibrary(
  ImportedRoute route,
  RecordedRouteStore store,
) => store.save(route);

/// Shared itinerary contract mirrored by planner-core.mjs and its JSON fixture.
List<ScheduledCircularRideStop> circularRideItinerary(
  CircularRideRequest request,
) {
  final duration = request.dayLength.duration;
  if (duration == null) return const [];
  final byMinute = <int, Set<CircularRideStopKind>>{};
  void addRepeating(Duration interval, CircularRideStopKind kind) {
    for (
      var minute = interval.inMinutes;
      minute < duration.inMinutes;
      minute += interval.inMinutes
    ) {
      byMinute.putIfAbsent(minute, () => <CircularRideStopKind>{}).add(kind);
    }
  }

  addRepeating(request.fuelEvery, CircularRideStopKind.fuel);
  addRepeating(request.comfortEvery, CircularRideStopKind.comfort);
  if (request.mealAfter < duration) {
    byMinute
        .putIfAbsent(
          request.mealAfter.inMinutes,
          () => <CircularRideStopKind>{},
        )
        .add(CircularRideStopKind.meal);
  }
  return [
    for (final entry
        in byMinute.entries.toList()..sort((a, b) => a.key.compareTo(b.key)))
      ScheduledCircularRideStop(
        after: Duration(minutes: entry.key),
        kinds: Set.unmodifiable(entry.value),
      ),
  ];
}

/// Pure geometry shared by tests and mirrored by the web planner.
List<GeoPoint> circularRideShapingPoints(
  CircularRideRequest request, {
  double? shapingDistanceMeters,
}) {
  final variant = request.variant % 8;
  final handedness = variant.isEven ? 1.0 : -1.0;
  final rotation = ((variant ~/ 2) * 7.5) * handedness;
  final heading = request.direction.bearingDegrees + rotation;
  // The four straight legs of this diamond total about 3.78 radii. Roads add
  // some distance, so 4.25 gives the router useful room without systematically
  // overshooting the requested total.
  final radius = (shapingDistanceMeters ?? request.distanceMeters) / 4.25;
  final controls = [
    _offset(
      request.start,
      forwardMeters: radius * 0.45,
      rightMeters: radius * 0.8 * -handedness,
      headingDegrees: heading,
    ),
    _destination(request.start, heading, radius),
    _offset(
      request.start,
      forwardMeters: radius * 0.45,
      rightMeters: radius * 0.8 * handedness,
      headingDegrees: heading,
    ),
  ];
  return heatmapBiasedCircularRideControls(
    controls: controls,
    start: request.start,
    cells: request.heatmapCells,
    enabled: request.heatmapPreference != CircularRideHeatmapPreference.none,
    searchRadiusMeters: radius * 0.75,
  );
}

const circularRideMinimumHeatmapCells = 20;
const circularRideHeatmapBiasStrength = 0.2;
const circularRideHeatmapStartExclusionMeters = 2000.0;

bool circularRideHeatmapBiasAvailable(
  Iterable<CircularRideHeatCell> cells, {
  GeoPoint? start,
}) =>
    cells.where((cell) {
      if (cell.weight <= 0) return false;
      return start == null ||
          _distanceMetres(start, cell.point) >=
              circularRideHeatmapStartExclusionMeters;
    }).length >=
    circularRideMinimumHeatmapCells;

/// Nudges shaping controls toward coverage; it never makes coverage mandatory.
/// Cells close to the ride start are excluded so a home-area cluster cannot
/// steer the route generator even when the local layer contains it.
List<GeoPoint> heatmapBiasedCircularRideControls({
  required List<GeoPoint> controls,
  required GeoPoint start,
  required List<CircularRideHeatCell> cells,
  required bool enabled,
  required double searchRadiusMeters,
  double strength = circularRideHeatmapBiasStrength,
}) {
  if (!enabled || !circularRideHeatmapBiasAvailable(cells, start: start)) {
    return controls;
  }
  final eligible = cells
      .where(
        (cell) =>
            cell.weight > 0 &&
            _distanceMetres(start, cell.point) >=
                circularRideHeatmapStartExclusionMeters,
      )
      .toList(growable: false);
  if (eligible.length < circularRideMinimumHeatmapCells) return controls;
  return [
    for (final control in controls)
      () {
        final nearby =
            eligible
                .map(
                  (cell) => (
                    cell: cell,
                    distance: _distanceMetres(control, cell.point),
                  ),
                )
                .where((candidate) => candidate.distance <= searchRadiusMeters)
                .toList()
              ..sort(
                (a, b) => (a.distance / a.cell.weight).compareTo(
                  b.distance / b.cell.weight,
                ),
              );
        final target = nearby.firstOrNull?.cell.point;
        if (target == null) return control;
        final amount = strength.clamp(0.0, 0.35);
        return GeoPoint(
          latitude:
              control.latitude + (target.latitude - control.latitude) * amount,
          longitude:
              control.longitude +
              (target.longitude - control.longitude) * amount,
        );
      }(),
  ];
}

double _distanceMetres(GeoPoint a, GeoPoint b) {
  const radius = 6371008.8;
  final lat1 = a.latitude * math.pi / 180;
  final lat2 = b.latitude * math.pi / 180;
  final deltaLat = lat2 - lat1;
  final deltaLon = (b.longitude - a.longitude) * math.pi / 180;
  final value =
      math.sin(deltaLat / 2) * math.sin(deltaLat / 2) +
      math.cos(lat1) *
          math.cos(lat2) *
          math.sin(deltaLon / 2) *
          math.sin(deltaLon / 2);
  return radius * 2 * math.atan2(math.sqrt(value), math.sqrt(1 - value));
}

GeoPoint _offset(
  GeoPoint origin, {
  required double forwardMeters,
  required double rightMeters,
  required double headingDegrees,
}) {
  final distance = math.sqrt(
    forwardMeters * forwardMeters + rightMeters * rightMeters,
  );
  final angle = math.atan2(rightMeters, forwardMeters) * 180 / math.pi;
  return _destination(origin, headingDegrees + angle, distance);
}

GeoPoint _destination(
  GeoPoint origin,
  double bearingDegrees,
  double distanceMeters,
) {
  const earthRadiusMeters = 6_371_008.8;
  final angularDistance = distanceMeters / earthRadiusMeters;
  final bearing = bearingDegrees * math.pi / 180;
  final latitude = origin.latitude * math.pi / 180;
  final longitude = origin.longitude * math.pi / 180;
  final targetLatitude = math.asin(
    math.sin(latitude) * math.cos(angularDistance) +
        math.cos(latitude) * math.sin(angularDistance) * math.cos(bearing),
  );
  final targetLongitude =
      longitude +
      math.atan2(
        math.sin(bearing) * math.sin(angularDistance) * math.cos(latitude),
        math.cos(angularDistance) -
            math.sin(latitude) * math.sin(targetLatitude),
      );
  return GeoPoint(
    latitude: targetLatitude * 180 / math.pi,
    longitude: ((targetLongitude * 180 / math.pi + 540) % 360) - 180,
  );
}

double dayRideDistanceMeters(
  RideDayLength length, {
  double movingSpeedKilometresPerHour = 55,
}) {
  final duration = length.duration;
  if (duration == null) {
    throw const FormatException('A custom ride needs an explicit distance.');
  }
  return movingSpeedKilometresPerHour * duration.inMinutes / 60 * 1000;
}
