import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/features/map/maneuver_symbol.dart';
import 'package:ride_relay/services/navigation_guidance.dart';

/// Every manoeuvre type the routing engine documents, plus one it does not, so
/// an unrecognised type still produces an instruction that matches its symbol.
const _types = [
  'turn',
  'new name',
  'depart',
  'arrive',
  'merge',
  'ramp',
  'on ramp',
  'off ramp',
  'fork',
  'end of road',
  'use lane',
  'continue',
  'roundabout',
  'rotary',
  'roundabout turn',
  'exit roundabout',
  'exit rotary',
  'notification',
  'teleport',
];

/// Every documented modifier, plus an absent and an empty one.
const _modifiers = [
  null,
  '',
  'uturn',
  'u-turn',
  'sharp right',
  'right',
  'slight right',
  'straight',
  'slight left',
  'left',
  'sharp left',
  'anticlockwise',
];

const _drivingSides = [null, 'left', 'right'];

final _leftWord = RegExp(r'\bleft\b', caseSensitive: false);
final _rightWord = RegExp(r'\bright\b', caseSensitive: false);

/// A roundabout whose exit was counted but whose direction was not reported.
final _exitNumberOnly = RegExp(
  r'^(Roundabout, take the|Take the) \d+(st|nd|rd|th) exit$',
);

