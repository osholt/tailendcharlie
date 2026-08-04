import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../controllers/distance_unit_controller.dart';
import '../../controllers/internet_relay_controller.dart';
import '../../controllers/ride_controller.dart';
import '../../controllers/nearby_relay_controller.dart';
import '../../controllers/marker_assistance_controller.dart';
import '../../domain/quick_message.dart';
import '../../domain/ride_coordination_mode.dart';
import '../../domain/ride_event.dart';
import '../../domain/ride_role.dart';
import '../../services/ride_connectivity_summary.dart';
import '../internet/internet_relay_status_card.dart';
import '../nearby/relay_status_card.dart';
import 'ride_invitation_qr_sheet.dart';
import 'marker_assistance_widgets.dart';

class RideDashboard extends StatelessWidget {
  const RideDashboard({
    super.key,
    required this.controller,
    required this.distanceUnits,
    required this.rideActions,
    required this.onOpenRoster,
    this.relayController,
    this.markerAssistanceController,
    this.internetRelayController,
    this.onSendQuickMessage,
    this.localObserverAssistanceActive = false,
    this.serviceWarning,
    this.connectivity,
  });

  final RideController controller;
  final DistanceUnitController distanceUnits;
  final Widget rideActions;
  final VoidCallback onOpenRoster;
  final NearbyRelayController? relayController;
  final MarkerAssistanceController? markerAssistanceController;
  final InternetRelayController? internetRelayController;
  final Future<void> Function(QuickMessage)? onSendQuickMessage;

  final bool localObserverAssistanceActive;
  final String? serviceWarning;

  /// The reconciled answer to "is the group seeing where I am".
  final RideConnectivitySummary? connectivity;

  @override
  Widget build(BuildContext context) {
    final session = controller.session!;
    final mode = controller.coordinationMode;
    final isSolo = mode == RideCoordinationMode.solo;
    final usesMarkers = mode.usesSecondBikeDropOff;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Tail End Charlie'),
        backgroundColor: Colors.transparent,
      ),
      body: AnimatedBuilder(
        animation: Listenable.merge([controller, ?markerAssistanceController]),
        builder: (context, _) => Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 40),
              children: [
                _RideHeader(
                  rideCode: session.rideCode,
                  displayName: session.displayName,
                  role: controller.session!.role,
                  coordinationMode: mode,
                  onRoleChanged: controller.setRole,
                ),
                rideActions,
                if (!isSolo) ...[
                  const SizedBox(height: 14),
                  _ConnectionCard(
                    controller: controller,
                    onOpenRoster: onOpenRoster,
                  ),
                ],
                // One answer above the per-channel cards (#174). Three accurate
                // cards that disagreed left a rider unable to tell whether the
                // app was working; the channels keep their own detail below.
                if (!isSolo) ...[
                  if (connectivity case final connectivity?) ...[
                    const SizedBox(height: 14),
                    _ConnectivitySummaryCard(summary: connectivity),
                  ],
                  if (relayController case final relayController?) ...[
                    const SizedBox(height: 14),
                    RelayStatusCard(controller: relayController),
                  ],
                  if (internetRelayController
                      case final internetRelayController?) ...[
                    const SizedBox(height: 14),
                    InternetRelayStatusCard(
                      controller: internetRelayController,
                    ),
                  ],
                ],
                if (serviceWarning case final warning?) ...[
                  const SizedBox(height: 14),
                  _ServiceWarning(message: warning),
                ],
                if (usesMarkers) ...[
                  const SizedBox(height: 14),
                  if (markerAssistanceController case final assistance?) ...[
                    MarkerAssistancePrompt(
                      controller: assistance,
                      distanceUnit: distanceUnits.value,
                    ),
                    if (assistance.hasSuggestion) const SizedBox(height: 14),
                  ],
                  _MarkerCard(controller: controller),
                  const SizedBox(height: 14),
                  MarkerStatisticsCard(summary: controller.markingSummary),
                ],
                if (!isSolo) ...[
                  const SizedBox(height: 22),
                  Text(
                    'QUICK MESSAGES',
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: const Color(0xFF8D98A7),
                      letterSpacing: 1.1,
                    ),
                  ),
                  const SizedBox(height: 10),
                  QuickMessageGrid(
                    busy: controller.busy,
                    onSend: onSendQuickMessage ?? controller.sendQuickMessage,
                    showResolved: localObserverAssistanceActive,
                  ),
                  const SizedBox(height: 22),
                  _RideCodeCard(controller: controller),
                ],
                const SizedBox(height: 22),
                _EventTimeline(controller: controller),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RideHeader extends StatelessWidget {
  const _RideHeader({
    required this.rideCode,
    required this.displayName,
    required this.role,
    required this.coordinationMode,
    required this.onRoleChanged,
  });

  final String rideCode;
  final String displayName;
  final RideRole role;
  final RideCoordinationMode coordinationMode;
  final ValueChanged<RideRole> onRoleChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF252E39), Color(0xFF171D25)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFF343F4C)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  coordinationMode == RideCoordinationMode.solo
                      ? 'SOLO RIDE'
                      : 'RIDE $rideCode',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 7),
                Text(
                  displayName,
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          if (coordinationMode != RideCoordinationMode.solo)
            DropdownButtonHideUnderline(
              child: DropdownButton<RideRole>(
                value: role,
                borderRadius: BorderRadius.circular(14),
                items: RideRole.values
                    .where((item) => item != RideRole.marker || role == item)
                    .map(
                      (item) => DropdownMenuItem(
                        value: item,
                        child: Text(item.label),
                      ),
                    )
                    .toList(),
                onChanged: role == RideRole.marker
                    ? null
                    : (value) {
                        if (value != null) {
                          onRoleChanged(value);
                        }
                      },
              ),
            ),
        ],
      ),
    );
  }
}

