import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/ride_simulation_controller.dart';
import 'package:ride_relay/controllers/situational_awareness_controller.dart';
import 'package:ride_relay/data/in_memory_event_store.dart';
import 'package:ride_relay/domain/geo_point.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/ride_session.dart';
import 'package:ride_relay/domain/route_alert.dart';
import 'package:ride_relay/services/ride_completion_detector.dart';

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
    expect(smoothSimulation.eventInterval, const Duration(seconds: 2));
  });

  test('retains a recent trail for the simulated leader', () async {
    final initialLeader = simulation.riders.singleWhere(
      (rider) => rider.role == RideRole.lead,
    );
    final tec = simulation.riders.singleWhere(
      (rider) => rider.role == RideRole.tailEndCharlie,
    );
    expect(initialLeader.travelTrail.length, greaterThan(1));
    expect(
      initialLeader.travelTrail.first.latitude,
      closeTo(tec.position.latitude, 1e-7),
    );
    expect(
      initialLeader.travelTrail.first.longitude,
      closeTo(tec.position.longitude, 1e-7),
    );

    await simulation.advance(const Duration(seconds: 1));

    final movingLeader = simulation.riders.singleWhere(
      (rider) => rider.role == RideRole.lead,
    );
    expect(movingLeader.travelTrail.length, greaterThan(1));
  });

  test('switches between leader, follower and TEC perspectives', () {
    simulation.setLocalRole(RideRole.rider);
    expect(simulation.localRole, RideRole.rider);
    final follower = simulation.riders.singleWhere((rider) => rider.isLocal);
    final leader = simulation.riders.singleWhere(
      (rider) => rider.displayName == 'Maya',
    );
    expect(follower.displayName, 'You · Follower');
    expect(follower.progress, lessThan(leader.progress));
    expect(leader.role, RideRole.lead);

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

  test('follower perspective remains behind the simulated leader', () async {
    simulation.setLocalRole(RideRole.rider);
    simulation.setTimeScale(1);

    await simulation.advance(const Duration(seconds: 30));

    final follower = simulation.riders.singleWhere((rider) => rider.isLocal);
    final leader = simulation.riders.singleWhere(
      (rider) => rider.displayName == 'Maya',
    );
    expect(follower.role, RideRole.rider);
    expect(leader.role, RideRole.lead);
    expect(follower.progress, lessThan(leader.progress));
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
    'follower automatically marks a junction and rides off before TEC arrives',
    () async {
      final markerSimulation = RideSimulationController(
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
        markerJunctions: const [GeoPoint(latitude: 51, longitude: -0.99)],
        tickInterval: const Duration(days: 1),
      );
      addTearDown(markerSimulation.dispose);
      await markerSimulation.initialize();
      markerSimulation.setLocalRole(RideRole.rider);

      await markerSimulation.advance(const Duration(seconds: 4));

      final stopped = markerSimulation.riders.singleWhere(
        (rider) => rider.isLocal,
      );
      expect(markerSimulation.markerMode, isTrue);
      expect(markerSimulation.automaticMarkerActivation, 1);
      expect(
        markerSimulation.markerPhase,
        SimulationMarkerPhase.waitingForRiders,
      );
      expect(stopped.role, RideRole.marker);
      expect(stopped.speedMetersPerSecond, 0);
      expect(markerSimulation.ridersExpectedToPass, greaterThanOrEqualTo(1));
      expect(markerSimulation.markerInstruction, contains('You are holding'));

      var sawTecApproaching = false;
      for (
        var tick = 0;
        tick < 180 && markerSimulation.automaticMarkerRideOffActivation == 0;
        tick += 1
      ) {
        await markerSimulation.advance(const Duration(milliseconds: 100));
        sawTecApproaching |=
            markerSimulation.markerPhase ==
            SimulationMarkerPhase.tecApproaching;
      }

      expect(sawTecApproaching, isTrue);
      expect(markerSimulation.automaticMarkerRideOffActivation, 1);
      expect(markerSimulation.lastAutomaticMarkerRideOffWasLocal, isTrue);
      expect(markerSimulation.markerMode, isFalse);
      expect(markerSimulation.markerPhase, SimulationMarkerPhase.riding);
      expect(
        markerSimulation.riders.singleWhere((rider) => rider.isLocal).role,
        RideRole.rider,
      );
    },
  );

  test(
    'the simulated second bike marks a route decision from leader view',
    () async {
      final markerSimulation = RideSimulationController(
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
        markerJunctions: const [GeoPoint(latitude: 51, longitude: -0.99)],
        tickInterval: const Duration(days: 1),
      );
      addTearDown(markerSimulation.dispose);
      await markerSimulation.initialize();

      for (
        var tick = 0;
        tick < 20 && !markerSimulation.automaticMarkerActive;
        tick += 1
      ) {
        await markerSimulation.advance(const Duration(seconds: 1));
      }

      final maya = markerSimulation.riders.singleWhere(
        (rider) => rider.id == 'ride-lab-maya',
      );
      expect(markerSimulation.localRole, RideRole.lead);
      expect(markerSimulation.automaticMarkerActive, isTrue);
      expect(markerSimulation.automaticMarkerIsLocal, isFalse);
      expect(markerSimulation.automaticMarkerRiderName, 'Maya');
      expect(maya.role, RideRole.marker);
      expect(maya.speedMetersPerSecond, 0);
      expect(markerSimulation.markerInstruction, contains('Maya is holding'));

      markerSimulation.setLocalRole(RideRole.rider);
      expect(markerSimulation.localRole, RideRole.rider);
      expect(
        markerSimulation.riders
            .singleWhere((rider) => rider.id == maya.id)
            .role,
        RideRole.marker,
      );
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

  test(
    'off-route visual trail is local to the current simulation run',
    () async {
      simulation.setAlexOffRoute(true);
      await simulation.advance(const Duration(seconds: 1));

      final alex = simulation.riders.singleWhere(
        (rider) => rider.id == RideSimulationController.offRouteRiderId,
      );
      expect(alex.offRouteTrail, hasLength(greaterThanOrEqualTo(2)));
      expect(
        alex.offRouteTrail.every(
          (point) => point.latitude > 50 && point.latitude < 52,
        ),
        isTrue,
      );

      simulation.setAlexOffRoute(false);
      expect(
        simulation.riders
            .singleWhere(
              (rider) => rider.id == RideSimulationController.offRouteRiderId,
            )
            .offRouteTrail,
        isEmpty,
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
    // A marker can be released during one visual step, then needs the next
    // step to rejoin the fleet. Completion is intentionally group-wide.
    for (var index = 0; index < 3; index += 1) {
      await simulation.advance(const Duration(minutes: 1));
      if (simulation.state == RideSimulationState.completed) break;
    }

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
    expect(
      const RideCompletionDetector().everyoneReachedDestination(
        destination: const GeoPoint(latitude: 51, longitude: -0.9),
        riderLocations: awareness.riderLocations,
        now: DateTime.now(),
      ),
      isTrue,
    );
  });
}
