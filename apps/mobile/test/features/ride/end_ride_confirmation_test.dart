import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/features/ride/end_ride_confirmation.dart';

/// Ending a ride stops the group, not just this phone, and it was reachable two
/// ways with a different dialog behind each (#306: "every destructive or safety
/// action reachable by the same gesture every time").
///
/// The two were not merely worded differently. Only the ride menu's told the
/// leader whether the ride could be resumed — including "this action cannot be
/// undone for the group" when the relay cannot carry a reopen. Only the
/// dashboard's showed the marking summary and offered to share it. So **whether
/// a leader learned that ending the ride was irreversible depended on which
/// button they happened to press.**
void main() {
  group('the consequence is stated once, for both entry points', () {
    test('a reopenable ride says it can be resumed', () {
      final text = endRideConsequence(relayCanCarryReopen: true);

      expect(text, contains('ends the group ride for everyone'));
      expect(text, contains('resume it within 24 hours'));
      expect(text, isNot(contains('cannot be undone')));
    });

    test('a ride that cannot be reopened says it cannot be undone', () {
      // The sentence the dashboard's dialog never had, and the one a leader
      // needs most.
      final text = endRideConsequence(relayCanCarryReopen: false);

      expect(text, contains('cannot resume an ended ride'));
      expect(text, contains('cannot be undone for the group'));
      expect(text, isNot(contains('within 24 hours')));
    });

    test('both readings name the group, not just this phone', () {
      // The dashboard's old wording led with "Location sharing will stop on
      // this phone", which understates an action that ends everyone's ride.
      for (final reopenable in [true, false]) {
        expect(
          endRideConsequence(relayCanCarryReopen: reopenable),
          contains('for everyone'),
          reason: 'relayCanCarryReopen: $reopenable',
        );
      }
    });

    test('the two readings differ only in whether it can be undone', () {
      // If they diverged anywhere else, the two entry points would be back to
      // telling a leader different things about the same action.
      final reopenable = endRideConsequence(relayCanCarryReopen: true);
      final permanent = endRideConsequence(relayCanCarryReopen: false);
      String head(String text) => text.split('\n\n').first;

      expect(head(reopenable), head(permanent));
      expect(reopenable, isNot(permanent));
    });
  });
}