class _ConnectionCard extends StatelessWidget {
  const _ConnectionCard({required this.controller, required this.onOpenRoster});

  final RideController controller;
  final VoidCallback onOpenRoster;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          children: [
            _StatusRow(
              icon: Icons.cloud_queue,
              title: 'Durable event queue',
              detail: '${controller.pendingEventCount} events stored locally',
              state: 'OFFLINE SAFE',
              stateColor: const Color(0xFFFFC857),
            ),
            const Divider(height: 24),
            ListTile(
              key: const Key('dashboard-open-roster'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.groups_2_outlined),
              title: const Text('Ride roster'),
              subtitle: Text(
                '${controller.liveParticipants.length} current riders · '
                'presence and transport status',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: onOpenRoster,
            ),
          ],
        ),
      ),
    );
  }
}

/// The one connectivity answer, above the channels that produced it (#174).
class _ConnectivitySummaryCard extends StatelessWidget {
  const _ConnectivitySummaryCard({required this.summary});

  final RideConnectivitySummary summary;

  @override
  Widget build(BuildContext context) {
    final (icon, colour) = switch (summary.state) {
      RideConnectivityState.reaching => (
        Icons.check_circle_outline,
        const Color(0xFF6ED89A),
      ),
      RideConnectivityState.degraded => (
        Icons.access_time,
        const Color(0xFFFFC857),
      ),
      RideConnectivityState.notReaching => (
        Icons.error_outline,
        const Color(0xFFFF5D73),
      ),
      RideConnectivityState.inactive => (
        Icons.cloud_off_outlined,
        const Color(0xFF8D98A7),
      ),
    };
    return Card(
      key: const Key('ride-connectivity-summary'),
      child: ListTile(
        leading: Icon(icon, color: colour),
        title: Text(
          summary.headline,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Text(summary.detail),
      ),
    );
  }
}

class _ServiceWarning extends StatelessWidget {
  const _ServiceWarning({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Card(
    color: const Color(0xFF2B2115),
    child: ListTile(
      leading: const Icon(Icons.info_outline, color: Color(0xFFFFC857)),
      title: const Text('Service limitation'),
      subtitle: Text(message),
    ),
  );
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({
    required this.icon,
    required this.title,
    required this.detail,
    required this.state,
    required this.stateColor,
  });

  final IconData icon;
  final String title;
  final String detail;
  final String state;
  final Color stateColor;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: stateColor),
        const SizedBox(width: 13),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(
                detail,
                style: const TextStyle(color: Color(0xFF98A3B1), fontSize: 12),
              ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: BoxDecoration(
            color: stateColor.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            state,
            style: TextStyle(
              color: stateColor,
              fontWeight: FontWeight.w800,
              fontSize: 11,
            ),
          ),
        ),
      ],
    );
  }
}

class _MarkerCard extends StatelessWidget {
  const _MarkerCard({required this.controller});

