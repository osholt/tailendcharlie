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
  });

  final ManeuverDirection direction;

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

/// What one drawn arc of the ring means to the rider.
enum RoundaboutRingSegment {
  /// The part of the ring the rider rides, from where they join to where they
  /// leave, in the direction traffic flows on the reported driving side.
  ridden,

  /// The rest of the ring, which carries traffic the rider does not follow.
  beyond,

  /// No driving side was reported, so no part of the ring is claimed as the
  /// part the rider rides.
  undirected,
}

/// One drawn arc of the ring, measured like the exit: degrees clockwise from
/// straight ahead, with a positive sweep running clockwise on screen.
@immutable
class RoundaboutRingArc {
  const RoundaboutRingArc({
    required this.startDegrees,
    required this.sweepDegrees,
    required this.segment,
  });

  final double startDegrees;
  final double sweepDegrees;
  final RoundaboutRingSegment segment;

  double get startRadians => (startDegrees - 90) * math.pi / 180;
  double get sweepRadians => sweepDegrees * math.pi / 180;
  double get endDegrees => startDegrees + sweepDegrees;
}

/// The one arrowhead a roundabout symbol carries, at the end of the exit road.
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
/// the symbol carries exactly one arrowhead, on the exit.
@immutable
class RoundaboutSymbolGeometry {
  const RoundaboutSymbolGeometry._({
    required this.centre,
    required this.radius,
    required this.roadStrokeWidth,
    required this.entryRoadStrokeWidth,
    required this.riddenRingStrokeWidth,
    required this.beyondRingStrokeWidth,
    required this.ringGapHalfDegrees,
    required this.entryDegrees,
    required this.entryRoadStart,
    required this.entryRoadEnd,
    required this.ringArcs,
    required this.exit,
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
    final gapHalfDegrees = _ringGapHalfDegrees(road: road, radius: radius);
    return RoundaboutSymbolGeometry._(
      centre: centre,
      radius: radius,
      roadStrokeWidth: road,
      entryRoadStrokeWidth: road * _entryRoadFraction,
      riddenRingStrokeWidth: road * _riddenRingFraction,
      beyondRingStrokeWidth: road * _beyondRingFraction,
      ringGapHalfDegrees: gapHalfDegrees,
      entryDegrees: entryDegrees,
      // Roads stop on the ring itself, so a rounded end fills the break in the
      // ring without reaching into the middle of it. The far end is carried out
      // from there along the road's own heading, which is its radius except
      // where the roads run parallel and both run straight down the box.
      entryRoadStart:
          centre + entryUnit * radius + entryDirection * (reach - radius),
      entryRoadEnd: centre + entryUnit * radius,
      ringArcs: _ringArcs(
        entryDegrees: entryDegrees,
        exitDegrees: exitDegrees,
        gapHalfDegrees: gapHalfDegrees,
        minimumSweepDegrees: _minimumSweepDegrees(
          stroke: road * _riddenRingFraction,
          radius: radius,
        ),
        leftHandTraffic: symbol.leftHandTraffic,
      ),
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
  static const _roadIntoHeadFraction = 0.6;

  /// The road in is context rather than instruction, so it is drawn lighter
  /// than the exit and never competes with it.
  static const _entryRoadFraction = 0.7;
  static const _riddenRingFraction = 0.85;
  static const _beyondRingFraction = 0.58;

  /// Bounds on the ring gap either road clears, in degrees of half-width.
  ///
  /// The gap has to be wider than the road that passes through it, or the road
  /// fills its own gap and the ring reads as unbroken. A road of stroke `s` at
  /// radius `r` covers `asin(s / 2r)` either side of its centre-line — about 10
  /// degrees here — so a half-gap must clear that with daylight to spare. These
  /// bounds only catch absurd sizes; the derived value normally passes through.
  static const _minimumGapHalfDegrees = 14.0;
  static const _maximumGapHalfDegrees = 26.0;

  /// Shortest arc worth drawing, as a multiple of its own stroke width.
  ///
  /// Measured in stroke widths rather than degrees because that is what decides
  /// whether a rider reads an arc or a speck: at banner size a first-exit stub
  /// is barely twice as long as the ring is thick, and sitting beside the exit
  /// it reads as something left in the gap.
  ///
  /// Held low deliberately. At 3.0 this worked out to a 64 degree threshold,
  /// which dropped the perfectly legible 38 degree arc beside a right turn and
  /// left the ring open on that side — the ring stopped reading as a ring.
  static const _minimumArcInStrokes = 1.2;

  final Offset centre;
  final double radius;
  final double roadStrokeWidth;
  final double entryRoadStrokeWidth;
  final double riddenRingStrokeWidth;
  final double beyondRingStrokeWidth;

  /// Half the angle each road clears from the ring, so the road passes through
  /// daylight on both sides rather than butting into an unbroken circle.
  final double ringGapHalfDegrees;

  /// Where the road in meets the ring, in degrees clockwise from straight ahead.
  final double entryDegrees;

  final Offset entryRoadStart;
  final Offset entryRoadEnd;
  final List<RoundaboutRingArc> ringArcs;

  /// The exit, or `null` where the engine reported no direction to draw.
  final RoundaboutExitRoad? exit;

  /// How much of the ring is drawn. Always short of a full turn.
  double get ringSweepDegrees =>
      ringArcs.fold(0, (total, arc) => total + arc.sweepDegrees.abs());

  /// How much of the ring is left open for the roads to pass through.
  double get ringGapDegrees => 360 - ringSweepDegrees;

  /// The number of arrowheads drawn, which is one wherever a direction is
  /// stated and none where the engine stated none.
  int get arrowHeadCount => exit == null ? 0 : 1;

  /// Exit angle in degrees clockwise from straight ahead, or `null` when the
  /// engine reported no direction to draw.
  static double? _exitDegrees(RoundaboutSymbol symbol) =>
      switch (symbol.direction) {
        ManeuverDirection.sharpLeft => -135,
        ManeuverDirection.left => -90,
        ManeuverDirection.slightLeft => -45,
        ManeuverDirection.straight => 0,
        ManeuverDirection.slightRight => 45,
        ManeuverDirection.right => 90,
        ManeuverDirection.sharpRight => 135,
        // Turning back leaves by the exit next to the one the rider joined by,
        // which is on the far side of the ring from the direction of flow.
        ManeuverDirection.uTurn => symbol.leftHandTraffic == false ? 165 : -165,
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
  /// takes half of that, leaving half a road width of daylight beside it.
  ///
  /// Held to a fixed angle rather than derived from the road width. Deriving it
  /// as `asin(road / radius)` produced a 26 degree half-gap — a 52 degree hole in
  /// the ring for every road — which left so little ring between two roads that
  /// the remaining arcs fell under the minimum below and were dropped. The ring
  /// then rendered as one long stroke with no visible circulation, which is what
  /// riders reported as "no gap" and as the flow running the wrong way round.
  static double _ringGapHalfDegrees({
    required double road,
    required double radius,
  }) => math.min(
    _maximumGapHalfDegrees,
    math.max(
      _minimumGapHalfDegrees,
      math.asin(math.min(0.92, road / radius)) * 180 / math.pi,
    ),
  );

  /// The shortest arc worth drawing, as a sweep.
  static double _minimumSweepDegrees({
    required double stroke,
    required double radius,
  }) => stroke * _minimumArcInStrokes / radius * 180 / math.pi;

  static List<RoundaboutRingArc> _ringArcs({
    required double entryDegrees,
    required double? exitDegrees,
    required double gapHalfDegrees,
    required double minimumSweepDegrees,
    required bool? leftHandTraffic,
  }) {
    if (exitDegrees == null) {
      // No direction was reported, so the ring breaks only where the rider
      // joins it and nothing claims where they leave.
      return [
        RoundaboutRingArc(
          startDegrees: entryDegrees + gapHalfDegrees,
          sweepDegrees: 360 - gapHalfDegrees * 2,
          segment: RoundaboutRingSegment.undirected,
        ),
      ];
    }
    // Traffic runs clockwise where riders keep left. Driving side shapes the
    // ring by deciding which way round the rider reaches the exit: the first
    // exit is a short arc, the last one nearly the whole ring.
    final flow = leftHandTraffic == false ? -1.0 : 1.0;
    final ridden = _turn(flow * (exitDegrees - entryDegrees));
    final riddenSweep = ridden - gapHalfDegrees * 2;
    final beyondSweep = 360 - ridden - gapHalfDegrees * 2;
    // An arc too short to read as an arc is left out, and the gap beside it
    // widens to take its place: drawn, it is a speck in the gap the exit leaves
    // through rather than part of the ring.
    final drawsRidden = riddenSweep >= minimumSweepDegrees;
    final drawsBeyond = beyondSweep >= minimumSweepDegrees;
    // One part cannot be emphasised over another that is not there, and a ring
    // whose flow was never reported claims no ridden part at all.
    final emphasised = drawsRidden && drawsBeyond && leftHandTraffic != null;
    return [
      if (drawsRidden)
        RoundaboutRingArc(
          startDegrees: entryDegrees + flow * gapHalfDegrees,
          sweepDegrees: flow * riddenSweep,
          segment: emphasised
              ? RoundaboutRingSegment.ridden
              : RoundaboutRingSegment.undirected,
        ),
      if (drawsBeyond)
        RoundaboutRingArc(
          startDegrees: exitDegrees + flow * gapHalfDegrees,
          sweepDegrees: flow * beyondSweep,
          segment: emphasised
              ? RoundaboutRingSegment.beyond
              : RoundaboutRingSegment.undirected,
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

  /// How much of the ink is kept on the part of the ring the rider leaves
  /// behind: enough to read as a ring, plainly less than the ridden part.
  static const _beyondRingOpacity = 0.7;

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
        ..strokeWidth = geometry.entryRoadStrokeWidth
        ..strokeCap = StrokeCap.round,
    );

    final bounds = Rect.fromCircle(
      center: geometry.centre,
      radius: geometry.radius,
    );
    for (final arc in geometry.ringArcs) {
      // Butt caps, so each gap is as wide on screen as it is in the geometry.
      canvas.drawArc(
        bounds,
        arc.startRadians,
        arc.sweepRadians,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = arc.segment == RoundaboutRingSegment.beyond
              ? geometry.beyondRingStrokeWidth
              : geometry.riddenRingStrokeWidth
          ..color = arc.segment == RoundaboutRingSegment.beyond
              ? color.withValues(alpha: color.a * _beyondRingOpacity)
              : color,
      );
    }

    final exit = geometry.exit;
    if (exit == null) return;
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
    final extent = compact ? 25.0 : 29.0;
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
                        size: compact ? 15 : 18,
                        color: lane.valid
                            ? const Color(0xFFE8FFF2)
                            : const Color(0xFF818C99),
                      ),
                    ),
                  ),
                  Container(
                    height: 3,
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    color: lane.valid
                        ? const Color(0xFF6ED89A)
                        : Colors.transparent,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 4),
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
