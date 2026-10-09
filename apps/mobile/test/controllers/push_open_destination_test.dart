import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/ride_push_notification_controller.dart';
import 'package:ride_relay/features/ride/active_ride_shell.dart';

PushOpenRequest _request(String category) =>
    PushOpenRequest(rideId: 'ride-1', eventId: 'event-1', category: category);

/// What 1.0.1+101 and +102 do with a tapped push, restated and frozen: they know
/// only `safety`, and send every other category, including one they have never
/// heard of, to the Ride tab. The relay's new categories reach those builds
/// first, so this is what a tester on build 102 meets (#881).
int _build102Destination({
  required bool isSimulation,
  required String category,
}) {
  final safetyAlert = category == 'safety';
  return switch ((isSimulation, safetyAlert)) {
    (true, true) => 3,
    (true, false) => 2,
    (false, true) => 2,
    (false, false) => 1,
  };
}

void main() {
  group('a tapped push opens the map for a leader broadcast or an alert', () {
    for (final isSimulation in [false, true]) {
      for (final category in [
        PushCategory.leaderBroadcast,
        PushCategory.groupAlert,
      ]) {
        test('$category, simulation: $isSimulation', () {
          expect(
            pushOpenDestinationIndex(
              isSimulation: isSimulation,
              request: _request(category),
            ),
            0,
          );
          expect(rideDestinations(simulation: isSimulation).first.label, 'Map');
        });
      }
    }

    test('the relay and the app agree on the two category names', () {
      // The strings the relay sends; renaming one on either side silently sends
      // every tap back to the Ride tab.
      expect(PushCategory.leaderBroadcast, 'leaderBroadcast');
      expect(PushCategory.groupAlert, 'groupAlert');
    });
  });

  group('every other category keeps the destination it always had', () {
    for (final (category, simulation, index) in [
      ('safety', false, 2),
      ('safety', true, 3),
      ('status', false, 1),
      ('status', true, 2),
      ('administrative', false, 1),
      ('administrative', true, 2),
      ('somethingTheRelayAddsLater', false, 1),
      ('', false, 1),
    ]) {
      test('"$category", simulation: $simulation', () {
        final request = _request(category);

        expect(request.isGroupInstruction, isFalse);
        expect(
          pushOpenDestinationIndex(isSimulation: simulation, request: request),
          index,
        );
      });
    }
  });

  group('a phone on build 101 or 102 meets the new push safely', () {
    for (final isSimulation in [false, true]) {
      for (final category in [
        PushCategory.leaderBroadcast,
        PushCategory.groupAlert,
      ]) {
        test('$category opens a real tab, simulation: $isSimulation', () {
          final destination = _build102Destination(
            isSimulation: isSimulation,
            category: category,
          );

          // The Ride tab: a destination that exists, not an index past the bar.
          expect(
            destination,
            lessThan(rideDestinations(simulation: isSimulation).length),
          );
          expect(
            rideDestinations(simulation: isSimulation)[destination].label,
            'Ride',
          );
        });
      }
    }
  });
}
