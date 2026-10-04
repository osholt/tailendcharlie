import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/completed_ride.dart';
import 'package:ride_relay/domain/geo_point.dart' as awareness;
import 'package:ride_relay/domain/hazard.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/domain/ride_event.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/ride_session.dart';
import 'package:ride_relay/domain/rider_location.dart';
import 'package:ride_relay/services/completed_ride_archiver.dart';
import 'package:ride_relay/services/completed_ride_sharer.dart';
import 'package:ride_relay/services/gpx_exporter.dart';
import 'package:ride_relay/services/gpx_parser.dart';
import 'package:ride_relay/services/ride_alert_log.dart';
import 'package:ride_relay/services/ride_summary_exporter.dart';
import 'package:ride_relay/services/situation_event_factory.dart';
import 'package:xml/xml.dart';

/// #849: alerts leave the app in three ways - the ride-ended share, the previous
/// ride's GPX export, and the summary text a rider pastes into a note - and each
/// carries the same list. They must also never become something else on the way
/// back in: an alert in a GPX file is a warning, not a stop on a route.
void main() {
  const secret = 'shared-secret';
  // Isle of Man: nowhere near any rider's home.
  const here = awareness.GeoPoint(latitude: 54.1500, longitude: -4.4800);
  final raised = DateTime.utc(2026, 10, 4, 13, 32, 7);

  final session = RideSession(
    rideId: 'ride-1',
    rideCode: 'ABC123',
    inviteSecret: secret,
    joinToken: 'test-join-token-0123456789',
    localRiderId: 'oliver',
    displayName: 'Oliver',
    role: RideRole.lead,
    joinedAt: DateTime.utc(2026, 10, 4, 9),
  );

  RideEvent location(
    String id, {
    required double latitude,
    required int minute,
  }) {
    final at = DateTime.utc(2026, 10, 4, 13, minute);
    final rider = RiderLocation(
      riderId: 'oliver',
      displayName: 'Oliver',
      role: RideRole.lead,
      sample: LocationSample(
        position: awareness.GeoPoint(latitude: latitude, longitude: -4.48),
        recordedAt: at,
        accuracyMeters: 5,
      ),
      receivedAt: at,
    );
    return SituationEventFactory(
      session: session,
      clock: () => at,
      idFactory: () => id,
    ).create(
      type: RideEventType.riderLocationUpdated,
      payload: {'location': rider.toJson()},
    );
  }

  RideEvent alertEvent(
    String id, {
    required String by,
    required String name,
    required DateTime at,
    awareness.GeoPoint position = here,
  }) {
    final hazard = HazardReport(
      id: id,
      rideId: 'ride-1',
      type: HazardType.alert,
      severity: HazardSeverity.serious,
      position: position,
      reportedAt: at,
      updatedAt: at,
      expiresAt: at.add(const Duration(hours: 1)),
      reporterId: by,
      reporterName: name,
      source: HazardSource.rider,
    );
    return SituationEventFactory(
      session: session,
      clock: () => at,
      idFactory: () => 'event-$id',
    ).create(
      type: RideEventType.hazardReported,
      payload: {'hazard': hazard.toJson()},
      priority: EventPriority.important,
      expiresAt: hazard.expiresAt,
    );
  }

  final journal = [
    location('l1', latitude: 54.14, minute: 20),
    location('l2', latitude: 54.15, minute: 32),
    alertEvent('a1', by: 'nigel', name: 'Nigel', at: raised),
    location('l3', latitude: 54.16, minute: 40),
    alertEvent(
      'a2',
      by: 'oliver',
      name: 'Oliver',
      at: DateTime.utc(2026, 10, 4, 13, 41, 9),
      position: const awareness.GeoPoint(latitude: 54.161, longitude: -4.481),
    ),
  ];

  final generatedAt = DateTime.utc(2026, 10, 4, 14);

  RideSummary summary() => const RideSummaryExporter().summarize(
    session,
    journal,
    generatedAt: generatedAt,
  );

  group('the summary a rider shares at the end', () {
    test('lists every alert with its time, who raised it and where', () {
      final text = const RideSummaryExporter().toPlainText(summary());

      expect(text, contains('Alerts raised: 2'));
      final lines = text.split('\n');
      final alertLines = lines
          .where((line) => line.contains('Nigel') || line.contains('· Oliver'))
          .toList();
      expect(alertLines, hasLength(2));
      expect(alertLines.first, contains('54.15000, -4.48000'));
      expect(alertLines.first, contains('2026-10-04 13:32:07 UTC'));
      expect(alertLines.last, contains('54.16100, -4.48100'));
    });

    test('puts them in the CSV as rows a spreadsheet can sort', () {
      final csv = const RideSummaryExporter().toCsv(summary());

      expect(
        csv,
        contains(
          '"alert_time_local","alert_time_utc","raised_by","latitude","longitude"',
        ),
      );
      expect(
        csv,
        contains('"2026-10-04T13:32:07.000Z","Nigel","54.150000","-4.480000"'),
      );
      expect(csv, contains('"2026-10-04T13:41:09.000Z","Oliver"'));
    });

    test('says nothing about alerts when there were none', () {
      final quiet = const RideSummaryExporter().summarize(session, [
        location('l1', latitude: 54.14, minute: 20),
      ], generatedAt: generatedAt);

      expect(
        const RideSummaryExporter().toPlainText(quiet),
        isNot(contains('Alerts')),
      );
      expect(
        const RideSummaryExporter().toCsv(quiet),
        isNot(contains('alert_time')),
      );
    });

    test('carries them into the GPX as waypoints, with the trail', () {
      const exporter = RideSummaryExporter();
      final route = exporter.traveledRoute(
        session,
        journal,
        generatedAt: generatedAt,
      )!;

      final gpx = exporter.trailGpx(route, summary());

      final document = XmlDocument.parse(gpx);
      final waypoints = document.rootElement.findElements('wpt').toList();
      expect(waypoints, hasLength(2));
      expect(document.rootElement.findElements('trk'), isNotEmpty);
      // The first alert, written the way a footage tool or a Garmin reads it.
      final first = waypoints.first;
      expect(first.getAttribute('lat'), '54.1500000');
      expect(first.getAttribute('lon'), '-4.4800000');
      expect(first.getElement('time')!.innerText, '2026-10-04T13:32:07.000Z');
      expect(first.getElement('name')!.innerText, startsWith('Alert '));
      expect(first.getElement('desc')!.innerText, contains('Nigel'));
      expect(
        first.getElement('desc')!.innerText,
        contains('2026-10-04 13:32:07 UTC'),
      );
      expect(first.getElement('sym')!.innerText, 'Danger Area');
    });

    test('and the recorded route itself never gains a stop', () {
      const exporter = RideSummaryExporter();

      final route = exporter.traveledRoute(
        session,
        journal,
        generatedAt: generatedAt,
      )!;

      expect(route.waypoints, isEmpty);
    });
  });

  group('the archived ride', () {
    CompletedRide archived() => const CompletedRideArchiver().create(
      session: session,
      events: journal,
      archivedAt: generatedAt,
    );

    test('keeps the alerts of the whole group, oldest first', () {
      final ride = archived();

      expect(ride.alerts.map((alert) => alert.id), ['a1', 'a2']);
      expect(ride.alerts.map((alert) => alert.raisedBy), ['Nigel', 'Oliver']);
      expect(ride.alerts.first.raisedByLocalRider, isFalse);
      expect(ride.alerts.last.raisedByLocalRider, isTrue);
      expect(ride.alerts.first.raisedAt, raised);
      expect(ride.alerts.first.position, here);
    });

    test(
      'does not put them in the stored route, which is offered to ride again',
      () {
        final ride = archived();

        expect(ride.traveledRoute, isNotNull);
        expect(ride.traveledRoute!.waypoints, isEmpty);
      },
    );

    test('survives a round trip through the library\'s JSON', () {
      final restored = CompletedRide.fromJson(archived().toJson());

      expect(restored.alerts, archived().alerts);
    });

    test('exports them as waypoints in the previous ride\'s GPX', () {
      const sharer = SystemCompletedRideSharer();

      final gpx = sharer.gpxFor(archived());

      final waypoints = XmlDocument.parse(gpx).rootElement.findElements('wpt');
      expect(waypoints, hasLength(2));
      expect(
        waypoints.map((waypoint) => waypoint.getElement('time')!.innerText),
        ['2026-10-04T13:32:07.000Z', '2026-10-04T13:41:09.000Z'],
      );
    });

    test('a ride with no alerts exports the GPX it always did', () {
      const sharer = SystemCompletedRideSharer();
      final quiet = const CompletedRideArchiver().create(
        session: session,
        events: [
          location('l1', latitude: 54.14, minute: 20),
          location('l2', latitude: 54.15, minute: 32),
        ],
        archivedAt: generatedAt,
      );

      final gpx = sharer.gpxFor(quiet);

      expect(gpx, isNot(contains('<wpt')));
      expect(gpx, isNot(contains('xmlns:tec')));
    });

    test('the summary text for a previous ride lists them too', () {
      // `shareSummary` hands this to the share sheet; the text is what a rider
      // pastes into a note.
      final ride = archived();

      expect(rideAlertLogText(ride.alerts).split('\n'), hasLength(2));
    });
  });

  group('the GPX alert marker', () {
    final route = ImportedRoute(
      id: 'route',
      name: 'Day out',
      importedAt: generatedAt,
      sourceFileName: 'day.gpx',
      paths: [
        RoutePath(
          kind: RoutePathKind.track,
          points: [
            GeoPoint(
              latitude: 54.14,
              longitude: -4.48,
              recordedAt: raised.subtract(const Duration(minutes: 5)),
            ),
            GeoPoint(latitude: 54.16, longitude: -4.48, recordedAt: raised),
          ],
        ),
      ],
      waypoints: const [
        RouteWaypoint(
          point: GeoPoint(latitude: 54.17, longitude: -4.47),
          name: 'Fuel',
        ),
      ],
    );

    final alerts = [
      GpxAlertWaypoint(
        point: GeoPoint(latitude: 54.15, longitude: -4.48, recordedAt: raised),
        name: 'Alert 14:32:07',
        description:
            'Alert raised by Nigel & co at 2026-10-04 14:32:07 <local>',
      ),
    ];

    ImportedRoute reimport(String gpx) => const GpxParser().parse(
      Uint8List.fromList(utf8.encode(gpx)),
      routeId: 'again',
      sourceFileName: 'again.gpx',
      importedAt: generatedAt,
    );

    test('is valid GPX 1.1 in the order the schema asks for', () {
      final gpx = const GpxExporter().export(route, alerts: alerts);

      final waypoint = XmlDocument.parse(
        gpx,
      ).rootElement.findElements('wpt').last;
      expect(waypoint.childElements.map((element) => element.name.qualified), [
        'time',
        'name',
        'desc',
        'sym',
        'extensions',
      ]);
      expect(gpx, contains('xmlns:tec="$gpxTecNamespace"'));
      expect(gpx, contains('<tec:alert/>'));
    });

    test('escapes what a name can contain', () {
      final gpx = const GpxExporter().export(route, alerts: alerts);

      final description = XmlDocument.parse(
        gpx,
      ).rootElement.findElements('wpt').last.getElement('desc')!.innerText;
      expect(description, contains('Nigel & co'));
      expect(description, contains('<local>'));
    });

    test('is not read back as a stop when the file is imported as a route', () {
      // Every other <wpt> is a named waypoint on import. Without the marker the
      // next import of a ride's GPX would grow a stop at every alert.
      final reimported = reimport(
        const GpxExporter().export(route, alerts: alerts),
      );

      expect(reimported.waypoints.map((waypoint) => waypoint.name), ['Fuel']);
      expect(reimported.paths, hasLength(1));
    });

    test('leaves an ordinary waypoint alone, whatever else is in the file', () {
      final withoutAlerts = const GpxExporter().export(route);

      expect(
        reimport(withoutAlerts).waypoints.map((waypoint) => waypoint.name),
        ['Fuel'],
      );
    });

    test(
      'does not swallow another tool\'s waypoint that has an alert element of its own',
      () {
        const foreign = '''<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="Other" xmlns="http://www.topografix.com/GPX/1/1"
     xmlns:x="https://example.org/ns">
  <wpt lat="54.2" lon="-4.4">
    <name>Their waypoint</name>
    <extensions><x:alert/></extensions>
  </wpt>
</gpx>''';

        final imported = reimport(foreign);

        expect(imported.waypoints.single.name, 'Their waypoint');
      },
    );

    test('a GPX of nothing but alerts is not a route', () {
      final onlyAlerts = const GpxExporter().export(
        ImportedRoute(
          id: 'empty',
          name: 'Alerts',
          importedAt: generatedAt,
          sourceFileName: 'alerts.gpx',
          paths: const [],
          waypoints: const [],
        ),
        alerts: alerts,
      );

      expect(() => reimport(onlyAlerts), throwsA(isA<GpxFormatException>()));
    });

    test('adds nothing to a GPX that has no alerts', () {
      final gpx = const GpxExporter().export(route);

      expect(gpx, isNot(contains('xmlns:tec')));
      expect(gpx, isNot(contains('Danger Area')));
    });
  });
}
