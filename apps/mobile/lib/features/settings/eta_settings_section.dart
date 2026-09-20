import 'package:flutter/material.dart';
import '../../controllers/eta_calibration_controller.dart';

class EtaSettingsSection extends StatelessWidget {
  const EtaSettingsSection({super.key});
  @override
  Widget build(BuildContext context) {
    final controller = EtaCalibrationScope.of(context);
    if (controller == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Arrival estimates',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: const Text('Learn from my rides'),
          subtitle: Text(
            '${controller.sampleCount} suitable completed rides. Long breaks are excluded. Learning stays on this phone.',
          ),
          value: controller.enabled,
          onChanged: controller.setEnabled,
        ),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: const Text('Contribute to motorcycle estimates'),
          subtitle: const Text(
            'Optional: share rounded timing ratios for three broad road types. No routes, trip times, speeds or account identity. Trends need at least 20 contributors; profiles expire after 90 days. Switching off removes your contribution.',
          ),
          value: controller.contributing,
          onChanged: controller.setContributing,
        ),
        Text(
          controller.hasPopulation
              ? 'Anonymous motorcycle trends are available.'
              : 'Not enough shared evidence yet; provider estimates are the starting point.',
        ),
        if (controller.syncMessage case final message?) Text(message),
        Wrap(
          spacing: 8,
          children: [
            TextButton(
              onPressed: controller.reset,
              child: const Text('Reset personal learning'),
            ),
            if (controller.syncMessage != null)
              TextButton(
                onPressed: () => controller.sync(force: true),
                child: const Text('Retry sync'),
              ),
          ],
        ),
      ],
    );
  }
}
