import 'dart:math' as math;

import '../domain/imported_route.dart';

enum MarkerPlanPointKind { likelyMarker, safetyReview, musterPoint }

/// Where a marking position came from: the detector, or a person who saw the
/// detector miss a junction and added it.
enum MarkerPlanPointSource { detected, manual }

class MarkerPlanningRules {
  const MarkerPlanningRules({
    this.markStraightTurns = false,
    this.markRoundabouts = true,
    this.roundaboutEntryAndExit = false,
    this.multiLaneRoundaboutThreshold = 3,
    this.onRouteToleranceMeters = 30,
    this.minimumRouteTurnDegrees = 20,
    this.maximumRouteTurnDegrees = 150,
    this.routeTurnWindowMeters = 30,
  });

  final bool markStraightTurns;
  final bool markRoundabouts;
  final bool roundaboutEntryAndExit;
  final int multiLaneRoundaboutThreshold;

  /// How far a manoeuvre may lie from the line the group will actually ride
  /// before it is treated as belonging to some other road.
  final double onRouteToleranceMeters;

  /// How far the ridden line must change heading at a manoeuvre before a rider
  /// could plausibly miss it.
  final double minimumRouteTurnDegrees;

  /// Above this the ridden line has reversed: the group is coming back out of a
  /// no-through road, not choosing between branches.
  final double maximumRouteTurnDegrees;

  /// The distance either side of a manoeuvre over which the ridden line's
  /// heading change is measured, when the route engine reports no bearings.
  final double routeTurnWindowMeters;
}

class MarkerPlanPoint {
  const MarkerPlanPoint({
    required this.id,
    required this.position,
    required this.kind,
    required this.label,
    this.detail,
    this.source = MarkerPlanPointSource.detected,
  });

  final String id;
  final GeoPoint position;
  final MarkerPlanPointKind kind;
  final String label;
  final String? detail;
  final MarkerPlanPointSource source;

  MarkerReviewPoint toReviewPoint() =>
      MarkerReviewPoint(id: id, position: position, label: label);
}

class RouteMarkerPlan {
  const RouteMarkerPlan({required this.points, this.rejectedPoints = const []});

  final List<MarkerPlanPoint> points;

  /// Positions the detector suggested and a person rejected. Kept so a review
  /// surface can offer the rejection back rather than hiding it for good.
  final List<MarkerPlanPoint> rejectedPoints;

  List<MarkerPlanPoint> get likelyMarkers => points
      .where((point) => point.kind == MarkerPlanPointKind.likelyMarker)
      .toList(growable: false);

  List<MarkerPlanPoint> get safetyReviews => points
      .where((point) => point.kind == MarkerPlanPointKind.safetyReview)
      .toList(growable: false);

  List<MarkerPlanPoint> get musterPoints => points
      .where((point) => point.kind == MarkerPlanPointKind.musterPoint)
      .toList(growable: false);
}

/// A junction the route passes that the plan does not suggest marking, offered
/// so a person can add one the detector missed.
class MarkerPlanCandidate {
  const MarkerPlanCandidate({
    required this.id,
    required this.position,
    required this.label,
  });

  final String id;
  final GeoPoint position;
  final String label;

  MarkerReviewPoint toReviewPoint() =>
      MarkerReviewPoint(id: id, position: position, label: label);
}

