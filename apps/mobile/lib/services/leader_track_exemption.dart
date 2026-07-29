import 'dart:math' as math;

import '../domain/geo_point.dart';
import 'geo_calculations.dart';

/// A rider inside the corridor of the leader's *actual* recorded track is on
/// route, whatever the planned GPX says. This is the single definition used for
/// alert state, the leader's off-course count, the roster and the map, so a
/// group following the leader down a diversion never reads as lost.
///
/// It lives in its own file so the deviation/alert side and the rejoin-routing
/// side can both depend on it without depending on each other.
abstract final class LeaderTrackExemption {
  static const defaultRecentPointLimit = 600;

  /// [leaderTrack] is the leader's recorded trail. Only the most recent
  /// [recentPointLimit] points are considered: "following the leader" means
  /// being near where the leader has recently been, not standing where the
  /// leader passed two hours ago, and it keeps the check cheap enough to run on
  /// every read.
  static bool isFollowingLeaderTrack({
    required GeoPoint position,
    required List<GeoPoint> leaderTrack,
    double accuracyMeters = 0,
    double corridorMeters = 120,
    int recentPointLimit = defaultRecentPointLimit,
  }) {
    if (leaderTrack.length < 2) return false;
    final recent = leaderTrack.length > recentPointLimit
        ? leaderTrack.sublist(leaderTrack.length - recentPointLimit)
        : leaderTrack;
    final distance = GeoCalculations.distanceToPolylineMeters(position, recent);
    // Give the rider the benefit of their own GPS error: an uncertain fix
    // beside the leader's track must not be called off course.
    return math.max(0, distance - accuracyMeters) <= corridorMeters;
  }
}
