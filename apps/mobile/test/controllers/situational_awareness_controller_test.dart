import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/situational_awareness_controller.dart';
import 'package:ride_relay/data/in_memory_event_store.dart';
import 'package:ride_relay/domain/geo_point.dart';
import 'package:ride_relay/domain/hazard.dart';
import 'package:ride_relay/domain/ride_event.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/ride_session.dart';
import 'package:ride_relay/domain/rider_location.dart';
import 'package:ride_relay/domain/route_alert.dart';
import 'package:ride_relay/services/external_hazard_provider.dart';
import 'package:ride_relay/services/route_deviation_detector.dart';
import 'package:ride_relay/services/situation_event_factory.dart';

void main() {
  late InMemoryEventStore store;
  late DateTime now;
  late int nextId;
  late SituationalAwarenessController controller;

  setUp(() async {
    store = InMemoryEventStore();
    now = DateTime.utc(2026, 7, 16, 12);
    nextId = 0;
    controller = _controller(
      store: store,
      clock: () => now,
      idFactory: () => 'id-${nextId++}',
    );
    await controller.initialize();
  });

  tearDown(() => controller.dispose());

  test('location and route assessment are persisted as ride events', () async {
    await controller.recordLocalLocation(_sample(latitude: 51.002, at: now));

    expect(controller.riderLocations, hasLength(1));
    expect(
      controller.routeAlerts.single.assessment.state,
      RouteTrackingState.offRoute,
    );
    expect(
      controller.routeAlerts.single.assessment.audience,
      RouteAlertAudience.coordinators,
    );

    final events = await store.eventsForRide(_session.rideId);
    expect(
      events.map((event) => event.type),
      containsAll([
        RideEventType.riderLocationUpdated,
        RideEventType.routeDeviationChanged,
      ]),
    );
  });

  test(
    'hazard report deduplicates, persists, expires, and can clear',
    () async {
      final first = await controller.reportHazard(
        type: HazardType.debris,
        severity: HazardSeverity.caution,
        position: const GeoPoint(latitude: 51, longitude: -1),
      );
      now = now.add(const Duration(minutes: 2));
      final confirmed = await controller.reportHazard(
        type: HazardType.debris,
        severity: HazardSeverity.serious,
        position: const GeoPoint(latitude: 51.0002, longitude: -1),
      );

      expect(confirmed?.id, first?.id);
      expect(controller.activeHazards.single.confirmations, 2);
      expect(controller.activeHazards.single.severity, HazardSeverity.serious);

      await controller.clearHazard(first!.id);
      expect(controller.activeHazards, isEmpty);
      final events = await store.eventsForRide(_session.rideId);
      expect(events.last.type, RideEventType.hazardCleared);
    },
  );

  test('event replay restores active hazards and acknowledgements', () async {
    final hazard = await controller.reportHazard(
      type: HazardType.roadworks,
      severity: HazardSeverity.caution,
      position: const GeoPoint(latitude: 51, longitude: -1),
    );
    await controller.recordLocalLocation(_sample(latitude: 51.002, at: now));
    await controller.acknowledgeAlert(_session.localRiderId);

    final restored = _controller(
      store: store,
      clock: () => now,
      idFactory: () => 'restored-${nextId++}',
    );
    await restored.initialize();

    expect(restored.activeHazards.single.id, hazard?.id);
    expect(restored.alertFor(_session.localRiderId)?.acknowledged, isTrue);
    restored.dispose();
  });

  test('remote events require ride match and a valid signature', () async {
    final factory = SituationEventFactory(
      session: _session,
      clock: () => now,
      idFactory: () => 'remote-event',
    );
    final location = RiderLocation(
      riderId: 'remote-rider',
      displayName: 'Remote',
      role: RideRole.rider,
      sample: _sample(latitude: 51, at: now),
      receivedAt: now,
    );
    final valid = factory.create(
      type: RideEventType.riderLocationUpdated,
      payload: {'location': location.toJson()},
    );

    await controller.ingestRemoteEvent(valid);
    expect(controller.riderLocations.map((item) => item.riderId), [
      'remote-rider',
    ]);

    final tampered = RideEvent(
      id: valid.id,
      rideId: valid.rideId,
      deviceId: valid.deviceId,
      type: valid.type,
      priority: valid.priority,
      createdAt: valid.createdAt,
      payload: {'location': location.toJson()..['displayName'] = 'Tampered'},
      signature: valid.signature,
    );
    expect(
      () => controller.ingestRemoteEvent(tampered),
      throwsA(isA<FormatException>()),
    );
  });

  test('updated local role is used by subsequent location beacons', () async {
    controller.updateLocalSession(
      _session.copyWith(role: RideRole.tailEndCharlie),
    );

    await controller.recordLocalLocation(_sample(latitude: 51, at: now));

    expect(controller.localLocation?.role, RideRole.tailEndCharlie);
  });

  test('refreshing staleness escalates a rider who stops reporting', () async {
    await controller.recordLocalLocation(_sample(latitude: 51, at: now));
    expect(
      controller.alertFor(_session.localRiderId)?.assessment.state,
      RouteTrackingState.onRoute,
    );

    now = now.add(const Duration(seconds: 91));
    await controller.refreshStaleness();

    final assessment = controller.alertFor(_session.localRiderId)?.assessment;
    expect(assessment?.state, RouteTrackingState.gpsStale);
    expect(assessment?.alertLevel, RouteAlertLevel.urgent);
    expect(
      (await store.eventsForRide(_session.rideId)).last.type,
      RideEventType.routeDeviationChanged,
    );
  });

  test(
    "the leader is never flagged off-route once their own trail exists",
    () async {
      await controller.recordLocalLocation(_sample(latitude: 51, at: now));
      now = now.add(const Duration(seconds: 5));
      // The leader detours far from the planned route - e.g. a road closure.
      await controller.recordLocalLocation(_sample(latitude: 52, at: now));

      expect(
        controller.alertFor(_session.localRiderId)?.assessment.state,
        RouteTrackingState.onRoute,
      );
      expect(controller.leaderTrail, hasLength(2));
    },
  );

  test("a follower on the leader's detour is not flagged off-route", () async {
    await controller.recordLocalLocation(_sample(latitude: 51, at: now));
    now = now.add(const Duration(seconds: 5));
    await controller.recordLocalLocation(_sample(latitude: 52, at: now));

    // A follower who took the same detour is judged against where the
    // leader actually went, not the GPX the leader has since abandoned.
    await controller.ingestRemoteEvent(
      _remoteLocationEvent(
        riderId: 'follower',
        role: RideRole.rider,
        latitude: 52,
        now: now,
      ),
    );

    expect(
      controller.alertFor('follower')?.assessment.state,
      RouteTrackingState.onRoute,
    );
  });

  test(
    'a follower who genuinely separates from the leader is still flagged',
    () async {
      await controller.recordLocalLocation(_sample(latitude: 51, at: now));
      now = now.add(const Duration(seconds: 5));
      await controller.recordLocalLocation(_sample(latitude: 51, at: now));

      await controller.ingestRemoteEvent(
        _remoteLocationEvent(
          riderId: 'stray',
          role: RideRole.rider,
          latitude: 53,
          now: now,
        ),
      );

      expect(
        controller.alertFor('stray')?.assessment.state,
        RouteTrackingState.offRoute,
      );
    },
  );

  test('unavailable Waze adapter remains explicit and is never fetched', () {
    final provider = controller.externalProviders.single;

    expect(provider, isA<WazeReadHazardProvider>());
    expect(provider.status.state, ExternalHazardProviderState.unavailable);
    expect(provider.status.canFetch, isFalse);
  });
}