/// Produces a deliberately conservative pre-ride marker estimate.
///
/// It uses route-engine manoeuvres rather than bends in GPX geometry. A safety
/// review point is never counted as a suggested place to stop: the ride leader
/// must inspect the junction and choose a legal, visible place away from live
/// lanes.
///
/// ## What a suggestion is scored on (#179)
///
/// Marking exists so nobody misses a turn **the group is taking**. A road the
/// route does not use needs no marker, however junction-like it looks: a
/// cul-de-sac mouth is topologically a junction, so scoring on how many roads
/// meet cannot tell a turn a rider might take from one nobody will. It scored a
/// tester a green dot at the end of a no-through road.
///
/// So the manoeuvre type is no longer sufficient on its own. A manoeuvre earns a
/// suggestion only when the group's own ridden line is ambiguous there:
///
/// 1. **On the ridden line.** The manoeuvre must lie within
///    [MarkerPlanningRules.onRouteToleranceMeters] of the primary ridden path -
///    the longest one, the same path `RouteProgressTracker` measures progress
///    against. `RouteGeometryEnricher` accumulates manoeuvres for every path in
///    the file, and exports commonly carry the same journey twice (#180), so
///    manoeuvres for a road the group will not ride were being suggested.
/// 2. **The line must deviate.** The ridden line's heading must change by at
///    least [MarkerPlanningRules.minimumRouteTurnDegrees], or the engine must
///    report a genuine branch choice for the route itself - a fork, roundabout
///    or rotary. A junction the group rides straight through is what a passed
///    cul-de-sac mouth, a side road and a farm track all look like, and none of
///    them can be missed.
/// 3. **The line must not double back.** A reversal of
///    [MarkerPlanningRules.maximumRouteTurnDegrees] or more, or a `uturn`
///    modifier, means the manoeuvre is inside a no-through road. Everyone comes
///    back out the way they went in, so nothing can be missed and a marker
///    there is a rider sent to a dead end for nothing. Roundabouts and rotaries
///    are excepted: their ring geometry legitimately reverses, and riders do
///    miss exits.
///
/// Junction degree - how many roads meet - is not scored at all.
class RouteMarkerPlanAnalyzer {
  const RouteMarkerPlanAnalyzer({this.rules = const MarkerPlanningRules()});

  final MarkerPlanningRules rules;

  RouteMarkerPlan analyze(ImportedRoute route) {
    final review = route.markerReview;
    final riddenLine = primaryRiddenPath(route);
    final points = <MarkerPlanPoint>[];
    final rejected = <MarkerPlanPoint>[];

    void collect(MarkerPlanPoint point) {
      if (_isRejected(review, point.id, point.position)) {
        rejected.add(point);
      } else {
        points.add(point);
      }
    }

    for (final entry in route.maneuvers.indexed) {
      final maneuver = entry.$2;
      final type = maneuver.type.trim().toLowerCase();
      final modifier = maneuver.modifier?.trim().toLowerCase() ?? '';
      final id = 'maneuver-${entry.$1}';
      final circular = type == 'roundabout' || type == 'rotary';

      // Gate 1. A manoeuvre off the line the group rides belongs to another
      // road, so nobody on this ride can miss it.
      if (!_isOnRiddenLine(maneuver.position, riddenLine)) continue;

      if (const {'merge', 'on ramp', 'off ramp'}.contains(type)) {
        collect(
          MarkerPlanPoint(
            id: id,
            position: maneuver.position,
            kind: MarkerPlanPointKind.safetyReview,
            label: _safetyLabel(type),
            detail:
                'Do not stop on the live carriageway or slip road. The leader '
                'must choose a legal regrouping or marker position elsewhere.',
          ),
        );
        continue;
      }

      final turn = _riddenTurnDegrees(maneuver, riddenLine);

      // Gate 3. A doubling-back is a no-through road, not a choice of branch.
      if (!circular && _doublesBack(modifier, turn)) continue;

      if (circular) {
        if (!rules.markRoundabouts) continue;
        final exit = maneuver.exitNumber;
        final laneCount = maneuver.lanes.length;
        final multiLane = laneCount >= rules.multiLaneRoundaboutThreshold;
        collect(
          MarkerPlanPoint(
            id: id,
            position: maneuver.position,
            kind: multiLane
                ? MarkerPlanPointKind.safetyReview
                : MarkerPlanPointKind.likelyMarker,
            label: exit == null
                ? 'Roundabout exit marker'
                : 'Roundabout exit $exit marker',
            detail: multiLane
                ? 'Large multi-lane roundabout: inspect a safe, legal position '
                      'after the required exit rather than stopping at entry.'
                : rules.roundaboutEntryAndExit
                ? 'Rules request entry and exit marking; confirm both safe '
                      'positions during the briefing.'
                : 'Default rule: mark the required exit only.',
          ),
        );
        continue;
      }

      final straight = modifier.isEmpty || modifier == 'straight';
      final decisionType = const {'turn', 'fork', 'end of road'}.contains(type);
      // A fork is a branch choice whichever way the route goes through it: the
      // carriageway splits and a following rider has to pick a side. That is
      // the definition of a junction where straight on is not clear, and it was
      // being dropped here before the fork exemption below could ever apply -
      // so the one shape of junction most worth marking when the route
      // continues ahead was the one shape never suggested (#366).
      //
      // [MarkerPlanningRules.markStraightTurns] is about ordinary junctions the
      // group rides straight through - a side road, a farm track - which is a
      // different question and keeps its answer.
      final branchesRegardless = type == 'fork';
      if (!decisionType ||
          (straight && !branchesRegardless && !rules.markStraightTurns)) {
        continue;
      }

      // Gate 2. Either the ridden line deviates, or the engine reports that the
      // route itself had a branch to choose between.
      if (type != 'fork' && !_lineDeviates(turn)) continue;

      collect(
        MarkerPlanPoint(
          id: id,
          position: maneuver.position,
          kind: MarkerPlanPointKind.likelyMarker,
          label: _decisionLabel(type, modifier),
        ),
      );
    }

    for (final entry in route.waypoints.indexed) {
      final waypoint = entry.$2;
      final searchable = [
        waypoint.name,
        waypoint.description,
        waypoint.symbol,
      ].whereType<String>().join(' ').toLowerCase();
      if (!searchable.contains('muster') &&
          !searchable.contains('regroup') &&
          !searchable.contains('re-group')) {
        continue;
      }
      collect(
        MarkerPlanPoint(
          id: 'muster-${entry.$1}',
          position: waypoint.point,
          kind: MarkerPlanPointKind.musterPoint,
          label: waypoint.name?.trim().isNotEmpty == true
              ? waypoint.name!.trim()
              : 'Muster point',
          detail: 'Planned regrouping point; not a ride stop or marker role.',
        ),
      );
    }

    // A person who saw the detector miss a junction gets the last word, so an
    // added position is never re-filtered by the gates that lost it.
    for (final added in review.added) {
      points.add(
        MarkerPlanPoint(
          id: added.id,
          position: added.position,
          kind: MarkerPlanPointKind.likelyMarker,
          label: added.label?.trim().isNotEmpty == true
              ? added.label!.trim()
              : 'Added marker position',
          detail: 'Added during review because the detector missed it.',
          source: MarkerPlanPointSource.manual,
        ),
      );
    }

    return RouteMarkerPlan(
      points: List.unmodifiable(points),
      rejectedPoints: List.unmodifiable(rejected),
    );
  }

