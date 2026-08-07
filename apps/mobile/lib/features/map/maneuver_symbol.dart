import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../domain/imported_route.dart';
import '../../services/navigation_guidance.dart';

/// A manoeuvre symbol described before it is drawn.
///
/// Every symbol declares the [ManeuverSide] it depicts, and every symbol is
/// derived from the instruction's own direction, so a symbol can never point
/// somewhere the instruction wording does not.
sealed class ManeuverSymbol {
  const ManeuverSymbol();

  /// The side the drawn symbol points to. The instruction wording must agree.
  ManeuverSide get side;
}

/// A Material glyph for manoeuvres that are a single arrow.
class ManeuverIconSymbol extends ManeuverSymbol {
  const ManeuverIconSymbol(this.icon, this.side);

  final IconData icon;

  @override
  final ManeuverSide side;
}

/// A drawn roundabout: a ring, the road in, and the exit taken.
///
/// Material has no glyph for leaving a roundabout straight on, and none can show
/// which way round the ring traffic flows, so the ring is drawn instead of
/// borrowing `roundabout_left`/`roundabout_right` - which mean *which exit you
/// take*, not which side a country drives on.
class RoundaboutSymbol extends ManeuverSymbol {
  const RoundaboutSymbol({
    required this.direction,
    required this.leftHandTraffic,
    this.exitNumber,
  });

  final ManeuverDirection direction;

  /// Which exit to take, drawn inside the ring where there is room for it.
  ///
  /// Null whenever the routing engine did not count the exits, which is common
  /// enough that the symbol must read correctly without it.
  final int? exitNumber;

  /// Chooses clockwise or anticlockwise ring flow only. The exit is placed from
  /// [direction]. Where the engine reported no driving side, no flow is drawn.
  final bool? leftHandTraffic;

  @override
  ManeuverSide get side => direction.side;
}

ManeuverSymbol maneuverSymbolFor(ManeuverInstruction instruction) {
  final direction = instruction.direction;
  final side = direction.side;
  switch (instruction.kind) {
    case ManeuverKind.roundabout:
      return RoundaboutSymbol(
        direction: direction,
        leftHandTraffic: instruction.leftHandTraffic,
        exitNumber: instruction.exitNumber,
      );
    case ManeuverKind.arrive:
      return const ManeuverIconSymbol(Icons.flag, ManeuverSide.ahead);
    case ManeuverKind.depart:
      return const ManeuverIconSymbol(Icons.my_location, ManeuverSide.ahead);
    case ManeuverKind.fork:
      if (side == ManeuverSide.left || side == ManeuverSide.right) {
        return ManeuverIconSymbol(
          side == ManeuverSide.left ? Icons.fork_left : Icons.fork_right,
          side,
        );
      }
    case ManeuverKind.onRamp:
    case ManeuverKind.offRamp:
      if (side == ManeuverSide.left || side == ManeuverSide.right) {
        return ManeuverIconSymbol(
          side == ManeuverSide.left ? Icons.ramp_left : Icons.ramp_right,
          side,
        );
      }
    case ManeuverKind.merge:
      if (direction == ManeuverDirection.straight) {
        return const ManeuverIconSymbol(Icons.merge, ManeuverSide.ahead);
      }
    case ManeuverKind.turn:
    case ManeuverKind.endOfRoad:
    case ManeuverKind.useLane:
    case ManeuverKind.continueAhead:
      break;
  }
  return ManeuverIconSymbol(
    _directionalIcon(direction, leftHandTraffic: instruction.leftHandTraffic),
    side,
  );
}

IconData _directionalIcon(
  ManeuverDirection direction, {
  required bool? leftHandTraffic,
}) => switch (direction) {
  ManeuverDirection.sharpLeft => Icons.turn_sharp_left,
  ManeuverDirection.left => Icons.turn_left,
  ManeuverDirection.slightLeft => Icons.turn_slight_left,
  ManeuverDirection.straight => Icons.straight,
  ManeuverDirection.slightRight => Icons.turn_slight_right,
  ManeuverDirection.right => Icons.turn_right,
  ManeuverDirection.sharpRight => Icons.turn_sharp_right,
  // A U-turn is made across oncoming traffic, so the glyph's handedness follows
  // the driving side. The wording never claims a side either way.
  ManeuverDirection.uTurn =>
    leftHandTraffic == true ? Icons.u_turn_right : Icons.u_turn_left,
  // No direction was reported, so none is drawn.
  ManeuverDirection.unstated => Icons.alt_route,
};

