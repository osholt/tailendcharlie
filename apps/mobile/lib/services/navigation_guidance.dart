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
    this.departureBearingDegrees,
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

  /// The heading on the road taken, where the direction was read from the
  /// junction's geometry rather than from a modifier.
  ///
  /// Only a roundabout sets it, and only a roundabout needs it: its direction
  /// comes from the approach bearing compared with *this*, across two merged
  /// steps, so the entry manoeuvre's own `bearingAfter` - the pair every other
  /// manoeuvre uses - is not the number the app reasoned from. Keeping it is
  /// what lets a captured turn detail explain the instruction a rider saw
  /// instead of showing a heading change that was never used (#360).
  final double? departureBearingDegrees;

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

/// Why the live guidance surface is showing what it is showing.
///
/// Keeping this state separate from [NavigationGuidance] prevents a temporary
/// loss of position, an off-route fix, or the end of the manoeuvre list from
/// silently turning the banner into an empty part of the screen (#254).
enum NavigationGuidanceState {
  noRoute,
  waitingForLocation,
  noManeuvers,

  /// The route was meant to be routed and is not.
  ///
  /// Distinct from [noManeuvers] because the two need different things from a
  /// rider: an imported track without prompts is working as intended and can be
  /// followed, while this one lost its directions to a failure and can be made
  /// to work again (#303).
  routingUnfinished,
  offRoute,
  active,
  complete,
}

class NavigationGuidanceAssessment {
  const NavigationGuidanceAssessment({
    required this.state,
    required this.message,
    this.guidance,
  });

  const NavigationGuidanceAssessment.noRoute()
    : state = NavigationGuidanceState.noRoute,
      message = 'No route is loaded.',
      guidance = null;

  final NavigationGuidanceState state;
  final String message;
  final NavigationGuidance? guidance;

  bool get isVisible => state != NavigationGuidanceState.noRoute;
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
    this.closeManeuverSpacingMeters = 300,
  });

  final double maximumDistanceFromRouteMeters;
  final double passedToleranceMeters;
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

  /// Shown when the route has turnable geometry but no turn instructions.
  ///
  /// The old wording for this was "Turn guidance is unavailable for this route",
  /// which a rider read as the route having failed - it was reported that way from
  /// a ride where the line on the map was perfectly good (#303). The route is
  /// followable; only the prompts are missing, and saying so is the difference
  /// between a rider carrying on and a rider stopping to work out what broke.
  ///
  /// The choice to road-match an imported track is made before route review,
  /// where the original can be preserved and compared safely (#325). This
  /// riding-state message stays concise and truthful for someone who chose to
  /// follow the original line.
  static const noTurnInstructionsMessage =
      'No turn prompts for this route — follow the line on the map.';

  /// Shown when there is no line to follow at all, which is a different problem:
  /// the rider has nothing, rather than something without prompts. These two
  /// shared one message until #303, which made a followable route and a broken
  /// one indistinguishable.
  static const noRouteLineMessage =
      'This route has no path to follow. Choose or import it again.';

  /// Shown when routing was meant to happen for this route and did not.
  ///
  /// `RouteGeometryEnricher` converts a `RoutePathKind.route` path into a
  /// `track` when the routing engine answers, and leaves it a `route` when the
  /// request fails. A surviving `route` path with no manoeuvres is therefore a
  /// routing failure that outlived the import it happened during: the enricher
  /// returns a warning, but nothing carried it onto the route, so by riding
  /// time the rider saw the same words as an imported track (#303).
  ///
  /// They are not the same. One is working as intended and can be followed; the
  /// other can be made to work again, and only this wording tells a rider which
  /// they have.
  static const routingUnfinishedMessage =
      'Directions could not be built for this route — the line is the raw '
      'import. Re-import it to try again.';

  NavigationGuidance? plan({
    required ImportedRoute? route,
    required GeoPoint? position,
    required double progressMeters,
  }) => assess(
    route: route,
    position: position,
    progressMeters: progressMeters,
  ).guidance;

  NavigationGuidanceAssessment assess({
    required ImportedRoute? route,
    required GeoPoint? position,
    required double progressMeters,
  }) {
    if (route == null) {
      return const NavigationGuidanceAssessment.noRoute();
    }
    if (position == null) {
      return const NavigationGuidanceAssessment(
        state: NavigationGuidanceState.waitingForLocation,
        message: 'Waiting for GPS — directions will resume automatically.',
      );
    }
    if (route.paths.isEmpty) {
      return const NavigationGuidanceAssessment(
        state: NavigationGuidanceState.noManeuvers,
        message: noRouteLineMessage,
      );
    }
    if (route.maneuvers.isEmpty) {
      // A path still marked `route` was never turned into road geometry, which
      // only happens when the routing request for it failed.
      final unrouted = route.paths.any(
        (path) => path.kind == RoutePathKind.route && path.points.length >= 2,
      );
      return NavigationGuidanceAssessment(
        state: unrouted
            ? NavigationGuidanceState.routingUnfinished
            : NavigationGuidanceState.noManeuvers,
        message: unrouted
            ? routingUnfinishedMessage
            : noTurnInstructionsMessage,
      );
    }
    final path = _primaryPath(route.paths);
    if (path.length < 2) {
      return const NavigationGuidanceAssessment(
        state: NavigationGuidanceState.noManeuvers,
        message: noRouteLineMessage,
      );
    }
    final riderProjection = _project(position, path);
    if (riderProjection.distanceMeters > maximumDistanceFromRouteMeters) {
      return const NavigationGuidanceAssessment(
        state: NavigationGuidanceState.offRoute,
        message: 'Off route — finding directions back.',
      );
    }

    final candidates =
        <({ManeuverInstruction instruction, double remaining})>[];
    for (final step in instructions(route)) {
      if (step.distanceFromRouteMeters > maximumDistanceFromRouteMeters) {
        continue;
      }
      final remaining = step.distanceFromStartMeters - progressMeters;
      if (remaining < -passedToleranceMeters) continue;
      candidates.add((instruction: step.instruction, remaining: remaining));
    }
    if (candidates.isEmpty) {
      return const NavigationGuidanceAssessment(
        state: NavigationGuidanceState.complete,
        message: 'No more turns — continue to the destination.',
      );
    }
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
    return NavigationGuidanceAssessment(
      state: NavigationGuidanceState.active,
      message: 'Turn guidance is active.',
      guidance: NavigationGuidance(
        maneuver: next.instruction.maneuver,
        instruction: next.instruction,
        distanceMeters: math.max(0, next.remaining),
        followingManeuver: showFollowing
            ? following.instruction.maneuver
            : null,
        followingInstruction: showFollowing ? following.instruction : null,
        followingDistanceMeters: showFollowing
            ? math.max(0, followingSpacing)
            : null,
      ),
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
  final departure = _ringDepartureBearing(
    entry: entry,
    exit: exit,
    follower: follower,
  );
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
    departureBearingDegrees: departure,
  );
}

