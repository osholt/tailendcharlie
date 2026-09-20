import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart' as vmt;
import 'package:vector_tile_renderer/vector_tile_renderer.dart' as vtr;

import '../../domain/imported_route.dart';
import '../../services/basemap_configuration.dart';
import '../../services/flutter_vector_style.dart';
import '../../services/preview_tile_readiness.dart';
import 'route_trail_style.dart';

const _routePreviewCameraInset = 30.0;
const _minimumRoutePreviewFitExtent = 24.0;
const _minimumRoutePreviewEndpointMarkerDiameter = 7.0;
const _maximumRoutePreviewEndpointMarkerDiameter = 18.0;

/// Keeps camera padding valid for both full previews and 52 px library icons.
///
/// A fixed 30 px inset consumes 60 px in each axis. That is comfortable on a
/// recap or route sheet, but leaves a small thumbnail with no area in which to
/// fit its route. Preserve the full inset whenever it fits and otherwise leave
/// at least [_minimumRoutePreviewFitExtent] for the complete track and its
/// endpoint markers.
@visibleForTesting
EdgeInsets routePreviewCameraPadding(Size viewportSize) {
  final shortestSide = math.min(viewportSize.width, viewportSize.height);
  if (!shortestSide.isFinite) {
    return const EdgeInsets.all(_routePreviewCameraInset);
  }
  final maximumInset = math.max(
    0.0,
    (shortestSide - _minimumRoutePreviewFitExtent) / 2,
  );
  return EdgeInsets.all(math.min(_routePreviewCameraInset, maximumInset));
}

/// Keeps endpoints legible without letting them cover a 52 px library image.
@visibleForTesting
double routePreviewEndpointMarkerDiameter(Size viewportSize) {
  final shortestSide = math.min(viewportSize.width, viewportSize.height);
  if (!shortestSide.isFinite || shortestSide <= 0) {
    return _maximumRoutePreviewEndpointMarkerDiameter;
  }
  return (shortestSide * 0.14).clamp(
    _minimumRoutePreviewEndpointMarkerDiameter,
    _maximumRoutePreviewEndpointMarkerDiameter,
  );
}

class _ResponsiveRoutePreviewCameraFit extends CameraFit {
  const _ResponsiveRoutePreviewCameraFit({required this.bounds, this.maxZoom});

  final LatLngBounds bounds;
  final double? maxZoom;

  @override
  MapCamera fit(MapCamera camera) => CameraFit.bounds(
    bounds: bounds,
    padding: routePreviewCameraPadding(camera.nonRotatedSize),
    maxZoom: maxZoom,
  ).fit(camera);
}

/// A capture-safe route map rendered entirely inside Flutter's layer tree.
///
/// Unlike MapLibre's native platform view, this widget is included by
/// `RepaintBoundary.toImage`, so the recap PNG contains the same basemap and
/// route the rider can see on screen (#157).
class FlutterVectorRoutePreview extends StatefulWidget {
  const FlutterVectorRoutePreview({
    super.key,
    required this.paths,
    required this.basemapConfiguration,
    this.interactive = true,
    this.onReady,
    this.onFailure,
    this.routeColour,
  });

  final List<List<GeoPoint>> paths;
  final BasemapConfiguration basemapConfiguration;
  final bool interactive;
  final VoidCallback? onReady;
  final ValueChanged<Object>? onFailure;
  final Color? routeColour;

  @override
  State<FlutterVectorRoutePreview> createState() =>
      _FlutterVectorRoutePreviewState();
}

class _FlutterVectorRoutePreviewState extends State<FlutterVectorRoutePreview> {
  static final Map<String, Future<vmt.Style>> _styleCache = {};
  late Future<vmt.Style> _style = _loadStyle();
  late PreviewTileReadiness _readiness = PreviewTileReadiness(
    onReady: () {
      if (mounted) widget.onReady?.call();
    },
  );
  bool _reportedFailure = false;

  List<LatLng> get _points => widget.paths
      .expand((path) => path)
      .map((point) => LatLng(point.latitude, point.longitude))
      .toList(growable: false);

