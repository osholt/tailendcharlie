import 'package:flutter/material.dart';

import '../../controllers/distance_unit_controller.dart';
import '../../controllers/internet_relay_controller.dart';
import '../../controllers/nearby_relay_controller.dart';
import '../../controllers/ride_controller.dart';
import '../../controllers/road_rating_controller.dart';
import '../../services/basemap_configuration.dart';
import '../../services/ride_summary_exporter.dart';
import '../internet/internet_relay_status_card.dart';
import '../nearby/relay_status_card.dart';
import 'ride_recap_screen.dart';
import 'road_rating_card.dart';

class EndedRideScreen extends StatefulWidget {
  const EndedRideScreen({
    super.key,
    required this.controller,
    required this.distanceUnits,
    this.nearbyRelayController,
    this.internetRelayController,
    this.summarySharer,
    this.onRemoveRide,
    this.roadRatings,
  });

  final RideController controller;
  final DistanceUnitController distanceUnits;
  final NearbyRelayController? nearbyRelayController;
  final InternetRelayController? internetRelayController;
  final RideSummarySharer? summarySharer;
  final Future<void> Function()? onRemoveRide;

  /// Absent in a build with no catalogue service configured, and in tests that
  /// are not about ratings. When absent, no rating card is built at all.
  final RoadRatingController? roadRatings;

  @override
  State<EndedRideScreen> createState() => _EndedRideScreenState();
}

class _EndedRideScreenState extends State<EndedRideScreen> {
  @override
  void initState() {
    super.initState();
    // After the first frame, never during it. Matching a track against the
    // catalogue means loading and scanning it, and #165 was about exactly this
    // screen taking too long to appear.
    WidgetsBinding.instance.addPostFrameCallback((_) => _prepareRatings());
  }

  Future<void> _prepareRatings() async {
    final ratings = widget.roadRatings;
    final session = widget.controller.session;
    if (ratings == null || ratings.prepared || session == null) return;
    final route = const RideSummaryExporter().traveledRoute(
      session,
      widget.controller.events,
      generatedAt: DateTime.now(),
    );
    await ratings.prepare(riddenTrack: route?.paths.single.points ?? const []);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Ride ended')),
    body: ListView(
      padding: const EdgeInsets.all(18),
      children: [
        Text(
          'Ride summary ready',
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 8),
        const Text(
          'Location sharing is stopped. Relay recovery stays available so the '
          'final marker and ride-ended events can still be delivered after a '
          'temporary loss of signal.',
          style: TextStyle(color: Color(0xFFABB5C1), height: 1.45),
        ),
        const SizedBox(height: 18),
        if (widget.nearbyRelayController case final nearby?) ...[
          RelayStatusCard(controller: nearby),
          const SizedBox(height: 12),
        ],
        if (widget.internetRelayController case final internet?) ...[
          InternetRelayStatusCard(controller: internet),
          const SizedBox(height: 18),
        ],
        if (widget.roadRatings case final ratings?)
          RoadRatingCard(controller: ratings),
        FilledButton.icon(
          onPressed: () => _shareSummary(context),
          icon: const Icon(Icons.ios_share),
          label: const Text('Share ride summary'),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          key: const Key('share-recap-image-entry-button'),
          onPressed: () => _openRecap(context),
          icon: const Icon(Icons.image_outlined),
          label: const Text('Share ride recap image'),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          key: const Key('file-ended-ride-button'),
          onPressed: () => _confirmFile(context),
          // Not a delete icon: this files the ride, and the icon is read before
          // the label (#156).
          icon: const Icon(Icons.inventory_2_outlined),
          label: const Text('Finish and file in Previous rides'),
        ),
      ],
    ),
  );

  Future<void> _shareSummary(BuildContext context) async {
    final renderObject = context.findRenderObject();
    final origin = renderObject is RenderBox && renderObject.hasSize
        ? renderObject.localToGlobal(Offset.zero) & renderObject.size
        : null;
    try {
      await (widget.summarySharer ?? const SystemRideSummarySharer()).share(
        widget.controller.session!,
        widget.controller.events,
        distanceUnit: widget.distanceUnits.value,
        sharePositionOrigin: origin,
      );
    } on Object catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not share ride summary: $error')),
      );
    }
  }

  Future<void> _openRecap(BuildContext context) async {
    const exporter = RideSummaryExporter();
    final generatedAt = DateTime.now();
    final summary = exporter.summarize(
      widget.controller.session!,
      widget.controller.events,
      generatedAt: generatedAt,
    );
    final route = exporter.traveledRoute(
      widget.controller.session!,
      widget.controller.events,
      generatedAt: generatedAt,
    );
    await RideRecapScreen.show(
      context,
      // The real configuration, not the empty default: without a style there is
      // no basemap to snapshot and the recap falls back to the outline (#157).
      basemapConfiguration: BasemapConfiguration.fromEnvironment(),
      summary: summary,
      routePoints: route?.paths.single.points ?? const [],
      distanceUnit: widget.distanceUnits.value,
    );
  }

  /// The confirmation is kept, but it no longer describes a deletion.
  ///
  /// Filing a ride is harmless - it is archived to Previous rides first and only
  /// the live working copy is cleared - so a scary modal is not warranted. What
  /// is warranted is one sentence, because the single real consequence cannot be
  /// undone: a phone that has not yet received another rider's last few events
  /// stops trying for them. A rider who presses this thirty seconds after the
  /// ride ends can lose the TEC's final marker count. That is small, and it is
  /// still a loss, and it is invisible unless said.
  Future<void> _confirmFile(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('File this ride in Previous rides?'),
        content: const Text(
          'The ride stays on this phone, in Previous rides, with its summary '
          'and recorded route.\n\n'
          'One thing stops: if another rider\'s last few events have not '
          'reached this phone yet, it will stop waiting for them.',
        ),
        actions: [
          TextButton(
            key: const Key('keep-ended-ride-open-button'),
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Not yet'),
          ),
          FilledButton(
            key: const Key('confirm-file-ended-ride-button'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('File ride'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      await (widget.onRemoveRide?.call() ?? widget.controller.clearEndedRide());
    }
  }
}
