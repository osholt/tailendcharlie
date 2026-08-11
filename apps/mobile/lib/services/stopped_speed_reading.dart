/// What the speed readout should say when the fixes stop arriving (#445).
///
/// ## Why silence is ambiguous
///
/// The platform location stream carries a `distanceFilter`, so **a stationary
/// bike produces no fixes at all** — standing still is silence, not a stream of
/// zeroes (#210). But losing signal is also silence, and a rider in a tunnel at
/// 60 mph produces exactly the same nothing as a rider at a red light.
///
/// So silence alone cannot decide between "stopped" and "lost", and the two
/// wrong answers are not equally wrong. Reading **0 while doing 60** is a lie
/// beside a speedometer. Reading **blank at a red light** is merely unhelpful,
/// which is what shipped and what was reported: *"When stopped the current speed
/// didn't go to 0."*
///
/// ## What breaks the tie
///
/// The last speed actually observed. A rider who was already down to walking
/// pace and then went quiet has almost certainly stopped — that is what stopping
/// looks like through a `distanceFilter`. A rider who was doing 60 and went quiet
/// has not stopped in the gap; something else happened.
///
/// So a low last speed resolves to zero and a high one resolves to unknown, and
/// the boundary is deliberately low.
library;

/// What the readout shows once fixes have stopped arriving.
enum StoppedSpeedReading {
  /// The rider stopped. Show zero.
  stopped,

  /// Something else happened — signal, permission, a wedged stream. Show nothing
  /// rather than a number, because a number here would be a claim.
  unknown,
}

/// Below this, going quiet means the bike stopped.
///
/// About 7 mph. Chosen low on purpose: the cost of reading zero when the rider is
/// actually moving is far higher than the cost of reading blank for another
/// second while they roll to a halt. A rider decelerating passes through this
/// band on the way to stopping anyway, so the honest answer arrives a moment
/// later rather than not at all.
const stoppedSpeedThresholdMetersPerSecond = 3.0;

/// How long silence must last before it is read as anything.
///
/// Longer than the freshness window that merely marks a reading as held: this
/// decides to *replace* the number, which is a stronger claim than dimming it.
const stoppedSpeedSilence = Duration(seconds: 6);

/// What to show, given how the rider was last seen moving.
///
/// [lastObservedSpeedMetersPerSecond] is null when no speed was ever seen, which
/// resolves to [StoppedSpeedReading.unknown]: with nothing to reason from, a zero
/// would be invented rather than inferred.
StoppedSpeedReading stoppedSpeedReading({
  required double? lastObservedSpeedMetersPerSecond,
  required Duration silence,
}) {
  if (silence < stoppedSpeedSilence) return StoppedSpeedReading.unknown;
  final last = lastObservedSpeedMetersPerSecond;
  if (last == null || !last.isFinite) return StoppedSpeedReading.unknown;
  return last <= stoppedSpeedThresholdMetersPerSecond
      ? StoppedSpeedReading.stopped
      : StoppedSpeedReading.unknown;
}
