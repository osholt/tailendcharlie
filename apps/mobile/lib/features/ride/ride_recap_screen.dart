import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:share_plus/share_plus.dart';

import '../../domain/distance_unit.dart';
import '../../domain/imported_route.dart' show GeoPoint;
import '../../services/ride_summary_exporter.dart';
import '../../services/trail_display_simplifier.dart';
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
  });

  final RideSummary summary;
  final List<GeoPoint> routePoints;
  final DistanceUnit distanceUnit;

  static Future<void> show(
    BuildContext context, {
    required RideSummary summary,
    required List<GeoPoint> routePoints,
    DistanceUnit distanceUnit = DistanceUnit.kilometres,
  }) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => RideRecapScreen(
        summary: summary,
        routePoints: routePoints,
        distanceUnit: distanceUnit,
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

  Future<void> _share() async {
    setState(() {
      _sharing = true;
      _error = null;
    });
    try {
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
      if (mounted) setState(() => _sharing = false);
    }
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
                  ),
                ),
              ),
            ),
            if (_error case final error?) ...[
              const SizedBox(height: 12),
              Text(error, style: const TextStyle(color: Colors.redAccent)),
            ],
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