  final RideController controller;

  @override
  Widget build(BuildContext context) {
    final active = controller.markerActive;
    final rideStarted = controller.rideStarted;
    final primary = Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: active
            ? primary.withValues(alpha: 0.1)
            : const Color(0xFF171D25),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: active ? primary : const Color(0xFF2B3542)),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: active
                  ? primary.withValues(alpha: 0.18)
                  : const Color(0xFF222B35),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(
              Icons.signpost_outlined,
              color: active ? primary : null,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  active ? 'Marking this junction' : 'Marker mode',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 3),
                Text(
                  active
                      ? controller.tecPassedCurrentMarker
                            ? 'TEC passed · ${controller.verifiedMarkerPassCount} '
                                  'verified riders'
                            : '${controller.verifiedMarkerPassCount} verified · '
                                  '${controller.markerPassCount} total riders'
                      : rideStarted
                      ? 'Assistance only suggests; you always confirm marker mode'
                      : 'Marker assistance begins after the leader starts the ride',
                  style: const TextStyle(
                    color: Color(0xFF9CA7B5),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          FilledButton.tonal(
            onPressed: controller.busy || !rideStarted
                ? null
                : active
                ? controller.endMarker
                : controller.startMarker,
            child: Text(active ? 'Finish' : 'Start'),
          ),
        ],
      ),
    );
  }
}

class QuickMessageGrid extends StatelessWidget {
  const QuickMessageGrid({
    super.key,
    required this.busy,
    required this.onSend,
    this.showResolved = false,
  });

  final bool busy;
  final Future<void> Function(QuickMessage) onSend;
  final bool showResolved;

  static const _messages = [
    (QuickMessage.stopped, Icons.pause_circle_outline),
    (QuickMessage.mechanical, Icons.build_outlined),
    (QuickMessage.fuel, Icons.local_gas_station_outlined),
    (QuickMessage.assistance, Icons.sos_outlined),
    (QuickMessage.routeBlocked, Icons.block_outlined),
    (QuickMessage.emergencyStop, Icons.warning_amber_rounded),
  ];

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 540 ? 3 : 2;
        return GridView.count(
          crossAxisCount: columns,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          childAspectRatio: 2.35,
          children: [
            for (final (message, icon) in _messages)
              OutlinedButton.icon(
                onPressed: busy ? null : () => onSend(message),
                icon: Icon(
                  icon,
                  color: message.priority == EventPriority.critical
                      ? Theme.of(context).colorScheme.error
                      : null,
                ),
                label: Text(
                  message.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            if (showResolved)
              OutlinedButton.icon(
                key: const Key('observer-assistance-resolved'),
                onPressed: busy ? null : () => onSend(QuickMessage.resolved),
                icon: const Icon(Icons.check_circle_outline),
                label: const Text('Resolved / I’m OK'),
              ),
          ],
        );
      },
    );
  }
}

class _RideCodeCard extends StatelessWidget {
  const _RideCodeCard({required this.controller});

  final RideController controller;

  @override
  Widget build(BuildContext context) {
    final session = controller.session!;
    if (session.role != RideRole.lead) {
      return const SizedBox.shrink();
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Share this ride code',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 5),
                  Text(
                    session.rideCode,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.w900,
                      fontSize: 24,
                      letterSpacing: 3,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      TextButton.icon(
                        onPressed: () => Clipboard.setData(
                          ClipboardData(text: session.rideCode),
                        ),
                        icon: const Icon(Icons.copy_outlined),
                        label: const Text('Copy code'),
                      ),
                      TextButton.icon(
                        onPressed: () => SharePlus.instance.share(
                          ShareParams(
                            text: controller.rideCodeShareText,
                            subject: 'Join my Tail End Charlie group',
                          ),
                        ),
                        icon: const Icon(Icons.ios_share),
                        label: const Text('Share code'),
                      ),
                      // The only way in that needs no signal. Sharing a code or
                      // an invite both end in a relay lookup, so in a car park
                      // with no bars they do nothing at all (#279).
                      TextButton.icon(
                        key: const Key('show-invitation-qr'),
                        onPressed: () =>
                            RideInvitationQrSheet.show(context, session),
                        icon: const Icon(Icons.qr_code_2),
                        label: const Text('Show QR'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EventTimeline extends StatelessWidget {
  const _EventTimeline({required this.controller});

  final RideController controller;

  @override
  Widget build(BuildContext context) {
    final events = controller.events.reversed.take(8).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'LOCAL EVENT JOURNAL',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: const Color(0xFF8D98A7),
                  letterSpacing: 1.1,
                ),
              ),
            ),
            Text(
              '${events.length} shown',
              style: const TextStyle(color: Color(0xFF75808D), fontSize: 12),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Card(
          child: events.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(20),
                  child: Text('No ride events yet.'),
                )
              : Column(
                  children: [
                    for (var index = 0; index < events.length; index++) ...[
                      _EventRow(event: events[index]),
                      if (index != events.length - 1)
                        const Divider(height: 1, indent: 50),
                    ],
                  ],
                ),
        ),
        if (kDebugMode) ...[
          const SizedBox(height: 10),
          const Text(
            'Debug build: transport acknowledgements are not yet connected, so '
            'events correctly remain queued.',
            style: TextStyle(color: Color(0xFF6F7A87), fontSize: 11),
          ),
        ],
      ],
    );
  }
}

class _EventRow extends StatelessWidget {
  const _EventRow({required this.event});

