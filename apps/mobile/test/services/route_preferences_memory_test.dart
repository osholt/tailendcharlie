import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/route_preferences.dart';
import 'package:ride_relay/services/route_preferences_memory.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const memory = RoutePreferencesMemory();

  test('nothing remembered yet is the defaults', () async {
    SharedPreferences.setMockInitialValues({});

    expect(await memory.load(), RoutePreferences.defaults);
  });

  test('the last confirmed options come back', () async {
    SharedPreferences.setMockInitialValues({});
    const chosen = RoutePreferences(
      style: RouteStyle.twisty,
      avoidMotorways: true,
      avoidTolls: true,
    );

    await memory.remember(chosen);

    expect(await memory.load(), chosen);
  });

  test('an unreadable memory is the defaults, not a failure', () async {
    SharedPreferences.setMockInitialValues({
      RoutePreferencesMemory.storageKey: 'not json',
    });

    expect(await memory.load(), RoutePreferences.defaults);
  });
}
