import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:xml/xml.dart';

import '../domain/imported_route.dart';

class GpxParser {
  const GpxParser({
    this.maximumBytes = 10 * 1024 * 1024,
    this.maximumPoints = 200000,
  });

  final int maximumBytes;
  final int maximumPoints;

  ImportedRoute parse(
    Uint8List bytes, {
    required String routeId,
    required String sourceFileName,
    required DateTime importedAt,
  }) {
    if (bytes.isEmpty) {
      throw const GpxFormatException('The GPX file is empty.');
    }
    if (bytes.length > maximumBytes) {
      throw GpxFormatException(
        'The GPX file exceeds the ${maximumBytes ~/ (1024 * 1024)} MB import limit.',
      );
    }

    final String source;
    try {
      source = utf8.decode(bytes);
    } on FormatException {
      throw const GpxFormatException('The GPX file must use UTF-8 encoding.');
    }
    if (source.toUpperCase().contains('<!DOCTYPE')) {
      throw const GpxFormatException(
        'GPX files containing a document type declaration are not accepted.',
      );
    }

    final XmlDocument document;
    try {
      document = XmlDocument.parse(source);
    } on XmlParserException catch (error) {
      throw GpxFormatException('Invalid GPX XML: ${error.message}');
    }
    final root = document.rootElement;
    if (root.name.local.toLowerCase() != 'gpx') {
      throw const GpxFormatException('The document root must be <gpx>.');
    }

    var pointCount = 0;
    GeoPoint parsePoint(XmlElement element) {
      pointCount += 1;
      if (pointCount > maximumPoints) {
        throw GpxFormatException(
          'The GPX file exceeds the $maximumPoints point import limit.',
        );
      }
      final latitude = _coordinate(element, 'lat', -90, 90);
      final longitude = _coordinate(element, 'lon', -180, 180);
      final elevation = _optionalDouble(_childText(element, 'ele'));
      final timeText = _childText(element, 'time');
      DateTime? recordedAt;
      if (timeText != null) {
        recordedAt = DateTime.tryParse(timeText)?.toUtc();
      }
      return GeoPoint(
        latitude: latitude,
        longitude: longitude,
        elevationMeters: elevation,
        recordedAt: recordedAt,
      );
    }

    final paths = <RoutePath>[];
    for (final track in _children(root, 'trk')) {
      final trackName = _childText(track, 'name');
      final isCalculatedRoadRoute = _children(track, 'extensions')
          .expand((extensions) => extensions.childElements)
          .any(
            (element) =>
                element.name.local.toLowerCase() == 'road-route' &&
                element.innerText.trim().toLowerCase() == 'true',
          );
      final segments = _children(track, 'trkseg').toList(growable: false);
      for (var index = 0; index < segments.length; index += 1) {
        final points = _children(
          segments[index],
          'trkpt',
        ).map(parsePoint).toList(growable: false);
        if (points.isEmpty) continue;
        final segmentName = segments.length > 1 && trackName != null
            ? '$trackName · segment ${index + 1}'
            : trackName;
        paths.add(
          RoutePath(
            kind: isCalculatedRoadRoute
                ? RoutePathKind.route
                : RoutePathKind.track,
            name: segmentName,
            points: points,
          ),
        );
      }
    }
    final routeElements = _routesForImport(root);
    final routeWaypoints = <RouteWaypoint>[];
    for (final route in routeElements) {
      final points = <GeoPoint>[];
      for (final routePoint in _children(route, 'rtept')) {
        final point = parsePoint(routePoint);
        points.add(point);
        final pointKind = _routePointKind(routePoint);
        if (pointKind != null) {
          routeWaypoints.add(
            RouteWaypoint(
              point: point,
              name: _childText(routePoint, 'name'),
              description: pointKind == 'shaping'
                  ? 'Soft route shaping point'
                  : 'Route via point',
              symbol: pointKind == 'shaping' ? 'Shaping point' : 'Via point',
            ),
          );
        }
        // Geometry, not waypoints (#574).
        //
        // `<gpxx:rpt>` is Garmin's decoded shape of the leg between two
        // `<rtept>`s — the calculated road the receiving device would
        // otherwise have to work out again. Every vertex of it used to be
        // promoted to a rendered, listed, tappable "Shaping point": one
        // MyRouteApp export of a 296 km day run produced **6960** of them,
        // which is the carpet of yellow markers that made the track
        // impossible to see zoomed out.
        //
        // The points still shape the line. What they stop doing is pretending
        // to be places somebody chose. A rider's actual via and shaping points
        // carry `<trp:ViaPoint>`/`<gpxx:ShapingPoint>` and are read above.
        for (final shapingPoint in _routePointExtensionPoints(routePoint)) {
          points.add(parsePoint(shapingPoint));
        }
      }
      if (points.isEmpty) continue;
      paths.add(
        RoutePath(
          kind: RoutePathKind.route,
          name: _childText(route, 'name'),
          points: points,
        ),
      );
    }

    final waypoints = _children(root, 'wpt')
        .map(
          (waypoint) => RouteWaypoint(
            point: parsePoint(waypoint),
            name: _childText(waypoint, 'name'),
            description:
                _childText(waypoint, 'desc') ?? _childText(waypoint, 'cmt'),
            symbol: _childText(waypoint, 'sym'),
          ),
        )
        .toList();
    for (final routeWaypoint in routeWaypoints) {
      final duplicate = waypoints.any(
        (waypoint) =>
            (waypoint.point.latitude - routeWaypoint.point.latitude).abs() <
                0.000001 &&
            (waypoint.point.longitude - routeWaypoint.point.longitude).abs() <
                0.000001,
      );
      if (!duplicate) waypoints.add(routeWaypoint);
    }

    final selectedPaths = _withoutDuplicateRepresentations(paths);

    if (selectedPaths.isEmpty && waypoints.isEmpty) {
      throw const GpxFormatException(
        'The GPX file contains no tracks, routes, or waypoints.',
      );
    }
    final metadata = _children(root, 'metadata').firstOrNull;
    final metadataName = metadata == null ? null : _childText(metadata, 'name');
    final firstPathName = selectedPaths
        .map((path) => path.name)
        .nonNulls
        .firstOrNull;

    return ImportedRoute(
      id: routeId,
      name:
          metadataName ??
          firstPathName ??
          _nameWithoutExtension(sourceFileName),
      description: metadata == null ? null : _childText(metadata, 'desc'),
      importedAt: importedAt.toUtc(),
      sourceFileName: sourceFileName,
      paths: selectedPaths,
      waypoints: List.unmodifiable(waypoints),
      preferences: metadata == null ? null : _routePreferences(metadata),
      markerReview: metadata == null
          ? MarkerPlanReview.empty
          : _markerReview(metadata),
    );
  }
}

