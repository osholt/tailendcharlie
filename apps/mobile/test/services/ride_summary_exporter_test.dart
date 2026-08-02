import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/geo_point.dart';
import 'package:ride_relay/domain/ride_event.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/ride_session.dart';
import 'package:ride_relay/domain/rider_location.dart';
import 'package:ride_relay/services/ride_event_authenticator.dart';
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

  test('breaks and excludes distance across a missing location interval', () {
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
        minute: 1,
        latitude: 53,
        longitude: -1,
      ),
      _locationEvent(
        '2',
        deviceId: 'device-a',
        riderId: 'device-a',
        minute: 2,
        latitude: 53.001,
        longitude: -1,
      ),
      _locationEvent(
        '3',
        deviceId: 'device-a',
        riderId: 'device-a',
        minute: 22,
        latitude: 54,
        longitude: -2,
      ),
      _locationEvent(
        '4',
        deviceId: 'device-a',
        riderId: 'device-a',
        minute: 23,
        latitude: 54.001,
        longitude: -2,
      ),
    ];
    const exporter = RideSummaryExporter();

    final summary = exporter.summarize(
      session,
      events,
      generatedAt: DateTime.utc(2026, 7, 16, 10, 25),
    );
    final route = exporter.traveledRoute(
      session,
      events,
      generatedAt: DateTime.utc(2026, 7, 16, 10, 25),
    );

    expect(route, isNotNull);
    expect(route!.paths, hasLength(2));
    expect(route.paths.map((path) => path.points.length), const [2, 2]);
    expect(
      summary.totalDistanceMeters,
      closeTo(222, 5),
      reason: 'the unknown cross-country section must not count as travel',
    );
  });

  test('duration and traveled trace begin at the authoritative start', () {
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
      _signedEvent(
        _event(
          'created',
          RideEventType.rideCreated,
          10,
          payload: const {'displayName': 'Oliver', 'role': 'lead'},
        ),
        session.inviteSecret,
      ),
      _locationEvent(
        'early',
        deviceId: 'device-a',
        riderId: 'device-a',
        minute: 11,
        latitude: 52,
        longitude: -1,
      ),
      _signedEvent(
        _event(
          'started',
          RideEventType.rideStarted,
          12,
          payload: const {'leaderRiderId': 'device-a'},
        ),
        session.inviteSecret,
      ),
      _locationEvent(
        'after-1',
        deviceId: 'device-a',
        riderId: 'device-a',
        minute: 13,
        latitude: 53,
        longitude: -1,
      ),
      _locationEvent(
        'after-2',
        deviceId: 'device-a',
        riderId: 'device-a',
        minute: 14,
        latitude: 53.01,
        longitude: -1,
      ),
    ];
    const exporter = RideSummaryExporter();

    final summary = exporter.summarize(
      session,
      events,
      generatedAt: DateTime.utc(2026, 7, 16, 10, 22),
    );
    final route = exporter.traveledRoute(
      session,
      events,
      generatedAt: DateTime.utc(2026, 7, 16, 10, 22),
    );

    expect(summary.startedAt, DateTime.utc(2026, 7, 16, 10, 12));
    expect(summary.rideDuration, const Duration(minutes: 10));
    expect(summary.totalDistanceMeters, closeTo(1111.95, 1));
    expect(route!.paths.single.points, hasLength(2));
    expect(route.paths.single.points.first.latitude, 53);
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

  // The decisive experiment for #299: "in single rider mode it forgets your
  // track after a while and then doesn't save the ride properly when you end
  // it." A recap shared the same day proved a 20-minute group ride saves fine,
  // and location events carry a 30-minute expiry, so the question is whether a
  // ride longer than that keeps its whole track through the save.
  //
  // Run here rather than on a bike: the saved track is derived purely from the
  // event log, so a 90-minute ride can be constructed exactly.
  group('a long solo ride with no route', () {
    const exporter = RideSummaryExporter();
    final session = RideSession(
      rideId: 'ride-1',
      rideCode: 'ABC123',
      inviteSecret: 'secret',
      joinToken: 'test-join-token-0123456789',
      localRiderId: 'device-a',
      displayName: 'Oliver',
      // Solo: the rider creates the ride, so they lead it.
      role: RideRole.lead,
      joinedAt: DateTime.utc(2026, 7, 16, 9, 55),
    );

    /// Ninety minutes of riding, one fix a minute, and no route anywhere.
    List<RideEvent> ninetyMinutesOfRiding() => [
      _event('created', RideEventType.rideCreated, 0),
      _event('started', RideEventType.rideStarted, 1),
      for (var minute = 1; minute <= 90; minute += 1)
        _locationEvent(
          'fix-$minute',
          deviceId: 'device-a',
          riderId: 'device-a',
          minute: minute,
          latitude: 51.45 + minute * 0.001,
          longitude: -2.47 + minute * 0.001,
        ),
      _event('ended', RideEventType.rideEnded, 91),
    ];

    test('the whole track survives, not just the last 30 minutes', () {
      final track = exporter.traveledRoute(
        session,
        ninetyMinutesOfRiding(),
        generatedAt: DateTime.utc(2026, 7, 16, 11, 31),
      );

      expect(track, isNotNull, reason: 'a 90-minute ride must save a track');
      final points = track!.paths.expand((path) => path.points).toList();
      expect(
        points.length,
        90,
        reason:
            'every recorded fix belongs in the saved ride; anything near 30 '
            'would mean the 30-minute event expiry reaches the saved track',
      );
      // The earliest fix is still the first minute, not a rolling window.
      // Compared in UTC because the exporter converts to local time, and a test
      // that only passes in one timezone is worse than no test.
      expect(
        points.first.recordedAt?.toUtc(),
        DateTime.utc(2026, 7, 16, 10, 1),
      );
      expect(
        points.last.recordedAt?.toUtc(),
        DateTime.utc(2026, 7, 16, 11, 30),
      );
    });

    test('the summary reports the full duration and a distance', () {
      final summary = exporter.summarize(
        session,
        ninetyMinutesOfRiding(),
        generatedAt: DateTime.utc(2026, 7, 16, 11, 31),
      );

      expect(summary.startedAt, isNotNull);
      expect(summary.endedAt, isNotNull);
      expect(
        summary.endedAt!.difference(summary.startedAt!).inMinutes,
        greaterThanOrEqualTo(89),
      );
      expect(summary.totalDistanceMeters, greaterThan(0));
    });
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

RideEvent _signedEvent(RideEvent event, String secret) => RideEvent(
  id: event.id,
  rideId: event.rideId,
  deviceId: event.deviceId,
  type: event.type,
  priority: event.priority,
  createdAt: event.createdAt,
  payload: event.payload,
  signature: RideEventAuthenticator.sign(event, secret),
);
