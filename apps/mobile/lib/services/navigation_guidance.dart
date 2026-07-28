import 'dart:math' as math;

import '../domain/imported_route.dart';

/// Which way a manoeuvre goes, as a symbol family.
///
/// [reverse] covers U-turns: the wording never names a side, and the glyph's
/// handedness is a driving-side rendering choice rather than a direction claim.
enum ManeuverSide { left, right, ahead, reverse }

/// The direction a manoeuvre actually takes.
///
/// Both the instruction wording and the symbol are derived from this single
/// value so they cannot contradict each other.
enum ManeuverDirection {
  sharpLeft('sharp left', ManeuverSide.left),
  left('left', ManeuverSide.left),
  slightLeft('slight left', ManeuverSide.left),
  straight('straight on', ManeuverSide.ahead),
  slightRight('slight right', ManeuverSide.right),
  right('right', ManeuverSide.right),
  sharpRight('sharp right', ManeuverSide.right),
  uTurn('U-turn', ManeuverSide.reverse),

  /// The routing engine supplied no direction that can be stated honestly.
  ///
  /// Wording then describes the junction without claiming a direction, because
  /// a wrong direction is worse than an incomplete one.
  unstated('', ManeuverSide.ahead);

  const ManeuverDirection(this.label, this.side);

  final String label;
  final ManeuverSide side;

  bool get isStated => this != ManeuverDirection.unstated;
}

/// The shape of a manoeuvre, mapped from the routing engine's step type.
enum ManeuverKind {
  depart,
  arrive,
  roundabout,
  turn,
  endOfRoad,
  merge,
  fork,
  onRamp,
  offRamp,
  useLane,
  continueAhead,
}

/// One rider-facing instruction, which may cover several engine steps.
///
/// A roundabout is a single instruction even though the engine reports joining
/// and leaving the ring separately.
class ManeuverInstruction {
  const ManeuverInstruction({
    required this.maneuver,
    required this.kind,
    required this.direction,
    required this.text,
    String? standaloneText,
    this.exitNumber,
    this.roadName,
    this.roadRef,
    this.lanes = const [],
    this.leftHandTraffic,
    this.stepCount = 1,
  }) : standaloneText = standaloneText ?? text;

  /// The engine step the rider acts on. Retained so route progress, positions
  /// and object identity stay tied to the original persisted manoeuvre.
  final RouteManeuver maneuver;
  final ManeuverKind kind;
  final ManeuverDirection direction;

  /// Wording shown beside the manoeuvre symbol, always naming a direction where
  /// one is known.
  ///
  /// A roundabout is not named here: the symbol beside it is a drawn roundabout,
  /// and repeating the word spends the glance a rider has on something they can
  /// already see.
  final String text;

  /// Wording for surfaces that show no symbol, where the junction is named
  /// because nothing else there says what it is.
  ///
  /// Used for the banner's accessibility label, which a rider who cannot see the
  /// symbol depends on, and for the CarPlay and Android Auto rows, which are
  /// plain text. Identical to [text] for every manoeuvre drawn from a glyph.
  final String standaloneText;

  /// Roundabout or rotary exit ordinal, only when the engine counted exits.
  final int? exitNumber;
  final String? roadName;
  final String? roadRef;
  final List<RouteLane> lanes;

  /// `true` where the engine reported left-hand traffic at this manoeuvre.
  ///
  /// Used only to draw a roundabout ring or U-turn the right way round; it
  /// never decides which way the instruction says to go.
  final bool? leftHandTraffic;

  /// Number of engine steps collapsed into this instruction.
  final int stepCount;

  GeoPoint get position => maneuver.position;

  bool get isRoundabout => kind == ManeuverKind.roundabout;

  /// Whether this instruction is worth announcing.
  ///
  /// Departures and road-name changes are route bookkeeping, not decisions.
  bool get isGuidance =>
      kind != ManeuverKind.depart && kind != ManeuverKind.continueAhead;

  String get roadLabel {
    final name = roadName?.trim();
    final ref = roadRef?.trim();
    if (name != null && name.isNotEmpty && ref != null && ref.isNotEmpty) {
      return name.contains(ref) ? name : '$name · $ref';
    }
    if (name != null && name.isNotEmpty) return name;
    if (ref != null && ref.isNotEmpty) return ref;
    return _sentenceCase(maneuver.type);
  }
}