/// Reads the preferences a Tail End Charlie route was planned with.
///
/// Absent for a file from any other tool, which is the honest answer: nothing
/// is assumed about a route whose planner never recorded one.
RoutePreferences? _routePreferences(XmlElement metadata) {
  final element = _children(metadata, 'extensions')
      .expand((extensions) => extensions.childElements)
      .where((child) => child.name.local.toLowerCase() == 'route-preferences')
      .firstOrNull;
  if (element == null) return null;
  String? attribute(String name) => element.attributes
      .where((item) => item.name.local.toLowerCase() == name)
      .map((item) => item.value.trim())
      .firstOrNull;
  return RoutePreferences.fromJson({
    'style': attribute('style'),
    'avoidMotorways': attribute('avoid-motorways') == 'true',
    'avoidMajorRoads': attribute('avoid-major-roads') == 'true',
    'avoidTolls': attribute('avoid-tolls') == 'true',
    'avoidFerries': attribute('avoid-ferries') == 'true',
    'bywaySurface': attribute('byway-surface'),
  });
}

MarkerPlanReview _markerReview(XmlElement metadata) {
  final element = _children(metadata, 'extensions')
      .expand((extensions) => extensions.childElements)
      .where((child) => child.name.local.toLowerCase() == 'marker-review')
      .firstOrNull;
  if (element == null) return MarkerPlanReview.empty;

  List<MarkerReviewPoint> points(String kind) {
    final children = element.childElements
        .where((child) => child.name.local.toLowerCase() == kind)
        .toList(growable: false);
    if (children.length > 500) {
      throw const GpxFormatException(
        'The GPX file contains too many marker review positions.',
      );
    }
    return children
        .map((child) {
          final id = child.getAttribute('id')?.trim();
          if (id == null || id.isEmpty || id.length > 120) {
            throw const GpxFormatException(
              'A marker review position has an invalid identifier.',
            );
          }
          final latitude = _coordinate(child, 'lat', -90, 90);
          final longitude = _coordinate(child, 'lon', -180, 180);
          final rawLabel = child.getAttribute('label')?.trim();
          final label = rawLabel != null && rawLabel.length > 160
              ? rawLabel.substring(0, 160)
              : rawLabel;
          return MarkerReviewPoint(
            id: id,
            position: GeoPoint(latitude: latitude, longitude: longitude),
            label: label == null || label.isEmpty ? null : label,
          );
        })
        .toList(growable: false);
  }

  return MarkerPlanReview(rejected: points('rejected'), added: points('added'));
}

