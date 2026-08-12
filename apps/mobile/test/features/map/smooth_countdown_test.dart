import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/features/map/smooth_countdown.dart';

void main() {
  group('the distance counts down rather than stepping (#449)', () {
    testWidgets('it passes through intermediate values between fixes', (
      tester,
    ) async {
      final seen = <double>[];

      Widget build(double meters) => MaterialApp(
        home: Scaffold(
          body: SmoothCountdown(
            meters: meters,
            builder: (context, value) {
              seen.add(value);
              return Text(value.round().toString());
            },
          ),
        ),
      );

      await tester.pumpWidget(build(400));
      await tester.pumpAndSettle();
      seen.clear();

      // The next fix arrives and the number moves rather than jumping.
      await tester.pumpWidget(build(370));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump(const Duration(milliseconds: 250));

      expect(
        seen.any((value) => value > 370 && value < 400),
        isTrue,
        reason: 'the count must pass through the gap, not step over it',
      );

      await tester.pumpAndSettle();
      expect(seen.last, closeTo(370, 0.01), reason: 'and it arrives');
    });

    testWidgets('it settles exactly on the real distance', (tester) async {
      // It may never leave the rider looking at an interpolated number once the
      // fixes stop — that would be a wrong distance held on screen.
      double? shown;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SmoothCountdown(
              meters: 250,
              builder: (context, value) {
                shown = value;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(shown, 250);
    });

    testWidgets('nothing is left animating after it goes', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SmoothCountdown(
              meters: 400,
              builder: (context, value) => const SizedBox.shrink(),
            ),
          ),
        ),
      );
      await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    });
  });

  group('it never counts up, and never glides through a junction', () {
    test('a nearer target animates', () {
      expect(
        smoothCountdownAnimates(
          shownMeters: 400,
          targetMeters: 370,
          sameManeuver: true,
        ),
        isTrue,
      );
    });

    test('a target further away steps instead', () {
      // A reroute, or the next leg becoming current. Watching a number crawl
      // upward toward a turn reads as the junction moving away.
      expect(
        smoothCountdownAnimates(
          shownMeters: 120,
          targetMeters: 900,
          sameManeuver: true,
        ),
        isFalse,
      );
    });

    test('a new manoeuvre steps, whatever the distance', () {
      // "It must not smooth *through* the junction. The count has to reach zero
      // when the rider reaches the junction, not glide past it."
      expect(
        smoothCountdownAnimates(
          shownMeters: 20,
          targetMeters: 10,
          sameManeuver: false,
        ),
        isFalse,
      );
    });

    test('nonsense steps rather than animating from it', () {
      for (final value in [double.nan, double.infinity]) {
        expect(
          smoothCountdownAnimates(
            shownMeters: value,
            targetMeters: 100,
            sameManeuver: true,
          ),
          isFalse,
          reason: '$value',
        );
      }
    });
  });

  group('only the display is smoothed', () {
    test('the banner still reasons from the real distance', () {
      // #449's own warning: "a smooth countdown built on a position that is 20 m
      // behind is a smoothly wrong number". The interpolated value must reach no
      // decision — it is handed to a formatter and nothing else.
      final source = File(
        'lib/features/map/ride_map_feature.dart',
      ).readAsStringSync();

      expect(source, contains('meters: guidance.distanceMeters'));
      // Keyed on the manoeuvre, or a new junction would glide down from the last
      // one's distance.
      expect(source, contains('key: ValueKey(instruction.maneuver.identity)'));
    });

    test('the spoken schedule is not given an interpolated distance', () {
      // The prompts are staged on distance (#410). If the smoothed number ever
      // reached them, a prompt would fire on an animation frame.
      final shell = File(
        'lib/features/ride/active_ride_shell.dart',
      ).readAsStringSync();

      expect(shell, isNot(contains('SmoothCountdown')));
      expect(
        shell,
        contains('distanceToManeuverMeters: guidance.distanceMeters'),
      );
    });
  });
}
