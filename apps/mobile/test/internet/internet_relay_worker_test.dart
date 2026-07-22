import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/data/in_memory_event_store.dart';
import 'package:ride_relay/domain/ride_event.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/ride_session.dart';
import 'package:ride_relay/internet/internet_cursor_store.dart';
import 'package:ride_relay/internet/internet_relay_client.dart';
import 'package:ride_relay/internet/internet_relay_worker.dart';
import 'package:ride_relay/services/ride_event_authenticator.dart';

void main() {
  test(
    'uploads pending events, applies remote events, and persists cursor',
    () async {
      final eventStore = InMemoryEventStore();
      final cursorStore = InMemoryInternetCursorStore();
      await eventStore.append(_event(id: 'local'));
      final api = _FakeApi(
        results: [
          InternetSyncResult(
            cursor: 'cursor-1',
            acceptedEventIds: const {'local'},
            events: [_event(id: 'remote', deviceId: 'remote-device')],
          ),
          InternetSyncResult(
            cursor: 'cursor-2',
            acceptedEventIds: const {},
            events: [_event(id: 'remote', deviceId: 'remote-device')],
          ),
        ],
      );
      final worker = InternetRelayWorker(
        api: api,
        eventStore: eventStore,
        cursorStore: cursorStore,
        pollInterval: const Duration(days: 1),
        randomValue: () => 0.5,
      );
      final received = <RideEvent>[];
      final subscription = worker.receivedEvents.listen(received.add);
      final firstSuccess = worker.statuses.firstWhere(
        (status) => status.phase == InternetRelayPhase.synced,
      );

      await worker.start(_session);
      await firstSuccess.timeout(const Duration(seconds: 1));

      expect(api.uploads.single.map((event) => event.id), ['local']);
      expect(await eventStore.pendingEvents(_session.rideId), isEmpty);
      expect(
        (await eventStore.eventsForRide(_session.rideId)).map((e) => e.id),
        ['local', 'remote'],
      );
      expect(await cursorStore.load(_session.rideId), 'cursor-1');
      expect(received.map((event) => event.id), ['remote']);

      await worker.synchronizeNow();
      expect(received.map((event) => event.id), ['remote']);
      expect(await cursorStore.load(_session.rideId), 'cursor-2');

      await subscription.cancel();
      await worker.close();
    },
  );

  test('stays unconfigured without contacting the network', () async {
    final api = _FakeApi(
      configuration: const InternetRelayConfiguration(baseUri: null),
      results: const [],
    );
    final worker = InternetRelayWorker(
      api: api,
      eventStore: InMemoryEventStore(),
      cursorStore: InMemoryInternetCursorStore(),
    );

    await worker.start(_session);

    expect(worker.status.phase, InternetRelayPhase.unconfigured);
    expect(api.callCount, 0);
    await worker.close();
  });

  test(
    'rejects tampered downloaded events before mutating durable state',
    () async {
      final eventStore = InMemoryEventStore();
      final cursorStore = InMemoryInternetCursorStore();
      await eventStore.append(_event(id: 'local'));
      final valid = _event(id: 'tampered', deviceId: 'remote-device');
      final tampered = RideEvent(
        id: valid.id,
        rideId: valid.rideId,
        deviceId: valid.deviceId,
        type: valid.type,
        priority: valid.priority,
        createdAt: valid.createdAt,
        payload: const {'message': 'Forged'},
        signature: valid.signature,
      );
      final api = _FakeApi(
        results: [
          InternetSyncResult(
            cursor: 'must-not-save',
            acceptedEventIds: const {'local'},
            events: [tampered],
          ),
        ],
      );
      final worker = InternetRelayWorker(
        api: api,
        eventStore: eventStore,
        cursorStore: cursorStore,
        pollInterval: const Duration(days: 1),
      );
      final failure = worker.statuses.firstWhere(
        (status) => status.phase == InternetRelayPhase.failed,
      );

      await worker.start(_session);
      await failure.timeout(const Duration(seconds: 1));

      expect(
        (await eventStore.pendingEvents(_session.rideId)).single.id,
        'local',
      );
      expect(
        (await eventStore.eventsForRide(
          _session.rideId,
        )).map((event) => event.id),
        ['local'],
      );
      expect(await cursorStore.load(_session.rideId), isNull);
      await worker.close();
    },
  );

  test('uses bounded exponential backoff with jitter', () {
    const policy = InternetRetryPolicy(
      initialDelay: Duration(seconds: 2),
      maximumDelay: Duration(seconds: 10),
    );

    expect(policy.delayFor(1, randomValue: 0.5), const Duration(seconds: 2));
    expect(policy.delayFor(2, randomValue: 0.5), const Duration(seconds: 4));
    expect(policy.delayFor(20, randomValue: 0.5), const Duration(seconds: 10));
  });

  test('recovers automatically after a retryable network failure', () async {
    final api = _RecoveringApi();
    final worker = InternetRelayWorker(
      api: api,
      eventStore: InMemoryEventStore(),
      cursorStore: InMemoryInternetCursorStore(),
      retryPolicy: const InternetRetryPolicy(
        initialDelay: Duration(milliseconds: 1),
        maximumDelay: Duration(milliseconds: 1),
      ),
      pollInterval: const Duration(days: 1),
      randomValue: () => 0.5,
    );
    final recovered = worker.statuses.firstWhere(
      (status) => status.phase == InternetRelayPhase.synced,
    );

    await worker.start(_session);
    await recovered.timeout(const Duration(seconds: 1));

    expect(api.callCount, 2);
    await worker.close();
  });

  test('withholds capability-dependent events from a legacy relay', () async {
    final eventStore = InMemoryEventStore();
    await eventStore.append(_event(id: 'core'));
    await eventStore.append(
      _event(id: 'departure', type: RideEventType.riderLeft),
    );
    await eventStore.append(
      _event(id: 'route', type: RideEventType.routeCleared),
    );
    final api = _CompatibilityApi(
      compatibility: _compatibility(
        RelayCompatibilityDisposition.legacyCompatible,
        capabilities: const {},
      ),
    );
    final worker = InternetRelayWorker(
      api: api,
      eventStore: eventStore,
      cursorStore: InMemoryInternetCursorStore(),
      pollInterval: const Duration(days: 1),
    );
    final synced = worker.statuses.firstWhere(
      (status) => status.phase == InternetRelayPhase.synced,
    );

    await worker.start(_session);
    await synced.timeout(const Duration(seconds: 1));
    await worker.stop();

    expect(api.compatibilityChecks, 1);
    expect(api.uploads.first.map((event) => event.id), ['core']);
    expect(
      (await eventStore.pendingEvents(
        _session.rideId,
      )).map((event) => event.id),
      containsAll(['departure', 'route']),
    );
    await worker.close();
  });

  test('stops safely when the relay requires an app update', () async {
    final api = _CompatibilityApi(
      compatibility: _compatibility(
        RelayCompatibilityDisposition.updateRequired,
        capabilities: const {},
      ),
    );
    final worker = InternetRelayWorker(
      api: api,
      eventStore: InMemoryEventStore(),
      cursorStore: InMemoryInternetCursorStore(),
    );
    final blocked = worker.statuses.firstWhere(
      (status) => status.phase == InternetRelayPhase.updateRequired,
    );

    await worker.start(_session);
    final status = await blocked.timeout(const Duration(seconds: 1));

    expect(api.callCount, 0);
    expect(status.actionUrl, Uri.parse('https://tailendcharlie.app/update'));
    await worker.close();
  });
}

