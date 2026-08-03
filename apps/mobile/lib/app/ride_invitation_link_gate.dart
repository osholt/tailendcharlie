import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/ride_code_preference_controller.dart';
import '../controllers/ride_controller.dart';
import '../controllers/ride_invitation_link_controller.dart';
import '../controllers/rider_profile_controller.dart';

/// Presents one native App/Universal Link as a deliberate join action.
///
/// This sits above both the home and active-ride surfaces. A link can arrive at
/// cold start or while the map is open, but it must never silently replace the
/// ride whose journal, role and safety state are already active on the phone.
class RideInvitationLinkGate extends StatefulWidget {
  const RideInvitationLinkGate({
    super.key,
    required this.links,
    required this.rideController,
    required this.rideCodePreference,
    required this.riderProfile,
    required this.ready,
    required this.child,
  });

  final RideInvitationLinkController links;
  final RideController rideController;
  final RideCodePreferenceController rideCodePreference;
  final RiderProfileController riderProfile;
  final bool ready;
  final Widget child;

  @override
  State<RideInvitationLinkGate> createState() => _RideInvitationLinkGateState();
}

class _RideInvitationLinkGateState extends State<RideInvitationLinkGate> {
  bool _scheduled = false;
  bool _handling = false;

  @override
  void initState() {
    super.initState();
    widget.links.addListener(_schedule);
    widget.riderProfile.addListener(_schedule);
    _schedule();
  }

  @override
  void didUpdateWidget(covariant RideInvitationLinkGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.links, widget.links)) {
      oldWidget.links.removeListener(_schedule);
      widget.links.addListener(_schedule);
    }
    if (!identical(oldWidget.riderProfile, widget.riderProfile)) {
      oldWidget.riderProfile.removeListener(_schedule);
      widget.riderProfile.addListener(_schedule);
    }
    _schedule();
  }

  @override
  void dispose() {
    widget.links.removeListener(_schedule);
    widget.riderProfile.removeListener(_schedule);
    super.dispose();
  }

  void _schedule() {
    if (!mounted ||
        _scheduled ||
        _handling ||
        !widget.ready ||
        widget.riderProfile.needsOnboarding ||
        !widget.links.hasNotice) {
      return;
    }
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (mounted) unawaited(_handlePending());
    });
  }

  Future<void> _handlePending() async {
    if (_handling || !widget.ready || !widget.links.hasNotice) return;
    _handling = true;
    try {
      final malformed = widget.links.errorMessage;
      if (malformed != null) {
        await _showMessage(
          title: 'Cannot open invitation',
          message: malformed,
          action: 'Close',
        );
        widget.links.clear();
        return;
      }

      final invitation = widget.links.pending;
      if (invitation == null) return;

      final current = widget.rideController.session;
      if (current != null) {
        final sameRide = current.rideCode == invitation.rideCode;
        await _showMessage(
          title: sameRide ? 'Already in this ride' : 'A ride is already open',
          message: sameRide
              ? 'This phone is already in ride ${current.rideCode}.'
              : 'Ride ${current.rideCode} is still open on this phone. For '
                    'safety, another invitation cannot replace it silently. '
                    'Leave or end the current ride from Ride actions, then tap '
                    'the new invitation again.',
          action: 'Keep current ride',
        );
        widget.links.clear();
        return;
      }

      final shouldJoin = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          key: const Key('ride-invitation-link-dialog'),
          icon: const Icon(Icons.group_add_outlined),
          title: Text('Join ride ${invitation.rideCode}?'),
          content: const Text(
            'This private invitation will connect you to the group. Only join '
            'if you recognise the person who shared it.',
          ),
          actions: [
            TextButton(
              key: const Key('decline-ride-invitation-link'),
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Not now'),
            ),
            FilledButton(
              key: const Key('accept-ride-invitation-link'),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Join ride'),
            ),
          ],
        ),
      );
      if (shouldJoin != true || !mounted) {
        widget.links.clear();
        return;
      }

      final profile = widget.riderProfile;
      await widget.rideController.joinRide(
        invitation.rideCode,
        profile.displayName,
        joinToken: invitation.joinToken,
        motorcycleStyle: profile.motorcycleStyle,
        riderSymbol: profile.riderSymbol,
        riderColor: profile.riderColor,
      );
      if (!mounted) return;

      final joined =
          widget.rideController.session?.rideCode == invitation.rideCode;
      if (joined) {
        await widget.rideCodePreference.rememberSuccessfulJoin(
          invitation.rideCode,
        );
        widget.links.clear();
        return;
      }

      final retry = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          key: const Key('ride-invitation-link-error-dialog'),
          icon: const Icon(Icons.link_off_outlined),
          title: const Text('Could not join this ride'),
          content: Text(
            widget.rideController.errorMessage ??
                'That invitation could not be checked. Ask the ride lead to '
                    'share a new one.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Close'),
            ),
            if (widget.rideController.errorIsRetryable)
              FilledButton(
                key: const Key('retry-ride-invitation-link'),
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Try again'),
              ),
          ],
        ),
      );
      if (retry != true) widget.links.clear();
    } finally {
      _handling = false;
      _schedule();
    }
  }

  Future<void> _showMessage({
    required String title,
    required String message,
    required String action,
  }) => showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      key: const Key('ride-invitation-link-message-dialog'),
      title: Text(title),
      content: Text(message),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(action),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => widget.child;
}
