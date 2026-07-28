import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/services/route_marker_plan.dart';

void main() {
  const analyzer = RouteMarkerPlanAnalyzer();

  test('applies default marker rules and separates unsafe junctions', () {
    final plan = analyzer.analyze(
      _route(
        maneuvers: const [
          RouteManeuver(
            position: GeoPoint(latitude: 51, longitude: -2),
            type: 'turn',
            modifier: 'straight',
          ),
          RouteManeuver(
            position: GeoPoint(latitude: 51.1, longitude: -2.1),
            type: 'turn',
            modifier: 'left',
          ),
          RouteManeuver(
            position: GeoPoint(latitude: 51.2, longitude: -2.2),
            type: 'roundabout',
            modifier: 'right',
            exitNumber: 3,
          ),
          RouteManeuver(
            position: GeoPoint(latitude: 51.3, longitude: -2.3),
            type: 'off ramp',
            modifier: 'left',
          ),
        ],
      ),
    );

    expect(plan.likelyMarkers, hasLength(2));
    expect(
      plan.likelyMarkers.map((point) => point.label),
      containsAll(['Turn left marker', 'Roundabout exit 3 marker']),
    );
    expect(plan.safetyReviews.single.label, contains('exit review'));
  });

  test('flags multi-lane roundabouts for leader safety review', () {
    final plan = analyzer.analyze(
      _route(
        maneuvers: const [
          RouteManeuver(
            position: GeoPoint(latitude: 51.2, longitude: -2.2),
            type: 'roundabout',
            modifier: 'right',
            lanes: [
              RouteLane(indications: ['left'], valid: false),
              RouteLane(indications: ['straight'], valid: false),
              RouteLane(indications: ['right'], valid: true),
            ],
          ),
        ],
      ),
    );

    expect(plan.likelyMarkers, isEmpty);
    expect(plan.safetyReviews.single.detail, contains('multi-lane'));
  });

  test('recognises an explicit muster waypoint', () {
    final plan = analyzer.analyze(
      _route(
        waypoints: const [
          RouteWaypoint(
            point: GeoPoint(latitude: 51.15, longitude: -2.15),
            name: 'Village muster point',
          ),
        ],
      ),
    );

    expect(plan.musterPoints.single.label, 'Village muster point');
  });

  group('a cul-de-sac the route does not enter', () {
    test('earns no suggestion at its mouth', () {
      final plan = analyzer.analyze(_culDeSacRoute());

      expect(
        plan.points.map((point) => point.label),
        ['Turn left marker'],
        reason:
            'The group turns left at the far junction and rides straight past '
            'the cul-de-sac mouth. A road nobody takes cannot be missed.',
      );
      expect(
        plan.points.every(
          (point) =>
              _metresApart(point.position, _culDeSacMouth) >
              _culDeSacMouthTolerance,
        ),
        isTrue,
      );
    });

    test('earns no suggestion inside it when the route does dip in', () {
      // A via point snapped into the no-through road, so the calculated line
      // really does go in and come back out. The reversal is what disqualifies
      // it: a marker left there is a rider sent to a dead end (#179).
      final plan = analyzer.analyze(
        _straightRoute(
          maneuvers: const [
            RouteManeuver(
              position: GeoPoint(latitude: 51.5015, longitude: -2.5),
              type: 'turn',
              modifier: 'uturn',
              bearingBeforeDegrees: 0,
              bearingAfterDegrees: 180,
            ),
          ],
        ),
      );

      expect(plan.points, isEmpty);
    });
  });

  test('a junction the route rides straight through earns no suggestion', () {
    final plan = analyzer.analyze(
      _straightRoute(
        maneuvers: const [
          RouteManeuver(
            position: GeoPoint(latitude: 51.501, longitude: -2.5),
            type: 'turn',
            modifier: 'right',
            // The engine names a right turn; the ridden line carries straight
            // on. Scoring the manoeuvre alone is what produced spurious dots.
            bearingBeforeDegrees: 0,
            bearingAfterDegrees: 2,
          ),
        ],
      ),
    );

    expect(plan.points, isEmpty);
  });

  test('a shallow fork is still suggested despite the small bend', () {
    final plan = analyzer.analyze(
      _straightRoute(
        maneuvers: const [
          RouteManeuver(
            position: GeoPoint(latitude: 51.501, longitude: -2.5),
            type: 'fork',
            modifier: 'slight left',
            bearingBeforeDegrees: 0,
            bearingAfterDegrees: 8,
          ),
        ],
      ),
    );

    expect(plan.likelyMarkers.single.label, 'Keep slight left marker');
  });

  test('a manoeuvre on a path the group will not ride is dropped', () {
    final plan = analyzer.analyze(
      ImportedRoute(
        id: 'two-paths',
        name: 'Two paths',
        importedAt: DateTime.utc(2026, 7, 27),
        sourceFileName: 'two-paths.gpx',
        paths: const [
          RoutePath(
            kind: RoutePathKind.track,
            points: [
              GeoPoint(latitude: 51.5, longitude: -2.5),
              GeoPoint(latitude: 51.51, longitude: -2.5),
              GeoPoint(latitude: 51.52, longitude: -2.5),
            ],
          ),
          RoutePath(
            kind: RoutePathKind.track,
            points: [
              GeoPoint(latitude: 52.5, longitude: -3.5),
              GeoPoint(latitude: 52.501, longitude: -3.5),
            ],
          ),
        ],
        waypoints: const [],
        maneuvers: const [
          RouteManeuver(
            position: GeoPoint(latitude: 52.5005, longitude: -3.5),
            type: 'turn',
            modifier: 'left',
            bearingBeforeDegrees: 0,
            bearingAfterDegrees: 270,
          ),
        ],
      ),
    );

    expect(plan.points, isEmpty);
  });

  group('review', () {
    test('a rejection is applied and offered back for restoring', () {
      final route = _culDeSacRoute();
      final suggested = analyzer.analyze(route).points.single;

      final reviewed = analyzer.analyze(
        route.withMarkerReview(
          MarkerPlanReview(rejected: [suggested.toReviewPoint()]),
        ),
      );

      expect(reviewed.points, isEmpty);
      expect(reviewed.rejectedPoints.single.label, suggested.label);
    });

    test('a rejection survives the manoeuvre being renumbered', () {
      final route = _culDeSacRoute();
      final suggested = analyzer.analyze(route).points.single;
      final rejected = MarkerPlanReview(
        rejected: [
          MarkerReviewPoint(
            // A reroute renumbered the manoeuvre, so only the position matches.
            id: 'maneuver-99',
            position: suggested.position,
            label: suggested.label,
          ),
        ],
      );

      expect(
        analyzer.analyze(route.withMarkerReview(rejected)).points,
        isEmpty,
      );
    });

    test('a manually added junction is suggested even though the gates lost '
        'it', () {
      final route = _straightRoute(
        maneuvers: const [
          RouteManeuver(
            position: GeoPoint(latitude: 51.501, longitude: -2.5),
            type: 'turn',
            modifier: 'right',
            bearingBeforeDegrees: 0,
            bearingAfterDegrees: 2,
          ),
        ],
      );
      expect(analyzer.analyze(route).points, isEmpty);

      final candidates = analyzer.candidates(route);
      expect(candidates, isNotEmpty);

      final reviewed = analyzer.analyze(
        route.withMarkerReview(
          MarkerPlanReview(added: [candidates.first.toReviewPoint()]),
        ),
      );

      expect(reviewed.points.single.source, MarkerPlanPointSource.manual);
      expect(reviewed.points.single.detail, contains('detector missed it'));
    });

    test('candidates do not repeat a position already in the plan', () {
      final route = _culDeSacRoute();
      final suggested = analyzer.analyze(route).points.single;

      expect(
        analyzer
            .candidates(route)
            .every(
              (candidate) =>
                  _metresApart(candidate.position, suggested.position) > 30,
            ),
        isTrue,
      );
    });

    test('the review round-trips through the persisted route', () {
      final route = _culDeSacRoute().withMarkerReview(
        const MarkerPlanReview(
          rejected: [
            MarkerReviewPoint(
              id: 'maneuver-0',
              position: GeoPoint(latitude: 51.5, longitude: -2.5),
              label: 'Junction marker',
            ),
          ],
          added: [
            MarkerReviewPoint(
              id: 'geometry-4',
              position: GeoPoint(latitude: 51.503, longitude: -2.5),
            ),
          ],
        ),
      );

      final restored = ImportedRoute.fromJsonString(route.toJsonString());

      expect(restored.markerReview.rejected.single.id, 'maneuver-0');
      expect(restored.markerReview.rejected.single.label, 'Junction marker');
      expect(restored.markerReview.added.single.id, 'geometry-4');
      expect(
        restored.markerReview.added.single.position.latitude,
        closeTo(51.503, 1e-9),
      );
    });

    test('a route saved before review parses with an empty one', () {
      final restored = ImportedRoute.fromJsonString(
        _straightRoute().toJsonString(),
      );

      expect(restored.markerReview.isEmpty, isTrue);
    });
  });
}

