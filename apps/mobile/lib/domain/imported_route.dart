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

class ImportedRoute {
  const ImportedRoute({
    required this.id,
    required this.name,
    required this.importedAt,
    required this.sourceFileName,
    required this.paths,
    required this.waypoints,
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
    if (rawPaths is! List || rawWaypoints is! List) {
      throw const FormatException('Route paths and waypoints must be lists.');
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
    if (paths.isEmpty && waypoints.isEmpty) {
      throw const FormatException('A route must contain geometry.');
    }

    return ImportedRoute(
      id: _requiredString(json, 'id'),
      name: _requiredString(json, 'name'),
      description: _optionalString(json['description']),
      importedAt: DateTime.parse(_requiredString(json, 'importedAt')).toUtc(),
      sourceFileName: _requiredString(json, 'sourceFileName'),
      paths: paths,
      waypoints: waypoints,
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

DateTime? _optionalDateTime(Object? value) {
  if (value == null) return null;
  if (value is! String) {
    throw const FormatException('Expected a date-time string.');
  }
  return DateTime.parse(value).toUtc();
}
