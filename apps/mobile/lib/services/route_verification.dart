/// What a planned route actually uses, set against what the rider asked for.
///
/// A routing engine is asked for a route with some preferences and answers with
/// a line. Nothing in that answer says whether the preferences were honoured:
/// the OSRM driving profile cannot express them at all, and the public Valhalla
/// motorcycle costing was measured on 4 October 2026 to ignore `exclude_unpaved`
/// (a canal-side `highway=track` with gates was routed under the default
/// "avoid unsurfaced byways", #840). So the preferences are treated as a request
/// and the answer is **checked**: the route's own geometry is looked up edge by
/// edge, each edge is classified against the preferences, and what is left over
/// is reported with its length instead of being presented as if it had been
/// avoided.
///
/// This file is the pure half: the model, the classification and the wording. It
/// reads no network. [RouteVerifier] in `verified_road_routing.dart` asks the
/// routing service for the edges and decides when to re-plan.
library;

import 'dart:math' as math;

import '../domain/distance_unit.dart';
import '../domain/imported_route.dart';
import 'measurement_formatter.dart';

/// One stretch of road as the routing graph describes it.
///
/// Only what the classification needs. [roadClass] and [use] are Valhalla's
/// vocabulary (`motorway`, `trunk`, `primary`, ...; `road`, `track`, `ramp`,
/// `footway`, ...), which is the vocabulary of the service that is asked.
class RouteEdge {
  const RouteEdge({
    required this.lengthMeters,
    required this.beginShapeIndex,
    required this.endShapeIndex,
    this.wayId,
    this.use,
    this.unpaved = false,
    this.surface,
    this.roadClass,
    this.names = const [],
  });

  final double lengthMeters;

  /// Where the edge starts and ends in the matched shape that accompanied it.
  final int beginShapeIndex;
  final int endShapeIndex;
  final int? wayId;
  final String? use;
  final bool unpaved;
  final String? surface;
  final String? roadClass;

  /// Names and references, most specific first (`M5`, then `Severn Bridge`).
  final List<String> names;
}

/// Why a stretch of a route is a concern.
enum RouteConcernKind {
  /// A way a motor vehicle has no business on: a footway, path, cycleway,
  /// bridleway, steps or pedestrian way. Never acceptable, whatever was asked.
  nonRoad,

  /// A track or an unpaved surface while "avoid unsurfaced byways" is on.
  unsurfaced,

  /// A motorway while "avoid motorways" is on.
  motorway,

  /// Trunk and primary roads while "avoid major roads" is on. This preference
  /// is a bias rather than an exclusion - excluding them strands most UK routes
  /// - so this concern is reported and never re-planned.
  majorRoad,
}

class RouteConcern {
  const RouteConcern({
    required this.kind,
    required this.lengthMeters,
    this.stretches = 1,
    this.labels = const [],
    this.locations = const [],
  });

  final RouteConcernKind kind;
  final double lengthMeters;

  /// Separate runs of consecutive offending edges.
  final int stretches;

  /// What to call it: the `track`/`road` of an unsurfaced concern, the
  /// `footpath`/`cycle path` of a non-road one, or the road references
  /// (`M5`, `A38`) of a motorway or major-road one.
  final List<String> labels;

  /// The middle of each offending edge, in route order.
  ///
  /// This is what a re-plan excludes. A point in the middle of an edge snaps to
  /// that edge and no other; the end of an edge is also the start of the next.
  final List<GeoPoint> locations;

  /// Whether a re-plan should try to avoid it.
  bool get isHard => kind != RouteConcernKind.majorRoad;

  RouteConcern _merged(RouteConcern other) => RouteConcern(
    kind: kind,
    lengthMeters: lengthMeters + other.lengthMeters,
    stretches: stretches + other.stretches,
    labels: {...labels, ...other.labels}.toList(growable: false),
    locations: [...locations, ...other.locations],
  );
}

/// What came of asking the routing service to avoid the offending edges.
enum RouteReplanOutcome {
  /// No re-plan was needed, or none was possible.
  notAttempted,

  /// A stricter request was made and its route is the one shown.
  adopted,

  /// A stricter request was made and did not give a better route, so the
  /// original is shown.
  failed,
}

/// The result of checking one planned route.
class RouteVerification {
  const RouteVerification({
    required this.preferences,
    required this.checked,
    this.concerns = const [],
    this.routeMeters = 0,
    this.coveredMeters = 0,
    this.replan = RouteReplanOutcome.notAttempted,
    this.avoided = const [],
  });

  /// A check that could not be made, for whatever reason.
  const RouteVerification.unchecked(this.preferences, {this.routeMeters = 0})
    : checked = false,
      concerns = const [],
      coveredMeters = 0,
      replan = RouteReplanOutcome.notAttempted,
      avoided = const [];

