import '../domain/event_store.dart';
import '../domain/ride_event.dart';

/// Nearby delivery state lives in the nearby relay queue, so the shared event
/// store's server acknowledgement must not make an event ineligible here.
Future<List<RideEvent>> eventsEligibleForNearbyRelay(
  EventStore eventStore,
  String rideId,
) => eventStore.eventsForRide(rideId);
