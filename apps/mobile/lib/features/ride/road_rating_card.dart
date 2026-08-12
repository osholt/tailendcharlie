import 'package:flutter/material.dart';

import '../../controllers/road_rating_controller.dart';
import '../../services/road_rating.dart';

/// The end-of-ride ask: was this road worth being in the directory? (#159)
///
/// A card in the ended-ride list, never a dialog and never a route. It cannot
/// block sharing, the recap or filing the ride, and it is not shown at all when
/// the ride crossed no catalogued road.
class RoadRatingCard extends StatelessWidget {
  const RoadRatingCard({super.key, required this.controller});

  /// What is sent, said before the first answer rather than after it and in the
  /// card rather than behind a link. This is the first feature that sends an
  /// opinion instead of a position, so the rider gets to read the whole of it.
  static const disclosure =
      'Optional and anonymous. If you answer, this phone sends the road and '
      'your yes or no - and nothing else. No name, no rider or device ID, no '
      'ride, no route, no position, and no record of when you rode it. Answers '
      'are held on this phone and sent hours later, on their own, so they '
      'cannot be lined up against your ride.';

  final RoadRatingController controller;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      if (!controller.hasQuestions) return const SizedBox.shrink();
      return Padding(
        key: const Key('road-rating-card'),
        padding: const EdgeInsets.only(bottom: 18),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFF1B2431),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFF3B4654)),
          ),
          child: controller.finished ? _thanks(context) : _question(context),
        ),
      );
    },
  );

  Widget _question(BuildContext context) {
    final question = controller.current!;
    final feature = question.feature;
    final total = controller.questions.length;
    final position = controller.answeredCount + 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Rate the roads you rode',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            Text(
              '$position of $total',
              style: const TextStyle(color: Color(0xFF8C97A5)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        const Text(
          key: Key('road-rating-disclosure'),
          disclosure,
          style: TextStyle(color: Color(0xFFABB5C1), height: 1.45),
        ),
        const SizedBox(height: 14),
        Text(
          feature.name,
          key: const Key('road-rating-road-name'),
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 4),
        Text(
          [
            feature.category.label,
            if (feature.score case final score?) 'score $score/100',
            if (question.riddenMeters >= 1000)
              '${(question.riddenMeters / 1000).toStringAsFixed(1)} km ridden',
          ].join(' - '),
          style: const TextStyle(color: Color(0xFF8C97A5)),
        ),
        const SizedBox(height: 14),
        const Text(
          'Does this road belong in the good-road directory?',
          style: TextStyle(height: 1.4),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          key: const Key('road-rating-yes-button'),
          onPressed: () => controller.answer(RoadRatingVerdict.worthIncluding),
          icon: const Icon(Icons.thumb_up_outlined),
          label: const Text('Yes, worth including'),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          key: const Key('road-rating-no-button'),
          onPressed: () =>
              controller.answer(RoadRatingVerdict.notWorthIncluding),
          icon: const Icon(Icons.thumb_down_outlined),
          label: const Text('No, it does not'),
        ),
        const SizedBox(height: 4),
        // A Wrap, not a Row with a Spacer (#469). At iPhone 13 width the two
        // controls overflowed by 24 px and drew the striped overflow bar at the
        // end of a real ride. It went unseen because every test of this card ran
        // at the default 800x600 viewport, which is wider than any phone the app
        // is used on. A Wrap cannot overflow: it takes a second line instead.
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          spacing: 8,
          children: [
            TextButton(
              key: const Key('road-rating-skip-button'),
              onPressed: controller.skip,
              child: const Text('Skip this road'),
            ),
            TextButton(
              key: const Key('road-rating-dismiss-button'),
              onPressed: controller.dismiss,
              child: const Text('Not now'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _thanks(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        'Thanks',
        key: const Key('road-rating-done'),
        style: Theme.of(context).textTheme.titleMedium,
      ),
      const SizedBox(height: 8),
      Text(
        _deliveryNote(),
        style: const TextStyle(color: Color(0xFFABB5C1), height: 1.45),
      ),
      const SizedBox(height: 4),
      Align(
        alignment: Alignment.centerRight,
        child: TextButton(
          key: const Key('road-rating-close-button'),
          onPressed: controller.dismiss,
          child: const Text('Close'),
        ),
      ),
    ],
  );

  /// Never "sent" when nothing was sent. Each limitation says what actually
  /// happened and what changes it.
  String _deliveryNote() {
    if (controller.pendingCount == 0) {
      return 'Your answers have been sent anonymously.';
    }
    return switch (controller.limitation) {
      RoadRatingLimitation.serviceNotConfigured =>
        'Your answers are saved on this phone. This build has no catalogue '
            'service configured, so nothing has been sent.',
      RoadRatingLimitation.serviceCapabilityMissing =>
        'Your answers are saved on this phone. The catalogue service does not '
            'accept road ratings yet, so nothing has been sent.',
      RoadRatingLimitation.serviceUnreachable =>
        'Your answers are saved on this phone and will be sent when the '
            'catalogue service can be reached.',
      RoadRatingLimitation.none =>
        'Your answers are saved on this phone and will be sent anonymously '
            'later, not now.',
    };
  }
}
