import '../domain/completed_ride.dart';
import '../domain/imported_route.dart';
import '../domain/recorded_route_store.dart';

/// Snapshot an explicitly related library plan. Never infer a historical link
/// from similar geometry or names. A missing/unreadable library cannot prevent
/// the actual ride being saved; a later checkpoint can retry the link.
Future<CompletedRide> completeRidePlanLink(
  CompletedRide ride, {
  CompletedRide? existing,
  RecordedRouteStore? library,
}) async {
  ImportedRoute? source = existing?.sourceRoute ?? ride.sourceRoute;
  final plan = existing?.plannedRoute ?? ride.plannedRoute;
  final sourceId = plan?.sourceRouteId ?? plan?.id;
  if (source == null && library != null && sourceId != null) {
    try {
      source = (await library.list())
          .where((route) => route.id == sourceId)
          .firstOrNull;
    } on Object {
      // Saving the recording is more important than this optional lookup.
    }
  }
  return ride.copyWith(
    sourceRoute: source,
    plannedRoute: plan,
    libraryName: existing?.libraryName,
    rating: existing?.rating,
    notes: existing?.notes,
    libraryStatus: existing?.libraryStatus,
    deletedAt: existing?.deletedAt,
    organisation: existing?.organisation,
  );
}
