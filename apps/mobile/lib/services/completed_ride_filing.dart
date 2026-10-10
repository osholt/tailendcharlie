import '../domain/completed_ride.dart';
import '../domain/completed_ride_store.dart';
import '../domain/recorded_route_store.dart';
import 'completed_ride_plan_link.dart';

/// Files a completed ride in My rides, as one ride with any leg it carried on
/// from (#896).
///
/// Converting solo ↔ group used to file two rides — the solo navigation and
/// the group ride — and a rider looking back saw half of their day twice. A
/// ride that names the leg it continued ([CompletedRide.continuesRideId]) is
/// joined to that leg here: one record, under the later ride's id, with both
/// legs' time, distance and track, and the earlier record removed once the
/// joined one is safely written.
///
/// Every leg can be saved more than once — a free-roam checkpoint, a final
/// save, a journal replayed after a restart — so filing is idempotent:
///
/// - the later leg finds the earlier one inside its own joined record, and
///   joins it again rather than losing it;
/// - an earlier leg that is already inside a later ride (a group ride's
///   journal replayed after the rider rode on alone) is not filed a second
///   time beside it.
///
/// Library edits made in My rides are kept, as `completeRidePlanLink` keeps
/// them for a single ride.
Future<CompletedRide> fileCompletedRide(
  CompletedRideStore store,
  CompletedRide ride, {
  RecordedRouteStore? library,
}) async {
  final stored = await store.list();
  final absorbedInto = stored
      .where(
        (other) =>
            other.rideId != ride.rideId &&
            other.legs.any((leg) => leg.rideId == ride.rideId),
      )
      .firstOrNull;
  if (absorbedInto != null) return absorbedInto;

  final existing = stored
      .where((other) => other.rideId == ride.rideId)
      .firstOrNull;
  final linked = await completeRidePlanLink(
    ride,
    existing: existing,
    library: library,
  );
  final earlierId = linked.continuesRideId;
  final kept = existing?.previousLeg;
  final earlier = earlierId == null
      ? null
      : kept != null && kept.rideId == earlierId
      ? kept
      : stored.where((other) => other.rideId == earlierId).firstOrNull;
  final filed = earlier == null
      ? linked
      : CompletedRide.joined(earlier, linked);
  await store.save(filed);
  // Removed only after the joined record is written: a failure in between
  // leaves the leg twice, never not at all.
  if (earlier != null &&
      stored.any((other) => other.rideId == earlier.rideId)) {
    await store.delete(earlier.rideId);
  }
  return filed;
}
