import 'package:flutter/material.dart';

import '../../controllers/foreground_location_controller.dart';
import '../../controllers/situational_awareness_controller.dart';
import '../../domain/hazard.dart';
import '../../domain/route_alert.dart';
import '../../services/device_location_source.dart';
import '../../services/external_hazard_provider.dart';
import '../map/route_trail_style.dart';

class SituationalAwarenessScreen extends StatelessWidget {
  const SituationalAwarenessScreen({
    super.key,
    required this.controller,
    this.showAppBar = true,
    this.locationController,
    this.rideStarted = true,
    this.onLocationStopped,
    this.trafficRerouteHazards = const [],
    this.trafficRerouting = false,
    this.trafficRerouteError,
    this.onReviewTrafficAlternative,
    this.onDismissTrafficAlternative,
    this.rejoinGuidance,
  });

  final SituationalAwarenessController controller;
  final bool showAppBar;
  final ForegroundLocationController? locationController;
  final bool rideStarted;
  final Future<void> Function()? onLocationStopped;
  final List<HazardReport> trafficRerouteHazards;
  final bool trafficRerouting;
  final String? trafficRerouteError;
  final Future<void> Function()? onReviewTrafficAlternative;
  final Future<void> Function()? onDismissTrafficAlternative;

  /// Issue #102: advisory rejoin guidance for the local rider, or null when
  /// they are on route. Shown verbatim - it already says when routing is
  /// unavailable and never names a manoeuvre.
  final String? rejoinGuidance;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: showAppBar ? AppBar(title: const Text('Alerts')) : null,
    body: AnimatedBuilder(
      animation: controller,
      builder: (context, _) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 40),
            children: [
              if (controller.errorMessage case final message?) ...[
                _ErrorBanner(
                  message: message,
                  onDismiss: controller.clearError,
                ),
                const SizedBox(height: 12),
              ],
              if (controller.routeAlerts.isNotEmpty ||
                  rejoinGuidance != null) ...[
                _RouteStatusCard(
                  controller: controller,
                  rejoinGuidance: rejoinGuidance,
                ),
                const SizedBox(height: 12),
              ],
              if (!rideStarted) ...[
                const _PreStartLocationCard(),
                if (locationController case final locationController?) ...[
                  const SizedBox(height: 12),
                  ForegroundLocationCard(
                    controller: locationController,
                    preStart: true,
                    onStopped: onLocationStopped,
                  ),
                ],
              ],
              const SizedBox(height: 20),
              _SectionHeader(
                title: 'ROAD ALERTS',
                action: FilledButton.icon(
                  key: const Key('report-hazard-button'),
                  onPressed: controller.busy
                      ? null
                      : () => _showHazardSheet(context),
                  icon: const Icon(Icons.add_alert_outlined),
                  label: const Text('Report'),
                ),
              ),
              const SizedBox(height: 10),
              if (controller.activeHazards.isEmpty)
                const _EmptyCard(
                  icon: Icons.check_circle_outline,
                  title: 'No active road alerts',
                  detail: 'Report something the riders behind need to know.',
                )
              else
                ...controller.activeHazards.map(
                  (hazard) => Padding(
                    padding: const EdgeInsets.only(bottom: 9),
                    child: HazardCard(
                      hazard: hazard,
                      onClear: () => controller.clearHazard(hazard.id),
                    ),
                  ),
                ),
              if (trafficRerouteHazards.isNotEmpty &&
                  onReviewTrafficAlternative != null &&
                  onDismissTrafficAlternative != null) ...[
                const SizedBox(height: 12),
                _TrafficRerouteCard(
                  hazards: trafficRerouteHazards,
                  busy: trafficRerouting,
                  error: trafficRerouteError,
                  onReview: onReviewTrafficAlternative!,
                  onDismiss: onDismissTrafficAlternative!,
                ),
              ],
              if (controller.routeAlerts.isNotEmpty) ...[
                const SizedBox(height: 20),
                const _SectionHeader(title: 'RIDERS NEEDING ATTENTION'),
                const SizedBox(height: 10),
                ...controller.routeAlerts.map((alert) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 9),
                    child: RiderStatusCard(
                      displayName: alert.displayName,
                      alert: alert,
                      onAcknowledge: alert.acknowledged
                          ? null
                          : () => controller.acknowledgeAlert(alert.riderId),
                    ),
                  );
                }),
              ],
            ],
          ),
        ),
      ),
    ),
  );

  Future<void> _showHazardSheet(BuildContext context) async {
    final draft = await showModalBottomSheet<HazardDraft>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const HazardReportSheet(),
    );
    if (draft != null) {
      await controller.reportHazard(
        type: draft.type,
        severity: draft.severity,
        details: draft.details,
      );
    }
  }
}

