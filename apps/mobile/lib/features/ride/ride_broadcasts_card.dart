import 'package:flutter/material.dart';

import '../../domain/quick_message.dart';
import '../../domain/ride_broadcast_record.dart';
import '../../services/ride_broadcast_log.dart';
import '../../services/ride_log_time.dart';
import '../map/ride_map_feature.dart' show quickMessageIcon;
import 'ride_log_copy.dart';

/// What the leader told the group during the ride, each with its time to the
/// second (#854): the ride history of "Pull over", "Wrong way", "Regroup at next
/// stop".
///
/// Shown on the ride-ended screen and on a previous ride, beside the alerts card
/// and for the same reason: afterwards, a rider reconciles where the group stopped
/// with what they were told, and with footage. Every time is one tap from the
/// clipboard.
///
/// Shows nothing when the leader sent none.
class RideBroadcastsCard extends StatelessWidget {
  const RideBroadcastsCard({super.key, required this.broadcasts});

  final List<RideBroadcastRecord> broadcasts;

  @override
  Widget build(BuildContext context) {
    if (broadcasts.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Card(
      key: const Key('ride-broadcasts-card'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    broadcasts.length == 1
                        ? '1 leader message'
                        : '${broadcasts.length} leader messages',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                TextButton.icon(
                  key: const Key('ride-broadcasts-copy-all'),
                  onPressed: () => copyRideLogText(
                    context,
                    text: rideBroadcastLogText(broadcasts),
                    confirmation: 'Copied all ${broadcasts.length} messages',
                  ),
                  icon: const Icon(Icons.copy_all_outlined, size: 18),
                  label: const Text('Copy all'),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8, bottom: 6),
              child: Text(
                'Times are to the second, in this phone’s time zone '
                '(${rideLogTimeZoneLabel(broadcasts.first.sentAt)}). Tap one '
                'to copy it.',
                key: const Key('ride-broadcasts-time-note'),
                style: const TextStyle(
                  color: Color(0xFF8994A2),
                  fontSize: 12,
                  height: 1.35,
                ),
              ),
            ),
            for (final broadcast in broadcasts)
              _BroadcastRow(record: broadcast),
          ],
        ),
      ),
    );
  }
}

class _BroadcastRow extends StatelessWidget {
  const _BroadcastRow({required this.record});

  final RideBroadcastRecord record;

  @override
  Widget build(BuildContext context) {
    final who = record.sentByLocalRider
        ? '${record.sentBy} (you)'
        : record.sentBy;
    void copy() => copyRideLogText(
      context,
      text: record.timestampLabel,
      confirmation: 'Copied ${record.timestampLabel}',
    );
    return Semantics(
      container: true,
      button: true,
      label: '${record.text}, sent by $who at ${record.clockLabel}',
      onTapHint: 'Copy the time',
      onTap: copy,
      excludeSemantics: true,
      child: InkWell(
        key: Key('ride-broadcast-row-${record.id}'),
        borderRadius: BorderRadius.circular(10),
        onTap: copy,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Icon(
                  quickMessageIcon(tryParseQuickMessage(record.kind)),
                  color: const Color(0xFF8FC4F5),
                  size: 22,
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      record.clockLabel,
                      key: Key('ride-broadcast-time-${record.id}'),
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                    Text(
                      '$who: ${record.text}',
                      key: Key('ride-broadcast-text-${record.id}'),
                      style: const TextStyle(
                        color: Color(0xFFABB5C1),
                        fontSize: 12.5,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                key: Key('ride-broadcast-copy-${record.id}'),
                tooltip: 'Copy ${record.timestampLabel}',
                onPressed: copy,
                icon: const Icon(Icons.copy_outlined, size: 20),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
