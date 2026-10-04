import '../domain/hazard.dart';
import '../domain/imported_route.dart' as route;
import '../domain/ride_alert_record.dart';
import '../domain/ride_event.dart';
import 'gpx_exporter.dart';
import 'ride_event_authenticator.dart';
import 'ride_lifecycle.dart';

/// Rebuilds the list of alerts a ride raised, from the signed journal (#849).
///
/// The log the ride review shows, plots, copies and exports. It is a reduction of
/// the same `hazardReported` events the live warning is built from, not a second
/// record kept beside them, so the two cannot disagree about what was raised.
///
/// What counts as an alert:
///
/// * one a rider raised with the one-tap alert, which is a hazard of kind
///   [HazardType.alert];
/// * one a rider raised with an older build, which is a speed camera or police
///   hazard. They are alerts too: a ride shared between old and new phones has
///   both, and an older rider's alert must not vanish from a newer rider's
///   review.
///
/// What does not: a hazard from a data provider (the bundled fixed cameras, live
/// traffic) - it was not raised by anyone in the ride - and the road-defect
/// hazards a rider reports from the awareness screen.
///
/// Every rule is the same one the live warning applies, and then some:
///
/// * signature-verified for this ride, like every other relayed fact;
/// * keyed by the hazard's own id, so a re-sent event and a confirmation of an
///   older build's sighting are one entry, and the earliest event names its time;
/// * a malformed or out-of-range event is skipped, never allowed to break the
///   whole log (events from other devices are untrusted);
/// * **not** limited to what is still active. An alert expires from the warning
///   after an hour; it must not leave the log, whose whole use is afterwards.
class RideAlertLogReducer {
  const RideAlertLogReducer();

  /// The longest name kept. A display name is short by construction, so this is
  /// only a bound on what an event from another device can make a list carry.
  static const maximumNameLength = 60;

  List<RideAlertRecord> fromEvents({
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
                  event.type == RideEventType.hazardReported &&
                  RideEventAuthenticator.verify(event, inviteSecret),
            )
            .toList(growable: false)
          ..sort(RideLifecycleReducer.compareEvents);
    final byHazardId = <String, RideAlertRecord>{};
    for (final event in ordered) {
      final hazard = _hazardFrom(event);
      if (hazard == null ||
          hazard.rideId != rideId ||
          hazard.source != HazardSource.rider) {
        continue;
      }
      final kind = _kindFor(hazard.type);
      if (kind == null) continue;
      final latitude = hazard.position.latitude;
      final longitude = hazard.position.longitude;
      if (!latitude.isFinite ||
          !longitude.isFinite ||
          latitude.abs() > 90 ||
          longitude.abs() > 180) {
        continue;
      }
      byHazardId.putIfAbsent(
        hazard.id,
        () => RideAlertRecord(
          id: hazard.id,
          raisedAt: hazard.reportedAt.toUtc(),
          position: hazard.position,
          raisedBy: _nameFor(hazard, displayNames),
          raisedByLocalRider: hazard.reporterId == localRiderId,
          kind: kind,
        ),
      );
    }
    final records = byHazardId.values.toList(growable: false)
      ..sort((first, second) {
        final byTime = first.raisedAt.compareTo(second.raisedAt);
        return byTime != 0 ? byTime : first.id.compareTo(second.id);
      });
    return List.unmodifiable(records);
  }

  static HazardReport? _hazardFrom(RideEvent event) {
    final raw = event.payload['hazard'];
    if (raw is! Map) return null;
    try {
      return HazardReport.fromJson(Map<String, Object?>.from(raw));
    } on Object {
      // Wrong shape, unknown enum name, a position off the globe: any of them
      // is somebody else's malformed event, and none may cost the whole log.
      return null;
    }
  }

  static RideAlertKind? _kindFor(HazardType type) => switch (type) {
    HazardType.alert => RideAlertKind.alert,
    HazardType.speedCamera => RideAlertKind.speedCamera,
    HazardType.policeActivity => RideAlertKind.police,
    _ => null,
  };

