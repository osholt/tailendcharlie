import 'dart:math' as math;
import 'dart:ui' show Brightness;

enum MapStyleMode { system, light, dark, sunriseSunset }

/// Which palette to use when the map resolves to daytime/light mode.
///
/// Both choices use the same OpenFreeMap Liberty data. [restrained] applies
/// Tail End Charlie's quieter road-first repaint; [original] leaves the
/// provider style unchanged (#489).
enum DayMapStyle { restrained, original }

typedef GeoCoordinate = ({double latitude, double longitude});

extension MapStyleModeLabel on MapStyleMode {
  String get label => switch (this) {
    MapStyleMode.system => 'Match device',
    MapStyleMode.light => 'Light',
    MapStyleMode.dark => 'Dark',
    MapStyleMode.sunriseSunset => 'Sun-based',
  };

  /// Resolves [system] against the platform's current brightness and
  /// [sunriseSunset] against whether the sun is currently up at
  /// [sunPosition] (falling back to [platformBrightness] if no position is
  /// available yet); [light] and [dark] are explicit and need no
  /// resolution.
  bool resolveDark(
    Brightness platformBrightness, {
    GeoCoordinate? sunPosition,
    DateTime? utcNow,
  }) => switch (this) {
    MapStyleMode.dark => true,
    MapStyleMode.light => false,
    MapStyleMode.system => platformBrightness == Brightness.dark,
    MapStyleMode.sunriseSunset =>
      sunPosition == null
          ? platformBrightness == Brightness.dark
          : !isDaylight(
              latitude: sunPosition.latitude,
              longitude: sunPosition.longitude,
              utcNow: utcNow ?? DateTime.now().toUtc(),
            ),
  };
}

extension DayMapStyleLabel on DayMapStyle {
  String get label => switch (this) {
    DayMapStyle.restrained => 'Restrained',
    DayMapStyle.original => 'Original',
  };
}

/// Whether the sun is above the horizon (allowing for the standard -0.833°
/// sunrise/sunset threshold, which accounts for atmospheric refraction and
/// the sun's own angular radius) at [latitude]/[longitude] at [utcNow].
///
/// Uses a compact solar-elevation approximation (declination from day-of-year,
/// hour angle from UTC time adjusted for longitude) rather than solving for
/// exact sunrise/sunset times - it ignores the equation-of-time correction,
/// so it can be off by up to ~15 minutes against a precise almanac. That's
/// fine for deciding a map's colour scheme; it is not an astronomy tool.
bool isDaylight({
  required double latitude,
  required double longitude,
  required DateTime utcNow,
}) {
  final dayOfYear = utcNow.difference(DateTime.utc(utcNow.year)).inDays + 1;
  final declination =
      _degToRad(-23.44) * math.cos(_degToRad(360 / 365.25 * (dayOfYear + 10)));
  final utcHours = utcNow.hour + utcNow.minute / 60 + utcNow.second / 3600;
  // Mean solar time for this longitude: 15 degrees of longitude per hour.
  final solarHours = utcHours + longitude / 15;
  final hourAngle = _degToRad(15 * (solarHours - 12));
  final latitudeRad = _degToRad(latitude);
  final elevation = math.asin(
    math.sin(latitudeRad) * math.sin(declination) +
        math.cos(latitudeRad) * math.cos(declination) * math.cos(hourAngle),
  );
  return elevation > _degToRad(-0.833);
}

double _degToRad(double degrees) => degrees * math.pi / 180;
