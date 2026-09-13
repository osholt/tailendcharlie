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
/// **It does not erase the side.** The geometry classifier already has a wide
/// straight band for a roundabout. Once an exit is outside that band, `slight`
/// means the route genuinely leaves to that side; collapsing it back to straight
/// made left exits on a French ride both speak and draw as straight (#743).
///
/// ## Where the boundaries sit
///
/// Ring offset is handled before this function: heading changes through 38° are
/// classified as [ManeuverDirection.straight]. Slight, normal and sharp exits
/// therefore keep their side here while still sharing one simple left/right
/// word and symbol arm.
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
      ManeuverDirection.left ||
      ManeuverDirection.slightLeft => RoundaboutExitBucket.left,
      ManeuverDirection.straight => RoundaboutExitBucket.straightOn,
      ManeuverDirection.slightRight ||
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
