import 'dart:ui' show Brightness;

import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/map_style_mode_controller.dart';
import 'package:ride_relay/domain/map_style_mode.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('resolveDark follows the platform when in system mode', () {
    expect(MapStyleMode.system.resolveDark(Brightness.dark), isTrue);
    expect(MapStyleMode.system.resolveDark(Brightness.light), isFalse);
    expect(MapStyleMode.dark.resolveDark(Brightness.light), isTrue);
    expect(MapStyleMode.light.resolveDark(Brightness.dark), isFalse);
  });

  group('MapStyleMode.sunriseSunset', () {
    test('falls back to platform brightness without a sun position', () {
      expect(MapStyleMode.sunriseSunset.resolveDark(Brightness.dark), isTrue);
      expect(MapStyleMode.sunriseSunset.resolveDark(Brightness.light), isFalse);
    });

    test('resolves dark at night and light during the day', () {
      const london = (latitude: 51.5074, longitude: -0.1278);

      expect(
        MapStyleMode.sunriseSunset.resolveDark(
          Brightness.light,
          sunPosition: london,
          utcNow: DateTime.utc(2026, 6, 21, 12), // summer noon
        ),
        isFalse,
      );
      expect(
        MapStyleMode.sunriseSunset.resolveDark(
          Brightness.light,
          sunPosition: london,
          utcNow: DateTime.utc(2026, 6, 21, 23), // well past summer dusk
        ),
        isTrue,
      );
    });
  });

  group('isDaylight', () {
    const london = (latitude: 51.5074, longitude: -0.1278);

    test('London is light at summer noon and dark late at night', () {
      expect(
        isDaylight(
          latitude: london.latitude,
          longitude: london.longitude,
          utcNow: DateTime.utc(2026, 6, 21, 12),
        ),
        isTrue,
      );
      expect(
        isDaylight(
          latitude: london.latitude,
          longitude: london.longitude,
          utcNow: DateTime.utc(2026, 6, 21, 23),
        ),
        isFalse,
      );
    });

    test('London is light at winter noon and dark by early evening', () {
      expect(
        isDaylight(
          latitude: london.latitude,
          longitude: london.longitude,
          utcNow: DateTime.utc(2026, 12, 21, 12),
        ),
        isTrue,
      );
      expect(
        isDaylight(
          latitude: london.latitude,
          longitude: london.longitude,
          utcNow: DateTime.utc(2026, 12, 21, 17),
        ),
        isFalse,
      );
    });

    test('the equator is light at solar noon on the equinox', () {
      expect(
        isDaylight(
          latitude: 0,
          longitude: 0,
          utcNow: DateTime.utc(2026, 3, 20, 12),
        ),
        isTrue,
      );
    });
  });

  test('defaults to system and persists an explicit override', () async {
    final controller = await MapStyleModeController.load(
      locationSource: () async => null,
    );
    addTearDown(controller.dispose);

    expect(controller.value, MapStyleMode.system);

    await controller.setMode(MapStyleMode.dark);
    expect(controller.value, MapStyleMode.dark);

    final reloaded = await MapStyleModeController.load(
      locationSource: () async => null,
    );
    addTearDown(reloaded.dispose);
    expect(reloaded.value, MapStyleMode.dark);
  });

  test(
    'defaults to restrained day tiles and persists original tiles',
    () async {
      final controller = await MapStyleModeController.load(
        locationSource: () async => null,
      );
      addTearDown(controller.dispose);

      expect(controller.dayStyle, DayMapStyle.restrained);

      await controller.setDayStyle(DayMapStyle.original);
      expect(controller.dayStyle, DayMapStyle.original);

      final reloaded = await MapStyleModeController.load(
        locationSource: () async => null,
      );
      addTearDown(reloaded.dispose);
      expect(reloaded.dayStyle, DayMapStyle.original);
    },
  );

  group('sun position caching', () {
    test('setMode(sunriseSunset) fetches a location fix', () async {
      const fixture = (latitude: 51.5, longitude: -0.1);
      final controller = await MapStyleModeController.load(
        locationSource: () async => fixture,
      );
      addTearDown(controller.dispose);

      expect(controller.hasSunPosition, isFalse);

      await controller.setMode(MapStyleMode.sunriseSunset);

      expect(controller.hasSunPosition, isTrue);
      expect(
        controller.resolveDark(Brightness.light),
        MapStyleMode.sunriseSunset.resolveDark(
          Brightness.light,
          sunPosition: fixture,
        ),
      );
    });

    test('a persisted sunriseSunset mode fetches a fix on load', () async {
      SharedPreferences.setMockInitialValues({
        MapStyleModeController.preferenceKey: MapStyleMode.sunriseSunset.name,
      });
      var fetches = 0;
      final controller = await MapStyleModeController.load(
        locationSource: () async {
          fetches += 1;
          return (latitude: 51.5, longitude: -0.1);
        },
      );
      addTearDown(controller.dispose);

      expect(controller.value, MapStyleMode.sunriseSunset);
      expect(controller.hasSunPosition, isTrue);
      expect(fetches, 1);
    });

    test('a failed location lookup leaves hasSunPosition false', () async {
      final controller = await MapStyleModeController.load(
        locationSource: () async => throw StateError('no location'),
      );
      addTearDown(controller.dispose);

      await controller.setMode(MapStyleMode.sunriseSunset);

      expect(controller.hasSunPosition, isFalse);
    });
  });
}