/// The mouth of the no-through road, on the ridden line but not a turn the
/// group takes.
const _culDeSacMouth = GeoPoint(latitude: 51.502, longitude: -2.5);
const _culDeSacMouthTolerance = 30.0;

/// A route north along one road, past the mouth of a cul-de-sac it never
/// enters, then a left turn at a genuine junction.
///
/// The cul-de-sac is a real junction on the map, and the route engine reports a
/// manoeuvre at its mouth. The group rides straight through it: the line's
/// heading does not change, so nobody can take the wrong branch by mistake.
ImportedRoute _culDeSacRoute() => ImportedRoute(
  id: 'cul-de-sac',
  name: 'Past a no-through road',
  importedAt: DateTime.utc(2026, 7, 27),
  sourceFileName: 'cul-de-sac.gpx',
  paths: const [
    RoutePath(
      kind: RoutePathKind.track,
      points: [
        GeoPoint(latitude: 51.5, longitude: -2.5),
        GeoPoint(latitude: 51.501, longitude: -2.5),
        // The cul-de-sac mouth: the road carries straight on past it.
        GeoPoint(latitude: 51.502, longitude: -2.5),
        GeoPoint(latitude: 51.503, longitude: -2.5),
        // A real left turn the group takes, and could miss.
        GeoPoint(latitude: 51.504, longitude: -2.5),
        GeoPoint(latitude: 51.504, longitude: -2.502),
        GeoPoint(latitude: 51.504, longitude: -2.504),
      ],
    ),
  ],
  waypoints: const [],
  maneuvers: const [
    RouteManeuver(
      position: _culDeSacMouth,
      type: 'turn',
      modifier: 'right',
      name: 'Orchard Close',
    ),
    RouteManeuver(
      position: GeoPoint(latitude: 51.504, longitude: -2.5),
      type: 'turn',
      modifier: 'left',
      name: 'Church Lane',
    ),
  ],
);

