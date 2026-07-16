import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/data/in_memory_event_store.dart';
import 'package:ride_relay/domain/ride_event.dart';
import 'package:ride_relay/relay/nearby_event_source.dart';

void main() {
  test(
    'server acknowledgement does not suppress nearby carrier delivery',
    () async {
      final store = InMemoryEventStore();
      final event = RideEvent(
        id: 'server-acknowledged',
        rideId: 'ride-alpha',
        deviceId: 'rider-one',
        type: RideEventType.statusMessage,
        priority: EventPriority.routine,
        createdAt: DateTime.utc(2026, 7, 16),
        payload: const {'message': 'Road closed'},
        signature: 'a' * 64,
      );
      await store.append(event);
      await store.markAcknowledged(event.id);

      expect(await store.pendingEvents(event.rideId), isEmpty);
      expect(
        (await eventsEligibleForNearbyRelay(
          store,
          event.rideId,
        )).map((candidate) => candidate.id),
        ['server-acknowledged'],
      );
    },
  );
}
