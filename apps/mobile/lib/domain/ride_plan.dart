/// The rider's intent for a route, before and after it is confirmed (#847).
///
/// ## Why this exists
///
/// "Type a destination and it defaults to your current location for a start
/// point but you can always change it and add named stopping points. Then in
/// the map view you can draw the route around with shaping points that don't
/// show up in the list of waypoints." That is Google Maps on mobile, and it is
/// what the operator asked the planning flow to become.
///
/// The app already had every piece of a route — named waypoints, shaping
/// points (#242), preferences (#182) — but no single statement of what the
/// rider asked for. A destination planned from Home lived as text in a form,
/// a route on the map lived as an [ImportedRoute], and "Edit stops" went back
/// from one to the other and lost everything drawn on the map in between.
///
/// A plan is that statement. It has no store of its own: **a confirmed plan is
/// an [ImportedRoute]** whose waypoints are the named places in order and whose
/// shaping points are the drawn ones. [RidePlan.fromRoute] reads one back, so
/// any route the app planned can be reopened and edited.
///
/// ## The rules this file owns
///
/// - The start defaults to the rider's location ([CurrentLocationStart]).
/// - Shaping points are never stops. They are kept apart from [stops] in every
///   edit and every conversion, including GPX shaping points that an importer
///   stored as waypoints.
/// - Every edit keeps the shaping points the rider drew, re-indexed onto the
///   legs they still belong to.
library;

import 'dart:math' as math;

import 'imported_route.dart';
import 'ride_coordination_mode.dart';

/// One named place on a plan: its start, a stop, or its destination.
class RidePlanPlace {
  const RidePlanPlace({
    required this.point,
    required this.label,
    this.description,
    this.symbol,
  });

  /// A place chosen from a destination search.
  ///
  /// Search results carry a full address ("Bath, Somerset, England, United
  /// Kingdom"). The itinerary shows the first part and keeps the rest as the
  /// description, which is what `DestinationRoutePlanner` already does with
  /// the same results.
  factory RidePlanPlace.fromSearchResult({
    required String label,
    required GeoPoint point,
  }) {
    final trimmed = label.trim();
    final short = shortPlaceLabel(trimmed);
    return RidePlanPlace(
      point: point,
      label: short.isEmpty ? trimmed : short,
      description: trimmed.isEmpty || trimmed == short ? null : trimmed,
    );
  }

  factory RidePlanPlace.fromWaypoint(
    RouteWaypoint waypoint, {
    required String fallbackLabel,
  }) {
    final name = waypoint.name?.trim();
    return RidePlanPlace(
      point: waypoint.point,
      label: name == null || name.isEmpty ? fallbackLabel : name,
      description: waypoint.description,
      symbol: waypoint.symbol,
    );
  }

  final GeoPoint point;

  /// The short name the itinerary shows.
  final String label;
  final String? description;

  /// A GPX `<sym>`, kept so a café added as a stop stays a café on export.
  final String? symbol;

  /// This place after its pin was dragged to [to] on the map (#891).
  ///
  /// A short nudge — onto the right road, or the other side of a junction —
  /// is still the same place and keeps its name. A longer drag is somewhere
  /// else, so it becomes a dropped pin rather than carrying a café's name to a
  /// lay-by two miles away.
  RidePlanPlace movedTo(GeoPoint to) =>
      _metres(point, to) <= keepNameWithinMeters
      ? RidePlanPlace(
          point: to,
          label: label,
          description: description,
          symbol: symbol,
        )
      : RidePlanPlace(point: to, label: droppedPinLabel);

  /// How far a dragged pin may move and still keep its name.
  static const keepNameWithinMeters = 150.0;

  /// What a place dragged further than [keepNameWithinMeters] is called.
  static const droppedPinLabel = 'Dropped pin';

  RouteWaypoint toWaypoint({required String defaultSymbol}) => RouteWaypoint(
    point: point,
    name: label,
    description: description,
    symbol: symbol ?? defaultSymbol,
  );
}

/// The first part of a search result's address.
String shortPlaceLabel(String label) => label.split(',').first.trim();

/// Where a plan starts.
sealed class RidePlanStart {
  const RidePlanStart();
}

/// The rider's own position, read when the route is calculated.
///
/// This is the default, as it is in Google Maps: a rider who only says where
/// they are going is going from here.
final class CurrentLocationStart extends RidePlanStart {
  const CurrentLocationStart();
}

