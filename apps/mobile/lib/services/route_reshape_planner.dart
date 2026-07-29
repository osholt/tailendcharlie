import '../domain/imported_route.dart';
import 'road_routing.dart';
import 'route_marker_plan.dart';

class RouteReshapeResult {
  const RouteReshapeResult({
    required this.route,
    required this.distanceMeters,
    required this.duration,
    this.twistinessScore,
  });

  final ImportedRoute route;
  final double distanceMeters;
  final Duration duration;
  final double? twistinessScore;
}

/// Recalculates a route through non-stopping shaping controls.
///
/// The caller owns confirmation. This class only returns an immutable preview;
/// it never writes the active route or publishes a group route event (#242).
class RouteReshapePlanner {
  const RouteReshapePlanner({required this.routingService});

  final RoadRoutingService routingService;

  Future<RouteReshapeResult> reshape(
    ImportedRoute route,
    List<RouteShapingPoint> shapingPoints,
  ) async {
    final controls = routeShapingControls(route, shapingPoints);
    if (controls.length < 2) {
      throw const FormatException(
        'This route needs a start and destination before it can be reshaped.',
      );
    }
    final result = await routingService.routeThrough(
      controls,
      preferences: route.preferences,
    );
    final primary = RouteMarkerPlanAnalyzer.primaryRiddenPath(route);
    final primaryPath = route.paths
        .where((path) => identical(path.points, primary))
        .firstOrNull;
    final reshaped = ImportedRoute(
      id: route.id,
      name: route.name,
      description: route.description,
      importedAt: route.importedAt,
      sourceFileName: route.sourceFileName,
      paths: [
        RoutePath(
          kind: primaryPath?.kind ?? RoutePathKind.track,
          name: primaryPath?.name,
          points: result.points,
        ),
      ],
      waypoints: route.waypoints,
      shapingPoints: List.unmodifiable(shapingPoints),
      maneuvers: result.maneuvers,
      markerReview: route.markerReview,
      preferences: route.preferences,
    );
    return RouteReshapeResult(
      route: reshaped,
      distanceMeters: result.distanceMeters,
      duration: result.duration,
      twistinessScore: result.twistinessScore,
    );
  }
}

List<GeoPoint> routeShapingControls(
  ImportedRoute route,
  List<RouteShapingPoint> shapingPoints,
) {
  final anchors = route.waypoints.length >= 2
      ? route.waypoints
            .map((waypoint) => waypoint.point)
            .toList(growable: false)
      : switch (RouteMarkerPlanAnalyzer.primaryRiddenPath(route)) {
          final points when points.length >= 2 => [points.first, points.last],
          _ => const <GeoPoint>[],
        };
  if (anchors.length < 2) return anchors;
  final controls = <GeoPoint>[];
  for (var legIndex = 0; legIndex < anchors.length - 1; legIndex += 1) {
    controls.add(anchors[legIndex]);
    controls.addAll(
      shapingPoints
          .where((point) => point.legIndex == legIndex)
          .map((point) => point.point),
    );
  }
  controls.add(anchors.last);
  return List.unmodifiable(controls);
}

/// Adds [point] to the correct named-stop leg and keeps controls on that leg in
/// route order. A route line can therefore be dragged without promoting the
/// new control to a named stop.
List<RouteShapingPoint> insertRouteShapingPoint(
  ImportedRoute route,
  List<RouteShapingPoint> existing,
  GeoPoint point, {
  required String id,
}) {
  final geometry = RouteMarkerPlanAnalyzer.primaryRiddenPath(route);
  final legIndex = routeLegIndexForPoint(route, point);
  final pointProgress = _nearestRouteProgress(geometry, point);
  var insertion = existing.length;
  for (var index = 0; index < existing.length; index += 1) {
    final current = existing[index];
    if (current.legIndex > legIndex ||
        (current.legIndex == legIndex &&
            _nearestRouteProgress(geometry, current.point) > pointProgress)) {
      insertion = index;
      break;
    }
  }
  final updated = [...existing]
    ..insert(
      insertion,
      RouteShapingPoint(id: id, point: point, legIndex: legIndex),
    );
  return List.unmodifiable(updated);
}

int routeLegIndexForPoint(ImportedRoute route, GeoPoint point) {
  final geometry = RouteMarkerPlanAnalyzer.primaryRiddenPath(route);
  final anchorPoints = route.waypoints.length >= 2
      ? route.waypoints
            .map((waypoint) => waypoint.point)
            .toList(growable: false)
      : switch (geometry) {
          final points when points.length >= 2 => [points.first, points.last],
          _ => const <GeoPoint>[],
        };
  if (geometry.length < 2 || anchorPoints.length < 2) return 0;
  final boundaries = <int>[0];
  var searchStart = 0;
  for (var index = 1; index < anchorPoints.length - 1; index += 1) {
    final boundary = _nearestPointIndex(
      geometry,
      anchorPoints[index],
      startIndex: searchStart,
    );
    boundaries.add(boundary);
    searchStart = boundary;
  }
  boundaries.add(geometry.length - 1);
  final progress = _nearestRouteProgress(geometry, point);
  for (var legIndex = 0; legIndex < boundaries.length - 1; legIndex += 1) {
    if (progress <= boundaries[legIndex + 1]) return legIndex;
  }
  return boundaries.length - 2;
}

double _nearestRouteProgress(List<GeoPoint> geometry, GeoPoint point) {
  if (geometry.length < 2) return 0;
  var nearestProgress = 0.0;
  var nearestDistance = double.infinity;
  for (var index = 1; index < geometry.length; index += 1) {
    final start = geometry[index - 1];
    final end = geometry[index];
    final latitudeDelta = end.latitude - start.latitude;
    final longitudeDelta = end.longitude - start.longitude;
    final lengthSquared =
        latitudeDelta * latitudeDelta + longitudeDelta * longitudeDelta;
    final position = lengthSquared == 0
        ? 0.0
        : (((point.latitude - start.latitude) * latitudeDelta +
                      (point.longitude - start.longitude) * longitudeDelta) /
                  lengthSquared)
              .clamp(0.0, 1.0);
    final projectedLatitude = start.latitude + position * latitudeDelta;
    final projectedLongitude = start.longitude + position * longitudeDelta;
    final projectedLatitudeDelta = point.latitude - projectedLatitude;
    final projectedLongitudeDelta = point.longitude - projectedLongitude;
    final distance =
        projectedLatitudeDelta * projectedLatitudeDelta +
        projectedLongitudeDelta * projectedLongitudeDelta;
    if (distance < nearestDistance) {
      nearestDistance = distance;
      nearestProgress = index - 1 + position;
    }
  }
  return nearestProgress;
}

int _nearestPointIndex(
  List<GeoPoint> geometry,
  GeoPoint point, {
  int startIndex = 0,
}) {
  if (geometry.isEmpty) return 0;
  var nearestIndex = startIndex.clamp(0, geometry.length - 1);
  var nearestDistance = double.infinity;
  for (var index = nearestIndex; index < geometry.length; index += 1) {
    final candidate = geometry[index];
    final latitudeDelta = candidate.latitude - point.latitude;
    final longitudeDelta = candidate.longitude - point.longitude;
    final distance =
        latitudeDelta * latitudeDelta + longitudeDelta * longitudeDelta;
    if (distance < nearestDistance) {
      nearestDistance = distance;
      nearestIndex = index;
    }
  }
  return nearestIndex;
}
