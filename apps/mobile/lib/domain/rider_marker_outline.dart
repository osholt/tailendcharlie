import 'ride_coordination_mode.dart';
import 'ride_role.dart';

/// The outline a rider's marker is drawn in on every map (#845).
///
/// The leader and the Tail End Charlie are marked with a star so a rider can
/// pick them out of the group at a glance, through a visor, without reading a
/// label. Everyone keeps their own colour (#250): the shape says the role and
/// the colour says who.
enum RiderMarkerOutline { circle, star }

/// Which outline a rider's marker has.
///
/// [isEffectiveTec] is the one back-marker the ride has resolved, not whoever's
/// own role says Tail End Charlie. A leader's accepted request wins over an
/// older self-selection, so two riders can claim the role in the journal while
/// the map must not draw two backs to one group (#128).
///
/// [inGroup] is false for a solo ride. The lead role is the creator's whether or
/// not anyone rides with them, but a ride of one has no leader to pick out and
/// no back to find, so its only marker stays a circle.
RiderMarkerOutline riderMarkerOutlineFor({
  required RideRole role,
  required bool isEffectiveTec,
  bool inGroup = true,
}) => inGroup && (role == RideRole.lead || isEffectiveTec)
    ? RiderMarkerOutline.star
    : RiderMarkerOutline.circle;

/// Which outline this phone's own marker has.
///
/// [role] and [localRiderId] are the local session's, null when there is no ride
/// (free roam). [effectiveTecRiderIds] is the shell's resolved Tail End Charlie
/// set, so a rider who has handed the back over to another stops being a star
/// the moment the ride says so.
RiderMarkerOutline localRiderMarkerOutline({
  required RideRole? role,
  required String? localRiderId,
  required Set<String> effectiveTecRiderIds,
  required RideCoordinationMode coordinationMode,
}) => role == null
    ? RiderMarkerOutline.circle
    : riderMarkerOutlineFor(
        role: role,
        isEffectiveTec: effectiveTecRiderIds.contains(localRiderId),
        inGroup: coordinationMode.isGroup,
      );