/// One collapsed instruction placed along a persisted route.
class RouteInstructionStep {
  const RouteInstructionStep({
    required this.instruction,
    required this.distanceFromStartMeters,
    required this.distanceFromRouteMeters,
  });

  final ManeuverInstruction instruction;

  /// Distance along the route's primary path from its start.
  final double distanceFromStartMeters;

  /// How far the manoeuvre sits from that path. A large value means the
  /// manoeuvre belongs to a different path in the same file.
  final double distanceFromRouteMeters;

  RouteManeuver get maneuver => instruction.maneuver;
}

class NavigationGuidance {
  const NavigationGuidance({
    required this.maneuver,
    required this.distanceMeters,
    required this.instruction,
    this.followingManeuver,
    this.followingDistanceMeters,
    this.followingInstruction,
  });

  final RouteManeuver maneuver;
  final double distanceMeters;

  /// Collapsed instruction for [maneuver], including its wording and direction.
  final ManeuverInstruction instruction;
  final RouteManeuver? followingManeuver;

  /// Distance from the first manoeuvre to a closely following manoeuvre.
  final double? followingDistanceMeters;
  final ManeuverInstruction? followingInstruction;

  String get roadLabel => instruction.roadLabel;
}

/// Collapsed instruction sequences, held weakly against the route they describe.
final _instructionCache = Expando<List<RouteInstructionStep>>(
  'route instructions',
);

/// Selects the next useful route-engine instruction from persisted route data.
///
/// Progress is supplied by the map's monotonic route tracker so self-crossing
/// routes do not jump backwards. A fresh geometric projection is still used to
/// suppress guidance when the rider is clearly away from the route.
class NavigationGuidancePlanner {
  const NavigationGuidancePlanner({
    this.maximumDistanceFromRouteMeters = 150,
    this.passedToleranceMeters = 25,
    this.maximumAdvanceDistanceMeters = 5000,
    this.closeManeuverSpacingMeters = 300,
  });

  final double maximumDistanceFromRouteMeters;
  final double passedToleranceMeters;
  final double maximumAdvanceDistanceMeters;
  final double closeManeuverSpacingMeters;

  /// Every announceable instruction for [route], in order, measured along the
  /// route's primary path.
  ///
  /// This works entirely from persisted route data so the rider can review the
  /// whole route offline, and it is the same sequence [plan] announces from.
  List<RouteInstructionStep> instructions(ImportedRoute? route) {
    if (route == null || route.maneuvers.isEmpty || route.paths.isEmpty) {
      return const [];
    }
    // A route is immutable and this is on the live guidance path, called for
    // every position fix, so the collapsed sequence is kept per route instance.
    final cached = _instructionCache[route];
    if (cached != null) return cached;
    final path = _primaryPath(route.paths);
    if (path.length < 2) return const [];
    final steps = <RouteInstructionStep>[];
    for (final instruction in collapseManeuvers(route.maneuvers)) {
      if (!instruction.isGuidance) continue;
      final projection = _project(instruction.position, path);
      steps.add(
        RouteInstructionStep(
          instruction: instruction,
          distanceFromStartMeters: projection.progressMeters,
          distanceFromRouteMeters: projection.distanceMeters,
        ),
      );
    }
    steps.sort(
      (first, second) => first.distanceFromStartMeters.compareTo(
        second.distanceFromStartMeters,
      ),
    );
    final sequence = List<RouteInstructionStep>.unmodifiable(steps);
    _instructionCache[route] = sequence;
    return sequence;
  }

  /// Distance ridden along [route]'s primary path at [position].
  ///
  /// Only for review surfaces. Live guidance uses the map's monotonic tracker so
  /// a self-crossing route cannot jump backwards.
  double? progressMetersAt(ImportedRoute? route, GeoPoint? position) {
    if (route == null || position == null || route.paths.isEmpty) return null;
    final path = _primaryPath(route.paths);
    if (path.length < 2) return null;
    final projection = _project(position, path);
    if (projection.distanceMeters > maximumDistanceFromRouteMeters) return null;
    return projection.progressMeters;
  }

