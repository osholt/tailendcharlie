import 'dart:convert';

enum RoutePathKind { track, route }

class GeoPoint {
  const GeoPoint({
    required this.latitude,
    required this.longitude,
    this.elevationMeters,
    this.recordedAt,
  });

  final double latitude;
  final double longitude;
  final double? elevationMeters;
  final DateTime? recordedAt;

  Map<String, Object?> toJson() => {
    'latitude': latitude,
    'longitude': longitude,
    if (elevationMeters != null) 'elevationMeters': elevationMeters,
    if (recordedAt != null) 'recordedAt': recordedAt!.toUtc().toIso8601String(),
  };

  factory GeoPoint.fromJson(Map<String, Object?> json) {
    final latitude = _number(json, 'latitude');
    final longitude = _number(json, 'longitude');
    if (latitude < -90 || latitude > 90) {
      throw const FormatException('Route point latitude is outside -90..90.');
    }
    if (longitude < -180 || longitude > 180) {
      throw const FormatException(
        'Route point longitude is outside -180..180.',
      );
    }

    return GeoPoint(
      latitude: latitude,
      longitude: longitude,
      elevationMeters: (json['elevationMeters'] as num?)?.toDouble(),
      recordedAt: _optionalDateTime(json['recordedAt']),
    );
  }
}

class RoutePath {
  const RoutePath({required this.kind, required this.points, this.name});

  final RoutePathKind kind;
  final String? name;
  final List<GeoPoint> points;

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    if (name != null) 'name': name,
    'points': points.map((point) => point.toJson()).toList(),
  };

  factory RoutePath.fromJson(Map<String, Object?> json) {
    final kindName = json['kind'];
    final kind = RoutePathKind.values.where((item) => item.name == kindName);
    if (kind.isEmpty) {
      throw FormatException('Unsupported route path kind: $kindName');
    }
    final rawPoints = json['points'];
    if (rawPoints is! List) {
      throw const FormatException('Route path points must be a list.');
    }
    final points = rawPoints
        .map((point) {
          if (point is! Map) {
            throw const FormatException('Route point must be an object.');
          }
          return GeoPoint.fromJson(Map<String, Object?>.from(point));
        })
        .toList(growable: false);
    if (points.isEmpty) {
      throw const FormatException('Route paths cannot be empty.');
    }

    return RoutePath(
      kind: kind.single,
      name: _optionalString(json['name']),
      points: points,
    );
  }
}

class RouteWaypoint {
  const RouteWaypoint({
    required this.point,
    this.name,
    this.description,
    this.symbol,
  });

  final GeoPoint point;
  final String? name;
  final String? description;
  final String? symbol;

  Map<String, Object?> toJson() => {
    'point': point.toJson(),
    if (name != null) 'name': name,
    if (description != null) 'description': description,
    if (symbol != null) 'symbol': symbol,
  };

  factory RouteWaypoint.fromJson(Map<String, Object?> json) {
    final rawPoint = json['point'];
    if (rawPoint is! Map) {
      throw const FormatException('Waypoint point must be an object.');
    }
    return RouteWaypoint(
      point: GeoPoint.fromJson(Map<String, Object?>.from(rawPoint)),
      name: _optionalString(json['name']),
      description: _optionalString(json['description']),
      symbol: _optionalString(json['symbol']),
    );
  }
}

/// A route-engine instruction retained with the route geometry so navigation
/// guidance remains available after restart and while offline.
class RouteManeuver {
  const RouteManeuver({
    required this.position,
    required this.type,
    this.modifier,
    this.name,
    this.ref,
    this.exitNumber,
    this.drivingSide,
    this.bearingBeforeDegrees,
    this.bearingAfterDegrees,
    this.lanes = const [],
  });

  final GeoPoint position;
  final String type;
  final String? modifier;
  final String? name;
  final String? ref;

  /// Roundabout or rotary exit ordinal reported by the routing engine.
  ///
  /// The engine only counts exits for circular junctions, so this is never
  /// invented for other manoeuvre types.
  final int? exitNumber;

