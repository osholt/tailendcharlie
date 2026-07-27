import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as ml;
import 'package:share_plus/share_plus.dart';

import '../../domain/distance_unit.dart';
import '../../domain/imported_route.dart' show GeoPoint;
import '../../services/basemap_configuration.dart';
import '../../services/recap_basemap_snapshot.dart';
import '../../services/ride_summary_exporter.dart';
import '../../services/trail_display_simplifier.dart';
import '../map/resolved_route_map_preview.dart';
import 'ride_recap_card.dart';

/// Shows [RideRecapCard] full-screen and shares it as a PNG - a purpose-made
/// image for social media, separate from the text/CSV/GPX ride summary
/// share so it isn't diluted by data files receiving apps don't expect.
class RideRecapScreen extends StatefulWidget {
  const RideRecapScreen({
    super.key,
    required this.summary,
    required this.routePoints,
    this.distanceUnit = DistanceUnit.kilometres,
    this.basemapConfiguration = const BasemapConfiguration(),
    this.snapshotter = const RecapBasemapSnapshotter(),
  });

  final RideSummary summary;
  final List<GeoPoint> routePoints;
  final DistanceUnit distanceUnit;
  final BasemapConfiguration basemapConfiguration;
  final RecapBasemapSnapshotter snapshotter;

  static Future<void> show(
    BuildContext context, {
    required RideSummary summary,
    required List<GeoPoint> routePoints,
    DistanceUnit distanceUnit = DistanceUnit.kilometres,
    BasemapConfiguration basemapConfiguration = const BasemapConfiguration(),
  }) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => RideRecapScreen(
        summary: summary,
        routePoints: routePoints,
        distanceUnit: distanceUnit,
        basemapConfiguration: basemapConfiguration,
      ),
    ),
  );

  @override
  State<RideRecapScreen> createState() => _RideRecapScreenState();
}

class _RideRecapScreenState extends State<RideRecapScreen> {
  final _boundaryKey = GlobalKey();
  bool _sharing = false;
  String? _error;

  /// Simplified once, here, rather than per build or per caller: a two-hour
  /// ride arrives with around ten thousand recorded points and the card is
  /// repainted on every frame it is on screen, then again at 3x to rasterise
  /// (#165).
  late List<GeoPoint> _routePoints = const TrailDisplaySimplifier().simplify(
    widget.routePoints,
  );

  @override
  void didUpdateWidget(RideRecapScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.routePoints, widget.routePoints)) {
      _routePoints = const TrailDisplaySimplifier().simplify(
        widget.routePoints,
      );
    }
  }

  ml.MapLibreMapController? _mapController;
  bool _mapStyleReady = false;

  /// The rasterised basemap, present only while capturing.
  ///
  /// The live map is a platform view, which `RepaintBoundary.toImage` cannot
  /// see - capturing with it on screen produced a blank panel, which is the
  /// reported defect (#157). So the snapshot replaces it for exactly the frames
  /// the capture needs, then goes.
  ui.Image? _capturedBasemap;

  /// Light or dark, for this image only. Seeded from the app's theme so the
  /// first Share does what a rider expects, and stored nowhere.
  bool? _darkOverride;

  bool get _dark =>
      _darkOverride ?? Theme.of(context).brightness == Brightness.dark;

  bool get _canShowBasemap =>
      widget.basemapConfiguration.usesMapLibre && _routePoints.length >= 2;

  Future<void> _share() async {
    setState(() {
      _sharing = true;
      _error = null;
    });
    try {
      final snapshot = await widget.snapshotter.capture(
        takeSnapshot: _mapStyleReady && _mapController != null
            ? _mapController!.takeSnapshot
            : null,
        basemapConfigured: _canShowBasemap,
      );
      if (!mounted) return;
      if (snapshot.hasImage) {
        setState(() => _capturedBasemap = snapshot.image);
        // One frame for the image to replace the platform view before the
        // boundary is read, or the capture still sees the hole.
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted) return;
      }
      final boundary =
          _boundaryKey.currentContext!.findRenderObject()
              as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 3);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      final bytes = byteData!.buffer.asUint8List();
      final fileName =
          'ride-relay-${widget.summary.rideCode.toLowerCase()}-recap.png';
      await SharePlus.instance.share(
        ShareParams(
          text: 'Tail End Charlie ride recap · ${widget.summary.rideCode}',
          files: [XFile.fromData(bytes, mimeType: 'image/png', name: fileName)],
          fileNameOverrides: [fileName],
        ),
      );
      if (mounted && snapshot.degradedMessage != null) {
        // Said rather than swallowed: an export with no tiles is the defect
        // being fixed, so if it happens again the rider is told which of the
        // reasons it was.
        setState(() => _error = snapshot.degradedMessage);
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = 'Could not share recap image: $error');
      }
    } finally {
      if (mounted) {
        setState(() {
          _sharing = false;
          _capturedBasemap = null;
        });
      }
    }
  }

  /// The live map behind the route while the rider is looking at the card.
  ///
  /// Keyed on the palette so switching light and dark rebuilds the map with the
  /// other style rather than leaving the old tiles behind.
  Widget _liveBasemap() => ResolvedRouteMapPreview(
    key: ValueKey('recap-basemap-${_dark ? 'dark' : 'light'}'),
    paths: [_routePoints],
    basemapConfiguration: widget.basemapConfiguration.forBrightness(
      dark: _dark,
    ),
    onControllerReady: (controller) => _mapController = controller,
    onStyleReady: () {
      if (mounted) setState(() => _mapStyleReady = true);
    },
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Ride recap')),
    body: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: RepaintBoundary(
                  key: _boundaryKey,
                  child: RideRecapCard(
                    summary: widget.summary,
                    routePoints: _routePoints,
                    distanceUnit: widget.distanceUnit,
                    dark: _dark,
                    basemap: _capturedBasemap,
                    basemapAttribution: _canShowBasemap
                        ? widget.basemapConfiguration.attribution
                        : null,
                    mapLayer: _canShowBasemap ? _liveBasemap() : null,
                  ),
                ),
              ),
            ),
            if (_error case final error?) ...[
              const SizedBox(height: 12),
              Text(error, style: const TextStyle(color: Colors.redAccent)),
            ],
            const SizedBox(height: 12),
            SegmentedButton<bool>(
              key: const Key('recap-brightness-toggle'),
              segments: const [
                ButtonSegment(
                  value: false,
                  icon: Icon(Icons.light_mode_outlined, size: 18),
                  label: Text('Light'),
                ),
                ButtonSegment(
                  value: true,
                  icon: Icon(Icons.dark_mode_outlined, size: 18),
                  label: Text('Dark'),
                ),
              ],
              selected: {_dark},
              // The image only. Nothing here touches the app theme, the ride
              // map, or any stored preference (#157).
              onSelectionChanged: (selection) =>
                  setState(() => _darkOverride = selection.first),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const Key('share-recap-image-button'),
              onPressed: _sharing ? null : _share,
              icon: const Icon(Icons.ios_share),
              label: Text(_sharing ? 'Preparing…' : 'Share image'),
            ),
          ],
        ),
      ),
    ),
  );
}
