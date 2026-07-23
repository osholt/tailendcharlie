import '../domain/completed_ride.dart';
import '../domain/imported_route.dart';
import '../domain/ride_event.dart';
import '../domain/ride_session.dart';
import 'ride_summary_exporter.dart';

class CompletedRideArchiver {
  const CompletedRideArchiver({
    this.summaryExporter = const RideSummaryExporter(),
  });

  final RideSummaryExporter summaryExporter;

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
    );
  }
}