/// A place the rider chose instead, such as a meeting point.
final class PlaceStart extends RidePlanStart {
  const PlaceStart(this.place);

  final RidePlanPlace place;
}

/// What to send to a router for one plan.
class RidePlanControls {
  const RidePlanControls({
    required this.points,
    required this.shapingPointIndexes,
    required this.namedPlaces,
  });

  /// Start, then each leg's shaping points, each stop, and the destination.
  final List<GeoPoint> points;

  /// Indexes into [points] that shape the route without stopping it. Only the
  /// other indexes split the route into legs, so only named places can
  /// produce an arrival (#839).
  final Set<int> shapingPointIndexes;

  /// The start (resolved), the stops and the destination, in order.
  final List<RidePlanPlace> namedPlaces;
}

/// The rider's intent: where from, where to, via where, and with whom.
class RidePlan {
  const RidePlan({
    this.start = const CurrentLocationStart(),
    this.stops = const [],
    this.destination,
    this.shapingPoints = const [],
    this.preferences = RoutePreferences.defaults,
    this.coordinationMode = RideCoordinationMode.solo,
    this.derivedFromGeometry = false,
  });

  /// A plan to [destination], starting where the rider is.
  ///
  /// The start is deliberately not a parameter. Choosing somewhere else is an
  /// edit the rider makes on the plan, not something a caller decides for them.
  factory RidePlan.toDestination(
    RidePlanPlace destination, {
    RoutePreferences preferences = RoutePreferences.defaults,
    RideCoordinationMode coordinationMode = RideCoordinationMode.solo,
  }) => RidePlan(
    destination: destination,
    preferences: preferences,
    coordinationMode: coordinationMode,
  );

  /// Reads a confirmed route back as a plan, so it can be edited.
  ///
  /// Waypoints are the named places in order. A waypoint an importer marked
  /// as a shaping point ([routeShapingPointSymbol]) is a shaping point on the
  /// leg it falls in, never a stop (#839). A start described as [currentLocationDescription] comes back as
  /// the rider's location, so editing a route mid-ride re-plans from where the
  /// rider is now.
  ///
  /// A route with fewer than two named waypoints — a recording, or a track
  /// with no route points — takes its start and destination from the ends of
  /// its line, and says so through [derivedFromGeometry].
  factory RidePlan.fromRoute(
    ImportedRoute route, {
    RideCoordinationMode coordinationMode = RideCoordinationMode.solo,
  }) {
    // Shaping points an importer kept as waypoints are separated the way
    // #839 separates them everywhere else: they bend a leg, they are not stops.
    final separated = separateShapingWaypoints(
      route.waypoints,
      existing: route.shapingPoints,
    );
    final named = separated.stops;
    final preferences = route.preferences ?? RoutePreferences.defaults;
    final line = _longestPath(route);

    // A planned route's first and last waypoints are where its line begins and
    // ends. A file whose waypoints are points of interest scattered along a
    // track is not a list of stops in order, and routing through them in file
    // order would replace the track with a tour of them.
    final waypointsDescribeLine =
        named.length >= 2 &&
        (line.length < 2 ||
            (_metres(named.first.point, line.first) <= maximumEndOffsetMeters &&
                _metres(named.last.point, line.last) <=
                    maximumEndOffsetMeters));

    if (!waypointsDescribeLine) {
      if (line.length < 2) {
        // Nothing to start from: a single pin at most. It is still a
        // destination worth planning to.
        final only = named.firstOrNull;
        return RidePlan(
          destination: only == null
              ? null
              : RidePlanPlace.fromWaypoint(only, fallbackLabel: 'Destination'),
          preferences: preferences,
          coordinationMode: coordinationMode,
          derivedFromGeometry: true,
        );
      }
      return RidePlan(
        start: PlaceStart(
          RidePlanPlace(point: line.first, label: 'Start of the route'),
        ),
        destination: RidePlanPlace(point: line.last, label: 'End of the route'),
        shapingPoints: _sortedByLeg([
          for (final point in separated.shapingPoints)
            RouteShapingPoint(id: point.id, point: point.point, legIndex: 0),
        ]),
        preferences: preferences,
        coordinationMode: coordinationMode,
        derivedFromGeometry: true,
      );
    }

    final legCount = named.length - 1;
    final first = named.first;
    final last = named.last;
    return RidePlan(
      start: first.description?.trim() == currentLocationDescription
          ? const CurrentLocationStart()
          : PlaceStart(
              RidePlanPlace.fromWaypoint(first, fallbackLabel: 'Start'),
            ),
      stops: [
        for (final (index, waypoint)
            in named.sublist(1, named.length - 1).indexed)
          RidePlanPlace.fromWaypoint(
            waypoint,
            fallbackLabel: 'Stop ${index + 1}',
          ),
      ],
      destination: RidePlanPlace.fromWaypoint(
        last,
        fallbackLabel: 'Destination',
      ),
      shapingPoints: _sortedByLeg([
        for (final point in separated.shapingPoints)
          _onLeg(point, point.legIndex.clamp(0, legCount - 1)),
      ]),
      preferences: preferences,
      coordinationMode: coordinationMode,
    );
  }

