import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as ml;

import 'map_camera_guard.dart';

import '../../domain/imported_route.dart';
import '../../services/basemap_configuration.dart';
import '../../services/map_style_repository.dart';

/// Lets a map embedded in a scrollable screen claim a drag that starts on the
/// map. Without this, the surrounding list wins vertical pans and the map feels
/// intermittently frozen.
final embeddedMapGestureRecognizers = <Factory<OneSequenceGestureRecognizer>>{
  Factory<EagerGestureRecognizer>(EagerGestureRecognizer.new),
};

class RoutePreviewPin {
  const RoutePreviewPin({
    required this.point,
    required this.kind,
    this.id,
    this.label,
    this.interactive = false,
    this.includeInFraming = true,
  });

  final GeoPoint point;
  final String kind;
  final String? id;
  final String? label;
  final bool interactive;
  final bool includeInFraming;
}

class RoutePreviewReshapeStart {
  const RoutePreviewReshapeStart({required this.point, this.shapingPointIndex});

  final GeoPoint point;

  /// Null when the drag began on the route line and should create a new
  /// shaping point. Otherwise this is the index among pins whose kind is
  /// `shape`.
  final int? shapingPointIndex;
}

/// A small MapLibre route canvas for review/recording surfaces that do not own
/// the app's main map dependencies. It resolves and normalises the remote style
/// before mounting MapLibre, matching the production ride map.
class ResolvedRouteMapPreview extends StatefulWidget {
  const ResolvedRouteMapPreview({
    super.key,
    required this.paths,
    required this.basemapConfiguration,
    this.referencePaths = const [],
    this.pins = const [],
    this.mapStyleString,
    this.lineColor = '#3478F6',
    this.onPointTap,
    this.onPinTap,
    this.onControllerReady,
    this.onStyleReady,
    this.reshapeEnabled = false,
    this.onReshapeStart,
    this.onReshapeUpdate,
    this.onReshapeEnd,
  });

  final List<List<GeoPoint>> paths;
  final List<List<GeoPoint>> referencePaths;
  final List<RoutePreviewPin> pins;
  final BasemapConfiguration basemapConfiguration;
  final String? mapStyleString;
  final String lineColor;
  final ValueChanged<int>? onPointTap;
  final ValueChanged<RoutePreviewPin>? onPinTap;
  final bool reshapeEnabled;
  final ValueChanged<RoutePreviewReshapeStart>? onReshapeStart;
  final ValueChanged<GeoPoint>? onReshapeUpdate;
  final VoidCallback? onReshapeEnd;

  /// Handed the map's controller once created, so a caller can snapshot it.
  /// Exposed for the recap export, which needs MapLibre's own snapshot because
  /// `RepaintBoundary.toImage` cannot capture a platform view (#157).
  final ValueChanged<ml.MapLibreMapController>? onControllerReady;

  /// Called once the style and this route's layers are on the map. A snapshot
  /// taken before this returns tiles that have not arrived.
  final VoidCallback? onStyleReady;

  @override
  State<ResolvedRouteMapPreview> createState() =>
      _ResolvedRouteMapPreviewState();
}

class _ResolvedRouteMapPreviewState extends State<ResolvedRouteMapPreview> {
  static const _routeSource = 'route-preview-lines';
  static const _referenceRouteSource = 'route-preview-reference-lines';
  static const _pinSource = 'route-preview-pins';
  ml.MapLibreMapController? _controller;
  bool _styleReady = false;
  bool _syncing = false;
  bool _syncAgain = false;
  bool _syncAgainShouldFit = false;
  Future<void>? _reshapeStartFuture;
  int _reshapeGesture = 0;
  int _reshapeUpdate = 0;
  bool _reshapeAccepted = false;
  Offset? _latestReshapePosition;
  late final Future<String> _style = _resolveStyle();

  List<GeoPoint> get _points => routePreviewFramingPoints([
    ...widget.referencePaths,
    ...widget.paths,
  ], widget.pins);

  double get _platformPixelScale => previewPlatformPixelScale(
    platform: defaultTargetPlatform,
    devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
  );