/// The heading on the road taken as the rider leaves the ring.
///
/// Split out of [_ringExitDirection] so the number and the direction read from
/// it cannot come from different places, and so a captured turn detail can show
/// the pair the direction was actually derived from.
double? _ringDepartureBearing({
  required RouteManeuver entry,
  required RouteManeuver? exit,
  required RouteManeuver? follower,
}) {
  final departure = exit?.bearingAfterDegrees;
  if (departure != null) return departure;
  if (exit == null &&
      follower != null &&
      _distance(entry.position, follower.position) <= _exitBearingReachMeters) {
    return follower.bearingBeforeDegrees;
  }
  return null;
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
  final before = maneuver.bearingBeforeDegrees;
  final after = maneuver.bearingAfterDegrees;
  final geometry = before == null || after == null
      ? ManeuverDirection.unstated
      : _directionFromTurnDegrees(_signedBearingDelta(before, after));
  if (!modifier.isStated) return geometry;
  if (!geometry.isStated) return modifier;
  // The modifier usually deserves the deference: it encodes which branch of a
  // junction the route takes, which the two bearings alone cannot express, and
  // across a sweep of 359 real steps the two agreed or sat one bucket apart 93%
  // of the time. Disagreeing by one bucket is a judgement call inside tolerance
  // - a 45 degree turn called `left` where this code would say `slight left` -
  // and the engine keeps it.
  //
  // A wider gap is not a judgement call. The same sweep found the engine
  // calling a 21 degree deviation `sharp right`, a 93 degree turn a `uturn`,
  // and an 82 degree left `straight`. A rider rides the bearings, so past one
  // bucket they win. #302 was reported as an ordinary 90 degree right announced
  // as a sharp right, which is this shape exactly.
  return _bucketDistance(modifier, geometry) > 1 ? geometry : modifier;
}

/// How far apart two directions sit on the straight-ahead-to-hard-over scale.
///
/// A U-turn has no side in this app, so it is compared by how hard over it is
/// rather than by which way: it sits one step beyond a sharp turn on either
/// side. Comparing it on the signed scale would make a U-turn and a sharp
/// *left* look seven buckets apart while a U-turn and a sharp *right* looked
/// like neighbours, which is the same physical disagreement mirrored.
int _bucketDistance(ManeuverDirection first, ManeuverDirection second) {
  final a = _bucketOrdinal(first);
  final b = _bucketOrdinal(second);
  if (first == ManeuverDirection.uTurn || second == ManeuverDirection.uTurn) {
    final other = first == ManeuverDirection.uTurn ? b : a;
    return (_bucketOrdinal(ManeuverDirection.uTurn) - other.abs()).abs();
  }
  return (a - b).abs();
}