/// Drops a route path that describes the same journey as a track path.
///
/// MyRoute-app exports one `<trk>` of calculated road geometry *and* one `<rte>`
/// of the waypoints it was calculated from - for the route this was found on,
/// 709 track points and 8 route points over the same 37.7 km. Keeping both meant
/// the ride was measured twice, so the app showed 47.4 mi for a 23.4 mi route,
/// and the sparse 8-point line drawn across the dense one read as loops wherever
/// the two diverged (#180).
///
/// `_routesForImport` already applies this principle among Scenic's three `<rte>`
/// representations; this extends it across the track/route boundary. Only a
/// genuine duplicate is dropped: every one of its points must lie within
/// [_duplicateRepresentationCorridorMeters] of a denser track path, so a `<trk>`
/// recording of a different ride alongside a planned `<rte>` keeps both. The
/// dropped path's `rtept`s have already been harvested as waypoints, with their
/// via and shaping semantics, so nothing is lost but the redundant line.
List<RoutePath> _withoutDuplicateRepresentations(List<RoutePath> paths) {
  final tracks = paths
      .where(
        (path) => path.kind == RoutePathKind.track && path.points.length >= 2,
      )
      .toList(growable: false);
  if (tracks.isEmpty) return List.unmodifiable(paths);
  final kept = <RoutePath>[];
  for (final path in paths) {
    final duplicated =
        path.kind == RoutePathKind.route &&
        path.points.length >= 2 &&
        tracks.any(
          (track) =>
              _comparablyDense(track: track.points, route: path.points) &&
              path.points.every(
                (point) =>
                    _metresFromPath(point, track.points) <=
                    _duplicateRepresentationCorridorMeters,
              ),
        );
    if (!duplicated) kept.add(path);
  }
  return List.unmodifiable(kept);
}

/// Whether a track is a fair substitute for a route, by point count.
///
/// #180 required the track be strictly *denser* before the route was dropped,
/// to protect a route carrying detail the track lacked. That reading is right
/// but the test was one-sided, and it missed the export it was written for: a
/// MyRouteApp file carries its `<gpxx:rpt>` leg geometry inline, so the route
/// representation comes out marginally **denser** than the track — 7204 points
/// against 7000 over the same 296 km — and both were kept. The ride was drawn
/// twice and measured twice (#574).
///
/// Ten per cent is the width of that gap and nothing like the gap between two
/// genuinely different representations: a sparse recording alongside a detailed
/// plan differs by an order of magnitude, not by the handful of `<rtept>`
/// anchors between the decoded legs.
bool _comparablyDense({
  required List<GeoPoint> track,
  required List<GeoPoint> route,
}) => track.length * 1.1 >= route.length;

/// How far a route point may sit from the track and still be the same journey.
///
/// 250 m: a shaping point is snapped to the road the router chose, so in practice
/// these land within metres. The margin is for a junction the router resolved
/// differently from where the point was dropped, and it is far tighter than any
/// separation between two genuinely different rides.
const _duplicateRepresentationCorridorMeters = 250.0;

