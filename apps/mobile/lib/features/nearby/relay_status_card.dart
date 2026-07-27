import 'package:flutter/material.dart';

import '../../controllers/nearby_relay_controller.dart';
import '../../relay/relay_engine.dart';

class RelayStatusCard extends StatelessWidget {
  const RelayStatusCard({required this.controller, super.key});

  final NearbyRelayController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final status = controller.status;
      final (icon, label) = switch (status.state) {
        RelayConnectionState.connected => (
          Icons.bluetooth_connected,
          '${status.peerIds.length} nearby',
        ),
        RelayConnectionState.searching => (Icons.radar, 'Searching nearby'),
        RelayConnectionState.backingOff => (
          Icons.sync_problem,
          'Reconnecting automatically',
        ),
        RelayConnectionState.unavailable => (
          Icons.bluetooth_disabled,
          'Nearby unavailable',
        ),
        RelayConnectionState.failed => (Icons.error_outline, 'Nearby error'),
        RelayConnectionState.starting => (Icons.sync, 'Starting nearby'),
        RelayConnectionState.stopped => (Icons.bluetooth, 'Nearby stopped'),
      };
      return Card(
        child: ListTile(
          leading: Icon(icon),
          title: Text(label),
          // "development alpha" was a build channel leaking into a rider-facing
          // card, and a bare count told a tester nothing about whether 106 was
          // normal (#174). The nearby transport genuinely does not carry events
          // yet, so say that instead - it is the useful half of what the build
          // channel was standing in for.
          subtitle: Text(
            status.queuedEventCount == 0
                ? 'Not carrying ride events yet'
                : '${status.queuedEventCount} held for nearby, which does not '
                      'carry ride events yet',
          ),
        ),
      );
    },
  );
}