  /// The description `DestinationRoutePlanner` gives a start that was the
  /// rider's position. Shared so that routes planned before #847 read back as
  /// "from your location" too.
  static const currentLocationDescription = 'Current location';

  /// The most stops "Add stop" offers. A café or highlight added from the map
  /// is not counted against it.
  static const maximumSearchedStops = 8;

  /// How far a route's first or last waypoint may sit from the end of its line
  /// and still be that end. A geocoded town or postcode is rarely on the road
  /// the router snaps to, so this is generous; a file's points of interest are
  /// usually much further from its ends than this.
  static const maximumEndOffsetMeters = 2000.0;

  final RidePlanStart start;

  /// The named stops between the start and the destination, in order.
  ///
  /// Never contains a shaping point: those are [shapingPoints], drawn on the
  /// map and routed without stopping.
  final List<RidePlanPlace> stops;
  final RidePlanPlace? destination;

  /// Drawn route adjustments. `legIndex` counts the legs of
  /// `[start, ...stops, destination]`.
  final List<RouteShapingPoint> shapingPoints;
  final RoutePreferences preferences;

  /// Solo, or one of the two group modes (#261). Solo is the default: a rider
  /// who says where they are going has said nothing about company (#600).
  final RideCoordinationMode coordinationMode;

  /// True when this plan was read from a line rather than from named places,
  /// so editing it re-plans the route on roads between them.
  final bool derivedFromGeometry;

  bool get startsAtCurrentLocation => start is CurrentLocationStart;
  bool get isGroup => coordinationMode.isGroup;
  int get legCount => stops.length + 1;

  /// The name a new plan gets: "To" and the destination.
  static String nameFor(RidePlanPlace destination) =>
      'To ${shortPlaceLabel(destination.label)}';

  /// The start as a place, once "your location" is known.
  RidePlanPlace? resolvedStart({GeoPoint? currentLocation}) => switch (start) {
    CurrentLocationStart() =>
      currentLocation == null
          ? null
          : RidePlanPlace(
              point: currentLocation,
              label: 'Start',
              description: currentLocationDescription,
            ),
    PlaceStart(:final place) => place,
  };

  /// What to ask a router for, or null while the start or the destination is
  /// still unknown.
  RidePlanControls? controls({GeoPoint? currentLocation}) {
    final startPlace = resolvedStart(currentLocation: currentLocation);
    final end = destination;
    if (startPlace == null || end == null) return null;
    final named = [startPlace, ...stops, end];
    final points = <GeoPoint>[];
    final shaping = <int>{};
    for (var leg = 0; leg < named.length - 1; leg += 1) {
      points.add(named[leg].point);
      for (final point in shapingPoints) {
        if (point.legIndex.clamp(0, named.length - 2) != leg) continue;
        shaping.add(points.length);
        points.add(point.point);
      }
    }
    points.add(named.last.point);
    return RidePlanControls(
      points: List.unmodifiable(points),
      shapingPointIndexes: Set.unmodifiable(shaping),
      namedPlaces: List.unmodifiable(named),
    );
  }

  RidePlan copyWith({
    RidePlanStart? start,
    List<RidePlanPlace>? stops,
    RidePlanPlace? destination,
    List<RouteShapingPoint>? shapingPoints,
    RoutePreferences? preferences,
    RideCoordinationMode? coordinationMode,
    bool? derivedFromGeometry,
  }) => RidePlan(
    start: start ?? this.start,
    stops: stops ?? this.stops,
    destination: destination ?? this.destination,
    shapingPoints: shapingPoints ?? this.shapingPoints,
    preferences: preferences ?? this.preferences,
    coordinationMode: coordinationMode ?? this.coordinationMode,
    derivedFromGeometry: derivedFromGeometry ?? this.derivedFromGeometry,
  );

