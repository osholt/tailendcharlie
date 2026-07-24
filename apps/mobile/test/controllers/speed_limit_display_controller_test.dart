import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/speed_limit_display_controller.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/services/speed_limit.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final baseTime = DateTime.utc(2026, 7, 24, 10);

  SpeedLimitLocation location(double latitude, DateTime recordedAt) =>
      SpeedLimitLocation(
        point: GeoPoint(latitude: latitude, longitude: -0.12),
        recordedAt: recordedAt,
        accuracyMeters: 5,
        headingDegrees: 0,
      );

  test('persists explicit opt-in', () async {
    SharedPreferences.setMockInitialValues({});
    final controller = await SpeedLimitDisplayController.load(
      provider: _FakeSpeedLimitProvider(),
    );

    expect(controller.enabled, isFalse);
    await controller.setEnabled(true);

    final preferences = await SharedPreferences.getInstance();
    expect(
      preferences.getBool(SpeedLimitDisplayController.preferenceKey),
      isTrue,
    );
    controller.dispose();
  });

  test('waits for movement and publishes the matched limit', () async {
    final provider = _FakeSpeedLimitProvider();
    final controller = SpeedLimitDisplayController.inMemory(
      provider: provider,
      enabled: true,
      clock: () => baseTime,
    );

    controller.observe(location(51.5000, baseTime));
    expect(provider.calls, isEmpty);
    controller.observe(
      location(51.5001, baseTime.add(const Duration(seconds: 1))),
    );
    await controller.waitForIdle();
    expect(provider.calls, isEmpty);
    controller.observe(
      location(51.5004, baseTime.add(const Duration(seconds: 2))),
    );
    await controller.waitForIdle();

    expect(provider.calls, hasLength(1));
    expect(controller.status, SpeedLimitDisplayStatus.known);
    expect(controller.limit?.milesPerHour, 30);
    controller.dispose();
  });

  test(
    'requires both the time interval and movement before rechecking',
    () async {
      final provider = _FakeSpeedLimitProvider();
      var now = baseTime;
      final controller = SpeedLimitDisplayController.inMemory(
        provider: provider,
        enabled: true,
        clock: () => now,
      );

      controller.observe(location(51.5000, baseTime));
      controller.observe(
        location(51.5004, baseTime.add(const Duration(seconds: 1))),
      );
      await controller.waitForIdle();

      now = baseTime.add(const Duration(seconds: 10));
      controller.observe(
        location(51.5008, baseTime.add(const Duration(seconds: 10))),
      );
      await controller.waitForIdle();
      expect(provider.calls, hasLength(1));

      now = baseTime.add(const Duration(seconds: 16));
      controller.observe(
        location(51.5012, baseTime.add(const Duration(seconds: 16))),
      );
      await controller.waitForIdle();
      expect(provider.calls, hasLength(2));
      controller.dispose();
    },
  );

  test('does not look up limits while disabled', () async {
    final provider = _FakeSpeedLimitProvider();
    final controller = SpeedLimitDisplayController.inMemory(provider: provider);

    controller.observe(location(51.5000, baseTime));
    controller.observe(
      location(51.5004, baseTime.add(const Duration(seconds: 1))),
    );
    await controller.waitForIdle();

    expect(provider.calls, isEmpty);
    expect(controller.status, SpeedLimitDisplayStatus.disabled);
    controller.dispose();
  });
}

class _FakeSpeedLimitProvider implements SpeedLimitProvider {
  final calls = <({SpeedLimitLocation previous, SpeedLimitLocation current})>[];
  bool closed = false;

  @override
  Future<SpeedLimitLookupResult> lookup({
    required SpeedLimitLocation previous,
    required SpeedLimitLocation current,
  }) async {
    calls.add((previous: previous, current: current));
    return SpeedLimitLookupResult.known(
      PostedSpeedLimit(
        milesPerHour: 30,
        source: 'Test',
        checkedAt: current.recordedAt,
        matchDistanceMeters: 2,
      ),
    );
  }

  @override
  void close() {
    closed = true;
  }
}