  /// Route-engine traffic side (`left` or `right`) at this manoeuvre.
  ///
  /// This is deliberately stored with the route instead of inferred from the
  /// phone locale: a rider can load a route for a different country. It only
  /// decides which way round a roundabout ring is drawn; it must never be used
  /// to decide which way the rider turns.
  final String? drivingSide;

  /// Heading in degrees clockwise from true north immediately before and after
  /// the manoeuvre, as reported by the routing engine.
  ///
  /// These give the manoeuvre's own geometry, which is the only reliable way to
  /// state the direction a roundabout is left: the entry modifier describes
  /// joining the ring, not the exit taken.
  final double? bearingBeforeDegrees;
  final double? bearingAfterDegrees;
  final List<RouteLane> lanes;

  Map<String, Object?> toJson() => {
    'latitude': position.latitude,
    'longitude': position.longitude,
    'type': type,
    if (modifier != null) 'modifier': modifier,
    if (name != null) 'name': name,
    if (ref != null) 'ref': ref,
    if (exitNumber != null) 'exitNumber': exitNumber,
    if (drivingSide != null) 'drivingSide': drivingSide,
    if (bearingBeforeDegrees != null)
      'bearingBeforeDegrees': bearingBeforeDegrees,
    if (bearingAfterDegrees != null) 'bearingAfterDegrees': bearingAfterDegrees,
    if (lanes.isNotEmpty)
      'lanes': lanes.map((lane) => lane.toJson()).toList(growable: false),
  };

  factory RouteManeuver.fromJson(Map<String, Object?> json) => RouteManeuver(
    position: GeoPoint(
      latitude: _number(json, 'latitude'),
      longitude: _number(json, 'longitude'),
    ),
    type: _requiredString(json, 'type'),
    modifier: _optionalString(json['modifier']),
    name: _optionalString(json['name']),
    ref: _optionalString(json['ref']),
    exitNumber: (json['exitNumber'] as num?)?.toInt(),
    drivingSide: _optionalString(json['drivingSide']),
    bearingBeforeDegrees: _optionalBearing(json['bearingBeforeDegrees']),
    bearingAfterDegrees: _optionalBearing(json['bearingAfterDegrees']),
    lanes:
        (json['lanes'] as List?)
            ?.whereType<Map>()
            .map((lane) => RouteLane.fromJson(Map<String, Object?>.from(lane)))
            .toList(growable: false) ??
        const [],
  );
}

class RouteLane {
  const RouteLane({required this.indications, required this.valid});

  final List<String> indications;
  final bool valid;

  Map<String, Object?> toJson() => {'indications': indications, 'valid': valid};

  factory RouteLane.fromJson(Map<String, Object?> json) => RouteLane(
    indications:
        (json['indications'] as List?)?.whereType<String>().toList(
          growable: false,
        ) ??
        const [],
    valid: json['valid'] == true,
  );
}

/// One reviewed marking position: a suggestion a person rejected, or a junction
/// the detector missed and a person added.
///
/// The position is recorded as well as the identifier because a manoeuvre
/// identifier is only an index into the route-engine reply. A reroute, or a
/// second recalculation of the same GPX, renumbers them. Matching on position
/// as well means a rejection still refers to the same place on the ground.
class MarkerReviewPoint {
  const MarkerReviewPoint({
    required this.id,
    required this.position,
    this.label,
  });

  final String id;
  final GeoPoint position;
  final String? label;

  Map<String, Object?> toJson() => {
    'id': id,
    'position': position.toJson(),
    if (label != null) 'label': label,
  };

  factory MarkerReviewPoint.fromJson(Map<String, Object?> json) {
    final rawPosition = json['position'];
    if (rawPosition is! Map) {
      throw const FormatException('Marker review position must be an object.');
    }
    return MarkerReviewPoint(
      id: _requiredString(json, 'id'),
      position: GeoPoint.fromJson(Map<String, Object?>.from(rawPosition)),
      label: _optionalString(json['label']),
    );
  }
}