/// Draws the symbol for one manoeuvre.
class ManeuverSymbolView extends StatelessWidget {
  const ManeuverSymbolView({
    super.key,
    required this.instruction,
    required this.size,
    required this.color,
  });

  final ManeuverInstruction instruction;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final symbol = maneuverSymbolFor(instruction);
    return switch (symbol) {
      ManeuverIconSymbol(:final icon) => Icon(icon, size: size, color: color),
      RoundaboutSymbol() => SizedBox.square(
        dimension: size,
        child: CustomPaint(
          painter: RoundaboutSymbolPainter(symbol: symbol, color: color),
        ),
      ),
    };
  }
}

/// One drawn arc of the ring, measured like the exit: degrees clockwise from
/// straight ahead, with a positive sweep running clockwise on screen.
@immutable
class RoundaboutRingArc {
  const RoundaboutRingArc({
    required this.startDegrees,
    required this.sweepDegrees,
  });

  final double startDegrees;
  final double sweepDegrees;

  double get startRadians => (startDegrees - 90) * math.pi / 180;
  double get sweepRadians => sweepDegrees * math.pi / 180;
  double get endDegrees => startDegrees + sweepDegrees;
}

/// An arrowhead. The symbol carries two: one at the end of the exit road,
/// saying where the rider leaves, and one on the ring, saying which way round
/// they travel to get there.
@immutable
class RoundaboutArrowHead {
  const RoundaboutArrowHead({
    required this.tip,
    required this.direction,
    required this.length,
    required this.halfWidth,
  });

  /// Where the arrow points, which is where the rider is going.
  final Offset tip;

  /// Unit vector from the ring towards [tip].
  final Offset direction;
  final double length;
  final double halfWidth;

  Offset get base => tip - direction * length;

  List<Offset> get barbs {
    final normal = Offset(-direction.dy, direction.dx);
    return [base + normal * halfWidth, base - normal * halfWidth];
  }

  Path toPath() {
    final corners = barbs;
    return Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(corners.first.dx, corners.first.dy)
      ..lineTo(corners.last.dx, corners.last.dy)
      ..close();
  }
}

/// The exit the rider takes: a road leaving through the break in the ring, and
/// the symbol's only arrowhead at the end of it.
@immutable
class RoundaboutExitRoad {
  const RoundaboutExitRoad({
    required this.start,
    required this.end,
    required this.head,
  });

  /// On the ring, so the road reads as leaving through the break in it.
  final Offset start;

  /// Where the drawn road stops, inside [head] so no cap shows past the point.
  final Offset end;
  final RoundaboutArrowHead head;
}

/// Every part of a roundabout symbol, worked out before anything is drawn.
///
/// The shape is separated from the painting so it can be asserted rather than
/// only eyeballed: that the ring is broken where each road meets it, and that
/// the way round the ring is drawn rather than left to be inferred.
@immutable
class RoundaboutSymbolGeometry {
  const RoundaboutSymbolGeometry._({
    required this.centre,
    required this.radius,
    required this.roadStrokeWidth,
    required this.ringStrokeWidth,
    required this.entryDegrees,
    required this.entryRoadStart,
    required this.entryRoadEnd,
    required this.ringArcs,
    required this.ringDirection,
    required this.exit,
    required this.exitNumber,
  });

