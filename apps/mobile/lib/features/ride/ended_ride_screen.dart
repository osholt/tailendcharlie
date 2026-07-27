import 'package:flutter/material.dart';

import '../../controllers/distance_unit_controller.dart';
import '../../controllers/internet_relay_controller.dart';
import '../../controllers/nearby_relay_controller.dart';
import '../../controllers/ride_controller.dart';
import '../../services/ride_summary_exporter.dart';
import '../internet/internet_relay_status_card.dart';
import '../nearby/relay_status_card.dart';
import 'ride_recap_screen.dart';

class EndedRideScreen extends StatelessWidget {
  const EndedRideScreen({
    super.key,
    required this.controller,
    required this.distanceUnits,
    this.nearbyRelayController,
    this.internetRelayController,
    this.summarySharer,
    this.onRemoveRide,
  });

  final RideController controller;
  final DistanceUnitController distanceUnits;
  final NearbyRelayController? nearbyRelayController;
  final InternetRelayController? internetRelayController;
  final RideSummarySharer? summarySharer;
  final Future<void> Function()? onRemoveRide;

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
        if (nearbyRelayController case final nearby?) ...[
          RelayStatusCard(controller: nearby),
          const SizedBox(height: 12),
        ],
        if (internetRelayController case final internet?) ...[
          InternetRelayStatusCard(controller: internet),
          const SizedBox(height: 18),
        ],
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
      await (summarySharer ?? const SystemRideSummarySharer()).share(
        controller.session!,
        controller.events,
        distanceUnit: distanceUnits.value,
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
      controller.session!,
      controller.events,
      generatedAt: generatedAt,
    );
    final route = exporter.traveledRoute(
      controller.session!,
      controller.events,
      generatedAt: generatedAt,
    );
    await RideRecapScreen.show(
      context,
      summary: summary,
      routePoints: route?.paths.single.points ?? const [],
      distanceUnit: distanceUnits.value,
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
      await (onRemoveRide?.call() ?? controller.clearEndedRide());
    }
  }
}
