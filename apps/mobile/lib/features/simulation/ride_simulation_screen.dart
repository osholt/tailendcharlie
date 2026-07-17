import 'dart:async';

import 'package:flutter/material.dart';

import '../../controllers/ride_simulation_controller.dart';
import '../../domain/ride_role.dart';

class RideSimulationScreen extends StatelessWidget {
  const RideSimulationScreen({
    super.key,
    required this.controller,
    required this.onRestart,
    required this.onExit,
  });

  final RideSimulationController controller;
  final Future<void> Function() onRestart;
  final Future<void> Function() onExit;

  @override
  Widget build(BuildContext context) {
    final landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: landscape ? 42 : 52,
        title: const Text('Ride Lab'),
        actions: [
          IconButton(
            tooltip: 'Restart simulation',
            onPressed: () => unawaited(onRestart()),
            icon: const Icon(Icons.replay),
          ),
          IconButton(
            tooltip: 'Exit simulation',
            onPressed: () => unawaited(onExit()),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        bottom: false,
        child: AnimatedBuilder(
          animation: controller,
          builder: (context, _) {
            final controls = _SimulationControls(controller: controller);
            final fleet = _FleetCard(controller: controller);
            if (landscape) {
              return Padding(
                padding: const EdgeInsets.all(10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: SingleChildScrollView(child: controls)),
                    const SizedBox(width: 10),
                    Expanded(child: SingleChildScrollView(child: fleet)),
                  ],
                ),
              );
            }
            return ListView(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 28),
              children: [controls, const SizedBox(height: 12), fleet],
            );
          },
        ),
      ),
    );
  }
}

class _SimulationControls extends StatelessWidget {
  const _SimulationControls({required this.controller});

  final RideSimulationController controller;

  @override
  Widget build(BuildContext context) {
    final status = switch (controller.state) {
      RideSimulationState.ready => 'READY',
      RideSimulationState.running => 'RUNNING',
      RideSimulationState.paused => 'PAUSED',
      RideSimulationState.completed => 'FINISHED',
    };
    final statusColor = switch (controller.state) {
      RideSimulationState.running => const Color(0xFF6ED89A),
      RideSimulationState.completed => Theme.of(context).colorScheme.primary,
      _ => const Color(0xFFFFC857),
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.science_outlined, color: statusColor),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'SYNTHETIC RIDE',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                _Pill(label: status, color: statusColor),
              ],
            ),
            const SizedBox(height: 10),
            const Text(
              'Five virtual bikes use the real navigation, TEC and off-course '
              'logic. Device GPS, internet relay and nearby radios are off.',
              style: TextStyle(color: Color(0xFFADB7C4), height: 1.35),
            ),
            const SizedBox(height: 14),
            LinearProgressIndicator(value: controller.progress),
            const SizedBox(height: 8),
            Text(
              '${(controller.progress * 100).round()}% route · '
              '${_duration(controller.simulatedElapsed)} simulated',
              style: const TextStyle(color: Color(0xFF8F9BAA)),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    key: const Key('simulation-play-pause'),
                    onPressed: controller.state == RideSimulationState.completed
                        ? null
                        : controller.isRunning
                        ? controller.pause
                        : controller.start,
                    icon: Icon(
                      controller.isRunning ? Icons.pause : Icons.play_arrow,
                    ),
                    label: Text(controller.isRunning ? 'Pause' : 'Run'),
                  ),
                ),
                const SizedBox(width: 10),
                Tooltip(
                  message: 'Simulation time scale',
                  child: DropdownButton<double>(
                    key: const Key('simulation-speed'),
                    value: controller.timeScale,
                    items: const [1.0, 4.0, 8.0, 16.0]
                        .map(
                          (value) => DropdownMenuItem(
                            value: value,
                            child: Text('${value.toInt()}×'),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value != null) controller.setTimeScale(value);
                    },
                  ),
                ),
              ],
            ),
            const Divider(height: 28),
            SwitchListTile.adaptive(
              key: const Key('simulation-off-route'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Send Alex off route'),
              subtitle: const Text('Builds the magenta trail and leader alert'),
              value: controller.alexOffRoute,
              onChanged: controller.setAlexOffRoute,
            ),
            SwitchListTile.adaptive(
              key: const Key('simulation-tec-delay'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Delay Tail End Charlie'),
              subtitle: const Text('Increases the lead-to-TEC gap'),
              value: controller.tecDelayed,
              onChanged: controller.setTecDelayed,
            ),
            const SizedBox(height: 6),
            OutlinedButton.icon(
              key: const Key('simulation-hazard'),
              onPressed: () => unawaited(controller.reportRoadworks()),
              icon: const Icon(Icons.warning_amber_rounded),
              label: const Text('Drop roadworks hazard'),
            ),
            const SizedBox(height: 8),
            const Text(
              'Open the Map tab to watch the production UI respond.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Color(0xFF7F8A98), fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  static String _duration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }
}

class _FleetCard extends StatelessWidget {
  const _FleetCard({required this.controller});

  final RideSimulationController controller;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('VIRTUAL FLEET', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          for (final rider in controller.riders) ...[
            Row(
              children: [
                Icon(
                  rider.isLocal ? Icons.navigation : Icons.two_wheeler,
                  color: rider.isOffRoute
                      ? const Color(0xFFFF4FA3)
                      : const Color(0xFF6ED89A),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        rider.displayName,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        '${rider.role.label} · '
                        '${(rider.speedMetersPerSecond * 2.23694).round()} mph',
                        style: const TextStyle(
                          color: Color(0xFF8F9BAA),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                if (rider.isOffRoute)
                  const _Pill(label: 'OFF ROUTE', color: Color(0xFFFF4FA3))
                else
                  Text('${(rider.progress * 100).round()}%'),
              ],
            ),
            const SizedBox(height: 7),
            LinearProgressIndicator(value: rider.progress, minHeight: 3),
            const SizedBox(height: 13),
          ],
        ],
      ),
    ),
  );
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(
      label,
      style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 11),
    ),
  );
}
