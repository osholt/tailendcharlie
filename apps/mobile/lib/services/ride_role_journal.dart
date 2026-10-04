import '../domain/ride_event.dart';
import '../domain/ride_role.dart';

/// Who holds which role at a point in the signed journal.
///
/// Fed the events of a ride in the journal's own order, it answers "was this rider
/// the leader when they did that?" - the rule every leader-only fact in this app
/// rests on. A ride start (`RideLifecycleReducer`), a Tail End Charlie request
/// (`TecRoleAssignmentReducer`, #128) and the leader's broadcasts (#854) are each
/// admitted only from a device whose latest signed role **at that point** is
/// [RideRole.lead], which is how a forged or replayed one from another device is
/// harmless (#99).
///
/// Roles come from the three events that carry one - `rideCreated`, `riderJoined`
/// and `roleChanged` - and nothing else. In particular a leader who starts a
/// junction marker session stays the leader here: the marker session changes the
/// phone's own session role but records no `roleChanged`, so a leader acting as
/// marker can still broadcast, and so can be heard.
class RideRoleJournal {
  final Map<String, RideRole> _roles = {};

  /// Whether [type] is an event [apply] reads, so a caller can keep the rest of a
  /// long journal out of the loop.
  static bool carriesRole(RideEventType type) => switch (type) {
    RideEventType.rideCreated ||
    RideEventType.riderJoined ||
    RideEventType.roleChanged => true,
    _ => false,
  };

  /// Folds [event] in, if it carries a role.
  void apply(RideEvent event) {
    if (!carriesRole(event.type)) return;
    final role = _role(event.payload['role']);
    if (role != null) _roles[event.deviceId] = role;
  }

  /// Whether [deviceId] holds the lead role at the point the journal has reached.
  bool isLeader(String deviceId) => _roles[deviceId] == RideRole.lead;

  static RideRole? _role(Object? value) {
    if (value is! String) return null;
    for (final role in RideRole.values) {
      if (role.name == value) return role;
    }
    return null;
  }
}
