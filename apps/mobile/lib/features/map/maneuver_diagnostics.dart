import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/navigation_guidance.dart';

/// What the routing engine said about one turn, and what this app made of it.
///
/// Two issues from the ride of 2 August 2026 are blocked on the same missing
/// thing: a 90-degree right announced as a sharp right (#302), and a roundabout
/// exit icon that looked like the wrong way round (#301). Both diagnoses ended
/// at "capture the raw manoeuvre JSON for the reported junction before touching
/// any code", and there was no way for a rider to capture it.
///
/// This is that way. It is deliberately the same instinct as #281's basemap
/// badge: rather than guess at a cause that only appears on a particular road,
/// make the next occurrence arrive with the answer attached.
///
/// It shows the engine's own words beside the app's reading of them, because
/// the single most useful fact about a turn that came out wrong is **which of
/// the two produced the direction**. A stated modifier means the app repeated
/// the engine; an unrecognised one means the app worked the direction out from
/// bearings, and those have different fixes.
String maneuverDiagnosticsReport(
  ManeuverInstruction instruction, {
  int? position,
}) {
  final maneuver = instruction.maneuver;
  final modifier = maneuver.modifier;
  final fromModifier = directionFromModifier(modifier);
  final headingChange = maneuverHeadingChangeDegrees(maneuver);
  final fromGeometry = headingChange == null
      ? null
      : directionFromHeadingChange(
          headingChange,
          straightBandDegrees: instruction.kind == ManeuverKind.roundabout
              ? maneuverRoundaboutStraightBandDegrees
              : maneuverStraightBandDegrees,
        );

  String label(ManeuverDirection direction) =>
      direction.isStated ? direction.label : 'unstated';

  final lines = <String>[
    'Tail End Charlie · turn detail${position == null ? '' : ' $position'}',
    'Instruction:      ${instruction.standaloneText}',
    'Shown as:         ${label(instruction.direction)} (${instruction.kind.name})',
    'Engine type:      ${maneuver.type}',
    'Engine modifier:  ${modifier ?? '—'}'
        '${modifier != null && !fromModifier.isStated ? '  (NOT RECOGNISED)' : ''}',
    'Modifier reads as: ${label(fromModifier)}',
    'Bearing before:   ${_degrees(maneuver.bearingBeforeDegrees)}',
    'Bearing after:    ${_degrees(maneuver.bearingAfterDegrees)}',
    'Heading change:   ${_signed(headingChange)}',
    'Geometry reads as: ${fromGeometry == null ? '—' : label(fromGeometry)}',
    'Exit number:      ${instruction.exitNumber ?? '—'}',
    'Driving side:     ${maneuver.drivingSide ?? '—'}',
    'Steps merged:     ${instruction.stepCount}',
    'Road:             ${instruction.roadLabel}',
    'Position:         ${maneuver.position.latitude.toStringAsFixed(6)}, '
        '${maneuver.position.longitude.toStringAsFixed(6)}',
  ];
  return lines.join('\n');
}

String _degrees(double? value) =>
    value == null ? '—' : '${value.toStringAsFixed(1)}°';

/// Signed and named, because "+130°" alone reads as an angle rather than as a
/// direction of travel, and the sign is the half that says which way.
String _signed(double? value) {
  if (value == null) return '—';
  final rounded = value.toStringAsFixed(1);
  if (value == 0) return '0.0° (straight on)';
  return value > 0
      ? '+$rounded° (clockwise, to the right)'
      : '$rounded° (anticlockwise, to the left)';
}

/// Shows [maneuverDiagnosticsReport] with a button that copies it.
///
/// Copyable because the reporting channel is the tester group: a rider who has
/// just been sent the wrong way needs to paste a dozen lines into a chat, not
/// transcribe them at the roadside.
class ManeuverDiagnosticsSheet extends StatelessWidget {
  const ManeuverDiagnosticsSheet({
    super.key,
    required this.instruction,
    this.position,
  });

  final ManeuverInstruction instruction;
  final int? position;

  static Future<void> show(
    BuildContext context,
    ManeuverInstruction instruction, {
    int? position,
  }) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: const Color(0xFF171D25),
    builder: (_) =>
        ManeuverDiagnosticsSheet(instruction: instruction, position: position),
  );

  @override
  Widget build(BuildContext context) {
    final report = maneuverDiagnosticsReport(instruction, position: position);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'What the router said about this turn',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          const Text(
            'If a turn was announced wrongly, send this with your report. It '
            'is what tells us whether the router got it wrong or we did.',
            style: TextStyle(color: Color(0xFFABB5C1), height: 1.4),
          ),
          const SizedBox(height: 14),
          Flexible(
            child: SingleChildScrollView(
              child: SelectableText(
                report,
                key: const Key('maneuver-diagnostics-report'),
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontFamilyFallback: ['Menlo', 'Courier'],
                  fontSize: 12,
                  height: 1.5,
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            key: const Key('copy-maneuver-diagnostics'),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: report));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context)
                ..hideCurrentSnackBar()
                ..showSnackBar(
                  const SnackBar(content: Text('Turn detail copied')),
                );
            },
            icon: const Icon(Icons.copy_all_outlined),
            label: const Text('Copy turn detail'),
          ),
        ],
      ),
    );
  }
}
