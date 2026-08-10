import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/features/ride/active_ride_shell.dart';

void main() {
  group('the active ride names its destinations once (#404)', () {
    // The navigation bar, the landscape rail and the ride menu all read this
    // list. The menu is the only way to reach these while the rider is moving,
    // so a copy that drifted would send a rider to the wrong tab at exactly the
    // moment they cannot look at the screen.

    test('an ordinary ride is Map, Ride, Alerts', () {
      final destinations = rideDestinations(simulation: false);

      expect(
        destinations.map((destination) => destination.label),
        ['Map', 'Ride', 'Alerts'],
      );
      expect(destinations.map((destination) => destination.index), [0, 1, 2]);
    });

    test('a simulation inserts Ride Lab and shifts what follows it', () {
      // The shell's `switch` puts Ride Lab at 1 in a simulation, so Ride and
      // Alerts are one further along than in an ordinary ride. Carrying the
      // index rather than letting a caller count is what keeps the menu
      // agreeing with the bar.
      final destinations = rideDestinations(simulation: true);

      expect(
        destinations.map((destination) => destination.label),
        ['Map', 'Ride Lab', 'Ride', 'Alerts'],
      );
      expect(destinations.map((destination) => destination.index), [0, 1, 2, 3]);
      expect(
        destinations.firstWhere((d) => d.label == 'Ride').index,
        2,
        reason: 'Ride Lab occupies 1 in a simulation',
      );
    });

    test('the map is always the first destination', () {
      // `hideWhileMoving` is written against index 0 being the map. If that
      // ever stopped being true the bar would hide on the wrong tab.
      for (final simulation in [false, true]) {
        expect(
          rideDestinations(simulation: simulation).first.index,
          0,
          reason: 'simulation: $simulation',
        );
        expect(
          rideDestinations(simulation: simulation).first.label,
          'Map',
          reason: 'simulation: $simulation',
        );
      }
    });
  });
}