  @override
  void didUpdateWidget(FlutterVectorRoutePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.basemapConfiguration.styleUrl !=
            widget.basemapConfiguration.styleUrl ||
        oldWidget.basemapConfiguration.restrainedLightStyle !=
            widget.basemapConfiguration.restrainedLightStyle) {
      _readiness.dispose();
      _readiness = PreviewTileReadiness(
        onReady: () {
          if (mounted) widget.onReady?.call();
        },
      );
      _reportedFailure = false;
      _style = _loadStyle();
    }
  }

  @override
  void dispose() {
    _readiness.dispose();
    super.dispose();
  }

  Future<vmt.Style> _loadStyle() {
    final configuration = widget.basemapConfiguration;
    final key =
        '${configuration.styleUrl}:${configuration.restrainedLightStyle}';
    final readiness = _readiness;
    return (_styleCache[key] ??= _readStyle(key, configuration)).then(
      (style) => vmt.Style(
        name: style.name,
        theme: style.theme,
        center: style.center,
        zoom: style.zoom,
        providers: vmt.TileProviders({
          for (final entry in style.providers.tileProviderBySource.entries)
            entry.key: _PreviewProvider(entry.value, readiness),
        }),
        sprites: style.sprites == null
            ? null
            : vmt.SpriteStyle(
                index: style.sprites!.index,
                atlasProvider: () =>
                    readiness.track(style.sprites!.atlasProvider, tile: false),
              ),
      ),
    );
  }

  static Future<vmt.Style> _readStyle(
    String key,
    BasemapConfiguration configuration,
  ) async {
    try {
      return await readFlutterVectorStyle(configuration);
    } on Object {
      _styleCache.remove(key);
      rethrow;
    }
  }

  void _mapReady() => _readiness.cameraReady();

  void _reportFailure(Object error) {
    if (_reportedFailure) return;
    _reportedFailure = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onFailure?.call(error);
    });
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<vmt.Style>(
    future: _style,
    builder: (context, snapshot) {
      final style = snapshot.data;
      if (style == null) {
        if (snapshot.hasError) {
          _reportFailure(snapshot.error!);
          return const SizedBox.shrink();
        }
        return const ColoredBox(
          color: Color(0xFF111820),
          child: Center(child: CircularProgressIndicator()),
        );
      }
      final points = _points;
      if (points.length < 2) return const SizedBox.shrink();
      return LayoutBuilder(
        builder: (context, constraints) {
          final markerDiameter = routePreviewEndpointMarkerDiameter(
            constraints.biggest,
          );
          final markerBorderWidth = markerDiameter < 12 ? 1.0 : 2.0;
          return FlutterMap(
            key: ValueKey(
              'flutter-vector-route-${widget.basemapConfiguration.styleUrl}',
            ),
            options: MapOptions(
              initialCameraFit: _ResponsiveRoutePreviewCameraFit(
                bounds: LatLngBounds.fromPoints(points),
                maxZoom: 16,
              ),
              initialCenter: points.first,
              initialZoom: 12,
              minZoom: 3,
              maxZoom: 18,
              interactionOptions: InteractionOptions(
                flags: widget.interactive
                    ? InteractiveFlag.all
                    : InteractiveFlag.none,
              ),
              onMapReady: _mapReady,
            ),
            children: [
              vmt.VectorTileLayer(
                tileProviders: style.providers,
                theme: style.theme,
                sprites: style.sprites,
                maximumZoom: 16,
                concurrency: widget.interactive ? 2 : 0,
                layerMode: widget.interactive
                    ? vmt.VectorTileLayerMode.raster
                    : vmt.VectorTileLayerMode.vector,
                fileCacheTtl: Duration.zero,
                fileCacheMaximumSizeInBytes: 0,
              ),
              PolylineLayer(
                polylines: [
                  for (final path in widget.paths)
                    if (path.length >= 2)
                      Polyline(
                        points: path
                            .map(
                              (point) =>
                                  LatLng(point.latitude, point.longitude),
                            )
                            .toList(growable: false),
                        color:
                            widget.routeColour ??
                            RouteTrailStyle.routeAhead.color,
                        strokeWidth: RouteTrailStyle.routeAhead.widthPixels,
                        borderColor: RouteTrailStyle.casing,
                        borderStrokeWidth:
                            RouteTrailStyle.routeAhead.casingWidthPixels -
                            RouteTrailStyle.routeAhead.widthPixels,
                      ),
                ],
              ),
              MarkerLayer(
                markers: [
                  Marker(
                    point: points.first,
                    width: markerDiameter,
                    height: markerDiameter,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                        border: Border.fromBorderSide(
                          BorderSide(
                            color: RouteTrailStyle.casing,
                            width: markerBorderWidth,
                          ),
                        ),
                      ),
                    ),
                  ),
                  Marker(
                    point: points.last,
                    width: markerDiameter,
                    height: markerDiameter,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFC857),
                        shape: BoxShape.circle,
                        border: Border.fromBorderSide(
                          BorderSide(
                            color: RouteTrailStyle.casing,
                            width: markerBorderWidth,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          );
        },
      );
    },
  );
}

class _PreviewProvider extends vmt.VectorTileProvider {
  _PreviewProvider(this.delegate, this.readiness);
  final vmt.VectorTileProvider delegate;
  final PreviewTileReadiness readiness;
  @override
  Future<Uint8List> provide(vmt.TileIdentity tile) => readiness.track(() async {
    final bytes = await delegate.provide(tile);
    if (delegate.type == vmt.TileProviderType.vector) {
      vtr.VectorTileReader().read(bytes);
    }
    return bytes;
  });
  @override
  int get maximumZoom => delegate.maximumZoom;
  @override
  int get minimumZoom => delegate.minimumZoom;
  @override
  vmt.TileOffset get tileOffset => delegate.tileOffset;
  @override
  vmt.TileProviderType get type => delegate.type;
}
