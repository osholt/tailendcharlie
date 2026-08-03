import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/features/map/maneuver_diagnostics.dart';
import 'package:ride_relay/services/navigation_guidance.dart';

/// #302 and #301 are both blocked on the same missing thing: the raw manoeuvre
/// data for a junction that came out wrong. This is the readout that unblocks
/// them, so what it has to get right is that it never disagrees with the
/// classifier it is describing.
void main() {
  /// Through the real planner, so the readout is always describing an
  /// instruction the app would actually give.
  ManeuverInstruction instructionFor(RouteManeuver maneuver) =>
      const NavigationGuidancePlanner()
          .instructions(
            ImportedRoute(
              id: 'r',
              name: 'Route',
              importedAt: DateTime.utc(2026, 8, 2),
              sourceFileName: 'r.gpx',
              waypoints: const [],
              paths: const [
                RoutePath(
                  kind: RoutePathKind.track,
                  points: [
                    GeoPoint(latitude: 51.4670, longitude: -2.5020),
                    GeoPoint(latitude: 51.4676, longitude: -2.5015),
                    GeoPoint(latitude: 51.4676, longitude: -2.4990),
                  ],
                ),
              ],
              maneuvers: [maneuver],
            ),
          )
          .single
          .instruction;

  const junction = GeoPoint(latitude: 51.4676, longitude: -2.5015);

  group('the readout says what the router said and what we made of it', () {
    test('a stated modifier is shown, and shown to have been understood', () {
      final report = maneuverDiagnosticsReport(
        instructionFor(
          const RouteManeuver(
            position: junction,
            type: 'turn',
            modifier: 'sharp right',
            name: 'Cloud Hill',
            bearingBeforeDegrees: 10,
            bearingAfterDegrees: 100,
          ),
        ),
        position: 7,
      );

      expect(report, contains('Engine type:      turn'));
      expect(report, contains('Engine modifier:  sharp right'));
      expect(report, contains('Modifier reads as: sharp right'));
      expect(report, isNot(contains('NOT RECOGNISED')));
    });

    test('the heading change is stated, signed and named', () {
      // The number #302 asks to be captured before any threshold is moved.
      final report = maneuverDiagnosticsReport(
        instructionFor(
          const RouteManeuver(
            position: junction,
            type: 'turn',
            modifier: 'right',
            bearingBeforeDegrees: 10,
            bearingAfterDegrees: 100,
          ),
        ),
      );

      expect(report, contains('Bearing before:   10.0°'));
      expect(report, contains('Bearing after:    100.0°'));
      expect(report, contains('+90.0° (clockwise, to the right)'));
    });

    test('an anticlockwise turn is named as one', () {
      final report = maneuverDiagnosticsReport(
        instructionFor(
          const RouteManeuver(
            position: junction,
            type: 'turn',
            modifier: 'left',
            bearingBeforeDegrees: 100,
            bearingAfterDegrees: 10,
          ),
        ),
      );

      expect(report, contains('-90.0° (anticlockwise, to the left)'));
    });

    test('a modifier the app does not understand is called out', () {
      // The half of #302 that is a provable defect rather than a hypothesis:
      // an unrecognised modifier means the app fell through to geometry, which
      // is a different fault with a different fix.
      final report = maneuverDiagnosticsReport(
        instructionFor(
          const RouteManeuver(
            position: junction,
            type: 'turn',
            modifier: 'hard right',
            bearingBeforeDegrees: 10,
            bearingAfterDegrees: 100,
          ),
        ),
      );

      expect(
        report,
        contains('Engine modifier:  hard right  (NOT RECOGNISED)'),
      );
      expect(report, contains('Modifier reads as: unstated'));
      expect(
        report,
        contains('Geometry reads as: right'),
        reason: 'and this is what the rider was told instead',
      );
    });

    test('a manoeuvre with no bearings says so rather than inventing one', () {
      final report = maneuverDiagnosticsReport(
        instructionFor(
          const RouteManeuver(
            position: junction,
            type: 'turn',
            modifier: 'right',
          ),
        ),
      );

      expect(report, contains('Heading change:   —'));
      expect(report, contains('Geometry reads as: —'));
    });

    test('the readout cannot disagree with the instruction it describes', () {
      // Both come from the same planner, so a change to the classifier moves
      // both together or this fails.
      final instruction = instructionFor(
        const RouteManeuver(
          position: junction,
          type: 'turn',
          modifier: 'sharp right',
          bearingBeforeDegrees: 10,
          bearingAfterDegrees: 100,
        ),
      );

      expect(
        maneuverDiagnosticsReport(instruction),
        contains('Instruction:      ${instruction.standaloneText}'),
      );
    });
  });

  group('turn severity boundaries, with realistic geometry (#302)', () {
    // The acceptance criteria ask for these. They are here rather than as a
    // fix because all three classifiers involved — OSRM's, Valhalla's and this
    // app's — already put a true 90 degrees in the plain band, so moving a
    // boundary would be the wrong change. What is worth pinning is where the
    // bands actually are, so the next report can be read against them.
    ManeuverDirection classify(double before, double after) =>
        directionFromHeadingChange(
          maneuverHeadingChangeDegrees(
            RouteManeuver(
              position: junction,
              type: 'turn',
              bearingBeforeDegrees: before,
              bearingAfterDegrees: after,
            ),
          )!,
        );

    test('an ordinary 90-degree right is a plain right', () {
      expect(classify(0, 90), ManeuverDirection.right);
      expect(classify(275, 5), ManeuverDirection.right);
    });

    test('the plain band runs from 60 to 120 degrees, exclusive of 60', () {
      expect(classify(0, 60), ManeuverDirection.slightRight);
      expect(classify(0, 61), ManeuverDirection.right);
      expect(classify(0, 120), ManeuverDirection.right);
      expect(classify(0, 121), ManeuverDirection.sharpRight);
    });

    test('the same boundaries hold to the left', () {
      expect(classify(0, 270), ManeuverDirection.left);
      expect(classify(0, 239), ManeuverDirection.sharpLeft);
    });

    test('an exit road that curves away can push a 90-degree turn to sharp', () {
      // This is candidate 2 from the issue, as an arithmetic fact rather than
      // a claim about the reported junction. A right turn onto a road that
      // then bends 35 degrees further right within the engine's bearing sample
      // measures 125 degrees, which is over the boundary — so a wrongly
      // reported severity can come from correct data sampled too far out.
      expect(classify(0, 90), ManeuverDirection.right);
      expect(classify(0, 90 + 35), ManeuverDirection.sharpRight);
    });

    test('a roundabout gets a wider straight band than a plain junction', () {
      expect(
        directionFromHeadingChange(30),
        ManeuverDirection.slightRight,
        reason: 'at an ordinary junction 30 degrees is a turn',
      );
      expect(
        directionFromHeadingChange(
          30,
          straightBandDegrees: maneuverRoundaboutStraightBandDegrees,
        ),
        ManeuverDirection.straight,
        reason: "on a ring it is the arms' offset, not a turn (#254)",
      );
    });
  });

  group('a hyphenated modifier is not silently lost (#302)', () {
    // `replaceAll('-', '')` turned `sharp-right` into `sharpright`, which
    // matched nothing and returned `unstated` — so an engine that hyphenates
    // lost its stated direction and the app fell through to geometry without
    // saying so.
    test('hyphenated and spaced modifiers read the same', () {
      for (final (hyphenated, spaced) in const [
        ('sharp-right', 'sharp right'),
        ('slight-left', 'slight left'),
        ('sharp-left', 'sharp left'),
        ('slight-right', 'slight right'),
      ]) {
        expect(
          directionFromModifier(hyphenated),
          directionFromModifier(spaced),
          reason: hyphenated,
        );
        expect(directionFromModifier(hyphenated).isStated, isTrue);
      }
    });

    test('both spellings of a U-turn still work', () {
      expect(directionFromModifier('uturn'), ManeuverDirection.uTurn);
      expect(directionFromModifier('u-turn'), ManeuverDirection.uTurn);
      expect(directionFromModifier('U Turn'), ManeuverDirection.uTurn);
    });

    test('a modifier this app has no word for stays unstated', () {
      // Guessing would be worse than saying nothing; the wording drops the
      // direction rather than inventing one.
      expect(directionFromModifier('hard-right'), ManeuverDirection.unstated);
      expect(directionFromModifier(null), ManeuverDirection.unstated);
      expect(directionFromModifier('   '), ManeuverDirection.unstated);
    });
  });

  group('the sheet', () {
    testWidgets('shows the readout and copies it', (tester) async {
      final clipboard = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      final instruction = instructionFor(
        const RouteManeuver(
          position: junction,
          type: 'turn',
          modifier: 'sharp right',
          bearingBeforeDegrees: 10,
          bearingAfterDegrees: 100,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ManeuverDiagnosticsSheet(
              instruction: instruction,
              position: 3,
            ),
          ),
        ),
      );

      expect(
        find.byKey(const Key('maneuver-diagnostics-report')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('copy-maneuver-diagnostics')));
      await tester.pumpAndSettle();

      expect(clipboard, hasLength(1));
      expect(clipboard.single, contains('Engine modifier:  sharp right'));
      expect(
        clipboard.single,
        contains('+90.0°'),
        reason:
            'the copied text is the whole point — it is what gets pasted '
            'into the tester group',
      );
    });
  });
}
