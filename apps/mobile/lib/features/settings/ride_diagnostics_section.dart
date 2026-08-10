import 'package:flutter/material.dart';

import '../../controllers/ride_diagnostics_controller.dart';

/// The runtime half of the ride-diagnostics gate (#419).
///
/// Renders **nothing** in an ordinary build, the way [TestControlSection] does:
/// the recorder is not in the binary there, so offering a switch for it would be
/// offering a control that cannot work.
///
/// The wording is deliberately plain about what is recorded. A rider who finds
/// this switched on should not have to infer "records where I went" from the word
/// "diagnostics" — that is the same reasoning `docs/test-control-api.md` gives for
/// why its row says another machine can drive the app rather than saying "debug".
class RideDiagnosticsSection extends StatelessWidget {
  const RideDiagnosticsSection({super.key, required this.controller});

  final RideDiagnosticsController controller;

  @override
  Widget build(BuildContext context) {
    if (!controller.isAvailable) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => SwitchListTile.adaptive(
        key: const Key('ride-diagnostics-toggle'),
        contentPadding: EdgeInsets.zero,
        value: controller.isOn,
        onChanged: controller.setEnabled,
        title: const Text('Record ride diagnostics'),
        subtitle: const Text(
          'Writes down each turn instruction, when it was spoken, every alert, '
          'and this phone’s own route, so a wrong instruction can be explained '
          'afterwards. No other rider’s position is recorded. Nothing is sent '
          'anywhere until you choose a recipient when you share the ride.',
        ),
      ),
    );
  }
}
