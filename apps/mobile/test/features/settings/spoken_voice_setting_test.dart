import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/distance_unit_controller.dart';
import 'package:ride_relay/controllers/map_style_mode_controller.dart';
import 'package:ride_relay/controllers/rider_profile_controller.dart';
import 'package:ride_relay/controllers/speed_limit_display_controller.dart';
import 'package:ride_relay/controllers/spoken_guidance_controller.dart';
import 'package:ride_relay/features/settings/unit_settings_sheet.dart';
import 'package:ride_relay/services/natural_voice_pack.dart';
import 'package:ride_relay/services/spoken_guidance.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('selecting an installed voice immediately previews it', (
    tester,
  ) async {
    const voice = SpokenGuidanceVoice(
      name: 'Samantha',
      locale: 'en-GB',
      identifier: 'com.apple.voice.samantha',
    );
    final engine = _RecordingEngine();
    final spoken = SpokenGuidanceController.inMemory(
      engine: () => engine,
      voiceLoader: () async => const [voice],
    );
    final mapStyle = await MapStyleModeController.load();
    final riderProfile = await RiderProfileController.load();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UnitSettingsSheet(
            controller: DistanceUnitController.forLocale(
              const Locale('en', 'GB'),
            ),
            mapStyleMode: mapStyle,
            riderProfile: riderProfile,
            speedLimitDisplay: SpeedLimitDisplayController.inMemory(),
            spokenGuidance: spoken,
            embedded: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final selector = find.byType(DropdownButtonFormField<String>);
    await tester.ensureVisible(selector);
    await tester.tap(selector);
    await tester.pumpAndSettle();
    await tester.tap(find.text(voice.label).last);
    await tester.pumpAndSettle();

    expect(spoken.voice, voice);
    expect(engine.configured, isTrue);
    expect(engine.spoken, ['In 2 miles, at the roundabout, turn right.']);
  });

  testWidgets('Daniel is selected and novelty voices stay behind Show all', (
    tester,
  ) async {
    const daniel = SpokenGuidanceVoice(
      name: 'Daniel',
      locale: 'en-GB',
      identifier: 'com.apple.voice.compact.en-GB.Daniel',
    );
    const novelty = SpokenGuidanceVoice(name: 'Bells', locale: 'en-US');
    final spoken = SpokenGuidanceController.inMemory(
      voice: SpokenGuidanceController.preferredDefaultVoice,
      voiceLoader: () async => const [daniel, novelty],
    );
    final mapStyle = await MapStyleModeController.load();
    final riderProfile = await RiderProfileController.load();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UnitSettingsSheet(
            controller: DistanceUnitController.forLocale(
              const Locale('en', 'GB'),
            ),
            mapStyleMode: mapStyle,
            riderProfile: riderProfile,
            speedLimitDisplay: SpeedLimitDisplayController.inMemory(),
            spokenGuidance: spoken,
            embedded: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(daniel.label), findsOneWidget);
    expect(find.text(novelty.label), findsNothing);
    final showAll = find.byKey(const Key('show-all-spoken-voices'));
    await tester.ensureVisible(showAll);
    await tester.tap(showAll);
    await tester.pumpAndSettle();

    final selector = find.byType(DropdownButtonFormField<String>);
    await tester.ensureVisible(selector);
    await tester.tap(selector);
    await tester.pumpAndSettle();
    expect(find.text(novelty.label), findsOneWidget);
  });

  testWidgets(
    'iPhone explains downloads and refreshes newly installed voices',
    (tester) async {
      const daniel = SpokenGuidanceVoice(
        name: 'Daniel',
        locale: 'en-GB',
        identifier: 'com.apple.voice.compact.en-GB.Daniel',
      );
      const premium = SpokenGuidanceVoice(
        name: 'Serena',
        locale: 'en-GB',
        identifier: 'com.apple.voice.premium.en-GB.Serena',
        quality: 'premium',
      );
      var installedVoices = const <SpokenGuidanceVoice>[daniel];
      final spoken = SpokenGuidanceController.inMemory(
        voiceLoader: () async => installedVoices,
      );
      final mapStyle = await MapStyleModeController.load();
      final riderProfile = await RiderProfileController.load();

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.iOS),
          home: Scaffold(
            body: UnitSettingsSheet(
              controller: DistanceUnitController.forLocale(
                const Locale('en', 'GB'),
              ),
              mapStyleMode: mapStyle,
              riderProfile: riderProfile,
              speedLimitDisplay: SpeedLimitDisplayController.inMemory(),
              spokenGuidance: spoken,
              embedded: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.textContaining('No Enhanced or Premium voices are installed'),
        findsOneWidget,
      );
      final help = find.byKey(const Key('add-natural-ios-voice-help'));
      await tester.ensureVisible(help);
      await tester.tap(help);
      await tester.pumpAndSettle();
      expect(find.text('Add a more natural iPhone voice'), findsOneWidget);
      expect(
        find.textContaining('Accessibility → Read & Speak → Voices'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Siri Voice choice can remain reserved'),
        findsOneWidget,
      );
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();

      installedVoices = const [daniel, premium];
      final refresh = find.byKey(const Key('refresh-spoken-voices'));
      await tester.ensureVisible(refresh);
      await tester.tap(refresh);
      await tester.pumpAndSettle();

      expect(
        find.text('1 Enhanced or Premium voice installed.'),
        findsOneWidget,
      );
      final selector = find.byType(DropdownButtonFormField<String>);
      await tester.ensureVisible(selector);
      await tester.tap(selector);
      await tester.pumpAndSettle();
      expect(find.text(premium.label), findsOneWidget);
    },
  );

  testWidgets('natural voice pack installs and previews on either platform', (
    tester,
  ) async {
    final store = _FakeNaturalVoicePackStore();
    final naturalPack = NaturalVoicePackController.inMemory(store: store);
    final preview = _RecordingEngine();
    final spoken = SpokenGuidanceController.inMemory(
      naturalVoicePack: naturalPack,
      naturalPreviewEngine: () => preview,
      voiceLoader: () async => const [],
    );
    final mapStyle = await MapStyleModeController.load();
    final riderProfile = await RiderProfileController.load();

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: Scaffold(
          body: UnitSettingsSheet(
            controller: DistanceUnitController.forLocale(
              const Locale('en', 'GB'),
            ),
            mapStyleMode: mapStyle,
            riderProfile: riderProfile,
            speedLimitDisplay: SpeedLimitDisplayController.inMemory(),
            spokenGuidance: spoken,
            embedded: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Natural offline voice · Beta'), findsOneWidget);
    final install = find.byKey(const Key('install-natural-voice'));
    await tester.ensureVisible(install);
    await tester.tap(install);
    await tester.pumpAndSettle();

    expect(store.installCalls, 1);
    expect(naturalPack.enabled, isTrue);
    expect(find.byKey(const Key('natural-voice-toggle')), findsOneWidget);
    expect(preview.configured, isTrue);
    expect(preview.spoken, ['In 2 miles, at the roundabout, turn right.']);
  });
}

class _RecordingEngine implements SpokenGuidanceEngine {
  bool configured = false;
  final spoken = <String>[];

  @override
  Future<void> configure() async => configured = true;

  @override
  Future<void> speak(String phrase) async => spoken.add(phrase);

  @override
  Future<void> stop() async {}
}

class _FakeNaturalVoicePackStore implements NaturalVoicePackStore {
  bool installed = false;
  int installCalls = 0;

  @override
  String get modelDirectory => '/fake/kokoro';

  @override
  Future<void> cancelInstall() async {}

  @override
  Future<void> install({required ValueChanged<double?> onProgress}) async {
    installCalls += 1;
    onProgress(0.5);
    installed = true;
    onProgress(1);
  }

  @override
  Future<bool> isInstalled() async => installed;

  @override
  Future<void> remove() async => installed = false;
}
