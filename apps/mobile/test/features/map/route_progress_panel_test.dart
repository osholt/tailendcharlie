import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/distance_unit.dart';
import 'package:ride_relay/domain/riding_display_size.dart';
import 'package:ride_relay/features/map/route_progress_panel.dart';
import 'package:ride_relay/services/route_journey_progress.dart';

void main() {
  for (final size in RidingDisplaySize.values) {
    testWidgets(
      'ETA honours ${size.label} at narrow width and large system text',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(1.6)),
              child: Scaffold(
                body: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: 228,
                    child: RouteProgressPanel(
                      displaySize: size,
                      distanceUnit: DistanceUnit.miles,
                      onStop: () {},
                      progress: RouteJourneyProgress(
                        remainingDistanceMeters: 233500,
                        remainingTime: const Duration(hours: 3, minutes: 42),
                        arrivalTime: DateTime(2026, 9, 20, 17, 42),
                        nextWaypointName: 'A long name for the next fuel stop',
                        nextWaypointDistanceMeters: 50300,
                        nextWaypointArrivalTime: DateTime(2026, 9, 20, 15, 20),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        final arrival = tester.widget<Text>(
          find.byKey(const Key('eta-arrival')),
        );
        expect(arrival.style!.fontSize, closeTo(11 * size.scale, 0.01));
        if (size != RidingDisplaySize.small) {
          final time = tester.widget<Text>(
            find.byKey(const Key('eta-remaining-time')),
          );
          expect(time.style!.fontSize, closeTo(13 * size.scale, 0.01));
          expect(
            time.overflow,
            isNot(TextOverflow.ellipsis),
            reason: 'enlargement must not hide remaining time',
          );
          expect(arrival.maxLines, isNull);
        }
        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('stop-navigating')), findsOneWidget);
      },
    );
  }
  testWidgets('shows trip, next-stop and current-time information compactly', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: RouteProgressPanel(
              distanceUnit: DistanceUnit.miles,
              showClock: true,
              progress: RouteJourneyProgress(
                remainingDistanceMeters: 16093.44,
                remainingTime: const Duration(minutes: 42),
                arrivalTime: DateTime(2026, 8, 14, 15, 42),
                nextWaypointName: 'Chippenham fuel stop',
                nextWaypointDistanceMeters: 8046.72,
                nextWaypointArrivalTime: DateTime(2026, 8, 14, 15, 20),
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.textContaining('42 min · 10.0 mi left'), findsOneWidget);
    expect(find.textContaining('Route ETA'), findsOneWidget);
    expect(find.text('Chippenham fuel stop'), findsOneWidget);
    expect(find.textContaining('5.0 mi'), findsOneWidget);
    expect(find.byKey(const Key('ride-clock')), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const Key('route-progress-panel'))).width,
      lessThanOrEqualTo(230),
    );
  });

  testWidgets('uses honest dashes before speed is known', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RouteProgressPanel(
            distanceUnit: DistanceUnit.kilometres,
            progress: const RouteJourneyProgress(
              remainingDistanceMeters: 4200,
              remainingTime: null,
              arrivalTime: null,
              nextWaypointName: 'Coffee',
              nextWaypointDistanceMeters: 2100,
              nextWaypointArrivalTime: null,
            ),
          ),
        ),
      ),
    );

    expect(find.textContaining('Time — · 4.2 km left'), findsOneWidget);
    expect(find.text('Route ETA —'), findsOneWidget);
    expect(find.textContaining('2.1 km · —'), findsOneWidget);
  });

  testWidgets('next-stop ETA fits the narrow landscape rail', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 228,
              child: RouteProgressPanel(
                distanceUnit: DistanceUnit.miles,
                progress: RouteJourneyProgress(
                  remainingDistanceMeters: 27841,
                  remainingTime: const Duration(minutes: 32),
                  arrivalTime: DateTime(2026, 8, 15, 13, 13),
                  nextWaypointName: 'A very long waypoint name',
                  nextWaypointDistanceMeters: 27841,
                  nextWaypointArrivalTime: DateTime(2026, 8, 15, 13, 13),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.textContaining('17.3 mi'), findsWidgets);
  });

  group('as a strip in the portrait band (#848)', () {
    Future<void> pumpStrip(
      WidgetTester tester,
      RouteJourneyProgress progress, {
      RidingDisplaySize size = RidingDisplaySize.small,
      double width = 366,
      double textScale = 1,
      VoidCallback? onStop,
    }) => tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
          child: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                child: RouteProgressPanel(
                  strip: true,
                  displaySize: size,
                  distanceUnit: DistanceUnit.miles,
                  onStop: onStop,
                  progress: progress,
                ),
              ),
            ),
          ),
        ),
      ),
    );

    // Nothing but the destination ahead: the next stop is the end of the route.
    RouteJourneyProgress toDestination({double travelled = 0}) =>
        RouteJourneyProgress(
          remainingDistanceMeters: 16093.44,
          travelledDistanceMeters: travelled,
          remainingTime: const Duration(minutes: 42),
          arrivalTime: DateTime(2026, 10, 4, 15, 42),
          nextWaypointName: 'Destination',
          nextWaypointDistanceMeters: 16093.44,
          nextWaypointArrivalTime: DateTime(2026, 10, 4, 15, 42),
        );

    testWidgets('puts time, distance and arrival on one row when they fit', (
      tester,
    ) async {
      // Wide enough that even the test font, which draws every glyph a full em
      // wide, fits all three: the claim is about the row, not about a phone.
      await pumpStrip(tester, toDestination(), width: 700);

      final time = tester.getRect(find.byKey(const Key('eta-remaining-time')));
      final arrival = tester.getRect(find.byKey(const Key('eta-arrival')));
      expect(find.textContaining('42 min · 10.0 mi left'), findsOneWidget);
      expect(find.textContaining('ETA'), findsOneWidget);
      expect(
        arrival.center.dy,
        closeTo(time.center.dy, 2),
        reason: 'the arrival shares the row with the figures it belongs to',
      );
      expect(arrival.left, greaterThan(time.right));
      expect(
        tester.getSize(find.byKey(const Key('route-progress-panel'))).width,
        700,
        reason: 'a strip spans the band it sits in',
      );
    });

    testWidgets('wraps the arrival under the figures rather than hide it', (
      tester,
    ) async {
      await pumpStrip(tester, toDestination(), width: 300, onStop: () {});

      final time = tester.getRect(find.byKey(const Key('eta-remaining-time')));
      final arrival = tester.getRect(find.byKey(const Key('eta-arrival')));
      expect(tester.takeException(), isNull);
      expect(arrival.top, greaterThanOrEqualTo(time.bottom - 1));
      expect(arrival.right, lessThanOrEqualTo(300));
    });

    testWidgets('costs a fraction of the card, and says so in its footprint', (
      tester,
    ) async {
      final progress = toDestination(travelled: 12000);
      await pumpStrip(tester, progress);
      final strip = tester.getSize(
        find.byKey(const Key('route-progress-panel')),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 366,
                child: RouteProgressPanel(
                  distanceUnit: DistanceUnit.miles,
                  progress: progress,
                ),
              ),
            ),
          ),
        ),
      );
      final card = tester.getSize(
        find.byKey(const Key('route-progress-panel')),
      );

      expect(
        strip.height,
        lessThan(card.height * 0.6),
        reason: 'the band pays for every pixel the strip takes (#848)',
      );
    });

    testWidgets('drops the ridden distance and a next stop that is the end', (
      tester,
    ) async {
      await pumpStrip(tester, toDestination(travelled: 12000));

      expect(find.byKey(const Key('eta-travelled-distance')), findsNothing);
      expect(find.text('Destination'), findsNothing);
    });

    testWidgets('keeps a named stop before the destination', (tester) async {
      await pumpStrip(
        tester,
        RouteJourneyProgress(
          remainingDistanceMeters: 16093.44,
          remainingTime: const Duration(minutes: 42),
          arrivalTime: DateTime(2026, 10, 4, 15, 42),
          nextWaypointName: 'Chippenham fuel stop',
          nextWaypointDistanceMeters: 8046.72,
          nextWaypointArrivalTime: DateTime(2026, 10, 4, 15, 20),
        ),
      );

      expect(find.text('Chippenham fuel stop'), findsOneWidget);
      expect(find.textContaining('5.0 mi'), findsOneWidget);
    });

    testWidgets('a stop within GPS error of the end is the end', (
      tester,
    ) async {
      await pumpStrip(
        tester,
        RouteJourneyProgress(
          remainingDistanceMeters: 16093.44,
          remainingTime: const Duration(minutes: 42),
          arrivalTime: DateTime(2026, 10, 4, 15, 42),
          nextWaypointName: 'The cafe',
          nextWaypointDistanceMeters: 16093.44 - 10,
          nextWaypointArrivalTime: DateTime(2026, 10, 4, 15, 42),
        ),
      );
      expect(find.text('The cafe'), findsNothing);

      await pumpStrip(
        tester,
        RouteJourneyProgress(
          remainingDistanceMeters: 16093.44,
          remainingTime: const Duration(minutes: 42),
          arrivalTime: DateTime(2026, 10, 4, 15, 42),
          nextWaypointName: 'The cafe',
          nextWaypointDistanceMeters: 16093.44 - 400,
          nextWaypointArrivalTime: DateTime(2026, 10, 4, 15, 41),
        ),
      );
      expect(find.text('The cafe'), findsOneWidget);
    });

    testWidgets('says what it cannot know instead of inventing a time', (
      tester,
    ) async {
      await pumpStrip(
        tester,
        const RouteJourneyProgress(
          remainingDistanceMeters: 4200,
          awaitingRejoin: true,
          remainingTime: null,
          arrivalTime: null,
          nextWaypointName: null,
          nextWaypointDistanceMeters: null,
          nextWaypointArrivalTime: null,
        ),
      );

      expect(find.textContaining('On route'), findsOneWidget);
      expect(find.text('ETA after rejoining'), findsOneWidget);
    });

    testWidgets('keeps the way out of free-roam navigation, in words', (
      tester,
    ) async {
      var stopped = 0;
      await pumpStrip(tester, toDestination(), onStop: () => stopped += 1);

      await tester.tap(find.byKey(const Key('stop-navigating')));
      expect(stopped, 1);
      expect(find.text('Stop navigating'), findsOneWidget);
    });

    for (final size in RidingDisplaySize.values) {
      testWidgets(
        '${size.label} hides no figure at narrow width and large system text',
        (tester) async {
          await pumpStrip(
            tester,
            toDestination(),
            size: size,
            width: 300,
            textScale: 1.6,
            onStop: () {},
          );

          expect(tester.takeException(), isNull);
          final arrival = tester.widget<Text>(
            find.byKey(const Key('eta-arrival')),
          );
          expect(arrival.style!.fontSize, closeTo(12 * size.scale, 0.01));
          if (size != RidingDisplaySize.small) {
            final time = tester.widget<Text>(
              find.byKey(const Key('eta-remaining-time')),
            );
            final distance = tester.widget<Text>(
              find.byKey(const Key('eta-remaining-distance')),
            );
            expect(time.style!.fontSize, closeTo(13 * size.scale, 0.01));
            expect(distance.style!.fontSize, closeTo(13 * size.scale, 0.01));
            expect(
              [time.overflow, distance.overflow],
              everyElement(isNot(TextOverflow.ellipsis)),
              reason: 'enlargement must wrap a figure, never hide it',
            );
          }
        },
      );
    }

    testWidgets('keeps the semantics label the card gives', (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpStrip(tester, toDestination(travelled: 12000));

      expect(
        tester
            .getSemantics(find.byKey(const Key('route-progress-panel')))
            .label,
        allOf(contains('42 min'), contains('10.0 mi'), contains('ridden')),
      );
      semantics.dispose();
    });
  });
}
