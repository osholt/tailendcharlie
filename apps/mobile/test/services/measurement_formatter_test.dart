import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/distance_unit.dart';
import 'package:ride_relay/services/measurement_formatter.dart';

void main() {
  test('formats metric and imperial distance and speed', () {
    const metric = MeasurementFormatter(DistanceUnit.kilometres);
    const imperial = MeasurementFormatter(DistanceUnit.miles);

    expect(metric.distance(3200), '3.2 km');
    expect(metric.speed(10), '36 km/h');
    expect(imperial.distance(3218.688), '2.0 mi');
    expect(imperial.speed(10), '22 mph');
    expect(imperial.distance(50), '50 yd');
  });

  test('short navigation distances use natural ten-unit increments', () {
    const metric = MeasurementFormatter(DistanceUnit.kilometres);
    const imperial = MeasurementFormatter(DistanceUnit.miles);

    expect(imperial.distance(151 / 1.093613), '150 yd');
    expect(imperial.distance(22 / 1.093613), '20 yd');
    expect(imperial.distance(49 / 1.093613), '50 yd');
    expect(metric.distance(151), '150 m');
    expect(metric.distance(22), '20 m');
    expect(metric.distance(49), '50 m');
  });

  test('metric speech rounds independently of the visible countdown', () {
    const metric = MeasurementFormatter(DistanceUnit.kilometres);
    expect(metric.spokenDistance(234), '250 m');
    expect(metric.spokenDistance(476), '500 m');
    expect(metric.spokenDistance(641), '600 m');
    expect(metric.spokenDistance(985), '1 km');
    expect(metric.spokenDistance(1000), '1 km');
    expect(metric.spokenDistance(2000), '2 km');
    expect(metric.spokenDistance(1300), '1.3 km');
    expect(metric.spokenDistance(12), '50 m');
    expect(metric.distance(234), '230 m');
    const imperial = MeasurementFormatter(DistanceUnit.miles);
    expect(imperial.spokenDistance(50), imperial.distance(50));
  });

  test('single-unit precision remains below ten', () {
    const metric = MeasurementFormatter(DistanceUnit.kilometres);
    const imperial = MeasurementFormatter(DistanceUnit.miles);

    expect(metric.distance(4), '4 m');
    expect(imperial.distance(4 / 1.093613), '4 yd');
    expect(metric.distance(0), '0 m');
  });
}