  NavigationGuidance? plan({
    required ImportedRoute? route,
    required GeoPoint? position,
    required double progressMeters,
  }) {
    if (route == null ||
        position == null ||
        route.maneuvers.isEmpty ||
        route.paths.isEmpty) {
      return null;
    }
    final path = _primaryPath(route.paths);
    if (path.length < 2) return null;
    final riderProjection = _project(position, path);
    if (riderProjection.distanceMeters > maximumDistanceFromRouteMeters) {
      return null;
    }

    final candidates =
        <({ManeuverInstruction instruction, double remaining})>[];
    for (final step in instructions(route)) {
      if (step.distanceFromRouteMeters > maximumDistanceFromRouteMeters) {
        continue;
      }
      final remaining = step.distanceFromStartMeters - progressMeters;
      if (remaining < -passedToleranceMeters ||
          remaining > maximumAdvanceDistanceMeters) {
        continue;
      }
      candidates.add((instruction: step.instruction, remaining: remaining));
    }
    if (candidates.isEmpty) return null;
    candidates.sort(
      (first, second) => first.remaining.compareTo(second.remaining),
    );
    final next = candidates.first;
    final following = candidates.length < 2 ? null : candidates[1];
    final followingSpacing = following == null
        ? null
        : following.remaining - next.remaining;
    final showFollowing =
        following != null &&
        followingSpacing! >= 0 &&
        followingSpacing <= closeManeuverSpacingMeters;
    return NavigationGuidance(
      maneuver: next.instruction.maneuver,
      instruction: next.instruction,
      distanceMeters: math.max(0, next.remaining),
      followingManeuver: showFollowing ? following.instruction.maneuver : null,
      followingInstruction: showFollowing ? following.instruction : null,
      followingDistanceMeters: showFollowing
          ? math.max(0, followingSpacing)
          : null,
    );
  }
}

/// Distance beyond which a following step's heading is no longer taken as the
/// heading of the road leaving a roundabout.
const _exitBearingReachMeters = 250.0;

/// Two ring entries this close together are one gyratory, not two junctions.
const _gyratoryMergeMeters = 25.0;

/// How far from its entry a ring exit may be and still belong to that ring.
///
/// Generous, because a large gyratory or a rotary can carry a rider a long way
/// between joining and leaving - but not unbounded, which is what let an exit
/// belonging to a later roundabout be absorbed into an earlier one.
const _ringExitMeters = 400.0;

/// Collapses routing-engine steps into rider-facing instructions.
///
/// A roundabout or rotary is reported as joining the ring and then leaving it.
/// Announcing both produces two instructions for one junction, each with a
/// direction that describes part of the ring rather than the exit taken, so the
/// sequence is merged into a single instruction here.
List<ManeuverInstruction> collapseManeuvers(List<RouteManeuver> maneuvers) {
  final instructions = <ManeuverInstruction>[];
  var index = 0;
  while (index < maneuvers.length) {
    final entry = maneuvers[index];
    if (_kindFor(entry.type) != ManeuverKind.roundabout) {
      instructions.add(_simpleInstruction(entry));
      index += 1;
      continue;
    }
    var last = index;
    // Always compared against the group's entry, so the thresholds mean what
    // they say rather than measuring hop to hop (#163).
    while (last + 1 < maneuvers.length &&
        _absorbsIntoRing(entry, maneuvers[last + 1])) {
      last += 1;
    }
    final follower = last + 1 < maneuvers.length ? maneuvers[last + 1] : null;
    instructions.add(
      _roundaboutInstruction(
        group: maneuvers.sublist(index, last + 1),
        follower: follower,
      ),
    );
    index = last + 1;
  }
  return List.unmodifiable(instructions);
}

/// Whether [candidate] describes the same ring as the group that starts at
/// [entry].
///
/// Measured from the group's **entry**, not from whatever manoeuvre happens to
/// precede the candidate. The threshold is documented as separating one gyratory
/// from two junctions, which is a statement about ring positions - but comparing
/// an exit against the next entry measures the gap between leaving one ring and
/// joining the next, which is much shorter than the distance between the rings.
/// The double roundabout on New Cheltenham Road is a pair of mini-roundabouts
/// **42 m apart** (OpenStreetMap nodes 51.46705,-2.50050 and 51.46721,-2.50106),
/// comfortably outside the 25 m threshold as centres and easily inside it as
/// exit-to-entry. Merging them announces one junction where a rider meets two
/// (#163).
///
/// An exit is likewise only absorbed while it plausibly belongs to this ring. It
/// used to be absorbed unconditionally, so an exit from a later, distant
/// roundabout could be pulled into an earlier group.
bool _absorbsIntoRing(RouteManeuver entry, RouteManeuver candidate) {
  if (_isRingExit(candidate.type)) {
    return _distance(entry.position, candidate.position) <= _ringExitMeters;
  }
  if (!_isRingEntry(candidate.type)) return false;
  return _distance(entry.position, candidate.position) <= _gyratoryMergeMeters;
}

