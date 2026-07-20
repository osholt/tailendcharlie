import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/geo_point.dart';
import 'package:ride_relay/domain/ride_event.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/ride_session.dart';
import 'package:ride_relay/domain/rider_location.dart';
import 'package:ride_relay/services/ride_summary_exporter.dart';

void main() {
  test('summarizes complete and active marker sessions deterministically', () {
    final session = RideSession(
      rideId: 'ride-1',
      rideCode: 'ABC123',
      inviteSecret: 'secret',
      joinToken: 'test-join-token-0123456789',
      localRiderId: 'device-a',
      displayName: 'Oliver',
      role: RideRole.lead,
      joinedAt: DateTime.utc(2026, 7, 16, 9, 55),
    );
    final events = [
      _event('1', RideEventType.rideCreated, 10),
      _event('2', RideEventType.markerStarted, 11),
      _event(
        '3',
        RideEventType.markerPass,
        12,
        payload: const {'riderId': 'rider-1'},
      ),
      _event(
        '4',
        RideEventType.markerPass,
        13,
        payload: const {'riderId': 'rider-1'},
      ),
      _event(
        '5',
        RideEventType.markerEnded,
        16,
        payload: const {'uniquePasses': 3},
      ),
      _event('6', RideEventType.markerStarted, 20),
    ];
    const exporter = RideSummaryExporter();

    final summary = exporter.summarize(
      session,
      events,
      generatedAt: DateTime.utc(2026, 7, 16, 10, 25),
    );

    expect(summary.markerSessions, hasLength(2));
    expect(summary.markerSessions.first.duration, const Duration(minutes: 5));
    expect(summary.markerSessions.first.uniquePassCount, 3);
    expect(summary.markerSessions.first.isComplete, isTrue);
    expect(summary.markerSessions.last.duration, const Duration(minutes: 5));
    expect(summary.markerSessions.last.isComplete, isFalse);
    expect(summary.totalMarkingDuration, const Duration(minutes: 10));
    expect(summary.totalConfirmedPasses, 3);
    expect(
      exporter.toPlainText(summary),
      contains('Time spent marking: 10m 0s'),
    );
    expect(exporter.toCsv(summary), contains('"duration_seconds"'));
    expect(exporter.toCsv(summary), contains('"300","3","true"'));
    expect(exporter.fileName(summary), 'ride-relay-abc123-summary.csv');
  });

  test("counts distinct riders and totals the local rider's distance", () {
    final session = RideSession(
      rideId: 'ride-1',
      rideCode: 'ABC123',
      inviteSecret: 'secret',
      joinToken: 'test-join-token-0123456789',
      localRiderId: 'device-a',
      displayName: 'Oliver',
      role: RideRole.lead,
      joinedAt: DateTime.utc(2026, 7, 16, 9, 55),
    );
    final events = [
      _event('1', RideEventType.rideCreated, 10),
      _joinEvent('2', deviceId: 'device-b', minute: 10),
      _locationEvent(
        '3',
        deviceId: 'device-a',
        riderId: 'device-a',
        minute: 11,
        latitude: 53,
        longitude: -1,
      ),
      _locationEvent(
        '4',
        deviceId: 'device-a',
        riderId: 'device-a',
        minute: 12,
        latitude: 53.01,
        longitude: -1,
      ),
      // A different rider's own location updates count toward the rider
      // total, but never toward the local rider's own trail/distance.
      _locationEvent(
        '5',
        deviceId: 'device-b',
        riderId: 'device-b',
        minute: 12,
        latitude: 60,
        longitude: 5,
      ),
    ];
    const exporter = RideSummaryExporter();

    final summary = exporter.summarize(
      session,
      events,
      generatedAt: DateTime.utc(2026, 7, 16, 10, 25),
    );

    expect(summary.riderCount, 2);
    expect(summary.totalDistanceMeters, closeTo(1111.95, 1));
    expect(exporter.toCsv(summary), contains('"rider_count","2"'));
    expect(exporter.toPlainText(summary), contains('Riders on this ride: 2'));
  });

  test("builds a GPX track from the local rider's own trail", () {
    final session = RideSession(
      rideId: 'ride-1',
      rideCode: 'ABC123',
      inviteSecret: 'secret',
      joinToken: 'test-join-token-0123456789',
      localRiderId: 'device-a',
      displayName: 'Oliver',
      role: RideRole.lead,
      joinedAt: DateTime.utc(2026, 7, 16, 9, 55),
    );
    final events = [
      _locationEvent(
        '1',
        deviceId: 'device-a',
        riderId: 'device-a',
        minute: 11,
        latitude: 53,
        longitude: -1,
      ),
      _locationEvent(
        '2',
        deviceId: 'device-a',
        riderId: 'device-a',
        minute: 12,
        latitude: 53.01,
        longitude: -1,
      ),
    ];
    const exporter = RideSummaryExporter();

    final route = exporter.traveledRoute(
      session,
      events,
      generatedAt: DateTime.utc(2026, 7, 16, 10, 25),
    );

    expect(route, isNotNull);
    expect(route!.paths, hasLength(1));
    expect(route.paths.single.points, hasLength(2));
    expect(route.paths.single.points.first.latitude, 53);
    expect(route.paths.single.points.last.latitude, 53.01);
  });

  test('traveledRoute returns null without at least two position fixes', () {
    final session = RideSession(
      rideId: 'ride-1',
      rideCode: 'ABC123',
      inviteSecret: 'secret',
      joinToken: 'test-join-token-0123456789',
      localRiderId: 'device-a',
      displayName: 'Oliver',
      role: RideRole.lead,
      joinedAt: DateTime.utc(2026, 7, 16, 9, 55),
    );
    const exporter = RideSummaryExporter();

    final route = exporter.traveledRoute(
      session,
      const [],
      generatedAt: DateTime.utc(2026, 7, 16, 10, 25),
    );

    expect(route, isNull);
  });

  test('ignores malformed location payloads instead of failing the export', () {
    final session = RideSession(
      rideId: 'ride-1',
      rideCode: 'ABC123',
      inviteSecret: 'secret',
      joinToken: 'test-join-token-0123456789',
      localRiderId: 'device-a',
      displayName: 'Oliver',
      role: RideRole.lead,
      joinedAt: DateTime.utc(2026, 7, 16, 9, 55),
    );
    final events = [
      RideEvent(
        id: '1',
        rideId: 'ride-1',
        deviceId: 'device-a',
        type: RideEventType.riderLocationUpdated,
        priority: EventPriority.routine,
        createdAt: DateTime.utc(2026, 7, 16, 10, 11),
        payload: const {
          'location': {'sample': 'not-a-map'},
        },
        signature: 'test',
      ),
    ];
    const exporter = RideSummaryExporter();

    final summary = exporter.summarize(
      session,
      events,
      generatedAt: DateTime.utc(2026, 7, 16, 10, 25),
    );

    expect(summary.totalDistanceMeters, 0);
    expect(
      exporter.traveledRoute(
        session,
        events,
        generatedAt: DateTime.utc(2026, 7, 16, 10, 25),
      ),
      isNull,
    );
  });
}

