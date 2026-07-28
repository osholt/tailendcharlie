import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/imported_route.dart' show GeoPoint;
import 'package:ride_relay/services/recorded_track_cleaner.dart';

void main() {
  const cleaner = RecordedTrackCleaner();

  test('a stop collapses to a single fix', () {
    // 200 m north to a junction, a wait at the lights where the fix wanders a
    // few metres either side, then 200 m east. The junction is a real corner,
    // so it is the wandering that has to disappear, not the turn.
    final junction = _north(200);
    final points = <GeoPoint>[
      for (var index = 0; index < 20; index += 1) _north(index * 10),
      for (var index = 0; index < 12; index += 1)
        _offset(junction, eastMeters: index.isEven ? 6 : -6),
      for (var index = 1; index <= 20; index += 1)
        _offset(junction, eastMeters: index * 10),
    ];

    final cleaned = cleaner.clean(points);

    // One fix at the junction, not thirteen.
    final atJunction = cleaned.where(
      (point) => _metersBetween(point, junction) < 20,
    );
    expect(atJunction, hasLength(1));
    // Both legs are still there.
    expect(_metersBetween(cleaned.first, _north(0)), lessThan(1));
    expect(
      _metersBetween(cleaned.last, _offset(junction, eastMeters: 200)),
      lessThan(1),
    );
  });

  test('a hairpin keeps its shape', () {
    // A 30 m radius hairpin sampled every ~10 m of arc, the tightest case the
    // trail work considered (#166). Its apex must survive tidying.
    final points = <GeoPoint>[
      for (var index = 0; index <= 18; index += 1)
        _arc(radiusMeters: 30, degrees: index * 10),
    ];

    final cleaned = cleaner.clean(points);

    for (final original in points) {
      expect(
        _nearestDistance(original, cleaned),
        lessThan(6),
        reason: 'tidying moved the ridden line at $original',
      );
    }
  });

  test('the first and last fix always survive', () {
    // A recording that is nothing but one long stop: the trail cannot be
    // reduced to a single point, or a route would start and finish nowhere.
    final points = <GeoPoint>[
      for (var index = 0; index < 30; index += 1)
        _offset(_north(0), eastMeters: index.isEven ? 4 : -4),
    ];

    final cleaned = cleaner.clean(points);

    expect(cleaned.length, greaterThanOrEqualTo(2));
    expect(cleaned.first.latitude, points.first.latitude);
    expect(cleaned.first.longitude, points.first.longitude);
    expect(cleaned.last.latitude, points.last.latitude);
    expect(cleaned.last.longitude, points.last.longitude);
  });

  test('a two-point track is returned untouched', () {
    final points = [_north(0), _north(500)];
    expect(cleaner.clean(points), same(points));
  });
}

const _originLatitude = 51.45;
const _originLongitude = -2.59;
const _metresPerDegreeLatitude = 111132.0;
final _metresPerDegreeLongitude =
    _metresPerDegreeLatitude * math.cos(_originLatitude * math.pi / 180);

GeoPoint _north(double meters) => GeoPoint(
  latitude: _originLatitude + meters / _metresPerDegreeLatitude,
  longitude: _originLongitude,
);

GeoPoint _offset(GeoPoint from, {double eastMeters = 0}) => GeoPoint(
  latitude: from.latitude,
  longitude: from.longitude + eastMeters / _metresPerDegreeLongitude,
);

GeoPoint _arc({required double radiusMeters, required double degrees}) {
  final radians = degrees * math.pi / 180;
  return GeoPoint(
    latitude:
        _originLatitude +
        radiusMeters * math.sin(radians) / _metresPerDegreeLatitude,
    longitude:
        _originLongitude +
        radiusMeters * (1 - math.cos(radians)) / _metresPerDegreeLongitude,
  );
}

double _metersBetween(GeoPoint first, GeoPoint second) {
  final x = (second.longitude - first.longitude) * _metresPerDegreeLongitude;
  final y = (second.latitude - first.latitude) * _metresPerDegreeLatitude;
  return math.sqrt(x * x + y * y);
}

double _nearestDistance(GeoPoint point, List<GeoPoint> polyline) {
  var nearest = double.infinity;
  for (var index = 0; index < polyline.length - 1; index += 1) {
    nearest = math.min(
      nearest,
      _distanceToSegment(point, polyline[index], polyline[index + 1]),
    );
  }
  return nearest;
}

double _distanceToSegment(GeoPoint point, GeoPoint start, GeoPoint end) {
  final startX =
      (start.longitude - point.longitude) * _metresPerDegreeLongitude;
  final startY = (start.latitude - point.latitude) * _metresPerDegreeLatitude;
  final endX = (end.longitude - point.longitude) * _metresPerDegreeLongitude;
  final endY = (end.latitude - point.latitude) * _metresPerDegreeLatitude;
  final deltaX = endX - startX;
  final deltaY = endY - startY;
  final lengthSquared = deltaX * deltaX + deltaY * deltaY;
  if (lengthSquared == 0) {
    return math.sqrt(startX * startX + startY * startY);
  }
  final projection = (-(startX * deltaX + startY * deltaY) / lengthSquared)
      .clamp(0.0, 1.0);
  final nearestX = startX + projection * deltaX;
  final nearestY = startY + projection * deltaY;
  return math.sqrt(nearestX * nearestX + nearestY * nearestY);
}