  static String _nameFor(HazardReport hazard, Map<String, String> names) {
    final relayed = hazard.reporterName?.trim();
    final name = relayed != null && relayed.isNotEmpty
        ? relayed
        : names[hazard.reporterId]?.trim();
    if (name == null || name.isEmpty) return 'A rider';
    return name.length <= maximumNameLength
        ? name
        : name.substring(0, maximumNameLength);
  }
}

/// How an alert reads in the ride review, and what gets copied from it.
///
/// Times are to the second and in this phone's own time zone: the point of the log
/// is finding the same moment in dash-cam footage. They are formatted by hand
/// rather than with `intl`, because the footage's clock does not follow a locale
/// and neither should this.
extension RideAlertRecordLabels on RideAlertRecord {
  /// `14:32:07`.
  String get clockLabel => _clock(raisedAt.toLocal());

  /// `2026-10-04 14:32:07`. The one thing the copy button puts on the clipboard.
  String get timestampLabel {
    final local = raisedAt.toLocal();
    return '${_date(local)} ${_clock(local)}';
  }

  /// `2026-10-04 13:32:07 UTC`, for a ride reviewed in another time zone than it
  /// was ridden in.
  String get utcLabel {
    final utc = raisedAt.toUtc();
    return '${_date(utc)} ${_clock(utc)} UTC';
  }

  /// `51.50012, -3.18012`: five decimal places, about a metre.
  String get positionLabel =>
      '${position.latitude.toStringAsFixed(5)}, '
      '${position.longitude.toStringAsFixed(5)}';

  /// One line carrying everything, for pasting a whole log into a note.
  String get summaryLine =>
      '$timestampLabel ($utcLabel) · $raisedBy · $positionLabel';
}

/// The whole log as text, oldest first.
String rideAlertLogText(Iterable<RideAlertRecord> alerts) =>
    alerts.map((alert) => alert.summaryLine).join('\n');

/// The name of the zone [moment] is shown in, such as `BST`, for the line that
/// says what the times are in.
String rideAlertTimeZoneLabel(DateTime moment) {
  final local = moment.toLocal();
  final offset = local.timeZoneOffset;
  final sign = offset.isNegative ? '-' : '+';
  final hours = offset.inHours.abs();
  final minutes = offset.inMinutes.abs().remainder(60);
  final utc = minutes == 0
      ? 'UTC$sign$hours'
      : 'UTC$sign$hours:${minutes.toString().padLeft(2, '0')}';
  final name = local.timeZoneName;
  return name.isEmpty || name == utc ? utc : '$name, $utc';
}

/// The alerts as GPX waypoints, for [GpxExporter.export].
///
/// Named and described rather than bare points, because a ride's GPX is opened in
/// map and footage tools that show a waypoint's name and nothing else: the clock
/// time is in the name, and the description repeats it with the date and in UTC.
List<GpxAlertWaypoint> rideAlertGpxWaypoints(
  Iterable<RideAlertRecord> alerts,
) => [
  for (final alert in alerts)
    GpxAlertWaypoint(
      point: route.GeoPoint(
        latitude: alert.position.latitude,
        longitude: alert.position.longitude,
        recordedAt: alert.raisedAt,
      ),
      name: 'Alert ${alert.clockLabel}',
      description:
          '${alert.kind.label} raised by ${alert.raisedBy} at '
          '${alert.timestampLabel} local time (${alert.utcLabel}).',
    ),
];

String _two(int value) => value.toString().padLeft(2, '0');

String _clock(DateTime moment) =>
    '${_two(moment.hour)}:${_two(moment.minute)}:${_two(moment.second)}';

String _date(DateTime moment) =>
    '${moment.year.toString().padLeft(4, '0')}-${_two(moment.month)}-'
    '${_two(moment.day)}';