int _bucketOrdinal(ManeuverDirection direction) => switch (direction) {
  ManeuverDirection.sharpLeft => -3,
  ManeuverDirection.left => -2,
  ManeuverDirection.slightLeft => -1,
  ManeuverDirection.straight || ManeuverDirection.unstated => 0,
  ManeuverDirection.slightRight => 1,
  ManeuverDirection.right => 2,
  ManeuverDirection.sharpRight => 3,
  ManeuverDirection.uTurn => 4,
};

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

/// Whether the ring should be drawn for left-hand traffic, from what the engine
/// said — and deliberately **not** believing it when it says right.
///
/// Two screenshots from the 10 August ride settle why. A "3rd exit, right" was
/// drawn as a short quarter-turn arc. Keeping left, that exit is three quarters
/// of the way round and draws 270 degrees; a quarter is what keeping *right*
/// draws. So the engine reported `right` for a UK roundabout and the symbol
/// mirrored itself to match, while the exit number and the direction word stayed
/// correct — which is exactly why it read as a drawing fault rather than a data
/// one (#427).
///
/// `right` is therefore treated as unstated, and an unstated driving side draws
/// clockwise. The reviewed mini-roundabout catalogue still states a rotation
/// where it has one, and says clockwise for 11,482 of the 11,487 it covers.
///
/// **This is a bet on where the app is used**, and it is the wrong bet on a
/// European tour: a genuine right-hand-traffic roundabout will now be drawn
/// left-hand. The right answer is to resolve the driving side from where the
/// route *is* rather than from a per-step claim, which is #408's original
/// proposal and is not built. Recorded so the next person meets a decision
/// rather than a puzzle.
bool? _leftHandTraffic(String? drivingSide) =>
    switch (drivingSide?.trim().toLowerCase()) {
      'left' => true,
      _ => null,
    };

/// The direction a routing engine's `modifier` states, or
/// [ManeuverDirection.unstated] where it says nothing this app understands.
///
/// Public so a manoeuvre can be shown the engine's own words beside what the
/// app made of them (#302): a modifier that arrives as `unstated` here is the
/// difference between the app repeating the engine and the app working the
/// direction out from geometry, and that is the first thing worth knowing
/// about a turn that came out wrong.
ManeuverDirection directionFromModifier(String? modifier) =>
    _directionFromModifier(modifier);

ManeuverDirection _directionFromModifier(String? modifier) {
  // A hyphen is a separator, not a character to delete. This used to
  // `replaceAll('-', '')`, which is right for `u-turn` and wrong for every
  // other modifier: `sharp-right` became `sharpright`, matched nothing, and
  // returned `unstated`, so an engine that hyphenates silently lost its stated
  // direction and fell through to geometry. Splitting on either separator
  // handles both, and `uturn` collapses because it is one word either way.
  final normalized = modifier
      ?.trim()
      .toLowerCase()
      .split(RegExp(r'[\s-]+'))
      .where((word) => word.isNotEmpty)
      .join(' ');
  return switch (normalized) {
    'sharp left' => ManeuverDirection.sharpLeft,
    'left' => ManeuverDirection.left,
    'slight left' => ManeuverDirection.slightLeft,
    'straight' => ManeuverDirection.straight,
    'slight right' => ManeuverDirection.slightRight,
    'right' => ManeuverDirection.right,
    'sharp right' => ManeuverDirection.sharpRight,
    'uturn' || 'u turn' => ManeuverDirection.uTurn,
    _ => ManeuverDirection.unstated,
  };
}

/// The straight band for an ordinary junction, where the roads meet directly.
const _straightBandDegrees = 20.0;

/// The straight band for an ordinary junction. Public so the boundaries can be
/// asserted where they are declared rather than restated as literals (#302).
const maneuverStraightBandDegrees = _straightBandDegrees;

/// The straight band for a roundabout exit; see [_roundaboutStraightBandDegrees].
const maneuverRoundaboutStraightBandDegrees = _roundaboutStraightBandDegrees;

/// How far the rider's heading turns through [maneuver], positive clockwise,
/// or null where the engine reported no bearings for it.
///
/// This is the number #302 asks to be captured before any threshold is moved:
/// it is what [directionFromHeadingChange] buckets, so a turn that came out
/// with the wrong severity is either this number being wrong or the buckets
/// being wrong, and the two have different fixes.
double? maneuverHeadingChangeDegrees(RouteManeuver maneuver) {
  final before = maneuver.bearingBeforeDegrees;
  final after = maneuver.bearingAfterDegrees;
  if (before == null || after == null) return null;
  return _signedBearingDelta(before, after);
}

/// The signed heading change between two bearings, for callers that hold the
/// pair themselves - a roundabout reads its direction across two merged steps
/// rather than from one manoeuvre's own bearings.
double maneuverHeadingChangeBetween(double before, double after) =>
    _signedBearingDelta(before, after);

/// Buckets a signed heading change into a direction. See
/// [_directionFromTurnDegrees].
ManeuverDirection directionFromHeadingChange(
  double degrees, {
  double straightBandDegrees = _straightBandDegrees,
}) => _directionFromTurnDegrees(
  degrees,
  straightBandDegrees: straightBandDegrees,
);

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
