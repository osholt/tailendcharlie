import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/features/map/ride_clock.dart';

void main() {
  group('the clock ticks on the minute, not the second (#452)', () {
    test('it sleeps until the next minute boundary', () {
      expect(
        millisecondsUntilNextMinute(DateTime(2026, 8, 12, 14, 30, 20)),
        40000,
      );
      expect(
        millisecondsUntilNextMinute(DateTime(2026, 8, 12, 14, 30, 0, 250)),
        59750,
      );
    });

    test('it never schedules a zero-length timer', () {
      // A timer for zero fires immediately and, if the clock has not yet crossed
      // the boundary, reschedules for zero again — a spin that would run flat out
      // for a whole second on a phone that is also drawing a moving map.
      for (final at in [
        DateTime(2026, 8, 12, 14, 30, 59, 999),
        DateTime(2026, 8, 12, 14, 30, 59, 500),
        DateTime(2026, 8, 12, 14, 30, 0),
      ]) {
        expect(
          millisecondsUntilNextMinute(at),
          greaterThanOrEqualTo(1000),
          reason: '$at',
        );
      }
    });

    test('it never sleeps past a minute', () {
      for (var second = 0; second < 60; second += 1) {
        final wait = millisecondsUntilNextMinute(
          DateTime(2026, 8, 12, 14, 30, second),
        );
        expect(wait, lessThanOrEqualTo(Duration.millisecondsPerMinute));
      }
    });
  });

  group('it shows the time and keeps up', () {
    testWidgets('the current time is drawn', (tester) async {
      var now = DateTime(2026, 8, 12, 14, 30, 10);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: RideClock(clock: () => now)),
        ),
      );

      String shown() =>
          tester.widget<Text>(find.byKey(const Key('ride-clock'))).data!;

      // Asserted on the minute rather than the whole string: the widget uses the
      // platform's own formatting, so the default test locale renders this as
      // "2:30 PM" and a 24-hour one as "14:30". Both are correct and the point
      // here is that it follows the clock.
      expect(shown(), contains('30'));

      // Fifty seconds later the minute rolls over and it follows, with nothing
      // else prompting a rebuild.
      now = DateTime(2026, 8, 12, 14, 31, 0);
      await tester.pump(const Duration(seconds: 50));

      expect(shown(), contains('31'));
      expect(shown(), isNot(contains('30')));
    });

    testWidgets('nothing is left ticking after it goes', (tester) async {
      // A pending timer fails the test outright, which is the point: this widget
      // is built and torn down as the ride chrome changes.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RideClock(clock: () => DateTime(2026, 8, 12, 14, 30)),
          ),
        ),
      );
      await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    });

    testWidgets('ink follows the map palette', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RideClock(
              darkMap: false,
              clock: () => DateTime(2026, 8, 12, 14, 30),
            ),
          ),
        ),
      );
      expect(
        tester.widget<Text>(find.byKey(const Key('ride-clock'))).style!.color,
        Colors.black,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RideClock(
              darkMap: true,
              clock: () => DateTime(2026, 8, 12, 14, 30),
            ),
          ),
        ),
      );
      expect(
        tester.widget<Text>(find.byKey(const Key('ride-clock'))).style!.color,
        Colors.white,
      );
    });
  });

  group('both surfaces draw it themselves', () {
    test('the landscape map places the clock', () {
      // Read as source because the ride map needs a platform map to build.
      final source = File(
        'lib/features/map/ride_map_feature.dart',
      ).readAsStringSync();

      expect(source, contains('RideClock(darkMap: _basemap.dark)'));
    });

    test('CarPlay draws its own label rather than using an Apple widget', () {
      // "don't use Apple's built in widgets to do it", stated explicitly in the
      // report. Read as source: this is only reachable from a head unit.
      final source = File(
        'ios/Runner/CarPlaySceneDelegate.swift',
      ).readAsStringSync();

      expect(source, contains('CarPlayClockLabel'));
      // `j`, not a hard-coded HH: it resolves to whichever of 12- or 24-hour the
      // head unit's locale uses.
      expect(source, contains('setLocalizedDateFormatFromTemplate("j:mm")'));
      expect(source, contains('label.textColor = darkMap ? .white : .black'));
      // A hard 24-hour format would show 13:00 on a car set to a 12-hour clock.
      // Checked on the formatter call rather than the string, since the comment
      // above it names "HH:mm" as the thing not being used.
      expect(source, isNot(contains('dateFormat = "HH:mm"')));
    });
  });
}
