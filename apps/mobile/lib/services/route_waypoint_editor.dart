import '../domain/imported_route.dart';
import 'route_marker_plan.dart';
import 'route_reshape_planner.dart';

/// Inserts a deliberate stop on the leg nearest [waypoint].
///
/// Shaping controls are re-indexed around the new stop so adding a café or
/// meeting point does not discard route adjustments the rider already made.
ImportedRoute insertRouteWaypoint(ImportedRoute route, RouteWaypoint waypoint) {
  final waypoints = _editableWaypoints(route);
  if (waypoints.length < 2) {
    throw const FormatException(
      'A route needs a start and destination before a waypoint can be added.',
    );
  }
  final legIndex = routeLegIndexForPoint(route, waypoint.point);
  final insertionIndex = (legIndex + 1).clamp(1, waypoints.length - 1);
  final waypointProgress = routeProgressForPoint(route, waypoint.point);
  final shapingPoints = [
    for (final shapingPoint in route.shapingPoints)
      RouteShapingPoint(
        id: shapingPoint.id,
        point: shapingPoint.point,
        legIndex: shapingPoint.legIndex < legIndex
            ? shapingPoint.legIndex
            : shapingPoint.legIndex > legIndex
            ? shapingPoint.legIndex + 1
            : routeProgressForPoint(route, shapingPoint.point) <=
                  waypointProgress
            ? legIndex
            : legIndex + 1,
      ),
  ];
  final updatedWaypoints = [...waypoints]..insert(insertionIndex, waypoint);
  return _withWaypoints(route, updatedWaypoints, shapingPoints);
}

/// Removes an intermediate stop and merges the two surrounding route legs.
ImportedRoute removeRouteWaypoint(ImportedRoute route, int index) {
  if (index <= 0 || index >= route.waypoints.length - 1) {
    throw const FormatException(
      'The route start and destination cannot be removed.',
    );
  }
  final removedLeg = index - 1;
  final waypoints = [...route.waypoints]..removeAt(index);
  final shapingPoints = [
    for (final shapingPoint in route.shapingPoints)
      RouteShapingPoint(
        id: shapingPoint.id,
        point: shapingPoint.point,
        legIndex: shapingPoint.legIndex <= removedLeg
            ? shapingPoint.legIndex
            : shapingPoint.legIndex - 1,
      ),
  ];
  return _withWaypoints(route, waypoints, shapingPoints);
}

ImportedRoute _withWaypoints(
  ImportedRoute route,
  List<RouteWaypoint> waypoints,
  List<RouteShapingPoint> shapingPoints,
) => ImportedRoute(
  id: route.id,
  name: route.name,
  description: route.description,
  importedAt: route.importedAt,
  sourceFileName: route.sourceFileName,
  paths: route.paths,
  waypoints: List.unmodifiable(waypoints),
  shapingPoints: List.unmodifiable(shapingPoints),
  // These describe the old route. The live recalculation replaces them before
  // the candidate can be confirmed.
  maneuvers: const [],
  markerReview: route.markerReview,
  preferences: route.preferences,
);

List<RouteWaypoint> _editableWaypoints(ImportedRoute route) {
  if (route.waypoints.length >= 2) return route.waypoints;
  final geometry = RouteMarkerPlanAnalyzer.primaryRiddenPath(route);
  if (geometry.length < 2) return route.waypoints;
  return [
    RouteWaypoint(point: geometry.first, name: 'Start', symbol: 'Flag, Blue'),
    RouteWaypoint(
      point: geometry.last,
      name: 'Destination',
      symbol: 'Flag, Red',
    ),
  ];
}

/// Progress along the primary ridden geometry, used to keep edits ordered.
double routeProgressForPoint(ImportedRoute route, GeoPoint point) {
  final geometry = RouteMarkerPlanAnalyzer.primaryRiddenPath(route);
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
    final latitudeError = point.latitude - projectedLatitude;
    final longitudeError = point.longitude - projectedLongitude;
    final distance =
        latitudeError * latitudeError + longitudeError * longitudeError;
    if (distance < nearestDistance) {
      nearestDistance = distance;
      nearestProgress = index - 1 + position;
    }
  }
  return nearestProgress;
}
