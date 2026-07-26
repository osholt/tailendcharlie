import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/services/navigation_heading.dart';

final _start = DateTime.utc(2026, 7, 25, 12);

/// Feeds a sequence of one-per-second fixes and returns the bearing after each.
List<double> _drive(
  NavigationHeadingSmoother smoother,
  List<double> headings, {
  double speed = 14,
  bool maneuverImminent = false,
  Duration interval = const Duration(seconds: 1),
  Duration from = Duration.zero,
}) {
  final bearings = <double>[];
  for (var index = 0; index < headings.length; index += 1) {
    bearings.add(
      smoother.update(
            headingDegrees: headings[index],
            speedMetersPerSecond: speed,
            at: _start.add(from + interval * index),
            maneuverImminent: maneuverImminent,
          ) ??
          double.nan,
    );
  }
  return bearings;
}

void main() {
  group('bearing arithmetic', () {
    test('normalises onto a single turn', () {
      expect(normaliseBearingDegrees(0), 0);
      expect(normaliseBearingDegrees(360), 0);
      expect(normaliseBearingDegrees(-10), 350);
      expect(normaliseBearingDegrees(725), 5);
    });

    test('takes the shortest angular path across north', () {
      expect(shortestBearingDeltaDegrees(1, 359), closeTo(2, 1e-9));
      expect(shortestBearingDeltaDegrees(359, 1), closeTo(-2, 1e-9));
      expect(shortestBearingDeltaDegrees(10, 350), closeTo(20, 1e-9));
      expect(shortestBearingDeltaDegrees(180, 0).abs(), closeTo(180, 1e-9));
    });
  });

  test('adopts the first usable heading instead of starting north-up', () {
    final smoother = NavigationHeadingSmoother();
    expect(smoother.bearingDegrees, isNull);
    expect(
      smoother.update(headingDegrees: 217, speedMetersPerSecond: 0, at: _start),
      217,
    );
  });

  test('a gently curving road produces no rotation at all', () {
    final smoother = NavigationHeadingSmoother();
    _drive(smoother, [90]);
    // A sequence of small course changes, none of them beyond the deadband.
    final bearings = _drive(smoother, [
      92,
      89,
      93,
      91,
      94,
      90,
      92,
    ], from: const Duration(seconds: 1));

    expect(bearings.every((bearing) => bearing == 90), isTrue);
    expect(smoother.settling, isFalse);
  });

  test('a sustained bend rotates smoothly once it leaves the deadband', () {
    final smoother = NavigationHeadingSmoother();
    _drive(smoother, [0]);
    // Two degrees per second for half a minute: a long sweeping A-road bend.
    final bearings = _drive(
      smoother,
      List<double>.generate(30, (index) => 2.0 * (index + 1)),
      from: const Duration(seconds: 1),
    );

    // It holds through the deadband, then tracks continuously rather than
    // jumping in deadband-sized steps.
    expect(bearings.first, 0);
    expect(bearings.last, greaterThan(45));
    var moves = 0;
    for (var index = 1; index < bearings.length; index += 1) {
      if (bearings[index] != bearings[index - 1]) moves += 1;
    }
    expect(moves, greaterThan(20));
  });

  test('a 90 degree junction eases to the new bearing within bounded time', () {
    final smoother = NavigationHeadingSmoother();
    _drive(smoother, [0]);
    final bearings = _drive(
      smoother,
      List<double>.filled(6, 90),
      from: const Duration(seconds: 1),
    );

    // Rate limited: no single one second step exceeds the documented rate.
    var previous = 0.0;
    for (final bearing in bearings) {
      expect(
        shortestBearingDeltaDegrees(bearing, previous).abs(),
        lessThanOrEqualTo(smoother.maximumRotationDegreesPerSecond + 1e-9),
      );
      previous = bearing;
    }
    // Settled within four seconds, with no overshoot past the new bearing.
    expect(bearings[3], closeTo(90, 2.5));
    expect(bearings.every((bearing) => bearing <= 90.001), isTrue);
    expect(bearings.last, closeTo(90, 2.5));
  });

  test('crossing north rotates the short way round', () {
    final smoother = NavigationHeadingSmoother();
    _drive(smoother, [355]);
    final bearings = _drive(smoother, [
      359,
      3,
      7,
      11,
      15,
    ], from: const Duration(seconds: 1));

    // Every intermediate bearing is close to north, never out through south.
    for (final bearing in bearings) {
      final fromNorth = shortestBearingDeltaDegrees(bearing, 0).abs();
      expect(
        fromNorth,
        lessThan(20),
        reason: 'bearing $bearing went the long way',
      );
    }
    expect(bearings.last, closeTo(11, 6));
  });

  test('a noisy stationary fix leaves the map bearing alone', () {
    final smoother = NavigationHeadingSmoother();
    _drive(smoother, [120]);
    final bearings = _drive(
      smoother,
      [200, 14, 305, 96, 180],
      speed: 0.4,
      from: const Duration(seconds: 1),
    );

    expect(bearings.every((bearing) => bearing == 120), isTrue);
    expect(smoother.bearingDegrees, 120);
  });

  test('rotation stays frozen right up to the documented speed', () {
    final smoother = NavigationHeadingSmoother();
    _drive(smoother, [10]);
    _drive(
      smoother,
      [100],
      speed: smoother.freezeBelowMetersPerSecond - 0.01,
      from: const Duration(seconds: 1),
    );
    expect(smoother.bearingDegrees, 10);

    _drive(
      smoother,
      [100],
      speed: smoother.freezeBelowMetersPerSecond,
      from: const Duration(seconds: 2),
    );
    expect(smoother.bearingDegrees, isNot(10));
  });

  test('an implausible single jump is rejected, not animated to', () {
    final smoother = NavigationHeadingSmoother();
    _drive(smoother, [90]);
    // One wild fix, then the real course resumes: the map never moved.
    final bearings = _drive(smoother, [
      265,
      91,
      90,
    ], from: const Duration(seconds: 1));

    expect(bearings.every((bearing) => bearing == 90), isTrue);
  });

  test('a corroborated jump is accepted after one fix of latency', () {
    final smoother = NavigationHeadingSmoother();
    _drive(smoother, [90]);
    // A tunnel exit: the first fix on the new heading is held back, the second
    // confirms it, and the rate limit eases the map round from there.
    final bearings = _drive(smoother, [
      265,
      268,
      270,
      270,
      270,
      270,
    ], from: const Duration(seconds: 1));

    expect(bearings.first, 90);
    expect(shortestBearingDeltaDegrees(bearings[1], 90).abs(), greaterThan(1));
    expect(bearings.last, closeTo(270, 3));
  });

  test('an imminent manoeuvre tightens the deadband', () {
    final relaxed = NavigationHeadingSmoother();
    _drive(relaxed, [90]);
    _drive(relaxed, [95, 95], from: const Duration(seconds: 1));
    expect(relaxed.bearingDegrees, 90);

    final tightened = NavigationHeadingSmoother();
    _drive(tightened, [90]);
    _drive(
      tightened,
      [95, 95],
      maneuverImminent: true,
      from: const Duration(seconds: 1),
    );
    expect(tightened.bearingDegrees, isNot(90));
    expect(tightened.bearingDegrees, closeTo(93, 3));
  });

  test('a long gap in fixes still eases rather than snapping', () {
    final smoother = NavigationHeadingSmoother();
    _drive(smoother, [0]);
    // Two corroborating fixes 40 seconds later, as after a long tunnel.
    smoother.update(
      headingDegrees: 200,
      speedMetersPerSecond: 20,
      at: _start.add(const Duration(seconds: 40)),
    );
    final bearing = smoother.update(
      headingDegrees: 202,
      speedMetersPerSecond: 20,
      at: _start.add(const Duration(seconds: 41)),
    );

    expect(
      shortestBearingDeltaDegrees(bearing!, 0).abs(),
      lessThanOrEqualTo(smoother.maximumRotationDegreesPerSecond * 2 + 1e-9),
    );
  });

  test('missing or invalid headings hold the last bearing', () {
    final smoother = NavigationHeadingSmoother();
    _drive(smoother, [45]);

    expect(
      smoother.update(
        headingDegrees: null,
        speedMetersPerSecond: 20,
        at: _start.add(const Duration(seconds: 1)),
      ),
      45,
    );
    expect(
      smoother.update(
        headingDegrees: double.nan,
        speedMetersPerSecond: 20,
        at: _start.add(const Duration(seconds: 2)),
      ),
      45,
    );
  });

  test('reset forgets the ride so a new one adopts its own first heading', () {
    final smoother = NavigationHeadingSmoother();
    _drive(smoother, [45]);
    smoother.reset();

    expect(smoother.bearingDegrees, isNull);
    expect(
      smoother.update(
        headingDegrees: 300,
        speedMetersPerSecond: 18,
        at: _start.add(const Duration(minutes: 5)),
      ),
      300,
    );
  });
}