  /// Changing either end keeps every drawn adjustment: they still describe the
  /// roads the rider wanted on that leg.
  RidePlan withStart(RidePlanStart start) => copyWith(start: start);

  RidePlan withDestination(RidePlanPlace destination) =>
      copyWith(destination: destination);

  RidePlan withPreferences(RoutePreferences preferences) =>
      copyWith(preferences: preferences);

  RidePlan withCoordinationMode(RideCoordinationMode mode) =>
      copyWith(coordinationMode: mode);

  RidePlan withShapingPoints(List<RouteShapingPoint> points) =>
      copyWith(shapingPoints: _sortedByLeg(points));

  /// Adds a named stop, by default just before the destination.
  ///
  /// The new stop splits one leg in two. Each adjustment on that leg moves to
  /// whichever half it lies nearer, and adjustments on later legs move up one,
  /// so nothing the rider drew is lost or attached to the wrong road.
  RidePlan addStop(
    RidePlanPlace stop, {
    int? index,
    GeoPoint? currentLocation,
  }) {
    final at = (index ?? stops.length).clamp(0, stops.length);
    final splitLeg = at;
    final before = _legStart(splitLeg, currentLocation: currentLocation);
    final after = _legEnd(splitLeg);
    final shaping = [
      for (final point in shapingPoints)
        if (point.legIndex < splitLeg)
          point
        else if (point.legIndex > splitLeg)
          _onLeg(point, point.legIndex + 1)
        else
          _onLeg(
            point,
            _nearerHalf(
                  point.point,
                  first: (before, stop.point),
                  second: (stop.point, after),
                )
                ? splitLeg
                : splitLeg + 1,
          ),
    ];
    return copyWith(
      stops: [...stops]..insert(at, stop),
      shapingPoints: _sortedByLeg(shaping),
    );
  }

  /// Removes a named stop. The legs either side of it become one, and keep
  /// their adjustments in order.
  RidePlan removeStop(int index) {
    if (index < 0 || index >= stops.length) {
      throw RangeError.index(index, stops, 'index');
    }
    // Stop i sits between legs i and i + 1.
    final mergedLeg = index;
    return copyWith(
      stops: [...stops]..removeAt(index),
      shapingPoints: _sortedByLeg([
        for (final point in shapingPoints)
          point.legIndex <= mergedLeg
              ? point
              : _onLeg(point, point.legIndex - 1),
      ]),
    );
  }

  /// Moves a named stop to [to], as a removal and then an insertion.
  RidePlan moveStop(int from, int to, {GeoPoint? currentLocation}) {
    if (from < 0 || from >= stops.length) {
      throw RangeError.index(from, stops, 'from');
    }
    final target = to.clamp(0, stops.length - 1);
    if (target == from) return this;
    final moved = stops[from];
    return removeStop(
      from,
    ).addStop(moved, index: target, currentLocation: currentLocation);
  }

  /// Moves one named place — the start, a stop or the destination, counted
  /// in that order from zero — to where its pin was dragged (#891).
  ///
  /// The order of the places is unchanged, so every leg is still the same leg
  /// and every drawn adjustment stays on it. Dragging "your location" makes the
  /// start a place the rider chose, as choosing one from the start row does.
  RidePlan withPlaceMoved(
    int namedIndex,
    GeoPoint to, {
    GeoPoint? currentLocation,
  }) {
    final destinationIndex = stops.length + 1;
    if (namedIndex < 0 || namedIndex > destinationIndex) {
      throw RangeError.range(namedIndex, 0, destinationIndex, 'namedIndex');
    }
    if (namedIndex == 0) {
      final from = resolvedStart(currentLocation: currentLocation);
      return withStart(
        PlaceStart(
          from == null || startsAtCurrentLocation
              ? RidePlanPlace(point: to, label: RidePlanPlace.droppedPinLabel)
              : from.movedTo(to),
        ),
      );
    }
    if (namedIndex == destinationIndex) {
      final end = destination;
      return end == null ? this : withDestination(end.movedTo(to));
    }
    final index = namedIndex - 1;
    return copyWith(stops: [...stops]..[index] = stops[index].movedTo(to));
  }

