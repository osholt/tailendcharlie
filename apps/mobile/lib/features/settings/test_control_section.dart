import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../controllers/test_control_controller.dart';
import '../../services/test_control_configuration.dart';

/// The in-app switch that opens the test-control surface, and the token a driver
/// needs to use it.
///
/// Renders nothing at all unless [TestControlConfiguration.enabled] - a build
/// without the compile-time define has no surface to describe, and a settings row
/// implying otherwise would be a lie about what the binary can do.
///
/// The copy is deliberately blunt. A rider who finds this switch on their own
/// phone should understand from the row alone that another machine can drive the
/// app, not have to infer it from the word "debug".
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
        final token = controller.token;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 20),
            Text(
              'FIELD TEST CONTROL',
              style: theme.textTheme.labelLarge?.copyWith(
                color: const Color(0xFF8D98A7),
                letterSpacing: 1.1,
              ),
            ),
            const SizedBox(height: 6),
            SwitchListTile.adaptive(
              key: const Key('test-control-toggle'),
              contentPadding: EdgeInsets.zero,
              value: controller.isOn,
              onChanged: (wanted) async {
                if (wanted) {
                  await controller.turnOn();
                } else {
                  await controller.turnOff();
                }
              },
              title: const Text('Allow another machine to drive this app'),
              subtitle: Text(
                controller.isOn
                    ? 'On. A computer on this network can create rides, join, '
                          'start, report hazards and read the roster on this '
                          'phone. Turns itself off after '
                          '${TestControlConfiguration.defaultIdleTimeout.inMinutes} '
                          'minutes of no activity.'
                    : 'Off. Only turn this on for a field test you are running. '
                          'Emergency actions and anyone’s phone number are '
                          'never reachable this way.',
              ),
            ),
            if (controller.isOn && token != null) ...[
              const SizedBox(height: 4),
              ListTile(
                key: const Key('test-control-token'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.key_outlined),
                title: const Text('Access token'),
                subtitle: Text(
                  '$token\n\nPort ${TestControlConfiguration.defaultPort}. '
                  'A new token is issued every time this is switched on, and '
                  'when the app restarts.',
                ),
                trailing: IconButton(
                  key: const Key('test-control-copy-token'),
                  icon: const Icon(Icons.copy_outlined),
                  tooltip: 'Copy token',
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: token));
                    if (!context.mounted) return;
                    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                      const SnackBar(content: Text('Token copied.')),
                    );
                  },
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}