class _TrafficRerouteCard extends StatelessWidget {
  const _TrafficRerouteCard({
    required this.hazards,
    required this.busy,
    required this.error,
    required this.onReview,
    required this.onDismiss,
  });

  final List<HazardReport> hazards;
  final bool busy;
  final String? error;
  final Future<void> Function() onReview;
  final Future<void> Function() onDismiss;

  @override
  Widget build(BuildContext context) {
    final first = hazards.first;
    return Card(
      key: const Key('traffic-reroute-card'),
      color: const Color(0xFF2A211A),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.alt_route_rounded, color: Color(0xFFFFC857)),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    hazards.length == 1
                        ? 'Serious incident may affect the route'
                        : '${hazards.length} serious incidents may affect the route',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              first.details ??
                  '${first.type.label} · ${first.severity.label} · live traffic',
              style: const TextStyle(color: Color(0xFFD8CBBE)),
            ),
            if (error case final message?) ...[
              const SizedBox(height: 8),
              Text(
                message,
                key: const Key('traffic-reroute-error'),
                style: const TextStyle(color: Color(0xFFFF8A80)),
              ),
            ],
            const SizedBox(height: 14),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  key: const Key('review-traffic-alternative'),
                  onPressed: busy ? null : onReview,
                  icon: busy
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.route_outlined),
                  label: Text(busy ? 'Calculating…' : 'Review alternative'),
                ),
                TextButton(
                  key: const Key('dismiss-traffic-alternative'),
                  onPressed: busy ? null : onDismiss,
                  child: const Text('Dismiss this incident'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'The group route changes only after the leader reviews and '
              'confirms the alternative.',
              style: TextStyle(color: Color(0xFFAD9E90), fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class _PreStartLocationCard extends StatelessWidget {
  const _PreStartLocationCard();

  @override
  Widget build(BuildContext context) => const Card(
    child: ListTile(
      leading: Icon(Icons.location_off_outlined, color: Color(0xFFFFC857)),
      title: Text('Current position only before departure'),
      subtitle: Text(
        'If you enable location, the group can see only your latest fresh '
        'position. Tracks, route progress and ride statistics begin when the '
        'leader starts the ride.',
      ),
    ),
  );
}

class ForegroundLocationCard extends StatelessWidget {
  const ForegroundLocationCard({
    super.key,
    required this.controller,
    this.preStart = false,
    this.onStopped,
  });

  final ForegroundLocationController controller;
  final bool preStart;
  final Future<void> Function()? onStopped;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final status = controller.status;
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: [
              Icon(
                controller.sharing
                    ? Icons.my_location
                    : Icons.location_disabled_outlined,
                color: controller.sharing
                    ? const Color(0xFF6ED89A)
                    : const Color(0xFF8EA7C4),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      preStart
                          ? 'Your assembly position'
                          : 'Your ride location',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      status.message,
                      style: const TextStyle(color: Color(0xFF9CA7B5)),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              TextButton(
                key: const Key('location-sharing-button'),
                onPressed:
                    status.state == DeviceLocationState.permissionDeniedForever
                    ? null
                    : controller.sharing
                    ? () async {
                        await controller.stop();
                        await onStopped?.call();
                      }
                    : controller.requestAndStart,
                child: Text(controller.sharing ? 'Stop' : _actionLabel(status)),
              ),
            ],
          ),
        ),
      );
    },
  );

  static String _actionLabel(DeviceLocationStatus status) =>
      switch (status.state) {
        DeviceLocationState.permissionDenied ||
        DeviceLocationState.idle => 'Enable',
        DeviceLocationState.permissionDeniedForever => 'Blocked',
        DeviceLocationState.serviceDisabled => 'Retry',
        DeviceLocationState.ready || DeviceLocationState.failed => 'Start',
        DeviceLocationState.sampling => 'Stop',
      };
}

