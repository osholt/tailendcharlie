import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/geo_point.dart';
import 'package:ride_relay/domain/hazard.dart';
import 'package:ride_relay/domain/ride_alert_record.dart';
import 'package:ride_relay/domain/ride_event.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/ride_session.dart';
import 'package:ride_relay/services/gpx_exporter.dart';
import 'package:ride_relay/services/ride_alert_log.dart';
import 'package:ride_relay/services/situation_event_factory.dart';

/// #849: the log the ride review lists, plots, copies and exports. It is a
/// reduction of the journal, so every rule here is a rule about which events
/// count and what they say - and the one that matters most is that an alert
/// raised by an older build still counts.
void main() {
  const reducer = RideAlertLogReducer();
  const secret = 'shared-secret';
  // Isle of Man: nowhere near any rider's home.
  const here = GeoPoint(latitude: 54.1500, longitude: -4.4800);
  final raised = DateTime.utc(2026, 10, 4, 13, 32, 7);

  RideSession sessionFor(String riderId, String name, {String? ride}) =>
      RideSession(
        rideId: ride ?? 'ride-1',
        rideCode: 'ABC123',
        inviteSecret: secret,
        joinToken: 'test-join-token-0123456789',
        localRiderId: riderId,
        displayName: name,
        role: RideRole.rider,
        joinedAt: DateTime.utc(2026, 10, 4, 9),
      );

  final oliver = sessionFor('oliver', 'Oliver');
  final nigel = sessionFor('nigel', 'Nigel');

  HazardReport hazard({
    required String id,
    required HazardType type,
    required RideSession by,
    DateTime? at,
    GeoPoint position = here,
    HazardSource source = HazardSource.rider,
    String? providerId,
    String? name,
  }) => HazardReport(
    id: id,
    rideId: by.rideId,
    type: type,
    severity: HazardSeverity.serious,
    position: position,
    reportedAt: at ?? raised,
    updatedAt: at ?? raised,
    expiresAt: (at ?? raised).add(const Duration(hours: 1)),
    reporterId: by.localRiderId,
    reporterName: name ?? by.displayName,
    source: source,
    providerId: providerId,
  );

  RideEvent eventFor(
    HazardReport report, {
    required RideSession by,
    String? eventId,
    DateTime? createdAt,
  }) =>
      SituationEventFactory(
        session: by,
        clock: () => createdAt ?? report.updatedAt,
        idFactory: () => eventId ?? 'event-${report.id}',
      ).create(
        type: RideEventType.hazardReported,
        payload: {'hazard': report.toJson()},
        priority: EventPriority.important,
        expiresAt: report.expiresAt,
      );

  List<RideAlertRecord> read(
    Iterable<RideEvent> events, {
    String localRiderId = 'oliver',
    Map<String, String> displayNames = const {},
  }) => reducer.fromEvents(
    rideId: 'ride-1',
    inviteSecret: secret,
    events: events,
    localRiderId: localRiderId,
    displayNames: displayNames,
  );

  group('what is an alert', () {
    test('a one-tap alert, with its time, place and who raised it', () {
      final records = read([
        eventFor(
          hazard(id: 'a1', type: HazardType.alert, by: nigel),
          by: nigel,
        ),
      ]);

      expect(records, hasLength(1));
      final record = records.single;
      expect(record.id, 'a1');
      expect(record.kind, RideAlertKind.alert);
      expect(record.raisedAt, raised);
      expect(record.position, here);
      expect(record.raisedBy, 'Nigel');
      expect(record.raisedByLocalRider, isFalse);
    });

    test('a rider\'s own alert is marked as theirs', () {
      final records = read([
        eventFor(
          hazard(id: 'mine', type: HazardType.alert, by: oliver),
          by: oliver,
        ),
      ]);

      expect(records.single.raisedByLocalRider, isTrue);
    });

    test(
      'a speed camera or police report from an older build is an alert too',
      () {
        // Build 101 raised these. A ride shared between old and new phones has
        // both, and an older rider's alert must not vanish from a newer rider's
        // review.
        final records = read([
          eventFor(
            hazard(id: 'cam', type: HazardType.speedCamera, by: nigel),
            by: nigel,
          ),
          eventFor(
            hazard(
              id: 'pol',
              type: HazardType.policeActivity,
              by: nigel,
              at: raised.add(const Duration(minutes: 1)),
            ),
            by: nigel,
          ),
        ]);

        expect(records.map((record) => record.kind), [
          RideAlertKind.speedCamera,
          RideAlertKind.police,
        ]);
        expect(records.map((record) => record.kind.label), [
          'Alert · speed camera',
          'Alert · police',
        ]);
      },
    );

    test('a hazard from a data provider is not an alert', () {
      // Nobody in the ride raised it: it is the bundled fixed-camera layer, or
      // live traffic.
      final records = read([
        eventFor(
          hazard(
            id: 'osm',
            type: HazardType.speedCamera,
            by: oliver,
            source: HazardSource.externalProvider,
            providerId: osmFixedCameraProviderId,
          ),
          by: oliver,
        ),
      ]);

      expect(records, isEmpty);
    });

    test('a road defect is not an alert, and neither is a plain other', () {
      // `other` is what an alert looks like to an older build, and what an older
      // build's own "road hazard" is. Without the `kind` marker it is a hazard.
      final records = read([
        for (final type in [
          HazardType.pothole,
          HazardType.debris,
          HazardType.roadworks,
          HazardType.other,
        ])
          eventFor(
            hazard(id: type.name, type: type, by: nigel),
            by: nigel,
          ),
      ]);

      expect(records, isEmpty);
    });
  });

  group('one entry per alert', () {
    test('a re-sent event is one alert', () {
      final report = hazard(id: 'a1', type: HazardType.alert, by: nigel);
      final records = read([
        eventFor(report, by: nigel, eventId: 'first'),
        eventFor(report, by: nigel, eventId: 'second'),
      ]);

      expect(records, hasLength(1));
    });

    test('a confirmation of an older build\'s sighting is the same entry', () {
      // Build 101 merged a second report within 75 m and 30 minutes into the
      // first, re-issuing the event with a later update time and the confirming
      // rider's device id. The alert is still one, and it was raised at the
      // first report's time.
      final original = hazard(
        id: 'cam',
        type: HazardType.speedCamera,
        by: nigel,
      );
      final confirmed = original.copyWith(
        updatedAt: raised.add(const Duration(minutes: 4)),
        confirmations: 2,
      );
      final records = read([
        eventFor(original, by: nigel),
        eventFor(confirmed, by: oliver, eventId: 'confirmation'),
      ]);

      expect(records, hasLength(1));
      expect(records.single.raisedAt, raised);
      expect(records.single.raisedBy, 'Nigel');
    });

    test('two alerts at the same place stay two', () {
      final records = read([
        eventFor(
          hazard(id: 'a1', type: HazardType.alert, by: nigel),
          by: nigel,
        ),
        eventFor(
          hazard(
            id: 'a2',
            type: HazardType.alert,
            by: oliver,
            at: raised.add(const Duration(seconds: 40)),
          ),
          by: oliver,
        ),
      ]);

      expect(records.map((record) => record.id), ['a1', 'a2']);
    });

    test('are listed oldest first whatever order the journal held them in', () {
      final records = read([
        eventFor(
          hazard(
            id: 'late',
            type: HazardType.alert,
            by: nigel,
            at: raised.add(const Duration(minutes: 20)),
          ),
          by: nigel,
        ),
        eventFor(
          hazard(
            id: 'early',
            type: HazardType.alert,
            by: nigel,
            at: raised.subtract(const Duration(minutes: 20)),
          ),
          by: nigel,
        ),
        eventFor(
          hazard(id: 'middle', type: HazardType.alert, by: nigel),
          by: nigel,
        ),
      ]);

      expect(records.map((record) => record.id), ['early', 'middle', 'late']);
    });

    test('an alert stays in the log long after it has expired', () {
      // The live warning drops an alert after an hour. The log's whole use is
      // afterwards.
      final records = read([
        eventFor(
          hazard(
            id: 'old',
            type: HazardType.alert,
            by: nigel,
            at: raised.subtract(const Duration(hours: 5)),
          ),
          by: nigel,
        ),
      ]);

      expect(records, hasLength(1));
    });
  });

  group('what is refused', () {
    test('an event signed with another ride\'s secret', () {
      final foreign = RideSession(
        rideId: 'ride-1',
        rideCode: 'ABC123',
        inviteSecret: 'somebody-elses-secret',
        joinToken: 'test-join-token-0123456789',
        localRiderId: 'nigel',
        displayName: 'Nigel',
        role: RideRole.rider,
        joinedAt: raised,
      );

      final records = read([
        eventFor(
          hazard(id: 'forged', type: HazardType.alert, by: foreign),
          by: foreign,
        ),
      ]);

      expect(records, isEmpty);
    });

    test('a tampered event', () {
      final real = eventFor(
        hazard(id: 'a1', type: HazardType.alert, by: nigel),
        by: nigel,
      );
      final tampered = RideEvent(
        id: real.id,
        rideId: real.rideId,
        deviceId: real.deviceId,
        type: real.type,
        priority: real.priority,
        createdAt: real.createdAt,
        expiresAt: real.expiresAt,
        payload: {
          'hazard': {
            ...(real.payload['hazard']! as Map<String, Object?>),
            'reporterName': 'Somebody else',
          },
        },
        signature: real.signature,
      );

      expect(read([tampered]), isEmpty);
    });

    test('an alert from another ride', () {
      final other = sessionFor('nigel', 'Nigel', ride: 'ride-2');

      final records = read([
        eventFor(
          hazard(id: 'elsewhere', type: HazardType.alert, by: other),
          by: other,
        ),
      ]);

      expect(records, isEmpty);
    });

    test('a malformed event is skipped and the rest of the log survives', () {
      RideEvent withPayload(Map<String, Object?> payload) =>
          SituationEventFactory(
            session: nigel,
            clock: () => raised,
            idFactory: () => 'bad-${payload.hashCode}',
          ).create(type: RideEventType.hazardReported, payload: payload);

      final good = eventFor(
        hazard(id: 'good', type: HazardType.alert, by: nigel),
        by: nigel,
      );
      final goodJson = (good.payload['hazard']! as Map).cast<String, Object?>();
      final records = read([
        withPayload({}),
        withPayload({'hazard': 'not an object'}),
        // An unknown type name with no alert marker beside it: the one case the
        // hazard decoder genuinely cannot place.
        withPayload({
          'hazard': {...goodJson, 'id': 'no-type', 'type': 'madeUp'}
            ..remove('kind'),
        }),
        withPayload({
          'hazard': {
            ...goodJson,
            'id': 'off-the-globe',
            'position': {'latitude': 123.0, 'longitude': 0.0},
          },
        }),
        withPayload({
          'hazard': {...goodJson, 'id': 'no-time', 'reportedAt': 'yesterday'},
        }),
        good,
      ]);

      expect(records.map((record) => record.id), ['good']);
    });
  });

  group('who raised it', () {
    test('falls back to the roster when the event carries no name', () {
      final records = read(
        [
          eventFor(
            HazardReport(
              id: 'a1',
              rideId: 'ride-1',
              type: HazardType.alert,
              severity: HazardSeverity.serious,
              position: here,
              reportedAt: raised,
              updatedAt: raised,
              expiresAt: raised.add(const Duration(hours: 1)),
              reporterId: 'nigel',
              source: HazardSource.rider,
            ),
            by: nigel,
          ),
        ],
        displayNames: const {'nigel': 'Nigel B'},
      );

      expect(records.single.raisedBy, 'Nigel B');
    });

    test('says "A rider" when nobody can say', () {
      final records = read([
        eventFor(
          HazardReport(
            id: 'a1',
            rideId: 'ride-1',
            type: HazardType.alert,
            severity: HazardSeverity.serious,
            position: here,
            reportedAt: raised,
            updatedAt: raised,
            expiresAt: raised.add(const Duration(hours: 1)),
            reporterId: 'nigel',
            source: HazardSource.rider,
          ),
          by: nigel,
        ),
      ]);

      expect(records.single.raisedBy, 'A rider');
    });

    test('a name is bounded, whatever another device sent', () {
      final records = read([
        eventFor(
          hazard(id: 'a1', type: HazardType.alert, by: nigel, name: 'N' * 500),
          by: nigel,
        ),
      ]);

      expect(
        records.single.raisedBy.length,
        RideAlertLogReducer.maximumNameLength,
      );
    });
  });

  group('how it reads', () {
    // Built from local components so the expectation does not depend on the
    // machine's time zone: whatever zone this runs in, 14:32:07 here is 14:32:07
    // in the label.
    final local = RideAlertRecord(
      id: 'a1',
      raisedAt: DateTime(2026, 10, 4, 14, 32, 7).toUtc(),
      position: here,
      raisedBy: 'Nigel',
    );

    test('the time is to the second, and the date is the footage\'s', () {
      expect(local.clockLabel, '14:32:07');
      expect(local.timestampLabel, '2026-10-04 14:32:07');
    });

    test('single digits are padded', () {
      final early = RideAlertRecord(
        id: 'a2',
        raisedAt: DateTime(2026, 1, 2, 3, 4, 5).toUtc(),
        position: here,
        raisedBy: 'Nigel',
      );

      expect(early.clockLabel, '03:04:05');
      expect(early.timestampLabel, '2026-01-02 03:04:05');
    });

    test('UTC is available for a ride reviewed in another time zone', () {
      final utc = RideAlertRecord(
        id: 'a3',
        raisedAt: raised,
        position: here,
        raisedBy: 'Nigel',
      );

      expect(utc.utcLabel, '2026-10-04 13:32:07 UTC');
    });

    test('the position is five decimal places', () {
      expect(local.positionLabel, '54.15000, -4.48000');
    });

    test('a whole log copies as one line each, oldest first', () {
      final second = RideAlertRecord(
        id: 'a2',
        raisedAt: DateTime(2026, 10, 4, 15, 1, 2).toUtc(),
        position: const GeoPoint(latitude: 54.2, longitude: -4.5),
        raisedBy: 'Becks',
      );

      final lines = rideAlertLogText([local, second]).split('\n');

      expect(lines, hasLength(2));
      expect(lines.first, startsWith('2026-10-04 14:32:07 ('));
      expect(lines.first, contains('Nigel'));
      expect(lines.first, endsWith('54.15000, -4.48000'));
      expect(lines.last, startsWith('2026-10-04 15:01:02 ('));
    });

    test('the zone is named so the times can be placed against footage', () {
      final label = rideAlertTimeZoneLabel(raised);

      expect(label, contains('UTC'));
    });
  });

  group('as GPX waypoints', () {
    test('carry the time in UTC, the clock time in the name, and who', () {
      final record = RideAlertRecord(
        id: 'a1',
        raisedAt: raised,
        position: here,
        raisedBy: 'Nigel',
      );

      final waypoints = rideAlertGpxWaypoints([record]);

      expect(waypoints, hasLength(1));
      final waypoint = waypoints.single;
      expect(waypoint.point.latitude, here.latitude);
      expect(waypoint.point.longitude, here.longitude);
      expect(waypoint.point.recordedAt, raised);
      expect(waypoint.name, 'Alert ${record.clockLabel}');
      expect(waypoint.description, contains('Nigel'));
      expect(waypoint.description, contains(record.timestampLabel));
      expect(waypoint.description, contains('2026-10-04 13:32:07 UTC'));
      expect(waypoint, isA<GpxAlertWaypoint>());
    });

    test('an older build\'s alert says what it was', () {
      final record = RideAlertRecord(
        id: 'a1',
        raisedAt: raised,
        position: here,
        raisedBy: 'Becks',
        kind: RideAlertKind.police,
      );

      expect(
        rideAlertGpxWaypoints([record]).single.description,
        contains('Alert · police'),
      );
    });
  });
}
