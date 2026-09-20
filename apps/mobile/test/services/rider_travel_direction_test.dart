import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/services/rider_travel_direction.dart';

void main() {
  const a = GeoPoint(latitude: 51, longitude: -2);
  const b = GeoPoint(latitude: 51, longitude: -1.9997);
  final start = DateTime.utc(2026);
  test('missing GPS course derives direction and holds it through a stop', () {
    final direction = RiderTravelDirection();
    direction.update(point: a, at: start, speedMetersPerSecond: 10);
    expect(direction.headingAt(start), isNull);
    final next = start.add(const Duration(seconds: 2));
    direction.update(point: b, at: next, speedMetersPerSecond: 10);
    expect(direction.headingAt(next), closeTo(90, .1));
    final stopped = next.add(const Duration(seconds: 5));
    direction.update(
      point: b,
      at: stopped,
      speedMetersPerSecond: 0,
      headingDegrees: 0,
    );
    expect(direction.headingAt(stopped), closeTo(90, .1));
    expect(
      direction.headingAt(stopped.add(const Duration(seconds: 31))),
      isNull,
    );
    expect(direction.headingAt(stopped, fresh: false), isNull);
  });
  test('GPS jitter and gaps cannot invent travel direction', () {
    final direction = RiderTravelDirection();
    direction.update(
      point: a,
      at: start,
      speedMetersPerSecond: 0,
      headingDegrees: 0,
    );
    expect(direction.headingAt(start), isNull);
    direction.update(
      point: const GeoPoint(latitude: 51, longitude: -1.99999),
      at: start.add(const Duration(seconds: 2)),
    );
    expect(direction.headingAt(start.add(const Duration(seconds: 2))), isNull);
    direction.update(
      point: b,
      at: start.add(const Duration(seconds: 60)),
      speedMetersPerSecond: 10,
    );
    expect(direction.headingAt(start.add(const Duration(seconds: 60))), isNull);
  });
}