/// A person's decisions about the suggested marking positions for one route.
///
/// Marker assistance only ever suggests; the rider confirms. Rejection is the
/// missing half of that (#179), and adding is the other half again: the
/// detector misses junctions as well as over-suggesting, so a review surface
/// that could only remove suggestions would be half a tool.
///
/// This rides with the route rather than in a side store, so a rejection sticks
/// for that route through save, restart and hand-off, and so the web planner
/// can read and write the same JSON without a second source of truth.
class MarkerPlanReview {
  const MarkerPlanReview({this.rejected = const [], this.added = const []});

  final List<MarkerReviewPoint> rejected;
  final List<MarkerReviewPoint> added;

  static const empty = MarkerPlanReview();

  bool get isEmpty => rejected.isEmpty && added.isEmpty;
  bool get isNotEmpty => !isEmpty;

  bool rejectsId(String id) => rejected.any((point) => point.id == id);

  /// A compact identity for the decisions this review holds, so a caller that
  /// caches work derived from a route can tell that the review changed.
  String get signature =>
      '${rejected.map((point) => point.id).join(',')}'
      '/${added.map((point) => point.id).join(',')}';

  MarkerPlanReview rejecting(MarkerReviewPoint point) => MarkerPlanReview(
    rejected: [...rejected.where((existing) => existing.id != point.id), point],
    added: added
        .where((existing) => existing.id != point.id)
        .toList(growable: false),
  );

  /// Undoes a rejection, and removes a manually added position of the same
  /// identifier. One control on the review surface, one method here.
  MarkerPlanReview restoring(String id) => MarkerPlanReview(
    rejected: rejected.where((point) => point.id != id).toList(growable: false),
    added: added.where((point) => point.id != id).toList(growable: false),
  );

  MarkerPlanReview adding(MarkerReviewPoint point) => MarkerPlanReview(
    rejected: rejected
        .where((existing) => existing.id != point.id)
        .toList(growable: false),
    added: [...added.where((existing) => existing.id != point.id), point],
  );

  Map<String, Object?> toJson() => {
    if (rejected.isNotEmpty)
      'rejected': rejected.map((point) => point.toJson()).toList(),
    if (added.isNotEmpty)
      'added': added.map((point) => point.toJson()).toList(),
  };

  factory MarkerPlanReview.fromJson(Map<String, Object?> json) =>
      MarkerPlanReview(
        rejected: _reviewPoints(json['rejected']),
        added: _reviewPoints(json['added']),
      );

  static List<MarkerReviewPoint> _reviewPoints(Object? raw) {
    if (raw == null) return const [];
    if (raw is! List) {
      throw const FormatException('Marker review entries must be a list.');
    }
    return raw
        .map((entry) {
          if (entry is! Map) {
            throw const FormatException(
              'Marker review entry must be an object.',
            );
          }
          return MarkerReviewPoint.fromJson(Map<String, Object?>.from(entry));
        })
        .toList(growable: false);
  }
}

class ImportedRoute {
  const ImportedRoute({
    required this.id,
    required this.name,
    required this.importedAt,
    required this.sourceFileName,
    required this.paths,
    required this.waypoints,
    this.maneuvers = const [],
    this.markerReview = MarkerPlanReview.empty,
    this.description,
  });

  static const schemaVersion = 1;

  final String id;
  final String name;
  final String? description;
  final DateTime importedAt;
  final String sourceFileName;
  final List<RoutePath> paths;
  final List<RouteWaypoint> waypoints;
  final List<RouteManeuver> maneuvers;

  /// Which suggested marking positions a person has rejected or added.
  final MarkerPlanReview markerReview;

  ImportedRoute withMarkerReview(MarkerPlanReview review) => ImportedRoute(
    id: id,
    name: name,
    description: description,
    importedAt: importedAt,
    sourceFileName: sourceFileName,
    paths: paths,
    waypoints: waypoints,
    maneuvers: maneuvers,
    markerReview: review,
  );

  Iterable<GeoPoint> get allPoints sync* {
    for (final path in paths) {
      yield* path.points;
    }
    for (final waypoint in waypoints) {
      yield waypoint.point;
    }
  }

