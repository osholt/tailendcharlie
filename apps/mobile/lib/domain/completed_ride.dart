import 'imported_route.dart';
import 'ride_role.dart';

enum RideLibraryStatus { active, archived, deleted }

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
    this.libraryName,
    this.rating,
    this.notes,
    this.libraryStatus = RideLibraryStatus.active,
    this.deletedAt,
  });

  static const schemaVersion = 2;

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
  final String? libraryName;
  final int? rating;
  final String? notes;
  final RideLibraryStatus libraryStatus;
  final DateTime? deletedAt;

  String get title {
    final renamed = libraryName?.trim();
    if (renamed?.isNotEmpty == true) return renamed!;
    final original = rideName?.trim();
    return original?.isNotEmpty == true ? original! : 'Ride $rideCode';
  }

  Duration get duration => endedAt.difference(startedAt).abs();

  /// More than one recorded track means the location stream stopped long
  /// enough that joining the fixes would invent a straight line (#205).
  bool get hasRecordingGaps =>
      (traveledRoute?.paths
              .where((path) => path.kind == RoutePathKind.track)
              .length ??
          0) >
      1;

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
    if (libraryName != null) 'libraryName': libraryName,
    if (rating != null) 'rating': rating,
    if (notes != null) 'notes': notes,
    'libraryStatus': libraryStatus.name,
    if (deletedAt != null) 'deletedAt': deletedAt!.toUtc().toIso8601String(),
  };

  factory CompletedRide.fromJson(Map<String, Object?> json) {
    final version = (json['schemaVersion'] as num?)?.toInt();
    if (version != 1 && version != schemaVersion) {
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
      libraryName: json['libraryName'] as String?,
      rating: _rating(json['rating']),
      notes: json['notes'] as String?,
      libraryStatus: _libraryStatus(json['libraryStatus']),
      deletedAt: switch (json['deletedAt']) {
        final String value => DateTime.tryParse(value)?.toUtc(),
        _ => null,
      },
    );
  }

  CompletedRide copyWith({
    String? libraryName,
    bool clearLibraryName = false,
    int? rating,
    bool clearRating = false,
    String? notes,
    bool clearNotes = false,
    RideLibraryStatus? libraryStatus,
    DateTime? deletedAt,
    bool clearDeletedAt = false,
  }) => CompletedRide(
    rideId: rideId,
    rideCode: rideCode,
    rideName: rideName,
    localDisplayName: localDisplayName,
    localRole: localRole,
    startedAt: startedAt,
    endedAt: endedAt,
    archivedAt: archivedAt,
    riderCount: riderCount,
    eventCount: eventCount,
    totalDistanceMeters: totalDistanceMeters,
    markerSessions: markerSessions,
    plannedRoute: plannedRoute,
    traveledRoute: traveledRoute,
    libraryName: clearLibraryName ? null : libraryName ?? this.libraryName,
    rating: clearRating ? null : rating ?? this.rating,
    notes: clearNotes ? null : notes ?? this.notes,
    libraryStatus: libraryStatus ?? this.libraryStatus,
    deletedAt: clearDeletedAt ? null : deletedAt ?? this.deletedAt,
  );

  static RideLibraryStatus _libraryStatus(Object? value) {
    if (value is String) {
      for (final status in RideLibraryStatus.values) {
        if (status.name == value) return status;
      }
    }
    return RideLibraryStatus.active;
  }

  static int? _rating(Object? value) {
    final rating = (value as num?)?.toInt();
    return rating != null && rating >= 1 && rating <= 5 ? rating : null;
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