ManeuverInstruction _roundaboutInstruction({
  required List<RouteManeuver> group,
  required RouteManeuver? follower,
}) {
  final entry = group.first;
  final last = group.last;
  final exit = _isRingExit(last.type) ? last : null;
  final direction = _ringExitDirection(
    entry: entry,
    exit: exit,
    follower: follower,
  );
  // Exit counts belong to one ring. Where adjacent rings were merged, neither
  // count describes the collapsed instruction, so no number is claimed.
  final exitNumbers = group
      .where((maneuver) => _isRingEntry(maneuver.type))
      .map((maneuver) => maneuver.exitNumber)
      .whereType<int>()
      .where((value) => value > 0)
      .toList(growable: false);
  final exitNumber = exitNumbers.length == 1 ? exitNumbers.single : null;
  return ManeuverInstruction(
    maneuver: entry,
    kind: ManeuverKind.roundabout,
    direction: direction,
    text: _instructionText(
      kind: ManeuverKind.roundabout,
      direction: direction,
      exitNumber: exitNumber,
    ),
    standaloneText: _instructionText(
      kind: ManeuverKind.roundabout,
      direction: direction,
      exitNumber: exitNumber,
      namesJunction: true,
    ),
    exitNumber: exitNumber,
    // The road the rider ends up on is named by the step that leaves the ring.
    roadName: last.name ?? entry.name,
    roadRef: last.ref ?? entry.ref,
    lanes: entry.lanes,
    leftHandTraffic: _leftHandTraffic(entry.drivingSide),
    stepCount: group.length,
  );
}

/// Direction the rider leaves a roundabout, from the manoeuvre's own geometry.
///
/// The engine's entry modifier describes joining the ring and its exit modifier
/// describes leaving it relative to travel around the ring, so neither states
/// the direction through the junction. The heading before joining compared with
/// the heading on the road taken does.
ManeuverDirection _ringExitDirection({
  required RouteManeuver entry,
  required RouteManeuver? exit,
  required RouteManeuver? follower,
}) {
  // A small roundabout the engine reports as a plain turn does carry the turn
  // direction in its own modifier.
  if (entry.type.trim().toLowerCase() == 'roundabout turn') {
    final modifier = _directionFromModifier(entry.modifier);
    if (modifier.isStated) return modifier;
  }
  final approach = entry.bearingBeforeDegrees;
  if (approach == null) return ManeuverDirection.unstated;
  // The step that leaves the ring reports the heading on the road taken.
  var departure = exit?.bearingAfterDegrees;
  if (departure == null &&
      exit == null &&
      follower != null &&
      _distance(entry.position, follower.position) <= _exitBearingReachMeters) {
    // Without a separate exit step the ring traversal ends at the next step,
    // whose approach heading is the heading on the road leaving the ring.
    departure = follower.bearingBeforeDegrees;
  }
  if (departure == null) return ManeuverDirection.unstated;
  return _directionFromTurnDegrees(
    _signedBearingDelta(approach, departure),
    straightBandDegrees: _roundaboutStraightBandDegrees,
  );
}

ManeuverInstruction _simpleInstruction(RouteManeuver maneuver) {
  final kind = _kindFor(maneuver.type);
  final reported = _maneuverDirection(maneuver);
  final direction = switch (kind) {
    // Neither end of the route is a turn, and the engine's modifier there
    // describes which side the destination is on rather than a direction to
    // ride, so no direction is claimed.
    ManeuverKind.arrive || ManeuverKind.depart => ManeuverDirection.straight,
    // Staying on the same road through a name change or a notification is
    // riding straight on even when the engine reports no direction change.
    ManeuverKind.continueAhead when !reported.isStated =>
      ManeuverDirection.straight,
    _ => reported,
  };
  return ManeuverInstruction(
    maneuver: maneuver,
    kind: kind,
    direction: direction,
    text: _instructionText(kind: kind, direction: direction),
    roadName: maneuver.name,
    roadRef: maneuver.ref,
    lanes: maneuver.lanes,
    leftHandTraffic: _leftHandTraffic(maneuver.drivingSide),
  );
}