  /// What is still ahead of a rider part-way along this plan's route (#893).
  ///
  /// The first [passedStops] stops are behind them and so are the shaping
  /// points in [passedShapingPointIds]; both are dropped, and the plan starts
  /// from the rider's location. The remaining adjustments move onto the same
  /// legs counted from there, so the leg the rider is on becomes leg 0. The
  /// destination is kept even when it is behind them: an edit still goes
  /// somewhere.
  RidePlan remainingFromCurrentLocation({
    required int passedStops,
    Set<String> passedShapingPointIds = const {},
  }) {
    final passed = passedStops.clamp(0, stops.length);
    return copyWith(
      start: const CurrentLocationStart(),
      stops: stops.sublist(passed),
      shapingPoints: _sortedByLeg([
        for (final point in shapingPoints)
          if (point.legIndex >= passed &&
              !passedShapingPointIds.contains(point.id))
            _onLeg(point, point.legIndex - passed),
      ]),
    );
  }

  GeoPoint? _legStart(int leg, {GeoPoint? currentLocation}) => leg == 0
      ? resolvedStart(currentLocation: currentLocation)?.point
      : stops[leg - 1].point;

  GeoPoint? _legEnd(int leg) =>
      leg < stops.length ? stops[leg].point : destination?.point;
}

RouteShapingPoint _onLeg(RouteShapingPoint point, int leg) =>
    RouteShapingPoint(id: point.id, point: point.point, legIndex: leg);

/// Stable, so adjustments keep their drawn order within each leg.
List<RouteShapingPoint> _sortedByLeg(List<RouteShapingPoint> points) {
  final indexed = points.indexed.toList()
    ..sort((first, second) {
      final byLeg = first.$2.legIndex.compareTo(second.$2.legIndex);
      return byLeg != 0 ? byLeg : first.$1.compareTo(second.$1);
    });
  return List.unmodifiable(indexed.map((entry) => entry.$2));
}

/// Whether [point] lies nearer the first of two segments than the second.
///
/// A segment with an unknown end (the rider's location, not yet found) is
/// measured to its known end alone. Distances are on a local flat projection,
/// which is ample for choosing between two halves of one leg.
bool _nearerHalf(
  GeoPoint point, {
  required (GeoPoint?, GeoPoint?) first,
  required (GeoPoint?, GeoPoint?) second,
}) =>
    _distanceToSegment(point, first.$1, first.$2) <=
    _distanceToSegment(point, second.$1, second.$2);

double _distanceToSegment(GeoPoint point, GeoPoint? from, GeoPoint? to) {
  if (from == null && to == null) return double.infinity;
  if (from == null) return _flatDistance(point, to!);
  if (to == null) return _flatDistance(point, from);
  final scale = math.cos(point.latitude * math.pi / 180);
  final ax = (from.longitude - point.longitude) * scale;
  final ay = from.latitude - point.latitude;
  final bx = (to.longitude - point.longitude) * scale;
  final by = to.latitude - point.latitude;
  final dx = bx - ax;
  final dy = by - ay;
  final lengthSquared = dx * dx + dy * dy;
  final t = lengthSquared == 0
      ? 0.0
      : (-(ax * dx + ay * dy) / lengthSquared).clamp(0.0, 1.0);
  final x = ax + t * dx;
  final y = ay + t * dy;
  return math.sqrt(x * x + y * y);
}

double _flatDistance(GeoPoint first, GeoPoint second) =>
    _distanceToSegment(first, second, second);

/// Great-circle distance in metres.
double _metres(GeoPoint first, GeoPoint second) {
  const earthRadius = 6371000.0;
  final lat1 = first.latitude * math.pi / 180;
  final lat2 = second.latitude * math.pi / 180;
  final dLat = lat2 - lat1;
  final dLon = (second.longitude - first.longitude) * math.pi / 180;
  final a =
      math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1) * math.cos(lat2) * math.sin(dLon / 2) * math.sin(dLon / 2);
  return 2 * earthRadius * math.asin(math.min(1, math.sqrt(a)));
}

List<GeoPoint> _longestPath(ImportedRoute route) {
  var longest = const <GeoPoint>[];
  var longestLength = -1.0;
  for (final path in route.paths) {
    var length = 0.0;
    for (var index = 1; index < path.points.length; index += 1) {
      length += _flatDistance(path.points[index - 1], path.points[index]);
    }
    if (length > longestLength) {
      longest = path.points;
      longestLength = length;
    }
  }
  return longest;
}
