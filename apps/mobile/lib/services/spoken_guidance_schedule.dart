/// When a turn is spoken, and what is said — as a decision separated from the
/// speaking, so the timing can be driven by a synthetic approach in a test
/// rather than only by riding (#409, #410, #429).
///
/// ## What was wrong
///
/// Speech fired when an instruction became *current*, and an instruction becomes
/// current when the previous one is passed. Three field reports came out of that
/// single fact:
///
/// - the prompt for a junction arrived **after** it (#409);
/// - it carried **no distance at all** — never "in 1 mile, turn right" (#410);
/// - and on a large roundabout the *next* instruction arrived while the rider was
///   still on the ring, part-way through the manoeuvre they were told about
///   (#429), because a roundabout is two engine steps merged into one instruction
///   and the manoeuvre point is behind the rider long before they are clear of it.
///
/// ## Staged on time, not on road class
///
/// The ask was "2 miles on a motorway, then half a mile, then just before". Those
/// distances are really a *time* budget wearing distance clothes: two miles at
/// 70 mph is about two minutes, and two miles at 30 mph is four minutes of
/// pointless early warning.
///
/// So the stages are times to the junction, converted through the rider's own
/// speed. At 70 mph that puts the first prompt at about 2.3 miles and the second
/// at about 0.6 — which is what was asked for — and on a B road at 30 mph it
/// pulls in to about a mile and 400 yards without a road-classification lookup
/// and without a single road-specific rule.
///
/// Each stage also has a distance ceiling, because a queue on a motorway at
/// walking pace should not push the first prompt ten miles out.
library;

/// One announcement in the run-up to a junction.
enum GuidanceStage {
  /// The early heads-up. "In 2 miles, take the 3rd exit."
  early,

  /// The confirmation, close enough to start positioning for.
  approach,

  /// The last word before the junction, with no distance on it.
  immediate,
}

/// The time-to-junction each stage fires at, and the furthest out it may be said.
///
/// Times rather than distances so one set of numbers works at every speed; see
/// the library note. The ceilings stop a slow-moving rider being warned absurdly
/// early — two minutes stuck at 10 mph is a third of a mile, which is fine, but
/// two minutes of *stationary* is unbounded without them.
const guidanceStageSeconds = <GuidanceStage, double>{
  GuidanceStage.early: 120,
  GuidanceStage.approach: 30,
  GuidanceStage.immediate: 8,
};

const guidanceStageCeilingMeters = <GuidanceStage, double>{
  GuidanceStage.early: 4000,
  GuidanceStage.approach: 1000,
  GuidanceStage.immediate: 250,
};

/// Below this, the early prompt is skipped entirely.
///
/// A junction 200 m away does not need three announcements; it needs one. Saying
/// "in 200 yards" and then "in 100 yards" and then the turn itself is the noise
/// that trains a rider to stop listening.
const guidanceEarliestStageMeters = 500.0;

/// How far past a junction the rider must be before the *next* one is spoken.
///
/// #429: a rider on a large roundabout is still executing the manoeuvre they were
/// told about when its point falls behind them. Nothing new is said until they
/// are clear.
const guidanceJunctionClearanceMeters = 60.0;

/// Except when the next junction is this close, where silence is worse.
///
/// #163's double mini-roundabout is **42 m** apart: both must be announced, and
/// the second while approaching the first. Any clearance rule that suppresses it
/// is wrong, which is why this exemption exists and why it is larger than the
/// clearance above.
const guidanceCloseFollowingMeters = 150.0;

/// The decision: say this, now, or say nothing.
class GuidanceAnnouncement {
  const GuidanceAnnouncement({
    required this.key,
    required this.phrase,
    required this.stage,
  });

  /// Identity of the announcement, so the same stage of the same junction is not
  /// repeated on every position fix. Carries the stage, because keying on the
  /// manoeuvre alone would let the first stage suppress the rest.
  final String key;
  final String phrase;
  final GuidanceStage stage;
}

