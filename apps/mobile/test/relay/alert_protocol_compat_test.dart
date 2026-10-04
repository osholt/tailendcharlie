import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/situational_awareness_controller.dart';
import 'package:ride_relay/data/in_memory_event_store.dart';
import 'package:ride_relay/domain/geo_point.dart';
import 'package:ride_relay/domain/hazard.dart';
import 'package:ride_relay/domain/ride_alert_record.dart';
import 'package:ride_relay/domain/ride_event.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/ride_session.dart';
import 'package:ride_relay/features/map/hazard_map_symbol.dart';
import 'package:ride_relay/relay/relay_event_compatibility.dart';
import 'package:ride_relay/services/enforcement_alert_detector.dart';
import 'package:ride_relay/services/ride_alert_log.dart';
import 'package:ride_relay/services/ride_event_authenticator.dart';
import 'package:ride_relay/services/situation_event_factory.dart';

/// #849 changed what a rider's alert is, while build 1.0.1+101 is in testers'
/// hands and a group ride will mix the two for as long as they take to update.
/// Both directions have to degrade safely: an older phone must never crash or
/// lose its ride on a newer phone's alert, and a newer phone must still warn
/// about, and log, what an older phone raised.
///
/// The older build is represented by [_Build101], a frozen restatement of how
/// 1.0.1+101 decodes and presents a hazard. It is deliberately **not** the code
/// under test: the point of the test is that the new wire format still satisfies
/// the old decoder, and a decoder that moved with the code could never fail.
void main() {
  const secret = 'shared-secret';
  final raised = DateTime.utc(2026, 10, 4, 13, 32, 7);
  const here = GeoPoint(latitude: 54.1500, longitude: -4.4800);

  final session = RideSession(
    rideId: 'ride-1',
    rideCode: 'ABC123',
    inviteSecret: secret,
    joinToken: 'test-join-token-0123456789',
    localRiderId: 'nigel',
    displayName: 'Nigel',
    role: RideRole.rider,
    joinedAt: DateTime.utc(2026, 10, 4, 9),
  );

  /// What the app puts on the relay: the event, as JSON text, and back.
  Map<String, Object?> overTheWire(RideEvent event) =>
      Map<String, Object?>.from(jsonDecode(jsonEncode(event.toJson())) as Map);

  Future<RideEvent> raiseAlert() async {
    final store = InMemoryEventStore();
    var next = 0;
    final controller = SituationalAwarenessController(
      store,
      session,
      route: const [],
      clock: () => raised,
      idFactory: () => 'alert-${next++}',
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.reportAlert(position: here);
    return (await store.eventsForRide(session.rideId)).single;
  }

  group('build 102 alert, read by build 101', () {
    test(
      'travels as an event type every build and the relay already carry',
      () async {
        final event = await raiseAlert();
        final wire = overTheWire(event);

        expect(event.type, RideEventType.hazardReported);
        expect(_Build101.eventTypes, contains(wire['type']));
        // Not skipped as "from a newer build": 101 would not have a name for the
        // limitation, and would lose the alert.
        expect(describeUnsupportedRelayEvent(wire), isNull);
        // And the envelope is strictly the one 101 decodes.
        expect(RideEvent.fromJson(wire).id, event.id);
        expect(
          RideEventAuthenticator.verify(RideEvent.fromJson(wire), secret),
          isTrue,
        );
      },
    );

    test('decodes in 101 without throwing, as an ordinary hazard', () async {
      final wire = overTheWire(await raiseAlert());
      final payload = wire['payload']! as Map;

      final decoded = _Build101.decodeHazard(
        Map<String, Object?>.from(payload['hazard']! as Map),
      );

      // `other`, the one name every build knows that means "something to look
      // out for". 101 would show it as an "Other hazard" at the right place and
      // would raise no enforcement warning, which is the honest degradation: it
      // does not know what this is.
      expect(decoded.type, 'other');
      expect(decoded.severity, 'serious');
      expect(decoded.position, here);
      expect(decoded.reporterName, 'Nigel');
      expect(decoded.reportedAt, raised);
      expect(_Build101.raisesEnforcementWarning(decoded.type), isFalse);
      expect(_Build101.mapGlyph(decoded.type), 'roadDefect');
    });

    test('101 replays it on every restart without breaking the ride', () async {
      // The journal replays every hazard through the decoder each time the ride
      // opens. One name 101 does not know would throw there, and the ride would
      // not open on that phone. So the whole journal is decoded, as 101 does.
      final journal = [overTheWire(await raiseAlert())];

      for (final wire in journal) {
        final hazard = (wire['payload']! as Map)['hazard']! as Map;
        expect(
          () => _Build101.decodeHazard(Map<String, Object?>.from(hazard)),
          returnsNormally,
        );
      }
    });

    test('adds exactly one key to a hazard, which 101 ignores', () async {
      final wire = overTheWire(await raiseAlert());
      final hazard = Map<String, Object?>.from(
        (wire['payload']! as Map)['hazard']! as Map,
      );

      expect(hazard.keys.toSet().difference(_Build101.hazardKeys), {
        HazardReportWire.kindKey,
      });
      expect(hazard[HazardReportWire.kindKey], 'alert');
      // And the rest of the shape is untouched, so 101 reads every field it uses.
      expect(_Build101.hazardKeys.difference(hazard.keys.toSet()), isEmpty);
    });

    test('no hazard kind writes a name 101 cannot decode', () {
      // The guard for the next person to add a kind. A new HazardType must say
      // how it travels, or an older build stops opening rides.
      for (final type in HazardType.values) {
        final wireType = HazardReport(
          id: 'h',
          rideId: 'ride-1',
          type: type,
          severity: HazardSeverity.serious,
          position: here,
          reportedAt: raised,
          updatedAt: raised,
          expiresAt: raised.add(const Duration(hours: 1)),
          reporterId: 'nigel',
          source: HazardSource.rider,
        ).toJson()['type'];

        expect(
          _Build101.hazardTypeNames,
          contains(wireType),
          reason: type.name,
        );
      }
    });

    test('a hazard that is not an alert is written exactly as before', () {
      // Nothing changes shape for the kinds that were already there.
      final json = HazardReport(
        id: 'h',
        rideId: 'ride-1',
        type: HazardType.pothole,
        severity: HazardSeverity.caution,
        position: here,
        reportedAt: raised,
        updatedAt: raised,
        expiresAt: raised.add(const Duration(hours: 12)),
        reporterId: 'nigel',
        source: HazardSource.rider,
      ).toJson();

      expect(json.keys.toSet(), _Build101.hazardKeys);
      expect(json['type'], 'pothole');
    });
  });

  group('build 101 alert, read by build 102', () {
    /// A police report exactly as 1.0.1+101 wrote it. Frozen JSON, not built from
    /// the current model, because it is the model that changed.
    Map<String, Object?> build101Hazard(String type, {String id = 'h-1'}) => {
      'id': id,
      'rideId': 'ride-1',
      'type': type,
      'severity': 'serious',
      'position': {'latitude': 54.15, 'longitude': -4.48},
      'reportedAt': '2026-10-04T13:32:07.000Z',
      'updatedAt': '2026-10-04T13:32:07.000Z',
      'expiresAt': '2026-10-04T14:32:07.000Z',
      'reporterId': 'becks',
      'reporterName': 'Becks',
      'source': 'rider',
      'providerId': null,
      'details': null,
      'confirmations': 1,
    };

    RideEvent build101Event(String type, {String id = 'h-1'}) =>
        SituationEventFactory(
          session: session,
          clock: () => raised,
          idFactory: () => 'event-$id',
        ).create(
          type: RideEventType.hazardReported,
          payload: {'hazard': build101Hazard(type, id: id)},
          priority: EventPriority.important,
          expiresAt: raised.add(const Duration(hours: 1)),
        );

    test('a police and a camera report still decode, as their own kinds', () {
      expect(
        HazardReport.fromJson(build101Hazard('policeActivity')).type,
        HazardType.policeActivity,
      );
      expect(
        HazardReport.fromJson(build101Hazard('speedCamera')).type,
        HazardType.speedCamera,
      );
    });

    test('are still warned about, exactly as an alert is', () {
      const detector = EnforcementAlertDetector();
      for (final type in ['policeActivity', 'speedCamera']) {
        final hazard = HazardReport.fromJson(build101Hazard(type));
        final warning = detector.detect(
          position: GeoPoint(
            latitude: here.latitude - 300 / 111320,
            longitude: here.longitude,
          ),
          headingDegrees: 0,
          speedMetersPerSecond: 13.4,
          hazards: [hazard],
          now: raised,
        );

        expect(warning, isNotNull, reason: type);
      }
    });

    test('arrive on a build 102 phone as active alerts', () async {
      final store = InMemoryEventStore();
      final controller = SituationalAwarenessController(
        store,
        session,
        route: const [],
        clock: () => raised,
        idFactory: () => 'unused',
      );
      addTearDown(controller.dispose);
      await controller.initialize();

      await controller.ingestRemoteEvent(
        build101Event('policeActivity', id: 'p'),
      );
      await controller.ingestRemoteEvent(build101Event('speedCamera', id: 'c'));

      expect(controller.activeHazards.map((hazard) => hazard.type).toSet(), {
        HazardType.policeActivity,
        HazardType.speedCamera,
      });
    });

    test('still draw as the symbols they always had', () {
      expect(
        HazardMapSymbols.glyphFor(HazardType.policeActivity),
        HazardMapGlyph.police,
      );
      expect(
        HazardMapSymbols.glyphFor(HazardType.speedCamera),
        HazardMapGlyph.camera,
      );
    });

    test(
      'are logged as alerts, beside a build 102 alert, in one ride',
      () async {
        final newer = await raiseAlert();
        final records = const RideAlertLogReducer().fromEvents(
          rideId: 'ride-1',
          inviteSecret: secret,
          events: [
            build101Event('policeActivity', id: 'p'),
            newer,
            build101Event('speedCamera', id: 'c'),
          ],
          localRiderId: 'nigel',
        );

        expect(records.map((record) => record.kind).toSet(), {
          RideAlertKind.police,
          RideAlertKind.speedCamera,
          RideAlertKind.alert,
        });
        expect(records, hasLength(3));
      },
    );
  });

  group('forwards', () {
    test(
      'the alert marker wins over whatever legacy-safe type a later build chose',
      () {
        // A later build may pick `policeActivity` as its wire type, to give older
        // phones a warning; this build must still read it as the alert it is.
        final hazard = HazardReport.fromJson({
          'id': 'h',
          'rideId': 'ride-1',
          'type': 'policeActivity',
          'kind': 'alert',
          'severity': 'serious',
          'position': {'latitude': 54.15, 'longitude': -4.48},
          'reportedAt': '2026-10-04T13:32:07.000Z',
          'updatedAt': '2026-10-04T13:32:07.000Z',
          'expiresAt': '2026-10-04T14:32:07.000Z',
          'reporterId': 'becks',
          'source': 'rider',
        });

        expect(hazard.type, HazardType.alert);
      },
    );

    test('round trips', () {
      final alert = HazardReport(
        id: 'h',
        rideId: 'ride-1',
        type: HazardType.alert,
        severity: HazardSeverity.serious,
        position: here,
        reportedAt: raised,
        updatedAt: raised,
        expiresAt: raised.add(const Duration(hours: 1)),
        reporterId: 'nigel',
        reporterName: 'Nigel',
        source: HazardSource.rider,
      );

      final back = HazardReport.fromJson(
        Map<String, Object?>.from(
          jsonDecode(jsonEncode(alert.toJson())) as Map,
        ),
      );

      expect(back.type, HazardType.alert);
      expect(back.id, alert.id);
      expect(back.reportedAt.isAtSameMomentAs(raised), isTrue);
      expect(back.position, here);
    });
  });
}

/// Build 1.0.1+101's reading of a hazard, restated by hand.
///
/// Every line is something 101 does, and none of it is shared with the current
/// code: that is what makes it a fair stand-in for a phone that has not updated.
abstract final class _Build101 {
  /// Its `HazardType`, by name, as of that build. It has no `alert`.
  static const hazardTypeNames = {
    'pothole',
    'looseSurface',
    'debris',
    'roadworks',
    'collision',
    'stoppedVehicle',
    'flooding',
    'animals',
    'policeActivity',
    'speedCamera',
    'other',
  };

  /// The keys its `HazardReport.toJson` writes, and so the ones it reads.
  static const hazardKeys = {
    'id',
    'rideId',
    'type',
    'severity',
    'position',
    'reportedAt',
    'updatedAt',
    'expiresAt',
    'reporterId',
    'reporterName',
    'source',
    'providerId',
    'details',
    'confirmations',
  };

  /// Its `RideEventType`, by name. A later build's names are skipped by it; these
  /// are the ones it understands.
  static const eventTypes = {
    'rideCreated',
    'riderJoined',
    'riderLeft',
    'roleChanged',
    'rideStarted',
    'markerStarted',
    'markerPass',
    'markerEnded',
    'statusMessage',
    'riderLocationUpdated',
    'hazardReported',
    'hazardCleared',
    'routeDeviationChanged',
    'routeAlertAcknowledged',
    'routeRevisionChunk',
    'routeRevisionPublished',
    'routeCleared',
    'ridePaused',
    'rideResumed',
    'rideEnded',
    'iceInfoShared',
    'iceInfoViewed',
    'tecRoleRequested',
    'tecRoleResponded',
    'rejoinRouteShared',
    'riderContactShared',
    'rideReopened',
  };

  static const severityNames = {'advisory', 'caution', 'serious', 'critical'};

  /// `HazardReport.fromJson` as 101 had it: `HazardType.values.byName`, which
  /// throws an [ArgumentError] on a name it does not know.
  static ({
    String type,
    String severity,
    GeoPoint position,
    String? reporterName,
    DateTime reportedAt,
  })
  decodeHazard(Map<String, Object?> json) {
    final type = json['type']! as String;
    if (!hazardTypeNames.contains(type)) {
      throw ArgumentError.value(type, 'name', 'No enum value with that name');
    }
    final severity = json['severity']! as String;
    if (!severityNames.contains(severity)) {
      throw ArgumentError.value(
        severity,
        'name',
        'No enum value with that name',
      );
    }
    final position = Map<String, Object?>.from(json['position']! as Map);
    return (
      type: type,
      severity: severity,
      position: GeoPoint(
        latitude: (position['latitude']! as num).toDouble(),
        longitude: (position['longitude']! as num).toDouble(),
      ),
      reporterName: json['reporterName'] as String?,
      reportedAt: DateTime.parse(json['reportedAt']! as String).toUtc(),
    );
  }

  /// Which hazards 101 raised its full warning for: the two enforcement kinds.
  static bool raisesEnforcementWarning(String type) =>
      type == 'speedCamera' || type == 'policeActivity';

  static String mapGlyph(String type) => switch (type) {
    'speedCamera' => 'camera',
    'policeActivity' => 'police',
    _ => 'roadDefect',
  };
}
