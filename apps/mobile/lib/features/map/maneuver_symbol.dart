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

/// Paints a roundabout with the exit pointing where the rider actually goes.
class RoundaboutSymbolPainter extends CustomPainter {
  const RoundaboutSymbolPainter({required this.symbol, required this.color});

  final RoundaboutSymbol symbol;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final extent = size.shortestSide;
    final stroke = math.max(1.6, extent * 0.1);
    final centre = Offset(size.width / 2, size.height * 0.44);
    final radius = extent * 0.26;
    final line = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    final ring = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke * 0.85;

    // The road the rider is on, entering from the bottom.
    canvas.drawLine(
      Offset(centre.dx, size.height - stroke / 2),
      Offset(centre.dx, centre.dy + radius),
      line,
    );
    canvas.drawCircle(centre, radius, ring);

    final exitDegrees = _exitDegrees(symbol);
    if (exitDegrees != null) {
      final radians = exitDegrees * math.pi / 180;
      final unit = Offset(math.sin(radians), -math.cos(radians));
      final start = centre + unit * radius;
      final end = centre + unit * (radius + extent * 0.3);
      canvas.drawLine(start, end, line);
      _drawArrowHead(canvas, line, end, unit, extent * 0.2);
    }

    final clockwise = symbol.leftHandTraffic;
    if (clockwise != null) {
      // Clockwise flow passes the west side of the ring heading north, and
      // anticlockwise flow passes the east side heading north.
      final anchor = Offset(
        centre.dx + (clockwise ? -radius : radius),
        centre.dy,
      );
      _drawArrowHead(canvas, line, anchor, const Offset(0, -1), extent * 0.155);
    }
  }

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

  static void _drawArrowHead(
    Canvas canvas,
    Paint paint,
    Offset tip,
    Offset direction,
    double length,
  ) {
    final back = -direction;
    final normal = Offset(-direction.dy, direction.dx);
    canvas.drawLine(tip, tip + back * length + normal * length * 0.62, paint);
    canvas.drawLine(tip, tip + back * length - normal * length * 0.62, paint);
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
