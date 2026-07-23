import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as ml;

import '../../domain/imported_route.dart';
import '../../services/basemap_configuration.dart';
import '../../services/map_style_repository.dart';

class RoutePreviewPin {
  const RoutePreviewPin({required this.point, required this.kind});

  final GeoPoint point;
  final String kind;
}

/// A small MapLibre route canvas for review/recording surfaces that do not own
/// the app's main map dependencies. It resolves and normalises the remote style
/// before mounting MapLibre, matching the production ride map.
class ResolvedRouteMapPreview extends StatefulWidget {
  const ResolvedRouteMapPreview({
    super.key,
    required this.paths,
    required this.basemapConfiguration,
    this.pins = const [],
    this.mapStyleString,
    this.lineColor = '#3478F6',
    this.onPointTap,
  });

  final List<List<GeoPoint>> paths;
  final List<RoutePreviewPin> pins;
  final BasemapConfiguration basemapConfiguration;
  final String? mapStyleString;
  final String lineColor;
  final ValueChanged<int>? onPointTap;

  @override
  State<ResolvedRouteMapPreview> createState() =>
      _ResolvedRouteMapPreviewState();
}

class _ResolvedRouteMapPreviewState extends State<ResolvedRouteMapPreview> {
  static const _routeSource = 'route-preview-lines';
  static const _pinSource = 'route-preview-pins';
  ml.MapLibreMapController? _controller;
  bool _styleReady = false;
  bool _syncing = false;
  bool _syncAgain = false;
  late final Future<String> _style = _resolveStyle();

  List<GeoPoint> get _points =>
      widget.paths.expand((path) => path).toList(growable: false);

  @override
  void didUpdateWidget(ResolvedRouteMapPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_styleReady) unawaited(_syncAndFit());
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
                onMapCreated: (controller) => _controller = controller,
                onStyleLoadedCallback: () => unawaited(_prepareStyle()),
                onMapClick: widget.onPointTap == null
                    ? null
                    : (point, _) => unawaited(_handlePointTap(point)),
                featureTapsTriggersMapClick: true,
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
      return await repository.resolve();
    } finally {
      repository.dispose();
    }
  }

  Future<void> _prepareStyle() async {
    final controller = _controller;
    if (controller == null) return;
    _styleReady = false;
    try {
      await controller.addGeoJsonSource(_routeSource, _routeGeoJson());
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
              'start',
            ],
            7,
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
            '#FFC857',
          ],
          circleStrokeColor: '#10151C',
          circleStrokeWidth: 2,
        ),
        enableInteraction: false,
      );
      _styleReady = true;
      await _syncAndFit();
    } on Object catch (error) {
      if (kDebugMode) debugPrint('Could not prepare route preview map: $error');
    }
  }

  Future<void> _syncAndFit() async {
    if (_syncing) {
      _syncAgain = true;
      return;
    }
    final controller = _controller;
    if (!_styleReady || controller == null) return;
    _syncing = true;
    try {
      await controller.setGeoJsonSource(_routeSource, _routeGeoJson());
      await controller.setGeoJsonSource(_pinSource, _pinGeoJson());
      await _fit();
    } on Object catch (error) {
      if (kDebugMode) debugPrint('Could not refresh route preview map: $error');
    } finally {
      _syncing = false;
      if (_syncAgain) {
        _syncAgain = false;
        unawaited(_syncAndFit());
      }
    }
  }

  Future<void> _fit() async {
    final controller = _controller;
    final points = _points;
    if (controller == null || points.isEmpty) return;
    if (points.length == 1) {
      await controller.animateCamera(
        ml.CameraUpdate.newLatLngZoom(
          ml.LatLng(points.single.latitude, points.single.longitude),
          15,
        ),
      );
      return;
    }
    await controller.animateCamera(
      ml.CameraUpdate.newLatLngBounds(
        routePreviewBounds(points),
        left: 34,
        top: 34,
        right: 34,
        bottom: 34,
      ),
      duration: const Duration(milliseconds: 350),
    );
  }

  Future<void> _handlePointTap(math.Point<double> tap) async {
    final callback = widget.onPointTap;
    final controller = _controller;
    final points = _points;
    if (callback == null || controller == null || points.length <= 2) return;
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

  Map<String, dynamic> _routeGeoJson() => {
    'type': 'FeatureCollection',
    'features': [
      for (final path in widget.paths)
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
            'properties': {'kind': pin.kind},
            'geometry': {
              'type': 'Point',
              'coordinates': [pin.point.longitude, pin.point.latitude],
            },
          },
      ],
    };
  }
}

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