  /// What the check was made against, with the defaults filled in.
  final RoutePreferences preferences;

  /// False when the route could not be looked up or the answer could not be
  /// trusted. Nothing is then known about the route either way.
  final bool checked;
  final List<RouteConcern> concerns;
  final double routeMeters;

  /// How much of the route the lookup covered.
  final double coveredMeters;
  final RouteReplanOutcome replan;

  /// What an adopted re-plan avoided. Empty otherwise.
  final List<RouteConcern> avoided;

  /// Below this much of the route unchecked, the gap is not worth mentioning:
  /// a route's first and last metres rarely match a road graph exactly.
  static const _partialToleranceMeters = 500.0;
  static const _partialToleranceFraction = 0.05;

  List<RouteConcern> get hardConcerns =>
      concerns.where((concern) => concern.isHard).toList(growable: false);
  bool get hasHardConcerns => concerns.any((concern) => concern.isHard);
  double get hardConcernMeters => concerns
      .where((concern) => concern.isHard)
      .fold(0.0, (total, concern) => total + concern.lengthMeters);

  /// Whether part of the route was never looked at.
  bool get isPartial =>
      checked &&
      routeMeters > 0 &&
      routeMeters - coveredMeters >
          math.max(
            _partialToleranceMeters,
            routeMeters * _partialToleranceFraction,
          );

  /// Checked, and nothing to say.
  bool get isClean => checked && concerns.isEmpty && !isPartial;

  RouteVerification copyWith({
    List<RouteConcern>? concerns,
    RouteReplanOutcome? replan,
    List<RouteConcern>? avoided,
  }) => RouteVerification(
    preferences: preferences,
    checked: checked,
    concerns: concerns ?? this.concerns,
    routeMeters: routeMeters,
    coveredMeters: coveredMeters,
    replan: replan ?? this.replan,
    avoided: avoided ?? this.avoided,
  );

  /// One verification for several checked paths of the same route.
  static RouteVerification? merge(Iterable<RouteVerification> verifications) {
    final all = verifications.toList(growable: false);
    if (all.isEmpty) return null;
    if (all.length == 1) return all.single;
    final byKind = <RouteConcernKind, RouteConcern>{};
    for (final verification in all) {
      for (final concern in verification.concerns) {
        final existing = byKind[concern.kind];
        byKind[concern.kind] = existing == null
            ? concern
            : existing._merged(concern);
      }
    }
    return RouteVerification(
      preferences: all.first.preferences,
      checked: all.every((verification) => verification.checked),
      concerns: [for (final kind in RouteConcernKind.values) ?byKind[kind]],
      routeMeters: all.fold(0.0, (sum, item) => sum + item.routeMeters),
      coveredMeters: all.fold(0.0, (sum, item) => sum + item.coveredMeters),
      replan: all.any((item) => item.replan == RouteReplanOutcome.failed)
          ? RouteReplanOutcome.failed
          : all.any((item) => item.replan == RouteReplanOutcome.adopted)
          ? RouteReplanOutcome.adopted
          : RouteReplanOutcome.notAttempted,
    );
  }

  /// What to tell the rider, as sentences for the route review.
  ///
  /// Empty when the route was checked and is clean.
  List<String> notices(DistanceUnit unit) {
    final formatter = MeasurementFormatter(unit);
    if (!checked) {
      final asked = _askedFor(preferences);
      return [
        asked.isEmpty
            ? 'Could not check this route against the road data, so it may '
                  'include ways a motorcycle cannot ride.'
            : 'Could not check this route against your road preferences '
                  '(${asked.join(', ')}), so it may use roads you asked to '
                  'avoid.',
      ];
    }
    return [
      for (final concern in concerns) _describe(concern, formatter),
      if (isPartial)
        'Only ${formatter.distance(coveredMeters)} of this '
            '${formatter.distance(routeMeters)} route could be checked against '
            'your road preferences.',
    ];
  }

  String _describe(RouteConcern concern, MeasurementFormatter formatter) {
    final distance = formatter.distance(concern.lengthMeters);
    final places = concern.stretches > 1
        ? ' in ${concern.stretches} places'
        : '';
    final roads = concern.labels.isEmpty ? '' : ' (${_listed(concern.labels)})';
    final noAlternative = replan == RouteReplanOutcome.failed;
    return switch (concern.kind) {
      RouteConcernKind.nonRoad =>
        'Uses $distance of ${_joinNouns(concern.labels)}$places, which is not '
            'a road.',
      RouteConcernKind.unsurfaced =>
        'Uses $distance of unsurfaced ${_joinNouns(concern.labels)}$places, '
            'although Avoid unsurfaced byways is on.'
            '${noAlternative ? ' No road route that avoids it was found.' : ''}',
      RouteConcernKind.motorway =>
        'Uses $distance of motorway$roads$places, although Avoid motorways '
            'is on.${noAlternative ? ' No motorway-free route was found.' : ''}',
      RouteConcernKind.majorRoad =>
        'Uses $distance of major roads$roads$places, although Avoid major '
            'roads is on.',
    };
  }

