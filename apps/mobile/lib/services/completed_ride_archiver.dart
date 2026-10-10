import '../domain/completed_ride.dart';
import '../domain/imported_route.dart';
import '../domain/ride_event.dart';
import '../domain/ride_session.dart';
import 'ride_alert_log.dart';
import 'ride_broadcast_log.dart';
import 'ride_summary_exporter.dart';

class CompletedRideArchiver {
  const CompletedRideArchiver({
    this.summaryExporter = const RideSummaryExporter(),
    this.alertLog = const RideAlertLogReducer(),
    this.broadcastLog = const RideBroadcastLogReducer(),
  });

  final RideSummaryExporter summaryExporter;
  final RideAlertLogReducer alertLog;
  final RideBroadcastLogReducer broadcastLog;

  CompletedRide create({
    required RideSession session,
    required Iterable<RideEvent> events,
    required DateTime archivedAt,
    ImportedRoute? plannedRoute,
  }) {
    final summary = summaryExporter.summarize(
      session,
      events,
      generatedAt: archivedAt,
    );
    return CompletedRide(
      rideId: session.rideId,
      rideCode: session.rideCode,
      rideName: session.rideName,
      continuesRideId: session.continuesRideId,
      localDisplayName: session.displayName,
      localRole: session.role,
      startedAt: summary.startedAt,
      endedAt: summary.endedAt ?? archivedAt,
      archivedAt: archivedAt,
      riderCount: summary.riderCount,
      eventCount: summary.eventCount,
      totalDistanceMeters: summary.totalDistanceMeters,
      markerSessions: [
        for (final marker in summary.markerSessions)
          CompletedMarkerSession(
            startedAt: marker.startedAt,
            endedAt: marker.endedAt,
            uniquePassCount: marker.uniquePassCount,
          ),
      ],
      plannedRoute: plannedRoute,
      traveledRoute: summaryExporter.traveledRoute(
        session,
        events,
        generatedAt: archivedAt,
      ),
      // Everyone's alerts, not only this rider's: the review is of the group's
      // ride, and an alert a leader raised is as much a moment to find in a
      // follower's footage (#849).
      alerts: alertLog.fromEvents(
        rideId: session.rideId,
        inviteSecret: session.inviteSecret,
        events: events,
        localRiderId: session.localRiderId,
      ),
      // What the leader told the group (#854), for the ride history.
      broadcasts: broadcastLog.fromEvents(
        rideId: session.rideId,
        inviteSecret: session.inviteSecret,
        events: events,
        localRiderId: session.localRiderId,
      ),
    );
  }
}
