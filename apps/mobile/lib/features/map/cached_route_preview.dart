import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../domain/imported_route.dart';
import '../../services/basemap_configuration.dart';
import '../../services/route_preview_cache.dart';
import 'flutter_vector_route_preview.dart';

class CachedRoutePreview extends StatelessWidget {
  const CachedRoutePreview({
    super.key,
    required this.paths,
    required this.configuration,
    required this.colour,
    required this.fallback,
    this.cache,
  });
  final List<List<GeoPoint>> paths;
  final BasemapConfiguration configuration;
  final Color colour;
  final Widget fallback;
  final RoutePreviewCache? cache;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final size = constraints.biggest;
      if (!size.isFinite || size.isEmpty) return fallback;
      final pixelRatio = MediaQuery.devicePixelRatioOf(context).clamp(1.0, 2.0);
      final identity = RoutePreviewCache.key(
        paths: paths,
        configuration: configuration,
        colourArgb: colour.toARGB32(),
        width: size.width.ceil(),
        height: size.height.ceil(),
        pixelRatio: pixelRatio,
      );
      return _CachedImage(
        key: ValueKey(identity),
        identity: identity,
        paths: paths,
        configuration: configuration,
        colour: colour,
        fallback: fallback,
        pixelRatio: pixelRatio,
        cache: cache,
      );
    },
  );
}

class _CachedImage extends StatefulWidget {
  const _CachedImage({
    super.key,
    required this.identity,
    required this.paths,
    required this.configuration,
    required this.colour,
    required this.fallback,
    required this.pixelRatio,
    this.cache,
  });
  final String identity;
  final List<List<GeoPoint>> paths;
  final BasemapConfiguration configuration;
  final Color colour;
  final Widget fallback;
  final double pixelRatio;
  final RoutePreviewCache? cache;
  @override
  State<_CachedImage> createState() => _CachedImageState();
}

class _CachedImageState extends State<_CachedImage> {
  final _boundary = GlobalKey();
  RoutePreviewCache? _cache;
  Uint8List? _bytes;
  bool _checked = false, _capturing = false;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    Uint8List? bytes;
    try {
      _cache =
          widget.cache ??
          await RoutePreviewCache.openDefault().timeout(
            const Duration(seconds: 2),
          );
      bytes = await _cache!
          .read(widget.identity)
          .timeout(const Duration(seconds: 2));
    } on Object {
      /* Fall back to a live preview when storage is unavailable. */
    }
    if (mounted) {
      setState(() {
        _bytes = bytes;
        _checked = true;
      });
    }
  }

  Future<void> _capture() async {
    if (_capturing || _cache == null || !mounted) return;
    _capturing = true;
    try {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      final boundary = _boundary.currentContext?.findRenderObject();
      if (boundary is! RenderRepaintBoundary ||
          boundary.debugNeedsPaint ||
          boundary.size.isEmpty) {
        return;
      }
      final image = await boundary.toImage(pixelRatio: widget.pixelRatio);
      Uint8List? bytes;
      try {
        bytes = (await image.toByteData(
          format: ui.ImageByteFormat.png,
        ))?.buffer.asUint8List();
      } finally {
        image.dispose();
      }
      if (bytes == null) return;
      await _cache!.save(widget.identity, bytes);
      if (mounted) setState(() => _bytes = bytes);
    } on Object {
      /* A thumbnail is never a reason to fail the library. */
    } finally {
      _capturing = false;
    }
  }

  void _corrupt() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_cache?.remove(widget.identity).catchError((Object _) {}));
      setState(() => _bytes = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_checked) return widget.fallback;
    if (_bytes case final bytes?) {
      return Image.memory(
        bytes,
        fit: BoxFit.fill,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) {
          _corrupt();
          return widget.fallback;
        },
      );
    }
    return RepaintBoundary(
      key: _boundary,
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.fallback,
          FlutterVectorRoutePreview(
            paths: widget.paths,
            basemapConfiguration: widget.configuration,
            interactive: false,
            routeColour: widget.colour,
            onReady: () => unawaited(_capture()),
          ),
          Positioned(
            right: 2,
            bottom: 1,
            left: 2,
            child: Text(
              widget.configuration.attribution,
              maxLines: 2,
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontSize: 5,
                color: Colors.white,
                backgroundColor: Color(0xC0000000),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