RideEvent _joinEvent(
  String id, {
  required String deviceId,
  required int minute,
}) => RideEvent(
  id: id,
  rideId: 'ride-1',
  deviceId: deviceId,
  type: RideEventType.riderJoined,
  priority: EventPriority.routine,
  createdAt: DateTime.utc(2026, 7, 16, 10, minute),
  payload: const {},
  signature: 'test',
);

RideEvent _locationEvent(
  String id, {
  required String deviceId,
  required String riderId,
  required int minute,
  required double latitude,
  required double longitude,
}) {
  final location = RiderLocation(
    riderId: riderId,
    displayName: riderId,
    role: RideRole.rider,
    sample: LocationSample(
      position: GeoPoint(latitude: latitude, longitude: longitude),
      recordedAt: DateTime.utc(2026, 7, 16, 10, minute),
      accuracyMeters: 5,
    ),
    receivedAt: DateTime.utc(2026, 7, 16, 10, minute),
  );
  return RideEvent(
    id: id,
    rideId: 'ride-1',
    deviceId: deviceId,
    type: RideEventType.riderLocationUpdated,
    priority: EventPriority.routine,
    createdAt: DateTime.utc(2026, 7, 16, 10, minute),
    payload: {'location': location.toJson()},
    signature: 'test',
  );
}

RideEvent _event(
  String id,
  RideEventType type,
  int minute, {
  Map<String, Object?> payload = const {},
}) => RideEvent(
  id: id,
  rideId: 'ride-1',
  deviceId: 'device-a',
  type: type,
  priority: EventPriority.routine,
  createdAt: DateTime.utc(2026, 7, 16, 10, minute),
  payload: payload,
  signature: 'test',
);