/// Shortest distance from [point] to the polyline [path], in metres.
///
/// Local flat-earth arithmetic rather than `GeoCalculations`, which speaks the
/// other `GeoPoint`: converting every track point for every route point would
/// cost more than the comparison. Over the few hundred metres that decide this,
/// the projection error is centimetres.
double _metresFromPath(GeoPoint point, List<GeoPoint> path) {
  const metresPerDegreeLatitude = 111132.0;
  final metresPerDegreeLongitude =
      metresPerDegreeLatitude * math.cos(point.latitude * math.pi / 180).abs();
  var nearest = double.infinity;
  for (var index = 0; index < path.length - 1; index += 1) {
    final startX =
        (path[index].longitude - point.longitude) * metresPerDegreeLongitude;
    final startY =
        (path[index].latitude - point.latitude) * metresPerDegreeLatitude;
    final endX =
        (path[index + 1].longitude - point.longitude) *
        metresPerDegreeLongitude;
    final endY =
        (path[index + 1].latitude - point.latitude) * metresPerDegreeLatitude;
    final spanX = endX - startX;
    final spanY = endY - startY;
    final spanLengthSquared = spanX * spanX + spanY * spanY;
    final fraction = spanLengthSquared == 0
        ? 0.0
        : (-(startX * spanX + startY * spanY) / spanLengthSquared).clamp(
            0.0,
            1.0,
          );
    final nearestX = startX + fraction * spanX;
    final nearestY = startY + fraction * spanY;
    final distance = math.sqrt(nearestX * nearestX + nearestY * nearestY);
    if (distance < nearest) nearest = distance;
    if (nearest == 0) return 0;
  }
  return nearest;
}

class GpxFormatException implements FormatException {
  const GpxFormatException(this.message);

  @override
  final String message;

  @override
  int? get offset => null;

  @override
  Object? get source => null;

  @override
  String toString() => 'GpxFormatException: $message';
}

Iterable<XmlElement> _children(XmlElement parent, String localName) => parent
    .childElements
    .where((element) => element.name.local.toLowerCase() == localName);

List<XmlElement> _routesForImport(XmlElement root) {
  final routes = _children(root, 'rte').toList(growable: false);
  final creator = root.getAttribute('creator')?.toLowerCase() ?? '';
  if (!creator.contains('scenic') || routes.length < 2) return routes;

  // Scenic exports plain GPX, Garmin Trip and Garmin RoutePoint versions of
  // the same route in one document. Importing all three creates overlapping,
  // differently recalculated paths. Select the richest representation,
  // preferring explicit shaping/via semantics when point coverage ties.
  XmlElement selected = routes.first;
  var selectedScore = _routeRepresentationScore(selected);
  for (final route in routes.skip(1)) {
    final score = _routeRepresentationScore(route);
    if (score > selectedScore) {
      selected = route;
      selectedScore = score;
    }
  }
  return [selected];
}

int _routeRepresentationScore(XmlElement route) {
  var effectivePoints = 0;
  var semanticPoints = 0;
  for (final routePoint in _children(route, 'rtept')) {
    effectivePoints += 1 + _routePointExtensionPoints(routePoint).length;
    if (_routePointKind(routePoint) != null) semanticPoints += 1;
  }
  return effectivePoints * 1000 + semanticPoints;
}

String? _routePointKind(XmlElement routePoint) {
  for (final element in routePoint.descendantElements) {
    switch (element.name.local.toLowerCase()) {
      case 'shapingpoint':
        return 'shaping';
      case 'viapoint':
        return 'via';
    }
  }
  return null;
}

List<XmlElement> _routePointExtensionPoints(XmlElement routePoint) => routePoint
    .descendantElements
    .where((element) => element.name.local.toLowerCase() == 'rpt')
    .toList(growable: false);

String? _childText(XmlElement parent, String localName) {
  final element = _children(parent, localName).firstOrNull;
  final value = element?.innerText.trim();
  return value == null || value.isEmpty ? null : value;
}

double _coordinate(
  XmlElement element,
  String attributeName,
  double minimum,
  double maximum,
) {
  final raw = element.getAttribute(attributeName);
  final value = double.tryParse(raw ?? '');
  if (value == null || !value.isFinite || value < minimum || value > maximum) {
    throw GpxFormatException(
      '<${element.name.local}> has an invalid $attributeName coordinate.',
    );
  }
  return value;
}

double? _optionalDouble(String? raw) {
  if (raw == null) return null;
  final value = double.tryParse(raw);
  return value != null && value.isFinite ? value : null;
}

String _nameWithoutExtension(String fileName) {
  final dot = fileName.lastIndexOf('.');
  final name = dot > 0 ? fileName.substring(0, dot) : fileName;
  return name.trim().isEmpty ? 'Imported route' : name.trim();
}
