import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/rider_profile_controller.dart';
import 'package:ride_relay/domain/rider_color.dart';
import 'package:ride_relay/features/map/motorcycle_icon.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('emergency info defaults to empty and unset', () async {
    final profile = await RiderProfileController.load();

    expect(profile.emergencyContactName, isEmpty);
    expect(profile.emergencyContactPhone, isEmpty);
    expect(profile.medicalNotes, isEmpty);
    expect(profile.hasEmergencyInfo, isFalse);
    expect(profile.shareIceWithLeaderByDefault, isFalse);
    expect(profile.installationId, isNotEmpty);
    expect(profile.needsOnboarding, isTrue);
  });

  test('installation identity is stable across app restarts', () async {
    final first = await RiderProfileController.load();
    final second = await RiderProfileController.load();

    expect(second.installationId, first.installationId);
  });

  test(
    'emergency info survives a fresh load, as if the app restarted',
    () async {
      final profile = await RiderProfileController.load();

      await profile.saveEmergencyInfo(
        emergencyContactName: 'Jamie Rider',
        emergencyContactPhone: '+44 7700 900123',
        medicalNotes: 'Penicillin allergy',
        shareWithLeaderByDefault: true,
      );

      final reloaded = await RiderProfileController.load();
      expect(reloaded.emergencyContactName, 'Jamie Rider');
      expect(reloaded.emergencyContactPhone, '+44 7700 900123');
      expect(reloaded.medicalNotes, 'Penicillin allergy');
      expect(reloaded.hasEmergencyInfo, isTrue);
      expect(reloaded.shareIceWithLeaderByDefault, isTrue);
    },
  );

  test('onboarding profile and completion survive an app restart', () async {
    final profile = await RiderProfileController.load();

    await profile.completeOnboarding(
      displayName: '  Oliver  ',
      motorcycleStyle: MotorcycleIconStyle.scrambler,
      riderColor: RiderColor.cyan,
      educationSkipped: false,
      rideChoice: OnboardingRideChoice.join,
    );
    final reloaded = await RiderProfileController.load();

    expect(profile.takePendingRideChoice(), OnboardingRideChoice.join);
    expect(profile.takePendingRideChoice(), isNull);
    expect(reloaded.onboardingCompleted, isTrue);
    expect(reloaded.displayName, 'Oliver');
    expect(reloaded.motorcycleStyle, MotorcycleIconStyle.scrambler);
    expect(reloaded.riderColor, RiderColor.cyan);
  });

  test('optional education can be skipped and onboarding replayed', () async {
    final profile = await RiderProfileController.load();
    await profile.completeOnboarding(
      displayName: 'Oliver',
      motorcycleStyle: MotorcycleIconStyle.roadster,
      riderColor: RiderColor.orange,
      educationSkipped: true,
      rideChoice: OnboardingRideChoice.create,
    );

    expect(profile.onboardingEducationSkipped, isTrue);
    await profile.replayOnboarding();
    final reloaded = await RiderProfileController.load();

    expect(reloaded.needsOnboarding, isTrue);
    expect(reloaded.displayName, 'Oliver');
  });

  test('onboarding requires a non-empty rider name', () async {
    final profile = await RiderProfileController.load();

    await expectLater(
      profile.completeOnboarding(
        displayName: '   ',
        motorcycleStyle: MotorcycleIconStyle.adventureTourer,
        riderColor: RiderColor.green,
        educationSkipped: false,
        rideChoice: OnboardingRideChoice.create,
      ),
      throwsArgumentError,
    );
    expect(profile.needsOnboarding, isTrue);
  });

  test('an existing saved profile is migrated past first-run setup', () async {
    SharedPreferences.setMockInitialValues({
      'rider_profile_display_name': 'Existing rider',
    });

    final profile = await RiderProfileController.load();

    expect(profile.onboardingCompleted, isTrue);
  });
}
