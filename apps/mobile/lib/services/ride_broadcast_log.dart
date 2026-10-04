import '../domain/geo_point.dart';
import '../domain/quick_message.dart';
import '../domain/ride_broadcast_record.dart';
import '../domain/ride_event.dart';
import 'received_quick_message.dart';
import 'ride_event_authenticator.dart';
import 'ride_lifecycle.dart';
import 'ride_log_time.dart';
import 'ride_role_journal.dart';

/// Rebuilds the list of broadcasts the leader sent during a ride, from the signed
/// journal (#854).
///
/// The ride history of what the group was told: "14:40:02 Oliver: Pull over". It is
/// a reduction of the same `statusMessage` events the banner and the voice are
/// built from, not a second record kept beside them, so the two cannot disagree
/// about what was sent.
///
/// The same admission rule the banner applies, so the history never lists what the
/// group was never shown:
///
/// * signature-verified for this ride, like every other relayed fact;
/// * a leader broadcast only, and only from a device that was the leader at that
///   point in the journal - a forged "Pull over" is not history;
/// * an acknowledgement is not a broadcast, however it is labelled;
/// * one entry per journal event, so a re-delivered event is one line.
///
/// Not limited to what is still on screen. A broadcast leaves the banner after ten
/// minutes; the history is for after the ride.
class RideBroadcastLogReducer {
  const RideBroadcastLogReducer();

  /// The longest name or text kept. Both are short by construction; this only
  /// bounds what an event from another device can make a list carry.
  static const maximumTextLength = 80;

  List<RideBroadcastRecord> fromEvents({
    required String rideId,
    required String inviteSecret,
    required Iterable<RideEvent> events,
    required String localRiderId,
    Map<String, String> displayNames = const {},
  }) {
    final ordered =
        events
            .where(
              (event) =>
                  event.rideId == rideId &&
                  (event.type == RideEventType.statusMessage ||
                      RideRoleJournal.carriesRole(event.type)) &&
                  RideEventAuthenticator.verify(event, inviteSecret),
            )
            .toList(growable: false)
          ..sort(RideLifecycleReducer.compareEvents);
    final roles = RideRoleJournal();
    final byEventId = <String, RideBroadcastRecord>{};
    for (final event in ordered) {
      if (event.type != RideEventType.statusMessage) {
        roles.apply(event);
        continue;
      }
      if (ReceivedQuickMessageReducer.isAcknowledgement(event)) continue;
      final kind = tryParseQuickMessage(event.payload['message']);
      if (kind == null ||
          !kind.isLeaderBroadcast ||
          !roles.isLeader(event.deviceId)) {
        continue;
      }
      final text = event.payload['label'];
      if (text is! String || text.trim().isEmpty) continue;
      byEventId.putIfAbsent(
        event.id,
        () => RideBroadcastRecord(
          id: event.id,
          sentAt: event.createdAt.toUtc(),
          sentBy: _nameFor(event, displayNames),
          text: _bounded(text),
          kind: kind.name,
          sentByLocalRider: event.deviceId == localRiderId,
          position: _positionFrom(event.payload['position']),
        ),
      );
    }
    final records = byEventId.values.toList(growable: false)
      ..sort((first, second) {
        final byTime = first.sentAt.compareTo(second.sentAt);
        return byTime != 0 ? byTime : first.id.compareTo(second.id);
      });
    return List.unmodifiable(records);
  }

  static String _nameFor(RideEvent event, Map<String, String> names) {
    final relayed = event.payload['senderDisplayName'];
    final name = relayed is String && relayed.trim().isNotEmpty
        ? relayed.trim()
        : names[event.deviceId]?.trim();
    return name == null || name.isEmpty ? 'The leader' : _bounded(name);
  }

  static String _bounded(String value) {
    final trimmed = value.trim();
    return trimmed.length <= maximumTextLength
        ? trimmed
        : trimmed.substring(0, maximumTextLength);
  }

  static GeoPoint? _positionFrom(Object? value) {
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
}

/// How a broadcast reads in the ride review, and what gets copied from it.
extension RideBroadcastRecordLabels on RideBroadcastRecord {
  /// `14:40:02`.
  String get clockLabel => rideLogClock(sentAt);

  /// `2026-10-04 14:40:02`.
  String get timestampLabel => rideLogTimestamp(sentAt);

  /// `Oliver: Pull over`.
  String get headline => '$sentBy: $text';

  /// One line carrying everything, for pasting a whole history into a note.
  String get summaryLine =>
      '$timestampLabel (${rideLogUtc(sentAt)}) · $headline';
}

/// The whole history as text, oldest first.
String rideBroadcastLogText(Iterable<RideBroadcastRecord> broadcasts) =>
    broadcasts.map((broadcast) => broadcast.summaryLine).join('\n');
