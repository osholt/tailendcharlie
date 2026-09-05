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
import 'package:ride_relay/services/road_jurisdiction.dart';
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
    'stored situational events are projected into the shared journal',
    () async {
      final stored = <RideEvent>[];
      final projecting = SituationalAwarenessController(
        store,
        _session,
        route: const [
          GeoPoint(latitude: 51, longitude: -1),
          GeoPoint(latitude: 51, longitude: -0.99),
        ],
        clock: () => now,
        idFactory: () => 'projected-${nextId++}',
        routeConfig: const RouteDeviationConfig(samplesToConfirmOffRoute: 1),
        onEventStored: stored.add,
      );
      addTearDown(projecting.dispose);
      await projecting.initialize();

      await projecting.recordLocalLocation(_sample(latitude: 51.002, at: now));

      expect(
        stored.map((event) => event.type),
        containsAll([
          RideEventType.riderLocationUpdated,
          RideEventType.routeDeviationChanged,
        ]),
      );
    },
  );

  test('the leader keeps their whole trail across a long ride', () async {
    final events = <RideEvent>[];
    for (var index = 0; index < 1200; index += 1) {
      final recordedAt = now.add(Duration(seconds: index));
      final factory = SituationEventFactory(
        session: _session,
        clock: () => recordedAt,
        idFactory: () => 'leader-$index',
      );
      final location = RiderLocation(
        riderId: _session.localRiderId,
        displayName: _session.displayName,
        role: RideRole.lead,
        sample: LocationSample(
          position: GeoPoint(latitude: 51 + index * 0.00001, longitude: -0.995),
          recordedAt: recordedAt,
          accuracyMeters: 5,
        ),
        receivedAt: recordedAt,
      );
      events.add(
        factory.create(
          type: RideEventType.riderLocationUpdated,
          payload: {'location': location.toJson()},
        ),
      );
    }
    final longRide = _controller(
      store: store,
      clock: () => now.add(const Duration(hours: 2)),
      idFactory: () => 'unused',
    );
    addTearDown(longRide.dispose);

    await longRide.initialize(restoredEvents: events);

    // This test previously asserted the opposite - that the trail was truncated
    // to LeaderTrackExemption.defaultRecentPointLimit (600). That bound cost a
    // tester the tail of a 6 h 4 m, 112 mile ride: at these rates 600 points is
    // the last 40 minutes, and everything earlier was deleted from memory, so it
    // could never be drawn, exported or recapped again.
    //
    // The performance property #165 needed is that no *per-update* work grows
    // with the ride, and that is now held by two things instead: the projection
    // is cached rather than rebuilt per read, and the follow-corridor check is
    // handed only the recent window. Neither requires throwing history away.
    expect(longRide.leaderTrail, hasLength(1200));
    expect(
      longRide.leaderTrail.first.latitude,
      closeTo(51, 1e-9),
      reason: 'the earliest point of the ride must survive',
    );
    expect(longRide.leaderTrail.last.latitude, closeTo(51.01199, 1e-9));
  });

  test(
    'the cached trail projection stays consistent as points arrive',
    () async {
      // The cache is what makes retaining the whole trail affordable, so a stale
      // cache would be a silently wrong trail rather than a slow one.
      var nextId = 0;
      final controller = _controller(
        store: InMemoryEventStore(),
        clock: () => now,
        idFactory: () => 'cached-${nextId++}',
      );
      addTearDown(controller.dispose);
      await controller.initialize(restoredEvents: const []);

      expect(controller.leaderTrail, isEmpty);

      for (var index = 0; index < 3; index += 1) {
        await controller.recordLocalLocation(
          LocationSample(
            position: GeoPoint(latitude: 51 + index * 0.001, longitude: -0.995),
            recordedAt: now.add(Duration(seconds: index)),
            accuracyMeters: 5,
          ),
        );
        expect(
          controller.leaderTrail,
          hasLength(index + 1),
          reason: 'the projection must reflect every recorded point',
        );
        expect(controller.leaderTrailSamples, hasLength(index + 1));
      }
      expect(controller.leaderTrail.last.latitude, closeTo(51.002, 1e-9));
    },
  );

  test(
    // The rule, decided for #300: a rider is visible to the group from the
    // moment they join, and the channel that carries that is presence — see
    // `pre_start_visibility_test.dart`. The durable journal is history, and
    // history starts at Start ride. This test used to be named "pre-start
    // location fixes are neither persisted nor displayed", which described
    // both halves as one policy; only the persistence half was ever this
    // controller's to enforce, and only that half survives the decision.
    'the durable journal records no fixes before the ride starts',
    () async {
      final waiting = SituationalAwarenessController(
        store,
        _session,
        route: const [
          GeoPoint(latitude: 51, longitude: -1),
          GeoPoint(latitude: 51, longitude: -0.99),
        ],
        rideStarted: false,
        rideStartedAt: null,
        clock: () => now,
        idFactory: () => 'waiting-${nextId++}',
      );
      await waiting.initialize();

      await waiting.recordLocalLocation(_sample(latitude: 51, at: now));
      await waiting.ingestRemoteEvent(
        _remoteLocationEvent(
          riderId: 'early-rider',
          role: RideRole.rider,
          latitude: 51,
          now: now,
        ),
      );

      expect(
        waiting.riderLocations,
        isEmpty,
        reason:
            'the journal projection is history, and history starts at '
            'Start ride; visibility before then comes from presence',
      );
      final stored = await store.eventsForRide(_session.rideId);
      expect(
        stored,
        hasLength(1),
        reason:
            'this device authored nothing — the one row is the remote '
            'peer\'s own event, kept as received',
      );
      expect(stored.single.id, 'early-rider-event');
      waiting.dispose();
    },
  );

  test(
    'activity replay rejects fixes recorded before the start anchor',
    () async {
      final startedAt = now.add(const Duration(minutes: 1));
      await store.append(
        _remoteLocationEvent(
          riderId: 'early-rider',
          role: RideRole.rider,
          latitude: 51,
          now: now,
        ),
      );
      await store.append(
        _remoteLocationEvent(
          riderId: 'late-rider',
          role: RideRole.rider,
          latitude: 51,
          now: startedAt,
        ),
      );
      final started = SituationalAwarenessController(
        store,
        _session,
        route: const [
          GeoPoint(latitude: 51, longitude: -1),
          GeoPoint(latitude: 51, longitude: -0.99),
        ],
        rideStarted: true,
        rideStartedAt: startedAt,
        clock: () => startedAt,
        idFactory: () => 'started-${nextId++}',
      );

      await started.initialize();

      expect(started.riderLocations.map((location) => location.riderId), [
        'late-rider',
      ]);
      started.dispose();
    },
  );

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

  test('riders can report enforcement sightings to the group', () async {
    for (final type in [HazardType.policeActivity, HazardType.speedCamera]) {
      final report = await controller.reportHazard(
        type: type,
        severity: HazardSeverity.serious,
        position: const GeoPoint(latitude: 51, longitude: -1),
      );

      expect(report, isNotNull);
      expect(report!.type, type);
      expect(report.source, HazardSource.rider);
    }

    expect(controller.activeHazards, hasLength(2));
    expect(await store.eventsForRide(_session.rideId), hasLength(2));
  });

  test('France disables enforcement alerts but keeps road hazards', () async {
    final frenchRules = SituationalAwarenessController(
      store,
      _session,
      route: const [],
      roadJurisdictions: _franceCatalogue,
      clock: () => now,
      idFactory: () => 'france-${nextId++}',
    );
    addTearDown(frenchRules.dispose);
    await frenchRules.initialize();
    const paris = GeoPoint(latitude: 48.8566, longitude: 2.3522);

    for (final type in [HazardType.policeActivity, HazardType.speedCamera]) {
      await expectLater(
        frenchRules.reportHazard(
          type: type,
          severity: HazardSeverity.serious,
          position: paris,
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('disabled in France'),
          ),
        ),
      );
    }

    final roadHazard = await frenchRules.reportHazard(
      type: HazardType.debris,
      severity: HazardSeverity.caution,
      position: paris,
    );
    expect(roadHazard, isNotNull);
    expect(frenchRules.activeHazards.single.type, HazardType.debris);
  });

  test('French enforcement events stay stored but are not presented', () async {
    const paris = GeoPoint(latitude: 48.8566, longitude: 2.3522);
    await controller.reportHazard(
      type: HazardType.speedCamera,
      severity: HazardSeverity.serious,
      position: paris,
    );

    final filtered = SituationalAwarenessController(
      store,
      _session,
      route: const [],
      roadJurisdictions: _franceCatalogue,
      clock: () => now,
      idFactory: () => 'filtered-${nextId++}',
    );
    addTearDown(filtered.dispose);
    await filtered.initialize();

    expect(await store.eventsForRide(_session.rideId), isNotEmpty);
    expect(filtered.activeHazards, isEmpty);
  });

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

  // This test previously asserted the opposite: that a leader is *never*
  // flagged off route once their own trail exists. That was wrong, and it is why
  // #102's rerouting never fired for a leader in the field. The leader's own
  // trail was included in the segments the leader was compared against, and a
  // leader is always at the end of their own trail, so the geometry answered
  // "on route" from anywhere - Kingswood to Chippenham, 27 July 2026:
  //
  //   "There was no rerouting navigation when I went off course."
  //
  // A leader who leaves the plan has left the plan. Followers are still judged
  // against where the leader actually went - the test below this one - because
  // that is what the leader-follow exemption is for. The leader is judged
  // against the plan, because nothing else can tell them they have left it.
  test('the leader is flagged off-route against the planned route', () async {
    await controller.recordLocalLocation(_sample(latitude: 51, at: now));
    expect(
      controller.alertFor(_session.localRiderId)?.assessment.state,
      RouteTrackingState.onRoute,
    );

    now = now.add(const Duration(seconds: 5));
    // The leader detours far from the planned route - e.g. a road closure.
    await controller.recordLocalLocation(_sample(latitude: 52, at: now));

    expect(
      controller.alertFor(_session.localRiderId)?.assessment.state,
      RouteTrackingState.offRoute,
    );
    expect(controller.leaderTrail, hasLength(2));
  });

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
    'a follower on the leader\'s detour emits no off-course deviation event',
    () async {
      // This device is a follower, not the leader, so the write-time exemption
      // is the only thing standing between it and a relayed off-route alert
      // about itself. Nothing may be appended that tells the rest of the group
      // this rider is lost.
      final follower = SituationalAwarenessController(
        store,
        _session.copyWith(role: RideRole.rider),
        route: const [
          GeoPoint(latitude: 51, longitude: -1),
          GeoPoint(latitude: 51, longitude: -0.99),
        ],
        clock: () => now,
        idFactory: () => 'follower-${nextId++}',
        routeConfig: const RouteDeviationConfig(samplesToConfirmOffRoute: 1),
      );
      addTearDown(follower.dispose);
      await follower.initialize();

      // The leader abandons the GPX and rides a degree north.
      await follower.ingestRemoteEvent(
        _remoteLocationEvent(
          riderId: 'leader',
          role: RideRole.lead,
          latitude: 51,
          now: now,
        ),
      );
      now = now.add(const Duration(seconds: 5));
      await follower.ingestRemoteEvent(
        _remoteLocationEvent(
          riderId: 'leader',
          role: RideRole.lead,
          latitude: 52,
          now: now,
        ),
      );

      // This rider follows them there.
      now = now.add(const Duration(seconds: 5));
      await follower.recordLocalLocation(_sample(latitude: 52, at: now));

      expect(follower.isFollowingLeaderTrack(_session.localRiderId), isTrue);
      expect(
        follower.alertFor(_session.localRiderId)?.assessment.state,
        RouteTrackingState.onRoute,
      );
      final deviations = (await store.eventsForRide(_session.rideId))
          .where((event) => event.type == RideEventType.routeDeviationChanged)
          .map(
            (event) => RiderRouteAlert.fromJson(
              Map<String, Object?>.from(event.payload['alert']! as Map),
            ),
          );
      expect(
        deviations.map((alert) => alert.assessment.state),
        isNot(contains(RouteTrackingState.offRoute)),
      );
    },
  );

  test("another device's off-course alert is ignored for a rider following the "
      'leader', () async {
    await controller.recordLocalLocation(_sample(latitude: 51, at: now));
    now = now.add(const Duration(seconds: 5));
    // The leader abandons the GPX.
    await controller.recordLocalLocation(_sample(latitude: 52, at: now));
    await controller.ingestRemoteEvent(
      _remoteLocationEvent(
        riderId: 'follower',
        role: RideRole.rider,
        latitude: 52,
        now: now,
      ),
    );
    expect(controller.isFollowingLeaderTrack('follower'), isTrue);

    // A device that had not yet seen the leader leave the GPX relays an
    // off-route alert for that follower. It must not surface anywhere.
    now = now.add(const Duration(seconds: 5));
    await controller.ingestRemoteEvent(
      _remoteDeviationEvent(riderId: 'follower', now: now),
    );

    expect(
      controller.alertFor('follower')?.assessment.state,
      RouteTrackingState.onRoute,
    );
    expect(
      controller.alertFor('follower')?.assessment.alertLevel,
      RouteAlertLevel.none,
    );
    expect(
      controller.routeAlerts.map((alert) => alert.riderId),
      isNot(contains('follower')),
    );
  });

  test('a relayed off-course alert still surfaces for a rider who is not '
      'following the leader', () async {
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
    expect(controller.isFollowingLeaderTrack('stray'), isFalse);

    now = now.add(const Duration(seconds: 5));
    await controller.ingestRemoteEvent(
      _remoteDeviationEvent(riderId: 'stray', now: now),
    );

    expect(
      controller.alertFor('stray')?.assessment.state,
      RouteTrackingState.offRoute,
    );
    expect(
      controller.routeAlerts.map((alert) => alert.riderId),
      contains('stray'),
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

  test(
    'refreshing the same provider incident does not invent confirmations',
    () async {
      final provider = _RefreshingTrafficProvider(now);
      final live = SituationalAwarenessController(
        store,
        _session,
        route: const [
          GeoPoint(latitude: 51, longitude: -1),
          GeoPoint(latitude: 51, longitude: -0.99),
        ],
        externalProviders: [provider],
        clock: () => now,
        idFactory: () => 'external-${nextId++}',
      );
      await live.initialize();

      await live.refreshExternalHazards();
      await live.refreshExternalHazards();

      expect(live.activeHazards, hasLength(1));
      expect(live.activeHazards.single.id, 'tomtom-incident');
      expect(live.activeHazards.single.confirmations, 4);
      live.dispose();
    },
  );

  test('unavailable Waze adapter remains explicit and is never fetched', () {
    final provider = controller.externalProviders.single;

    expect(provider, isA<WazeReadHazardProvider>());
    expect(provider.status.state, ExternalHazardProviderState.unavailable);
    expect(provider.status.canFetch, isFalse);
  });
}

class _RefreshingTrafficProvider implements ExternalHazardProvider {
  _RefreshingTrafficProvider(this.now);

  final DateTime now;
  var fetchCount = 0;

  @override
  String get displayName => 'Live traffic';

  @override
  String get id => 'tomtom-traffic';

  @override
  ExternalHazardProviderStatus get status => const ExternalHazardProviderStatus(
    state: ExternalHazardProviderState.configured,
    message: 'Configured',
  );

  @override
  Future<ExternalHazardFetchResult> fetch(ExternalHazardQuery query) async {
    fetchCount += 1;
    return ExternalHazardFetchResult(
      status: ExternalHazardProviderStatus(
        state: ExternalHazardProviderState.ready,
        message: 'Ready',
        lastUpdatedAt: now.add(Duration(minutes: fetchCount)),
      ),
      hazards: [
        HazardReport(
          id: 'tomtom-incident',
          rideId: query.rideId,
          type: HazardType.roadworks,
          severity: HazardSeverity.serious,
          position: const GeoPoint(latitude: 51, longitude: -0.995),
          reportedAt: now,
          updatedAt: now.add(Duration(minutes: fetchCount)),
          expiresAt: now.add(const Duration(hours: 1)),
          reporterId: id,
          source: HazardSource.externalProvider,
          providerId: id,
          confirmations: 4,
        ),
      ],
    );
  }
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

final _franceCatalogue = RoadJurisdictionCatalogue.parse('''
{
  "type":"FeatureCollection",
  "features":[{
    "type":"Feature",
    "properties":{
      "countryCode":"FR",
      "name":"France",
      "drivingSide":"right",
      "distanceUnit":"kilometres"
    },
    "geometry":{
      "type":"Polygon",
      "coordinates":[[[1,41],[10,41],[10,52],[1,52],[1,41]]]
    }
  }]
}
''');

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

/// A deviation alert as another device would have relayed it: that device
/// compared the rider against the planned GPX only.
RideEvent _remoteDeviationEvent({
  required String riderId,
  required DateTime now,
}) {
  final factory = SituationEventFactory(
    session: _session,
    clock: () => now,
    idFactory: () => '$riderId-deviation',
  );
  final alert = RiderRouteAlert(
    riderId: riderId,
    displayName: riderId,
    assessment: RouteDeviationAssessment(
      state: RouteTrackingState.offRoute,
      alertLevel: RouteAlertLevel.urgent,
      audience: RouteAlertAudience.coordinators,
      evaluatedAt: now,
      message: 'Rider is confirmed off route.',
      distanceFromRouteMeters: 111000,
      offRouteSince: now,
    ),
  );
  return factory.create(
    type: RideEventType.routeDeviationChanged,
    payload: {'alert': alert.toJson()},
  );
}