/// Direction of an ordinary manoeuvre.
///
/// The engine's modifier is the documented direction change, so it is preferred;
/// the manoeuvre's own bearings cover steps that carry no modifier.
ManeuverDirection _maneuverDirection(RouteManeuver maneuver) {
  final modifier = _directionFromModifier(maneuver.modifier);
  if (modifier.isStated) return modifier;
  final before = maneuver.bearingBeforeDegrees;
  final after = maneuver.bearingAfterDegrees;
  if (before == null || after == null) return ManeuverDirection.unstated;
  return _directionFromTurnDegrees(_signedBearingDelta(before, after));
}

ManeuverKind _kindFor(String type) => switch (type.trim().toLowerCase()) {
  'depart' => ManeuverKind.depart,
  'arrive' => ManeuverKind.arrive,
  'roundabout' ||
  'rotary' ||
  'roundabout turn' ||
  'exit roundabout' ||
  'exit rotary' => ManeuverKind.roundabout,
  'end of road' => ManeuverKind.endOfRoad,
  'merge' => ManeuverKind.merge,
  'fork' => ManeuverKind.fork,
  'on ramp' || 'ramp' => ManeuverKind.onRamp,
  'off ramp' => ManeuverKind.offRamp,
  'use lane' => ManeuverKind.useLane,
  'new name' || 'continue' || 'notification' => ManeuverKind.continueAhead,
  // Anything the engine adds later is still a decision with a direction.
  _ => ManeuverKind.turn,
};

bool _isRingEntry(String type) {
  final normalized = type.trim().toLowerCase();
  return normalized == 'roundabout' || normalized == 'rotary';
}

bool _isRingExit(String type) {
  final normalized = type.trim().toLowerCase();
  return normalized == 'exit roundabout' || normalized == 'exit rotary';
}

bool? _leftHandTraffic(String? drivingSide) =>
    switch (drivingSide?.trim().toLowerCase()) {
      'left' => true,
      'right' => false,
      _ => null,
    };

ManeuverDirection _directionFromModifier(String? modifier) {
  final normalized = modifier?.trim().toLowerCase().replaceAll('-', '');
  return switch (normalized) {
    'sharp left' => ManeuverDirection.sharpLeft,
    'left' => ManeuverDirection.left,
    'slight left' => ManeuverDirection.slightLeft,
    'straight' => ManeuverDirection.straight,
    'slight right' => ManeuverDirection.slightRight,
    'right' => ManeuverDirection.right,
    'sharp right' => ManeuverDirection.sharpRight,
    'uturn' => ManeuverDirection.uTurn,
    _ => ManeuverDirection.unstated,
  };
}

/// The straight band for an ordinary junction, where the roads meet directly.
const _straightBandDegrees = 20.0;

/// The straight band for a roundabout exit.
///
/// Wider, because a roundabout's arms are offset by the ring rather than meeting
/// at a point: riding straight across a four-arm roundabout routinely shows an
/// entry-to-exit heading change of 25 to 35 degrees purely from that offset. At
/// the ordinary 20 degree band, crossing the A46 from the A420 was announced and
/// drawn as a slight right, which is a junction the rider has been told to do
/// something at that they do not in fact have to do.
///
/// It stops short of 45, which is where a genuine slight right begins to be a
/// real change of direction rather than the ring's geometry.
const _roundaboutStraightBandDegrees = 38.0;

/// Buckets a heading change into a direction a rider can act on.
///
/// The straight band is deliberately wide so a gentle curve on the road taken
/// is not announced as a turn.
ManeuverDirection _directionFromTurnDegrees(
  double degrees, {
  double straightBandDegrees = _straightBandDegrees,
}) {
  final magnitude = degrees.abs();
  if (magnitude <= straightBandDegrees) return ManeuverDirection.straight;
  if (magnitude > 160) return ManeuverDirection.uTurn;
  final right = degrees > 0;
  if (magnitude <= 60) {
    return right ? ManeuverDirection.slightRight : ManeuverDirection.slightLeft;
  }
  if (magnitude <= 120) {
    return right ? ManeuverDirection.right : ManeuverDirection.left;
  }
  return right ? ManeuverDirection.sharpRight : ManeuverDirection.sharpLeft;
}

