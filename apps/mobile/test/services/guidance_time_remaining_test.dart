import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/services/guidance_time_remaining.dart';

void main() {
  group('the car gets a real time to the turn, or none (#452)', () {
    test('a moving bike gets the obvious arithmetic', () {
      // 900 m at 30 m/s is thirty seconds.
      expect(
        guidanceSecondsRemaining(distanceMeters: 900, speedMetersPerSecond: 30),
        closeTo(30, 0.01),
      );
    });

    test('no speed means no estimate, not a zero', () {
      // Zero was the bug: `CPTravelEstimates.h` says a zero means the rider is
      // imminently arriving, so the car rendered an arrival time of the current
      // clock on every update.
      expect(
        guidanceSecondsRemaining(
          distanceMeters: 900,
          speedMetersPerSecond: null,
        ),
        isNull,
      );
    });

    test('stopped at lights gets no estimate', () {
      // 400 m at 0.4 m/s is a quarter of an hour, and it would climb while the
      // rider waited. "--" is the honest answer.
      for (final speed in [0.0, 0.4, 2.9]) {
        expect(
          guidanceSecondsRemaining(
            distanceMeters: 400,
            speedMetersPerSecond: speed,
          ),
          isNull,
          reason: '$speed m/s',
        );
      }
    });

    test('the threshold is the one the speed readout already uses', () {
      // #445 picked 3 m/s as the speed below which a motorcycle is not really
      // under way. Two numbers for one idea is how they drift apart.
      expect(guidanceEstimateMinimumSpeedMetersPerSecond, 3.0);
    });

    test('nonsense in gives nothing out', () {
      for (final distance in [-1.0, double.nan, double.infinity]) {
        expect(
          guidanceSecondsRemaining(
            distanceMeters: distance,
            speedMetersPerSecond: 20,
          ),
          isNull,
          reason: 'distance $distance',
        );
      }
      for (final speed in [double.nan, double.infinity]) {
        expect(
          guidanceSecondsRemaining(
            distanceMeters: 900,
            speedMetersPerSecond: speed,
          ),
          isNull,
          reason: 'speed $speed',
        );
      }
    });

    test('the unavailable value is negative, not zero', () {
      // The documented way to render "--". Zero means arriving.
      expect(guidanceTimeRemainingUnavailable, lessThan(0));
    });
  });

  group('the car actually uses it', () {
    test('the bridge publishes an estimate', () {
      final source = File(
        'lib/services/carplay_bridge.dart',
      ).readAsStringSync();

      expect(source, contains('guidanceSecondsRemaining'));
    });

    test('Swift no longer sends a hard zero', () {
      // The whole defect was one literal. Read as source because this line is
      // only reachable from a head unit.
      final source = File(
        'ios/Runner/CarPlaySceneDelegate.swift',
      ).readAsStringSync();

      expect(
        source,
        contains('guidanceSecondsRemaining'),
        reason: 'the car must use the computed estimate',
      );
      expect(
        source,
        isNot(contains('timeRemaining: 0')),
        reason: 'zero tells CarPlay the rider is arriving now',
      );
    });
  });
}
