import 'geo_point.dart';

/// What a logged alert was, as far as the rider who raised it said.
///
/// The one-tap alert (#849) says nothing about what was seen, and that is the
/// point of it. The other two are what an older build raised when a rider chose
/// between a speed camera and the police, and a ride that was shared between old
/// and new phones has both in its log.
enum RideAlertKind {
  alert,
  speedCamera,
  police;

  /// What an older build's rider said it was, or null for the one-tap alert,
  /// which says nothing.
  String? get qualifier => switch (this) {
    RideAlertKind.alert => null,
    RideAlertKind.speedCamera => 'speed camera',
    RideAlertKind.police => 'police',
  };

  /// What the ride review calls it.
  String get label => qualifier == null ? 'Alert' : 'Alert · $qualifier';
}

/// One alert raised during a ride: when, where, and by whom.
///
/// Kept after the ride so it can be listed in the ride review, plotted on its
/// map, copied into a note and exported as a GPX waypoint - the point of it being
/// to find the same moment in dash-cam footage afterwards (#849). It carries a
/// name and nothing else about the rider: like the rest of a completed ride it
/// holds no rider identifier, secret or event payload.
class RideAlertRecord {
  const RideAlertRecord({
    required this.id,
    required this.raisedAt,
    required this.position,
    required this.raisedBy,
    this.raisedByLocalRider = false,
    this.kind = RideAlertKind.alert,
  });

  /// The alert's own identity, stable across duplicate and re-sent events.
  final String id;

  /// When the rider tapped, by their phone's clock, to the second.
  final DateTime raisedAt;

  /// Where the rider was when they tapped. Not where the alert was: by the time
  /// a rider has seen something and tapped, they are a few tens of metres past it.
  final GeoPoint position;

  /// The display name the rider had at the time.
  final String raisedBy;

  /// Whether this phone's own rider raised it.
  final bool raisedByLocalRider;

  final RideAlertKind kind;

  Map<String, Object?> toJson() => {
    'id': id,
    'raisedAt': raisedAt.toUtc().toIso8601String(),
    'position': position.toJson(),
    'raisedBy': raisedBy,
    if (raisedByLocalRider) 'raisedByLocalRider': true,
    if (kind != RideAlertKind.alert) 'kind': kind.name,
  };

  /// Reads one record, or throws [FormatException] when it is unusable.
  ///
  /// Strict about what a map cannot survive - a position outside the globe would
  /// crash the review screen every time it was opened (#359) - and lenient about
  /// everything else, so a record written by a later build still reads.
  factory RideAlertRecord.fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final raisedAt = json['raisedAt'];
    final position = json['position'];
    final raisedBy = json['raisedBy'];
    if (id is! String ||
        id.isEmpty ||
        raisedAt is! String ||
        position is! Map ||
        raisedBy is! String) {
      throw const FormatException('Alert record is incomplete.');
    }
    final time = DateTime.tryParse(raisedAt);
    final latitude = position['latitude'];
    final longitude = position['longitude'];
    if (time == null ||
        latitude is! num ||
        longitude is! num ||
        !latitude.isFinite ||
        !longitude.isFinite ||
        latitude.abs() > 90 ||
        longitude.abs() > 180) {
      throw const FormatException('Alert record has no usable time or place.');
    }
    return RideAlertRecord(
      id: id,
      raisedAt: time.toUtc(),
      position: GeoPoint(
        latitude: latitude.toDouble(),
        longitude: longitude.toDouble(),
      ),
      raisedBy: raisedBy,
      raisedByLocalRider: json['raisedByLocalRider'] == true,
      kind: _kind(json['kind']),
    );
  }

  static RideAlertKind _kind(Object? value) {
    for (final kind in RideAlertKind.values) {
      if (kind.name == value) return kind;
    }
    return RideAlertKind.alert;
  }

  @override
  bool operator ==(Object other) =>
      other is RideAlertRecord &&
      id == other.id &&
      raisedAt == other.raisedAt &&
      position == other.position &&
      raisedBy == other.raisedBy &&
      raisedByLocalRider == other.raisedByLocalRider &&
      kind == other.kind;

  @override
  int get hashCode =>
      Object.hash(id, raisedAt, position, raisedBy, raisedByLocalRider, kind);

  @override
  String toString() => 'RideAlertRecord($id, $raisedAt, $raisedBy)';
}
