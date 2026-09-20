import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/completed_ride.dart';
import '../domain/completed_ride_store.dart';
import '../domain/imported_route.dart';
import '../services/recorded_heatmap_continuity.dart';

typedef PersonalHeatmapBounds = ({
  double west,
  double south,
  double east,
  double north,
});

/// One bounded spatial cell in the private, on-device archive heatmap.
class PersonalRideHeatmapCell {
  const PersonalRideHeatmapCell({
    required this.x,
    required this.y,
    required this.visits,
    required this.weight,
    this.resolution = PersonalRideHeatmapBuilder.canonicalZoom,
  });

  final int x;
  final int y;
  final int visits;
  final int resolution;

  /// Log-scaled 0..1 intensity so one very familiar road does not flatten all
  /// the other roads to the same faint colour.
  final double weight;

  GeoPoint get centre {
    final scale = 1 << resolution;
    final longitude = (x + 0.5) / scale * 360 - 180;
    final latitude = _latitudeAtTileY(y + 0.5, scale);
    return GeoPoint(latitude: latitude, longitude: longitude);
  }

  /// The exact square represented by this cell, clockwise from north-west.
  /// Adjacent cells therefore share an edge exactly instead of becoming dots
  /// whose radius happens to look joined at one zoom level (#661).
  List<GeoPoint> get polygon {
    final scale = 1 << resolution;
    final west = x / scale * 360 - 180;
    final east = (x + 1) / scale * 360 - 180;
    final north = _latitudeAtTileY(y.toDouble(), scale);
    final south = _latitudeAtTileY((y + 1).toDouble(), scale);
    return List.unmodifiable([
      GeoPoint(latitude: north, longitude: west),
      GeoPoint(latitude: north, longitude: east),
      GeoPoint(latitude: south, longitude: east),
      GeoPoint(latitude: south, longitude: west),
    ]);
  }

  static double _latitudeAtTileY(double tileY, int scale) {
    final mercator = math.pi * (1 - 2 * tileY / scale);
    final sinh = (math.exp(mercator) - math.exp(-mercator)) / 2;
    return math.atan(sinh) * 180 / math.pi;
  }
}

/// Derived local coverage. It contains no ride identity, time, speed or plan.
class PersonalRideHeatmap {
  const PersonalRideHeatmap({
    required this.cells,
    required this.inputPointCount,
    required this.truncated,
    this.resolution = PersonalRideHeatmapBuilder.canonicalZoom,
  });

  static const empty = PersonalRideHeatmap(
    cells: [],
    inputPointCount: 0,
    truncated: false,
  );

  final List<PersonalRideHeatmapCell> cells;
  final int inputPointCount;
  final bool truncated;
  final int resolution;

  Map<String, dynamic> toGeoJson() => {
    'type': 'FeatureCollection',
    'features': [
      for (final cell in cells)
        {
          'type': 'Feature',
          'id': 'personal-${cell.x}-${cell.y}',
          'properties': {
            'visits': cell.visits,
            'weight': cell.weight,
            'resolution': cell.resolution,
          },
          'geometry': {
            'type': 'Point',
            'coordinates': [cell.centre.longitude, cell.centre.latitude],
          },
        },
    ],
  };

  Map<String, dynamic> toCellGeoJson() => {
    'type': 'FeatureCollection',
    'features': [
      for (final cell in cells)
        {
          'type': 'Feature',
          'id': 'personal-cell-${cell.x}-${cell.y}',
          'properties': {
            'visits': cell.visits,
            'weight': cell.weight,
            'resolution': cell.resolution,
          },
          'geometry': {
            'type': 'Polygon',
            'coordinates': [
              [
                for (final point in [...cell.polygon, cell.polygon.first])
                  [point.longitude, point.latitude],
              ],
            ],
          },
        },
    ],
  };
}

/// Turns only travelled track segments into a fixed-size spatial index.
///
/// Tiling is the rendering bound: 100,000 archived GPS fixes do not become
/// 100,000 widgets or MapLibre features. Gaps remain gaps because each track
/// path is rasterised independently. Nearby fixes fill the cells between them;
/// distant fixes remain separate real samples instead of becoming a fabricated
/// straight road.
class PersonalRideHeatmapBuilder {
  const PersonalRideHeatmapBuilder({this.maximumCells = 20000});

  // Roughly 45-50 m across at UK latitudes. z17 was about 190 m and made the
  // close-zoom overlay look like a handful of large coloured map tiles rather
  // than road coverage (#661).
  static const canonicalZoom = 19;
  static const _maximumMercatorLatitude = 85.05112878;

  final int maximumCells;

