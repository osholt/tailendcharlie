import 'dart:math' as math;

import '../domain/imported_route.dart';
import '../domain/recorded_route_store.dart';
import 'road_routing.dart';

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
  });

  final ImportedRoute route;
  final CircularRideRequest request;
  final double requestedDistanceMeters;
  final double actualDistanceMeters;
  final Duration duration;
  final double? twistinessScore;
}

/// Generates a road-routed loop from three non-stopping shaping controls.
///
/// The controls form a broad diamond in the requested compass direction. A
/// variant changes its handedness and angle, so “another route” makes a
/// materially different request rather than asking the router the same thing.
class CircularRidePlanner {
  const CircularRidePlanner({required this.routingService});

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

    var shapingDistance = request.distanceMeters;
    late List<GeoPoint> controls;
    late RoadRouteResult result;
    for (var attempt = 0; attempt < 3; attempt += 1) {
      controls = circularRideShapingPoints(
        request,
        shapingDistanceMeters: shapingDistance,
      );
      final orderedControls = <({double fraction, GeoPoint point})>[
        for (final (index, point) in controls.indexed)
          (fraction: (index + 1) / 4, point: point),
        for (final stop in request.plannedStops)
          (fraction: stop.fraction, point: stop.waypoint.point),
      ]..sort((first, second) => first.fraction.compareTo(second.fraction));
      try {
        result = await routingService.routeThrough([
          request.start,
          ...orderedControls.map((control) => control.point),
          request.start,
        ], preferences: request.preferences);
      } on RoadRoutingException catch (error) {
        if (!error.routeNotFound) rethrow;
        throw FormatException(_circularRideNoRouteMessage(request));
      }
      _validateClosedRoute(request.start, result);
      if (_hasUTurn(result)) {
        throw const FormatException(
          'That loop contains a U-turn. Generate another route or move a shaping point.',
        );
      }
      if (circularRideDistanceWithinTolerance(
        requestedMeters: request.distanceMeters,
        actualMeters: result.distanceMeters,
      )) {
        break;
      }
      if (attempt == 2) {
        throw const FormatException(
          'The road network could not make a loop close enough to that distance. Generate another route or adjust the distance.',
        );
      }
      shapingDistance =
          (shapingDistance * request.distanceMeters / result.distanceMeters)
              .clamp(request.distanceMeters * 0.4, request.distanceMeters * 1.8)
              .toDouble();
    }
    final now = DateTime.now().toUtc();
    final route = ImportedRoute(
      id: 'circular-${now.microsecondsSinceEpoch}-${request.variant}',
      name: _routeName(request),
      description: _description(request),
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
        RouteWaypoint(point: request.start, name: 'Start and finish'),
        ...request.plannedStops.map((stop) => stop.waypoint),
        RouteWaypoint(point: request.start, name: 'Finish'),
      ],
      shapingPoints: [
        for (final (index, point) in controls.indexed)
          RouteShapingPoint(
            id: 'loop-${request.variant}-$index',
            point: point,
            legIndex: request.plannedStops
                .where((stop) => stop.fraction < (index + 1) / 4)
                .length,
          ),
      ],
      maneuvers: result.maneuvers,
      preferences: request.preferences,
      plannedDuration: result.duration,
    );
    return CircularRidePlan(
      route: route,
      request: request,
      requestedDistanceMeters: request.distanceMeters,
      actualDistanceMeters: result.distanceMeters,
      duration: result.duration,
      twistinessScore: result.twistinessScore,
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

  static String _description(CircularRideRequest request) {
    return 'Generated ${request.direction.label} circular ride; '
        '${request.preferences.summary} Fuel every ${request.fuelEvery.inMinutes} min, '
        'comfort every ${request.comfortEvery.inMinutes} min, meal after '
        '${request.mealAfter.inMinutes} min. '
        '${request.heatmapPreference == CircularRideHeatmapPreference.none ? 'No heatmap preference.' : 'Soft preference: ${request.heatmapPreference.label.toLowerCase()}.'}';
  }
}

String _circularRideNoRouteMessage(CircularRideRequest request) {
  const lead = 'No circular route could be found with those settings.';
  if (request.preferences.avoidMotorways) {
    return '$lead Try turning off Avoid motorways, choosing another direction, '
        'or reducing the distance.';
  }
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

void _validateClosedRoute(GeoPoint start, RoadRouteResult result) {
  if (result.points.length < 2 ||
      _distanceMetres(start, result.points.first) >
          circularRideClosureToleranceMeters ||
      _distanceMetres(start, result.points.last) >
          circularRideClosureToleranceMeters) {
    throw const FormatException(
      'The router did not return a closed loop. Generate another route.',
    );
  }
}

bool _hasUTurn(RoadRouteResult result) => result.maneuvers.any((maneuver) {
  final modifier = maneuver.modifier?.trim().toLowerCase().replaceAll('-', ' ');
  return modifier == 'uturn' || modifier == 'u turn';
});

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