  /// Works out how [symbol] is drawn into a box of [size].
  ///
  /// Every part is placed within the box at every direction, so no arrowhead is
  /// lost to a clip in the banner or in the all-turns list.
  factory RoundaboutSymbolGeometry.of(RoundaboutSymbol symbol, Size size) {
    final extent = size.shortestSide;
    final centre = Offset(size.width / 2, size.height / 2);
    final road = math.max(_minimumRoadStroke, extent * _roadStrokeFraction);
    final radius = extent * _radiusFraction;
    final reach = extent * _reachFraction;
    final exitDegrees = _exitDegrees(symbol);
    final entryDegrees = _entryDegrees(exitDegrees);
    final entryUnit = _unitAt(entryDegrees);
    // Turning back leaves by the exit beside the one the rider came in by, so
    // both roads sit near the bottom of the ring. Run them along the box instead
    // of along their own radii: radial roads splay apart into a V, which reads as
    // two unrelated sticks rather than as going back the way you came.
    final parallelRoads = _turnsBack(exitDegrees);
    final entryDirection = parallelRoads ? _down : entryUnit;
    final ringArcs = _ringArcs(
      entryDegrees: entryDegrees,
      exitDegrees: exitDegrees,
      leftHandTraffic: symbol.leftHandTraffic,
    );
    return RoundaboutSymbolGeometry._(
      centre: centre,
      radius: radius,
      roadStrokeWidth: road,
      ringStrokeWidth: road,
      entryDegrees: entryDegrees,
      // Roads stop on the ring itself, so a rounded end fills the break in the
      // ring without reaching into the middle of it. The far end is carried out
      // from there along the road's own heading, which is its radius except
      // where the roads run parallel and both run straight down the box.
      entryRoadStart:
          centre + entryUnit * radius + entryDirection * (reach - radius),
      entryRoadEnd: centre + entryUnit * radius,
      ringArcs: ringArcs,
      ringDirection: _ringDirection(
        centre: centre,
        extent: extent,
        radius: radius,
        ringArcs: ringArcs,
      ),
      exitNumber: symbol.exitNumber,
      exit: exitDegrees == null
          ? null
          : _exitRoad(
              centre: centre,
              extent: extent,
              exitDegrees: exitDegrees,
              radius: radius,
              along: parallelRoads ? _down : _unitAt(exitDegrees),
            ),
    );
  }

  /// The exit road, from where it meets the ring out to its arrowhead.
  ///
  /// [along] is the heading the road runs on, which is normally its own radius
  /// but is straight down the box where the roads run parallel. Splitting the two
  /// is what lets a turn back on itself leave alongside the road in rather than
  /// splaying away from it.
  static RoundaboutExitRoad _exitRoad({
    required Offset centre,
    required double extent,
    required double exitDegrees,
    required double radius,
    required Offset along,
  }) {
    final onRing = centre + _unitAt(exitDegrees) * radius;
    final headLength = extent * _arrowHeadLengthFraction;
    final tip = onRing + along * (extent * _reachFraction - radius);
    return RoundaboutExitRoad(
      start: onRing,
      end: tip - along * (headLength * _roadIntoHeadFraction),
      head: RoundaboutArrowHead(
        tip: tip,
        direction: along,
        length: headLength,
        halfWidth: extent * _arrowHeadHalfWidthFraction,
      ),
    );
  }

  /// Which way round the ring the rider travels, drawn on the ring itself.
  ///
  /// Reported from the field as "the symbol shows going anticlockwise round a
  /// roundabout to turn right". The arc was correct — keeping left, a right turn
  /// is three quarters of the way round, and on a clock face that runs
  /// 6 → 9 → 12 → 3, so the drawn path leaves the bottom towards the *left* of
  /// the box before coming back to the right-hand exit. It reads as
  /// anticlockwise because the only thing saying otherwise was the shape of the
  /// arc, and a rider glancing at a long arc reads it in whichever direction
  /// their eye travels.
  ///
  /// Flipping the sweep was the obvious fix and would have drawn the illegal
  /// manoeuvre. Saying which way round instead costs one arrowhead.
  ///
  /// Placed early on the arc, not at its middle: on a near-full circle the
  /// middle is diametrically opposite the roads and reads as belonging to
  /// neither, while a mark just after the rider joins is unambiguously about the
  /// direction they set off in.
  static RoundaboutArrowHead? _ringDirection({
    required Offset centre,
    required double extent,
    required double radius,
    required List<RoundaboutRingArc> ringArcs,
  }) {
    final arc = ringArcs.isEmpty ? null : ringArcs.first;
    // A short arc is all corner: the entry road, the arrowhead and the exit
    // road would collide, and the direction is not in doubt over 45 degrees
    // anyway.
    if (arc == null ||
        arc.sweepDegrees.abs() < _minimumArcForDirectionDegrees) {
      return null;
    }
    final flow = arc.sweepDegrees.isNegative ? -1.0 : 1.0;
    final atDegrees = arc.startDegrees + arc.sweepDegrees * _directionAlongArc;
    final radians = atDegrees * math.pi / 180;
    // The tangent to _unitAt at this angle, pointing the way the arc sweeps.
    final along = Offset(math.cos(radians) * flow, math.sin(radians) * flow);
    return RoundaboutArrowHead(
      tip:
          centre +
          _unitAt(atDegrees) * radius +
          along * (extent * _arrowHeadLengthFraction / 2),
      direction: along,
      length: extent * _arrowHeadLengthFraction,
      halfWidth: extent * _arrowHeadHalfWidthFraction,
    );
  }

