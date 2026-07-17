import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/ride_controller.dart';
import 'package:ride_relay/data/in_memory_event_store.dart';
import 'package:ride_relay/data/in_memory_session_store.dart';
import 'package:ride_relay/domain/quick_message.dart';
import 'package:ride_relay/domain/marker_assistance.dart';
import 'package:ride_relay/domain/geo_point.dart';
import 'package:ride_relay/domain/ride_event.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/ride_session.dart';
import 'package:ride_relay/domain/rider_location.dart';
import 'package:ride_relay/services/nearby_bridge.dart';
import 'package:ride_relay/services/situation_event_factory.dart';

void main() {
  late InMemoryEventStore eventStore;
  late InMemorySessionStore sessionStore;
  late RideController controller;
  late int id;

  setUp(() async {
    eventStore = InMemoryEventStore();
    sessionStore = InMemorySessionStore();
    id = 0;
    controller = RideController(
      eventStore,
      sessionStore,
      const _FakeNearbyBridge(),
      clock: () => DateTime.utc(2026, 7, 16, 12),
      idFactory: () => 'id-${id++}',
      random: Random(42),
    );
    await controller.initialize();
  });

  tearDown(() => controller.dispose());

  test('new ride is persisted with lead role and a signed event', () async {
    await controller.createRide('Oliver');

    expect(controller.session?.role, RideRole.lead);
    expect(controller.session?.displayName, 'Oliver');
    expect(controller.session?.rideCode, hasLength(6));
    expect(controller.events, hasLength(1));
    expect(controller.events.single.type, RideEventType.rideCreated);
    expect(controller.events.single.signature, hasLength(64));

    final restored = await sessionStore.load();
    expect(restored?.rideId, controller.session?.rideId);
  });

  test('simulation ride is explicitly tagged and restartable', () async {
    await controller.createSimulationRide();

    final firstRideId = controller.session!.rideId;
    expect(controller.session?.isSimulation, isTrue);
    expect(controller.session?.displayName, 'Demo Lead');
    expect(controller.events.single.payload['simulation'], isTrue);

    await controller.restartSimulationRide();

    expect(controller.session?.isSimulation, isTrue);
    expect(controller.session?.rideId, isNot(firstRideId));
    expect(await eventStore.eventsForRide(firstRideId), isEmpty);
  });

  test('invalid join code is rejected without creating a session', () async {
    await controller.joinRide('123', 'Oliver');

    expect(controller.hasActiveRide, isFalse);
    expect(controller.errorMessage, contains('complete private invite'));
  });

  test(
    'ride code alone is rejected because it cannot authenticate relay',
    () async {
      await controller.joinRide('ABC234', 'Oliver');

      expect(controller.hasActiveRide, isFalse);
      expect(controller.errorMessage, contains('code alone'));
    },
  );

  test('private invite joins the leader ride with its relay secret', () async {
    await controller.createRide('Lead');
    final leaderSession = controller.session!;
    final invitation = controller.inviteText;
    expect(controller.inviteUri.queryParameters['ride'], leaderSession.rideId);

    final follower = RideController(
      InMemoryEventStore(),
      InMemorySessionStore(),
      const _FakeNearbyBridge(),
      clock: () => DateTime.utc(2026, 7, 16, 12),
      idFactory: () => 'follower-id',
      random: Random(7),
    );
    await follower.initialize();
    await follower.joinRide(invitation, 'Follower');

    expect(follower.session?.rideId, leaderSession.rideId);
    expect(follower.session?.rideCode, leaderSession.rideCode);
    expect(follower.session?.inviteSecret, leaderSession.inviteSecret);
    expect(follower.session?.role, RideRole.rider);
    expect(
      SituationEventFactory.verify(
        follower.events.single,
        leaderSession.inviteSecret,
      ),
      isTrue,
    );
    follower.dispose();
  });

  test(
    'invalid private invite never falls back to code-only joining',
    () async {
      await controller.joinRide(
        'riderelay://join?ride=ride-1&code=ABC234&secret=short',
        'Oliver',
      );

      expect(controller.hasActiveRide, isFalse);
      expect(controller.errorMessage, contains('private invite'));
    },
  );

  test('quick messages are durable, prioritised events', () async {
    await controller.createRide('Oliver');
    await controller.sendQuickMessage(QuickMessage.emergencyStop);

    final pending = await eventStore.pendingEvents(controller.session!.rideId);
    final message = pending.last;
    expect(message.type, RideEventType.statusMessage);
    expect(message.priority, EventPriority.critical);
    expect(message.payload['message'], 'emergencyStop');
  });

  test('marker counts each rider once', () async {
    await controller.createRide('Oliver');
    await controller.startMarker();
    await controller.recordMarkerPass('rider-a');
    await controller.recordMarkerPass('rider-a');
    await controller.recordMarkerPass('rider-b');

    expect(controller.markerPassCount, 2);
    expect(
      controller.events.where(
        (event) => event.type == RideEventType.markerPass,
      ),
      hasLength(2),
    );
  });

  test('marker uniqueness is scoped to each marker session', () async {
    await controller.createRide('Oliver');
    await controller.startMarker();
    await controller.recordMarkerPass('rider-a');
    await controller.endMarker();
    await controller.startMarker();
    await controller.recordMarkerPass('rider-a');

    expect(controller.markerPassCount, 1);
    expect(controller.markingSummary.sessions, hasLength(2));
    expect(
      controller.events.where(
        (event) => event.type == RideEventType.markerPass,
      ),
      hasLength(2),
    );
  });

  test('restoring an active marker preserves the previous lead role', () async {
    await controller.createRide('Oliver');
    await controller.startMarker();

    final restored = RideController(
      eventStore,
      sessionStore,
      const _FakeNearbyBridge(),
      clock: () => DateTime.utc(2026, 7, 16, 12),
      idFactory: () => 'restored-id',
      random: Random(9),
    );
    await restored.initialize();
    expect(restored.markerActive, isTrue);

    await restored.endMarker();

    expect(restored.session?.role, RideRole.lead);
    restored.dispose();
  });

  test(
    'another device marker session does not change local marker state',
    () async {
      await controller.createRide('Oliver');
      await eventStore.append(
        RideEvent(
          id: 'remote-marker',
          rideId: controller.session!.rideId,
          deviceId: 'remote-device',
          type: RideEventType.markerStarted,
          priority: EventPriority.important,
          createdAt: DateTime.utc(2026, 7, 16, 12),
          payload: const {
            'markerSessionId': 'remote-session',
            'mode': 'manual',
          },
          signature: 'relay-test',
        ),
      );
      await controller.reloadEvents();

      expect(controller.markerActive, isFalse);
      expect(controller.markingSummary.sessions, isEmpty);
    },
  );

  test(
    'authenticated TEC evidence is reflected in marker statistics',
    () async {
      await controller.createRide('Oliver');
      await controller.startMarker();
      await _appendLocationEvidence(
        eventStore: eventStore,
        controller: controller,
        riderId: 'tec',
        role: RideRole.tailEndCharlie,
        eventId: 'location-event',
      );
      await controller.recordMarkerPass(
        'tec',
        evidenceEventId: 'location-event',
        riderRole: RideRole.tailEndCharlie,
        observedAt: DateTime.utc(2026, 7, 16, 12),
      );

      expect(controller.verifiedMarkerPassCount, 1);
      expect(controller.tecPassedCurrentMarker, isTrue);
    },
  );

  test('ride-ended event persists the marking summary', () async {
    await controller.createRide('Oliver');
    final rideId = controller.session!.rideId;
    await controller.startMarker();
    await _appendLocationEvidence(
      eventStore: eventStore,
      controller: controller,
      riderId: 'rider-a',
      role: RideRole.rider,
      eventId: 'location-event',
    );
    await controller.recordMarkerPass(
      'rider-a',
      evidenceEventId: 'location-event',
      riderRole: RideRole.rider,
    );

    await controller.endRide();

    final events = await eventStore.eventsForRide(rideId);
    final ended = events.singleWhere(
      (event) => event.type == RideEventType.rideEnded,
    );
    final summary = RideMarkingSummary.fromJson(
      Map<String, Object?>.from(ended.payload['markingSummary']! as Map),
    );
    expect(summary.sessions, hasLength(1));
    expect(summary.sessions.single.completed, isTrue);
    expect(summary.verifiedPassCount, 1);
    expect(controller.hasActiveRide, isTrue);
    expect(controller.rideEnded, isTrue);
    expect((await sessionStore.load())?.rideId, rideId);
  });

  test('ended ride is removed only after explicit clearing', () async {
    await controller.createRide('Oliver');
    final rideId = controller.session!.rideId;
    await controller.endRide();

    await controller.clearEndedRide();

    expect(controller.hasActiveRide, isFalse);
    expect(await sessionStore.load(), isNull);
    expect(await eventStore.eventsForRide(rideId), isEmpty);
  });

  test('leaving an active ride clears its local session and events', () async {
    await controller.createRide('Oliver');
    final rideId = controller.session!.rideId;

    await controller.leaveRide();

    expect(controller.hasActiveRide, isFalse);
    expect(await sessionStore.load(), isNull);
    expect(await eventStore.eventsForRide(rideId), isEmpty);
  });
}