class HazardDraft {
  const HazardDraft({required this.type, required this.severity, this.details});

  final HazardType type;
  final HazardSeverity severity;
  final String? details;
}

class HazardReportSheet extends StatefulWidget {
  const HazardReportSheet({super.key});

  @override
  State<HazardReportSheet> createState() => _HazardReportSheetState();
}

class _HazardReportSheetState extends State<HazardReportSheet> {
  HazardType _type = HazardType.roadworks;
  HazardSeverity _severity = HazardSeverity.caution;
  final _detailsController = TextEditingController();

  @override
  void dispose() {
    _detailsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        20,
        20,
        20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Report a hazard',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 18),
            DropdownButtonFormField<HazardType>(
              key: const Key('hazard-type-field'),
              initialValue: _type,
              decoration: const InputDecoration(labelText: 'Hazard'),
              items: riderReportableHazardTypes
                  .map(
                    (type) =>
                        DropdownMenuItem(value: type, child: Text(type.label)),
                  )
                  .toList(growable: false),
              onChanged: (value) => setState(() => _type = value ?? _type),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<HazardSeverity>(
              key: const Key('hazard-severity-field'),
              initialValue: _severity,
              decoration: const InputDecoration(labelText: 'Severity'),
              items: HazardSeverity.values
                  .map(
                    (severity) => DropdownMenuItem(
                      value: severity,
                      child: Text(severity.label),
                    ),
                  )
                  .toList(growable: false),
              onChanged: (value) =>
                  setState(() => _severity = value ?? _severity),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _detailsController,
              maxLength: 160,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Optional detail',
                hintText: 'e.g. gravel across both lanes',
              ),
            ),
            const SizedBox(height: 8),
            FilledButton(
              key: const Key('submit-hazard-button'),
              onPressed: () => Navigator.pop(
                context,
                HazardDraft(
                  type: _type,
                  severity: _severity,
                  details: _detailsController.text,
                ),
              ),
              child: const Text('Share with ride'),
            ),
          ],
        ),
      ),
    ),
  );
}

class HazardCard extends StatelessWidget {
  const HazardCard({super.key, required this.hazard, required this.onClear});

  final HazardReport hazard;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final color = _severityColor(hazard.severity);
    return Card(
      child: ListTile(
        leading: Icon(Icons.warning_amber_rounded, color: color),
        title: Text(hazard.type.label),
        subtitle: Text(
          '${hazard.severity.label} • ${hazard.confirmations} report'
          '${hazard.confirmations == 1 ? '' : 's'}'
          '${hazard.details == null ? '' : '\n${hazard.details}'}',
        ),
        isThreeLine: hazard.details != null,
        trailing: IconButton(
          tooltip: 'Clear hazard',
          onPressed: onClear,
          icon: const Icon(Icons.done),
        ),
      ),
    );
  }
}

class RiderStatusCard extends StatelessWidget {
  const RiderStatusCard({
    super.key,
    required this.displayName,
    required this.alert,
    this.onAcknowledge,
  });

  final String displayName;
  final RiderRouteAlert? alert;
  final VoidCallback? onAcknowledge;

  @override
  Widget build(BuildContext context) {
    final assessment = alert?.assessment;
    final level = assessment?.alertLevel ?? RouteAlertLevel.none;
    final color = _alertColor(level);
    return Card(
      child: ListTile(
        leading: Icon(_alertIcon(level), color: color),
        title: Text(displayName),
        subtitle: Text(assessment?.message ?? 'Location received.'),
        trailing: assessment?.coordinatorActionRequired == true
            ? TextButton(
                onPressed: onAcknowledge,
                child: Text(alert!.acknowledged ? 'Seen' : 'Acknowledge'),
              )
            : null,
      ),
    );
  }
}

class ProviderStatusCard extends StatelessWidget {
  const ProviderStatusCard({super.key, required this.provider});