  /// Straight down the box, the way the rider came from.
  static const _down = Offset(0, 1);

  /// Whether the exit leaves close enough to the road in for the two to need
  /// running parallel rather than along their own radii.
  static bool _turnsBack(double? exitDegrees) =>
      exitDegrees != null &&
      _halfTurn(exitDegrees - _straightBackDegrees).abs() <
          _minimumRoadSeparationDegrees;

  /// Straight back the way the rider came, where the road in normally meets the
  /// ring: at the bottom of the box, opposite a straight-ahead exit.
  static const _straightBackDegrees = 180.0;

  /// Least angle kept between the road in and the exit, so a turn back on
  /// itself leaves the ring beside the road in rather than along it.
  static const _minimumRoadSeparationDegrees = 36.0;

  static const _minimumRoadStroke = 1.6;
  static const _roadStrokeFraction = 0.07;
  static const _radiusFraction = 0.20;

  /// Furthest any ink sits from the centre, which keeps the arrow point inside
  /// the box at every exit angle, including straight ahead and square across.
  static const _reachFraction = 0.45;

  /// Arrowhead size, kept proportionate to the ring rather than to the box.
  ///
  /// At 0.088 the head was almost as wide across its base as the ring's radius,
  /// which read as a solid wedge stuck to a stub of road rather than as an arrow
  /// on a road. Two road widths across is enough to be unmistakable.
  static const _arrowHeadLengthFraction = 0.12;
  static const _arrowHeadHalfWidthFraction = 0.070;

  /// Below this the arc is a short hop to a near exit and reads only one way,
  /// so the mark would be clutter crowding the entry road. Keeping left that
  /// leaves a left turn (a quarter of the ring) unmarked, and marks straight on
  /// (a half) and a right turn (three quarters) - which are exactly the two a
  /// rider can read backwards.
  static const _minimumArcForDirectionDegrees = 135.0;

  /// How far along the ridden arc the direction arrowhead sits.
  static const _directionAlongArc = 0.25;
  static const _roadIntoHeadFraction = 0.6;

  final Offset centre;
  final double radius;
  final double roadStrokeWidth;

  /// The same width as the roads. A ring drawn at a different weight to the roads
  /// that meet it reads as a separate object rather than as the junction.
  final double ringStrokeWidth;

  /// Which exit to take, or null when the engine did not count the exits or the
  /// symbol is too small to hold a legible digit.
  final int? exitNumber;

  /// Where the road in meets the ring, in degrees clockwise from straight ahead.
  final double entryDegrees;

  final Offset entryRoadStart;
  final Offset entryRoadEnd;
  final List<RoundaboutRingArc> ringArcs;

  /// Which way round the ring the rider goes. Null where the arc is too short
  /// to carry the mark, which is also where the direction is not in doubt.
  final RoundaboutArrowHead? ringDirection;

  /// The exit, or `null` where the engine reported no direction to draw.
  final RoundaboutExitRoad? exit;

  /// How much of the ring is drawn. Always short of a full turn.
  double get ringSweepDegrees =>
      ringArcs.fold(0, (total, arc) => total + arc.sweepDegrees.abs());

  /// How much of the ring is left open for the roads to pass through.
  /// What is not drawn: the part of the ring the rider never reaches.
  double get ringGapDegrees => 360 - ringSweepDegrees;

  /// The number of arrowheads drawn, which is one wherever a direction is
  /// stated and none where the engine stated none.
  int get arrowHeadCount => exit == null ? 0 : 1;

