import 'dart:math' as math;

import '../domain/geo_point.dart';
import '../domain/marker_assistance.dart';
import 'geo_calculations.dart';

class ExplicitDecisionPoint {
  const ExplicitDecisionPoint({required this.position, this.label});

  final GeoPoint position;
  final String? label;
}

class RouteDecisionPointConfig {
  const RouteDecisionPointConfig({
    this.minimumTurnDegrees = 35,
    this.maximumTurnDegrees = 150,
    this.minimumSpacingMeters = 80,
    this.rejectionRadiusMeters = 30,
  });

  final double minimumTurnDegrees;

  /// Above this the route has reversed on itself rather than turned: the group
  /// is coming back out of a no-through road, and there is no branch anyone
  /// could take by mistake. Marking it sends a rider to a dead end (#179).
  final double maximumTurnDegrees;

  final double minimumSpacingMeters;

  /// How close a candidate must be to a rejected position to count as the same
  /// place. Identifiers cannot be matched across a reroute, positions can.
  final double rejectionRadiusMeters;
}

class RouteDecisionPointExtractor {
  const RouteDecisionPointExtractor({
    this.config = const RouteDecisionPointConfig(),
  });

  final RouteDecisionPointConfig config;

  /// [rejectedPositions] and [addedPositions] carry a route's marker review into
  /// the live detector, so a suggestion rejected on the planner or at the
  /// roadside does not come back on the next stop, and a junction the detector
  /// missed can still raise one.
  List<RouteDecisionPoint> extract({
    required List<GeoPoint> route,
    List<ExplicitDecisionPoint> explicitPoints = const [],
    List<GeoPoint> rejectedPositions = const [],
    List<ExplicitDecisionPoint> addedPositions = const [],
  }) {
    final result = <RouteDecisionPoint>[];
    bool rejected(GeoPoint point) => rejectedPositions.any(
      (position) =>
          GeoCalculations.distanceMeters(position, point) <=
          config.rejectionRadiusMeters,
    );

    for (var index = 0; index < addedPositions.length; index += 1) {
      final point = addedPositions[index];
      result.add(
        RouteDecisionPoint(
          id: 'added-$index',
          position: point.position,
          source: DecisionPointSource.waypoint,
          label: point.label,
        ),
      );
    }

    for (var index = 0; index < explicitPoints.length; index += 1) {
      final point = explicitPoints[index];
      if (rejected(point.position)) continue;
      result.add(
        RouteDecisionPoint(
          id: 'waypoint-$index',
          position: point.position,
          source: DecisionPointSource.waypoint,
          label: point.label,
        ),
      );
    }

    for (var index = 1; index < route.length - 1; index += 1) {
      final point = route[index];
      final inbound = _bearing(route[index - 1], point);
      final outbound = _bearing(point, route[index + 1]);
      final turn = _smallestAngle(inbound, outbound);
      if (turn < config.minimumTurnDegrees ||
          turn >= config.maximumTurnDegrees ||
          rejected(point) ||
          result.any(
            (existing) =>
                GeoCalculations.distanceMeters(existing.position, point) <
                config.minimumSpacingMeters,
          )) {
        continue;
      }
      result.add(
        RouteDecisionPoint(
          id: 'turn-$index',
          position: point,
          source: DecisionPointSource.routeGeometry,
          label: '${turn.round()}° route turn',
        ),
      );
    }
    return List.unmodifiable(result);
  }

  static double _bearing(GeoPoint from, GeoPoint to) {
    final latitude1 = _radians(from.latitude);
    final latitude2 = _radians(to.latitude);
    final longitudeDelta = _radians(to.longitude - from.longitude);
    final y = math.sin(longitudeDelta) * math.cos(latitude2);
    final x =
        math.cos(latitude1) * math.sin(latitude2) -
        math.sin(latitude1) * math.cos(latitude2) * math.cos(longitudeDelta);
    return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
  }

  static double _smallestAngle(double first, double second) {
    final difference = (second - first).abs() % 360;
    return difference > 180 ? 360 - difference : difference;
  }

  static double _radians(double degrees) => degrees * math.pi / 180;
}
