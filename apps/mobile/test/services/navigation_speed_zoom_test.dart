import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/services/navigation_camera.dart';
import 'package:ride_relay/services/navigation_speed_zoom.dart';

/// #936: the follow camera is closer around town and further out at speed, and
/// does not pump at junctions or in stop-start traffic.
///
/// > I think the map zoom should change based on vehicle speed. Around town being
/// > more zoomed in would be useful.
///
/// The mapping and the smoothing are pure, so a whole ride is replayed through
/// them here as a list of (seconds, speed) fixes.
void main() {
  const mph = 0.44704;
  final start = DateTime.utc(2026, 10, 10, 9);

  group('the speed to zoom mapping', () {
    test('is as close as it goes at town speed and as far out at open-road '
        'speed', () {
      expect(NavigationSpeedZoom.offsetFor(0), navigationZoomTownOffset);
      expect(
        NavigationSpeedZoom.offsetFor(navigationZoomTownSpeedMetersPerSecond),
        navigationZoomTownOffset,
      );
      expect(
        NavigationSpeedZoom.offsetFor(
          navigationZoomOpenRoadSpeedMetersPerSecond,
        ),
        navigationZoomOpenRoadOffset,
      );
      expect(NavigationSpeedZoom.offsetFor(50), navigationZoomOpenRoadOffset);
    });

    test('puts a 30 mph town well closer than a 60 mph road', () {
      final town = NavigationSpeedZoom.offsetFor(30 * mph);
      final road = NavigationSpeedZoom.offsetFor(60 * mph);
      expect(town, greaterThan(0.3), reason: 'closer than the resting zoom');
      expect(road, lessThan(-0.4), reason: 'and 60 mph is further out');
      expect(
        town - road,
        greaterThan(1),
        reason: 'more than a whole level, a factor of two in scale',
      );
    });

    test('never gets closer as the rider gets faster', () {
      var previous = double.infinity;
      for (var speed = 0.0; speed <= 50; speed += 0.25) {
        final offset = NavigationSpeedZoom.offsetFor(speed);
        expect(offset, lessThanOrEqualTo(previous + 1e-12), reason: '$speed');
        previous = offset;
      }
    });

    test('has no step anywhere: a small change of speed is a small change '
        'of zoom', () {
      for (var speed = 0.0; speed < 50; speed += 0.05) {
        final jump =
            (NavigationSpeedZoom.offsetFor(speed + 0.05) -
                    NavigationSpeedZoom.offsetFor(speed))
                .abs();
        expect(jump, lessThan(0.01), reason: 'at $speed m/s');
      }
    });

    test(
      'is flat where the speed thresholds meet it, so nothing snaps there',
      () {
        for (final threshold in [
          navigationZoomTownSpeedMetersPerSecond,
          navigationZoomOpenRoadSpeedMetersPerSecond,
        ]) {
          final slope =
              (NavigationSpeedZoom.offsetFor(threshold + 0.01) -
                  NavigationSpeedZoom.offsetFor(threshold - 0.01)) /
              0.02;
          expect(slope.abs(), lessThan(0.001), reason: 'at $threshold m/s');
        }
      },
    );

    test('reads an unknown or non-finite speed as stopped', () {
      for (final speed in [null, double.nan, double.infinity, -3.0]) {
        expect(
          NavigationSpeedZoom.offsetFor(speed),
          navigationZoomTownOffset,
          reason: '$speed',
        );
      }
    });
  });

  group('the planner', () {
    test('adds the offset to the resting zoom of each orientation', () {
      for (final landscape in [false, true]) {
        final resting = NavigationCameraPlanner.plan(
          speedMetersPerSecond: 0,
          landscape: landscape,
        );
        final adaptive = NavigationCameraPlanner.plan(
          speedMetersPerSecond: 20,
          landscape: landscape,
          speedZoomOffset: 0.9,
        );
        expect(adaptive.zoom, closeTo(resting.zoom + 0.9, 1e-9));
      }
    });

    test('without an offset keeps the zoom it always had', () {
      final legacy = NavigationCameraPlanner.plan(
        speedMetersPerSecond: 30,
        landscape: false,
      );
      expect(legacy.zoom, closeTo(14.65 - 0.8, 1e-9));
      for (final bad in [double.nan, double.infinity]) {
        final plan = NavigationCameraPlanner.plan(
          speedMetersPerSecond: 30,
          landscape: false,
          speedZoomOffset: bad,
        );
        expect(plan.zoom, legacy.zoom, reason: '$bad is not an offset');
      }
    });

    test('leaves the tilt and the rider position to the speed curve', () {
      final without = NavigationCameraPlanner.plan(
        speedMetersPerSecond: 20,
        landscape: false,
      );
      final within = NavigationCameraPlanner.plan(
        speedMetersPerSecond: 20,
        landscape: false,
        speedZoomOffset: 0.9,
      );
      expect(within.tilt, without.tilt);
      expect(within.riderViewportFraction, without.riderViewportFraction);
      expect(within.forwardBiasPixels, without.forwardBiasPixels);
    });

    test('solves the look-ahead at the zoom it chose', () {
      final close = NavigationCameraPlanner.plan(
        speedMetersPerSecond: 5,
        landscape: false,
        speedZoomOffset: navigationZoomTownOffset,
      );
      final far = NavigationCameraPlanner.plan(
        speedMetersPerSecond: 5,
        landscape: false,
        speedZoomOffset: navigationZoomOpenRoadOffset,
      );
      expect(
        close.lookAheadMeters,
        lessThan(far.lookAheadMeters),
        reason:
            'the same screen distance is fewer metres when zoomed in, '
            'so the camera aims nearer',
      );
    });
  });

  group('the governor', () {
    /// Replays `(seconds, speed)` fixes and returns the offset after each.
    List<double> replay(
      NavigationZoomGovernor governor,
      Iterable<(double, double)> fixes,
    ) => [
      for (final (seconds, speed) in fixes)
        governor.update(
          speedMetersPerSecond: speed,
          at: start.add(Duration(milliseconds: (seconds * 1000).round())),
        ),
    ];

    /// One fix a second at [speed] for [seconds], from [from].
    Iterable<(double, double)> steady(
      double from,
      double seconds,
      double speed,
    ) sync* {
      for (var second = 0.0; second <= seconds; second += 1) {
        yield (from + second, speed);
      }
    }

    test('starts at the resting zoom and takes the first speed as it is', () {
      final governor = NavigationZoomGovernor();
      expect(governor.offset, 0);
      expect(governor.hasObservation, isFalse);
      final first = governor.update(speedMetersPerSecond: 25, at: start);
      expect(first, NavigationSpeedZoom.offsetFor(25));
      expect(governor.hasObservation, isTrue);
    });

    test(
      'a junction slow-down on an open road does not move the zoom at all',
      () {
        final governor = NavigationZoomGovernor();
        final cruise = replay(governor, steady(0, 40, 20)).last;
        final dip = replay(governor, [
          ...steady(41, 1, 12),
          ...steady(43, 5, 4),
          ...steady(49, 8, 20),
          ...steady(58, 20, 20),
        ]);
        expect(cruise, closeTo(NavigationSpeedZoom.offsetFor(20), 1e-9));
        expect(
          dip.every((offset) => offset == cruise),
          isTrue,
          reason:
              'a rider who slows for six seconds is about to speed up again',
        );
      },
    );

    test('a red light changes nothing, however long it lasts', () {
      final governor = NavigationZoomGovernor();
      replay(governor, steady(0, 30, 22));
      final braking = replay(governor, [(31, 15), (32, 9), (33, 4), (34, 1.5)]);
      final atTheLine = braking.last;
      final waiting = replay(governor, steady(35, 120, 0));
      expect(waiting.every((offset) => offset == atTheLine), isTrue);
      expect(governor.filteredSpeedMetersPerSecond, greaterThan(10));
    });

    test('stop-start traffic does not pump the zoom', () {
      final governor = NavigationZoomGovernor();
      final fixes = <(double, double)>[];
      var second = 0.0;
      for (var cycle = 0; cycle < 12; cycle++) {
        for (final speed in [0.0, 0.0, 2.5, 5.0, 7.5, 9.0, 6.0, 3.0, 0.5]) {
          fixes.add((second++, speed));
        }
      }
      final offsets = replay(governor, fixes);
      final range = offsets.reduce(math.max) - offsets.reduce(math.min);
      expect(
        range,
        lessThan(navigationZoomDeadbandLevels),
        reason: 'a whole queue is one scale',
      );
    });

    test(
      'speed wandering around a value inside the dead-band changes nothing',
      () {
        final governor = NavigationZoomGovernor();
        final fixes = <(double, double)>[
          for (var second = 0; second < 120; second++)
            (second.toDouble(), 12 + 1.5 * math.sin(second / 3)),
        ];
        final offsets = replay(governor, fixes);
        expect(offsets.toSet(), hasLength(1));
      },
    );

    test('speeding up opens the view promptly', () {
      final governor = NavigationZoomGovernor();
      final town = replay(governor, steady(0, 30, 9)).last;
      final accelerating = replay(governor, steady(31, 12, 26));
      expect(
        accelerating.last,
        lessThan(town - 0.5),
        reason: 'within twelve seconds of a fast road the view is out',
      );
      // And it starts at once, not after a wait.
      expect(accelerating[3], lessThan(town - navigationZoomDeadbandLevels));
    });

    test('leaving the fast road for a town comes in, but only after the '
        'dwell and never faster than the limit', () {
      final governor = NavigationZoomGovernor();
      final fast = replay(governor, steady(0, 40, 30)).last;
      expect(fast, navigationZoomOpenRoadOffset);

      final offsets = replay(governor, steady(41, 90, 13));
      // Nothing for the first moving seconds: the want has not lasted.
      expect(
        offsets
            .take(navigationZoomInDwellSeconds.floor() - 1)
            .every((offset) => offset == fast),
        isTrue,
      );
      // Then it arrives at the zoom a town speed calls for. Once it has started
      // it carries on rather than stopping a whole dead-band short.
      expect(
        offsets.last,
        closeTo(NavigationSpeedZoom.offsetFor(13), 0.05),
        reason: 'closer to the target than the dead-band',
      );
      expect(offsets.last, greaterThan(fast + 1));
      // At a bounded rate.
      var previous = fast;
      for (final offset in offsets) {
        expect(
          (offset - previous).abs(),
          lessThanOrEqualTo(navigationZoomMaximumRateLevelsPerSecond + 1e-9),
        );
        previous = offset;
      }
    });

    test('believes a rider who is slowing down more slowly than one who is '
        'speeding up', () {
      final slowing = NavigationZoomGovernor();
      replay(slowing, steady(0, 30, 20));
      replay(slowing, steady(31, 5, 10));
      final fallen = 20 - slowing.filteredSpeedMetersPerSecond!;

      final speeding = NavigationZoomGovernor();
      replay(speeding, steady(0, 30, 10));
      replay(speeding, steady(31, 5, 20));
      final risen = speeding.filteredSpeedMetersPerSecond! - 10;

      expect(
        fallen,
        lessThan(risen - 2),
        reason:
            'the same ten metres a second, five seconds on, is believed '
            'more readily on the way up',
      );
    });

    test('a gap in the fixes does not make one giant step', () {
      final governor = NavigationZoomGovernor();
      final fast = replay(governor, steady(0, 40, 30)).last;
      replay(governor, steady(41, 12, 13));
      final before = governor.offset;
      final after = governor.update(
        speedMetersPerSecond: 13,
        at: start.add(const Duration(minutes: 10)),
      );
      expect(before, greaterThan(fast));
      expect(
        (after - before).abs(),
        lessThanOrEqualTo(
          navigationZoomMaximumRateLevelsPerSecond *
                  navigationZoomMaximumStepSeconds +
              1e-9,
        ),
      );
    });

    test('ignores a fix with no usable speed or no new time', () {
      final governor = NavigationZoomGovernor();
      governor.update(speedMetersPerSecond: 20, at: start);
      final before = governor.offset;
      governor.update(speedMetersPerSecond: double.nan, at: start);
      governor.update(
        speedMetersPerSecond: 0,
        at: start.subtract(const Duration(seconds: 5)),
      );
      governor.update(speedMetersPerSecond: 3, at: start);
      expect(governor.offset, before);
      expect(
        governor.filteredSpeedMetersPerSecond,
        20,
        reason: 'neither a stale fix nor a repeat of the instant moves it',
      );
    });

    test('forgets everything on reset', () {
      final governor = NavigationZoomGovernor();
      replay(governor, steady(0, 40, 30));
      governor.reset();
      expect(governor.offset, 0);
      expect(governor.hasObservation, isFalse);
      expect(
        governor.update(speedMetersPerSecond: 5, at: start),
        NavigationSpeedZoom.offsetFor(5),
      );
    });
  });
}