/// Signed heading change in degrees; positive is clockwise (to the right).
double _signedBearingDelta(double before, double after) =>
    ((after - before + 540) % 360) - 180;

String _instructionText({
  required ManeuverKind kind,
  required ManeuverDirection direction,
  int? exitNumber,
  bool namesJunction = false,
}) {
  final label = direction.label;
  switch (kind) {
    case ManeuverKind.depart:
      return 'Start off';
    case ManeuverKind.arrive:
      return 'Arrive at the destination';
    case ManeuverKind.roundabout:
      final ordinal = exitNumber == null || exitNumber <= 0
          ? null
          : _ordinal(exitNumber);
      // Beside the banner and the all-turns list is a drawn roundabout, so the
      // wording there leaves the junction to the symbol and states only what a
      // rider still needs: which exit, and which way it goes. Where no symbol
      // is shown - a screen reader, CarPlay, Android Auto - it is named.
      if (ordinal != null && direction.isStated) {
        return namesJunction
            ? 'Roundabout, $ordinal exit, $label'
            : '$ordinal exit, $label';
      }
      if (ordinal != null) {
        return namesJunction
            ? 'Roundabout, take the $ordinal exit'
            : 'Take the $ordinal exit';
      }
      if (direction == ManeuverDirection.uTurn) {
        return namesJunction ? 'Roundabout, U-turn' : 'Make a U-turn';
      }
      if (direction.isStated) {
        return namesJunction
            ? 'Roundabout, take the exit $label'
            : 'Take the exit $label';
      }
      // Neither an exit number nor a direction was reported, so nothing is
      // claimed about either. The symbol says which junction it is.
      return namesJunction
          ? 'Roundabout ahead, follow the route'
          : 'Follow the route';
    case ManeuverKind.turn:
    case ManeuverKind.endOfRoad:
    case ManeuverKind.merge:
    case ManeuverKind.fork:
    case ManeuverKind.onRamp:
    case ManeuverKind.offRamp:
    case ManeuverKind.useLane:
    case ManeuverKind.continueAhead:
      break;
  }
  // Turning back is the same instruction whatever the junction looks like, and
  // the wording never claims a side: which way round it is ridden depends on the
  // driving side, not on the route.
  if (direction == ManeuverDirection.uTurn) return 'Make a U-turn';
  switch (kind) {
    case ManeuverKind.endOfRoad:
      return switch (direction) {
        ManeuverDirection.unstated => 'End of the road, follow the route',
        ManeuverDirection.straight =>
          'At the end of the road, continue straight on',
        _ => 'At the end of the road, turn $label',
      };
    case ManeuverKind.merge:
      return direction.isStated ? 'Merge $label' : 'Merge with traffic';
    case ManeuverKind.fork:
      return switch (direction) {
        ManeuverDirection.unstated => 'Fork ahead, follow the route',
        ManeuverDirection.straight => 'At the fork, continue straight on',
        _ => 'At the fork, keep $label',
      };
    case ManeuverKind.onRamp:
      return direction.isStated
          ? 'Take the slip road $label'
          : 'Take the slip road';
    case ManeuverKind.offRamp:
      return direction.isStated
          ? 'Take the exit slip road $label'
          : 'Take the exit slip road';
    case ManeuverKind.useLane:
      return switch (direction) {
        ManeuverDirection.unstated => 'Stay in your lane',
        ManeuverDirection.straight => 'Continue straight on',
        _ => 'Use the $label lane',
      };
    case ManeuverKind.continueAhead:
      return direction == ManeuverDirection.straight
          ? 'Continue straight on'
          : 'Continue $label';
    case ManeuverKind.turn:
    case ManeuverKind.depart:
    case ManeuverKind.arrive:
    case ManeuverKind.roundabout:
      return switch (direction) {
        ManeuverDirection.unstated => 'Junction ahead, follow the route',
        ManeuverDirection.straight => 'Continue straight on',
        _ => 'Turn $label',
      };
  }
}