void main() {
  test('every symbol points the way its instruction reads', () {
    for (final type in _types) {
      for (final modifier in _modifiers) {
        for (final drivingSide in _drivingSides) {
          // Without engine bearings, and with them, so both the reported and the
          // derived direction paths are covered.
          _expectAgreement(
            _instruction(type: type, modifier: modifier, side: drivingSide),
          );
          _expectAgreement(
            _instruction(
              type: type,
              modifier: modifier,
              side: drivingSide,
              bearings: true,
            ),
          );
          _expectAgreement(
            _instruction(
              type: type,
              modifier: modifier,
              side: drivingSide,
              bearings: true,
              withRingExit: true,
            ),
          );
        }
      }
    }
  });

  test('a roundabout symbol is not chosen from the driving side', () {
    ManeuverInstruction straightOn(String? drivingSide) => _instruction(
      type: 'roundabout',
      // The engine's entry modifier for a clockwise ring, which is what used to
      // be read as the exit direction.
      modifier: 'slight left',
      side: drivingSide,
      bearings: true,
      withRingExit: true,
      exitTurnDegrees: 0,
      exitNumber: 2,
    );

    for (final drivingSide in _drivingSides) {
      final instruction = straightOn(drivingSide);
      final symbol = maneuverSymbolFor(instruction);

      expect(instruction.text, '2nd exit, straight on');
      expect(symbol, isA<RoundaboutSymbol>());
      expect(symbol.side, ManeuverSide.ahead);
      expect(
        (symbol as RoundaboutSymbol).direction,
        ManeuverDirection.straight,
      );
    }

    // Driving side only decides which way round the ring is drawn.
    expect(
      (maneuverSymbolFor(straightOn('left')) as RoundaboutSymbol)
          .leftHandTraffic,
      isTrue,
    );
    // And an engine claiming right-hand traffic no longer decides it at all.
    // It said exactly that for two UK roundabouts on the 10 August ride, and
    // the ring mirrored itself to match while the exit number and the direction
    // word stayed correct — see #427 and _leftHandTraffic's own note.
    expect(
      (maneuverSymbolFor(straightOn('right')) as RoundaboutSymbol)
          .leftHandTraffic,
      isNull,
    );
    expect(
      (maneuverSymbolFor(straightOn(null)) as RoundaboutSymbol).leftHandTraffic,
      isNull,
    );
  });

  test('a roundabout exit to the right draws its exit to the right', () {
    final symbol =
        maneuverSymbolFor(
              _instruction(
                type: 'roundabout',
                modifier: 'slight left',
                side: 'left',
                bearings: true,
                withRingExit: true,
                exitTurnDegrees: 90,
                exitNumber: 3,
              ),
            )
            as RoundaboutSymbol;

    expect(symbol.direction, ManeuverDirection.right);
    expect(symbol.side, ManeuverSide.right);
  });

  testWidgets('a roundabout is drawn rather than borrowed from a glyph', (
    tester,
  ) async {
    final instruction = _instruction(
      type: 'roundabout',
      modifier: 'slight left',
      side: 'left',
      bearings: true,
      withRingExit: true,
      exitTurnDegrees: 0,
      exitNumber: 2,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: ManeuverSymbolView(
          instruction: instruction,
          size: 38,
          color: const Color(0xFF68A9FF),
        ),
      ),
    );

    expect(find.byType(CustomPaint), findsWidgets);
    expect(find.byIcon(Icons.roundabout_left), findsNothing);
    expect(find.byIcon(Icons.roundabout_right), findsNothing);
  });

  testWidgets('lane guidance marks usable lanes and hides when unusable', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Column(
          children: [
            ManeuverLaneStrip(
              lanes: [
                RouteLane(indications: ['left'], valid: false),
                RouteLane(indications: ['straight', 'right'], valid: true),
              ],
              compact: false,
            ),
          ],
        ),
      ),
    );

    expect(find.byKey(const Key('lane-guidance')), findsOneWidget);
    expect(find.byIcon(Icons.turn_left), findsOneWidget);
    expect(find.byIcon(Icons.turn_right), findsOneWidget);

    // Absent lanes show nothing at all rather than an empty placeholder.
    expect(maneuverLanesAreShowable(const []), isFalse);
    // A strip too wide to read at speed would move the usable lane to the
    // wrong side of the road, so nothing is shown.
    expect(
      maneuverLanesAreShowable(
        List.filled(
          maneuverLaneStripMaxLanes + 1,
          const RouteLane(indications: ['straight'], valid: true),
        ),
      ),
      isFalse,
    );
  });

  test('lane summaries name the usable lanes only', () {
    expect(
      maneuverLaneSummary(const [
        RouteLane(indications: ['left'], valid: false),
        RouteLane(indications: ['straight', 'right'], valid: true),
      ]),
      'Use lane 2: straight or right',
    );
    expect(
      maneuverLaneSummary(const [
        RouteLane(indications: ['left'], valid: false),
      ]),
      'No recommended lane supplied',
    );
  });

  // Reported from the field as "the symbol shows going anticlockwise round a
  // roundabout to turn right". The arc was already correct - keeping left, a
  // right turn is three quarters of the way round, which on a clock face runs
  // 6 -> 9 -> 12 -> 3 and so leaves the bottom towards the *left* of the box.
  // Nothing said which way along it the rider travels, so the eye supplied an
  // answer and supplied the wrong one. Flipping the sweep would have drawn the
  // illegal manoeuvre; this asserts the direction is stated instead.
  //
  // The cross product of the radius with the arrowhead's heading is +1 for a
  // clockwise sweep on screen and -1 for an anticlockwise one, so it reads the
  // way round directly rather than through the sign of an angle.
  double? sweepSign(RoundaboutSymbol symbol) {
    final geometry = RoundaboutSymbolGeometry.of(symbol, const Size(200, 200));
    final head = geometry.ringDirection;
    if (head == null) return null;
    final radius = head.tip - geometry.centre;
    return (radius.dx * head.direction.dy - radius.dy * head.direction.dx).sign;
  }

  test('a right turn keeping left is marked as going round clockwise', () {
    for (final drivingSide in [null, true]) {
      expect(
        sweepSign(
          RoundaboutSymbol(
            direction: ManeuverDirection.right,
            leftHandTraffic: drivingSide,
            exitNumber: 3,
          ),
        ),
        1.0,
        reason: 'driving side $drivingSide should circulate clockwise',
      );
    }
  });

  // The mirror image: keeping right, traffic circulates anticlockwise, so it is
  // the *left* turn that goes three quarters of the way round and needs saying.
  test('a left turn keeping right is marked as going round anticlockwise', () {
    expect(
      sweepSign(
        const RoundaboutSymbol(
          direction: ManeuverDirection.left,
          leftHandTraffic: false,
          exitNumber: 3,
        ),
      ),
      -1.0,
    );
  });

  // #301's second acceptance criterion: the swept arc and the exit must not be
  // able to drift apart. They are computed separately - the arc from the flow
  // direction, the exit road from the manoeuvre direction - so a future
  // mirroring change could leave the sweep right and put the arrow on the wrong
  // exit, or the reverse. Nothing caught that before this.
  //
  // The invariant is simply that riding the drawn arc lands you on the drawn
  // exit: the arc's end angle is the exit's angle.
  double angleOf(Offset point, Offset centre) {
    final delta = point - centre;
    // Screen y grows downward, and these degrees run clockwise from straight up.
    final degrees = math.atan2(delta.dx, -delta.dy) * 180 / math.pi;
    return (degrees % 360 + 360) % 360;
  }

  test('the drawn arc always ends on the drawn exit', () {
    const directions = [
      ManeuverDirection.sharpLeft,
      ManeuverDirection.left,
      ManeuverDirection.slightLeft,
      ManeuverDirection.straight,
      ManeuverDirection.slightRight,
      ManeuverDirection.right,
      ManeuverDirection.sharpRight,
      ManeuverDirection.uTurn,
    ];
    for (final drivingSide in [true, false, null]) {
      for (final direction in directions) {
        final geometry = RoundaboutSymbolGeometry.of(
          RoundaboutSymbol(
            direction: direction,
            leftHandTraffic: drivingSide,
            exitNumber: 3,
          ),
          const Size(200, 200),
        );
        final exit = geometry.exit;
        final arc = geometry.ringArcs.single;
        expect(exit, isNotNull, reason: '$direction should draw an exit');

        final arcEnd = (arc.endDegrees % 360 + 360) % 360;
        expect(
          arcEnd,
          closeTo(angleOf(exit!.start, geometry.centre), 0.5),
          reason:
              'riding the arc for $direction keeping '
              '${drivingSide == false ? 'right' : 'left'} must end at the exit',
        );
      }
    }
  });

  test('the arc sweeps the way traffic flows on that side of the road', () {
    // Keeping left the whole ridden arc runs clockwise, keeping right it runs
    // anticlockwise, whatever the exit. Sign, not size: the size is the exit.
    for (final direction in [
      ManeuverDirection.left,
      ManeuverDirection.right,
      ManeuverDirection.uTurn,
    ]) {
      expect(
        RoundaboutSymbolGeometry.of(
          RoundaboutSymbol(direction: direction, leftHandTraffic: true),
          const Size(200, 200),
        ).ringArcs.single.sweepDegrees,
        greaterThan(0),
        reason: 'keeping left, $direction must circulate clockwise',
      );
      expect(
        RoundaboutSymbolGeometry.of(
          RoundaboutSymbol(direction: direction, leftHandTraffic: false),
          const Size(200, 200),
        ).ringArcs.single.sweepDegrees,
        lessThan(0),
        reason: 'keeping right, $direction must circulate anticlockwise',
      );
    }
  });

  // A quarter of the ring reads only one way, and the mark would crowd the
  // entry road it sits beside.
  test('a short arc carries no direction mark', () {
    expect(
      sweepSign(
        const RoundaboutSymbol(
          direction: ManeuverDirection.left,
          leftHandTraffic: true,
          exitNumber: 1,
        ),
      ),
      isNull,
    );
  });

  // #381: "the lane indication arrows are quite a good idea but far far too
  // small". The arrow is the part meant to be grasped without reading, so it
  // must not be smaller than the text beside it - the turn banner's distance is
  // 26 compact / 30. Asserted against the rendered tile rather than the
  // constant, so a change that shrinks it back has to fail here.
  testWidgets('a lane tile is big enough to read at a glance', (tester) async {
    for (final compact in [true, false]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: ManeuverLaneStrip(
                lanes: const [
                  RouteLane(indications: ['left'], valid: true),
                  RouteLane(indications: ['straight'], valid: false),
                ],
                compact: compact,
              ),
            ),
          ),
        ),
      );

      final tile = tester.getSize(
        find
            .descendant(
              of: find.byKey(const Key('lane-guidance')),
              matching: find.byType(Container),
            )
            .first,
      );
      expect(
        tile.height,
        greaterThanOrEqualTo(compact ? 30 : 35),
        reason: 'compact=$compact lane tile is $tile',
      );
      // And still inside what the bottom band can carry: #361 came within 0.07
      // of the 60% chrome cap, so this is not free height.
      expect(tile.height, lessThanOrEqualTo(compact ? 34 : 40));
    }
  });
}