  PersonalRideHeatmap build(
    Iterable<CompletedRide> rides, {
    PersonalHeatmapBounds? bounds,
  }) {
    if (maximumCells < 1) {
      throw ArgumentError.value(maximumCells, 'maximumCells');
    }
    // Reduce precision, never the set of trips. Starting with the newest trips
    // and dropping later cells erased older countries after a long tour (#780).
    for (var zoom = canonicalZoom; zoom >= 0; zoom--) {
      final result = _buildAtResolution(rides, zoom, bounds);
      if (!result.truncated) return result;
    }
    throw StateError('A world cell must fit a positive cell budget.');
  }

  PersonalRideHeatmap _buildAtResolution(
    Iterable<CompletedRide> rides,
    int zoom,
    PersonalHeatmapBounds? bounds,
  ) {
    final northwest = bounds == null
        ? null
        : _tileCoordinate(
            GeoPoint(latitude: bounds.north, longitude: bounds.west),
            zoom,
          );
    final southeast = bounds == null
        ? null
        : _tileCoordinate(
            GeoPoint(latitude: bounds.south, longitude: bounds.east),
            zoom,
          );
    bool inBounds((int x, int y) cell) =>
        northwest == null ||
        southeast == null ||
        (cell.$1 >= northwest.x.floor() &&
            cell.$1 <= southeast.x.floor() &&
            cell.$2 >= northwest.y.floor() &&
            cell.$2 <= southeast.y.floor());
    final visits = <(int x, int y), int>{};
    var inputPointCount = 0;
    var truncated = false;
    for (final ride in rides) {
      if (ride.libraryStatus == RideLibraryStatus.deleted) continue;
      final route = ride.traveledRoute;
      if (route == null) continue;
      for (final path in route.paths) {
        if (path.kind != RoutePathKind.track || path.points.length < 2) {
          continue;
        }
        inputPointCount += path.points.length;
        (int x, int y)? previousCell;
        void record((int x, int y) cell) {
          if (cell == previousCell || !inBounds(cell)) return;
          previousCell = cell;
          if (!visits.containsKey(cell) && visits.length >= maximumCells) {
            truncated = true;
            return;
          }
          visits.update(cell, (value) => value + 1, ifAbsent: () => 1);
        }

        record(_cellAt(path.points.first, zoom));
        for (var index = 1; index < path.points.length; index += 1) {
          final start = path.points[index - 1];
          final end = path.points[index];
          if (!recordedHeatmapSegmentIsContinuous(start, end)) {
            // Both endpoints are recorded evidence, but nothing between them
            // is. Resetting also prevents a repeated tile after a GPS outage
            // from being merged with the earlier visit.
            previousCell = null;
            record(_cellAt(end, zoom));
            continue;
          }
          for (final cell in _cellsBetween(start, end, zoom)) {
            record(cell);
            if (truncated) break;
          }
          if (truncated) break;
        }
        if (truncated) break;
      }
      if (truncated) break;
    }
    if (visits.isEmpty) {
      return PersonalRideHeatmap(
        cells: const [],
        inputPointCount: inputPointCount,
        truncated: truncated,
        resolution: zoom,
      );
    }
    // Absolute rather than normalised-to-this-archive: otherwise one ride and
    // two identical rides would both be the archive maximum and render at the
    // same intensity. Eight passages reaches the visual cap.
    final denominator = math.log(9);
    final cells =
        visits.entries
            .map(
              (entry) => PersonalRideHeatmapCell(
                x: entry.key.$1,
                y: entry.key.$2,
                visits: entry.value,
                resolution: zoom,
                weight: (math.log(entry.value + 1) / denominator).clamp(0, 1),
              ),
            )
            .toList(growable: false)
          ..sort((left, right) {
            final y = left.y.compareTo(right.y);
            return y != 0 ? y : left.x.compareTo(right.x);
          });
    return PersonalRideHeatmap(
      cells: List.unmodifiable(cells),
      inputPointCount: inputPointCount,
      truncated: truncated,
      resolution: zoom,
    );
  }

  Iterable<(int x, int y)> _cellsBetween(
    GeoPoint start,
    GeoPoint end,
    int zoom,
  ) sync* {
    final a = _tileCoordinate(start, zoom);
    final b = _tileCoordinate(end, zoom);
    final steps = math.max(
      1,
      (math.max((b.x - a.x).abs(), (b.y - a.y).abs()) * 2).ceil(),
    );
    for (var step = 0; step <= steps; step += 1) {
      final fraction = step / steps;
      yield (
        (a.x + (b.x - a.x) * fraction).floor(),
        (a.y + (b.y - a.y) * fraction).floor(),
      );
    }
  }

  (int x, int y) _cellAt(GeoPoint point, int zoom) {
    final coordinate = _tileCoordinate(point, zoom);
    return (coordinate.x.floor(), coordinate.y.floor());
  }

