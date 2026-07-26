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
    expect(
      (maneuverSymbolFor(straightOn('right')) as RoundaboutSymbol)
          .leftHandTraffic,
      isFalse,
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
