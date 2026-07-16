import 'package:flutter/material.dart';

import '../../controllers/internet_relay_controller.dart';
import '../../internet/internet_relay_worker.dart';

class InternetRelayStatusCard extends StatelessWidget {
  const InternetRelayStatusCard({super.key, required this.controller});

  final InternetRelayController controller;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final status = controller.status;
      final presentation = _presentation(status.phase);
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: [
              Icon(presentation.icon, color: presentation.color, size: 28),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      presentation.title,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      _detail(status),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF9AA6B5),
                      ),
                    ),
                  ],
                ),
              ),
              if (status.pendingEventCount > 0)
                Text(
                  '${status.pendingEventCount} queued',
                  style: TextStyle(
                    color: presentation.color,
                    fontWeight: FontWeight.w700,
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );

  String _detail(InternetRelayStatus status) {
    if (status.phase == InternetRelayPhase.unconfigured) {
      return 'Set RIDE_RELAY_API_BASE_URL · no server traffic';
    }
    final nextAttempt = status.nextAttemptAt;
    if (nextAttempt != null) {
      final seconds = nextAttempt
          .difference(DateTime.now())
          .inSeconds
          .clamp(0, 300);
      return '${status.message} · retry in ${seconds}s';
    }
    return status.message;
  }

  _InternetPresentation _presentation(InternetRelayPhase phase) =>
      switch (phase) {
        InternetRelayPhase.unconfigured => const _InternetPresentation(
          title: 'Internet relay not configured',
          icon: Icons.cloud_off_outlined,
          color: Color(0xFF8D98A7),
        ),
        InternetRelayPhase.stopped => const _InternetPresentation(
          title: 'Internet relay stopped',
          icon: Icons.cloud_off_outlined,
          color: Color(0xFF8D98A7),
        ),
        InternetRelayPhase.syncing => const _InternetPresentation(
          title: 'Internet relay synchronizing',
          icon: Icons.cloud_sync_outlined,
          color: Color(0xFF62B5FF),
        ),
        InternetRelayPhase.synced => const _InternetPresentation(
          title: 'Server sync succeeded',
          icon: Icons.cloud_done_outlined,
          color: Color(0xFF6ED89A),
        ),
        InternetRelayPhase.retrying => const _InternetPresentation(
          title: 'Internet relay reconnecting',
          icon: Icons.cloud_sync_outlined,
          color: Color(0xFFFFC857),
        ),
        InternetRelayPhase.unauthorized => const _InternetPresentation(
          title: 'Internet relay credential rejected',
          icon: Icons.cloud_off_outlined,
          color: Color(0xFFFF8A4C),
        ),
        InternetRelayPhase.failed => const _InternetPresentation(
          title: 'Internet relay response rejected',
          icon: Icons.error_outline,
          color: Color(0xFFFF5D73),
        ),
      };
}

class _InternetPresentation {
  const _InternetPresentation({
    required this.title,
    required this.icon,
    required this.color,
  });

  final String title;
  final IconData icon;
  final Color color;
}