void _expectAgreement(ManeuverInstruction instruction) {
  final symbol = maneuverSymbolFor(instruction);
  final reason =
      'type "${instruction.maneuver.type}" '
      'modifier "${instruction.maneuver.modifier}" '
      'driving side "${instruction.maneuver.drivingSide}" '
      'gave "${instruction.text}" '
      'and "${instruction.standaloneText}"';

  expect(symbol.side, instruction.direction.side, reason: reason);
  // The wording beside the symbol and the wording read where there is no symbol
  // must both agree with the symbol: neither may point the other way.
  for (final text in {instruction.text, instruction.standaloneText}) {
    expect(text.trim(), isNotEmpty, reason: reason);
    switch (symbol.side) {
      case ManeuverSide.left:
        expect(text, matches(_leftWord), reason: reason);
        expect(text, isNot(matches(_rightWord)), reason: reason);
      case ManeuverSide.right:
        expect(text, matches(_rightWord), reason: reason);
        expect(text, isNot(matches(_leftWord)), reason: reason);
      case ManeuverSide.reverse:
        expect(text.toLowerCase(), contains('u-turn'), reason: reason);
        expect(text, isNot(matches(_leftWord)), reason: reason);
        expect(text, isNot(matches(_rightWord)), reason: reason);
      case ManeuverSide.ahead:
        expect(text, isNot(matches(_leftWord)), reason: reason);
        expect(text, isNot(matches(_rightWord)), reason: reason);
    }
    // Every instruction names a direction, states the exit it is known to take,
    // or is a named special case. None of them is empty of instruction.
    final named =
        instruction.direction.isStated ||
        _exitNumberOnly.hasMatch(text) ||
        const {
          // A roundabout with neither an exit number nor a direction has only
          // the symbol to say what the junction is; the wording read without
          // the symbol still names it.
          'Follow the route',
          'Roundabout ahead, follow the route',
          'Junction ahead, follow the route',
          'End of the road, follow the route',
          'Merge with traffic',
          'Fork ahead, follow the route',
          'Take the slip road',
          'Take the exit slip road',
          'Stay in your lane',
          'Start off',
          'Arrive at the destination',
        }.contains(text);
    expect(named, isTrue, reason: reason);
  }

  // The symbol carries the junction where it is drawn, and the wording carries
  // it where it is not.
  if (instruction.isRoundabout) {
    expect(
      instruction.text.toLowerCase(),
      isNot(contains('roundabout')),
      reason: reason,
    );
    expect(
      instruction.standaloneText.toLowerCase(),
      contains('roundabout'),
      reason: reason,
    );
  } else {
    expect(instruction.standaloneText, instruction.text, reason: reason);
  }
}