  final ExternalHazardProvider provider;

  @override
  Widget build(BuildContext context) {
    final available = provider.status.canFetch;
    return Card(
      child: ListTile(
        leading: Icon(
          available ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
          color: available ? const Color(0xFF6ED89A) : const Color(0xFF8EA7C4),
        ),
        title: Text(provider.displayName),
        subtitle: Text(provider.status.message),
        trailing: Text(
          provider.status.state.label.toUpperCase(),
          style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800),
        ),
      ),
    );
  }
}

class _RouteStatusCard extends StatelessWidget {
  const _RouteStatusCard({required this.controller, this.rejoinGuidance});

  final SituationalAwarenessController controller;
  final String? rejoinGuidance;

  @override
  Widget build(BuildContext context) {
    final alerts = controller.routeAlerts;
    final urgent = alerts.where(
      (alert) => alert.assessment.coordinatorActionRequired,
    );
    final returningToRoute = rejoinGuidance != null;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF171D25),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: urgent.isEmpty
              ? const Color(0xFF2B3542)
              : const Color(0xFFFF715B),
        ),
      ),
      child: Row(
        children: [
          Icon(
            urgent.isEmpty ? Icons.route_outlined : Icons.crisis_alert,
            color: urgent.isEmpty
                ? const Color(0xFF6ED89A)
                : const Color(0xFFFF715B),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  returningToRoute
                      ? 'Return to the route'
                      : '${alerts.length} route alert'
                            '${alerts.length == 1 ? '' : 's'}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 3),
                if (!returningToRoute)
                  Text(
                    urgent.isEmpty
                        ? 'Check the rider shown below.'
                        : 'The ride coordinator may need to respond.',
                    style: const TextStyle(color: Color(0xFF9CA7B5)),
                  ),
                if (rejoinGuidance case final guidance?) ...[
                  const SizedBox(height: 8),
                  Text(
                    guidance,
                    key: const Key('rejoin-guidance-text'),
                    // The same cyan the breadcrumb is drawn in, from the one
                    // palette table, so the words and the line on the map read
                    // as one thing.
                    style: TextStyle(
                      color: RouteTrailStyle.rejoinBreadcrumb.color,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.action});

  final String title;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Text(
          title,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            color: const Color(0xFF8D98A7),
            letterSpacing: 1.1,
          ),
        ),
      ),
      ?action,
    ],
  );
}

class _EmptyCard extends StatelessWidget {
  const _EmptyCard({
    required this.icon,
    required this.title,
    required this.detail,
  });

  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Row(
        children: [
          Icon(icon, color: const Color(0xFF8EA7C4)),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 3),
                Text(detail, style: const TextStyle(color: Color(0xFF9CA7B5))),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message, required this.onDismiss});

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) => Material(
    color: const Color(0xFF552821),
    borderRadius: BorderRadius.circular(14),
    child: ListTile(
      leading: const Icon(Icons.error_outline),
      title: Text(message),
      trailing: IconButton(
        tooltip: 'Dismiss',
        onPressed: onDismiss,
        icon: const Icon(Icons.close),
      ),
    ),
  );
}

Color _severityColor(HazardSeverity severity) => switch (severity) {
  HazardSeverity.advisory => const Color(0xFF8EA7C4),
  HazardSeverity.caution => const Color(0xFFFFC857),
  HazardSeverity.serious => const Color(0xFFFF9D4D),
  HazardSeverity.critical => const Color(0xFFFF715B),
};

Color _alertColor(RouteAlertLevel level) => switch (level) {
  RouteAlertLevel.none => const Color(0xFF6ED89A),
  RouteAlertLevel.watch => const Color(0xFFFFC857),
  RouteAlertLevel.urgent => const Color(0xFFFF9D4D),
  RouteAlertLevel.critical => const Color(0xFFFF715B),
};

IconData _alertIcon(RouteAlertLevel level) => switch (level) {
  RouteAlertLevel.none => Icons.check_circle_outline,
  RouteAlertLevel.watch => Icons.location_searching,
  RouteAlertLevel.urgent => Icons.wrong_location_outlined,
  RouteAlertLevel.critical => Icons.crisis_alert,
};
