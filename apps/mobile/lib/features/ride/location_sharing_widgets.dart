import 'package:flutter/material.dart';

import '../../controllers/location_sharing_guard.dart';
import '../../services/sharing_reminder_notifier.dart';

/// Colours for the three states a rider's sharing can be in, shared by the dot
/// on the ride menu, the Ride tab and the bar, so they read as one thing.
///
/// Green is the same green `ForegroundLocationCard` already uses for "sharing".
Color sharingStatusColor(SharingGuardPhase phase) => switch (phase) {
  SharingGuardPhase.sharing => const Color(0xFF6ED89A),
  SharingGuardPhase.prompting => const Color(0xFFFFC857),
  SharingGuardPhase.paused => const Color(0xFF8EA7C4),
};

/// What the status dot means, for a screen reader. The dot itself says nothing
/// in words, so this is what makes it an indicator rather than decoration.
String sharingStatusLabel(SharingGuardPhase phase) => switch (phase) {
  SharingGuardPhase.sharing => 'Location sharing is on',
  SharingGuardPhase.prompting => 'Location sharing is on and needs an answer',
  SharingGuardPhase.paused => 'Location sharing is off',
};

/// A small status dot on whatever it wraps (#859).
///
/// This is the persistent in-app half of "a rider can always see that they are
/// sharing"; the platform's own indicator is the other half. It sits on the ride
/// menu button and the Ride tab, which are the two things always within reach,
/// and it is small on purpose: it must be there without costing the map any of
/// the room the road ahead is read in.
class LocationSharingBadge extends StatelessWidget {
  const LocationSharingBadge({
    super.key,
    required this.phase,
    required this.child,
  });

  final SharingGuardPhase phase;
  final Widget child;

  @override
  Widget build(BuildContext context) => Semantics(
    label: sharingStatusLabel(phase),
    child: Badge(
      key: const Key('location-sharing-badge'),
      smallSize: 10,
      backgroundColor: sharingStatusColor(phase),
      child: child,
    ),
  );
}

/// The bar that carries the sharing question, and then the fact that sharing is
/// off (#859). Nothing when sharing is on and there is nothing to ask.
///
/// Not a dialog: a rider who is apart from the group may still be riding, and a
/// modal would cover the map exactly when they need it (the same reasoning as
/// #380). It sits at the foot of the screen, where the app's other controls are,
/// and the map keeps the rest.
class LocationSharingBar extends StatelessWidget {
  const LocationSharingBar({
    super.key,
    required this.phase,
    required this.copy,
    this.pauseReason,
    this.awayFor = Duration.zero,
    this.riding = false,
    this.resuming = false,
    this.onKeepSharing,
    this.onStopSharing,
    this.onResume,
  });

  final SharingGuardPhase phase;
  final SharingCopy copy;
  final SharingPauseReason? pauseReason;

  /// How long the rider has been away, for the question's own wording.
  final Duration awayFor;

  /// Whether the rider has moved lately, which changes what an unanswered
  /// question means.
  final bool riding;

  /// True while "Resume sharing" is starting the location stream.
  final bool resuming;

  final VoidCallback? onKeepSharing;
  final VoidCallback? onStopSharing;
  final VoidCallback? onResume;

  @override
  Widget build(BuildContext context) => switch (phase) {
    SharingGuardPhase.sharing => const SizedBox.shrink(),
    SharingGuardPhase.prompting => _buildPrompt(context),
    SharingGuardPhase.paused => _buildPaused(context),
  };