  /// Exit angle in degrees clockwise from straight ahead, or `null` when the
  /// engine reported no direction to draw.
  static double? _exitDegrees(
    RoundaboutSymbol symbol,
  ) => switch (symbol.direction) {
    ManeuverDirection.sharpLeft => -135,
    ManeuverDirection.left => -90,
    ManeuverDirection.slightLeft => -45,
    ManeuverDirection.straight => 0,
    ManeuverDirection.slightRight => 45,
    ManeuverDirection.right => 90,
    ManeuverDirection.sharpRight => 135,
    // Turning back leaves by the exit beside the one the rider joined by -
    // but the one they reach *last*, having gone almost the whole way round.
    // Keeping left, traffic circulates clockwise, so that exit sits just
    // before the road in rather than just after it. The two were the wrong way
    // round, which drew a U-turn as a 36 degree arc: take the first exit, the
    // opposite instruction. Invisible while the whole ring was drawn and only
    // the emphasis varied; obvious once only the ridden arc is drawn.
    ManeuverDirection.uTurn => symbol.leftHandTraffic == false ? -165 : 165,
    ManeuverDirection.unstated => null,
  };

  /// Where the road in meets the ring, in the same degrees as the exit.
  ///
  /// It comes straight up from the bottom, except where the exit turns so far
  /// back that the two would be drawn along each other: the road in then swings
  /// to the other side of straight back, so a turn back on itself reads as
  /// leaving by the exit beside the one the rider came in by.
  static double _entryDegrees(double? exitDegrees) {
    if (exitDegrees == null) return _straightBackDegrees;
    final fromStraightBack = _halfTurn(exitDegrees - _straightBackDegrees);
    if (fromStraightBack.abs() >= _minimumRoadSeparationDegrees) {
      return _straightBackDegrees;
    }
    final aside = _minimumRoadSeparationDegrees - fromStraightBack.abs();
    return _straightBackDegrees -
        (fromStraightBack.isNegative ? -aside : aside);
  }

  static Offset _unitAt(double degrees) {
    final radians = degrees * math.pi / 180;
    return Offset(math.sin(radians), -math.cos(radians));
  }

  /// Half the ring gap, as the angle whose chord is one road width: the road
  /// The one arc: the part of the ring the rider actually rides.
  ///
  /// From where they join to where they leave, the way traffic flows on their
  /// side of the road. The rest of the circle is not drawn at all - it is not a
  /// ring with a gap cut in it, it is only ever the arc needed to reach the exit,
  /// and the gap is the negative of that same arc.
  ///
  /// This replaced a ring drawn as two arcs with a fixed gap either side of each
  /// road. Every complaint about the old symbol came from the part of the ring the
  /// rider does not ride: drawn thinner it read as a second, smaller circle;
  /// drawn at full weight it closed the ring up; and the fixed gaps left the roads
  /// either floating in a hole or welded to an unbroken circle. Not drawing it at
  /// all answers all of that, and says something true - this is the way round you
  /// go.
  static List<RoundaboutRingArc> _ringArcs({
    required double entryDegrees,
    required double? exitDegrees,
    required bool? leftHandTraffic,
  }) {
    if (exitDegrees == null) {
      // No exit was reported, so no part of the ring can be claimed as the part
      // ridden. The whole circle is drawn, saying only "a roundabout".
      return [const RoundaboutRingArc(startDegrees: 0, sweepDegrees: 360)];
    }
    // Traffic runs clockwise where riders keep left, so that is the way round the
    // arc sweeps: the first exit is a short arc, the last one nearly the whole
    // circle. Where the driving side was never reported, assume the local one
    // rather than draw nothing - the exit road still carries the instruction.
    final flow = leftHandTraffic == false ? -1.0 : 1.0;
    final ridden = _turn(flow * (exitDegrees - entryDegrees));
    return [
      RoundaboutRingArc(
        startDegrees: entryDegrees,
        sweepDegrees: flow * ridden,
      ),
    ];
  }

  /// Reduces an angle to the turn it describes, from 0 up to a full circle.
  static double _turn(double degrees) => (degrees % 360 + 360) % 360;

  /// Reduces an angle to the shortest turn it describes, either way round.
  static double _halfTurn(double degrees) {
    final turn = _turn(degrees);
    return turn > 180 ? turn - 360 : turn;
  }
}