  static List<String> _askedFor(RoutePreferences preferences) => [
    if (preferences.bywaySurface.avoidsUnsurfaced) 'avoid unsurfaced byways',
    if (preferences.avoidMotorways) 'avoid motorways',
    if (preferences.avoidMajorRoads) 'avoid major roads',
  ];

  static String _joinNouns(List<String> nouns) =>
      nouns.isEmpty ? 'road' : nouns.join(' or ');

  /// The first few road references, so a long route's notice stays a sentence.
  static String _listed(List<String> labels) => labels.length > _listedMaximum
      ? '${labels.take(_listedMaximum).join(', ')} and others'
      : labels.join(', ');

  static const _listedMaximum = 6;
}

/// Valhalla `use` values that are not a road a motor vehicle can ride, with what
/// to call each.
const _nonRoadUses = {
  'footway': 'footpath',
  'sidewalk': 'footpath',
  'pedestrian': 'pedestrian way',
  'path': 'path',
  'cycleway': 'cycle path',
  'bridleway': 'bridleway',
  'steps': 'steps',
  'mountain_bike': 'mountain bike trail',
};

/// Ways that exist to reach a place rather than to be ridden along: a car park
/// aisle or a drive at either end of a journey is not a byway.
const _accessOnlyUses = {'parking_aisle', 'driveway', 'drive_through'};

const _unpavedSurfaces = {'compacted', 'dirt', 'gravel', 'path', 'impassable'};

/// A concern shorter than this in total is not worth interrupting a rider for,
/// and is too short to route around in any case.
const _minimumConcernMeters = 20.0;

/// Major roads are reported only when they are a real part of the route. Almost
/// every British route crosses a town on an A-road.
const _minimumMajorRoadMeters = 1000.0;

/// Sorts a route's edges into what the rider asked not to use.
///
/// [shape] is the matched shape the edges index into. Without it the concerns
/// are still found and measured; they just carry no [RouteConcern.locations],
/// so there is nothing a re-plan could exclude.
List<RouteConcern> classifyRouteEdges(
  List<RouteEdge> edges,
  List<GeoPoint> shape,
  RoutePreferences preferences,
) {
  final builders = <RouteConcernKind, _ConcernBuilder>{};
  RouteConcernKind? previous;
  for (final edge in edges) {
    final kind = _classify(edge, preferences);
    if (kind != null) {
      final builder = builders.putIfAbsent(kind, _ConcernBuilder.new);
      if (kind != previous) builder.stretches += 1;
      builder.lengthMeters += edge.lengthMeters;
      builder.note(kind, edge);
      final midpoint = kind == RouteConcernKind.majorRoad
          ? null
          : _edgeMidpoint(shape, edge.beginShapeIndex, edge.endShapeIndex);
      if (midpoint != null) {
        builder.locations.add(midpoint);
      }
    }
    previous = kind;
  }
  return [
    for (final kind in RouteConcernKind.values)
      if (builders[kind] case final builder?)
        if (builder.lengthMeters >=
            (kind == RouteConcernKind.majorRoad
                ? _minimumMajorRoadMeters
                : _minimumConcernMeters))
          RouteConcern(
            kind: kind,
            lengthMeters: builder.lengthMeters,
            stretches: builder.stretches,
            labels: List.unmodifiable(
              builder.labels.isNotEmpty ? builder.labels : builder.names,
            ),
            locations: List.unmodifiable(builder.locations),
          ),
  ];
}

RouteConcernKind? _classify(RouteEdge edge, RoutePreferences preferences) {
  final use = edge.use;
  if (_nonRoadUses.containsKey(use)) return RouteConcernKind.nonRoad;
  if (preferences.bywaySurface.avoidsUnsurfaced &&
      !_accessOnlyUses.contains(use) &&
      (use == 'track' ||
          edge.unpaved ||
          _unpavedSurfaces.contains(edge.surface))) {
    return RouteConcernKind.unsurfaced;
  }
  final roadClass = edge.roadClass;
  if (preferences.avoidMotorways && roadClass == 'motorway') {
    return RouteConcernKind.motorway;
  }
  if (preferences.avoidMajorRoads &&
      (roadClass == 'trunk' ||
          roadClass == 'primary' ||
          roadClass == 'motorway')) {
    return RouteConcernKind.majorRoad;
  }
  return null;
}

class _ConcernBuilder {
  double lengthMeters = 0;
  int stretches = 0;

