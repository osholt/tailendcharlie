import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/ride_controller.dart';
import 'package:ride_relay/data/in_memory_event_store.dart';
import 'package:ride_relay/data/in_memory_session_store.dart';
import 'package:ride_relay/domain/completed_ride_store.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/domain/ride_coordination_mode.dart';
import 'package:ride_relay/domain/ride_event.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/ride_session.dart';
import 'package:ride_relay/internet/internet_relay_client.dart';
import 'package:ride_relay/services/nearby_bridge.dart';

/// Solo to group, as one action that keeps the route (#847).
void main() {
  late InMemoryCompletedRideStore archive;
  late RideController controller;
  late int id;

  setUp(() async {
    archive = InMemoryCompletedRideStore();
    id = 0;
    controller = RideController(
      InMemoryEventStore(),
      InMemorySessionStore(),
      const _FakeNearbyBridge(),
      clock: () => DateTime.utc(2026, 10, 4, 10),
      idFactory: () => 'id-${(id++).toString().padLeft(3, '0')}',
      random: Random(7),
      rideCodeDirectory: _UnusedRideCodeDirectory(),
      completedRideStore: archive,
    );
    await controller.initialize();
  });

  tearDown(() => controller.dispose());

  test(
    'a rider who is navigating stays navigating as a group leader',
    () async {
      final route = _route();

      await controller.startGroupRide(
        displayName: 'Oliver',
        route: route,
        startNow: true,
      );

      expect(controller.errorMessage, isNull);
      expect(controller.session?.role, RideRole.lead);
      expect(
        controller.coordinationMode,
        RideCoordinationMode.secondBikeDropOff,
      );
      // Started at once: a moving rider is never put back into a lobby, so the
      // map keeps navigating and the voice keeps talking.
      expect(controller.rideStarted, isTrue);
      expect(controller.authoritativeRoute?.id, route.id);
      expect(controller.authoritativeRoute?.waypoints.last.name, 'Town');
      expect(controller.session?.rideName, 'To Town');
      // The ordinary group-ride events, in the order CarPlay already uses.
      final types = controller.events.map((event) => event.type).toList();
      expect(types.first, RideEventType.rideCreated);
      expect(types.last, RideEventType.rideStarted);
      expect(
        types.indexOf(RideEventType.routeRevisionPublished),
        lessThan(types.indexOf(RideEventType.rideStarted)),
      );
    },
  );

  test('a plan made as a group waits in the lobby with its route', () async {
    await controller.startGroupRide(
      displayName: 'Oliver',
      coordinationMode: RideCoordinationMode.keepTogether,
      route: _route(),
    );

    expect(controller.coordinationMode, RideCoordinationMode.keepTogether);
    expect(controller.rideStarted, isFalse);
    expect(controller.authoritativeRoute, isNotNull);
  });

  test('a solo ride under way is filed and becomes a group ride', () async {
    await controller.createRide(
      'Oliver',
      coordinationMode: RideCoordinationMode.solo,
    );
    await controller.startRide();
    final soloRideId = controller.session!.rideId;

    await controller.startGroupRide(
      displayName: 'Oliver',
      route: _route(),
      startNow: controller.rideStarted,
    );

    expect(controller.errorMessage, isNull);
    expect(controller.session!.rideId, isNot(soloRideId));
    expect(controller.coordinationMode.isGroup, isTrue);
    expect(controller.rideStarted, isTrue);
    expect(
      (await archive.list()).map((ride) => ride.rideId),
      contains(soloRideId),
    );
  });

  test('a group ride is already a group ride', () async {
    await controller.createRide('Oliver');
    final rideId = controller.session!.rideId;

    await controller.startGroupRide(displayName: 'Oliver', route: _route());

    expect(controller.errorMessage, 'This is already a group ride.');
    expect(controller.session!.rideId, rideId);
  });

  test('a refused name never costs the rider their solo ride', () async {
    await controller.createRide(
      'Oliver',
      coordinationMode: RideCoordinationMode.solo,
    );
    final soloRideId = controller.session!.rideId;

    await controller.startGroupRide(displayName: '  ', route: _route());

    expect(controller.errorMessage, 'Enter a rider name.');
    expect(controller.session!.rideId, soloRideId);
    expect(controller.coordinationMode, RideCoordinationMode.solo);
  });

  test('solo is not a group mode', () async {
    await controller.startGroupRide(
      displayName: 'Oliver',
      coordinationMode: RideCoordinationMode.solo,
    );

    expect(controller.hasActiveRide, isFalse);
    expect(controller.errorMessage, isNotNull);
  });
}

ImportedRoute _route() => ImportedRoute(
  id: 'to-town',
  name: 'To Town',
  importedAt: DateTime.utc(2026, 10, 4, 9),
  sourceFileName: 'to-town.gpx',
  paths: const [
    RoutePath(
      kind: RoutePathKind.track,
      points: [
        GeoPoint(latitude: 52.0, longitude: -1.0),
        GeoPoint(latitude: 52.3, longitude: -1.0),
      ],
    ),
  ],
  waypoints: const [
    RouteWaypoint(
      point: GeoPoint(latitude: 52.0, longitude: -1.0),
      name: 'Start',
      description: 'Current location',
    ),
    RouteWaypoint(
      point: GeoPoint(latitude: 52.3, longitude: -1.0),
      name: 'Town',
    ),
  ],
);

class _FakeNearbyBridge extends NearbyBridge {
  const _FakeNearbyBridge();

  @override
  Future<NearbyCapabilities> capabilities() async =>
      const NearbyCapabilities.unavailable();
}

/// Converting never registers or resolves a code itself; the ride shell does
/// that for any group ride it opens.
class _UnusedRideCodeDirectory implements RideCodeDirectory {
  @override
  Future<void> register(RideSession session) async =>
      throw StateError('not used by a conversion');

  @override
  Future<RideCodeCredentials> resolve(String rideCode, {String? joinToken}) =>
      throw StateError('not used by a conversion');

  @override
  void close() {}
}