  final RideEvent event;

  @override
  Widget build(BuildContext context) {
    final title = switch (event.type) {
      RideEventType.rideCreated => 'Ride created',
      RideEventType.riderJoined => 'Joined ride',
      RideEventType.riderLeft => 'Left ride',
      RideEventType.roleChanged => 'Role changed',
      RideEventType.rideStarted => 'Ride started',
      RideEventType.markerStarted => 'Marker started',
      RideEventType.markerPass => 'Rider passed marker',
      RideEventType.markerEnded => 'Marker finished',
      // Also the acknowledgement of another rider's message, which is a
      // `statusMessage` carrying `acknowledgesQuickMessageEventId` and the label
      // "Seen: <what they raised>" (#151). One row either way: the log records
      // what went into the journal, and the ride surface is where a rider is
      // actually told (`_QuickMessageAlertCard` in the map).
      RideEventType.statusMessage =>
        event.payload['label'] as String? ?? 'Status message',
      RideEventType.riderLocationUpdated => 'Location updated',
      RideEventType.hazardReported => 'Hazard reported',
      RideEventType.hazardCleared => 'Hazard cleared',
      RideEventType.routeDeviationChanged => 'Route status changed',
      RideEventType.routeAlertAcknowledged => 'Route alert acknowledged',
      RideEventType.routeRevisionChunk => 'Route revision received',
      RideEventType.routeRevisionPublished => 'Group route updated',
      RideEventType.routeCleared => 'Group route cleared',
      RideEventType.ridePaused => 'Ride paused',
      RideEventType.rideResumed => 'Ride resumed',
      RideEventType.rideEnded => 'Ride ended',
      // Says what happened rather than what it undid: the journal keeps both
      // events, and a rider reading the log should see the sequence.
      RideEventType.rideReopened => 'Ride reopened by the leader',
      RideEventType.iceInfoShared => 'Emergency contact shared',
      RideEventType.iceInfoViewed => 'Emergency contact viewed',
      RideEventType.tecRoleRequested => 'Tail End Charlie requested',
      RideEventType.tecRoleResponded =>
        event.payload['accepted'] == true
            ? 'Tail End Charlie accepted'
            : 'Tail End Charlie declined',
      RideEventType.rejoinRouteShared =>
        (event.payload['share'] as Map?)?['cleared'] == true
            ? 'Rejoin route cleared'
            : 'Rejoin route shared with the leader',
      // #188. The activity list says a number was shared and with whom, never
      // what the number is: this is a log, not a place to read a number off a
      // screen.
      RideEventType.riderContactShared =>
        event.payload['recipientRiderIds'] == null
            ? 'Phone number shared with the ride'
            : 'Phone number shared with the leader and TEC',
    };
    final time = TimeOfDay.fromDateTime(event.createdAt).format(context);
    return ListTile(
      dense: true,
      leading: Icon(
        event.acknowledged ? Icons.cloud_done_outlined : Icons.schedule_send,
        size: 20,
        color: event.acknowledged
            ? const Color(0xFF6ED89A)
            : const Color(0xFFFFC857),
      ),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(event.acknowledged ? 'Delivered' : 'Stored locally'),
      trailing: Text(time, style: const TextStyle(color: Color(0xFF7F8995))),
    );
  }
}