SituationalAwarenessController _controller({
  required InMemoryEventStore store,
  required DateTime Function() clock,
  required String Function() idFactory,
}) => SituationalAwarenessController(
  store,
  _session,
  route: const [
    GeoPoint(latitude: 51, longitude: -1),
    GeoPoint(latitude: 51, longitude: -0.99),
  ],
  externalProviders: const [WazeReadHazardProvider()],
  clock: clock,
  idFactory: idFactory,
  routeConfig: const RouteDeviationConfig(samplesToConfirmOffRoute: 1),
);

final _session = RideSession(
  rideId: 'ride',
  rideCode: 'ABC123',
  inviteSecret: 'shared-secret',
  joinToken: 'test-join-token-0123456789',
  localRiderId: 'local-rider',
  displayName: 'Oliver',
  role: RideRole.lead,
  joinedAt: DateTime.utc(2026, 7, 16),
);

LocationSample _sample({required double latitude, required DateTime at}) =>
    LocationSample(
      position: GeoPoint(latitude: latitude, longitude: -0.995),
      recordedAt: at,
      accuracyMeters: 5,
    );

RideEvent _remoteLocationEvent({
  required String riderId,
  required RideRole role,
  required double latitude,
  required DateTime now,
}) {
  final factory = SituationEventFactory(
    session: _session,
    clock: () => now,
    idFactory: () => '$riderId-event',
  );
  final location = RiderLocation(
    riderId: riderId,
    displayName: riderId,
    role: role,
    sample: _sample(latitude: latitude, at: now),
    receivedAt: now,
  );
  return factory.create(
    type: RideEventType.riderLocationUpdated,
    payload: {'location': location.toJson()},
  );
}