ManeuverInstruction _instruction({
  required String type,
  required String? modifier,
  required String? side,
  bool bearings = false,
  bool withRingExit = false,
  double? exitTurnDegrees,
  int? exitNumber,
}) {
  final turn = exitTurnDegrees ?? _modifierTurnDegrees(modifier);
  final maneuvers = [
    RouteManeuver(
      position: const GeoPoint(latitude: 51.46, longitude: -2.59),
      type: type,
      modifier: modifier,
      drivingSide: side,
      exitNumber: exitNumber,
      bearingBeforeDegrees: bearings ? 0 : null,
      bearingAfterDegrees: bearings
          ? (withRingExit ? 290 : (turn + 360) % 360)
          : null,
    ),
    if (withRingExit)
      RouteManeuver(
        position: const GeoPoint(latitude: 51.4601, longitude: -2.59),
        type: type.contains('rotary') ? 'exit rotary' : 'exit roundabout',
        modifier: modifier,
        drivingSide: side,
        bearingBeforeDegrees: bearings ? 200 : null,
        bearingAfterDegrees: bearings ? (turn + 360) % 360 : null,
      ),
  ];
  return collapseManeuvers(maneuvers).first;
}

double _modifierTurnDegrees(String? modifier) => switch (modifier) {
  'sharp left' => -135,
  'left' => -90,
  'slight left' => -45,
  'slight right' => 45,
  'right' => 90,
  'sharp right' => 135,
  'uturn' || 'u-turn' => 180,
  _ => 0,
};