  Widget _buildPrompt(BuildContext context) {
    final theme = Theme.of(context);
    return _Frame(
      key: const Key('location-sharing-prompt'),
      accent: sharingStatusColor(SharingGuardPhase.prompting),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(
            Icons.share_location,
            color: sharingStatusColor(SharingGuardPhase.prompting),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Semantics(
              liveRegion: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    copy.promptTitle,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    copy.promptBody(awayFor, riding: riding),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          // As wide as the wider of the two, so the answers line up. A stretched
          // column inside a row has no width to stretch to without this.
          IntrinsicWidth(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FilledButton(
                  key: const Key('location-sharing-stop'),
                  onPressed: onStopSharing,
                  style: _buttonStyle,
                  child: const Text('Stop sharing'),
                ),
                const SizedBox(height: 4),
                TextButton(
                  key: const Key('location-sharing-keep'),
                  onPressed: onKeepSharing,
                  style: _buttonStyle,
                  child: const Text('Keep sharing'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPaused(BuildContext context) {
    final theme = Theme.of(context);
    final unanswered = pauseReason == SharingPauseReason.unanswered;
    return _Frame(
      key: const Key('location-sharing-paused'),
      accent: sharingStatusColor(SharingGuardPhase.paused),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(
            Icons.location_off_outlined,
            color: sharingStatusColor(SharingGuardPhase.paused),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  copy.pausedTitle(unanswered: unanswered),
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  copy.pausedBody(unanswered: unanswered),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.tonal(
            key: const Key('location-sharing-resume'),
            onPressed: resuming ? null : onResume,
            style: _buttonStyle,
            child: const Text('Resume sharing'),
          ),
        ],
      ),
    );
  }

  /// Glove-sized, but not stretched: the bar shares a narrow screen with its
  /// own words.
  static final _buttonStyle = ButtonStyle(
    minimumSize: WidgetStateProperty.all(const Size(0, 40)),
    padding: WidgetStateProperty.all(
      const EdgeInsets.symmetric(horizontal: 12),
    ),
  );
}

class _Frame extends StatelessWidget {
  const _Frame({super.key, required this.accent, required this.child});

  final Color accent;
  final Widget child;

  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surfaceContainerHigh,
    elevation: 3,
    child: DecoratedBox(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: accent, width: 2)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: child,
      ),
    ),
  );
}

/// Puts the sharing bar at the foot of [child], and keeps [child] exactly where
/// it was when the bar comes and goes (#859).
///
/// Two things here are easy to get wrong and invisible until a phone is in a
/// rider's hand, so they are tested:
///
///  * **[child] is never re-parented.** A widget that changes parent is rebuilt
///    from nothing, and [child] is the map: it would reload and flash every time
///    a question appeared or went. So the wrapper is the same whether or not
///    there is a bar, and only the bar is optional.
///  * **The bottom inset is counted once.** With no navigation bar below, the
///    bar owns the home-indicator inset and the map must not add it again, which
///    is [ownsBottomInset]. With a navigation bar, the Scaffold has already taken
///    the inset off its body, so the padding is read from where this widget sits
///    - inside that body - and left alone. Reading it from a context outside the
///    Scaffold would put the inset back, and the map would sit a notch too high.
class LocationSharingFooter extends StatelessWidget {
  const LocationSharingFooter({
    super.key,
    required this.child,
    required this.ownsBottomInset,
    this.bar,
  });

  final Widget child;
  final Widget? bar;

  /// True when nothing below the bar takes the bottom inset.
  final bool ownsBottomInset;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Expanded(
        child: MediaQuery.removePadding(
          context: context,
          removeBottom: ownsBottomInset && bar != null,
          child: child,
        ),
      ),
      ?bar,
    ],
  );
}

/// The Ride tab's always-on statement of whether the group can see the rider,
/// with the one action that goes with it (#859).
///
/// The words are the point: the dot says "something", this says what.
class LocationSharingCard extends StatelessWidget {
  const LocationSharingCard({
    super.key,
    required this.phase,
    required this.copy,
    required this.pauseReason,
    this.busy = false,
    this.onStopSharing,
    this.onResume,
  });

  final SharingGuardPhase phase;
  final SharingCopy copy;
  final SharingPauseReason? pauseReason;
  final bool busy;
  final VoidCallback? onStopSharing;
  final VoidCallback? onResume;

  @override
  Widget build(BuildContext context) {
    final paused = phase == SharingGuardPhase.paused;
    final color = sharingStatusColor(phase);
    return Card(
      key: const Key('location-sharing-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(
              paused ? Icons.location_off_outlined : Icons.my_location,
              color: color,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    copy.statusTitle(paused: paused),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    copy.statusBody(
                      paused: paused,
                      unanswered: pauseReason == SharingPauseReason.unanswered,
                    ),
                    style: const TextStyle(color: Color(0xFF9CA7B5)),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            if (paused)
              FilledButton.tonal(
                key: const Key('location-sharing-card-resume'),
                onPressed: busy ? null : onResume,
                child: const Text('Resume sharing'),
              )
            else
              TextButton(
                key: const Key('location-sharing-card-stop'),
                onPressed: busy ? null : onStopSharing,
                child: const Text('Stop sharing'),
              ),
          ],
        ),
      ),
    );
  }
}
