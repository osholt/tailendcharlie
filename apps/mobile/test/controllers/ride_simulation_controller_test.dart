import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/ride_simulation_controller.dart';
import 'package:ride_relay/controllers/situational_awareness_controller.dart';
import 'package:ride_relay/data/in_memory_event_store.dart';
import 'package:ride_relay/domain/geo_point.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/ride_session.dart';
import 'package:ride_relay/domain/route_alert.dart';

void main() {
  late InMemoryEventStore store;
  late SituationalAwarenessController awareness;
  late RideSimulationController simulation;

  setUp(() async {
    store = InMemoryEventStore();
    final session = RideSession(
      rideId: 'sim-ride',
      rideCode: 'SIM123',
      inviteSecret: 'simulation-secret-that-is-long-enough',
      localRiderId: 'lead',
      displayName: 'Demo Lead',
      role: RideRole.lead,
      joinedAt: DateTime.utc(2026, 7, 17),
      isSimulation: true,
    );
    const route = [
      GeoPoint(latitude: 51, longitude: -1),
      GeoPoint(latitude: 51, longitude: -0.9),
    ];
    awareness = SituationalAwarenessController(store, session, route: route);
    await awareness.initialize();
    simulation = RideSimulationController(
      awareness,
      session: session,
      route: route,
      tickInterval: const Duration(days: 1),
    );
    await simulation.initialize();
  });

  tearDown(() {
    simulation.dispose();
    awareness.dispose();
  });

  test(
    'emits an authenticated five-bike fleet and advances virtual time',
    () async {
      expect(awareness.riderLocations, hasLength(5));
      expect(awareness.authenticatedLocationEvidence, hasLength(5));
      expect(
        awareness.riderLocations
            .singleWhere(
              (location) =>
                  location.riderId == RideSimulationController.tecRiderId,
            )
            .role,
        RideRole.tailEndCharlie,
      );

      final initialProgress = simulation.progress;
      await simulation.advance(const Duration(seconds: 2));

      expect(simulation.progress, greaterThan(initialProgress));
      expect(simulation.simulatedElapsed, const Duration(seconds: 16));
    },
  );

  test('uses short updates for continuous visual movement', () {
    final smoothSimulation = RideSimulationController(
      awareness,
      session: RideSession(
        rideId: 'sim-ride',
        rideCode: 'SIM123',
        inviteSecret: 'simulation-secret-that-is-long-enough',
        localRiderId: 'lead',
        displayName: 'Demo Lead',
        role: RideRole.lead,
        joinedAt: DateTime.utc(2026, 7, 17),
        isSimulation: true,
      ),
      route: const [
        GeoPoint(latitude: 51, longitude: -1),
        GeoPoint(latitude: 51, longitude: -0.9),
      ],
    );
    addTearDown(smoothSimulation.dispose);

    expect(smoothSimulation.tickInterval, const Duration(milliseconds: 100));
    expect(smoothSimulation.eventInterval, const Duration(milliseconds: 500));
  });

  test('switches between leader, follower and TEC perspectives', () {
    simulation.setLocalRole(RideRole.rider);
    expect(simulation.localRole, RideRole.rider);
    expect(
      simulation.riders
          .singleWhere((rider) => rider.displayName == 'Maya')
          .role,
      RideRole.lead,
    );

    simulation.setLocalRole(RideRole.tailEndCharlie);
    expect(simulation.localRole, RideRole.tailEndCharlie);
    expect(
      simulation.riders
          .singleWhere(
            (rider) => rider.id == RideSimulationController.tecRiderId,
          )
          .role,
      RideRole.rider,
    );
  });

  test(
    'marker mode freezes the local bike while the group continues',
    () async {
      final localBefore = simulation.riders.singleWhere(
        (rider) => rider.isLocal,
      );
      final mayaBefore = simulation.riders.singleWhere(
        (rider) => rider.displayName == 'Maya',
      );
      simulation.setMarkerMode(true);

      await simulation.advance(const Duration(seconds: 1));

      final localAfter = simulation.riders.singleWhere(
        (rider) => rider.isLocal,
      );
      final mayaAfter = simulation.riders.singleWhere(
        (rider) => rider.displayName == 'Maya',
      );
      expect(localAfter.role, RideRole.marker);
      expect(localAfter.progress, localBefore.progress);
      expect(localAfter.speedMetersPerSecond, 0);
      expect(mayaAfter.progress, greaterThan(mayaBefore.progress));
    },
  );

  test(
    'off-route scenario drives real alert hysteresis and recovery',
    () async {
      simulation.setAlexOffRoute(true);
      await simulation.advance(const Duration(seconds: 1));
      await simulation.advance(const Duration(seconds: 1));
      await simulation.advance(const Duration(seconds: 1));

      final alert = awareness.alertFor(
        RideSimulationController.offRouteRiderId,
      );
      expect(alert?.assessment.state, RouteTrackingState.offRoute);
      expect(alert?.assessment.alertLevel, RouteAlertLevel.urgent);
      expect(alert?.assessment.distanceFromRouteMeters, greaterThan(120));

      simulation.setAlexOffRoute(false);
      await simulation.advance(const Duration(seconds: 1));
      await simulation.advance(const Duration(seconds: 1));

      expect(
        awareness
            .alertFor(RideSimulationController.offRouteRiderId)
            ?.assessment
            .state,
        RouteTrackingState.onRoute,
      );
    },
  );

  test('can delay TEC and inject a synthetic roadworks hazard', () async {
    final normalTecSpeed = simulation.riders
        .singleWhere((rider) => rider.id == RideSimulationController.tecRiderId)
        .speedMetersPerSecond;
    simulation.setTecDelayed(true);
    final delayedTecSpeed = simulation.riders
        .singleWhere((rider) => rider.id == RideSimulationController.tecRiderId)
        .speedMetersPerSecond;
    expect(delayedTecSpeed, lessThan(normalTecSpeed));

    await simulation.reportRoadworks();
    expect(awareness.activeHazards.single.details, contains('Ride Lab'));
    expect(
      (awareness.activeHazards.single.position.longitude -
              awareness.localLocation!.sample.position.longitude)
          .abs(),
      greaterThan(0.0001),
    );
  });

  test('completion publishes stopped GPS fixes', () async {
    simulation.setTimeScale(16);
    await simulation.advance(const Duration(hours: 1));

    expect(simulation.state, RideSimulationState.completed);
    expect(
      simulation.riders.every((rider) => rider.speedMetersPerSecond == 0),
      isTrue,
    );
    expect(
      awareness.riderLocations.every(
        (location) => location.sample.speedMetersPerSecond == 0,
      ),
      isTrue,
    );
  });
}