/// Paints a roundabout with the exit pointing where the rider actually goes.
///
/// The ring is broken where the roads meet it and the exit carries the only
/// arrowhead, so the one arrow a rider glances at is the one they follow.
class RoundaboutSymbolPainter extends CustomPainter {
  const RoundaboutSymbolPainter({required this.symbol, required this.color});

  /// Smallest box that can hold a legible exit number inside the ring.
  ///
  /// The ring's inner diameter is about a third of the box, so below this the
  /// digit would be a smudge. Omitting it is better than drawing something
  /// unreadable in the middle of the junction.
  static const _minimumExtentForExitNumber = 28.0;

  /// Digit height as a fraction of the box, chosen so the glyph's layout box sits
  /// inside the ring's inscribed square with margin left over.
  static const _exitNumberFraction = 0.20;

  final RoundaboutSymbol symbol;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final geometry = RoundaboutSymbolGeometry.of(symbol, size);

    // The road the rider is on, entering from the bottom of the box.
    canvas.drawLine(
      geometry.entryRoadStart,
      geometry.entryRoadEnd,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = geometry.roadStrokeWidth
        ..strokeCap = StrokeCap.round,
    );

    final bounds = Rect.fromCircle(
      center: geometry.centre,
      radius: geometry.radius,
    );
    // One weight, one colour, every arc. The ring is a single road; drawing part
    // of it thinner and dimmer made that part read as a second, smaller circle
    // sitting in the gap instead of as the rest of the same ring.
    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = geometry.ringStrokeWidth
      ..color = color;
    for (final arc in geometry.ringArcs) {
      // Butt caps, so each gap is as wide on screen as it is in the geometry.
      canvas.drawArc(
        bounds,
        arc.startRadians,
        arc.sweepRadians,
        false,
        ringPaint,
      );
    }

    if (geometry.ringDirection case final direction?) {
      canvas.drawPath(direction.toPath(), Paint()..color = color);
    }

    _paintExitNumber(canvas, geometry, size);

    final exit = geometry.exit;
    if (exit == null) return;
    // The shaft runs into the arrowhead's base rather than stopping short of it,
    // so the road and the arrow are one continuous mark with no seam.
    //
    // Round caps, like the road in. A butt cap starts the stroke exactly on the
    // ring's centre-line, which leaves the inner half of the ring's own width
    // uncovered and shows as a hairline notch at the join; the round cap reaches
    // back across it. Nothing shows at the far end, where the arrowhead covers it.
    canvas.drawLine(
      exit.start,
      exit.end,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = geometry.roadStrokeWidth
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawPath(
      exit.head.toPath(),
      Paint()
        ..color = color
        ..style = PaintingStyle.fill,
    );
  }

