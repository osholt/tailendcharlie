import '../domain/ride_event.dart';
import '../domain/ride_role.dart';
import 'ride_event_authenticator.dart';

enum RidePhase { open, started, ended }

class RideLifecycle {
  const RideLifecycle({this.startEvent});

  final RideEvent? startEvent;

  bool get started => startEvent != null;
  DateTime? get startedAt => startEvent?.createdAt;
}

/// Reconstructs the authoritative ride start from the signed event journal.
///
/// Events are ordered by timestamp and then ID so every device chooses the
/// same start after offline delivery, retries, or duplicate start taps. A
/// start is accepted only from a rider whose latest signed role at that point
/// is lead, and the event must identify its author as that leader.
class RideLifecycleReducer {
  const RideLifecycleReducer._();

  static RideLifecycle fromEvents({
    required String rideId,
    required String inviteSecret,
    required Iterable<RideEvent> events,
  }) {
    final ordered =
        events
            .where(
              (event) =>
                  event.rideId == rideId &&
                  RideEventAuthenticator.verify(event, inviteSecret),
            )
            .toList(growable: false)
          ..sort(compareEvents);
    final roles = <String, RideRole>{};

    for (final event in ordered) {
      switch (event.type) {
        case RideEventType.rideCreated:
        case RideEventType.riderJoined:
        case RideEventType.roleChanged:
          final role = _roleFromPayload(event.payload['role']);
          if (role != null) roles[event.deviceId] = role;
          break;
        case RideEventType.rideStarted:
          if (roles[event.deviceId] == RideRole.lead &&
              event.payload['leaderRiderId'] == event.deviceId) {
            return RideLifecycle(startEvent: event);
          }
        case RideEventType.markerStarted:
        case RideEventType.riderLeft:
        case RideEventType.markerPass:
        case RideEventType.markerEnded:
        case RideEventType.statusMessage:
        case RideEventType.riderLocationUpdated:
        case RideEventType.hazardReported:
        case RideEventType.hazardCleared:
        case RideEventType.routeDeviationChanged:
        case RideEventType.routeAlertAcknowledged:
        case RideEventType.routeRevisionChunk:
        case RideEventType.routeRevisionPublished:
        case RideEventType.routeCleared:
        case RideEventType.ridePaused:
        case RideEventType.rideResumed:
        case RideEventType.rideEnded:
        case RideEventType.iceInfoShared:
        case RideEventType.iceInfoViewed:
          break;
      }
    }
    return const RideLifecycle();
  }

  static int compareEvents(RideEvent left, RideEvent right) {
    final byTime = left.createdAt.compareTo(right.createdAt);
    return byTime != 0 ? byTime : left.id.compareTo(right.id);
  }

  static RideRole? _roleFromPayload(Object? value) {
    if (value is! String) return null;
    try {
      return RideRole.values.byName(value);
    } on ArgumentError {
      return null;
    }
  }
}
