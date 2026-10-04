/// How a moment in a ride's log is written, shared by every list in the ride review
/// (#849 alerts, #854 leader messages).
///
/// Times are to the second and in this phone's own time zone, because the point of
/// the log is finding the same moment in dash-cam footage and in a rider's memory.
/// They are formatted by hand rather than with `intl`: the footage's clock does not
/// follow a locale, and neither should this.
library;

/// `14:32:07`.
String rideLogClock(DateTime moment) => _clock(moment.toLocal());

/// `2026-10-04 14:32:07`, the form a footage player shows.
String rideLogTimestamp(DateTime moment) {
  final local = moment.toLocal();
  return '${_date(local)} ${_clock(local)}';
}

/// `2026-10-04 13:32:07 UTC`, for a ride reviewed in another time zone than it was
/// ridden in.
String rideLogUtc(DateTime moment) {
  final utc = moment.toUtc();
  return '${_date(utc)} ${_clock(utc)} UTC';
}

/// The name of the zone [moment] is shown in, such as `BST, UTC+1`, for the line
/// that says what the times are in.
String rideLogTimeZoneLabel(DateTime moment) {
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

String _two(int value) => value.toString().padLeft(2, '0');

String _clock(DateTime moment) =>
    '${_two(moment.hour)}:${_two(moment.minute)}:${_two(moment.second)}';

String _date(DateTime moment) =>
    '${moment.year.toString().padLeft(4, '0')}-${_two(moment.month)}-'
    '${_two(moment.day)}';