  math.Point<double> _platformPoint(Offset position) => math.Point<double>(
    position.dx * _platformPixelScale,
    position.dy * _platformPixelScale,
  );

  @override
  void didUpdateWidget(ResolvedRouteMapPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Parent state changes such as pressing Share used to re-fit the route here,
    // discarding the framing the rider had just chosen before the snapshot.
    if (_styleReady &&
        (!_samePreviewPaths(oldWidget.paths, widget.paths) ||
            !_samePreviewPaths(
              oldWidget.referencePaths,
              widget.referencePaths,
            ) ||
            !_samePreviewPins(oldWidget.pins, widget.pins))) {
      unawaited(_syncAndFit(fit: !widget.reshapeEnabled));
    }
  }

  @override
  Widget build(BuildContext context) {
    final points = _points;
    final initial = points.firstOrNull;
    return FutureBuilder<String>(
      future: _style,
      builder: (context, snapshot) {
        final style = snapshot.data;
        if (style == null) {
          return const ColoredBox(
            color: Color(0xFF111820),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        return Stack(
          children: [
            Positioned.fill(
              child: ml.MapLibreMap(
                key: const Key('resolved-route-map-preview'),
                styleString: style,
                initialCameraPosition: ml.CameraPosition(
                  target: ml.LatLng(
                    initial?.latitude ?? 54.5,
                    initial?.longitude ?? -3.2,
                  ),
                  zoom: initial == null ? 5 : 13,
                ),
                onMapCreated: (controller) {
                  _controller = controller;
                  widget.onControllerReady?.call(controller);
                },
                onStyleLoadedCallback: () => unawaited(_prepareStyle()),
                onMapClick: widget.onPointTap == null && widget.onPinTap == null
                    ? null
                    : (point, _) => unawaited(_handlePointTap(point)),
                featureTapsTriggersMapClick: true,
                gestureRecognizers: embeddedMapGestureRecognizers,
                logoEnabled: false,
                compassEnabled: true,
                minMaxZoomPreference: ml.MinMaxZoomPreference(
                  3,
                  widget.basemapConfiguration.maximumNativeZoom.toDouble(),
                ),
              ),
            ),
            const Positioned(
              right: 5,
              bottom: 4,
              child: DecoratedBox(
                decoration: BoxDecoration(color: Color(0xB3000000)),
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: Text(
                    'OpenFreeMap · © OSM',
                    style: TextStyle(color: Colors.white, fontSize: 7),
                  ),
                ),
              ),
            ),
            if (widget.reshapeEnabled)
              Positioned.fill(
                child: GestureDetector(
                  key: const Key('route-preview-reshape-surface'),
                  behavior: HitTestBehavior.opaque,
                  onPanStart: _beginReshape,
                  onPanUpdate: _updateReshape,
                  onPanEnd: (_) => _endReshape(),
                  onPanCancel: _endReshape,
                  onTapUp: (details) => unawaited(
                    _handlePointTap(_platformPoint(details.localPosition)),
                  ),
                ),
              ),
            Positioned(
              left: 8,
              top: 8,
              child: Material(
                color: const Color(0xD9182029),
                shape: const CircleBorder(),
                child: IconButton(
                  key: const Key('route-preview-fit-route'),
                  tooltip: 'Fit the whole route',
                  onPressed: _fit,
                  color: Colors.white,
                  icon: const Icon(Icons.fit_screen),
                ),
              ),
            ),
            if (widget.referencePaths.isNotEmpty)
              const Positioned(
                right: 8,
                top: 8,
                child: _RouteComparisonLegend(),
              ),
            if (widget.reshapeEnabled)
              const Positioned(
                left: 58,
                right: 58,
                bottom: 10,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Color(0xE61A2029),
                      borderRadius: BorderRadius.all(Radius.circular(18)),
                    ),
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 7,
                      ),
                      child: Text(
                        'Drag the route or a purple handle · exit Reshape to pan',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white, fontSize: 12),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Future<String> _resolveStyle() async {
    final supplied = widget.mapStyleString;
    if (supplied != null) return supplied;
    final repository = await MapStyleRepository.openDefault(
      widget.basemapConfiguration,
    );
    try {
      // A still preview of a route, not the live ride map: it has no chrome to
      // report a basemap failure through, so the outcome is dropped here
      // deliberately rather than by omission (#281).
      return (await repository.resolve()).style;
    } finally {
      repository.dispose();
    }
  }

  Future<void> _prepareStyle() async {
    final controller = _controller;
    if (controller == null) return;
    _styleReady = false;
    try {
      await controller.addGeoJsonSource(
        _referenceRouteSource,
        _routeGeoJson(widget.referencePaths),
      );
      await controller.addLineLayer(
        _referenceRouteSource,
        'route-preview-reference-line',
        const ml.LineLayerProperties(
          lineColor: '#B8C0CC',
          lineWidth: 5,
          lineOpacity: 0.9,
          lineDasharray: [2, 2],
          lineCap: 'round',
          lineJoin: 'round',
        ),
        enableInteraction: false,
      );
      await controller.addGeoJsonSource(
        _routeSource,
        _routeGeoJson(widget.paths),
      );
      await controller.addLineLayer(
        _routeSource,
        'route-preview-border',
        const ml.LineLayerProperties(
          lineColor: '#10151C',
          lineWidth: 8,
          lineCap: 'round',
          lineJoin: 'round',
        ),
        enableInteraction: false,
      );
      await controller.addLineLayer(
        _routeSource,
        'route-preview-line',
        ml.LineLayerProperties(
          lineColor: widget.lineColor,
          lineWidth: 5,
          lineCap: 'round',
          lineJoin: 'round',
        ),
        enableInteraction: false,
      );
      await controller.addGeoJsonSource(_pinSource, _pinGeoJson());
      await controller.addCircleLayer(
        _pinSource,
        'route-preview-points',
        const ml.CircleLayerProperties(
          circleRadius: [
            'case',
            [
              '==',
              ['get', 'kind'],
              'poi',
            ],
            7,
            [
              '==',
              ['get', 'kind'],
              'safety',
            ],
            8,
            6,
          ],
          circleColor: [
            'case',
            [
              '==',
              ['get', 'kind'],
              'start',
            ],
            '#FFFFFF',
            [
              '==',
              ['get', 'kind'],
              'marker',
            ],
            '#6ED89A',
            [
              '==',
              ['get', 'kind'],
              'safety',
            ],
            '#FF8A4C',
            [
              '==',
              ['get', 'kind'],
              'muster',
            ],
            '#68A9FF',
            [
              '==',
              ['get', 'kind'],
              'shape',
            ],
            '#B37CFF',
            [
              '==',
              ['get', 'kind'],
              'poi',
            ],
            '#F97316',
            '#FFC857',
          ],
          circleStrokeColor: '#10151C',
          circleStrokeWidth: 2,
        ),
        enableInteraction: false,
      );
      _styleReady = true;
      await _syncAndFit();
      // After the fit, so a snapshot taken on this signal frames the route
      // rather than wherever the camera started (#157).
      widget.onStyleReady?.call();
    } on Object catch (error) {
      if (kDebugMode) debugPrint('Could not prepare route preview map: $error');
    }
  }

  Future<void> _syncAndFit({bool fit = true}) async {
    if (_syncing) {
      _syncAgain = true;
      _syncAgainShouldFit = _syncAgainShouldFit || fit;
      return;
    }
    final controller = _controller;
    if (!_styleReady || controller == null) return;
    _syncing = true;
    try {
      await controller.setGeoJsonSource(
        _referenceRouteSource,
        _routeGeoJson(widget.referencePaths),
      );
      await controller.setGeoJsonSource(
        _routeSource,
        _routeGeoJson(widget.paths),
      );
      await controller.setGeoJsonSource(_pinSource, _pinGeoJson());
      if (fit) await _fit();
    } on Object catch (error) {
      if (kDebugMode) debugPrint('Could not refresh route preview map: $error');
    } finally {
      _syncing = false;
      if (_syncAgain) {
        _syncAgain = false;
        final shouldFit = _syncAgainShouldFit;
        _syncAgainShouldFit = false;
        unawaited(_syncAndFit(fit: shouldFit));
      }
    }
  }

  Future<void> _fit() async {
    final controller = _controller;
    final points = _points;
    if (controller == null || points.isEmpty) return;
    if (points.length == 1) {
      final only = ml.LatLng(points.single.latitude, points.single.longitude);
      if (!mapLibreCameraIsUsable(only, zoom: 15)) return;
      await controller.animateCamera(ml.CameraUpdate.newLatLngZoom(only, 15));
      return;
    }
    final bounds = routePreviewBounds(points);
    if (!bounds.isUsableCamera) return;
    await controller.animateCamera(
      ml.CameraUpdate.newLatLngBounds(
        bounds,
        left: 34,
        top: 34,
        right: 34,
        bottom: 34,
      ),
      duration: const Duration(milliseconds: 350),
    );
  }

  Future<void> _handlePointTap(math.Point<double> tap) async {
    final controller = _controller;
    if (controller == null) return;

    final pinCallback = widget.onPinTap;
    final interactivePins = widget.pins
        .where((pin) => pin.interactive)
        .toList(growable: false);
    if (pinCallback != null && interactivePins.isNotEmpty) {
      final screens = await controller.toScreenLocationBatch(
        interactivePins.map(
          (pin) => ml.LatLng(pin.point.latitude, pin.point.longitude),
        ),
      );
      var closest = -1;
      var closestDistance = double.infinity;
      for (var index = 0; index < screens.length; index += 1) {
        final distance = _screenDistance(tap, screens[index]);
        if (distance < closestDistance) {
          closest = index;
          closestDistance = distance;
        }
      }
      if (closest >= 0 && closestDistance <= 36 * _platformPixelScale) {
        pinCallback(interactivePins[closest]);
        return;
      }
    }

    final callback = widget.onPointTap;
    final points = _points;
    if (callback == null || points.length <= 2) return;
    final screenPoints = await controller.toScreenLocationBatch(
      points.map((point) => ml.LatLng(point.latitude, point.longitude)),
    );
    var closest = -1;
    var closestDistance = double.infinity;
    for (var index = 0; index < screenPoints.length; index += 1) {
      final candidate = screenPoints[index];
      final dx = candidate.x - tap.x;
      final dy = candidate.y - tap.y;
      final distance = math.sqrt(dx * dx + dy * dy);
      if (distance < closestDistance) {
        closest = index;
        closestDistance = distance;
      }
    }
    if (closest >= 0 && closestDistance <= 30) callback(closest);
  }

  void _beginReshape(DragStartDetails details) {
    final gesture = ++_reshapeGesture;
    _reshapeUpdate += 1;
    _reshapeAccepted = false;
    _latestReshapePosition = details.localPosition;
    _reshapeStartFuture = _resolveReshapeStart(details.localPosition, gesture);
  }

  Future<void> _resolveReshapeStart(Offset localPosition, int gesture) async {
    final controller = _controller;
    final callback = widget.onReshapeStart;
    if (controller == null || callback == null) return;
    final tap = _platformPoint(localPosition);
    final shapePins = widget.pins
        .where((pin) => pin.kind == 'shape')
        .toList(growable: false);
    int? shapeIndex;
    if (shapePins.isNotEmpty) {
      final screens = await controller.toScreenLocationBatch(
        shapePins.map(
          (pin) => ml.LatLng(pin.point.latitude, pin.point.longitude),
        ),
      );
      var closestDistance = double.infinity;
      for (var index = 0; index < screens.length; index += 1) {
        final distance = _screenDistance(tap, screens[index]);
        if (distance < closestDistance) {
          closestDistance = distance;
          shapeIndex = index;
        }
      }
      if (closestDistance > 32 * _platformPixelScale) shapeIndex = null;
    }
    if (shapeIndex == null && !await _tapIsNearRoute(controller, tap)) return;
    final location = await controller.toLatLng(tap);
    if (gesture != _reshapeGesture) return;
    _reshapeAccepted = true;
    callback(
      RoutePreviewReshapeStart(
        point: GeoPoint(
          latitude: location.latitude,
          longitude: location.longitude,
        ),
        shapingPointIndex: shapeIndex,
      ),
    );
  }

  void _updateReshape(DragUpdateDetails details) {
    final gesture = _reshapeGesture;
    final update = ++_reshapeUpdate;
    _latestReshapePosition = details.localPosition;
    unawaited(_resolveReshapeUpdate(details.localPosition, gesture, update));
  }

  Future<void> _resolveReshapeUpdate(
    Offset localPosition,
    int gesture,
    int update,
  ) async {
    await _reshapeStartFuture;
    final controller = _controller;
    final callback = widget.onReshapeUpdate;
    if (!_reshapeAccepted ||
        controller == null ||
        callback == null ||
        gesture != _reshapeGesture ||
        update != _reshapeUpdate) {
      return;
    }
    final location = await controller.toLatLng(_platformPoint(localPosition));
    if (gesture != _reshapeGesture || update != _reshapeUpdate) return;
    callback(
      GeoPoint(latitude: location.latitude, longitude: location.longitude),
    );
  }

  void _endReshape() {
    final gesture = _reshapeGesture;
    final update = ++_reshapeUpdate;
    unawaited(_resolveReshapeEnd(gesture, update, _latestReshapePosition));
  }

  Future<void> _resolveReshapeEnd(
    int gesture,
    int update,
    Offset? localPosition,
  ) async {
    await _reshapeStartFuture;
    if (gesture != _reshapeGesture || !_reshapeAccepted) return;
    if (localPosition != null) {
      await _resolveReshapeUpdate(localPosition, gesture, update);
    }
    if (gesture != _reshapeGesture || update != _reshapeUpdate) return;
    _reshapeAccepted = false;
    _latestReshapePosition = null;
    widget.onReshapeEnd?.call();
  }

  Future<bool> _tapIsNearRoute(
    ml.MapLibreMapController controller,
    math.Point<double> tap,
  ) async {
    for (final path in widget.paths) {
      if (path.length < 2) continue;
      final screens = await controller.toScreenLocationBatch(
        path.map((point) => ml.LatLng(point.latitude, point.longitude)),
      );
      for (var index = 1; index < screens.length; index += 1) {
        if (_pointToSegmentDistance(tap, screens[index - 1], screens[index]) <=
            28 * _platformPixelScale) {
          return true;
        }
      }
    }
    return false;
  }

  Map<String, dynamic> _routeGeoJson(List<List<GeoPoint>> paths) => {
    'type': 'FeatureCollection',
    'features': [
      for (final path in paths)
        if (path.length >= 2)
          {
            'type': 'Feature',
            'properties': const <String, dynamic>{},
            'geometry': {
              'type': 'LineString',
              'coordinates': [
                for (final point in path) [point.longitude, point.latitude],
              ],
            },
          },
    ],
  };

  Map<String, dynamic> _pinGeoJson() {
    final pins = widget.pins.isNotEmpty
        ? widget.pins
        : switch (_points) {
            [] => const <RoutePreviewPin>[],
            [final point] => [RoutePreviewPin(point: point, kind: 'start')],
            final points => [
              RoutePreviewPin(point: points.first, kind: 'start'),
              RoutePreviewPin(point: points.last, kind: 'finish'),
            ],
          };
    return {
      'type': 'FeatureCollection',
      'features': [
        for (final pin in pins)
          {
            'type': 'Feature',
            'properties': {
              'kind': pin.kind,
              if (pin.id != null) 'id': pin.id,
              if (pin.label != null) 'label': pin.label,
            },
            'geometry': {
              'type': 'Point',
              'coordinates': [pin.point.longitude, pin.point.latitude],
            },
          },
      ],
    };
  }
}

class _RouteComparisonLegend extends StatelessWidget {
  const _RouteComparisonLegend();

  @override
  Widget build(BuildContext context) => const IgnorePointer(
    child: DecoratedBox(
      key: Key('route-comparison-legend'),
      decoration: BoxDecoration(
        color: Color(0xE61A2029),
        borderRadius: BorderRadius.all(Radius.circular(8)),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 9, vertical: 7),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _RouteLegendRow(color: Color(0xFF3478F6), label: 'Navigable'),
            SizedBox(height: 4),
            _RouteLegendRow(color: Color(0xFFB8C0CC), label: 'Original'),
          ],
        ),
      ),
    ),
  );
}

class _RouteLegendRow extends StatelessWidget {
  const _RouteLegendRow({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(width: 20, height: 3, color: color),
      const SizedBox(width: 6),
      Text(label, style: const TextStyle(color: Colors.white, fontSize: 11)),
    ],
  );
}

/// MapLibre Android reports and accepts native-view pixels, while Flutter
/// gestures arrive in logical pixels. iOS uses points for both. Comparing the
/// two coordinate spaces made every Android drag look far away from the route,
/// so reshaping never began on physical Android devices (#242).
@visibleForTesting
double previewPlatformPixelScale({
  required TargetPlatform platform,
  required double devicePixelRatio,
}) => platform == TargetPlatform.android ? devicePixelRatio : 1;

double _screenDistance(math.Point<num> first, math.Point<num> second) {
  final dx = first.x - second.x;
  final dy = first.y - second.y;
  return math.sqrt(dx * dx + dy * dy);
}

double _pointToSegmentDistance(
  math.Point<num> point,
  math.Point<num> start,
  math.Point<num> end,
) {
  final dx = end.x - start.x;
  final dy = end.y - start.y;
  if (dx == 0 && dy == 0) return _screenDistance(point, start);
  final position =
      (((point.x - start.x) * dx + (point.y - start.y) * dy) /
              (dx * dx + dy * dy))
          .clamp(0.0, 1.0);
  return _screenDistance(
    point,
    math.Point(start.x + position * dx, start.y + position * dy),
  );
}

bool _samePreviewPaths(
  List<List<GeoPoint>> first,
  List<List<GeoPoint>> second,
) {
  if (first.length != second.length) return false;
  for (var pathIndex = 0; pathIndex < first.length; pathIndex += 1) {
    final firstPath = first[pathIndex];
    final secondPath = second[pathIndex];
    if (firstPath.length != secondPath.length) return false;
    for (var pointIndex = 0; pointIndex < firstPath.length; pointIndex += 1) {
      if (!_samePoint(firstPath[pointIndex], secondPath[pointIndex])) {
        return false;
      }
    }
  }
  return true;
}

bool _samePreviewPins(
  List<RoutePreviewPin> first,
  List<RoutePreviewPin> second,
) {
  if (first.length != second.length) return false;
  for (var index = 0; index < first.length; index += 1) {
    if (first[index].kind != second[index].kind ||
        first[index].id != second[index].id ||
        first[index].label != second[index].label ||
        first[index].interactive != second[index].interactive ||
        first[index].includeInFraming != second[index].includeInFraming ||
        !_samePoint(first[index].point, second[index].point)) {
      return false;
    }
  }
  return true;
}

bool _samePoint(GeoPoint first, GeoPoint second) =>
    first.latitude == second.latitude && first.longitude == second.longitude;

@visibleForTesting
List<GeoPoint> routePreviewFramingPoints(
  List<List<GeoPoint>> paths,
  List<RoutePreviewPin> pins,
) => List.unmodifiable([
  ...paths.expand((path) => path),
  ...pins.where((pin) => pin.includeInFraming).map((pin) => pin.point),
]);

@visibleForTesting
ml.LatLngBounds routePreviewBounds(List<GeoPoint> points) {
  if (points.isEmpty) {
    throw ArgumentError.value(points, 'points', 'Must not be empty');
  }
  var south = points.first.latitude;
  var north = points.first.latitude;
  var west = points.first.longitude;
  var east = points.first.longitude;
  for (final point in points.skip(1)) {
    south = math.min(south, point.latitude);
    north = math.max(north, point.latitude);
    west = math.min(west, point.longitude);
    east = math.max(east, point.longitude);
  }
  return ml.LatLngBounds(
    southwest: ml.LatLng(south, west),
    northeast: ml.LatLng(north, east),
  );
}
