import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ride_relay/controllers/global_ride_heatmap_controller.dart';
import 'package:ride_relay/controllers/rider_profile_controller.dart';
import 'package:ride_relay/features/onboarding/onboarding_screen.dart';
import 'package:ride_relay/services/global_ride_heatmap.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('first run collects the required profile before skip', (
    tester,
  ) async {
    final profile = await RiderProfileController.load();
    await tester.pumpWidget(_app(profile));

    expect(find.text('Keep the whole ride together'), findsOneWidget);
    await tester.tap(find.byKey(const Key('onboarding-continue')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('skip-onboarding-tour')));
    await tester.pump();

    expect(
      find.text('Enter the name your group will recognise.'),
      findsOneWidget,
    );
    expect(profile.needsOnboarding, isTrue);

    await tester.enterText(
      find.byKey(const Key('onboarding-name-field')),
      'Oliver',
    );
    final initialsChoice = find.byKey(const Key('onboarding-symbol-initials'));
    await tester.ensureVisible(initialsChoice);
    await tester.tap(initialsChoice);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('rider-custom-initials')),
      'TEC',
    );
    await tester.pump();
    final purpleInk = find.byKey(
      const Key('onboarding-symbol-initials-ink-purple'),
    );
    await tester.ensureVisible(purpleInk);
    await tester.tap(purpleInk);
    final purpleColour = find.byKey(const Key('onboarding-colour-purple'));
    await tester.ensureVisible(purpleColour);
    await tester.tap(purpleColour);
    await tester.tap(find.byKey(const Key('skip-onboarding-tour')));
    await tester.pumpAndSettle();
    expect(find.text('Help build better riding maps'), findsOneWidget);
    await tester.tap(find.byKey(const Key('onboarding-continue')));
    await tester.pumpAndSettle();
    expect(find.text('You are ready to ride'), findsOneWidget);

    await tester.tap(find.byKey(const Key('onboarding-join-ride')));
    await tester.pumpAndSettle();

    expect(profile.onboardingCompleted, isTrue);
    expect(profile.onboardingEducationSkipped, isTrue);
    expect(profile.displayName, 'Oliver');
    expect(profile.riderSymbol.storageValue, 'initials:v1:VEVD:purple');
    expect(profile.riderColor.name, 'purple');
    expect(profile.takePendingRideChoice(), OnboardingRideChoice.join);
  });

  testWidgets('permission deferral explains degradation and recovery', (
    tester,
  ) async {
    final profile = await RiderProfileController.load();
    await tester.pumpWidget(_app(profile));

    await tester.tap(find.byKey(const Key('onboarding-continue')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('onboarding-name-field')),
      'Oliver',
    );
    await tester.tap(find.byKey(const Key('onboarding-continue')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('onboarding-continue')));
    await tester.pumpAndSettle();

    expect(find.text('Connections and permissions'), findsOneWidget);
    await tester.ensureVisible(
      find.byKey(const Key('defer-onboarding-permissions')),
    );
    await tester.tap(find.byKey(const Key('defer-onboarding-permissions')));
    await tester.pump();

    expect(find.byKey(const Key('permission-degraded-path')), findsOneWidget);
    expect(find.textContaining('restore blocked access'), findsOneWidget);
  });

  testWidgets('first-run content remains usable at large text sizes', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final profile = await RiderProfileController.load();

    await tester.pumpWidget(
      _app(profile, textScaler: const TextScaler.linear(2)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Keep the whole ride together'), findsOneWidget);
    expect(find.byKey(const Key('onboarding-continue')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('setup can end on the map rather than in a ride (#598)', (
    tester,
  ) async {
    // #405 and #426 made the map the surface a rider lands on before any
    // decision — "I don't want the start screen at all". Setup was still
    // holding the old gate at the end, insisting on Create or Join before it
    // would let anybody through.
    final profile = await RiderProfileController.load();
    await tester.pumpWidget(_app(profile));

    await tester.tap(find.byKey(const Key('onboarding-continue')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('skip-onboarding-tour')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('onboarding-name-field')),
      'Oliver',
    );
    await tester.tap(find.byKey(const Key('skip-onboarding-tour')));
    await tester.pumpAndSettle();
    expect(find.text('Help build better riding maps'), findsOneWidget);
    await tester.tap(find.byKey(const Key('onboarding-continue')));
    await tester.pumpAndSettle();
    expect(find.text('You are ready to ride'), findsOneWidget);

    final toMap = find.byKey(const Key('onboarding-free-roam'));
    expect(toMap, findsOneWidget);
    await tester.ensureVisible(toMap);
    await tester.pumpAndSettle();
    await tester.tap(toMap);
    await tester.pumpAndSettle();

    expect(profile.needsOnboarding, isFalse);
    expect(
      profile.takePendingRideChoice(),
      isNull,
      reason: 'no ride was chosen, so nothing should be staged',
    );
  });

  group('global heatmap choice in setup (#957)', () {
    Future<GlobalRideHeatmapController> loadHeatmap() async {
      final heatmap = await GlobalRideHeatmapController.load(
        client: GlobalHeatmapClient(
          baseUri: Uri.parse('https://relay.example/api/'),
          client: MockClient((_) async => http.Response('{}', 200)),
        ),
        credentials: _MemoryCredentials(),
      );
      addTearDown(heatmap.dispose);
      return heatmap;
    }

    /// Opens setup on the heatmap step, as a first-run rider reaches it.
    Future<RiderProfileController> openHeatmapStep(
      WidgetTester tester,
      GlobalRideHeatmapController heatmap,
    ) async {
      final profile = await RiderProfileController.load();
      await tester.pumpWidget(_app(profile, globalRideHeatmap: heatmap));
      await tester.tap(find.byKey(const Key('onboarding-continue')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('onboarding-name-field')),
        'Oliver',
      );
      await tester.tap(find.byKey(const Key('skip-onboarding-tour')));
      await tester.pumpAndSettle();
      expect(find.text('Help build better riding maps'), findsOneWidget);
      return profile;
    }

    HeatmapContributionConsent? selected(WidgetTester tester) => tester
        .widget<RadioGroup<HeatmapContributionConsent>>(
          find.byType(RadioGroup<HeatmapContributionConsent>),
        )
        .groupValue;

    Future<void> finish(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('onboarding-continue')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('onboarding-free-roam')));
      await tester.pumpAndSettle();
    }

    testWidgets('offers all three choices with none selected, and says what '
        'is shared', (tester) async {
      final heatmap = await loadHeatmap();
      await openHeatmapStep(tester, heatmap);

      for (final choice in HeatmapContributionConsent.values) {
        expect(
          find.byKey(Key('onboarding-heatmap-${choice.name}')),
          findsOneWidget,
          reason: choice.name,
        );
      }
      expect(selected(tester), isNull);
      expect(heatmap.consentAnswered, isFalse);
      expect(
        find.byKey(const Key('onboarding-heatmap-nothing-selected')),
        findsOneWidget,
      );
      final summary = find.byKey(const Key('heatmap-sharing-summary'));
      await tester.ensureVisible(summary);
      expect(
        find.descendant(
          of: summary,
          matching: find.textContaining('unordered, coarse map cells'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: summary,
          matching: find.textContaining('Never your track'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: summary,
          matching: find.textContaining('at least three separate contributors'),
        ),
        findsOneWidget,
      );
    });

    for (final choice in HeatmapContributionConsent.values) {
      testWidgets('choosing ${choice.name} is stored when setup finishes', (
        tester,
      ) async {
        final heatmap = await loadHeatmap();
        await openHeatmapStep(tester, heatmap);

        final option = find.byKey(Key('onboarding-heatmap-${choice.name}'));
        await tester.ensureVisible(option);
        await tester.tap(option);
        await tester.pump();
        expect(selected(tester), choice);
        // Nothing is stored until setup is finished.
        expect(heatmap.consentAnswered, isFalse);
        await finish(tester);

        expect(heatmap.consent, choice);
        expect(heatmap.consentAnswered, isTrue);
        final stored = await SharedPreferences.getInstance();
        expect(
          stored.getString(GlobalRideHeatmapController.consentKey),
          choice.name,
        );
      });
    }

    testWidgets('skipping the step means never, and is recorded', (
      tester,
    ) async {
      final heatmap = await loadHeatmap();
      await openHeatmapStep(tester, heatmap);

      await tester.tap(find.byKey(const Key('skip-heatmap-choice')));
      await tester.pumpAndSettle();
      expect(find.text('You are ready to ride'), findsOneWidget);
      await tester.tap(find.byKey(const Key('onboarding-free-roam')));
      await tester.pumpAndSettle();

      expect(heatmap.consent, HeatmapContributionConsent.never);
      expect(heatmap.consentAnswered, isTrue);
      final stored = await SharedPreferences.getInstance();
      expect(stored.getString(GlobalRideHeatmapController.consentKey), 'never');
    });

    testWidgets('continuing without choosing also means never', (tester) async {
      final heatmap = await loadHeatmap();
      await openHeatmapStep(tester, heatmap);

      await finish(tester);

      expect(heatmap.consent, HeatmapContributionConsent.never);
      expect(heatmap.consentAnswered, isTrue);
    });

    testWidgets('a rider replaying setup keeps what they chose before', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        GlobalRideHeatmapController.consentKey:
            HeatmapContributionConsent.askAfterEachRide.name,
      });
      final heatmap = await loadHeatmap();
      await openHeatmapStep(tester, heatmap);

      // Their own earlier answer is shown, so it is not a pre-selected default.
      expect(selected(tester), HeatmapContributionConsent.askAfterEachRide);

      // Skipping the question does not overturn it.
      await tester.tap(find.byKey(const Key('skip-heatmap-choice')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('onboarding-free-roam')));
      await tester.pumpAndSettle();

      expect(heatmap.consent, HeatmapContributionConsent.askAfterEachRide);
    });
  });
}

Widget _app(
  RiderProfileController profile, {
  TextScaler textScaler = TextScaler.noScaling,
  GlobalRideHeatmapController? globalRideHeatmap,
}) => MaterialApp(
  theme: ThemeData.dark(useMaterial3: true),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: textScaler),
    child: child!,
  ),
  home: OnboardingScreen(
    riderProfile: profile,
    globalRideHeatmap: globalRideHeatmap,
  ),
);

class _MemoryCredentials implements HeatmapCredentialStore {
  HeatmapCredential? value;

  @override
  Future<void> delete() async => value = null;

  @override
  Future<HeatmapCredential?> read() async => value;

  @override
  Future<void> write(HeatmapCredential credential) async => value = credential;
}
