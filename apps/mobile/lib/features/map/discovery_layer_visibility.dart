/// What the map is being used for, as far as the optional discovery layers - the
/// orange and blue road highlights, the mountain passes and the biker cafés - are
/// concerned (#846).
enum DiscoveryLayerContext {
  /// Free roam with no route on the map: browsing for somewhere to go.
  freeRoamBrowsing,

  /// A route is on the map and nobody is following it yet: building a plan, or a
  /// group ride that has not started.
  planning,

  /// Reviewing a route before committing to it. The review screen has its own
  /// layer switch and draws its own pins, so a ride in progress underneath does
  /// not reach it.
  routeReview,

  /// A rider following a route outside any ride, from free roam or a searched
  /// destination.
  freeRoamNavigation,

  /// A started ride, solo or group.
  rideNavigation,
}

/// Whether the discovery layers are drawn in [context].
///
/// They exist for choosing where to go. Once a route is being followed they sit
/// beside the route line and read as part of it, which is what a rider on a group
/// ride found confusing, so they stay off until the rider is planning or browsing
/// again.
///
/// This decides what is *drawn*. It never touches what the rider chose in the
/// layer menu: their saved choices are read and written exactly as before, so the
/// layers come back, as chosen, the moment navigation ends.
bool discoveryLayersShownIn(DiscoveryLayerContext context) => switch (context) {
  DiscoveryLayerContext.freeRoamBrowsing ||
  DiscoveryLayerContext.planning ||
  DiscoveryLayerContext.routeReview => true,
  DiscoveryLayerContext.freeRoamNavigation ||
  DiscoveryLayerContext.rideNavigation => false,
};

/// The context the live map is in.
///
/// [navigating] is "following a route right now", ride or no ride;
/// [rideStarted] is whether a ride is under way; [hasRoute] is whether the map
/// holds a route. A route that is on the map but not being followed is planning.
DiscoveryLayerContext discoveryLayerContextFor({
  required bool navigating,
  required bool rideStarted,
  required bool hasRoute,
}) {
  if (navigating) {
    return rideStarted
        ? DiscoveryLayerContext.rideNavigation
        : DiscoveryLayerContext.freeRoamNavigation;
  }
  return hasRoute
      ? DiscoveryLayerContext.planning
      : DiscoveryLayerContext.freeRoamBrowsing;
}
