import 'package:uuid/uuid.dart';

import '../domain/imported_route.dart';
import 'recorded_track_cleaner.dart';
import 'ride_timing_analysis.dart';
import 'road_routing.dart';

/// Editing always creates a plan derivative. Actual fixes, elapsed times and
/// ride statistics remain in the source archive and are never rewritten.
class RouteCorrection {
  static ImportedRoute copyOf(
    ImportedRoute source, {
    String? id,
    String? name,
  }) => ImportedRoute(
    id: id ?? const Uuid().v4(),
    name: name ?? '${source.name} (corrected)',
    derivedFromRouteId: source.id,
    importedAt: DateTime.now().toUtc(),
    sourceFileName: 'corrected-route.gpx',
    description:
        'Corrected copy of ${source.name}. Edited plan, not an as-ridden recording.',
    paths: [
      for (final path in source.paths)
        RoutePath(
          kind: RoutePathKind.route,
          name: path.name,
          points: [for (final point in path.points) _untimed(point)],
        ),
    ],
    waypoints: const [],
    preferences: source.preferences,
    organisation: source.organisation,
  );

  static ImportedRoute tidy(ImportedRoute draft) => _withPaths(draft, [
    for (final path in draft.paths)
      RoutePath(
        kind: RoutePathKind.route,
        name: path.name,
        points: const RecordedTrackCleaner().clean(path.points),
      ),
  ]);

  static ImportedRoute trim(ImportedRoute draft, int first, int last) {
    _validate(draft, first, last);
    return _withPaths(draft, _slice(draft, first, last));
  }

  static Future<ImportedRoute> replaceSection(
    ImportedRoute draft,
    int first,
    int last,
    RoadRoutingService router,
  ) async {
    _validate(draft, first, last);
    final points = draft.paths.expand((path) => path.points).toList();
    final result = await router
        .routeThrough([
          points[first],
          points[last],
        ], preferences: draft.preferences)
        .timeout(const Duration(seconds: 25));
    if (result.points.length < 2 ||
        ridePointDistance(points[first], result.points.first) > 100 ||
        ridePointDistance(points[last], result.points.last) > 100) {
      throw const FormatException(
        'The router could not connect the selected points closely enough. Move the selection onto the road and retry.',
      );
    }
    final before = _slice(draft, 0, first);
    final after = _slice(draft, last, points.length - 1);
    final joined = <GeoPoint>[
      ...before.removeLast().points,
      ...result.points.map(_untimed),
      ...after.removeAt(0).points,
    ];
    return _withPaths(draft, [
      ...before,
      RoutePath(kind: RoutePathKind.route, points: joined),
      ...after,
    ]);
  }

  static void _validate(ImportedRoute draft, int first, int last) {
    if (first < 0 || last >= draft.pathPointCount || first >= last) {
      throw const FormatException(
        'Select two different points in route order.',
      );
    }
  }

  static List<RoutePath> _slice(ImportedRoute route, int start, int end) {
    var offset = 0;
    final result = <RoutePath>[];
    for (final path in route.paths) {
      final from = (start - offset).clamp(0, path.points.length);
      final to = (end - offset + 1).clamp(0, path.points.length);
      if (from < to) {
        result.add(
          RoutePath(
            kind: RoutePathKind.route,
            name: path.name,
            points: path.points.sublist(from, to),
          ),
        );
      }
      offset += path.points.length;
    }
    return result;
  }

  static ImportedRoute _withPaths(ImportedRoute draft, List<RoutePath> paths) =>
      ImportedRoute(
        id: draft.id,
        name: draft.name,
        derivedFromRouteId: draft.derivedFromRouteId,
        importedAt: draft.importedAt,
        sourceFileName: draft.sourceFileName,
        description: draft.description,
        paths: paths,
        waypoints: const [],
        preferences: draft.preferences,
        organisation: draft.organisation,
      );
  static GeoPoint _untimed(GeoPoint point) => GeoPoint(
    latitude: point.latitude,
    longitude: point.longitude,
    elevationMeters: point.elevationMeters,
  );
}
