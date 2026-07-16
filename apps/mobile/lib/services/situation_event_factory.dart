import '../domain/ride_event.dart';
import '../domain/ride_session.dart';
import 'ride_event_authenticator.dart';

typedef SituationClock = DateTime Function();
typedef SituationIdFactory = String Function();

class SituationEventFactory {
  const SituationEventFactory({
    required this.session,
    required this.clock,
    required this.idFactory,
  });

  final RideSession session;
  final SituationClock clock;
  final SituationIdFactory idFactory;

  RideEvent create({
    required RideEventType type,
    required Map<String, Object?> payload,
    EventPriority priority = EventPriority.routine,
    DateTime? expiresAt,
  }) {
    final event = RideEvent(
      id: idFactory(),
      rideId: session.rideId,
      deviceId: session.localRiderId,
      type: type,
      priority: priority,
      createdAt: clock(),
      expiresAt: expiresAt,
      payload: payload,
      signature: '',
      schemaVersion: 1,
    );
    return RideEvent(
      id: event.id,
      rideId: event.rideId,
      deviceId: event.deviceId,
      type: event.type,
      priority: event.priority,
      createdAt: event.createdAt,
      expiresAt: event.expiresAt,
      payload: event.payload,
      signature: sign(event, session.inviteSecret),
      schemaVersion: event.schemaVersion,
    );
  }

  static String sign(RideEvent event, String secret) =>
      RideEventAuthenticator.sign(event, secret);

  static bool verify(RideEvent event, String secret) =>
      RideEventAuthenticator.verify(event, secret);
}