  int get pathPointCount =>
      paths.fold(0, (total, path) => total + path.points.length);

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'id': id,
    'name': name,
    if (description != null) 'description': description,
    'importedAt': importedAt.toUtc().toIso8601String(),
    'sourceFileName': sourceFileName,
    'paths': paths.map((path) => path.toJson()).toList(),
    'waypoints': waypoints.map((waypoint) => waypoint.toJson()).toList(),
    if (maneuvers.isNotEmpty)
      'maneuvers': maneuvers.map((maneuver) => maneuver.toJson()).toList(),
    if (markerReview.isNotEmpty) 'markerReview': markerReview.toJson(),
  };

  String toJsonString() => jsonEncode(toJson());

  factory ImportedRoute.fromJson(Map<String, Object?> json) {
    if (json['schemaVersion'] != schemaVersion) {
      throw FormatException(
        'Unsupported route schema version: ${json['schemaVersion']}',
      );
    }
    final rawPaths = json['paths'];
    final rawWaypoints = json['waypoints'];
    final rawManeuvers = json['maneuvers'] ?? const [];
    if (rawPaths is! List || rawWaypoints is! List || rawManeuvers is! List) {
      throw const FormatException(
        'Route paths, waypoints and maneuvers must be lists.',
      );
    }
    final paths = rawPaths
        .map((path) {
          if (path is! Map) {
            throw const FormatException('Route path must be an object.');
          }
          return RoutePath.fromJson(Map<String, Object?>.from(path));
        })
        .toList(growable: false);
    final waypoints = rawWaypoints
        .map((waypoint) {
          if (waypoint is! Map) {
            throw const FormatException('Route waypoint must be an object.');
          }
          return RouteWaypoint.fromJson(Map<String, Object?>.from(waypoint));
        })
        .toList(growable: false);
    final maneuvers = rawManeuvers
        .map((maneuver) {
          if (maneuver is! Map) {
            throw const FormatException('Route maneuver must be an object.');
          }
          return RouteManeuver.fromJson(Map<String, Object?>.from(maneuver));
        })
        .toList(growable: false);
    if (paths.isEmpty && waypoints.isEmpty) {
      throw const FormatException('A route must contain geometry.');
    }
    final markerReview = switch (json['markerReview']) {
      null => MarkerPlanReview.empty,
      final Map<Object?, Object?> value => MarkerPlanReview.fromJson(
        Map<String, Object?>.from(value),
      ),
      _ => throw const FormatException(
        'Route marker review must be an object.',
      ),
    };

    return ImportedRoute(
      id: _requiredString(json, 'id'),
      name: _requiredString(json, 'name'),
      description: _optionalString(json['description']),
      importedAt: DateTime.parse(_requiredString(json, 'importedAt')).toUtc(),
      sourceFileName: _requiredString(json, 'sourceFileName'),
      paths: paths,
      waypoints: waypoints,
      maneuvers: maneuvers,
      markerReview: markerReview,
    );
  }

  factory ImportedRoute.fromJsonString(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map) {
      throw const FormatException('Persisted route must be a JSON object.');
    }
    return ImportedRoute.fromJson(Map<String, Object?>.from(decoded));
  }
}

double _number(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! num || !value.isFinite) {
    throw FormatException('$key must be a finite number.');
  }
  return value.toDouble();
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = _optionalString(json[key]);
  if (value == null) {
    throw FormatException('$key must be a non-empty string.');
  }
  return value;
}

String? _optionalString(Object? value) {
  if (value == null) return null;
  if (value is! String) {
    throw const FormatException('Expected a string value.');
  }
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

double? _optionalBearing(Object? value) {
  if (value == null) return null;
  if (value is! num || !value.isFinite) {
    throw const FormatException('Expected a finite bearing in degrees.');
  }
  return (value.toDouble() % 360 + 360) % 360;
}

DateTime? _optionalDateTime(Object? value) {
  if (value == null) return null;
  if (value is! String) {
    throw const FormatException('Expected a date-time string.');
  }
  return DateTime.parse(value).toUtc();
}