Future<void> _appendLocationEvidence({
  required InMemoryEventStore eventStore,
  required RideController controller,
  required String riderId,
  required RideRole role,
  required String eventId,
}) async {
  final session = controller.session!;
  final now = DateTime.utc(2026, 7, 16, 12);
  final remoteSession = RideSession(
    rideId: session.rideId,
    rideCode: session.rideCode,
    inviteSecret: session.inviteSecret,
    localRiderId: riderId,
    displayName: riderId,
    role: role,
    joinedAt: now,
  );
  final location = RiderLocation(
    riderId: riderId,
    displayName: riderId,
    role: role,
    sample: LocationSample(
      position: const GeoPoint(latitude: 51, longitude: -1),
      recordedAt: now,
      accuracyMeters: 4,
    ),
    receivedAt: now,
  );
  final event =
      SituationEventFactory(
        session: remoteSession,
        clock: () => now,
        idFactory: () => eventId,
      ).create(
        type: RideEventType.riderLocationUpdated,
        payload: {'location': location.toJson()},
      );
  await eventStore.append(event);
  await controller.reloadEvents();
}

class _FakeNearbyBridge extends NearbyBridge {
  const _FakeNearbyBridge();

  @override
  Future<NearbyCapabilities> capabilities() async => const NearbyCapabilities(
    platform: 'test',
    nativeBridgeReady: true,
    nearbyApiLinked: false,
    status: 'phase0',
  );
}