  /// What to call it: nouns for a surface or a non-road way, road references
  /// for a motorway or a major road.
  final labels = <String>[];

  /// Names of road edges that carry no reference, used only when none does.
  final names = <String>[];
  final locations = <GeoPoint>[];

  void note(RouteConcernKind kind, RouteEdge edge) {
    switch (kind) {
      case RouteConcernKind.nonRoad:
        _add(labels, _nonRoadUses[edge.use]);
      case RouteConcernKind.unsurfaced:
        _add(labels, edge.use == 'track' ? 'track' : 'road');
      case RouteConcernKind.motorway || RouteConcernKind.majorRoad:
        final reference = _reference(edge.names);
        if (reference != null) {
          _add(labels, reference);
        } else if (edge.names.isNotEmpty) {
          _add(names, edge.names.first);
        }
    }
  }

  static void _add(List<String> into, String? value) {
    if (value != null && !into.contains(value)) into.add(value);
  }
}

/// A road reference - `M5`, `A38`, `A404(M)`, `I-95` - as opposed to a name.
final _referencePattern = RegExp(
  r'^[A-Z]{1,3}[ -]?\d{1,4}[A-Z]?(\([A-Z]+\))?$',
);

/// International E-road numbers accompany the national reference of a road
/// rather than replacing it, so they are not what a rider would call it.
final _internationalPattern = RegExp(r'^E[ -]?\d{1,3}$');

String? _reference(List<String> names) {
  final references = names.where(_referencePattern.hasMatch).toList();
  return references
          .where((name) => !_internationalPattern.hasMatch(name))
          .firstOrNull ??
      references.firstOrNull;
}

/// The point half way along an edge, measured along the matched shape.
GeoPoint? _edgeMidpoint(List<GeoPoint> shape, int begin, int end) {
  if (begin < 0 || end < begin || end >= shape.length) return null;
  if (begin == end) return shape[begin];
  final lengths = [
    for (var index = begin; index < end; index += 1)
      routeDistanceMeters(shape[index], shape[index + 1]),
  ];
  final half = lengths.fold(0.0, (sum, length) => sum + length) / 2;
  var travelled = 0.0;
  for (var index = 0; index < lengths.length; index += 1) {
    final length = lengths[index];
    if (travelled + length >= half) {
      final from = shape[begin + index];
      final to = shape[begin + index + 1];
      final fraction = length <= 0 ? 0.0 : (half - travelled) / length;
      return GeoPoint(
        latitude: from.latitude + (to.latitude - from.latitude) * fraction,
        longitude: from.longitude + (to.longitude - from.longitude) * fraction,
      );
    }
    travelled += length;
  }
  return shape[end];
}

/// Picks at most [cap] of the offending edges' midpoints to exclude.
///
/// A short list is taken whole. A long one - a motorway is dozens of edges - is
/// shared out so every concern keeps a say, then thinned evenly: excluding every
/// few edges along a motorway is enough to stop a router riding it, because it
/// would have to leave and rejoin between them.
List<GeoPoint> selectExclusionLocations(List<RouteConcern> concerns, int cap) {
  final hard = [
    for (final concern in concerns)
      if (concern.isHard && concern.locations.isNotEmpty) concern,
  ]..sort((a, b) => a.locations.length.compareTo(b.locations.length));
  final selected = <GeoPoint>[];
  var remaining = cap;
  for (final (index, concern) in hard.indexed) {
    if (remaining <= 0) break;
    final share = math.max(1, remaining ~/ (hard.length - index));
    final take = math.min(concern.locations.length, share);
    selected.addAll(_evenlySpaced(concern.locations, take));
    remaining -= take;
  }
  return List.unmodifiable(selected);
}

List<GeoPoint> _evenlySpaced(List<GeoPoint> points, int count) {
  if (count >= points.length) return points;
  if (count == 1) return [points[points.length ~/ 2]];
  return [
    for (var index = 0; index < count; index += 1)
      points[(index * (points.length - 1) / (count - 1)).round()],
  ];
}

/// Great-circle distance between two route points, in metres.
double routeDistanceMeters(GeoPoint first, GeoPoint second) {
  const earthRadius = 6371008.8;
  final firstLatitude = first.latitude * math.pi / 180;
  final secondLatitude = second.latitude * math.pi / 180;
  final deltaLatitude = (second.latitude - first.latitude) * math.pi / 180;
  final deltaLongitude = (second.longitude - first.longitude) * math.pi / 180;
  final a =
      math.sin(deltaLatitude / 2) * math.sin(deltaLatitude / 2) +
      math.cos(firstLatitude) *
          math.cos(secondLatitude) *
          math.sin(deltaLongitude / 2) *
          math.sin(deltaLongitude / 2);
  return earthRadius * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}
