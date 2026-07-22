import '../domain/marker_assistance.dart';
import '../domain/ride_event.dart';

abstract final class MarkerStatistics {
  static RideMarkingSummary fromEvents(
    Iterable<RideEvent> source, {
    required DateTime asOf,
    String? markerDeviceId,
    Map<String, String>? authenticatedLocationEvidence,
  }) {
    final events = source.toList()..sort(_compareEvents);
    final sessionsById = <String, _SessionBuilder>{};
    final activeSessionByDevice = <String, String>{};

    for (final event in events) {
      if (markerDeviceId != null && event.deviceId != markerDeviceId) continue;
      switch (event.type) {
        case RideEventType.markerStarted:
          final sessionId =
              event.payload['markerSessionId'] as String? ?? event.id;
          final builder = _SessionBuilder(
            sessionId: sessionId,
            markerDeviceId: event.deviceId,
            startedAt: event.createdAt,
            mode: event.payload['mode'] as String? ?? 'manual',
            decisionPointId: event.payload['decisionPointId'] as String?,
          );
          sessionsById[_key(event.deviceId, sessionId)] = builder;
          activeSessionByDevice[event.deviceId] = sessionId;
          break;
        case RideEventType.markerPass:
          final active = _sessionFor(
            event,
            sessionsById,
            activeSessionByDevice,
          );
          if (active == null) break;
          final riderId = event.payload['riderId'];
          if (riderId is! String || riderId.isEmpty) break;
          active.uniqueRiderIds.add(riderId);
          final verified =
              event.payload['authenticated'] == true &&
              event.payload['evidenceEventId'] is String &&
              (authenticatedLocationEvidence == null ||
                  authenticatedLocationEvidence[event.payload['evidenceEventId']
                          as String] ==
                      riderId);
          if (verified) {
            active.verifiedRiderIds.add(riderId);
            if (event.payload['role'] == 'tailEndCharlie') {
              active.tecPassedAt ??= event.createdAt;
            }
          }
          break;
        case RideEventType.markerEnded:
          final active = _sessionFor(
            event,
            sessionsById,
            activeSessionByDevice,
          );
          if (active == null) break;
          active.endedAt = event.createdAt;
          if (activeSessionByDevice[event.deviceId] == active.sessionId) {
            activeSessionByDevice.remove(event.deviceId);
          }
          break;
        case RideEventType.rideCreated:
        case RideEventType.riderJoined:
        case RideEventType.riderLeft:
        case RideEventType.roleChanged:
        case RideEventType.rideStarted:
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

    final sessions = sessionsById.values.toList()
      ..sort((first, second) => first.startedAt.compareTo(second.startedAt));
    return RideMarkingSummary(
      asOf: asOf,
      sessions: sessions.map((session) => session.build()).toList(),
    );
  }

  static _SessionBuilder? _sessionFor(
    RideEvent event,
    Map<String, _SessionBuilder> sessionsById,
    Map<String, String> activeSessionByDevice,
  ) {
    final explicitSessionId = event.payload['markerSessionId'] as String?;
    final sessionId =
        explicitSessionId ?? activeSessionByDevice[event.deviceId];
    if (sessionId == null) return null;
    final session = sessionsById[_key(event.deviceId, sessionId)];
    return session?.markerDeviceId == event.deviceId ? session : null;
  }

  static String _key(String deviceId, String sessionId) =>
      '$deviceId\u0000$sessionId';

  static int _compareEvents(RideEvent first, RideEvent second) {
    final time = first.createdAt.compareTo(second.createdAt);
    return time != 0 ? time : first.id.compareTo(second.id);
  }
}

class _SessionBuilder {
  _SessionBuilder({
    required this.sessionId,
    required this.markerDeviceId,
    required this.startedAt,
    required this.mode,
    required this.decisionPointId,
  });

  final String sessionId;
  final String markerDeviceId;
  final DateTime startedAt;
  final String mode;
  final String? decisionPointId;
  final Set<String> uniqueRiderIds = {};
  final Set<String> verifiedRiderIds = {};
  DateTime? endedAt;
  DateTime? tecPassedAt;

  MarkerSessionSummary build() => MarkerSessionSummary(
    sessionId: sessionId,
    markerDeviceId: markerDeviceId,
    startedAt: startedAt,
    endedAt: endedAt,
    mode: mode,
    decisionPointId: decisionPointId,
    uniquePassCount: uniqueRiderIds.length,
    uniqueRiderIds: uniqueRiderIds.toList(growable: false)..sort(),
    verifiedPassCount: verifiedRiderIds.length,
    verifiedRiderIds: verifiedRiderIds.toList(growable: false)..sort(),
    tecPassedAt: tecPassedAt,
  );
}