/// A dense straight line, so a manoeuvre's own bearings decide the outcome
/// rather than sparse geometry.
ImportedRoute _straightRoute({List<RouteManeuver> maneuvers = const []}) =>
    ImportedRoute(
      id: 'straight',
      name: 'Straight road',
      importedAt: DateTime.utc(2026, 7, 27),
      sourceFileName: 'straight.gpx',
      paths: [
        RoutePath(
          kind: RoutePathKind.track,
          points: List.generate(
            8,
            (index) =>
                GeoPoint(latitude: 51.5 + index * 0.0005, longitude: -2.5),
            growable: false,
          ),
        ),
      ],
      waypoints: const [],
      maneuvers: maneuvers,
    );

ImportedRoute _route({
  List<RouteManeuver> maneuvers = const [],
  List<RouteWaypoint> waypoints = const [],
}) => ImportedRoute(
  id: 'route',
  name: 'Marker plan',
  importedAt: DateTime.utc(2026, 7, 24),
  sourceFileName: 'marker-plan.gpx',
  paths: const [
    RoutePath(
      kind: RoutePathKind.track,
      points: [
        GeoPoint(latitude: 51, longitude: -2),
        GeoPoint(latitude: 51.4, longitude: -2.4),
      ],
    ),
  ],
  waypoints: waypoints,
  maneuvers: maneuvers,
);

double _metresApart(GeoPoint first, GeoPoint second) {
  const metresPerDegree = 111320.0;
  final latitude = (first.latitude - second.latitude) * metresPerDegree;
  final longitude =
      (first.longitude - second.longitude) * metresPerDegree * 0.62;
  return math.sqrt(latitude * latitude + longitude * longitude);
}
