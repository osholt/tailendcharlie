import 'dart:math' as math;

import '../domain/geo_point.dart';
import '../domain/rider_location.dart';

/// Conservative, leader-owned completion check for a group ride.
///
/// A ride only ends after the route has actually been ridden *and* every rider
/// with a known position has sent a recent fix inside the destination radius.
/// Stale data therefore keeps the ride open rather than accidentally ending it
/// while somebody has dropped signal.
///
/// The progress gate exists because proximity alone is not arrival (#206). A day
/// tour is normally a loop: it starts and finishes at the same hotel, so every
/// rider satisfies the radius test at the moment the ride begins. A tester's
/// Isle of Man tour ended itself twenty minutes in for exactly that reason, and
/// could not be resumed.
///
/// The two failure directions are not symmetric. Ending a ride early strands the
/// group mid-route and cannot be undone from a rider's phone; failing to end one
/// automatically costs the leader a single tap. The gate is therefore set high on
/// purpose.
class RideCompletionDetector {
  const RideCompletionDetector({
    this.destinationRadiusMeters = 90,
    this.locationFreshness = const Duration(minutes: 2),
    this.minimumRouteProgressFraction = 0.9,
  });

  final double destinationRadiusMeters;
  final Duration locationFreshness;

  /// How much of the route must be behind the group before arrival is even
  /// considered, as a fraction of the primary path's length.
  final double minimumRouteProgressFraction;

  /// [routeProgressFraction] is monotonic progress along the route, 0 to 1, as
  /// tracked by `RouteProgressTracker`. A route with no measurable length must
  /// pass 0 so that a degenerate plan can never end a ride on its own.
  bool everyoneReachedDestination({
    required GeoPoint destination,
    required Iterable<RiderLocation> riderLocations,
    required DateTime now,
    required double routeProgressFraction,
  }) {
    if (!routeProgressFraction.isFinite ||
        routeProgressFraction < minimumRouteProgressFraction) {
      return false;
    }
    final latestByRider = <String, RiderLocation>{
      for (final location in riderLocations) location.riderId: location,
    };
    if (latestByRider.isEmpty) return false;
    return latestByRider.values.every((location) {
      if (location.sample.isStaleAt(now, locationFreshness)) return false;
      return _distanceMeters(location.sample.position, destination) <=
          destinationRadiusMeters;
    });
  }
}

double _distanceMeters(GeoPoint first, GeoPoint second) {
  const earthRadiusMeters = 6371008.8;
  final latitude1 = first.latitude * math.pi / 180;
  final latitude2 = second.latitude * math.pi / 180;
  final latitudeDelta = latitude2 - latitude1;
  final longitudeDelta = (second.longitude - first.longitude) * math.pi / 180;
  final a =
      math.pow(math.sin(latitudeDelta / 2), 2) +
      math.cos(latitude1) *
          math.cos(latitude2) *
          math.pow(math.sin(longitudeDelta / 2), 2);
  return earthRadiusMeters * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}
