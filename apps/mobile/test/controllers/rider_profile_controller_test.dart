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
      riderSymbol: const RiderSymbol.emoji('🦊'),
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
    expect(reloaded.riderSymbol, const RiderSymbol.emoji('🦊'));
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

  group("a rider's own number (#188)", () {
    test('is empty on a fresh install and never inferred', () async {
      final profile = await RiderProfileController.load();

      expect(profile.ownPhoneNumber, isEmpty);
      expect(profile.hasOwnPhoneNumber, isFalse);
      // The whole point of the field: an install that has been given nothing
      // holds nothing. Nothing reads the SIM, the telephony subscription or the
      // contacts book, so there is no path by which a number appears here
      // without the rider typing it.
    });

    test('survives a restart, and is a different field from the ICE '
        'contact', () async {
      final profile = await RiderProfileController.load();

      await profile.saveOwnPhoneNumber(' +44 7700 900321 ');
      await profile.saveEmergencyInfo(
        emergencyContactName: 'Jamie Rider',
        emergencyContactPhone: '+44 7700 900123',
        medicalNotes: '',
        shareWithLeaderByDefault: true,
      );
      final reloaded = await RiderProfileController.load();

      expect(reloaded.ownPhoneNumber, '+44 7700 900321');
      expect(reloaded.hasOwnPhoneNumber, isTrue);
      // Distinct storage: ringing one must never ring the other.
      expect(reloaded.emergencyContactPhone, '+44 7700 900123');
      expect(reloaded.ownPhoneNumber, isNot(reloaded.emergencyContactPhone));
    });

    test('saving an ICE contact never populates the rider\'s own '
        'number', () async {
      final profile = await RiderProfileController.load();

      await profile.saveEmergencyInfo(
        emergencyContactName: 'Next of kin',
        emergencyContactPhone: '+44 7700 900999',
        medicalNotes: 'Penicillin allergy',
        shareWithLeaderByDefault: true,
      );

      expect(profile.ownPhoneNumber, isEmpty);
      expect(profile.hasOwnPhoneNumber, isFalse);
      expect((await RiderProfileController.load()).ownPhoneNumber, isEmpty);
    });

    test('an empty value clears it rather than storing a blank', () async {
      final profile = await RiderProfileController.load();
      await profile.saveOwnPhoneNumber('07700 900321');

      await profile.saveOwnPhoneNumber('   ');

      expect(profile.hasOwnPhoneNumber, isFalse);
      expect((await RiderProfileController.load()).ownPhoneNumber, isEmpty);
    });

    test('a value that is not dialable is rejected, not stored', () async {
      final profile = await RiderProfileController.load();

      // This is handed to `tel:`/`sms:`, so anything carrying a scheme, a path
      // or free text is refused rather than sanitised into something that
      // dials somewhere unintended.
      for (final rejected in [
        'tel:+447700900321',
        '+44 7700 900321?body=hi',
        'call me',
        '123',
        'sms:07700900321',
      ]) {
        await expectLater(
          profile.saveOwnPhoneNumber(rejected),
          throwsArgumentError,
          reason: rejected,
        );
      }
      expect(profile.hasOwnPhoneNumber, isFalse);
    });
  });
}
