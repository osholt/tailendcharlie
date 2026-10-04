import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/ride_alert_record.dart';
import '../../services/ride_alert_log.dart';

/// The alerts a ride raised, each with its time to the second, where it was
/// raised and who raised it (#849).
///
/// It exists so a rider can find the same moment in dash-cam footage afterwards:
/// every time is one tap from the clipboard, in the form a footage player shows,
/// and the whole list copies as text. It is shown on the ride-ended screen and on
/// a previous ride, and nowhere else, because an alert is only a moment worth
/// reviewing once the ride is over.
///
/// Shows nothing when the ride raised none - an empty card would only ask the
/// rider to wonder where the alerts had gone.
class RideAlertsCard extends StatelessWidget {
  const RideAlertsCard({super.key, required this.alerts});

  final List<RideAlertRecord> alerts;

  @override
  Widget build(BuildContext context) {
    if (alerts.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Card(
      key: const Key('ride-alerts-card'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    alerts.length == 1 ? '1 alert' : '${alerts.length} alerts',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                TextButton.icon(
                  key: const Key('ride-alerts-copy-all'),
                  onPressed: () => _copy(
                    context,
                    text: rideAlertLogText(alerts),
                    confirmation: 'Copied all ${alerts.length} alerts',
                  ),
                  icon: const Icon(Icons.copy_all_outlined, size: 18),
                  label: const Text('Copy all'),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8, bottom: 6),
              child: Text(
                // The zone is named because the footage's clock does not follow
                // this phone's: a ride reviewed in another country than it was
                // ridden in is an hour out, and UTC is in what "Copy all" copies.
                'Times are to the second, in this phone’s time zone '
                '(${rideAlertTimeZoneLabel(alerts.first.raisedAt)}). Tap one '
                'to copy it.',
                key: const Key('ride-alerts-time-note'),
                style: const TextStyle(
                  color: Color(0xFF8994A2),
                  fontSize: 12,
                  height: 1.35,
                ),
              ),
            ),
            for (final alert in alerts) _AlertRow(alert: alert),
          ],
        ),
      ),
    );
  }
}

class _AlertRow extends StatelessWidget {
  const _AlertRow({required this.alert});

  final RideAlertRecord alert;

  @override
  Widget build(BuildContext context) {
    final who = alert.raisedByLocalRider
        ? '${alert.raisedBy} (you)'
        : alert.raisedBy;
    final qualifier = alert.kind.qualifier;
    final kind = qualifier == null ? '' : ' · $qualifier';
    void copy() => _copy(
      context,
      text: alert.timestampLabel,
      confirmation: 'Copied ${alert.timestampLabel}',
    );
    return Semantics(
      container: true,
      button: true,
      // One node for the whole row, read once: the time, who and where, with the
      // action it has. Without this the row's own text and the copy button's
      // tooltip were all read out separately, the time twice.
      label:
          'Alert at ${alert.clockLabel}, raised by $who, '
          '${alert.positionLabel}',
      onTapHint: 'Copy the time',
      onTap: copy,
      excludeSemantics: true,
      child: InkWell(
        key: Key('ride-alert-row-${alert.id}'),
        borderRadius: BorderRadius.circular(10),
        onTap: copy,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(0, 0, 12, 0),
                child: Icon(
                  Icons.add_alert_rounded,
                  color: Color(0xFFFFC857),
                  size: 22,
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      alert.clockLabel,
                      key: Key('ride-alert-time-${alert.id}'),
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        // Digits of one width, so a column of times lines up and
                        // can be read down against a footage timeline.
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                    Text(
                      '$who$kind · ${alert.positionLabel}',
                      key: Key('ride-alert-detail-${alert.id}'),
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
                key: Key('ride-alert-copy-${alert.id}'),
                tooltip: 'Copy ${alert.timestampLabel}',
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

Future<void> _copy(
  BuildContext context, {
  required String text,
  required String confirmation,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  await Clipboard.setData(ClipboardData(text: text));
  messenger?.showSnackBar(
    SnackBar(content: Text(confirmation), duration: const Duration(seconds: 2)),
  );
}
