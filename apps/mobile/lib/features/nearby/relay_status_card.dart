import 'package:flutter/material.dart';

import '../../controllers/nearby_relay_controller.dart';
import '../../relay/relay_engine.dart';
import '../../services/transport_evidence_ledger.dart';
import '../../services/transport_evidence_presentation.dart';

/// The direct phone-to-phone link: whether it is up, and what has come over it.
///
/// The title is the same ride-level line the roster shows (#855), so the two
/// cannot disagree. The line under it used to say the link "does not carry ride
/// events yet", which stopped being true when the relay engine and its durable
/// queue shipped, and which contradicted the evidence the rest of the app now
/// shows. It says what has actually been received instead.
class RelayStatusCard extends StatelessWidget {
  const RelayStatusCard({required this.controller, this.evidence, super.key});

  final NearbyRelayController controller;

  /// Which route delivered each update, for the line about what has arrived.
  /// Without it the card says only what is queued.
  final TransportEvidenceLedger? evidence;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final status = controller.status;
      final icon = switch (status.state) {
        RelayConnectionState.connected => Icons.bluetooth_connected,
        RelayConnectionState.searching => Icons.radar,
        RelayConnectionState.backingOff => Icons.sync_problem,
        RelayConnectionState.unavailable => Icons.bluetooth_disabled,
        RelayConnectionState.failed => Icons.error_outline,
        RelayConnectionState.starting => Icons.sync,
        RelayConnectionState.stopped => Icons.bluetooth,
      };
      final queued = status.queuedEventCount == 0
          ? null
          : '${status.queuedEventCount} held for nearby phones';
      final received = evidence == null
          ? null
          : bluetoothReceivedLine(evidence!.summary().bluetooth);
      return Card(
        child: ListTile(
          leading: Icon(icon),
          title: Text(bluetoothLinkLine(status)),
          subtitle: Text(
            [?received, ?queued].isEmpty
                ? 'Nothing held for nearby phones'
                : [?received, ?queued].join(' · '),
          ),
        ),
      );
    },
  );
}
