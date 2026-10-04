import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/features/map/maneuver_diagnostics.dart';
import 'package:ride_relay/services/navigation_guidance.dart';

import 'osrm_maneuver_fixtures.dart';

/// #856: the Aust roundabout (M48 J1) was announced "Roundabout, 1st exit,
/// left" while the engine step said `rotary` `straight` with a heading change
/// of -4 degrees, and the captured turn detail beside it read "Geometry reads
/// as: straight on".
void main() {
  Future<ManeuverInstruction> austRoundabout() async =>
      const NavigationGuidancePlanner()
          .instructions(await routeFromOsrmResponse(austInterchangeResponse()))
          .map((step) => step.instruction)
          .singleWhere((instruction) => instruction.isRoundabout);

  group('the Aust interchange (#856)', () {
    test('is the first exit, on the left, read from its roads', () async {
      final roundabout = await austRoundabout();

      // The engine's own pair is the turn onto the ring, not the junction.
      expect(roundabout.maneuver.type, 'rotary');
      expect(roundabout.maneuver.modifier, 'straight');
      expect(
        maneuverHeadingChangeDegrees(roundabout.maneuver),
        closeTo(-4, 0.01),
      );

      // Sandy Lane arrives on about 160 degrees and the B4461 leaves on about
      // 122: the first exit, and the only one on the left.
      expect(roundabout.ringRoadsFromRouteLine, isTrue);
      expect(roundabout.approachBearingDegrees, closeTo(160.6, 0.5));
      expect(roundabout.departureBearingDegrees, closeTo(121.6, 0.5));
      expect(roundabout.exitNumber, 1);
      expect(roundabout.direction, ManeuverDirection.slightLeft);
      expect(roundabout.standaloneText, 'Roundabout, 1st exit, left');
    });

    test(
      'its turn detail reports the pair the instruction came from',
      () async {
        final report = maneuverDiagnosticsReport(await austRoundabout());

        expect(report, contains('Shown as:         slight left (roundabout)'));
        expect(report, contains('Bearing before:   160.6°'));
        expect(report, contains('Bearing off ring: 121.6°'));
        expect(report, contains('-39.0° (anticlockwise, to the left)'));
        expect(report, contains('Geometry reads as: slight left'));
        // What used to be printed: the engine's approach at the ring beside the
        // route line's departure, a pair nothing was ever worked out from.
        expect(report, isNot(contains('-29.4°')));
        expect(report, isNot(contains('Geometry reads as: straight on')));
        // Where the numbers came from, and what the engine's own words meant.
        expect(
          report,
          contains(
            'Read from:        the roads either side of the ring, '
            'on the route line',
          ),
        );
        expect(
          report,
          contains('Engine at ring:   151.0° in, 147.0° onto the ring'),
        );
        expect(
          report,
          contains(
            'Modifier reads as: straight on (joining the ring, not the exit)',
          ),
        );
      },
    );
  });

  test(
    'a captured roundabout never contradicts the instruction it describes',
    () async {
      // Every recorded and fixture roundabout, read through the real client and
      // persistence, as the capture sheet and the ride log render them.
      final responses = {
        'UK straight on': ukRoundaboutStraightOnResponse(),
        'third exit right': roundaboutThirdExitRightResponse(),
        'gyratory': gyratoryResponse(),
        'urban pair': multiRoundaboutUrbanResponse(),
        'New Cheltenham Road': newCheltenhamRoadOmittedRoundaboutsResponse(),
        'Aust interchange': austInterchangeResponse(),
      };
      var roundabouts = 0;
      for (final MapEntry(key: name, value: response) in responses.entries) {
        final route = await routeFromOsrmResponse(response);
        for (final step in const NavigationGuidancePlanner().instructions(
          route,
        )) {
          final instruction = step.instruction;
          if (!instruction.isRoundabout) continue;
          roundabouts += 1;
          final report = maneuverDiagnosticsReport(instruction);
          final reads = RegExp(
            r'Geometry reads as: (.*)',
          ).firstMatch(report)!.group(1);
          final shown = instruction.direction.isStated
              ? instruction.direction.label
              : 'unstated';
          expect(
            reads == '—' ? 'unstated' : reads,
            shown,
            reason:
                '$name: the capture must explain "${instruction.text}"\n$report',
          );
        }
      }
      expect(roundabouts, greaterThanOrEqualTo(6));
    },
  );

  test('a roundabout read from the engine says so', () {
    // Without a usable route line the engine's bearings are the pair, and
    // the capture names them as the source.
    final instruction = collapseManeuvers(const [
      RouteManeuver(
        position: GeoPoint(latitude: 51.46, longitude: -2.59),
        type: 'roundabout',
        exitNumber: 2,
        bearingBeforeDegrees: 0,
        bearingAfterDegrees: 290,
      ),
      RouteManeuver(
        position: GeoPoint(latitude: 51.4601, longitude: -2.59),
        type: 'exit roundabout',
        bearingBeforeDegrees: 200,
        bearingAfterDegrees: 5,
      ),
    ]).single;
    expect(instruction.ringRoadsFromRouteLine, isFalse);
    expect(instruction.approachBearingDegrees, 0);
    expect(instruction.departureBearingDegrees, 5);
    final report = maneuverDiagnosticsReport(instruction);
    expect(report, contains('Read from:        the engine\'s bearings'));
    expect(report, isNot(contains('Engine at ring:')));
    expect(report, contains('Bearing before:   0.0°'));
  });
}
