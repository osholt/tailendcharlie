import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/speed_limit_display_controller.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/services/speed_limit.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final baseTime = DateTime.utc(2026, 7, 24, 10);

  SpeedLimitLocation location(
    double latitude,
    DateTime recordedAt, {
    double? accuracyMeters = 5,
    double? headingDegrees = 0,
  }) => SpeedLimitLocation(
    point: GeoPoint(latitude: latitude, longitude: -0.12),
    recordedAt: recordedAt,
    accuracyMeters: accuracyMeters,
    headingDegrees: headingDegrees,
  );

  test('a fresh install shows mapped limits without being asked', () async {
    // #126: the feature was invisible because it shipped off. Nothing is stored
    // until a rider touches the toggle, so an absent key is "never chose".
    SharedPreferences.setMockInitialValues({});
    final controller = await SpeedLimitDisplayController.load(
      provider: _FakeSpeedLimitProvider(),
    );

    expect(controller.enabled, isTrue);
    expect(controller.status, SpeedLimitDisplayStatus.unconfirmedRoad);
    controller.dispose();
  });

  test('a rider who turned it off stays off across the upgrade', () async {
    SharedPreferences.setMockInitialValues({
      SpeedLimitDisplayController.preferenceKey: false,
    });
    final controller = await SpeedLimitDisplayController.load(
      provider: _FakeSpeedLimitProvider(),
    );

    expect(controller.enabled, isFalse);
    expect(controller.status, SpeedLimitDisplayStatus.disabled);
    controller.dispose();
  });

  test(
    'turning it off is recorded so the new default cannot undo it',
    () async {
      SharedPreferences.setMockInitialValues({});
      final controller = await SpeedLimitDisplayController.load(
        provider: _FakeSpeedLimitProvider(),
      );
      await controller.setEnabled(false);

      final preferences = await SharedPreferences.getInstance();
      expect(
        preferences.getBool(SpeedLimitDisplayController.preferenceKey),
        isFalse,
      );
      controller.dispose();
    },
  );

  test('resolves the current road from one stationary fix', () async {
    final provider = _FakeSpeedLimitProvider();
    final controller = SpeedLimitDisplayController.inMemory(
      provider: provider,
      clock: () => baseTime,
    );

    controller.observe(location(51.5000, baseTime));
    await controller.waitForIdle();

    expect(provider.calls, hasLength(1));
    // Stationary: no origin fix, so the provider is told there is no heading to
    // disambiguate with rather than being handed a bearing off GPS jitter.
    expect(provider.calls.single.previous, isNull);
    expect(controller.status, SpeedLimitDisplayStatus.known);
    expect(controller.limit?.milesPerHour, 30);
    controller.dispose();
  });

  test('uses heading once moving to separate parallel carriageways', () async {
    final provider = _FakeSpeedLimitProvider();
    var now = baseTime;
    final controller = SpeedLimitDisplayController.inMemory(
      provider: provider,
      clock: () => now,
    );

    controller.observe(location(51.5000, baseTime));
    await controller.waitForIdle();

    now = baseTime.add(const Duration(seconds: 20));
    controller.observe(location(51.5008, now));
    await controller.waitForIdle();

    expect(provider.calls, hasLength(2));
    // The second lookup is a travelled trace, so a bearing exists even when the
    // platform reports no course.
    expect(provider.calls.last.previous?.point.latitude, 51.5000);
    controller.dispose();
  });

  test('an ambiguous fix says so and resolves on the next good fix', () async {
    final provider = _FakeSpeedLimitProvider(
      results: [
        const SpeedLimitLookupResult.unknown(
          SpeedLimitLookupOutcome.poorAccuracy,
        ),
      ],
    );
    var now = baseTime;
    final controller = SpeedLimitDisplayController.inMemory(
      provider: provider,
      clock: () => now,
    );

    controller.observe(location(51.5000, baseTime, accuracyMeters: 40));
    await controller.waitForIdle();

    expect(controller.status, SpeedLimitDisplayStatus.unconfirmedRoad);
    expect(controller.lastOutcome, SpeedLimitLookupOutcome.poorAccuracy);
    expect(controller.limit, isNull);

    // Still standing in the same spot, but the fix improved: an unconfirmed road
    // is retried where it stands rather than waiting for the bike to move.
    now = baseTime.add(SpeedLimitDisplayController.unconfirmedRetryInterval);
    controller.observe(location(51.5000, now));
    await controller.waitForIdle();

    expect(provider.calls, hasLength(2));
    expect(controller.status, SpeedLimitDisplayStatus.known);
    controller.dispose();
  });

  test('a settled road is not rechecked from a standstill', () async {
    final provider = _FakeSpeedLimitProvider();
    var now = baseTime;
    final controller = SpeedLimitDisplayController.inMemory(
      provider: provider,
      clock: () => now,
    );

    controller.observe(location(51.5000, baseTime));
    await controller.waitForIdle();
    expect(controller.status, SpeedLimitDisplayStatus.known);

    now = baseTime.add(const Duration(minutes: 5));
    controller.observe(location(51.5000, now));
    await controller.waitForIdle();

    expect(provider.calls, hasLength(1));
    controller.dispose();
  });

  test(
    'requires both the time interval and movement before rechecking',
    () async {
      final provider = _FakeSpeedLimitProvider();
      var now = baseTime;
      final controller = SpeedLimitDisplayController.inMemory(
        provider: provider,
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

  test('a start point with nothing mapped nearby stops asking', () async {
    // #145: a ride often starts in a car park whose aisle and neighbouring roads
    // carry no mapped limit at all - the bundled demo route's own start point is
    // one. That cannot change while the bike is still, so it settles rather than
    // re-asking a fair-use service every few seconds, and it resolves on movement.
    final provider = _FakeSpeedLimitProvider(
      results: [
        const SpeedLimitLookupResult.unknown(
          SpeedLimitLookupOutcome.noTaggedLimit,
        ),
      ],
    );
    var now = baseTime;
    final controller = SpeedLimitDisplayController.inMemory(
      provider: provider,
      clock: () => now,
    );

    controller.observe(location(51.5000, baseTime));
    await controller.waitForIdle();

    expect(controller.status, SpeedLimitDisplayStatus.unavailable);
    expect(controller.limit, isNull);

    now = baseTime.add(const Duration(minutes: 5));
    controller.observe(location(51.5000, now));
    await controller.waitForIdle();
    expect(provider.calls, hasLength(1));

    // Setting off resolves it, and the travelled pair now carries a heading.
    now = baseTime.add(const Duration(minutes: 6));
    controller.observe(location(51.5004, now));
    await controller.waitForIdle();

    expect(provider.calls, hasLength(2));
    expect(provider.calls.last.previous?.point.latitude, 51.5000);
    expect(controller.status, SpeedLimitDisplayStatus.known);
    controller.dispose();
  });

  test('an ambiguous junction keeps trying where the bike stands', () async {
    // #145: candidates that genuinely disagree - standing where a 30 becomes a
    // 50 - report the unconfirmed state rather than one of the two limits, and
    // the rider is not left looking at it.
    final provider = _FakeSpeedLimitProvider(
      results: [
        const SpeedLimitLookupResult.unknown(SpeedLimitLookupOutcome.poorMatch),
        const SpeedLimitLookupResult.unknown(SpeedLimitLookupOutcome.poorMatch),
      ],
    );
    var now = baseTime;
    final controller = SpeedLimitDisplayController.inMemory(
      provider: provider,
      clock: () => now,
    );

    controller.observe(location(51.5000, baseTime));
    await controller.waitForIdle();
    expect(controller.status, SpeedLimitDisplayStatus.unconfirmedRoad);

    now = baseTime.add(SpeedLimitDisplayController.unconfirmedRetryInterval);
    controller.observe(location(51.5000, now));
    await controller.waitForIdle();
    expect(provider.calls, hasLength(2));
    expect(controller.status, SpeedLimitDisplayStatus.unconfirmedRoad);

    now = now.add(SpeedLimitDisplayController.unconfirmedRetryInterval);
    controller.observe(location(51.5000, now));
    await controller.waitForIdle();

    expect(provider.calls, hasLength(3));
    expect(controller.status, SpeedLimitDisplayStatus.known);
    controller.dispose();
  });

  test('does not look up limits while disabled', () async {
    final provider = _FakeSpeedLimitProvider();
    final controller = SpeedLimitDisplayController.inMemory(
      provider: provider,
      enabled: false,
    );

    controller.observe(location(51.5000, baseTime));
    controller.observe(
      location(51.5004, baseTime.add(const Duration(seconds: 1))),
    );
    await controller.waitForIdle();

    expect(provider.calls, isEmpty);
    expect(controller.status, SpeedLimitDisplayStatus.disabled);
    controller.dispose();
  });

  // #164: "The speed limit display was showing a loading animation a lot of the
  // time." Every lookup set the status to `checking`, so each time the rider
  // moved far enough to trigger another one the known limit was replaced by a
  // spinner - which on a moving ride is most of the time.
  group('the spinner belongs to the first resolution only', () {
    test('the first lookup may show as checking', () async {
      SharedPreferences.setMockInitialValues({});
      final controller = SpeedLimitDisplayController.inMemory(
        provider: _FakeSpeedLimitProvider(),
      );
      addTearDown(controller.dispose);

      controller.observe(location(51.5, baseTime));

      expect(controller.status, SpeedLimitDisplayStatus.checking);
      expect(controller.limit, isNull);
      await controller.waitForIdle();
      expect(controller.status, SpeedLimitDisplayStatus.known);
    });

    test('a later lookup keeps the number on screen', () async {
      SharedPreferences.setMockInitialValues({});
      var now = baseTime;
      final controller = SpeedLimitDisplayController.inMemory(
        provider: _FakeSpeedLimitProvider(),
        clock: () => now,
      );
      addTearDown(controller.dispose);

      controller.observe(location(51.5, now));
      await controller.waitForIdle();
      expect(controller.status, SpeedLimitDisplayStatus.known);
      final first = controller.limit;

      now = baseTime.add(const Duration(seconds: 30));
      controller.observe(location(51.5015, now));

      expect(
        controller.status,
        SpeedLimitDisplayStatus.known,
        reason:
            'a resolved limit must stay on screen while the next is fetched',
      );
      expect(controller.limit, same(first));
      expect(
        controller.refreshing,
        isTrue,
        reason: 'the recheck is reported without replacing the reading',
      );

      await controller.waitForIdle();
      expect(controller.status, SpeedLimitDisplayStatus.known);
      expect(controller.refreshing, isFalse);
    });

    test('a spinner never returns once anything has resolved', () async {
      SharedPreferences.setMockInitialValues({});
      var now = baseTime;
      final controller = SpeedLimitDisplayController.inMemory(
        provider: _FakeSpeedLimitProvider(),
        clock: () => now,
      );
      addTearDown(controller.dispose);

      controller.observe(location(51.5, now));
      await controller.waitForIdle();

      // Ten more fixes, each far enough to trigger a lookup - a ride.
      for (var step = 1; step <= 10; step += 1) {
        now = baseTime.add(Duration(seconds: 30 * step));
        controller.observe(location(51.5 + step * 0.0015, now));
        expect(
          controller.status,
          isNot(SpeedLimitDisplayStatus.checking),
          reason: 'fix $step put a spinner back in the sign',
        );
        await controller.waitForIdle();
      }
    });

    test('turning it off and on again may show checking again', () async {
      SharedPreferences.setMockInitialValues({});
      final controller = SpeedLimitDisplayController.inMemory(
        provider: _FakeSpeedLimitProvider(),
      );
      addTearDown(controller.dispose);

      controller.observe(location(51.5, baseTime));
      await controller.waitForIdle();
      await controller.setEnabled(false);
      await controller.setEnabled(true);

      expect(controller.limit, isNull, reason: 'the reading was discarded');
      expect(controller.refreshing, isFalse);
      controller.observe(location(51.5, baseTime));
      expect(
        controller.status,
        SpeedLimitDisplayStatus.checking,
        reason: 'with nothing to show, checking is the honest state',
      );
    });
  });
}

class _FakeSpeedLimitProvider implements SpeedLimitProvider {
  _FakeSpeedLimitProvider({this.results = const []});

  /// Consumed in order; anything past the end matches at 30 mph.
  final List<SpeedLimitLookupResult> results;
  final calls =
      <({SpeedLimitLocation? previous, SpeedLimitLocation current})>[];
  bool closed = false;

  @override
  Future<SpeedLimitLookupResult> lookup({
    required SpeedLimitLocation current,
    SpeedLimitLocation? previous,
  }) async {
    final index = calls.length;
    calls.add((previous: previous, current: current));
    if (index < results.length) return results[index];
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