String _ordinal(int value) {
  final tens = value % 100;
  if (tens >= 11 && tens <= 13) return '${value}th';
  return switch (value % 10) {
    1 => '${value}st',
    2 => '${value}nd',
    3 => '${value}rd',
    _ => '${value}th',
  };
}

List<GeoPoint> _primaryPath(List<RoutePath> paths) {
  var selected = paths.first.points;
  var selectedLength = _pathLength(selected);
  for (final path in paths.skip(1)) {
    final length = _pathLength(path.points);
    if (length > selectedLength) {
      selected = path.points;
      selectedLength = length;
    }
  }
  return selected;
}

double _pathLength(List<GeoPoint> points) {
  var total = 0.0;
  for (var index = 0; index < points.length - 1; index += 1) {
    total += _distance(points[index], points[index + 1]);
  }
  return total;
}

_Projection _project(GeoPoint point, List<GeoPoint> path) {
  var nearestDistance = double.infinity;
  var nearestProgress = 0.0;
  var travelled = 0.0;
  for (var index = 0; index < path.length - 1; index += 1) {
    final start = path[index];
    final end = path[index + 1];
    final segment = _projectToSegment(point, start, end);
    final length = _distance(start, end);
    if (segment.distanceMeters < nearestDistance) {
      nearestDistance = segment.distanceMeters;
      nearestProgress = travelled + length * segment.fraction;
    }
    travelled += length;
  }
  return _Projection(
    distanceMeters: nearestDistance,
    progressMeters: nearestProgress,
  );
}

_SegmentProjection _projectToSegment(
  GeoPoint point,
  GeoPoint start,
  GeoPoint end,
) {
  final referenceLatitude = _radians(point.latitude);
  final startX =
      _radians(_longitudeDelta(start.longitude - point.longitude)) *
      math.cos(referenceLatitude) *
      _earthRadiusMeters;
  final startY = _radians(start.latitude - point.latitude) * _earthRadiusMeters;
  final endX =
      _radians(_longitudeDelta(end.longitude - point.longitude)) *
      math.cos(referenceLatitude) *
      _earthRadiusMeters;
  final endY = _radians(end.latitude - point.latitude) * _earthRadiusMeters;
  final deltaX = endX - startX;
  final deltaY = endY - startY;
  final lengthSquared = deltaX * deltaX + deltaY * deltaY;
  if (lengthSquared == 0) {
    return _SegmentProjection(
      distanceMeters: math.sqrt(startX * startX + startY * startY),
      fraction: 0,
    );
  }
  final fraction = (-(startX * deltaX + startY * deltaY) / lengthSquared).clamp(
    0.0,
    1.0,
  );
  final nearestX = startX + fraction * deltaX;
  final nearestY = startY + fraction * deltaY;
  return _SegmentProjection(
    distanceMeters: math.sqrt(nearestX * nearestX + nearestY * nearestY),
    fraction: fraction,
  );
}

double _distance(GeoPoint first, GeoPoint second) {
  final latitude1 = _radians(first.latitude);
  final latitude2 = _radians(second.latitude);
  final latitudeDelta = latitude2 - latitude1;
  final longitudeDelta = _radians(
    _longitudeDelta(second.longitude - first.longitude),
  );
  final a =
      math.pow(math.sin(latitudeDelta / 2), 2) +
      math.cos(latitude1) *
          math.cos(latitude2) *
          math.pow(math.sin(longitudeDelta / 2), 2);
  return _earthRadiusMeters * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}

String _sentenceCase(String value) {
  final words = value.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (words.isEmpty) return 'Continue';
  return '${words[0].toUpperCase()}${words.substring(1)}';
}

double _radians(double degrees) => degrees * math.pi / 180;

double _longitudeDelta(double delta) => ((delta + 540) % 360) - 180;

const _earthRadiusMeters = 6371008.8;

class _Projection {
  const _Projection({
    required this.distanceMeters,
    required this.progressMeters,
  });

  final double distanceMeters;
  final double progressMeters;
}

class _SegmentProjection {
  const _SegmentProjection({
    required this.distanceMeters,
    required this.fraction,
  });

  final double distanceMeters;
  final double fraction;
}
