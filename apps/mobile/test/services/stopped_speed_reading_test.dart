import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/services/stopped_speed_reading.dart';

void main() {
  group('a stopped bike reads zero, a lost one reads nothing (#445)', () {
    test('rolling to a halt and going quiet reads as stopped', () {
      // What stopping looks like through a distanceFilter: the speed falls, then
      // the fixes stop, because a stationary phone has nothing to report.
      expect(
        stoppedSpeedReading(
          lastObservedSpeedMetersPerSecond: 1.5,
          silence: const Duration(seconds: 10),
        ),
        StoppedSpeedReading.stopped,
      );
    });

    test('going quiet at speed does not read as stopped', () {
      // A tunnel at 60 mph produces exactly the same silence. Zero here would be
      // a lie beside a speedometer, which is the asymmetry the whole rule turns
      // on.
      expect(
        stoppedSpeedReading(
          lastObservedSpeedMetersPerSecond: 27,
          silence: const Duration(seconds: 30),
        ),
        StoppedSpeedReading.unknown,
      );
    });

    test('a short gap between ordinary fixes changes nothing', () {
      // Fixes are irregular on a motorcycle in a town. The readout must not
      // flicker to zero between them.
      expect(
        stoppedSpeedReading(
          lastObservedSpeedMetersPerSecond: 0.5,
          silence: const Duration(seconds: 2),
        ),
        StoppedSpeedReading.unknown,
      );
    });

    test('never having seen a speed reads as unknown, not zero', () {
      // With nothing to reason from, zero would be invented rather than
      // inferred.
      expect(
        stoppedSpeedReading(
          lastObservedSpeedMetersPerSecond: null,
          silence: const Duration(minutes: 1),
        ),
        StoppedSpeedReading.unknown,
      );
    });

    test('a nonsense speed reads as unknown', () {
      for (final speed in [double.nan, double.infinity]) {
        expect(
          stoppedSpeedReading(
            lastObservedSpeedMetersPerSecond: speed,
            silence: const Duration(minutes: 1),
          ),
          StoppedSpeedReading.unknown,
          reason: '$speed',
        );
      }
    });

    test('the threshold is low, because the two errors are not equal', () {
      // Reading zero while moving is a lie; reading blank for another second
      // while rolling to a halt is merely unhelpful. About 7 mph.
      expect(stoppedSpeedThresholdMetersPerSecond, lessThan(4));
      expect(stoppedSpeedThresholdMetersPerSecond, greaterThan(0));
    });

    test('the silence window is longer than a held reading', () {
      // Replacing the number is a stronger claim than dimming it, so it waits
      // longer than the freshness window that merely marks a reading as held.
      expect(stoppedSpeedSilence, greaterThan(const Duration(seconds: 3)));
    });
  });
}
