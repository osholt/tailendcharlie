import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/ride_simulation_controller.dart';
import 'package:ride_relay/domain/geo_point.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/rider_color.dart';
import 'package:ride_relay/domain/route_store.dart';
import 'package:ride_relay/features/map/motorcycle_icon.dart';
import 'package:ride_relay/features/ride/active_ride_shell.dart';
import 'package:ride_relay/services/ride_membership.dart';

void main() {
  group('the registered TEC comes from the reconciled roster', () {
    RideParticipant participant({
      required String riderId,
      required RideRole role,
      RideMembershipState state = RideMembershipState.joined,
    }) => RideParticipant(
      riderId: riderId,
      displayName: riderId,
      role: role,
      joinedAt: DateTime.utc(2026, 7, 25, 9),
      lastSeenAt: DateTime.utc(2026, 7, 25, 9),
      state: state,
      motorcycleStyle: motorcycleIconStyleDefault,
      riderColor: RiderColor.amber,
      transportEvidence: const {RideTransportEvidence.internetRelay},
      isLocal: false,
    );

    test('a joined TEC counts before reporting any position', () {
      expect(
        registeredTecRiderIds(
          simulatedRiders: null,
          liveParticipants: [
            participant(riderId: 'lead', role: RideRole.lead),
            participant(riderId: 'charlie', role: RideRole.tailEndCharlie),
          ],
        ),
        {'charlie'},
      );
    });

    test('a ride of riders only has no TEC', () {
      expect(
        registeredTecRiderIds(
          simulatedRiders: null,
          liveParticipants: [
            participant(riderId: 'lead', role: RideRole.lead),
            participant(riderId: 'alex', role: RideRole.rider),
          ],
        ),
        isEmpty,
      );
    });

    test('a TEC who has left the ride is no longer the TEC', () {
      expect(
        registeredTecRiderIds(
          simulatedRiders: null,
          liveParticipants: [
            participant(riderId: 'lead', role: RideRole.lead),
            participant(
              riderId: 'charlie',
              role: RideRole.tailEndCharlie,
              state: RideMembershipState.left,
            ),
          ],
        ),
        isEmpty,
      );
    });

    test('Ride Lab resolves its TEC from the virtual roster', () {
      expect(
        registeredTecRiderIds(
          simulatedRiders: [
            _simulated(id: 'ride-lab-maya', role: RideRole.lead),
            _simulated(id: 'ride-lab-charlie', role: RideRole.tailEndCharlie),
          ],
          liveParticipants: const [],
        ),
        {'ride-lab-charlie'},
      );
    });
  });

  test(
    'a new ride waits for its scoped route store before mounting the map',
    () {
      final rideStore = InMemoryRouteStore();

      expect(
        activeRideMapStoreWhenReady(
          initializing: true,
          isSimulation: false,
          rideRouteStore: rideStore,
          simulationRouteStore: null,
        ),
        isNull,
      );
      expect(
        activeRideMapStoreWhenReady(
          initializing: false,
          isSimulation: false,
          rideRouteStore: rideStore,
          simulationRouteStore: null,
        ),
        same(rideStore),
      );
      expect(
        activeRideMapStoreWhenReady(
          initializing: false,
          isSimulation: false,
          rideRouteStore: null,
          simulationRouteStore: null,
        ),
        isNull,
      );
    },
  );
}

SimulatedRiderSnapshot _simulated({
  required String id,
  required RideRole role,
}) => SimulatedRiderSnapshot(
  id: id,
  displayName: id,
  role: role,
  progress: 0,
  speedMetersPerSecond: 12,
  isLocal: false,
  isOffRoute: false,
  position: const GeoPoint(latitude: 51.45, longitude: -2.59),
  headingDegrees: 90,
  offRouteTrail: const [],
  travelTrail: const [],
  motorcycleStyle: motorcycleIconStyleDefault,
  riderColor: RiderColor.amber,
);
