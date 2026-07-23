import 'imported_route.dart';
import 'ride_role.dart';

class CompletedMarkerSession {
  const CompletedMarkerSession({
    required this.startedAt,
    required this.endedAt,
    required this.uniquePassCount,
  });

  final DateTime startedAt;
  final DateTime? endedAt;
  final int uniquePassCount;

  Map<String, Object?> toJson() => {
    'startedAt': startedAt.toUtc().toIso8601String(),
    if (endedAt != null) 'endedAt': endedAt!.toUtc().toIso8601String(),
    'uniquePassCount': uniquePassCount,
  };

  factory CompletedMarkerSession.fromJson(Map<String, Object?> json) =>
      CompletedMarkerSession(
        startedAt: DateTime.parse(json['startedAt']! as String).toUtc(),
        endedAt: switch (json['endedAt']) {
          final String value => DateTime.parse(value).toUtc(),
          _ => null,
        },
        uniquePassCount: (json['uniquePassCount'] as num?)?.toInt() ?? 0,
      );
}

/// A secret-free, immutable local record derived from a completed ride.
///
/// Invitation credentials, rider identifiers, event payloads and other
/// riders' location trails are deliberately excluded.
class CompletedRide {
  const CompletedRide({
    required this.rideId,
    required this.rideCode,
    required this.rideName,
    required this.localDisplayName,
    required this.localRole,
    required this.startedAt,
    required this.endedAt,
    required this.archivedAt,
    required this.riderCount,
    required this.eventCount,
    required this.totalDistanceMeters,
    required this.markerSessions,
    required this.plannedRoute,
    required this.traveledRoute,
  });

  static const schemaVersion = 1;

  final String rideId;
  final String rideCode;
  final String? rideName;
  final String localDisplayName;
  final RideRole localRole;
  final DateTime startedAt;
  final DateTime endedAt;
  final DateTime archivedAt;
  final int riderCount;
  final int eventCount;
  final double totalDistanceMeters;
  final List<CompletedMarkerSession> markerSessions;
  final ImportedRoute? plannedRoute;
  final ImportedRoute? traveledRoute;

  String get title =>
      rideName?.trim().isNotEmpty == true ? rideName!.trim() : 'Ride $rideCode';

  Duration get duration => endedAt.difference(startedAt).abs();

  Iterable<GeoPoint> get mapPoints sync* {
    if (plannedRoute case final route?) yield* route.allPoints;
    if (traveledRoute case final route?) yield* route.allPoints;
  }

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'rideId': rideId,
    'rideCode': rideCode,
    if (rideName != null) 'rideName': rideName,
    'localDisplayName': localDisplayName,
    'localRole': localRole.name,
    'startedAt': startedAt.toUtc().toIso8601String(),
    'endedAt': endedAt.toUtc().toIso8601String(),
    'archivedAt': archivedAt.toUtc().toIso8601String(),
    'riderCount': riderCount,
    'eventCount': eventCount,
    'totalDistanceMeters': totalDistanceMeters,
    'markerSessions': markerSessions.map((value) => value.toJson()).toList(),
    if (plannedRoute != null) 'plannedRoute': plannedRoute!.toJson(),
    if (traveledRoute != null) 'traveledRoute': traveledRoute!.toJson(),
  };

  factory CompletedRide.fromJson(Map<String, Object?> json) {
    if (json['schemaVersion'] != schemaVersion) {
      throw FormatException(
        'Unsupported completed ride schema: ${json['schemaVersion']}',
      );
    }
    return CompletedRide(
      rideId: json['rideId']! as String,
      rideCode: json['rideCode']! as String,
      rideName: json['rideName'] as String?,
      localDisplayName: json['localDisplayName']! as String,
      localRole: RideRole.values.byName(json['localRole']! as String),
      startedAt: DateTime.parse(json['startedAt']! as String).toUtc(),
      endedAt: DateTime.parse(json['endedAt']! as String).toUtc(),
      archivedAt: DateTime.parse(json['archivedAt']! as String).toUtc(),
      riderCount: (json['riderCount'] as num?)?.toInt() ?? 1,
      eventCount: (json['eventCount'] as num?)?.toInt() ?? 0,
      totalDistanceMeters:
          (json['totalDistanceMeters'] as num?)?.toDouble() ?? 0,
      markerSessions: switch (json['markerSessions']) {
        final List values =>
          values
              .whereType<Map>()
              .map(
                (value) => CompletedMarkerSession.fromJson(
                  Map<String, Object?>.from(value),
                ),
              )
              .toList(growable: false),
        _ => const [],
      },
      plannedRoute: _optionalRoute(json['plannedRoute']),
      traveledRoute: _optionalRoute(json['traveledRoute']),
    );
  }

  static ImportedRoute? _optionalRoute(Object? value) {
    if (value is! Map) return null;
    try {
      return ImportedRoute.fromJson(Map<String, Object?>.from(value));
    } on FormatException {
      // Preserve useful summary metadata when optional geometry is damaged.
      return null;
    }
  }
}
