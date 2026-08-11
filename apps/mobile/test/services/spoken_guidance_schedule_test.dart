import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/distance_unit.dart';
import 'package:ride_relay/services/measurement_formatter.dart';
import 'package:ride_relay/services/spoken_guidance_schedule.dart';

void main() {
  const formatter = MeasurementFormatter(DistanceUnit.miles);
  String format(double meters) => formatter.distance(meters);

  /// Plays an approach through the scheduler the way a phone would: a fix every
  /// [step] metres, collecting what is said and where.
  List<({double at, GuidanceStage stage, String phrase})> ride({
    required double fromMeters,
    required double speedMetersPerSecond,
    double step = 10,
    double? metersSincePreviousManeuver,
    String instruction = 'take the 3rd exit, right',
  }) {
    final spoken = <String>{};
    final said = <({double at, GuidanceStage stage, String phrase})>[];
    for (var distance = fromMeters; distance > 0; distance -= step) {
      final announcement = nextGuidanceAnnouncement(
        maneuverIdentity: 'junction-1',
        instructionText: instruction,
        distanceToManeuverMeters: distance,
        speedMetersPerSecond: speedMetersPerSecond,
        alreadySpokenKeys: spoken,
        metersSincePreviousManeuver: metersSincePreviousManeuver,
        distanceFormatter: format,
      );
      if (announcement == null) continue;
      spoken.add(announcement.key);
      said.add((
        at: distance,
        stage: announcement.stage,
        phrase: announcement.phrase,
      ));
    }
    return said;
  }

  group('a turn is announced before it, with the distance (#409, #410)', () {
    test(
      'a motorway approach gets three prompts, roughly 2 mi / 0.5 mi / final',
      () {
        // 70 mph. The ask was "2 mile warning on motorways and then a follow up at
        // 0.5 miles and a final one just prior" — from time budgets rather than a
        // road-class lookup.
        final said = ride(fromMeters: 6000, speedMetersPerSecond: 31.3);

        expect(said.map((s) => s.stage), [
          GuidanceStage.early,
          GuidanceStage.approach,
          GuidanceStage.immediate,
        ]);
        expect(said[0].at, closeTo(3756, 60)); // ~2.3 mi
        expect(said[1].at, closeTo(939, 30)); // ~0.6 mi
        expect(said[2].at, closeTo(250, 30)); // ceiling-bound, ~270 yd
      },
    );

    test('the same route at 30 mph pulls the prompts in', () {
      // The point of staging on time: a two-mile warning on a B road is four
      // minutes of nothing.
      final said = ride(fromMeters: 6000, speedMetersPerSecond: 13.4);

      expect(said.map((s) => s.stage), [
        GuidanceStage.early,
        GuidanceStage.approach,
        GuidanceStage.immediate,
      ]);
      expect(said[0].at, closeTo(1608, 30));
      expect(said[1].at, closeTo(402, 20));
    });

    test('the prompt carries the distance, and the last one does not', () {
      final said = ride(fromMeters: 6000, speedMetersPerSecond: 31.3);

      // #410: it never said any distance at all before this.
      expect(said[0].phrase, startsWith('In '));
      expect(said[0].phrase, contains('take the 3rd exit, right'));
      expect(said[1].phrase, startsWith('In '));
      // At eight seconds out a distance is a syllable the rider has no time for.
      expect(said[2].phrase, 'take the 3rd exit, right');
    });

    test('a junction is never announced after it has been passed', () {
      // #409, stated as the property that was broken: every prompt lands with
      // road still to go.
      final said = ride(fromMeters: 6000, speedMetersPerSecond: 31.3);

      for (final prompt in said) {
        expect(prompt.at, greaterThan(0), reason: '${prompt.stage} was late');
      }
    });

    test('nothing is said twice', () {
      final said = ride(fromMeters: 6000, speedMetersPerSecond: 31.3, step: 2);

      expect(said.map((s) => s.stage).toSet().length, said.length);
    });
  });

  group('a close junction gets one prompt, not three', () {
    test('a turn 300 m ahead skips the early heads-up', () {
      final said = ride(fromMeters: 300, speedMetersPerSecond: 13.4);

      expect(said.map((s) => s.stage), isNot(contains(GuidanceStage.early)));
      expect(said, isNotEmpty);
    });
  });

  group('nothing is said until the rider is clear of the junction (#429)', () {
    test('still on the roundabout, the next turn waits', () {
      // The reported case: on a large roundabout the next instruction arrived
      // while the rider was still going round the one they were told about.
      final announcement = nextGuidanceAnnouncement(
        maneuverIdentity: 'junction-2',
        instructionText: 'turn left',
        distanceToManeuverMeters: 400,
        speedMetersPerSecond: 13.4,
        alreadySpokenKeys: const {},
        metersSincePreviousManeuver: 20,
        distanceFormatter: format,
      );

      expect(announcement, isNull);
    });

    test('clear of it, the next turn is announced', () {
      final announcement = nextGuidanceAnnouncement(
        maneuverIdentity: 'junction-2',
        instructionText: 'turn left',
        distanceToManeuverMeters: 400,
        speedMetersPerSecond: 13.4,
        alreadySpokenKeys: const {},
        metersSincePreviousManeuver: 80,
        distanceFormatter: format,
      );

      expect(announcement, isNotNull);
    });

    test('two junctions 42 m apart are both announced', () {
      // #163's double mini-roundabout. Silence here is worse than a prompt that
      // arrives while the rider is still finishing the first, which is why the
      // exemption exists and is wider than the clearance.
      final announcement = nextGuidanceAnnouncement(
        maneuverIdentity: 'junction-2',
        instructionText: '2nd exit, straight on',
        distanceToManeuverMeters: 42,
        speedMetersPerSecond: 8,
        alreadySpokenKeys: const {},
        metersSincePreviousManeuver: 5,
        distanceFormatter: format,
      );

      expect(
        announcement,
        isNotNull,
        reason: 'the 42 m double mini-roundabout must not be silenced',
      );
    });
  });

  group('a speed the phone cannot vouch for still gets a prompt', () {
    test('no speed falls back to the stage ceiling', () {
      final said = ride(fromMeters: 6000, speedMetersPerSecond: 0);

      expect(said.map((s) => s.stage), contains(GuidanceStage.early));
      expect(said.first.at, closeTo(4000, 30));
    });
  });

  group('nothing is invented from bad input', () {
    test('a negative or absent distance says nothing', () {
      for (final distance in [-1.0, double.nan]) {
        expect(
          nextGuidanceAnnouncement(
            maneuverIdentity: 'j',
            instructionText: 'turn left',
            distanceToManeuverMeters: distance,
            speedMetersPerSecond: 13,
            alreadySpokenKeys: const {},
            metersSincePreviousManeuver: null,
            distanceFormatter: format,
          ),
          isNull,
        );
      }
    });

    test('an empty instruction says nothing', () {
      expect(
        nextGuidanceAnnouncement(
          maneuverIdentity: 'j',
          instructionText: '   ',
          distanceToManeuverMeters: 100,
          speedMetersPerSecond: 13,
          alreadySpokenKeys: const {},
          metersSincePreviousManeuver: null,
          distanceFormatter: format,
        ),
        isNull,
      );
    });
  });
}