class _FakeApi implements InternetRelayApi {
  _FakeApi({
    InternetRelayConfiguration? configuration,
    required List<InternetSyncResult> results,
  }) : configuration =
           configuration ??
           InternetRelayConfiguration(
             baseUri: Uri.parse('https://relay.example'),
           ),
       _results = List.of(results);

  @override
  final InternetRelayConfiguration configuration;
  final List<InternetSyncResult> _results;
  final List<List<RideEvent>> uploads = [];
  int callCount = 0;

  @override
  Future<InternetSyncResult> synchronize({
    required RideSession session,
    required String? cursor,
    required List<RideEvent> events,
  }) async {
    callCount += 1;
    uploads.add(List.of(events));
    return _results.removeAt(0);
  }

  @override
  void close() {}
}

class _RecoveringApi implements InternetRelayApi {
  int callCount = 0;

  @override
  InternetRelayConfiguration get configuration =>
      InternetRelayConfiguration(baseUri: Uri.parse('https://relay.example'));

  @override
  Future<InternetSyncResult> synchronize({
    required RideSession session,
    required String? cursor,
    required List<RideEvent> events,
  }) async {
    callCount += 1;
    if (callCount == 1) {
      throw const InternetRelayException('No coverage', retryable: true);
    }
    return const InternetSyncResult(
      cursor: 'recovered',
      acceptedEventIds: {},
      events: [],
    );
  }

