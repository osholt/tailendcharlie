import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/location_sharing_guard.dart';
import 'package:ride_relay/features/ride/location_sharing_widgets.dart';
import 'package:ride_relay/services/sharing_reminder_notifier.dart';

final _copy = SharingCopy.forRide(
  rideName: 'Sunday run',
  answerWithin: const Duration(minutes: 15),
);

Widget _host(Widget child, {double width = 390, double textScale = 1}) =>
    MaterialApp(
      theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
      home: MediaQuery(
        data: MediaQueryData(
          size: Size(width, 800),
          textScaler: TextScaler.linear(textScale),
        ),
        child: Scaffold(
          body: const SizedBox.expand(),
          bottomNavigationBar: SizedBox(width: width, child: child),
        ),
      ),
    );

/// A stand-in for the map: counts how often it is created, and reports the
/// bottom padding it is given each time it is built.
class _Probe extends StatefulWidget {
  const _Probe({required this.onPadding});

  final void Function(double bottom) onPadding;

  static int created = 0;

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  void initState() {
    super.initState();
    _Probe.created += 1;
  }

  @override
  Widget build(BuildContext context) {
    widget.onPadding(MediaQuery.paddingOf(context).bottom);
    return const SizedBox.expand(key: Key('probe'));
  }
}

void main() {
  group('LocationSharingFooter', () {
    const inset = 34.0;
    const barHeight = 60.0;
    final bar = SafeArea(
      top: false,
      bottom: false,
      child: const SizedBox(key: Key('footer-bar'), height: barHeight),
    );

    setUp(() => _Probe.created = 0);

    void phone(WidgetTester tester) {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 800);
      tester.view.padding = const FakeViewPadding(bottom: inset);
      tester.view.viewPadding = const FakeViewPadding(bottom: inset);
      addTearDown(tester.view.reset);
    }

    Widget screen({
      required void Function(double) onPadding,
      required bool ownsBottomInset,
      required bool navigationBar,
      Widget? footerBar,
    }) => MaterialApp(
      home: Scaffold(
        body: LocationSharingFooter(
          ownsBottomInset: ownsBottomInset,
          bar: footerBar,
          child: _Probe(onPadding: onPadding),
        ),
        bottomNavigationBar: navigationBar
            ? NavigationBar(
                destinations: const [
                  NavigationDestination(icon: Icon(Icons.map), label: 'Map'),
                  NavigationDestination(icon: Icon(Icons.menu), label: 'More'),
                ],
              )
            : null,
      ),
    );

    testWidgets('never re-creates its child as the bar comes and goes', (
      tester,
    ) async {
      phone(tester);
      void ignore(double _) {}

      await tester.pumpWidget(
        screen(onPadding: ignore, ownsBottomInset: true, navigationBar: false),
      );
      await tester.pumpWidget(
        screen(
          onPadding: ignore,
          ownsBottomInset: true,
          navigationBar: false,
          footerBar: bar,
        ),
      );
      await tester.pumpWidget(
        screen(onPadding: ignore, ownsBottomInset: true, navigationBar: false),
      );

      // The map under it would reload and flash if this were more than one.
      expect(_Probe.created, 1);
    });

    testWidgets('puts the bar below the child and gives the child the rest', (
      tester,
    ) async {
      phone(tester);

      await tester.pumpWidget(
        screen(
          onPadding: (_) {},
          ownsBottomInset: false,
          navigationBar: false,
          footerBar: bar,
        ),
      );

      expect(
        tester.getSize(find.byKey(const Key('probe'))).height,
        800 - barHeight,
      );
      expect(
        tester.getTopLeft(find.byKey(const Key('footer-bar'))).dy,
        800 - barHeight,
      );
    });

    testWidgets(
      'with nothing below it, the bar owns the inset and the child does not repeat it',
      (tester) async {
        phone(tester);
        var bottom = -1.0;

        await tester.pumpWidget(
          screen(
            onPadding: (value) => bottom = value,
            ownsBottomInset: true,
            navigationBar: false,
          ),
        );
        expect(bottom, inset, reason: 'no bar: the child keeps the inset');

        await tester.pumpWidget(
          screen(
            onPadding: (value) => bottom = value,
            ownsBottomInset: true,
            navigationBar: false,
            footerBar: bar,
          ),
        );
        expect(bottom, 0, reason: 'with the bar: the bar has it');
      },
    );

    testWidgets(
      'above a navigation bar, leaves the child the padding the Scaffold gave it',
      (tester) async {
        phone(tester);
        var bottom = -1.0;

        await tester.pumpWidget(
          screen(
            onPadding: (value) => bottom = value,
            ownsBottomInset: false,
            navigationBar: true,
          ),
        );
        final withoutBar = bottom;

        await tester.pumpWidget(
          screen(
            onPadding: (value) => bottom = value,
            ownsBottomInset: false,
            navigationBar: true,
            footerBar: bar,
          ),
        );

        // The navigation bar takes the inset, so the Scaffold takes it off its
        // body. Reading the padding from outside the body would put it back.
        expect(withoutBar, 0);
        expect(bottom, 0);
      },
    );
  });

  group('LocationSharingBar', () {
    testWidgets('shows nothing while sharing and nothing is being asked', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          LocationSharingBar(phase: SharingGuardPhase.sharing, copy: _copy),
        ),
      );

      expect(find.byKey(const Key('location-sharing-prompt')), findsNothing);
      expect(find.byKey(const Key('location-sharing-paused')), findsNothing);
    });

    testWidgets('asks the question with the group named and why', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          LocationSharingBar(
            phase: SharingGuardPhase.prompting,
            copy: _copy,
            awayFor: const Duration(minutes: 31),
          ),
        ),
      );

      expect(find.text('Still riding with Sunday run?'), findsOneWidget);
      expect(
        find.textContaining('Away from the group for at least 31 minutes'),
        findsOneWidget,
      );
      expect(find.text('Stop sharing'), findsOneWidget);
      expect(find.text('Keep sharing'), findsOneWidget);
    });

    testWidgets('both answers reach the callbacks', (tester) async {
      var kept = 0;
      var stopped = 0;
      await tester.pumpWidget(
        _host(
          LocationSharingBar(
            phase: SharingGuardPhase.prompting,
            copy: _copy,
            onKeepSharing: () => kept += 1,
            onStopSharing: () => stopped += 1,
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('location-sharing-keep')));
      await tester.tap(find.byKey(const Key('location-sharing-stop')));

      expect(kept, 1);
      expect(stopped, 1);
    });

    testWidgets(
      'tells a rider on the road that nothing stops while they ride',
      (tester) async {
        await tester.pumpWidget(
          _host(
            LocationSharingBar(
              phase: SharingGuardPhase.prompting,
              copy: _copy,
              riding: true,
            ),
          ),
        );

        expect(
          find.textContaining('will not stop while you are riding'),
          findsOneWidget,
        );
      },
    );

    testWidgets('fits a small phone at a large text size without overflow', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          LocationSharingBar(
            phase: SharingGuardPhase.prompting,
            copy: _copy,
            awayFor: const Duration(hours: 2, minutes: 35),
            riding: true,
          ),
          width: 320,
          textScale: 1.5,
        ),
      );

      expect(tester.takeException(), isNull);
      // A strip, not a screen: under a third of a short phone's height.
      expect(
        tester.getSize(find.byKey(const Key('location-sharing-prompt'))).height,
        lessThan(800 / 3),
      );
    });

    testWidgets('says sharing stopped on its own, and how to resume', (
      tester,
    ) async {
      var resumed = 0;
      await tester.pumpWidget(
        _host(
          LocationSharingBar(
            phase: SharingGuardPhase.paused,
            copy: _copy,
            pauseReason: SharingPauseReason.unanswered,
            onResume: () => resumed += 1,
          ),
        ),
      );

      expect(find.text('Location sharing is paused'), findsOneWidget);
      expect(find.textContaining('did not answer'), findsOneWidget);

      await tester.tap(find.byKey(const Key('location-sharing-resume')));
      expect(resumed, 1);
    });

    testWidgets('does not blame the rider for a stop they chose', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          LocationSharingBar(
            phase: SharingGuardPhase.paused,
            copy: _copy,
            pauseReason: SharingPauseReason.rider,
          ),
        ),
      );

      expect(find.text('Location sharing is off'), findsOneWidget);
      expect(find.textContaining('did not answer'), findsNothing);
    });

    testWidgets('cannot be resumed twice while it is starting', (tester) async {
      var resumed = 0;
      await tester.pumpWidget(
        _host(
          LocationSharingBar(
            phase: SharingGuardPhase.paused,
            copy: _copy,
            pauseReason: SharingPauseReason.rider,
            resuming: true,
            onResume: () => resumed += 1,
          ),
        ),
      );

      await tester.tap(
        find.byKey(const Key('location-sharing-resume')),
        warnIfMissed: false,
      );

      expect(resumed, 0);
    });
  });

  group('LocationSharingBadge', () {
    testWidgets(
      'is a dot in the colour of the state, with words for a screen reader',
      (tester) async {
        for (final phase in SharingGuardPhase.values) {
          await tester.pumpWidget(
            MaterialApp(
              home: LocationSharingBadge(
                phase: phase,
                child: const Icon(Icons.menu),
              ),
            ),
          );

          final badge = tester.widget<Badge>(
            find.byKey(const Key('location-sharing-badge')),
          );
          expect(badge.backgroundColor, sharingStatusColor(phase));
          expect(
            find.bySemanticsLabel(sharingStatusLabel(phase)),
            findsWidgets,
          );
        }
      },
    );

    testWidgets('the three states are three different colours', (tester) async {
      final colours = {
        for (final phase in SharingGuardPhase.values) sharingStatusColor(phase),
      };

      expect(colours, hasLength(3));
    });
  });

  group('LocationSharingCard', () {
    testWidgets('says the group can see the rider, and offers to stop', (
      tester,
    ) async {
      var stopped = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LocationSharingCard(
              phase: SharingGuardPhase.sharing,
              copy: _copy,
              pauseReason: null,
              onStopSharing: () => stopped += 1,
            ),
          ),
        ),
      );

      expect(
        find.text('You are sharing your location with the group'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('location-sharing-card-stop')));
      expect(stopped, 1);
      expect(
        find.byKey(const Key('location-sharing-card-resume')),
        findsNothing,
      );
    });

    testWidgets('says the rider is not shared, and offers to resume', (
      tester,
    ) async {
      var resumed = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LocationSharingCard(
              phase: SharingGuardPhase.paused,
              copy: _copy,
              pauseReason: SharingPauseReason.unanswered,
              onResume: () => resumed += 1,
            ),
          ),
        ),
      );

      expect(find.text('You are not sharing your location'), findsOneWidget);
      expect(find.textContaining('did not answer'), findsOneWidget);
      await tester.tap(find.byKey(const Key('location-sharing-card-resume')));
      expect(resumed, 1);
      expect(find.byKey(const Key('location-sharing-card-stop')), findsNothing);
    });

    testWidgets('the buttons wait while a change is under way', (tester) async {
      var presses = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LocationSharingCard(
              phase: SharingGuardPhase.paused,
              copy: _copy,
              pauseReason: SharingPauseReason.rider,
              busy: true,
              onResume: () => presses += 1,
            ),
          ),
        ),
      );

      await tester.tap(
        find.byKey(const Key('location-sharing-card-resume')),
        warnIfMissed: false,
      );

      expect(presses, 0);
    });
  });
}
