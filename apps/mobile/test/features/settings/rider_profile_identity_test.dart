import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/rider_profile_controller.dart';
import 'package:ride_relay/domain/rider_color.dart';
import 'package:ride_relay/features/map/motorcycle_icon.dart';
import 'package:ride_relay/features/settings/rider_profile_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('Rider Profile saves white, custom initials and chosen ink', (
    tester,
  ) async {
    final profile = await RiderProfileController.load();
    await profile.save(
      displayName: 'Oliver Holt',
      motorcycleStyle: MotorcycleIconStyle.scrambler,
      riderColor: RiderColor.green,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
          body: RiderProfileSheet(
            riderProfile: profile,
            currentRideActive: false,
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('profile-symbol-initials')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('rider-custom-initials')),
      'OH3',
    );
    await tester.pump();
    final whiteInk = find.byKey(const Key('profile-symbol-initials-ink-white'));
    await tester.ensureVisible(whiteInk);
    await tester.tap(whiteInk);
    final whiteBadge = find.byKey(const Key('profile-colour-white'));
    await tester.ensureVisible(whiteBadge);
    await tester.tap(whiteBadge);
    final save = find.byKey(const Key('save-rider-profile'));
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();

    expect(profile.riderSymbol.storageValue, 'initials:v1:T0gz:white');
    expect(profile.riderColor, RiderColor.white);
    expect(
      (await RiderProfileController.load()).riderSymbol,
      profile.riderSymbol,
    );
  });
}