/// Decides the next thing to say about a junction.
///
/// Pure: everything it needs is an argument, so a whole approach can be played
/// through it in a test. [distanceFormatter] is the caller's, so what is spoken
/// says miles or kilometres in step with what the banner shows.
GuidanceAnnouncement? nextGuidanceAnnouncement({
  required String maneuverIdentity,
  required String instructionText,
  required double distanceToManeuverMeters,
  required double? speedMetersPerSecond,
  required Set<String> alreadySpokenKeys,
  required double? metersSincePreviousManeuver,
  required String Function(double meters) distanceFormatter,
  String? followingInstructionText,
}) {
  if (distanceToManeuverMeters.isNaN || distanceToManeuverMeters < 0) {
    return null;
  }
  if (instructionText.trim().isEmpty) return null;

  // #429. Still inside the junction just left, so nothing new is said — unless
  // the next one is close enough that waiting would mean saying nothing useful.
  final since = metersSincePreviousManeuver;
  if (since != null &&
      since < guidanceJunctionClearanceMeters &&
      distanceToManeuverMeters > guidanceCloseFollowingMeters) {
    return null;
  }

  final stage = _dueStage(
    distanceToManeuverMeters: distanceToManeuverMeters,
    speedMetersPerSecond: speedMetersPerSecond,
    alreadySpokenKeys: alreadySpokenKeys,
    maneuverIdentity: maneuverIdentity,
  );
  if (stage == null) return null;

  final subject = guidanceSubject(
    instructionText: instructionText,
    followingInstructionText: followingInstructionText,
  );
  final spokenSubject = _naturaliseArrival(
    subject,
    immediate: stage == GuidanceStage.immediate,
  );
  return GuidanceAnnouncement(
    key: '$maneuverIdentity|${stage.name}',
    // The immediate prompt carries no distance: at eight seconds out, "in 90
    // yards" is a number the rider has no use for and a syllable they have no
    // time for.
    phrase: stage == GuidanceStage.immediate
        ? spokenSubject
        : 'In ${distanceFormatter(distanceToManeuverMeters)}, $spokenSubject',
    stage: stage,
  );
}

String _naturaliseArrival(String subject, {required bool immediate}) {
  final arrival = RegExp(r'Arrive at the destination', caseSensitive: false);
  final match = arrival.firstMatch(subject);
  if (match == null) return subject;
  final atStart = match.start == 0;
  final replacement = immediate
      ? atStart
            ? 'Your destination is just ahead'
            : 'your destination is just ahead'
      : "you'll arrive at your destination";
  return subject.replaceFirst(arrival, replacement);
}

/// What the prompt is *about* — one junction, or a close pair named together.
///
/// ## Why a pair is named in one prompt (#460)
///
/// A junction can only be announced once it is the nearest one, because that is
/// what the guidance layer hands over. So for a pair A then B, B's first
/// opportunity is at the A→B spacing rather than at its own scheduled distance:
///
/// - over ~500 m apart, B gets all three prompts;
/// - 300–500 m, B loses the early heads-up;
/// - under about 100 m, **only the final prompt survives** — which is the reported
///   *"sometimes only when at the junction"*, and the one that is genuinely late.
///
/// A general lookahead would be the wrong answer and would make it worse:
/// announcing B early while A is still 200 m ahead tells the rider about the wrong
/// junction.
///
/// Instead the pair is named in the prompt for the *first* of them — the one
/// moment the rider still has time to act on both. The banner has shown pairs like
/// this since #163; speech simply ignored the following instruction it was already
/// being given.
String guidanceSubject({
  required String instructionText,
  required String? followingInstructionText,
}) {
  final following = followingInstructionText?.trim();
  if (following == null || following.isEmpty) return instructionText;
  // "then", not "and then": one syllable fewer, and it is the word a pillion
  // would use.
  return '$instructionText, then $following';
}

/// The nearest stage that is due and has not been said.
///
/// Walked from the closest outwards so a rider who joins a route already inside
/// the early band, or whose GPS jumps, gets the *right* prompt rather than a
/// backlog of the ones they missed.
GuidanceStage? _dueStage({
  required double distanceToManeuverMeters,
  required double? speedMetersPerSecond,
  required Set<String> alreadySpokenKeys,
  required String maneuverIdentity,
}) {
  for (final stage in [
    GuidanceStage.immediate,
    GuidanceStage.approach,
    GuidanceStage.early,
  ]) {
    if (alreadySpokenKeys.contains('$maneuverIdentity|${stage.name}')) {
      // Already said, and so is everything closer in — nothing left to say.
      return null;
    }
    if (stage == GuidanceStage.early &&
        distanceToManeuverMeters < guidanceEarliestStageMeters) {
      continue;
    }
    if (distanceToManeuverMeters <=
        _stageTriggerMeters(stage, speedMetersPerSecond)) {
      return stage;
    }
  }
  return null;
}

/// Where a stage fires, in metres, for the speed the rider is doing.
///
/// A rider with no usable speed — stopped, or a fix without one — falls back to
/// the ceiling, which is the most warning the stage will ever give. Better early
/// than never: a stationary rider is about to move.
double _stageTriggerMeters(GuidanceStage stage, double? speedMetersPerSecond) {
  final ceiling = guidanceStageCeilingMeters[stage]!;
  final speed = speedMetersPerSecond;
  if (speed == null || !speed.isFinite || speed <= 1) return ceiling;
  final fromTime = guidanceStageSeconds[stage]! * speed;
  return fromTime < ceiling ? fromTime : ceiling;
}
