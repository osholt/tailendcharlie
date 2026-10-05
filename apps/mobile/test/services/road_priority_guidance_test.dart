import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/features/map/maneuver_diagnostics.dart';
import 'package:ride_relay/services/navigation_guidance.dart';
import 'package:ride_relay/services/spoken_guidance_schedule.dart';

import 'osrm_maneuver_fixtures.dart';

/// #851: UK junction wording follows major/minor road priority. Where the road
/// the rider is on carries on they follow it, and nothing is said where nothing
/// needs deciding; leaving the major road keeps its direction; roundabouts and
/// the end of a road keep their explicit left, right and straight on.
void main() {
  Future<List<ManeuverInstruction>> spoken(
    Map<String, Object?> response,
  ) async => const NavigationGuidancePlanner()
      .instructions(await routeFromOsrmResponse(response))
      .map((step) => step.instruction)
      .toList();

  group('the forks heard between Aust and Bristol are not announced', () {
    test('leaving Aust services there is no fork at either junction', () async {
      // Diagnostics file 5 logged "At the fork, continue straight on" at
      // 51.604228,-2.620230 and 51.603037,-2.618555, where the engine had said
      // nothing and its other roads leave 45 and 75 degrees from the one taken.
      final instructions = await spoken(austServicesExitResponse());
      expect(instructions.map((instruction) => instruction.standaloneText), [
        'Keep right',
        'Arrive at the destination',
      ]);
      expect(
        instructions.map((instruction) => instruction.maneuver.type),
        isNot(contains('fork')),
      );
      // An unnamed service road is not a road called "Turn".
      expect(instructions.first.roadLabel, isEmpty);
    });

    test('on the M48 the exit slip it passes is not a fork', () async {
      // M48 at 51.557187,-2.556790: the main line at 157 degrees, the slip at
      // 151 - the straighter of the two - and the M48 carries on.
      final instructions = await spoken(m48PastExitSlipResponse());
      expect(instructions.map((instruction) => instruction.standaloneText), [
        'Arrive at the destination',
      ]);
    });

    test('after joining the M32 the split it stays on is not a fork', () async {
      final instructions = await spoken(m32AfterMergeResponse());
      expect(instructions.map((instruction) => instruction.kind), [
        ManeuverKind.merge,
        ManeuverKind.arrive,
      ]);
      for (final instruction in instructions) {
        expect(instruction.standaloneText, isNot(contains('fork')));
      }
    });
  });

  group('the major road carrying on is followed', () {
    test(
      'the engine\'s fork where the M4 carries on says follow the road',
      () async {
        final instruction = (await spoken(
          m4M48ForkResponse(staysOnM4: true),
        )).firstWhere((instruction) => instruction.maneuver.type == 'fork');
        expect(instruction.text, followTheRoadText);
        expect(instruction.standaloneText, followTheRoadText);
        expect(instruction.kind, ManeuverKind.continueAhead);
        expect(instruction.direction, ManeuverDirection.straight);
        expect(instruction.isGuidance, isTrue);
        expect(instruction.roadLabel, 'M4');
      },
    );

    test(
      'leaving the M4 for the M48 at the same fork keeps its side',
      () async {
        final instruction = (await spoken(
          m4M48ForkResponse(staysOnM4: false),
        )).firstWhere((instruction) => instruction.maneuver.type == 'fork');
        expect(instruction.text, 'Keep left');
        expect(instruction.direction, ManeuverDirection.slightLeft);
        expect(instruction.roadLabel, 'M48');
      },
    );

    test('leaving the A472 for the B4235 slip keeps its side', () async {
      final instruction = (await spoken(
        uskB4235DivergeResponse(),
      )).firstWhere((instruction) => instruction.maneuver.type == 'turn');
      expect(instruction.text, 'Keep left');
    });

    test('a road bending where nothing else can be taken is followed', () {
      // Live OSRM, Beaufort Square in Chepstow: `continue` `left`, the only
      // road the route may take at that junction.
      final instruction = _second(
        before: _road(name: 'Beaufort Square'),
        maneuver: RouteManeuver(
          position: _at,
          type: 'continue',
          modifier: 'left',
          name: 'Beaufort Square',
          bearingBeforeDegrees: 1,
          bearingAfterDegrees: 312,
          junction: RouteJunction.tryCreate(
            bearingsDegrees: const [105, 120, 180, 315],
            enterable: const [false, false, false, true],
            takenIndex: 3,
            approachIndex: 2,
          ),
        ),
      );
      expect(instruction.text, followTheRoadText);
      expect(instruction.isGuidance, isTrue);
    });

    test('a numbered road is the same road whatever its name', () {
      // Live OSRM: Hardwick Hill A48 becomes Mount Pleasant A48 at a `turn`
      // `left` of 31 degrees; the only other road leaves 105 degrees round.
      final instruction = _second(
        before: _road(name: 'Hardwick Hill', ref: 'A48'),
        maneuver: RouteManeuver(
          position: _at,
          type: 'turn',
          modifier: 'left',
          name: 'Mount Pleasant',
          ref: 'A48',
          bearingBeforeDegrees: 61,
          bearingAfterDegrees: 30,
          junction: RouteJunction.tryCreate(
            bearingsDegrees: const [30, 240, 315],
            enterable: const [true, false, true],
            takenIndex: 0,
            approachIndex: 1,
          ),
        ),
      );
      expect(instruction.text, followTheRoadText);
    });

    test('a saved route\'s restored fork is followed, never "continue '
        'straight on"', () {
      // Routes saved before this change still hold the forks the old detector
      // invented, with no junction kept. Where the road carries on they are
      // worded as following it.
      final instruction = _second(
        before: _road(ref: 'B4235'),
        maneuver: const RouteManeuver(
          position: _at,
          type: 'fork',
          modifier: 'straight',
          ref: 'B4235',
          bearingBeforeDegrees: 60,
          bearingAfterDegrees: 60,
        ),
      );
      expect(instruction.text, followTheRoadText);
    });
  });

  group(
    'where following the road would not say which road, it is not used',
    () {
      test('a straighter road at the junction keeps the direction', () {
        // Live OSRM: Bromley Heath Road A4017 to Cleeve Hill A4017, a `turn`
        // `slight left` of 24 degrees with a road carrying on dead ahead. The
        // A4017 continues, but "follow the road" could mean either.
        final instruction = _second(
          before: _road(name: 'Bromley Heath Road', ref: 'A4017'),
          maneuver: RouteManeuver(
            position: _at,
            type: 'turn',
            modifier: 'slight left',
            name: 'Cleeve Hill',
            ref: 'A4017',
            bearingBeforeDegrees: 189,
            bearingAfterDegrees: 165,
            junction: RouteJunction.tryCreate(
              bearingsDegrees: const [15, 165, 195],
              enterable: const [false, true, true],
              takenIndex: 1,
              approachIndex: 0,
            ),
          ),
        );
        expect(instruction.text, 'Keep left');
      });

      test('two near-parallel branches of the same road keep their side', () {
        // Live OSRM, the M32 split: the route's branch is one degree off
        // straight ahead and the other three.
        final instruction = _second(
          before: _road(ref: 'M32'),
          maneuver: RouteManeuver(
            position: _at,
            type: 'fork',
            modifier: 'slight right',
            ref: 'M32',
            bearingBeforeDegrees: 26,
            bearingAfterDegrees: 29,
            junction: RouteJunction.tryCreate(
              bearingsDegrees: const [27, 31, 208],
              enterable: const [true, true, false],
              takenIndex: 0,
              approachIndex: 2,
            ),
          ),
        );
        expect(instruction.text, 'Keep right');
      });

      test('a different road is never followed', () {
        for (final (before, after) in [
          (_road(ref: 'A472'), 'B4235'),
          (_road(name: 'High Street'), null),
          (_road(), null),
        ]) {
          final instruction = _second(
            before: before,
            maneuver: RouteManeuver(
              position: _at,
              type: 'fork',
              modifier: 'straight',
              ref: after,
              bearingBeforeDegrees: 60,
              bearingAfterDegrees: 60,
            ),
          );
          expect(instruction.text, 'At the fork, continue straight on');
        }
      });

      test('a sharp bend keeps its own wording', () {
        final instruction = _second(
          before: _road(name: 'Hill Road'),
          maneuver: RouteManeuver(
            position: _at,
            type: 'continue',
            modifier: 'sharp right',
            name: 'Hill Road',
            bearingBeforeDegrees: 0,
            bearingAfterDegrees: 140,
            junction: RouteJunction.tryCreate(
              bearingsDegrees: const [140, 180],
              enterable: const [true, false],
              takenIndex: 0,
              approachIndex: 1,
            ),
          ),
        );
        expect(instruction.text, 'Continue sharp right');
      });
    },
  );

  group('roundabouts and the end of a road keep explicit directions', () {
    test('a roundabout on the same road still names its exit', () {
      final instructions = collapseManeuvers([
        _road(ref: 'A4042'),
        const RouteManeuver(
          position: _at,
          type: 'roundabout',
          modifier: 'slight left',
          ref: 'A4042',
          exitNumber: 2,
          bearingBeforeDegrees: 180,
          bearingAfterDegrees: 150,
        ),
        const RouteManeuver(
          position: GeoPoint(latitude: 51.7001, longitude: -2.8),
          type: 'exit roundabout',
          modifier: 'slight left',
          ref: 'A4042',
          bearingBeforeDegrees: 200,
          bearingAfterDegrees: 178,
        ),
      ]);
      expect(instructions.last.text, '2nd exit, straight on');
    });

    test('the end of the same road still says which way', () {
      // Even where the road turns left at a T-junction and the right arm may
      // not be entered: the road ends here, and the rider is told which way.
      final instruction = _second(
        before: _road(ref: 'B4235'),
        maneuver: RouteManeuver(
          position: _at,
          type: 'end of road',
          modifier: 'left',
          ref: 'B4235',
          bearingBeforeDegrees: 0,
          bearingAfterDegrees: 270,
          junction: RouteJunction.tryCreate(
            bearingsDegrees: const [270, 90, 180],
            enterable: const [true, false, false],
            takenIndex: 0,
            approachIndex: 2,
          ),
        ),
      );
      expect(instruction.text, 'At the end of the road, turn left');
    });
  });

  group('the road and the paired prompt read as written English', () {
    test('an unnamed road has no label rather than the engine step type', () {
      for (final type in ['turn', 'fork', 'off ramp', 'depart', 'new name']) {
        final instruction = collapseManeuvers([
          RouteManeuver(position: _at, type: type, modifier: 'right'),
        ]).single;
        expect(instruction.roadLabel, isEmpty, reason: type);
        expect(
          maneuverDiagnosticsReport(instruction),
          contains('Road:             —'),
          reason: type,
        );
      }
    });

    test('a pair of turns is spoken as one sentence', () {
      // File 2 logged "Turn right, then Turn right".
      expect(
        guidanceSubject(
          instructionText: 'Turn right',
          followingInstructionText: 'Turn right',
        ),
        'Turn right, then turn right',
      );
      expect(
        guidanceSubject(
          instructionText: 'Keep right',
          followingInstructionText: 'Roundabout, 1st exit, left',
        ),
        'Keep right, then roundabout, 1st exit, left',
      );
    });

    test('an instruction after a distance is mid-sentence too', () {
      final announcement = nextGuidanceAnnouncement(
        maneuverIdentity: 'turn',
        instructionText: 'Turn right',
        followingInstructionText: 'Turn right',
        distanceToManeuverMeters: 300,
        speedMetersPerSecond: 13,
        alreadySpokenKeys: const {},
        metersSincePreviousManeuver: null,
        distanceFormatter: (meters) => '${meters.round()} m',
      );
      expect(announcement?.phrase, 'In 300 m, turn right, then turn right');
    });
  });
}

const _at = GeoPoint(latitude: 51.7, longitude: -2.8);

RouteManeuver _road({String? name, String? ref}) => RouteManeuver(
  position: const GeoPoint(latitude: 51.69, longitude: -2.8),
  type: 'depart',
  name: name,
  ref: ref,
);

ManeuverInstruction _second({
  required RouteManeuver before,
  required RouteManeuver maneuver,
}) => collapseManeuvers([before, maneuver]).last;
