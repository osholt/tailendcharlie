import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/distance_unit_controller.dart';
import 'package:ride_relay/controllers/map_style_mode_controller.dart';
import 'package:ride_relay/controllers/rider_profile_controller.dart';
import 'package:ride_relay/controllers/speed_limit_display_controller.dart';
import 'package:ride_relay/controllers/spoken_guidance_controller.dart';
import 'package:ride_relay/features/settings/unit_settings_sheet.dart';
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
