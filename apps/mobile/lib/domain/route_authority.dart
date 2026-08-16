/// Whose route the map surface is showing, and therefore who may change it.
///
/// This replaces a single `canEditRoute` boolean that was answering two
/// unrelated questions with one bit: *is there a group route governed by a
/// leader?* and *may anything build a route on this surface at all?*
///
/// Free roam answered `false` — it had no ride, so it was given the flag that
/// meant "not the leader" — and every route-building action inherited a
/// leadership rule with no group behind it. A rider adding a café to their own
/// route in free roam was told "Only the ride leader can replace the group
/// route" with no ride started and no leader in existence (#576).
///
/// The two questions are separated here because they have different answers in
/// the one case that matters: alone on the map, a rider has full authority over
/// their own route and there is no group route to protect.
enum RouteAuthority {
  /// No ride. The route belongs to this rider alone, so nothing gates it.
  personal,

  /// A group ride this rider leads. Replacing the route replaces the group's.
  leader,

  /// A group ride somebody else leads. Only that leader may replace the route.
  follower;

  /// The authority a ride surface has, from what the ride knows about itself.
  ///
  /// Named rather than written inline at the call site so the mapping can be
  /// asserted without standing up a whole ride shell — an inline conditional
  /// here was uncovered, and a mutation making every rider a follower passed
  /// the entire ride suite.
  ///
  /// The simulator drives the map itself and has no group behind it, so it is
  /// [personal] rather than [leader]: nothing it does is relayed to anyone.
  static RouteAuthority forRide({
    required bool isSimulation,
    required bool isLocalRideLeader,
  }) => isSimulation
      ? RouteAuthority.personal
      : isLocalRideLeader
      ? RouteAuthority.leader
      : RouteAuthority.follower;

  /// Whether this surface may build or replace the route it is showing.
  bool get canEditRoute => this != RouteAuthority.follower;

  /// Why a route change is refused, or null when it is allowed.
  ///
  /// Nullable rather than a string for every case, so "allowed" cannot be
  /// rendered as a refusal by accident. This is the only place the sentence is
  /// written; it reaches riders through [ScaffoldMessenger] and through
  /// `ActiveRideShell`'s warning list, and both must say the same thing.
  String? get routeChangeRefusal => switch (this) {
    RouteAuthority.personal || RouteAuthority.leader => null,
    RouteAuthority.follower => groupRouteRefusal,
  };

  /// The refusal a rider who is not the leader sees, wherever it is raised.
  static const groupRouteRefusal =
      'Only the ride leader can replace the group route.';
}
