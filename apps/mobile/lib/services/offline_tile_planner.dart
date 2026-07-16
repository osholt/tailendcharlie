import 'dart:math' as math;

import '../domain/imported_route.dart';

class OfflineTileCoordinate implements Comparable<OfflineTileCoordinate> {
  const OfflineTileCoordinate({
    required this.zoom,
    required this.x,
    required this.y,
  });

  final int zoom;
  final int x;
  final int y;

  @override
  int compareTo(OfflineTileCoordinate other) {
    final zoomComparison = zoom.compareTo(other.zoom);
    if (zoomComparison != 0) return zoomComparison;
    final xComparison = x.compareTo(other.x);
    return xComparison != 0 ? xComparison : y.compareTo(other.y);
  }

  @override
  bool operator ==(Object other) =>
      other is OfflineTileCoordinate &&
      zoom == other.zoom &&
      x == other.x &&
      y == other.y;

  @override
  int get hashCode => Object.hash(zoom, x, y);
}

class OfflineTilePlanner {
  const OfflineTilePlanner();

  List<OfflineTileCoordinate> planRouteCorridor(
    ImportedRoute route, {
    int minimumZoom = 11,
    int maximumZoom = 15,
    int corridorTileRadius = 1,
    int maximumTiles = 2500,
  }) {
    if (minimumZoom < 0 || maximumZoom > 22 || minimumZoom > maximumZoom) {
      throw ArgumentError('Zoom range must be ordered and within 0..22.');
    }
    if (corridorTileRadius < 0 || corridorTileRadius > 3) {
      throw ArgumentError('Corridor tile radius must be within 0..3.');
    }
    if (maximumTiles < 1) {
      throw ArgumentError('Maximum tile count must be positive.');
    }

    final selected = <OfflineTileCoordinate>{};
    for (var zoom = minimumZoom; zoom <= maximumZoom; zoom += 1) {
      for (final path in route.paths) {
        if (path.points.length == 1) {
          _addBuffered(
            selected,
            _project(path.points.single, zoom),
            corridorTileRadius,
            maximumTiles,
          );
          continue;
        }
        for (var index = 1; index < path.points.length; index += 1) {
          final start = _project(path.points[index - 1], zoom);
          final end = _project(path.points[index], zoom);
          for (final tile in _lineBetween(start, end)) {
            _addBuffered(selected, tile, corridorTileRadius, maximumTiles);
          }
        }
      }
      for (final waypoint in route.waypoints) {
        _addBuffered(
          selected,
          _project(waypoint.point, zoom),
          corridorTileRadius,
          maximumTiles,
        );
      }
    }
    final result = selected.toList(growable: false)..sort();
    return result;
  }

  OfflineTileCoordinate _project(GeoPoint point, int zoom) {
    final count = 1 << zoom;
    final x = ((point.longitude + 180) / 360 * count).floor();
    final webMercatorLatitude = point.latitude.clamp(-85.05112878, 85.05112878);
    final latitudeRadians = webMercatorLatitude * math.pi / 180;
    final y =
        ((1 -
                    math.log(
                          math.tan(latitudeRadians) +
                              (1 / math.cos(latitudeRadians)),
                        ) /
                        math.pi) /
                2 *
                count)
            .floor();
    return OfflineTileCoordinate(
      zoom: zoom,
      x: x.clamp(0, count - 1),
      y: y.clamp(0, count - 1),
    );
  }

  Iterable<OfflineTileCoordinate> _lineBetween(
    OfflineTileCoordinate start,
    OfflineTileCoordinate end,
  ) sync* {
    var x = start.x;
    var y = start.y;
    final deltaX = (end.x - start.x).abs();
    final stepX = start.x < end.x ? 1 : -1;
    final deltaY = -(end.y - start.y).abs();
    final stepY = start.y < end.y ? 1 : -1;
    var error = deltaX + deltaY;
    while (true) {
      yield OfflineTileCoordinate(zoom: start.zoom, x: x, y: y);
      if (x == end.x && y == end.y) break;
      final doubled = 2 * error;
      if (doubled >= deltaY) {
        error += deltaY;
        x += stepX;
      }
      if (doubled <= deltaX) {
        error += deltaX;
        y += stepY;
      }
    }
  }

  void _addBuffered(
    Set<OfflineTileCoordinate> target,
    OfflineTileCoordinate tile,
    int radius,
    int maximumTiles,
  ) {
    final count = 1 << tile.zoom;
    for (var xOffset = -radius; xOffset <= radius; xOffset += 1) {
      for (var yOffset = -radius; yOffset <= radius; yOffset += 1) {
        final x = tile.x + xOffset;
        final y = tile.y + yOffset;
        if (x < 0 || x >= count || y < 0 || y >= count) continue;
        target.add(OfflineTileCoordinate(zoom: tile.zoom, x: x, y: y));
        if (target.length > maximumTiles) {
          throw OfflineTileLimitException(maximumTiles);
        }
      }
    }
  }
}

class OfflineTileLimitException implements Exception {
  const OfflineTileLimitException(this.maximumTiles);

  final int maximumTiles;

  @override
  String toString() =>
      'The requested route corridor exceeds the $maximumTiles tile safety cap.';
}
