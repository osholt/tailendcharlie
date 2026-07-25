import 'geo_point.dart';

enum HazardType {
  pothole,
  looseSurface,
  debris,
  roadworks,
  collision,
  stoppedVehicle,
  flooding,
  animals,
  policeActivity,
  speedCamera,
  other,
}

extension HazardTypeLabel on HazardType {
  String get label => switch (this) {
    HazardType.pothole => 'Pothole',
    HazardType.looseSurface => 'Loose surface',
    HazardType.debris => 'Debris',
    HazardType.roadworks => 'Roadworks',
    HazardType.collision => 'Collision',
    HazardType.stoppedVehicle => 'Stopped vehicle',
    HazardType.flooding => 'Flooding',
    HazardType.animals => 'Animals',
    HazardType.policeActivity => 'Police activity',
    HazardType.speedCamera => 'Speed camera',
    HazardType.other => 'Other hazard',
  };
}

/// Everything a rider can raise from the app. Enforcement sightings are
/// included: they are first-hand observations by the rider making the report,
/// which is a different thing from redistributing a provider's data, and they
/// are the reports the group most wants to receive.
const riderReportableHazardTypes = <HazardType>[
  HazardType.speedCamera,
  HazardType.policeActivity,
  HazardType.pothole,
  HazardType.looseSurface,
  HazardType.debris,
  HazardType.roadworks,
  HazardType.collision,
  HazardType.stoppedVehicle,
  HazardType.flooding,
  HazardType.animals,
  HazardType.other,
];

extension HazardTypePolicy on HazardType {
  bool get isRiderReportable => riderReportableHazardTypes.contains(this);
}

enum HazardSeverity { advisory, caution, serious, critical }

extension HazardSeverityLabel on HazardSeverity {
  String get label => switch (this) {
    HazardSeverity.advisory => 'Advisory',
    HazardSeverity.caution => 'Caution',
    HazardSeverity.serious => 'Serious',
    HazardSeverity.critical => 'Critical',
  };
}

enum HazardSource { rider, externalProvider }

class HazardReport {
  const HazardReport({
    required this.id,
    required this.rideId,
    required this.type,
    required this.severity,
    required this.position,
    required this.reportedAt,
    required this.updatedAt,
    required this.expiresAt,
    required this.reporterId,
    required this.source,
    this.reporterName,
    this.providerId,
    this.details,
    this.confirmations = 1,
  }) : assert(confirmations >= 1),
       assert(source == HazardSource.rider || providerId != null);

  final String id;
  final String rideId;
  final HazardType type;
  final HazardSeverity severity;
  final GeoPoint position;
  final DateTime reportedAt;
  final DateTime updatedAt;
  final DateTime expiresAt;
  final String reporterId;
  final String? reporterName;
  final HazardSource source;
  final String? providerId;
  final String? details;
  final int confirmations;

  bool isActiveAt(DateTime now) => expiresAt.isAfter(now);

  HazardReport copyWith({
    HazardSeverity? severity,
    DateTime? updatedAt,
    DateTime? expiresAt,
    String? details,
    int? confirmations,
  }) => HazardReport(
    id: id,
    rideId: rideId,
    type: type,
    severity: severity ?? this.severity,
    position: position,
    reportedAt: reportedAt,
    updatedAt: updatedAt ?? this.updatedAt,
    expiresAt: expiresAt ?? this.expiresAt,
    reporterId: reporterId,
    reporterName: reporterName,
    source: source,
    providerId: providerId,
    details: details ?? this.details,
    confirmations: confirmations ?? this.confirmations,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'rideId': rideId,
    'type': type.name,
    'severity': severity.name,
    'position': position.toJson(),
    'reportedAt': reportedAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'expiresAt': expiresAt.toUtc().toIso8601String(),
    'reporterId': reporterId,
    'reporterName': reporterName,
    'source': source.name,
    'providerId': providerId,
    'details': details,
    'confirmations': confirmations,
  };

  factory HazardReport.fromJson(Map<String, Object?> json) => HazardReport(
    id: json['id']! as String,
    rideId: json['rideId']! as String,
    type: HazardType.values.byName(json['type']! as String),
    severity: HazardSeverity.values.byName(json['severity']! as String),
    position: GeoPoint.fromJson(
      Map<String, Object?>.from(json['position']! as Map),
    ),
    reportedAt: DateTime.parse(json['reportedAt']! as String).toLocal(),
    updatedAt: DateTime.parse(json['updatedAt']! as String).toLocal(),
    expiresAt: DateTime.parse(json['expiresAt']! as String).toLocal(),
    reporterId: json['reporterId']! as String,
    reporterName: json['reporterName'] as String?,
    source: HazardSource.values.byName(json['source']! as String),
    providerId: json['providerId'] as String?,
    details: json['details'] as String?,
    confirmations: (json['confirmations'] as num?)?.toInt() ?? 1,
  );
}

class HazardExpiryPolicy {
  const HazardExpiryPolicy();

  Duration durationFor(HazardType type, HazardSeverity severity) {
    if (severity == HazardSeverity.critical) {
      return const Duration(hours: 4);
    }
    return switch (type) {
      HazardType.pothole ||
      HazardType.roadworks ||
      HazardType.flooding => const Duration(hours: 12),
      // Enforcement a rider reports is almost always a mobile van or a patrol
      // car, and both move on. A stale sighting raises a full-screen warning
      // for the whole group, so these expire faster than a road defect.
      HazardType.speedCamera => const Duration(hours: 2),
      HazardType.policeActivity => const Duration(hours: 1),
      HazardType.collision ||
      HazardType.stoppedVehicle => const Duration(hours: 2),
      HazardType.looseSurface ||
      HazardType.debris ||
      HazardType.animals ||
      HazardType.other => const Duration(hours: 6),
    };
  }
}