  ({double x, double y}) _tileCoordinate(GeoPoint point, int zoom) {
    final scale = (1 << zoom).toDouble();
    final latitude = point.latitude.clamp(
      -_maximumMercatorLatitude,
      _maximumMercatorLatitude,
    );
    final latitudeRadians = latitude * math.pi / 180;
    final x = (point.longitude + 180) / 360 * scale;
    final y =
        (1 -
            math.log(
                  math.tan(latitudeRadians) + 1 / math.cos(latitudeRadians),
                ) /
                math.pi) /
        2 *
        scale;
    return (x: x.clamp(0, scale - 0.000001), y: y.clamp(0, scale - 0.000001));
  }
}

/// Remembered visibility plus fresh local derivation from [CompletedRideStore].
///
/// There is deliberately no HTTP dependency in this boundary. When the store
/// is also a [Listenable] (the production [CompletedRidesController] is), a
/// save or deletion rebuilds visible coverage immediately.
class PersonalRideHeatmapController extends ChangeNotifier {
  PersonalRideHeatmapController._(
    this._store,
    this._preferences,
    this._builder,
    this._visible,
  );

  static const preferenceKey = 'personal_ride_heatmap_visible';
  static const defaultVisible = true;

  final CompletedRideStore _store;
  final SharedPreferences _preferences;
  final PersonalRideHeatmapBuilder _builder;
  bool _visible;
  bool _loading = false;
  PersonalRideHeatmap _heatmap = PersonalRideHeatmap.empty;
  PersonalRideHeatmap? _viewportHeatmap;
  PersonalHeatmapBounds? _viewportBounds;
  List<CompletedRide> _rides = const [];
  int _refreshGeneration = 0;
  Listenable? _listenableStore;

  static Future<PersonalRideHeatmapController> load({
    required CompletedRideStore store,
    PersonalRideHeatmapBuilder builder = const PersonalRideHeatmapBuilder(),
  }) async {
    final preferences = await SharedPreferences.getInstance();
    final controller = PersonalRideHeatmapController._(
      store,
      preferences,
      builder,
      preferences.getBool(preferenceKey) ?? defaultVisible,
    );
    if (store case final Listenable listenable) {
      controller._listenableStore = listenable;
      listenable.addListener(controller._storeChanged);
    }
    // The derived cache also powers the independent circular-route preference;
    // visibility controls rendering only, never whether local coverage exists.
    await controller.refresh();
    return controller;
  }

  bool get visible => _visible;
  bool get loading => _loading;
  PersonalRideHeatmap get heatmap => _heatmap;
  PersonalRideHeatmap get visibleHeatmap => _viewportHeatmap ?? _heatmap;

  /// Restore street detail from original tracks as the viewport narrows. The
  /// padded area keeps coverage on screen during the next gesture; native and
  /// Flutter maps call this after camera movement, never on every GPS fix.
  void setViewport(List<GeoPoint> corners) {
    if (corners.length < 2) return;
    final west = corners.map((p) => p.longitude).reduce(math.min);
    final east = corners.map((p) => p.longitude).reduce(math.max);
    final south = corners.map((p) => p.latitude).reduce(math.min);
    final north = corners.map((p) => p.latitude).reduce(math.max);
    final dx = math.max(0.002, (east - west) / 2);
    final dy = math.max(0.002, (north - south) / 2);
    final bounds = (
      west: (west - dx).clamp(-180.0, 180.0),
      east: (east + dx).clamp(-180.0, 180.0),
      south: (south - dy).clamp(-85.0, 85.0),
      north: (north + dy).clamp(-85.0, 85.0),
    );
    if (bounds == _viewportBounds) return;
    _viewportBounds = bounds;
    _viewportHeatmap = _builder.build(_rides, bounds: bounds);
    notifyListeners();
  }

  Future<void> setVisible(bool visible) async {
    if (_visible == visible) return;
    _visible = visible;
    await _preferences.setBool(preferenceKey, visible);
    notifyListeners();
    if (visible) await refresh();
  }

  Future<void> refresh() async {
    final generation = ++_refreshGeneration;
    _loading = true;
    notifyListeners();
    try {
      final rides = await _store.list();
      final next = _builder.build(rides);
      if (generation != _refreshGeneration) return;
      _rides = rides;
      _heatmap = next;
      _viewportHeatmap = _viewportBounds == null
          ? null
          : _builder.build(rides, bounds: _viewportBounds);
    } finally {
      if (generation == _refreshGeneration) {
        _loading = false;
        notifyListeners();
      }
    }
  }

  void _storeChanged() {
    unawaited(_refreshAfterStoreChange());
  }

  Future<void> _refreshAfterStoreChange() async {
    try {
      await refresh();
    } on Object {
      // The archive owns its own error reporting. Keep the last valid derived
      // coverage rather than turning a delete/save notification into an
      // unhandled asynchronous error.
    }
  }

  @override
  void dispose() {
    _refreshGeneration += 1;
    _listenableStore?.removeListener(_storeChanged);
    super.dispose();
  }
}
