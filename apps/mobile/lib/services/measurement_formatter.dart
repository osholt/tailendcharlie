import '../domain/distance_unit.dart';

class MeasurementFormatter {
  const MeasurementFormatter(this.unit);

  final DistanceUnit unit;

  String distance(double meters) => switch (unit) {
    DistanceUnit.miles => _imperialDistance(meters),
    DistanceUnit.kilometres => _metricDistance(meters),
  };

  String speed(double metersPerSecond) => switch (unit) {
    DistanceUnit.miles => '${(metersPerSecond * 2.236936).round()} mph',
    DistanceUnit.kilometres => '${(metersPerSecond * 3.6).round()} km/h',
  };

  static String _metricDistance(double meters) => meters < 1000
      ? '${_naturalShortDistance(meters)} m'
      : '${(meters / 1000).toStringAsFixed(1)} km';

  static String _imperialDistance(double meters) {
    final miles = meters / 1609.344;
    if (miles < 0.1) {
      return '${_naturalShortDistance(meters * 1.093613)} yd';
    }
    return '${miles.toStringAsFixed(1)} mi';
  }

  /// Navigation-grade short distances, without exposing unit conversion noise.
  ///
  /// A rider can use "150 yards" or "20 metres" at a glance; 151 or 22 is
  /// spurious precision from converting the same route geometry. Below ten,
  /// whole-unit precision still matters and prevents four becoming zero.
  static int _naturalShortDistance(double value) {
    if (value < 10) return value.round();
    return (value / 10).round() * 10;
  }
}
