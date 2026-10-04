import '../domain/imported_route.dart';
import 'road_routing.dart';
import 'route_reshape_planner.dart';
import 'route_verification.dart';

class RouteGeometryEnrichment {
  const RouteGeometryEnrichment({
    required this.route,
    required this.attempted,
    required this.snappedPathCount,
    this.warning,
    this.verification,
  });

  final ImportedRoute route;
  final bool attempted;
  final int snappedPathCount;
  final String? warning;

  /// What checking the re-snapped geometry against the route's preferences
  /// found, or null when nothing was re-snapped or the routing service does not
  /// check its routes (#840).
  final RouteVerification? verification;

  bool get changed => snappedPathCount > 0;
}

class RouteGeometryEnricher {
  const RouteGeometryEnricher({
    required this.routingService,
    this.maximumViaPoints = 50,
  });

  final RoadRoutingService routingService;
  final int maximumViaPoints;

  Future<RouteGeometryEnrichment> enrich(ImportedRoute route) async {
    final paths = <RoutePath>[];
    final maneuvers = <RouteManeuver>[...route.maneuvers];
    var attempted = false;
    var snapped = 0;
    String? warning;
    final verifications = <RouteVerification>[];

    for (final path in route.paths) {
      if (path.kind != RoutePathKind.route || path.points.length < 2) {
        paths.add(path);
        continue;
      }
      attempted = true;
      try {
        // Only the route's stops end a leg. Every other point of a GPX route -
        // a shaping point, a plain route point, a Garmin shape vertex - bends
        // the line and is passed through, so it is never arrived at (#839).
        final controls = _routeControls(
          path.points,
          route.waypoints,
          maximumViaPoints,
        );
        final result = await routeThroughWithShaping(
          routingService,
          controls.points,
          shapingPointIndexes: controls.shapingPointIndexes,
          // A route that recorded what it was planned for is re-snapped for the
          // same thing, so a shared route does not quietly gain a motorway when
          // it reaches a second rider's phone (#182).
          preferences: route.preferences,
        );
        paths.add(
          RoutePath(
            kind: RoutePathKind.track,
            name: path.name,
            points: result.points,
          ),
        );
        maneuvers.addAll(result.maneuvers);
        snapped += 1;
        if (result.verification case final verification?) {
          verifications.add(verification);
        }
      } on Object catch (error) {
        paths.add(path);
        warning ??= 'Could not match every GPX route point to roads: $error';
      }
    }

    if (route.paths.isEmpty && route.waypoints.length >= 2) {
      attempted = true;
      try {
        final controls = routeShapingControlPlan(route, route.shapingPoints);
        final result = await routeThroughWithShaping(
          routingService,
          controls.points.length <= maximumViaPoints
              ? controls.points
              : _sample(controls.points, maximumViaPoints),
          shapingPointIndexes: controls.points.length <= maximumViaPoints
              ? controls.shapingPointIndexes
              : const {},
          preferences: route.preferences,
        );
        paths.add(
          RoutePath(
            kind: RoutePathKind.track,
            name: route.name,
            points: result.points,
          ),
        );
        maneuvers.addAll(result.maneuvers);
        snapped += 1;
        if (result.verification case final verification?) {
          verifications.add(verification);
        }
      } on Object catch (error) {
        warning = 'Could not match GPX waypoints to roads: $error';
      }
    }

    if (snapped == 0) {
      return RouteGeometryEnrichment(
        route: route,
        attempted: attempted,
        snappedPathCount: 0,
        warning: warning,
      );
    }
    return RouteGeometryEnrichment(
      route: ImportedRoute(
        id: route.id,
        sourceRouteId: route.sourceRouteId ?? route.id,
        organisation: route.organisation,
        derivedFromRouteId: route.derivedFromRouteId,
        name: route.name,
        description: route.description,
        importedAt: route.importedAt,
        sourceFileName: route.sourceFileName,
        paths: List.unmodifiable(paths),
        waypoints: route.waypoints,
        shapingPoints: route.shapingPoints,
        maneuvers: List.unmodifiable(maneuvers),
        // Recalculating geometry must not silently un-reject a marking
        // position a person already rejected for this route (#179).
        markerReview: route.markerReview,
        preferences: route.preferences,
        plannedDuration: route.plannedDuration,
      ),
      attempted: attempted,
      snappedPathCount: snapped,
      warning: warning,
      verification: RouteVerification.merge(verifications),
    );
  }
}

List<GeoPoint> _sample(List<GeoPoint> points, int maximum) {
  if (maximum < 2) {
    throw ArgumentError.value(maximum, 'maximum', 'Must be at least two.');
  }
  if (points.length <= maximum) return List.unmodifiable(points);
  return List.generate(maximum, (index) {
    final sourceIndex = (index * (points.length - 1) / (maximum - 1)).round();
    return points[sourceIndex];
  }, growable: false);
}

/// The points to route a GPX route path through, and which of them are only
/// shaping it (#839).
///
/// A point is a stop where one of the route's stop waypoints sits on it - a
/// `<trp:ViaPoint>` or a waypoint placed on the route - and the path's own ends
/// are always stops. Every stop is kept; the rest of [maximum] samples the line
/// between them evenly.
({List<GeoPoint> points, Set<int> shapingPointIndexes}) _routeControls(
  List<GeoPoint> points,
  List<RouteWaypoint> stops,
  int maximum,
) {
  if (maximum < 2) {
    throw ArgumentError.value(maximum, 'maximum', 'Must be at least two.');
  }
  final last = points.length - 1;
  final stopIndexes = <int>{
    0,
    last,
    for (var index = 1; index < last; index += 1)
      if (stops.any((stop) => _samePoint(stop.point, points[index]))) index,
  };
  final kept = <int>{};
  if (stopIndexes.length >= maximum) {
    final ordered = stopIndexes.toList()..sort();
    kept.addAll(_evenly(ordered, maximum));
  } else {
    kept.addAll(stopIndexes);
    final others = [
      for (var index = 0; index <= last; index += 1)
        if (!stopIndexes.contains(index)) index,
    ];
    kept.addAll(_evenly(others, maximum - stopIndexes.length));
  }
  final chosen = kept.toList()..sort();
  return (
    points: List.unmodifiable([for (final index in chosen) points[index]]),
    shapingPointIndexes: Set.unmodifiable({
      for (final (position, index) in chosen.indexed)
        if (!stopIndexes.contains(index)) position,
    }),
  );
}

/// [count] of [items], spread evenly and keeping both ends where it can.
Iterable<int> _evenly(List<int> items, int count) {
  if (count <= 0 || items.isEmpty) return const [];
  if (items.length <= count) return items;
  if (count == 1) return [items.first];
  return {
    for (var index = 0; index < count; index += 1)
      items[(index * (items.length - 1) / (count - 1)).round()],
  };
}

bool _samePoint(GeoPoint first, GeoPoint second) =>
    (first.latitude - second.latitude).abs() < 0.000001 &&
    (first.longitude - second.longitude).abs() < 0.000001;