  /// Junctions on the ridden line that the plan does not suggest, so a person
  /// can add one the detector missed.
  ///
  /// Both sources the detectors use are offered: route-engine manoeuvres the
  /// gates above filtered out, and bends in the ridden geometry, which is all
  /// there is when a GPX file was never matched to roads.
  List<MarkerPlanCandidate> candidates(ImportedRoute route) {
    final plan = analyze(route);
    final claimed = [
      ...plan.points.map((point) => point.position),
      ...plan.rejectedPoints.map((point) => point.position),
    ];
    final riddenLine = primaryRiddenPath(route);
    final candidates = <MarkerPlanCandidate>[];

    void offer(String id, GeoPoint position, String label) {
      for (final existing in claimed) {
        if (_distanceMeters(existing, position) <=
            rules.onRouteToleranceMeters) {
          return;
        }
      }
      for (final existing in candidates) {
        if (_distanceMeters(existing.position, position) <=
            rules.onRouteToleranceMeters) {
          return;
        }
      }
      claimed.add(position);
      candidates.add(
        MarkerPlanCandidate(id: id, position: position, label: label),
      );
    }

    for (final entry in route.maneuvers.indexed) {
      final maneuver = entry.$2;
      if (!_isOnRiddenLine(maneuver.position, riddenLine)) continue;
      final type = maneuver.type.trim().toLowerCase();
      final modifier = maneuver.modifier?.trim().toLowerCase() ?? '';
      if (type == 'depart' || type == 'arrive') continue;
      final label = _candidateLabel(type, modifier);
      offer(
        'maneuver-${entry.$1}',
        maneuver.position,
        maneuver.name?.trim().isNotEmpty == true
            ? '$label · ${maneuver.name!.trim()}'
            : label,
      );
    }

    for (var index = 1; index < riddenLine.length - 1; index += 1) {
      final turn = _turnDegreesAt(riddenLine, index);
      if (!_lineDeviates(turn) || _doublesBack('', turn)) continue;
      offer(
        'geometry-$index',
        riddenLine[index],
        '${turn.round()}° bend in the route',
      );
    }

    return List.unmodifiable(candidates);
  }

