import 'dart:math' as math;
import '../domain/imported_route.dart';

/// Holds the last supported travel direction through traffic lights. If GPS
/// omits course, successive fixes can establish it without guessing from the
/// route. Stale positions and a new stationary rider have no direction.
class RiderTravelDirection {
  GeoPoint? _previous;
  DateTime? _observedAt;
  double? _heading;

  void update({
    required GeoPoint point,
    required DateTime at,
    double? headingDegrees,
    double? speedMetersPerSecond,
    double accuracyMeters = 0,
  }) {
    if (_observedAt != null && !at.isAfter(_observedAt!)) return;
    final previous = _previous;
    final elapsed = _observedAt == null
        ? null
        : at.difference(_observedAt!).inMilliseconds / 1000;
    final recent = elapsed != null && elapsed > 0 && elapsed <= 30;
    if (!recent) _heading = null;
    final moving =
        speedMetersPerSecond != null &&
        speedMetersPerSecond.isFinite &&
        speedMetersPerSecond >= 1.5;
    if (moving &&
        headingDegrees != null &&
        headingDegrees.isFinite &&
        headingDegrees >= 0 &&
        headingDegrees < 360) {
      _heading = headingDegrees;
    } else if (recent &&
        previous != null &&
        (moving || speedMetersPerSecond == null)) {
      final lat1 = previous.latitude * math.pi / 180;
      final lat2 = point.latitude * math.pi / 180;
      final delta = (point.longitude - previous.longitude) * math.pi / 180;
      final x = delta * math.cos((lat1 + lat2) / 2);
      final y = lat2 - lat1;
      final meters = math.sqrt(x * x + y * y) * 6371000;
      if (meters >= math.max(5, accuracyMeters) && meters / elapsed < 70) {
        _heading =
            (math.atan2(
                      math.sin(delta) * math.cos(lat2),
                      math.cos(lat1) * math.sin(lat2) -
                          math.sin(lat1) * math.cos(lat2) * math.cos(delta),
                    ) *
                    180 /
                    math.pi +
                360) %
            360;
      }
    }
    _previous = point;
    _observedAt = at;
  }

  double? headingAt(DateTime now, {bool fresh = true}) =>
      fresh &&
          _observedAt != null &&
          now.difference(_observedAt!) <= const Duration(seconds: 30)
      ? _heading
      : null;
}
