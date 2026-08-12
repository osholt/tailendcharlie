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
    this.onSetAside,
    this.relayCanCarryReopen = true,
    this.diagnostics,
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

  /// Leaves this screen without acting on the ride.
  ///
  /// Required, in practice: without it this screen is the whole app and its only
  /// exit files the ride (#207).
  final VoidCallback? onSetAside;

  /// The negotiated `ride-reopen-v1` capability. False hides the action rather
  /// than offering a reopen that could not reach the rest of the group.
  final bool relayCanCarryReopen;

  /// The recorded diagnostics log for this ride, if it was recorded (#456).
  ///
  /// A callback returning a future because the log may have to be read back from
  /// disk: this screen is also where a rider lands after restoring a ride that
  /// was recorded in a previous run of the app.
  ///
  /// The share here originally took no log at all, which made **Share ride
  /// summary** — the obvious button once a ride is over — the one door that
  /// silently dropped the evidence.
  final Future<String?> Function()? diagnostics;

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

  /// The way off this screen that gives nothing up (#207).
  VoidCallback get _setAside =>
      widget.onSetAside ?? widget.controller.setEndedRideAside;

  bool _reopening = false;

  /// Only the leader, only while the relay can carry it.
  ///
  /// The window is not checked here — [RideController.reopenRide] owns that, and
  /// it is the same 24 hours the ended ride survives for anyway, so a screen that
  /// exists at all is inside it.
  bool get _canOfferReopen =>
      widget.relayCanCarryReopen && widget.controller.isLocalRideLeader;

  Future<void> _confirmReopen(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Resume this ride?'),
        content: const Text(
          'The ride goes back to running for everyone, on the same ride code. '
          'Riders who already left stay out until they rejoin.\n\n'
          'One thing does not come back: emergency contact details other '
          'riders shared with you were cleared when the ride ended.',
        ),
        actions: [
          TextButton(
            key: const Key('cancel-reopen-ride-button'),
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Leave it ended'),
          ),
          FilledButton(
            key: const Key('confirm-reopen-ride-button'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Resume ride'),
          ),
        ],
      ),
    );
    if (!(confirmed ?? false)) return;
    setState(() => _reopening = true);
    final outcome = await widget.controller.reopenRide(
      relayCanCarryReopen: widget.relayCanCarryReopen,
    );
    if (mounted) setState(() => _reopening = false);
    if (outcome == RideReopenOutcome.reopened || !context.mounted) return;
    // Anything short of success is said out loud. A leader must never be left
    // believing the group is riding again when it is not.
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(_reopenFailure(outcome))));
  }

  static String _reopenFailure(RideReopenOutcome outcome) => switch (outcome) {
    RideReopenOutcome.notLeader => 'Only the ride leader can resume a ride.',
    RideReopenOutcome.windowExpired =>
      'This ride ended too long ago to resume. Start a new one.',
    RideReopenOutcome.relayUnsupported =>
      'The ride service cannot carry a resume yet, so the rest of the group '
          'would not see it. Start a new ride instead.',
    RideReopenOutcome.notEnded => 'This ride is already running.',
    RideReopenOutcome.failed || RideReopenOutcome.reopened =>
      'Could not resume the ride. Please try again.',
  };

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Ride ended'),
      leading: IconButton(
        key: const Key('leave-ended-ride-screen-button'),
        tooltip: 'Back to the map',
        onPressed: _setAside,
        icon: const Icon(Icons.close),
      ),
    ),
    body: ListView(
      padding: const EdgeInsets.all(18),
      children: [
        // Above everything, including who ended the ride. Recording the ride is
        // the premise of the app; a rider who has lost one needs to know before
        // they read its summary, not after (#299).
        if (widget.controller.rideArchiveError case final message?)
          Padding(
            key: const Key('ride-archive-failed-notice'),
            padding: const EdgeInsets.only(bottom: 16),
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF3A2126),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFFFF8A6B)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.save_as_outlined, color: Color(0xFFFF8A6B)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'This ride was not saved',
                          style: TextStyle(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          message,
                          style: const TextStyle(
                            color: Color(0xFFE6C3BB),
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        // Named, prominent, and first. A tester read an unexplained end as a
        // crash (#283): the screen said the ride had ended but not that somebody
        // had ended it, nor who, so it was indistinguishable from the app
        // falling over. "Ride summary ready" is the wrong first thing to say to
        // a rider who did not ask for the ride to stop.
        if (widget.controller.rideEndedBy case final endedBy?
            when !endedBy.isLocalRider)
          Padding(
            key: const Key('ride-ended-by-notice'),
            padding: const EdgeInsets.only(bottom: 16),
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF2A2136),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFFFFA76B)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.info_outline, color: Color(0xFFFFC79B)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          endedBy.displayName == null
                              ? 'The ride leader ended this ride for everyone'
                              : '${endedBy.displayName} ended this ride for '
                                    'everyone',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(color: const Color(0xFFFFF1E4)),
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'The app did not stop on its own and nothing has gone '
                          'wrong. Your position is no longer being shared with '
                          'the group.',
                          style: TextStyle(
                            color: Color(0xFFE3CBB6),
                            height: 1.45,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
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
        const SizedBox(height: 8),
        const Text(
          'This ride is already saved in Previous rides. You can leave this '
          'screen any time — nothing here has to be done now.',
          style: TextStyle(color: Color(0xFF7F8A98), height: 1.45),
        ),
        const SizedBox(height: 16),
        // The way out, **above** everything that can grow.
        //
        // It used to be eighth in this list, below two relay status cards and the
        // road-rating card. In a test none of those three is supplied, so the
        // button was on screen and a passing test said the exit worked. On a real
        // ride all three are present and it went off the bottom — which is
        // precisely what was reported: the shares worked and nothing dismissed the
        // screen (#440). The shares are directly above where it used to be.
        //
        // Filled, not outlined: it is the ordinary thing to do here. Filing the
        // ride is the deliberate one and it stays at the bottom.
        FilledButton.icon(
          key: const Key('leave-ended-ride-button'),
          onPressed: _setAside,
          icon: const Icon(Icons.map_outlined),
          // "the map", not "home": #426 made the home screen a free-roam map, and
          // the report was that there was "no way back to the map".
          label: const Text('Back to the map'),
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
        // Above the shares and the filing, because a leader who is here by
        // mistake is mid-ride and has a group waiting (#206).
        if (_canOfferReopen) ...[
          const SizedBox(height: 12),
          OutlinedButton.icon(
            key: const Key('reopen-ended-ride-button'),
            onPressed: _reopening ? null : () => _confirmReopen(context),
            icon: const Icon(Icons.play_arrow_outlined),
            label: const Text("This ride hasn't finished — resume it"),
          ),
        ],
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
      final diagnostics = await widget.diagnostics?.call();
      await (widget.summarySharer ?? const SystemRideSummarySharer()).share(
        widget.controller.session!,
        widget.controller.events,
        distanceUnit: widget.distanceUnits.value,
        sharePositionOrigin: origin,
        diagnostics: diagnostics == null || diagnostics.isEmpty
            ? null
            : diagnostics,
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
