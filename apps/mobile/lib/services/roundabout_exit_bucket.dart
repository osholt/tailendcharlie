import 'navigation_guidance.dart';

/// How a roundabout exit is named to a rider: left, straight on, right, or back
/// (#427).
///
/// ## Why four and not eight
///
/// Asked for from the road: *"Roundabouts should be simplified to left, straight
/// on, right and U-turn. The turn direction should match the signs shown on the
/// approach to the roundabout."*
///
/// It is the right call for two reasons beyond preference.
///
/// **It matches the sign.** A UK direction sign at a roundabout names each exit
/// by where it points — left, ahead, right. It does not distinguish a slight
/// right from a right, because a rider approaching does not either.
///
/// **It absorbs the error that is actually being made.** #412 reports the
/// direction as "either correct or one off". Eight buckets means a one-off error
/// changes the word a rider hears; four means most one-off errors land in the
/// same bucket and change nothing. Collapsing does not fix #412, but it stops
/// most of it reaching the rider.
///
/// ## Where the boundaries sit, and why slight is straight
///
/// A "slight" exit at a roundabout is one a rider would call straight on. The
/// arms of a roundabout are offset by the ring itself, so a genuinely straight
/// crossing routinely shows 25–35° of heading change from geometry alone — which
/// is why `_roundaboutStraightBandDegrees` is already 38 rather than 20. Treating
/// slight as straight follows the same reasoning one step further.
///
/// Sharp turns stay with their side: a sharp left is unambiguously a left, and
/// nothing about the ring makes it read as straight on.
enum RoundaboutExitBucket {
  left('left'),
  straightOn('straight on'),
  right('right'),

  /// All the way round and back the way you came.
  back('back');

  const RoundaboutExitBucket(this.label);

  /// What the rider hears and reads.
  final String label;
}

/// The bucket for [direction], or null where the engine stated no direction.
///
/// Null rather than a guess: #412 is about the direction being wrong, and a
/// roundabout with an exit number and no direction is still useful — "take the
/// 2nd exit" is actionable on its own, and a made-up word is not.
RoundaboutExitBucket? roundaboutExitBucket(ManeuverDirection direction) =>
    switch (direction) {
      ManeuverDirection.sharpLeft ||
      ManeuverDirection.left => RoundaboutExitBucket.left,
      // Slight is straight on. See the note above: the ring's own geometry puts
      // 25-35 degrees on a crossing that a rider would call straight.
      ManeuverDirection.slightLeft ||
      ManeuverDirection.straight ||
      ManeuverDirection.slightRight => RoundaboutExitBucket.straightOn,
      ManeuverDirection.right ||
      ManeuverDirection.sharpRight => RoundaboutExitBucket.right,
      ManeuverDirection.uTurn => RoundaboutExitBucket.back,
      ManeuverDirection.unstated => null,
    };

/// The exit angle the simplified symbol draws, in degrees clockwise from the road
/// ahead.
///
/// Four fixed angles rather than the engine's own geometry. That is the point: an
/// arrow at 47 degrees invites a rider to read a precision the data does not
/// have, and #412 says the precision is wrong about as often as it is right.
double roundaboutExitBucketDegrees(RoundaboutExitBucket bucket) =>
    switch (bucket) {
      RoundaboutExitBucket.left => -90,
      RoundaboutExitBucket.straightOn => 0,
      RoundaboutExitBucket.right => 90,
      // Not 180: an exit drawn straight back would sit on top of the road the
      // rider came in on. Offset enough to be seen as its own arm.
      RoundaboutExitBucket.back => 165,
    };