  /// The path the group actually rides: the longest one.
  ///
  /// The same choice `RouteProgressTracker` and the reviewed distance make, so
  /// the marker plan cannot disagree with them about which road this ride is on.
  static List<GeoPoint> primaryRiddenPath(ImportedRoute route) {
    var longest = const <GeoPoint>[];
    var longestLength = -1.0;
    for (final path in route.paths) {
      final length = _pathLengthMeters(path.points);
      if (length > longestLength) {
        longestLength = length;
        longest = path.points;
      }
    }
    return longest;
  }

  bool _isRejected(MarkerPlanReview review, String id, GeoPoint position) =>
      review.rejectsId(id) ||
      review.rejected.any(
        (point) =>
            _distanceMeters(point.position, position) <=
            rules.onRouteToleranceMeters,
      );

  bool _isOnRiddenLine(GeoPoint position, List<GeoPoint> riddenLine) {
    // A route with a single path and no usable geometry cannot contradict a
    // manoeuvre, so the gate stays open rather than emptying the plan.
    if (riddenLine.length < 2) return true;
    return _distanceToPolylineMeters(position, riddenLine) <=
        rules.onRouteToleranceMeters;
  }

  /// Whether the ridden line changes direction enough to be missed.
  ///
  /// A null reading means neither the engine nor the geometry could say, and the
  /// gate stays open: it closes on evidence that the group rides straight
  /// through, never on the absence of evidence. Dropping a marker silently is
  /// the worse failure of the two.
  bool _lineDeviates(double? turnDegrees) =>
      turnDegrees == null || turnDegrees >= rules.minimumRouteTurnDegrees;

  bool _doublesBack(String modifier, double? turnDegrees) =>
      modifier == 'uturn' ||
      (turnDegrees != null && turnDegrees >= rules.maximumRouteTurnDegrees);

  /// How far the ridden line changes heading at [maneuver], or null when
  /// neither the engine nor the geometry can say.
  ///
  /// The engine's own bearings are preferred: they are the manoeuvre's real
  /// geometry, reported by the router that built it, and they survive geometry
  /// too sparse to measure.
  double? _riddenTurnDegrees(
    RouteManeuver maneuver,
    List<GeoPoint> riddenLine,
  ) {
    final before = maneuver.bearingBeforeDegrees;
    final after = maneuver.bearingAfterDegrees;
    if (before != null && after != null) return _smallestAngle(before, after);
    if (riddenLine.length < 3) return null;
    var nearestIndex = -1;
    var nearestDistance = double.infinity;
    for (var index = 0; index < riddenLine.length; index += 1) {
      final distance = _distanceMeters(riddenLine[index], maneuver.position);
      if (distance < nearestDistance) {
        nearestDistance = distance;
        nearestIndex = index;
      }
    }
    if (nearestIndex <= 0 || nearestIndex >= riddenLine.length - 1) return null;
    return _turnDegreesAt(riddenLine, nearestIndex);
  }

  /// The heading change of [line] at [index], measured across a window either
  /// side so a corner split over several vertices still reads as one turn.
  double _turnDegreesAt(List<GeoPoint> line, int index) {
    final vertex = line[index];
    var inboundIndex = index - 1;
    while (inboundIndex > 0 &&
        _distanceMeters(line[inboundIndex], vertex) <
            rules.routeTurnWindowMeters) {
      inboundIndex -= 1;
    }
    var outboundIndex = index + 1;
    while (outboundIndex < line.length - 1 &&
        _distanceMeters(line[outboundIndex], vertex) <
            rules.routeTurnWindowMeters) {
      outboundIndex += 1;
    }
    return _smallestAngle(
      _bearing(line[inboundIndex], vertex),
      _bearing(vertex, line[outboundIndex]),
    );
  }

  static String _safetyLabel(String type) => switch (type) {
    'off ramp' => 'Motorway or dual-carriageway exit review',
    'on ramp' => 'Motorway or dual-carriageway entry review',
    _ => 'Live-lane merge review',
  };

