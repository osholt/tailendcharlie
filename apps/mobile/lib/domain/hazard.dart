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

  /// A rider's one-tap "heads up" to the group (#849). It could be police, a
  /// camera or anything else, so it deliberately says none of them.
  ///
  /// Appended, never reordered, and **never written to the wire under its own
  /// name**: see [HazardReportWire]. An older build decodes a hazard's `type` with
  /// `HazardType.values.byName`, which throws on a name it does not know, and the
  /// journal replays that decode on every restart.
  alert,
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
    HazardType.alert => 'Alert',
  };
}

/// Everything a rider can raise from the app.
///
/// [HazardType.alert] is the one-tap warning that replaced the choice between a
/// speed camera and the police (#849). It is a first-hand observation by the
/// rider making it, which is a different thing from redistributing a provider's
/// data. [HazardType.speedCamera] and [HazardType.policeActivity] are no longer
/// offered, but stay in the enum: a build that still sends them is in a tester's
/// hands, and they are still read, warned about and logged as alerts.
const riderReportableHazardTypes = <HazardType>[
  HazardType.alert,
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

/// The bundled OpenStreetMap fixed-camera layer.
///
/// Named here rather than in the provider so the domain can say what kind of
/// claim it makes without depending on the service that produces it.
const osmFixedCameraProviderId = 'osm-fixed-cameras';

/// Providers whose hazards are standing records rather than sightings.
///
/// Everything else in this model is something somebody saw at a moment: it has
/// an age, it decays, and it eventually expires. A permanent roadside camera
/// has none of those. Reporting one as seen "just now" would tell a rider a
/// patrol is out when all the app knows is what the map has always said.
const standingRecordProviderIds = <String>{osmFixedCameraProviderId};

extension HazardReportProvenance on HazardReport {
  /// True when this hazard is a permanent record, so its age says nothing and
  /// must not be shown or allowed to fade it.
  bool get isStandingRecord =>
      source == HazardSource.externalProvider &&
      standingRecordProviderIds.contains(providerId);
}

/// How a [HazardReport] is written for, and read from, the wire (#849).
///
/// The wire is shared with builds already in testers' hands. 1.0.1+101 decodes a
/// hazard's `type` with `HazardType.values.byName`, which throws on a name it has
/// never heard of, and the ride journal replays that decode every time the ride
/// restarts - so one unknown name in one relayed event would not just drop that
/// event, it would stop the ride opening on that phone.
///
/// An alert is therefore written as an ordinary `other` hazard carrying one extra
/// key, `kind: alert`. Every older build ignores the key and shows "Other hazard"
/// at the right place; this build reads the key and knows it for an alert. A
/// hazard with no `kind` - which is everything an older build writes, police and
/// cameras included - decodes exactly as it always did.
abstract final class HazardReportWire {
  /// The extra key, and the value of it, that makes an `other` hazard an alert.
  static const kindKey = 'kind';
  static const alertKind = 'alert';

  /// The `type` an alert carries on the wire: a name every build can decode.
  static const alertWireType = 'other';

  static String typeFor(HazardType type) =>
      type == HazardType.alert ? alertWireType : type.name;

  /// The type a decoded hazard has, whatever build wrote it.
  ///
  /// The kind marker wins over `type`, so a later build may choose a different
  /// legacy-safe `type` for an alert without this one misreading it.
  static HazardType typeFrom(Map<String, Object?> json) =>
      json[kindKey] == alertKind
      ? HazardType.alert
      : HazardType.values.byName(json['type']! as String);
}

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
    'type': HazardReportWire.typeFor(type),
    if (type == HazardType.alert)
      HazardReportWire.kindKey: HazardReportWire.alertKind,
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
    type: HazardReportWire.typeFrom(json),
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
      // An alert may be either of those, and a rider cannot say which. It takes
      // the shorter of the two: a stale one raises a warning for the whole group,
      // and an hour is long enough for the riders behind to reach it (#849).
      HazardType.alert => const Duration(hours: 1),
      HazardType.collision ||
      HazardType.stoppedVehicle => const Duration(hours: 2),
      HazardType.looseSurface ||
      HazardType.debris ||
      HazardType.animals ||
      HazardType.other => const Duration(hours: 6),
    };
  }
}
