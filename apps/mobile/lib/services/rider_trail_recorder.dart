import '../domain/imported_route.dart';

/// How a route or trail line is presented on the ride map.
///
/// The kind only affects styling and never whether a trail exists: a rider who
/// has left the planned route still has a trail, it simply reads as an
/// off-route excursion.
enum RiderTrailKind {
  /// Any rider's travelled path, including the local rider's own.
  rider,

  /// The current leader's travelled path - the group's ground truth when the
  /// plan stops matching the road, so it is styled as the most prominent trail
  /// and is rendered on every participant's map.
  leader,

  /// A rider whose route alert says they are suspected off route, confirmed off
  /// route, or recovering.
  offRoute,

  /// The advisory rejoin route computed for an off-course rider (#102). The one
  /// kind that is not recorded history: it is where the routing engine says to
  /// go next, which is why it is never produced by [RiderTrailRecorder] and is
  /// published alongside the recorded trails instead.
  rejoin,
}

/// One rider's travelled path, ready to be rendered.
class RiderTrail {
  const RiderTrail({
    required this.riderId,
    required this.displayName,
    required this.kind,
    required this.points,
  });

  final String riderId;
  final String displayName;
  final RiderTrailKind kind;
  final List<GeoPoint> points;

  bool get isRenderable => points.length >= 2;
}

/// One rider's current state, as far as trail recording is concerned.
///
/// Note what is absent: whether a route is loaded, and how far this rider is
/// from it. Neither may decide whether a trail exists.
class RiderTrailUpdate {
  const RiderTrailUpdate({
    required this.riderId,
    required this.displayName,
    this.position,
    this.isLeader = false,
    this.isOffRoute = false,
    this.isEligible = true,
    this.journalTrail,
  });

  final String riderId;
  final String displayName;

  /// The newest known fix, or null when this refresh brought nothing new.
  final GeoPoint? position;

  final bool isLeader;

  /// Whether the rider's route alert says they are off route. Styling only.
  final bool isOffRoute;

  /// Whether the rider is eligible for live position sharing. An ineligible
  /// rider's history is dropped rather than retained unseen.
  final bool isEligible;

  /// History recovered from the durable ride journal, which is what lets a
  /// trail survive an app restart mid-ride. Preferred over this device's live
  /// recording when it is longer.
  final List<GeoPoint>? journalTrail;
}

/// Records where every rider has actually been, from position history alone.
///
/// Route matching is deliberately not an input. The travelled trail used to be
/// derived from the planned route's progress split plus an off-route trace that
/// only existed while a rider was flagged, so a leader who rode off the
/// imported GPX - a state the leader can never be flagged for, because their
/// own trail is treated as a valid route - lost their trail entirely (#100).
/// Recording is therefore unconditional, and route matching is left to drive
/// route progress and alerts only.
///
/// Samples are inserted in recorded order rather than arrival order, because
/// relayed and journal-replayed fixes are not guaranteed to arrive in the order
/// they were recorded. Each rider's history is bounded by
/// [maximumPointsPerRider]; the oldest points are dropped first so the visible
/// trail stays continuous up to the current position.
class RiderTrailRecorder {
  RiderTrailRecorder({
    this.maximumPointsPerRider = defaultMaximumPointsPerRider,
    this.minimumSeparationDegrees = 1e-7,
  }) : assert(maximumPointsPerRider >= 2),
       assert(minimumSeparationDegrees >= 0);

  /// Bounded per-rider memory. Applied identically to every rider, including
  /// the local one, so no rider's trail can grow without limit on a long ride.
  static const defaultMaximumPointsPerRider = 120;

  final int maximumPointsPerRider;
  final double minimumSeparationDegrees;

  final _trails = <String, List<GeoPoint>>{};

  /// The recorded trail for [riderId], oldest point first.
  List<GeoPoint> trailFor(String riderId) =>
      List.unmodifiable(_trails[riderId] ?? const <GeoPoint>[]);

  /// Records this refresh's fixes and returns every rider's trail.
  ///
  /// Unconditional: a rider off the planned route, a rider with no planned
  /// route at all, and the leader - who is never flagged off route because
  /// their own trail counts as a valid route - all keep a trail. The off-route
  /// flag only chooses how the trail is styled.
  List<RiderTrail> update(Iterable<RiderTrailUpdate> riders) {
    final trails = <RiderTrail>[];
    for (final rider in riders) {
      if (!rider.isEligible) {
        forget(rider.riderId);
        continue;
      }
      final position = rider.position;
      if (position != null) {
        record(riderId: rider.riderId, point: position);
      }
      final recorded = trailFor(rider.riderId);
      final journal = rider.journalTrail;
      trails.add(
        RiderTrail(
          riderId: rider.riderId,
          displayName: rider.displayName,
          kind: kindFor(isLeader: rider.isLeader, isOffRoute: rider.isOffRoute),
          points: journal != null && journal.length > recorded.length
              ? boundedTrail(journal)
              : recorded,
        ),
      );
    }
    return List.unmodifiable(trails);
  }

  /// The most recent [maximumPointsPerRider] points of [trail], so history from
  /// any source obeys the same bound.
  List<GeoPoint> boundedTrail(List<GeoPoint> trail) => List.unmodifiable(
    trail.length > maximumPointsPerRider
        ? trail.sublist(trail.length - maximumPointsPerRider)
        : trail,
  );

  /// The leader kind always wins: a leader cannot be off route by design, so
  /// their trail must never be restyled as an excursion.
  static RiderTrailKind kindFor({
    required bool isLeader,
    required bool isOffRoute,
  }) => isLeader
      ? RiderTrailKind.leader
      : isOffRoute
      ? RiderTrailKind.offRoute
      : RiderTrailKind.rider;

  /// Records [point] for [riderId] and reports whether it extended the trail.
  ///
  /// Points that repeat the rider's last recorded position, or that predate an
  /// already recorded position, are ignored rather than reordering history.
  bool record({required String riderId, required GeoPoint point}) {
    final trail = _trails.putIfAbsent(riderId, () => <GeoPoint>[]);
    final index = _insertionIndex(trail, point);
    if (index == null) return false;
    trail.insert(index, point);
    if (trail.length > maximumPointsPerRider) {
      trail.removeRange(0, trail.length - maximumPointsPerRider);
    }
    return true;
  }

  /// Drops [riderId]'s history, used when a rider stops being eligible for
  /// live position sharing.
  ///
  /// A rider simply missing from a refresh keeps their history: they may be
  /// briefly stale rather than gone, and a returning rider must not restart
  /// their trail.
  void forget(String riderId) => _trails.remove(riderId);

  void clear() => _trails.clear();

  int? _insertionIndex(List<GeoPoint> trail, GeoPoint point) {
    if (trail.isEmpty) return 0;
    final recordedAt = point.recordedAt;
    if (recordedAt == null) {
      return _isSamePlace(trail.last, point) ? null : trail.length;
    }
    var index = trail.length;
    while (index > 0) {
      final previous = trail[index - 1].recordedAt;
      if (previous == null || !previous.isAfter(recordedAt)) break;
      index -= 1;
    }
    if (index > 0) {
      final previous = trail[index - 1];
      if (previous.recordedAt != null &&
          !previous.recordedAt!.isBefore(recordedAt)) {
        return null;
      }
      if (_isSamePlace(previous, point)) return null;
    }
    return index;
  }

  bool _isSamePlace(GeoPoint first, GeoPoint second) =>
      (first.latitude - second.latitude).abs() <= minimumSeparationDegrees &&
      (first.longitude - second.longitude).abs() <= minimumSeparationDegrees;
}
