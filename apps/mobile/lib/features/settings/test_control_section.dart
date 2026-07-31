import 'package:flutter/material.dart';

import '../../controllers/test_control_controller.dart';
import '../../services/test_control_configuration.dart';

/// Shown **only** while the app is actually being driven, and carries no switch.
///
/// The switch lives in the iOS Settings app (`ios/Runner/Settings.bundle`), not
/// here. That is deliberate: a rider who stumbles across an in-app control
/// offering to let another machine drive their safety app is a worse outcome than
/// a field tester having to leave the app to turn it on. While the surface is off
/// this renders nothing at all — no row, no heading, no hint that the capability
/// exists.
///
/// What it does show, when on, is a warning that does not hedge, plus the access
/// token a driver needs. Anyone who picks up this phone should be able to tell
/// from one screen that something else can act through the app, and how to stop
/// it.
class TestControlSection extends StatelessWidget {
  const TestControlSection({super.key, required this.controller});

  final TestControlController controller;

  @override
  Widget build(BuildContext context) {
    if (!TestControlConfiguration.enabled) return const SizedBox.shrink();
    final theme = Theme.of(context);

    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        // Nothing to say while nothing is being driven, and nothing at all if
        // the switch was never set.
        if (!controller.switchRequested) return const SizedBox.shrink();

        // The one state that needs explaining: the switch is on but no usable
        // token was set, so the surface is serving nothing. Silence here would
        // look like the switch simply did not work.
        if (controller.needsToken) {
          return Container(
            key: const Key('test-control-needs-token'),
            margin: const EdgeInsets.only(top: 20),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF3A2F16),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFFE0B341)),
            ),
            child: Text(
              'Field test control is switched on but no access token is set, so '
              'nothing is being served and nothing can reach this phone.\n\n'
              'Set a token of at least '
              '${TestControlController.minimumTokenLength} characters in the iOS '
              'Settings app under Tail End Charlie → Field test control, or turn '
              'the switch off.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: const Color(0xFFF6E6BE),
                height: 1.45,
              ),
            ),
          );
        }

        return Container(
          key: const Key('test-control-active-warning'),
          margin: const EdgeInsets.only(top: 20),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFF4A1520),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFFFF7F98)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.warning_amber_rounded,
                    color: Color(0xFFFFD3DB),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Another machine can control this app',
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: const Color(0xFFFFF5F6),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                'A computer on this network can create rides, join, start them, '
                'report hazards and read this ride’s roster on this phone. '
                'The screen is being kept awake.\n\n'
                'Emergency actions, phone numbers and emergency-contact details '
                'can never be reached this way.\n\n'
                'Turn this off in the iOS Settings app under Tail End Charlie '
                '→ Field test control.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: const Color(0xFFFFD3DB),
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 12),
              // The token itself is not printed. The operator set it in iOS
              // Settings, so they already have it, and rendering a live secret
              // on a phone screen only makes it shoulder-readable. The length is
              // enough to confirm the right one is in place.
              Text(
                'Listening on port ${TestControlConfiguration.defaultPort} with a '
                '${controller.tokenLength}-character token. Stops serving after '
                '${TestControlConfiguration.defaultIdleTimeout.inMinutes} minutes '
                'of no activity.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: const Color(0xFFE9A8B6),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
