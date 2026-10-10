import 'package:flutter/material.dart';

import '../../controllers/global_ride_heatmap_controller.dart';
import '../../services/global_ride_heatmap.dart';

/// Whether the one-time global-heatmap question may be put to the rider now
/// (#957).
///
/// The question exists for installs that predate it and never stored a choice:
/// setup asks everyone who installs from now on. Until such a rider answers they
/// contribute nothing, so nothing here is urgent, and every condition below is a
/// reason to wait rather than to interrupt:
///
/// - a ride, or one being restored: a rider out on the road does not get a
///   dialog, the same rule the update screen follows;
/// - navigation under way, or a route about to be restored into navigation;
/// - a ride or a destination being arranged.
///
/// Every way out of the question stores an answer, so a rider who has seen it is
/// never in the unanswered state again: that, not a flag here, keeps it to once.
bool shouldAskHeatmapConsent({
  required bool consentAnswered,
  required bool hasActiveRide,
  required bool restoring,
  required bool navigating,
  required bool arrangingRide,
}) =>
    !consentAnswered &&
    !hasActiveRide &&
    !restoring &&
    !navigating &&
    !arrangingRide;

/// The three things a rider can agree to, in the order they are offered, each
/// in the words setup and the one-time question share.
const _choices = <HeatmapContributionConsent>[
  HeatmapContributionConsent.always,
  HeatmapContributionConsent.askAfterEachRide,
  HeatmapContributionConsent.never,
];

extension on HeatmapContributionConsent {
  String get choiceTitle => switch (this) {
    HeatmapContributionConsent.always => 'Always share after a ride',
    HeatmapContributionConsent.askAfterEachRide => 'Ask me after each ride',
    HeatmapContributionConsent.never => 'Never share',
  };

  String get choiceDescription => switch (this) {
    HeatmapContributionConsent.always =>
      'Coverage from each finished ride is sent automatically.',
    HeatmapContributionConsent.askAfterEachRide =>
      'You decide ride by ride, on the ride summary.',
    HeatmapContributionConsent.never =>
      'Nothing is sent. You can still view the global map.',
  };
}

/// The three-way choice, with nothing chosen until the rider chooses.
///
/// There is deliberately no default: a sharing option that is already selected
/// is a default the rider did not make. [selected] is null for a rider who has
/// not answered, and only ever holds an answer they gave.
class HeatmapConsentChoices extends StatelessWidget {
  const HeatmapConsentChoices({
    super.key,
    required this.selected,
    required this.onChanged,
    this.keyPrefix = 'heatmap-consent',
  });

  final HeatmapContributionConsent? selected;
  final ValueChanged<HeatmapContributionConsent> onChanged;

  /// Prefix of each option's key, `<prefix>-always`, `<prefix>-askAfterEachRide`
  /// and `<prefix>-never`, so setup and the question can both be driven by tests.
  final String keyPrefix;

  @override
  Widget build(BuildContext context) => RadioGroup<HeatmapContributionConsent>(
    groupValue: selected,
    onChanged: (value) {
      if (value != null) onChanged(value);
    },
    child: Column(
      children: [
        for (final choice in _choices)
          RadioListTile<HeatmapContributionConsent>(
            key: Key('$keyPrefix-${choice.name}'),
            contentPadding: EdgeInsets.zero,
            value: choice,
            title: Text(choice.choiceTitle),
            subtitle: Text(choice.choiceDescription),
          ),
      ],
    ),
  );
}

/// What contributing sends, and what it does not, in the same words wherever
/// the choice is offered. It matches `docs/ride-heatmap-design.md` and the
/// privacy page; change them together.
class HeatmapSharingSummary extends StatelessWidget {
  const HeatmapSharingSummary({super.key});

  @override
  Widget build(BuildContext context) {
    const body = TextStyle(color: Color(0xFFABB5C1), height: 1.4);
    return Column(
      key: const Key('heatmap-sharing-summary'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'What is shared',
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 6),
        const Text(
          'Only unordered, coarse map cells (roughly 200 m) along roads you '
          'rode, after the first and last 1 km of each ride are removed on '
          'your phone. Never your track, the order of your route, times, '
          'speeds, your name or any ride code.',
          style: body,
        ),
        const SizedBox(height: 8),
        const Text(
          'A road stays hidden from the public map until at least three '
          'separate contributors have ridden it. The cells can still describe '
          'places you ride often, so this is not anonymous.',
          style: body,
        ),
        const SizedBox(height: 8),
        const Text(
          'Nothing is shared unless you choose Always or Ask after each ride. '
          'You can change this at any time in Settings.',
          style: body,
        ),
      ],
    );
  }
}

/// The one-time question for a rider who never stored a choice (#957).
///
/// Shown by the home screen after launch, never over a ride or navigation (see
/// [shouldAskHeatmapConsent]). Every way out records an answer, so it is asked
/// once: a rider who dismisses it, or presses back, has said no. Settings
/// remains the place to change that.
class HeatmapConsentDialog extends StatefulWidget {
  const HeatmapConsentDialog({super.key});

  /// Asks, then stores what the rider said.
  static Future<void> show(
    BuildContext context,
    GlobalRideHeatmapController heatmap,
  ) async {
    final choice = await showDialog<HeatmapContributionConsent>(
      context: context,
      // An answer is stored either way; a tap outside should not be able to
      // stand in for one by accident.
      barrierDismissible: false,
      builder: (_) => const HeatmapConsentDialog(),
    );
    await heatmap.setConsent(choice ?? HeatmapContributionConsent.never);
  }

  @override
  State<HeatmapConsentDialog> createState() => _HeatmapConsentDialogState();
}

class _HeatmapConsentDialogState extends State<HeatmapConsentDialog> {
  HeatmapContributionConsent? _selected;

  @override
  Widget build(BuildContext context) => AlertDialog(
    key: const Key('heatmap-consent-dialog'),
    title: const Text('Contribute to the global heatmap?'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'This is a new question. Until you answer, nothing is shared.',
          ),
          const SizedBox(height: 8),
          HeatmapConsentChoices(
            keyPrefix: 'heatmap-consent-dialog',
            selected: _selected,
            onChanged: (value) => setState(() => _selected = value),
          ),
          const SizedBox(height: 8),
          const HeatmapSharingSummary(),
        ],
      ),
    ),
    actions: [
      TextButton(
        key: const Key('heatmap-consent-dialog-decline'),
        onPressed: () =>
            Navigator.pop(context, HeatmapContributionConsent.never),
        child: const Text('Don’t share'),
      ),
      FilledButton(
        key: const Key('heatmap-consent-dialog-save'),
        onPressed: _selected == null
            ? null
            : () => Navigator.pop(context, _selected),
        child: const Text('Save choice'),
      ),
    ],
  );
}
