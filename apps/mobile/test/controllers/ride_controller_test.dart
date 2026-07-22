import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/ride_controller.dart';
import 'package:ride_relay/data/in_memory_event_store.dart';
import 'package:ride_relay/data/in_memory_session_store.dart';
import 'package:ride_relay/domain/quick_message.dart';
import 'package:ride_relay/domain/marker_assistance.dart';
import 'package:ride_relay/domain/geo_point.dart';
import 'package:ride_relay/domain/imported_route.dart' as route_domain;
import 'package:ride_relay/domain/ride_event.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/ride_session.dart';
import 'package:ride_relay/internet/internet_relay_client.dart';
import 'package:ride_relay/domain/rider_location.dart';
import 'package:ride_relay/services/nearby_bridge.dart';
import 'package:ride_relay/services/situation_event_factory.dart';

void main() {
  late InMemoryEventStore eventStore;
  late InMemorySessionStore sessionStore;
  late RideController controller;
  late _InMemoryRideCodeDirectory rideCodes;
  late int id;

  setUp(() async {
    eventStore = InMemoryEventStore();
    sessionStore = InMemorySessionStore();
    rideCodes = _InMemoryRideCodeDirectory();
    id = 0;
    controller = RideController(
      eventStore,
      sessionStore,
      const _FakeNearbyBridge(),
      clock: () => DateTime.utc(2026, 7, 16, 12),
      idFactory: () => 'id-${(id++).toString().padLeft(3, '0')}',
      random: Random(42),
      rideCodeDirectory: rideCodes,
    );
    await controller.initialize();
  });

  tearDown(() => controller.dispose());

  test('new ride is persisted with lead role and a signed event', () async {
    await controller.createRide('Oliver');

    expect(controller.session?.role, RideRole.lead);
    expect(controller.session?.displayName, 'Oliver');
    expect(controller.session?.rideCode, matches(RegExp(r'^\d{6}$')));
    expect(controller.events, hasLength(1));
    expect(controller.events.single.type, RideEventType.rideCreated);
    expect(controller.events.single.signature, hasLength(64));
    expect(controller.rideStarted, isFalse);

    final restored = await sessionStore.load();
    expect(restored?.rideId, controller.session?.rideId);
  });

  test('leader start is signed, durable, idempotent and restored', () async {
    await controller.createRide('Oliver');

    await controller.startRide();
    await controller.startRide();

    final startEvents = controller.events
        .where((event) => event.type == RideEventType.rideStarted)
        .toList();
    expect(startEvents, hasLength(1));
    expect(
      startEvents.single.payload['leaderRiderId'],
      controller.session!.localRiderId,
    );
    expect(startEvents.single.signature, hasLength(64));
    expect(controller.rideStartedAt, DateTime.utc(2026, 7, 16, 12));

    final restored = RideController(
      eventStore,
      sessionStore,
      const _FakeNearbyBridge(),
      clock: () => DateTime.utc(2026, 7, 16, 13),
      idFactory: () => 'restored-start-id',
      random: Random(9),
      rideCodeDirectory: rideCodes,
    );
    await restored.initialize();
    expect(restored.rideStarted, isTrue);
    expect(restored.rideStartedAt, controller.rideStartedAt);
    restored.dispose();
  });

  test('leader route publish and clear are signed durable revisions', () async {
    await controller.createRide('Oliver');
    final route = route_domain.ImportedRoute(
      id: 'route-a',
      name: 'Coast route',
      importedAt: DateTime.utc(2026, 7, 16),
      sourceFileName: 'coast.gpx',
      paths: const [
        route_domain.RoutePath(
          kind: route_domain.RoutePathKind.track,
          points: [
            route_domain.GeoPoint(latitude: 51.4, longitude: -2.6),
            route_domain.GeoPoint(latitude: 51.5, longitude: -2.5),
          ],
        ),
      ],
      waypoints: const [],
    );

    await controller.publishRoute(route);

    expect(controller.authoritativeRoute?.name, 'Coast route');
    expect(controller.authoritativeRouteState.revisionNumber, 1);
    expect(controller.events.last.type, RideEventType.routeRevisionPublished);
    expect(controller.events.last.signature, hasLength(64));

    await controller.clearRoute();

    expect(controller.authoritativeRouteState.hasDecision, isTrue);
    expect(controller.authoritativeRoute, isNull);
    expect(controller.authoritativeRouteState.revisionNumber, 2);
    expect(controller.events.last.type, RideEventType.routeCleared);
  });

  test('a non-leader cannot publish or clear the group route', () async {
    await controller.createRide('Oliver');
    await controller.setRole(RideRole.rider);
    final route = route_domain.ImportedRoute(
      id: 'route-a',
      name: 'Wrong route',
      importedAt: DateTime.utc(2026, 7, 16),
      sourceFileName: 'wrong.gpx',
      paths: const [
        route_domain.RoutePath(
          kind: route_domain.RoutePathKind.track,
          points: [route_domain.GeoPoint(latitude: 51.4, longitude: -2.6)],
        ),
      ],
      waypoints: const [],
    );

    await controller.publishRoute(route);
    expect(controller.authoritativeRoute, isNull);
    expect(controller.errorMessage, contains('Only the ride leader'));

    controller.clearError();
    await controller.clearRoute();
    expect(controller.authoritativeRouteState.hasDecision, isFalse);
    expect(controller.errorMessage, contains('Only the ride leader'));
  });

  test('a non-leader cannot start the ride', () async {
    await controller.createRide('Oliver');
    await controller.setRole(RideRole.rider);

    await controller.startRide();

    expect(controller.rideStarted, isFalse);
    expect(controller.errorMessage, contains('Only the ride leader'));
    expect(
      controller.events.where(
        (event) => event.type == RideEventType.rideStarted,
      ),
      isEmpty,
    );
  });

  test(
    'offline leader handover and duplicate starts converge deterministically',
    () async {
      await controller.createRide('Oliver');
      final session = controller.session!;
      final followerSession = RideSession(
        rideId: session.rideId,
        rideCode: session.rideCode,
        inviteSecret: session.inviteSecret,
        joinToken: session.joinToken,
        localRiderId: 'follower',
        displayName: 'Alex',
        role: RideRole.rider,
        joinedAt: DateTime.utc(2026, 7, 16, 12, 1),
      );
      await eventStore.append(
        _signedEvent(
          session: followerSession,
          id: 'join-follower',
          type: RideEventType.riderJoined,
          createdAt: DateTime.utc(2026, 7, 16, 12, 1),
          payload: const {'displayName': 'Alex', 'role': 'rider'},
        ),
      );
      await eventStore.append(
        _signedEvent(
          session: followerSession,
          id: 'promote-follower',
          type: RideEventType.roleChanged,
          createdAt: DateTime.utc(2026, 7, 16, 12, 2),
          payload: const {'role': 'lead'},
        ),
      );
      for (final id in ['start-z', 'start-a']) {
        await eventStore.append(
          _signedEvent(
            session: followerSession,
            id: id,
            type: RideEventType.rideStarted,
            createdAt: DateTime.utc(2026, 7, 16, 12, 3),
            payload: const {
              'leaderRiderId': 'follower',
              'leaderDisplayName': 'Alex',
            },
          ),
        );
      }

      await controller.reloadEvents();

      expect(controller.rideStarted, isTrue);
      expect(controller.rideStartedAt, DateTime.utc(2026, 7, 16, 12, 3));
      expect(controller.participants, hasLength(2));
      expect(
        controller.participants
            .singleWhere((participant) => participant.riderId == 'follower')
            .role,
        RideRole.lead,
      );
    },
  );

  test('simulation ride is explicitly tagged and restartable', () async {
    await controller.createSimulationRide(riderCount: 30);

    final firstRideId = controller.session!.rideId;
    expect(controller.session?.isSimulation, isTrue);
    expect(controller.session?.simulationRiderCount, 30);
    expect(controller.session?.displayName, 'Demo Lead');
    expect(controller.events.first.payload['simulation'], isTrue);
    expect(controller.events.last.type, RideEventType.rideStarted);
    expect(controller.rideStarted, isTrue);

    await controller.restartSimulationRide(riderCount: 12);

    expect(controller.session?.isSimulation, isTrue);
    expect(controller.session?.simulationRiderCount, 12);
    expect(controller.session?.rideId, isNot(firstRideId));
    expect(await eventStore.eventsForRide(firstRideId), isEmpty);
  });

  test('invalid join code is rejected without creating a session', () async {
    await controller.joinRide('123', 'Oliver');

    expect(controller.hasActiveRide, isFalse);
    expect(controller.errorMessage, contains('six-digit'));
  });

  test('six-digit ride code resolves the leader ride credentials', () async {
    await controller.createRide('Lead');
    final leaderSession = controller.session!;
    await controller.publishRideCode();

    final follower = RideController(
      InMemoryEventStore(),
      InMemorySessionStore(),
      const _FakeNearbyBridge(),
      clock: () => DateTime.utc(2026, 7, 16, 12),
      idFactory: () => 'follower-id',
      random: Random(7),
      rideCodeDirectory: rideCodes,
    );
    await follower.initialize();
    await follower.joinRide(leaderSession.rideCode, 'Follower');

    expect(follower.session?.rideId, leaderSession.rideId);
    expect(follower.session?.inviteSecret, leaderSession.inviteSecret);
    follower.dispose();
  });

  test('ride code joins the leader ride with its relay secret', () async {
    await controller.createRide('Lead');
    final leaderSession = controller.session!;
    await controller.publishRideCode();

    final follower = RideController(
      InMemoryEventStore(),
      InMemorySessionStore(),
      const _FakeNearbyBridge(),
      clock: () => DateTime.utc(2026, 7, 16, 12),
      idFactory: () => 'follower-id',
      random: Random(7),
      rideCodeDirectory: rideCodes,
    );
    await follower.initialize();
    await follower.joinRide(leaderSession.rideCode, 'Follower');

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
    'joining rider receives the ride join token for future re-sharing',
    () async {
      await controller.createRide('Lead');
      final leaderSession = controller.session!;
      await controller.publishRideCode();

      final follower = RideController(
        InMemoryEventStore(),
        InMemorySessionStore(),
        const _FakeNearbyBridge(),
        clock: () => DateTime.utc(2026, 7, 16, 12),
        idFactory: () => 'follower-id',
        random: Random(7),
        rideCodeDirectory: rideCodes,
      );
      await follower.initialize();
      await follower.joinRide(leaderSession.rideCode, 'Follower');

      expect(follower.session?.joinToken, leaderSession.joinToken);
      follower.dispose();
    },
  );

  test(
    'ride code share text carries the six digits and a paired invite',
    () async {
      await controller.createRide('Lead');
      final leaderSession = controller.session!;

      expect(
        controller.rideCodeShareText,
        contains('ride code ${leaderSession.rideCode} in the'),
      );
      expect(
        controller.rideCodeShareText,
        contains('${leaderSession.rideCode}#${leaderSession.joinToken}'),
      );
    },
  );

  test('non-numeric ride code is rejected before lookup', () async {
    await controller.joinRide('ABC234', 'Oliver');

    expect(controller.hasActiveRide, isFalse);
    expect(controller.errorMessage, contains('six-digit'));
  });

  test('quick messages are durable, prioritised directed events', () async {
    await controller.createRide('Oliver');
    await controller.sendQuickMessage(
      QuickMessage.emergencyStop,
      recipientRiderIds: const ['lead', 'tec', 'lead'],
    );

    final pending = await eventStore.pendingEvents(controller.session!.rideId);
    final message = pending.last;
    expect(message.type, RideEventType.statusMessage);
    expect(message.priority, EventPriority.critical);
    expect(message.payload['message'], 'emergencyStop');
    expect(message.payload['recipientRiderIds'], const ['lead', 'tec']);
  });

  test(
    'leader can pause and resume the shared ride without stopping GPS',
    () async {
      await controller.createRide('Oliver');
      await controller.startRide();

      await controller.pauseRide();
      expect(controller.ridePaused, isTrue);
      expect(controller.events.last.type, RideEventType.ridePaused);

      await controller.resumeRide();
      expect(controller.ridePaused, isFalse);
      expect(controller.events.last.type, RideEventType.rideResumed);
    },
  );

  test('marker counts each rider once', () async {
    await controller.createRide('Oliver');
    await controller.startRide();
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
    await controller.startRide();
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
    await controller.startRide();
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
      await controller.startRide();
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
    await controller.startRide();
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

  test('expired ended ride data is deleted when the app is reopened', () async {
    var now = DateTime.utc(2026, 7, 16, 12);
    var seedId = 0;
    final seed = RideController(
      eventStore,
      sessionStore,
      const _FakeNearbyBridge(),
      clock: () => now,
      idFactory: () => 'retention-${seedId++}',
      random: Random(1),
      rideCodeDirectory: rideCodes,
    );
    await seed.initialize();
    await seed.createRide('Oliver');
    final rideId = seed.session!.rideId;
    await seed.endRide();
    seed.dispose();

    now = now
        .add(RideController.endedRideRecoveryWindow)
        .add(const Duration(seconds: 1));
    final reopened = RideController(
      eventStore,
      sessionStore,
      const _FakeNearbyBridge(),
      clock: () => now,
      idFactory: () => 'reopened-${seedId++}',
      random: Random(2),
      rideCodeDirectory: rideCodes,
    );
    await reopened.initialize();

    expect(reopened.hasActiveRide, isFalse);
    expect(await sessionStore.load(), isNull);
    expect(await eventStore.eventsForRide(rideId), isEmpty);
    reopened.dispose();
  });

  test(
    'leaving records a signed departure before clearing the session',
    () async {
      await controller.createRide('Oliver');
      final rideId = controller.session!.rideId;
      RideEvent? published;

      await controller.leaveRide(
        publishDeparture: (departure) async => published = departure,
      );

      expect(controller.hasActiveRide, isFalse);
      expect(await sessionStore.load(), isNull);
      final retained = await eventStore.eventsForRide(rideId);
      expect(retained.last.type, RideEventType.riderLeft);
      expect(retained.last.payload['riderId'], retained.last.deviceId);
      expect(published?.id, retained.last.id);
      expect(published?.signature, hasLength(64));
    },
  );

  test('explicit ICE share carries no recipient filter', () async {
    await controller.createRide('Oliver');
    await controller.shareEmergencyInfo(
      contactName: 'Sam',
      contactPhone: '+44 7700 900111',
      medicalNotes: 'Type 1 diabetic',
      recipientRiderIds: const [],
    );

    final shared = controller.events.singleWhere(
      (event) => event.type == RideEventType.iceInfoShared,
    );
    expect(shared.payload.containsKey('recipientRiderIds'), isFalse);
    expect(controller.sentIceShares.single.toWholeGroup, isTrue);
    expect(controller.sentIceShares.single.viewedAt, isNull);
  });

  test('default-share-with-leader carries a recipient filter', () async {
    await controller.createRide('Oliver');
    await controller.shareEmergencyInfo(
      contactName: 'Sam',
      contactPhone: '+44 7700 900111',
      medicalNotes: '',
      recipientRiderIds: const ['leader-device'],
    );

    final shared = controller.events.singleWhere(
      (event) => event.type == RideEventType.iceInfoShared,
    );
    expect(shared.payload['recipientRiderIds'], ['leader-device']);
    expect(controller.sentIceShares.single.toWholeGroup, isFalse);
  });

  test('received ICE shares include broadcasts and shares addressed to me, '
      'not shares addressed elsewhere', () async {
    await controller.createRide('Oliver');
    final rideId = controller.session!.rideId;
    final myId = controller.session!.localRiderId;

    await eventStore.append(
      RideEvent(
        id: 'broadcast-share',
        rideId: rideId,
        deviceId: 'remote-device-a',
        type: RideEventType.iceInfoShared,
        priority: EventPriority.critical,
        createdAt: DateTime.utc(2026, 7, 16, 12),
        payload: const {
          'contactName': 'Alex',
          'contactPhone': '+44 7700 900222',
          'medicalNotes': '',
          'sharedByDisplayName': 'Remote A',
        },
        signature: 'relay-test',
      ),
    );
    await eventStore.append(
      RideEvent(
        id: 'addressed-to-me',
        rideId: rideId,
        deviceId: 'remote-device-b',
        type: RideEventType.iceInfoShared,
        priority: EventPriority.critical,
        createdAt: DateTime.utc(2026, 7, 16, 12),
        payload: {
          'contactName': 'Jo',
          'contactPhone': '+44 7700 900333',
          'medicalNotes': '',
          'sharedByDisplayName': 'Remote B',
          'recipientRiderIds': [myId],
        },
        signature: 'relay-test',
      ),
    );
    await eventStore.append(
      RideEvent(
        id: 'addressed-elsewhere',
        rideId: rideId,
        deviceId: 'remote-device-c',
        type: RideEventType.iceInfoShared,
        priority: EventPriority.critical,
        createdAt: DateTime.utc(2026, 7, 16, 12),
        payload: const {
          'contactName': 'Chris',
          'contactPhone': '+44 7700 900444',
          'medicalNotes': '',
          'sharedByDisplayName': 'Remote C',
          'recipientRiderIds': ['someone-else'],
        },
        signature: 'relay-test',
      ),
    );
    await controller.reloadEvents();

    final receivedIds = controller.receivedIceShares
        .map((share) => share.eventId)
        .toSet();
    expect(receivedIds, {'broadcast-share', 'addressed-to-me'});
  });

  test('viewing a share records exactly one view event, however many times '
      "it's opened", () async {
    await controller.createRide('Oliver');
    final rideId = controller.session!.rideId;
    final myId = controller.session!.localRiderId;

    await eventStore.append(
      RideEvent(
        id: 'their-share',
        rideId: rideId,
        deviceId: 'remote-device',
        type: RideEventType.iceInfoShared,
        priority: EventPriority.critical,
        createdAt: DateTime.utc(2026, 7, 16, 12),
        payload: const {
          'contactName': 'Alex',
          'contactPhone': '+44 7700 900222',
          'medicalNotes': '',
          'sharedByDisplayName': 'Remote',
        },
        signature: 'relay-test',
      ),
    );
    await controller.reloadEvents();

    await controller.markIceInfoViewed('their-share');
    await controller.markIceInfoViewed('their-share');

    final views = controller.events.where(
      (event) => event.type == RideEventType.iceInfoViewed,
    );
    expect(views, hasLength(1));
    expect(views.single.deviceId, myId);
  });

  test("a received view event updates the sharer's own share with who saw it "
      'and when', () async {
    await controller.createRide('Oliver');
    final rideId = controller.session!.rideId;

    await controller.shareEmergencyInfo(
      contactName: 'Sam',
      contactPhone: '+44 7700 900111',
      medicalNotes: '',
      recipientRiderIds: const [],
    );
    final sharedEventId = controller.events
        .singleWhere((event) => event.type == RideEventType.iceInfoShared)
        .id;
    expect(controller.sentIceShares.single.viewedAt, isNull);

    await eventStore.append(
      RideEvent(
        id: 'their-view',
        rideId: rideId,
        deviceId: 'remote-device',
        type: RideEventType.iceInfoViewed,
        priority: EventPriority.routine,
        createdAt: DateTime.utc(2026, 7, 16, 13),
        payload: {'sharedEventId': sharedEventId},
        signature: 'relay-test',
      ),
    );
    await controller.reloadEvents();

    final sent = controller.sentIceShares.single;
    expect(sent.viewedAt, DateTime.utc(2026, 7, 16, 13));
    expect(sent.viewedByRiderId, 'remote-device');
  });

  test('ending the ride purges unused received ICE shares, keeps used and '
      'self-sent ones', () async {
    await controller.createRide('Oliver');
    final rideId = controller.session!.rideId;
    final myId = controller.session!.localRiderId;

    await eventStore.append(
      RideEvent(
        id: 'unused-share',
        rideId: rideId,
        deviceId: 'remote-device-a',
        type: RideEventType.iceInfoShared,
        priority: EventPriority.critical,
        createdAt: DateTime.utc(2026, 7, 16, 12),
        payload: const {
          'contactName': 'Alex',
          'contactPhone': '+44 7700 900222',
          'medicalNotes': '',
          'sharedByDisplayName': 'Remote A',
        },
        signature: 'relay-test',
      ),
    );
    await eventStore.append(
      RideEvent(
        id: 'used-share',
        rideId: rideId,
        deviceId: 'remote-device-b',
        type: RideEventType.iceInfoShared,
        priority: EventPriority.critical,
        createdAt: DateTime.utc(2026, 7, 16, 12),
        payload: {
          'contactName': 'Jo',
          'contactPhone': '+44 7700 900333',
          'medicalNotes': '',
          'sharedByDisplayName': 'Remote B',
          'recipientRiderIds': [myId],
        },
        signature: 'relay-test',
      ),
    );
    await controller.reloadEvents();
    controller.markIceShareUsed('used-share');

    await controller.shareEmergencyInfo(
      contactName: 'Own contact',
      contactPhone: '+44 7700 900555',
      medicalNotes: '',
      recipientRiderIds: const [],
    );
    final ownShareId = controller.events
        .singleWhere(
          (event) =>
              event.type == RideEventType.iceInfoShared &&
              event.deviceId == myId,
        )
        .id;

    await controller.endRide();

    final remainingIds = (await eventStore.eventsForRide(rideId))
        .where((event) => event.type == RideEventType.iceInfoShared)
        .map((event) => event.id)
        .toSet();
    expect(remainingIds, {'used-share', ownShareId});
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
    joinToken: session.joinToken,
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

RideEvent _signedEvent({
  required RideSession session,
  required String id,
  required RideEventType type,
  required DateTime createdAt,
  required Map<String, Object?> payload,
}) {
  final unsigned = RideEvent(
    id: id,
    rideId: session.rideId,
    deviceId: session.localRiderId,
    type: type,
    priority: EventPriority.important,
    createdAt: createdAt,
    payload: payload,
    signature: '',
  );
  return RideEvent(
    id: unsigned.id,
    rideId: unsigned.rideId,
    deviceId: unsigned.deviceId,
    type: unsigned.type,
    priority: unsigned.priority,
    createdAt: unsigned.createdAt,
    payload: unsigned.payload,
    signature: SituationEventFactory.sign(unsigned, session.inviteSecret),
  );
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

class _InMemoryRideCodeDirectory implements RideCodeDirectory {
  final _credentials = <String, RideCodeCredentials>{};

  @override
  Future<void> register(RideSession session) async {
    final existing = _credentials[session.rideCode];
    if (existing != null && existing.rideId != session.rideId) {
      throw const RideCodeDirectoryException(
        'Ride code is already in use.',
        codeConflict: true,
      );
    }
    _credentials[session.rideCode] = RideCodeCredentials(
      rideId: session.rideId,
      rideCode: session.rideCode,
      inviteSecret: session.inviteSecret,
      joinToken: session.joinToken,
    );
  }

  @override
  Future<RideCodeCredentials> resolve(
    String rideCode, {
    String? joinToken,
  }) async {
    final credentials = _credentials[rideCode];
    if (credentials == null) {
      throw const RideCodeDirectoryException('That ride code is not active.');
    }
    return credentials;
  }

  @override
  void close() {}
}
