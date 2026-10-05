import 'geo_point.dart';

/// One broadcast the leader sent the group during a ride (#854): what, when,
/// from where, and by whom.
///
/// Kept after the ride so the review can say "14:40:02 Oliver: Pull over", which
/// is how a rider reconciles where the group stopped with what they remember being
/// told. Like every part of a completed ride it carries a name and nothing else
/// about the rider: no rider identifier, secret or event payload.
class RideBroadcastRecord {
  const RideBroadcastRecord({
    required this.id,
    required this.sentAt,
    required this.sentBy,
    required this.text,
    required this.kind,
    this.sentByLocalRider = false,
    this.position,
  });

  /// The journal event this came from, stable across duplicate delivery.
  final String id;

  /// When the leader tapped, by their phone's clock, to the second.
  final DateTime sentAt;

  /// The display name the leader had at the time.
  final String sentBy;

  /// What the leader's button said: "Pull over". Their own words, as relayed, so a
  /// kind only a newer build knows still reads.
  final String text;

  /// The `QuickMessage` name the broadcast carried, for choosing its symbol.
  /// Kept as text because a record from a later build may name a kind this one
  /// has never heard of.
  final String kind;

  /// Whether this phone's own rider sent it.
  final bool sentByLocalRider;

  /// Where the leader was, when they relayed one.
  final GeoPoint? position;

  Map<String, Object?> toJson() => {
    'id': id,
    'sentAt': sentAt.toUtc().toIso8601String(),
    'sentBy': sentBy,
    'text': text,
    'kind': kind,
    if (sentByLocalRider) 'sentByLocalRider': true,
    if (position != null) 'position': position!.toJson(),
  };

  /// Reads one record, or throws [FormatException] when it is unusable.
  ///
  /// A position, if there is one, must be on the globe - a map cannot survive one
  /// that is not (#359) - but a record with a bad position is still a record of
  /// what was said, so the position alone is dropped rather than the whole entry.
  factory RideBroadcastRecord.fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final sentAt = json['sentAt'];
    final sentBy = json['sentBy'];
    final text = json['text'];
    if (id is! String ||
        id.isEmpty ||
        sentAt is! String ||
        sentBy is! String ||
        text is! String ||
        text.isEmpty) {
      throw const FormatException('Broadcast record is incomplete.');
    }
    final time = DateTime.tryParse(sentAt);
    if (time == null) {
      throw const FormatException('Broadcast record has no usable time.');
    }
    return RideBroadcastRecord(
      id: id,
      sentAt: time.toUtc(),
      sentBy: sentBy,
      text: text,
      kind: json['kind'] is String ? json['kind']! as String : '',
      sentByLocalRider: json['sentByLocalRider'] == true,
      position: _position(json['position']),
    );
  }

  static GeoPoint? _position(Object? value) {
    if (value is! Map) return null;
    final latitude = value['latitude'];
    final longitude = value['longitude'];
    if (latitude is! num ||
        longitude is! num ||
        !latitude.isFinite ||
        !longitude.isFinite ||
        latitude.abs() > 90 ||
        longitude.abs() > 180) {
      return null;
    }
    return GeoPoint(
      latitude: latitude.toDouble(),
      longitude: longitude.toDouble(),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RideBroadcastRecord &&
      id == other.id &&
      sentAt == other.sentAt &&
      sentBy == other.sentBy &&
      text == other.text &&
      kind == other.kind &&
      sentByLocalRider == other.sentByLocalRider &&
      position == other.position;

  @override
  int get hashCode =>
      Object.hash(id, sentAt, sentBy, text, kind, sentByLocalRider, position);

  @override
  String toString() => 'RideBroadcastRecord($id, $sentAt, $sentBy, $text)';
}
