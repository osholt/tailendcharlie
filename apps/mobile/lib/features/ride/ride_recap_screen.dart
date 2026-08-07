import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:share_plus/share_plus.dart';

import '../../domain/distance_unit.dart';
import '../../domain/imported_route.dart' show GeoPoint;
import '../../services/recap_basemap_snapshot.dart';
import '../../services/basemap_configuration.dart';
import '../../services/ride_summary_exporter.dart';
import '../../services/trail_display_simplifier.dart';
import '../map/flutter_vector_route_preview.dart';
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
    this.mapBuilder,
  });

  final RideSummary summary;
  final List<GeoPoint> routePoints;
  final DistanceUnit distanceUnit;
  final BasemapConfiguration basemapConfiguration;
  final Widget Function(
    Key key,
    List<List<GeoPoint>> paths,
    BasemapConfiguration configuration,
    VoidCallback onReady,
    ValueChanged<Object> onFailure,
  )?
  mapBuilder;

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

  bool _mapReady = false;

  /// Why the recap has no basemap, once that is settled. Null while it is still
  /// loading and after a successful load.
  ///
  /// The outcome rather than a bare "failed" flag, so this screen and
  /// [RecapBasemapSnapshot] say the same words about the same situations
  /// instead of keeping two vocabularies for one fact.
  RecapBasemapOutcome? _mapOutcome;

  /// Bounds the wait. Without one, a style that loads but whose tiles never
  /// arrive left the screen in "still loading" for ever: Share refused every
  /// time, with no end and nothing said, which is the reported "the export
  /// takes a really long time and then has no map" (#364).
  Timer? _basemapDeadline;

  /// Long enough for a cold vector-tile load on mobile data, short enough that
  /// a rider stops waiting and gets an outline they can actually send.
  static const _basemapTimeout = Duration(seconds: 12);

  bool get _mapFailed => _mapOutcome != null;

  @override
  void dispose() {
    _basemapDeadline?.cancel();
    super.dispose();
  }

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
      if (_canShowBasemap && !_mapReady && !_mapFailed) {
        setState(() {
          _sharing = false;
          _error =
              'The recap map is still loading. Try Share again in a moment.';
        });
        return;
      }
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
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
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = 'Could not share recap image: $error');
      }
    } finally {
      if (mounted) {
        setState(() {
          _sharing = false;
        });
      }
    }
  }

  Widget _liveBasemap() {
    final key = ValueKey('recap-basemap-${_dark ? 'dark' : 'light'}');
    final configuration = widget.basemapConfiguration.forBrightness(
      dark: _dark,
    );
    void settle(RecapBasemapOutcome outcome) {
      if (!mounted) return;
      _basemapDeadline?.cancel();
      _basemapDeadline = null;
      setState(() {
        _mapOutcome = outcome;
        _mapReady = false;
        _error = RecapBasemapSnapshot.unavailable(outcome).degradedMessage;
      });
    }

    void ready() {
      if (!mounted) return;
      _basemapDeadline?.cancel();
      _basemapDeadline = null;
      setState(() => _mapReady = true);
    }

    void failed(Object _) => settle(RecapBasemapOutcome.failed);

    _basemapDeadline ??= Timer(_basemapTimeout, () {
      if (_mapReady || _mapOutcome != null) return;
      settle(RecapBasemapOutcome.timedOut);
    });

    return widget.mapBuilder?.call(
          key,
          [_routePoints],
          configuration,
          ready,
          failed,
        ) ??
        FlutterVectorRoutePreview(
          key: key,
          paths: [_routePoints],
          basemapConfiguration: configuration,
          onReady: ready,
          onFailure: failed,
        );
  }

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
                    basemapAttribution: _canShowBasemap && !_mapFailed
                        ? widget.basemapConfiguration.attribution
                        : null,
                    mapLayer: _canShowBasemap && !_mapFailed
                        ? _liveBasemap()
                        : null,
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
              onSelectionChanged: (selection) => setState(() {
                _darkOverride = selection.first;
                _mapReady = false;
                _mapOutcome = null;
                _error = null;
                _basemapDeadline?.cancel();
                _basemapDeadline = null;
              }),
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