  /// Draws the exit number in the middle of the ring, where there is room.
  void _paintExitNumber(
    Canvas canvas,
    RoundaboutSymbolGeometry geometry,
    Size size,
  ) {
    final exitNumber = geometry.exitNumber;
    if (exitNumber == null) return;
    if (size.shortestSide < _minimumExtentForExitNumber) return;
    final label = TextPainter(
      text: TextSpan(
        text: '$exitNumber',
        style: TextStyle(
          color: color,
          fontSize: size.shortestSide * _exitNumberFraction,
          fontWeight: FontWeight.w700,
          height: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    )..layout();
    // Measured against the largest square that fits inside the ring, not its
    // diameter. A box as tall as the inner diameter overlaps the stroke top and
    // bottom, because the circle narrows away from its middle.
    final innerRadius = geometry.radius - geometry.ringStrokeWidth / 2;
    final room = innerRadius * math.sqrt2;
    if (label.width > room || label.height > room) return;
    label.paint(
      canvas,
      geometry.centre - Offset(label.width / 2, label.height / 2),
    );
  }

  @override
  bool shouldRepaint(RoundaboutSymbolPainter oldDelegate) =>
      oldDelegate.symbol.direction != symbol.direction ||
      oldDelegate.symbol.leftHandTraffic != symbol.leftHandTraffic ||
      oldDelegate.color != color;
}

/// Most lanes that can be shown and still be read at a glance.
const maneuverLaneStripMaxLanes = 6;

/// Whether lane guidance can be shown honestly.
///
/// Nothing is shown when the engine supplied no lanes, and nothing is shown when
/// there are too many to fit: a truncated strip would put the recommended lane
/// in the wrong place on the road.
bool maneuverLanesAreShowable(List<RouteLane> lanes) =>
    lanes.isNotEmpty && lanes.length <= maneuverLaneStripMaxLanes;

/// Spoken and written summary of the lanes to use.
String maneuverLaneSummary(List<RouteLane> lanes) {
  final valid = <String>[];
  for (var index = 0; index < lanes.length; index += 1) {
    final lane = lanes[index];
    if (!lane.valid) continue;
    final direction = lane.indications.isEmpty
        ? 'continue'
        : lane.indications.join(' or ');
    valid.add('lane ${index + 1}: $direction');
  }
  return valid.isEmpty
      ? 'No recommended lane supplied'
      : 'Use ${valid.join(', ')}';
}

/// Lane arrows for the upcoming manoeuvre, with the usable lanes marked.
class ManeuverLaneStrip extends StatelessWidget {
  const ManeuverLaneStrip({
    super.key,
    required this.lanes,
    required this.compact,
  });

  final List<RouteLane> lanes;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (!maneuverLanesAreShowable(lanes)) return const SizedBox.shrink();
    // Sized to be understood without reading, like the turn banner above it
    // (#361). At 25/29 the arrow - the part meant to be grasped at a glance -
    // was smaller than the text beside it, which is backwards.
    //
    // The bottom band is capped: the layout test holds worst-case chrome under
    // 60% of the viewport and #361 already came within 0.07 of it. These sizes
    // are what fits under that cap alongside the banner, so a further increase
    // is a decision about what comes off the band rather than a free change.
    final extent = compact ? 32.0 : 37.0;
    return Semantics(
      key: const Key('lane-guidance'),
      label: maneuverLaneSummary(lanes),
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final lane in lanes) ...[
            Container(
              width: extent,
              height: extent,
              decoration: BoxDecoration(
                color: lane.valid
                    ? const Color(0xFF225C45)
                    : const Color(0xFF303A46),
                borderRadius: BorderRadius.circular(5),
                border: Border.all(
                  color: lane.valid
                      ? const Color(0xFF6ED89A)
                      : const Color(0xFF596574),
                ),
              ),
              // A usable lane is marked by an underline as well as colour so it
              // stays distinct in bright sun and for colour-blind riders.
              child: Column(
                children: [
                  Expanded(
                    child: Center(
                      child: Icon(
                        _laneIcon(lane.indications),
                        size: compact ? 21 : 24,
                        color: lane.valid
                            ? const Color(0xFFE8FFF2)
                            : const Color(0xFF818C99),
                      ),
                    ),
                  ),
                  Container(
                    // Grows with the tile: the underline is what keeps a usable
                    // lane distinct in bright sun and for a rider who cannot
                    // separate the two fills by colour, so it must not stay a
                    // hairline while the tile doubles.
                    height: 4,
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    color: lane.valid
                        ? const Color(0xFF6ED89A)
                        : Colors.transparent,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 5),
          ],
        ],
      ),
    );
  }
}

IconData _laneIcon(List<String> indications) {
  final normalized = indications.map((value) => value.toLowerCase()).toSet();
  // An unmarked lane is drawn as a plain lane rather than as a straight arrow,
  // which would claim a direction the engine did not report.
  if (normalized.isEmpty) return Icons.horizontal_rule;
  if (normalized.any((value) => value.contains('uturn'))) {
    return normalized.any((value) => value.contains('right'))
        ? Icons.u_turn_right
        : Icons.u_turn_left;
  }
  if (normalized.any((value) => value.contains('sharp left'))) {
    return Icons.turn_sharp_left;
  }
  if (normalized.any((value) => value.contains('sharp right'))) {
    return Icons.turn_sharp_right;
  }
  if (normalized.any((value) => value.contains('slight left'))) {
    return Icons.turn_slight_left;
  }
  if (normalized.any((value) => value.contains('slight right'))) {
    return Icons.turn_slight_right;
  }
  if (normalized.any((value) => value == 'left')) return Icons.turn_left;
  if (normalized.any((value) => value == 'right')) return Icons.turn_right;
  return Icons.straight;
}
