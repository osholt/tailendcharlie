import '../domain/imported_route.dart';
import '../domain/ride_plan.dart';
import 'route_progress.dart';

/// How near the route a rider must be, before any progress along it, to be
/// riding it rather than still on the way to its start. The same distance
/// decides when "Navigate to start" is offered (#262).
const remainingPlanOnRouteMeters = 250.0;

/// The plan to edit for a route that is being ridden (#893).
///
/// Editing a route under way used to re-plan the whole of it: back to the
/// meeting point, through the café the group left an hour ago. Google Maps
/// re-plans from where you are, and so does this. The plan starts from the
/// rider's location, keeps only the stops and drawn adjustments still ahead,
/// and so the revision it becomes no longer carries the part already ridden.
///
/// [progressMeters] is the rider's progress along [route], as the navigation
/// progress tracker measures it, so a loop's finish is not mistaken for its
/// start. Stops and adjustments are placed on the same line in route order,
/// and whatever lies at or behind that progress is behind the rider.
///
/// A rider who has made no progress and is not near the route is still on the
/// way to its start, and the plan keeps its start: the group meets there.
RidePlan remainingRidePlan(
  ImportedRoute route, {
  required double progressMeters,
  required GeoPoint position,
}) {
  final plan = RidePlan.fromRoute(route);
  final destination = plan.destination;
  if (destination == null) return plan;
  if (progressMeters <= 0 &&
      distanceToRouteMeters(route, position) > remainingPlanOnRouteMeters) {
    return plan;
  }

  // Every control in the order the route visits it: each leg's adjustments,
  // then the stop that ends the leg. The start and the destination bracket
  // them so the projection measures a loop the way the tracker does.
  final origin =
      plan
          .resolvedStart(currentLocation: route.waypoints.firstOrNull?.point)
          ?.point ??
      route.allPoints.firstOrNull ??
      destination.point;
  final points = <GeoPoint>[origin];
  final owners = <Object?>[null];
  for (var leg = 0; leg < plan.legCount; leg += 1) {
    for (final point in plan.shapingPoints) {
      if (point.legIndex != leg) continue;
      points.add(point.point);
      owners.add(point.id);
    }
    if (leg < plan.stops.length) {
      points.add(plan.stops[leg].point);
      owners.add(leg);
    }
  }
  points.add(destination.point);
  owners.add(null);

  final progress = routeWaypointProgressMeters(
    ImportedRoute(
      id: route.id,
      name: route.name,
      importedAt: route.importedAt,
      sourceFileName: route.sourceFileName,
      paths: route.paths,
      waypoints: [for (final point in points) RouteWaypoint(point: point)],
    ),
  );
  var passedStops = 0;
  final passedShaping = <String>{};
  if (progress.length == points.length) {
    for (var index = 1; index < points.length - 1; index += 1) {
      if (progress[index] > progressMeters) break;
      switch (owners[index]) {
        case final int stop:
          passedStops = stop + 1;
        case final String shaping:
          passedShaping.add(shaping);
      }
    }
  }
  return plan.remainingFromCurrentLocation(
    passedStops: passedStops,
    passedShapingPointIds: passedShaping,
  );
}
