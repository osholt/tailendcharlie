import 'package:flutter/material.dart';

import '../../controllers/ride_controller.dart';
import 'marker_assistance_widgets.dart';

/// The one confirmation for ending a ride, wherever it is reached from.
///
/// Ending a ride is the app's most destructive action — it stops the group, not
/// just this phone — and it was reachable two ways, from the ride menu and from
/// the dashboard header, each with its own dialog saying different things
/// (#306: "every destructive or safety action reachable by the same gesture
/// every time").
///
/// The two were not merely worded differently. Only the ride menu's told the
/// leader whether the ride could be resumed, including the sentence "this
/// action cannot be undone for the group" when the relay cannot carry a reopen.
/// Only the dashboard's showed the marking summary and offered to share it
/// first. **So whether a leader learned that ending the ride was irreversible
/// depended on which button they happened to press.**
///
/// This is the union of the two, not the intersection: nothing either of them
/// said is lost, and both entry points now say all of it. Which of the two
/// entry points survives the consolidation is a separate question — this makes
/// them agree in the meantime.
Future<bool> confirmEndRide(
  BuildContext context, {
  required RideController controller,
  required bool relayCanCarryReopen,
  Future<void> Function()? onShareSummary,
}) async {
  // `isLocalRideLeader`, which is the app's own definition of who may end a
  // ride, and the same condition both entry points use to decide whether to
  // offer it at all.
  //
  // Consolidating the two dialogs exposed a latent defect here. The ride menu
  // offers End ride on `isLocalRideLeader`, but the shell's own guard read
  // `session?.role != RideRole.lead` and returned — and those differ, because
  // `isLocalRideLeader` is also true for a leader currently acting as the
  // marker, where `session.role` is not `lead`. So a leader who took the marker
  // role could see End ride in the ride menu, tap it, and have nothing happen
  // at all. Offering an action and refusing it silently is worse than not
  // offering it.
  if (!controller.isLocalRideLeader) return false;
  final summary = controller.markingSummary;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('End this ride?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(endRideConsequence(relayCanCarryReopen: relayCanCarryReopen)),
          const SizedBox(height: 14),
          EndRideMarkingSummary(summary: summary),
        ],
      ),
      actions: [
        if (onShareSummary != null)
          TextButton.icon(
            key: const Key('end-ride-share-summary'),
            onPressed: () => onShareSummary(),
            icon: const Icon(Icons.summarize_outlined),
            label: const Text('Share summary'),
          ),
        TextButton(
          key: const Key('cancel-end-ride'),
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('confirm-end-ride'),
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('End ride'),
        ),
      ],
    ),
  );
  if (!(confirmed ?? false)) return false;
  await controller.endRide();
  return true;
}

/// What ending the ride actually does, in one place so the two entry points
/// cannot disagree about whether it can be undone.
///
/// The irreversibility sentence is the half that was missing from the dashboard
/// dialog, and it is the half a leader needs most.
String endRideConsequence({required bool relayCanCarryReopen}) =>
    'This ends the group ride for everyone. Location sharing stops on this '
    'phone, and relay recovery stays available for final queued events until '
    'you file the ended ride.\n\n'
    '${relayCanCarryReopen ? 'You can resume it within 24 hours without changing the ride code.' : 'This relay cannot resume an ended ride on the other phones. This action cannot be undone for the group.'}';