  @override
  void close() {}
}

class _CompatibilityApi implements InternetRelayApi, RelayCompatibilityApi {
  _CompatibilityApi({required this.compatibility});

  final RelayCompatibilityResult compatibility;
  final List<List<RideEvent>> uploads = [];
  int compatibilityChecks = 0;
  int callCount = 0;

  @override
  InternetRelayConfiguration get configuration =>
      InternetRelayConfiguration(baseUri: Uri.parse('https://relay.example'));

  @override
  Future<RelayCompatibilityResult> checkCompatibility() async {
    compatibilityChecks += 1;
    return compatibility;
  }

  @override
  Future<InternetSyncResult> synchronize({
    required RideSession session,
    required String? cursor,
    required List<RideEvent> events,
  }) async {
    callCount += 1;
    uploads.add(List.of(events));
    return InternetSyncResult(
      cursor: 'cursor-$callCount',
      acceptedEventIds: events.map((event) => event.id).toSet(),
      events: const [],
    );
  }

  @override
  void close() {}
}

RelayCompatibilityResult _compatibility(
  RelayCompatibilityDisposition disposition, {
  required Set<String> capabilities,
}) => RelayCompatibilityResult(
  disposition: disposition,
  serverProtocol: 1,
  minimumClientProtocol: 1,
  capabilities: capabilities,
  checkedAt: DateTime.utc(2026, 7, 22),
  validUntil: DateTime.utc(2026, 7, 22, 0, 5),
  message: disposition == RelayCompatibilityDisposition.updateRequired
      ? 'Update required.'
      : null,
  updateUri: disposition == RelayCompatibilityDisposition.updateRequired
      ? Uri.parse('https://tailendcharlie.app/update')
      : null,
);

final _session = RideSession(
  rideId: 'ride-alpha',
  rideCode: 'ALPHA1',
  inviteSecret: '0123456789abcdef0123456789abcdef',
  joinToken: 'test-join-token-0123456789',
  localRiderId: 'local-device',
  displayName: 'Oliver',
  role: RideRole.rider,
  joinedAt: DateTime.utc(2026, 7, 16),
);

RideEvent _event({
  required String id,
  String deviceId = 'local-device',
  RideEventType type = RideEventType.statusMessage,
}) => _signedEvent(id: id, deviceId: deviceId, type: type);

RideEvent _signedEvent({
  required String id,
  required String deviceId,
  RideEventType type = RideEventType.statusMessage,
}) {
  final unsigned = RideEvent(
    id: id,
    rideId: _session.rideId,
    deviceId: deviceId,
    type: type,
    priority: EventPriority.routine,
    createdAt: DateTime.utc(2026, 7, 16, 10),
    payload: const {'message': 'OK'},
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
    signature: RideEventAuthenticator.sign(unsigned, _session.inviteSecret),
  );
}
