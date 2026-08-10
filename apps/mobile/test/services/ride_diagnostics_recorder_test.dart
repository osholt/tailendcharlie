import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/geo_point.dart';
import 'package:ride_relay/services/ride_diagnostics_configuration.dart';
import 'package:ride_relay/services/ride_diagnostics_recorder.dart';

void main() {
  // A synthetic track, so the pairing that answers #412 can be driven without
  // riding. Points are generated from a start, a bearing and a distance, which is
  // how a rider approaching and leaving a junction actually looks to the recorder.
  GeoPoint move(GeoPoint from, double bearingDegrees, double meters) {
    const earthRadius = 6371000.0;
    final bearing = bearingDegrees * math.pi / 180;
    final latitude = from.latitude * math.pi / 180;
    final longitude = from.longitude * math.pi / 180;
    final angular = meters / earthRadius;
    final destinationLatitude = math.asin(
      math.sin(latitude) * math.cos(angular) +
          math.cos(latitude) * math.sin(angular) * math.cos(bearing),
    );
    final destinationLongitude =
        longitude +
        math.atan2(
          math.sin(bearing) * math.sin(angular) * math.cos(latitude),
          math.cos(angular) -
              math.sin(latitude) * math.sin(destinationLatitude),
        );
    return GeoPoint(
      latitude: destinationLatitude * 180 / math.pi,
      longitude: destinationLongitude * 180 / math.pi,
    );
  }

  /// Rides [from] towards [junction] on [approachBearing], then away on
  /// [departureBearing], feeding the recorder a fix every 10 m the way a phone
  /// would.
  void rideThrough(
    RideDiagnosticsRecorder recorder, {
    required GeoPoint junction,
    required double approachBearing,
    required double departureBearing,
    double beforeMeters = 150,
    double afterMeters = 150,
  }) {
    for (var back = beforeMeters; back > 0; back -= 10) {
      recorder.observePosition(
        // Behind the junction is the reciprocal of the approach bearing.
        point: move(junction, approachBearing + 180, back),
        headingDegrees: approachBearing,
      );
    }
    recorder.observePosition(point: junction, headingDegrees: approachBearing);
    for (var forward = 10.0; forward <= afterMeters; forward += 10) {
      recorder.observePosition(
        point: move(junction, departureBearing, forward),
        headingDegrees: departureBearing,
      );
    }
  }

  void recordJunction(
    RideDiagnosticsRecorder recorder, {
    required GeoPoint junction,
    required String shownAs,
    double? bearingBefore,
    double? bearingAfter,
    double? headingChange,
  }) => recorder.recordManoeuvre(
    key: 'junction-1',
    position: junction,
    engineType: 'roundabout',
    engineModifier: 'right',
    shownAs: shownAs,
    instructionText: 'Take the 2nd exit',
    bearingBeforeDegrees: bearingBefore,
    bearingAfterDegrees: bearingAfter,
    headingChangeDegrees: headingChange,
    straightBandDegrees: 38,
    exitNumber: 2,
    drivingSide: 'left',
    stepCount: 2,
    roadLabel: 'A46',
  );

  final junction = const GeoPoint(latitude: 51.4545, longitude: -2.5879);

  group('a manoeuvre is written down with what the app reasoned from', () {
    test('every field the two #412 candidates are told apart by is present', () {
      final recorder = RideDiagnosticsRecorder(
        clock: () => DateTime.utc(2026, 8, 10),
      );

      recordJunction(
        recorder,
        junction: junction,
        shownAs: 'right',
        bearingBefore: 10,
        bearingAfter: 100,
        headingChange: 90,
      );

      final report = recorder.render(rideCode: '123456');
      // The reference question: does the bearing the app used match the road?
      expect(report, contains('bearing before  10.0°'));
      expect(report, contains('bearing after   100.0°'));
      // The bucketing question: was the change inside the band?
      expect(
        report,
        contains('heading change  +90.0° (clockwise, to the right)'),
      );
      expect(report, contains('straight band   ±38°'));
      // And the rest of what the #302 sheet shows, so a captured turn explains
      // the instruction rather than only naming it.
      expect(report, contains('engine          roundabout / right'));
      expect(report, contains('exit number     2'));
      expect(report, contains('driving side    left'));
      expect(report, contains('steps merged    2'));
    });

    test('a manoeuvre re-derived on every fix is written down once', () {
      final recorder = RideDiagnosticsRecorder(
        clock: () => DateTime.utc(2026, 8, 10),
      );

      for (var attempt = 0; attempt < 5; attempt += 1) {
        recordJunction(recorder, junction: junction, shownAs: 'right');
      }

      expect(
        recorder.entries.where((entry) => entry.contains('MANOEUVRE')).length,
        1,
      );
    });
  });

  group('what the bike did is compared against what the app said', () {
    test('a rider who went straight on has their actual change recorded', () {
      final recorder = RideDiagnosticsRecorder(
        clock: () => DateTime.utc(2026, 8, 10),
      );

      // Approach north, leave north: straight on through the junction.
      for (var back = 150.0; back > 40; back -= 10) {
        recorder.observePosition(
          point: move(junction, 180, back),
          headingDegrees: 0,
        );
      }
      recordJunction(
        recorder,
        junction: junction,
        shownAs: 'right',
        bearingBefore: 0,
        bearingAfter: 90,
        headingChange: 90,
      );
      rideThrough(
        recorder,
        junction: junction,
        approachBearing: 0,
        departureBearing: 0,
        beforeMeters: 40,
      );

      final report = recorder.render();
      expect(report, contains('RIDDEN'));
      // This is the line that settles #412: the app said a 90 degree right, the
      // bike went straight on. A disagreement of this shape is the reference
      // error; agreement would point at the bucketing instead.
      expect(
        report,
        contains('actual change   0.0° (straight on)'),
        reason: 'the rider rode straight through, so the actual change is zero',
      );
    });

    test('a rider who turned right records a rightward change', () {
      final recorder = RideDiagnosticsRecorder(
        clock: () => DateTime.utc(2026, 8, 10),
      );

      for (var back = 150.0; back > 40; back -= 10) {
        recorder.observePosition(
          point: move(junction, 180, back),
          headingDegrees: 0,
        );
      }
      recordJunction(recorder, junction: junction, shownAs: 'right');
      rideThrough(
        recorder,
        junction: junction,
        approachBearing: 0,
        departureBearing: 90,
        beforeMeters: 40,
      );

      final ridden = recorder.entries.firstWhere((e) => e.contains('RIDDEN'));
      expect(ridden, contains('clockwise, to the right'));
      expect(ridden, contains('actual change   +90.0°'));
    });

    test('nothing is claimed for a junction the rider has not reached', () {
      final recorder = RideDiagnosticsRecorder(
        clock: () => DateTime.utc(2026, 8, 10),
      );

      for (var back = 150.0; back > 40; back -= 10) {
        recorder.observePosition(
          point: move(junction, 180, back),
          headingDegrees: 0,
        );
      }
      recordJunction(recorder, junction: junction, shownAs: 'right');

      expect(
        recorder.entries.any((entry) => entry.contains('RIDDEN')),
        isFalse,
        reason: 'the rider is still approaching; there is nothing to compare',
      );
    });
  });

  group('the other three tickets get their numbers too', () {
    test(
      'a spoken prompt records how far from the junction it fired (#409)',
      () {
        final recorder = RideDiagnosticsRecorder(
          clock: () => DateTime.utc(2026, 8, 10),
        );

        recorder.recordSpokenPrompt(
          phrase: 'Take the 2nd exit',
          distanceToManoeuvreMeters: 12.4,
        );

        expect(recorder.render(), contains('12 m to the junction'));
      },
    );

    test('an unknown distance says so rather than reading as zero', () {
      final recorder = RideDiagnosticsRecorder(
        clock: () => DateTime.utc(2026, 8, 10),
      );

      recorder.recordSpokenPrompt(
        phrase: 'Take the 2nd exit',
        distanceToManoeuvreMeters: null,
      );

      expect(recorder.render(), contains('distance to junction unknown'));
    });

    test('an enforcement warning records arming and clearing (#418)', () {
      final recorder = RideDiagnosticsRecorder(
        clock: () => DateTime.utc(2026, 8, 10),
      );

      recorder.recordEnforcementWarning(
        hazardType: 'speedCamera',
        distanceMeters: 1600,
        armed: true,
        clearedBy: null,
      );
      recorder.recordEnforcementWarning(
        hazardType: 'speedCamera',
        distanceMeters: 0,
        armed: false,
        clearedBy: 'rider tap',
      );

      final report = recorder.render();
      expect(report, contains('ENFORCE    armed  speedCamera  1600 m'));
      expect(report, contains('cleared by rider tap'));
    });

    test('a recalculation is recorded either way (#414)', () {
      final recorder = RideDiagnosticsRecorder(
        clock: () => DateTime.utc(2026, 8, 10),
      );

      recorder.recordReroute(reason: 'off route', succeeded: true);
      recorder.recordReroute(reason: 'off route', succeeded: false);

      expect(recorder.render(), contains('off route  produced a route'));
      expect(recorder.render(), contains('off route  failed'));
    });
  });

  group('the record is bounded and says when it truncated', () {
    test('a long ride drops the oldest entries and reports how many', () {
      final recorder = RideDiagnosticsRecorder(
        clock: () => DateTime.utc(2026, 8, 10),
      );
      final overflow = RideDiagnosticsConfiguration.maximumEntries + 25;

      for (var index = 0; index < overflow; index += 1) {
        recorder.recordNote('entry $index');
      }

      expect(
        recorder.entries.length,
        RideDiagnosticsConfiguration.maximumEntries,
      );
      expect(recorder.droppedEntries, 25);
      // Silent truncation reads as a complete record, which is worse than a
      // short one.
      expect(recorder.render(), contains('25 earlier entries were dropped'));
      expect(recorder.render(), contains('entry ${overflow - 1}'));
    });
  });

  group('the file says what is and is not in it', () {
    test('the header states the privacy scope', () {
      final recorder = RideDiagnosticsRecorder(
        clock: () => DateTime.utc(2026, 8, 10),
      );
      recorder.recordNote('anything');

      final report = recorder.render(rideCode: '123456', appBuild: '1.2.3+46');

      expect(report, contains("this phone's own"));
      expect(report, contains('no ride or invite secret'));
      expect(report, contains('Ride:  123456'));
      expect(report, contains('Build: 1.2.3+46'));
    });
  });
}