  /// A candidate is offered for what it is, not as an instruction: a person
  /// picking one has looked at the map, not at the routing engine's wording.
  static String _candidateLabel(String type, String modifier) {
    final where = switch (type) {
      'roundabout' || 'rotary' => 'Roundabout',
      'merge' => 'Merge',
      'on ramp' => 'Slip road on',
      'off ramp' => 'Slip road off',
      'end of road' => 'End of road',
      'fork' => 'Fork',
      'new name' => 'Road name change',
      'continue' => 'Continue',
      'turn' => 'Turn',
      _ => type.isEmpty ? 'Junction' : _sentenceCase(type),
    };
    return modifier.isEmpty ? where : '$where, $modifier';
  }

  static String _sentenceCase(String value) =>
      value[0].toUpperCase() + value.substring(1);

  static String _decisionLabel(String type, String modifier) {
    if (type == 'fork') {
      return modifier.isEmpty ? 'Fork marker' : 'Keep $modifier marker';
    }
    if (type == 'end of road') {
      return modifier.isEmpty
          ? 'End-of-road marker'
          : 'End of road, turn $modifier marker';
    }
    return modifier.isEmpty ? 'Junction marker' : 'Turn $modifier marker';
  }
}

double _pathLengthMeters(List<GeoPoint> points) {
  var total = 0.0;
  for (var index = 1; index < points.length; index += 1) {
    total += _distanceMeters(points[index - 1], points[index]);
  }
  return total;
}

const _earthRadiusMeters = 6371008.8;

double _distanceMeters(GeoPoint first, GeoPoint second) {
  final latitude1 = _radians(first.latitude);
  final latitude2 = _radians(second.latitude);
  final latitudeDelta = latitude2 - latitude1;
  final longitudeDelta = _radians(
    _normaliseLongitudeDelta(second.longitude - first.longitude),
  );
  final a =
      math.pow(math.sin(latitudeDelta / 2), 2) +
      math.cos(latitude1) *
          math.cos(latitude2) *
          math.pow(math.sin(longitudeDelta / 2), 2);
  return _earthRadiusMeters * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}

double _distanceToPolylineMeters(GeoPoint point, List<GeoPoint> polyline) {
  if (polyline.isEmpty) return double.infinity;
  if (polyline.length == 1) return _distanceMeters(point, polyline.single);
  var nearest = double.infinity;
  for (var index = 0; index < polyline.length - 1; index += 1) {
    nearest = math.min(
      nearest,
      _distanceToSegmentMeters(point, polyline[index], polyline[index + 1]),
    );
  }
  return nearest;
}

double _distanceToSegmentMeters(GeoPoint point, GeoPoint start, GeoPoint end) {
  final referenceLatitude = _radians(point.latitude);
  final startX =
      _radians(_normaliseLongitudeDelta(start.longitude - point.longitude)) *
      math.cos(referenceLatitude) *
      _earthRadiusMeters;
  final startY = _radians(start.latitude - point.latitude) * _earthRadiusMeters;
  final endX =
      _radians(_normaliseLongitudeDelta(end.longitude - point.longitude)) *
      math.cos(referenceLatitude) *
      _earthRadiusMeters;
  final endY = _radians(end.latitude - point.latitude) * _earthRadiusMeters;
  final deltaX = endX - startX;
  final deltaY = endY - startY;
  final lengthSquared = deltaX * deltaX + deltaY * deltaY;
  if (lengthSquared == 0) {
    return math.sqrt(startX * startX + startY * startY);
  }
  final projection = (-(startX * deltaX + startY * deltaY) / lengthSquared)
      .clamp(0.0, 1.0);
  final nearestX = startX + projection * deltaX;
  final nearestY = startY + projection * deltaY;
  return math.sqrt(nearestX * nearestX + nearestY * nearestY);
}

double _bearing(GeoPoint from, GeoPoint to) {
  final latitude1 = _radians(from.latitude);
  final latitude2 = _radians(to.latitude);
  final longitudeDelta = _radians(
    _normaliseLongitudeDelta(to.longitude - from.longitude),
  );
  final y = math.sin(longitudeDelta) * math.cos(latitude2);
  final x =
      math.cos(latitude1) * math.sin(latitude2) -
      math.sin(latitude1) * math.cos(latitude2) * math.cos(longitudeDelta);
  return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
}

double _smallestAngle(double first, double second) {
  final difference = (second - first).abs() % 360;
  return difference > 180 ? 360 - difference : difference;
}

double _radians(double degrees) => degrees * math.pi / 180;

double _normaliseLongitudeDelta(double delta) => ((delta + 540) % 360) - 180;
