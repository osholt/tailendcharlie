import 'package:flutter/widgets.dart';

/// The distance to the next turn, counting down rather than stepping (#449).
///
/// > It would be good to count down distance more smoothly.
///
/// Position fixes arrive about a second apart, so the distance drops in visible
/// steps — 400, then 370, then 340. On a surface a rider glances at, a number
/// that jumps is harder to read than one that moves.
///
/// ## What this does *not* do
///
/// It does not touch the position the app reasons from. #449 warns about exactly
/// that:
///
/// > Interpolating between fixes is a claim about where the rider is *now*,
/// > which is #448's territory. […] a smooth countdown built on a position that
/// > is 20 m behind is a smoothly wrong number.
///
/// So this animates the **displayed** number toward the latest computed distance
/// and nothing else. Guidance staging, the camera detector and the spoken prompts
/// all keep using the real value. If #448 later moves the position itself, this
/// keeps working and does not have to be unpicked — and it cannot be blamed for a
/// wrong prompt in the meantime, because it reaches no decision.
///
/// ## It never counts up, and it never glides through a junction
///
/// Two rules, both from the ticket:
///
/// - A target **further away** than what is shown snaps rather than animating.
///   That happens on a reroute or when the next manoeuvre becomes current, and
///   watching a number crawl upward toward a turn is worse than a step.
/// - A **new manoeuvre** snaps, via the key. The count has to reach zero at the
///   junction and start again at the next one, not glide between them.
class SmoothCountdown extends StatelessWidget {
  const SmoothCountdown({
    super.key,
    required this.meters,
    required this.builder,
    this.duration = defaultDuration,
  });

  final double meters;

  /// Builds the text for an interpolated distance. The caller's formatter, so
  /// what is drawn stays in the rider's own units.
  final Widget Function(BuildContext context, double meters) builder;

  final Duration duration;

  /// Matched to the gap between position fixes.
  ///
  /// Shorter and the number still steps; longer and it lags behind the rider,
  /// which is the failure #449 explicitly does not want traded for smoothness.
  static const defaultDuration = Duration(milliseconds: 1000);

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween<double>(begin: meters, end: meters),
    duration: duration,
    curve: Curves.linear,
    builder: (context, value, _) => builder(context, value),
  );
}

/// Whether a new target should be animated to, or jumped to.
///
/// Pure so the two rules above are testable without pumping a widget.
bool smoothCountdownAnimates({
  required double shownMeters,
  required double targetMeters,
  required bool sameManeuver,
}) {
  if (!sameManeuver) return false;
  if (!shownMeters.isFinite || !targetMeters.isFinite) return false;
  // Counting up toward a turn reads as the junction moving away. A reroute or a
  // new leg is a step change, and a step is the honest way to show it.
  return targetMeters <= shownMeters;
}
