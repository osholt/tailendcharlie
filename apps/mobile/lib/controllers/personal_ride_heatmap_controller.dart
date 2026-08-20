import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/completed_ride.dart';
import '../domain/completed_ride_store.dart';
import '../domain/imported_route.dart';

/// One bounded z17 cell in the private, on-device archive heatmap.
class PersonalRideHeatmapCell {
  const PersonalRideHeatmapCell({
    required this.x,
    required this.y,
    required this.visits,
    required this.weight,
  });

  final int x;
  final int y;
  final int visits;

  /// Log-scaled 0..1 intensity so one very familiar road does not flatten all
  /// the other roads to the same faint colour.
  final double weight;

  GeoPoint get centre {
    const zoom = PersonalRideHeatmapBuilder.canonicalZoom;
    final scale = 1 << zoom;
    final longitude = (x + 0.5) / scale * 360 - 180;
    final mercator = math.pi * (1 - 2 * (y + 0.5) / scale);
    final sinh = (math.exp(mercator) - math.exp(-mercator)) / 2;
    final latitude = math.atan(sinh) * 180 / math.pi;
    return GeoPoint(latitude: latitude, longitude: longitude);
  }
}

/// Derived local coverage. It contains no ride identity, time, speed or plan.
class PersonalRideHeatmap {
  const PersonalRideHeatmap({
    required this.cells,
    required this.inputPointCount,
    required this.truncated,
  });

  static const empty = PersonalRideHeatmap(
    cells: [],
    inputPointCount: 0,
    truncated: false,
  );

  final List<PersonalRideHeatmapCell> cells;
  final int inputPointCount;
  final bool truncated;

  Map<String, dynamic> toGeoJson() => {
    'type': 'FeatureCollection',
    'features': [
      for (final cell in cells)
        {
          'type': 'Feature',
          'id': 'personal-${cell.x}-${cell.y}',
          'properties': {'visits': cell.visits, 'weight': cell.weight},
          'geometry': {
            'type': 'Point',
            'coordinates': [cell.centre.longitude, cell.centre.latitude],
          },
        },
    ],
  };
}

/// Turns only travelled track segments into a fixed-size spatial index.
///
/// Tiling is the rendering bound: 100,000 archived GPS fixes do not become
/// 100,000 widgets or MapLibre features. Gaps remain gaps because each track
/// path is rasterised independently, while sparse fixes cannot skip cells.
class PersonalRideHeatmapBuilder {
  const PersonalRideHeatmapBuilder({this.maximumCells = 20000});

  static const canonicalZoom = 17;
  static const _maximumMercatorLatitude = 85.05112878;

  final int maximumCells;

  PersonalRideHeatmap build(Iterable<CompletedRide> rides) {
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
        for (var index = 1; index < path.points.length; index += 1) {
          for (final cell in _cellsBetween(
            path.points[index - 1],
            path.points[index],
          )) {
            if (cell == previousCell) continue;
            previousCell = cell;
            if (!visits.containsKey(cell) && visits.length >= maximumCells) {
              truncated = true;
              continue;
            }
            visits.update(cell, (value) => value + 1, ifAbsent: () => 1);
          }
        }
      }
    }
    if (visits.isEmpty) {
      return PersonalRideHeatmap(
        cells: const [],
        inputPointCount: inputPointCount,
        truncated: truncated,
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
    );
  }

  Iterable<(int x, int y)> _cellsBetween(GeoPoint start, GeoPoint end) sync* {
    final a = _tileCoordinate(start);
    final b = _tileCoordinate(end);
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

  ({double x, double y}) _tileCoordinate(GeoPoint point) {
    final scale = (1 << canonicalZoom).toDouble();
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
      _heatmap = next;
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
