import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/data/in_memory_event_store.dart';
import 'package:ride_relay/domain/ride_event.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/ride_session.dart';
import 'package:ride_relay/internet/internet_cursor_store.dart';
import 'package:ride_relay/internet/internet_relay_client.dart';
import 'package:ride_relay/internet/internet_relay_worker.dart';
import 'package:ride_relay/relay/live_presence.dart';
import 'package:ride_relay/services/ride_event_authenticator.dart';

/// Upload and download share one relay request, so a refused upload used to
/// discard the download that would have carried a join or a position. Because
/// pending events are offered oldest-first, one permanently refused event at the
/// head of the queue silently froze the whole ride in both directions — exactly
/// the field report in issue #99.
void main() {
  test(
    'one refused event is isolated instead of blocking the whole queue',
    () async {
      final eventStore = InMemoryEventStore();
      await eventStore.append(_event(id: 'poison', createdAt: _base));
      await eventStore.append(
        _event(
          id: 'join',
          type: RideEventType.riderJoined,
          createdAt: _base.add(const Duration(seconds: 1)),
        ),
      );
      await eventStore.append(
        _event(
          id: 'position',
          type: RideEventType.riderLocationUpdated,
          createdAt: _base.add(const Duration(seconds: 2)),
        ),
      );
      final api = _PoisonEventApi(refusedEventId: 'poison');
      final worker = InternetRelayWorker(
        api: api,
        eventStore: eventStore,
        cursorStore: InMemoryInternetCursorStore(),
        pollInterval: const Duration(milliseconds: 1),
        retryPolicy: const InternetRetryPolicy(
          initialDelay: Duration(milliseconds: 1),
          maximumDelay: Duration(milliseconds: 1),
        ),
        randomValue: () => 0.5,
      );
      final quarantined = worker.statuses.firstWhere(
        (status) => status.quarantinedEventCount > 0,
      );

      await worker.start(_session);
      await quarantined.timeout(const Duration(seconds: 2));
      final accepted = worker.statuses.firstWhere(
        (status) =>
            status.phase == InternetRelayPhase.synced &&
            status.pendingEventCount == 0,
      );
      await accepted.timeout(const Duration(seconds: 2));

      expect(worker.quarantinedEventIds, {'poison'});
      // The join and the position got through despite the refused event.
      expect(api.acceptedEventIds, containsAll(['join', 'position']));
      // The refused event stays in the durable journal: offline-first is not
      // sacrificed to keep the relay moving.
      expect(
        (await eventStore.eventsForRide(_session.rideId)).map((e) => e.id),
        containsAll(['poison', 'join', 'position']),
      );
      expect(
        worker.status.limitations.map((limitation) => limitation.kind),
        contains(PresenceLimitationKind.uploadQuarantined),
      );
      await worker.close();
    },
  );

  test('a refused upload never blocks receiving', () async {
    final eventStore = InMemoryEventStore();
    await eventStore.append(_event(id: 'poison', createdAt: _base));
    final api = _PoisonEventApi(
      refusedEventId: 'poison',
      download: [
        _event(
          id: 'peer-join',
          deviceId: 'peer-device',
          type: RideEventType.riderJoined,
          createdAt: _base,
        ),
      ],
    );
    final worker = InternetRelayWorker(
      api: api,
      eventStore: eventStore,
      cursorStore: InMemoryInternetCursorStore(),
      pollInterval: const Duration(milliseconds: 1),
      retryPolicy: const InternetRetryPolicy(
        initialDelay: Duration(milliseconds: 1),
        maximumDelay: Duration(milliseconds: 1),
      ),
      randomValue: () => 0.5,
    );
    final received = <RideEvent>[];
    final subscription = worker.receivedEvents.listen(received.add);
    final delivered = worker.receivedEvents.first;

    await worker.start(_session);
    await delivered.timeout(const Duration(seconds: 2));

    expect(received.single.id, 'peer-join');
    // The first retry after a refusal uploads nothing at all.
    expect(api.uploadSizes.take(2), [1, 0]);
    await subscription.cancel();
    await worker.close();
  });

  test('a negotiation verdict is not mistaken for a poison event', () async {
    final eventStore = InMemoryEventStore();
    await eventStore.append(_event(id: 'local', createdAt: _base));
    final api = _RejectingApi(
      const InternetRelayException(
        'Update Tail End Charlie.',
        code: 'update_required',
        statusCode: 426,
      ),
    );
    final worker = InternetRelayWorker(
      api: api,
      eventStore: eventStore,
      cursorStore: InMemoryInternetCursorStore(),
      pollInterval: const Duration(days: 1),
    );
    final blocked = worker.statuses.firstWhere(
      (status) => status.phase == InternetRelayPhase.updateRequired,
    );

    await worker.start(_session);
    await blocked.timeout(const Duration(seconds: 2));

    expect(worker.quarantinedEventIds, isEmpty);
    await worker.close();
  });

  test('a rejected credential never quarantines a rider event', () async {
    final eventStore = InMemoryEventStore();
    await eventStore.append(_event(id: 'local', createdAt: _base));
    final api = _RejectingApi(
      const InternetRelayException(
        'Ride credential rejected.',
        unauthorized: true,
        statusCode: 403,
      ),
    );
    final worker = InternetRelayWorker(
      api: api,
      eventStore: eventStore,
      cursorStore: InMemoryInternetCursorStore(),
      pollInterval: const Duration(days: 1),
    );
    final blocked = worker.statuses.firstWhere(
      (status) => status.phase == InternetRelayPhase.unauthorized,
    );

    await worker.start(_session);
    await blocked.timeout(const Duration(seconds: 2));

    expect(worker.quarantinedEventIds, isEmpty);
    await worker.close();
  });

  test('events a newer peer sent are counted as a named limitation', () async {
    final api = _FixedResultApi(
      const InternetSyncResult(
        cursor: 'cursor-1',
        acceptedEventIds: {},
        events: [],
        ignoredEventCount: 2,
        ignoredEventTypes: {'rideTeleported'},
      ),
    );
    final worker = InternetRelayWorker(
      api: api,
      eventStore: InMemoryEventStore(),
      cursorStore: InMemoryInternetCursorStore(),
      pollInterval: const Duration(days: 1),
    );
    final synced = worker.statuses.firstWhere(
      (status) => status.phase == InternetRelayPhase.synced,
    );

    await worker.start(_session);
    final status = await synced.timeout(const Duration(seconds: 2));

    expect(status.ignoredEventCount, 2);
    final limitation = status.limitations.single;
    expect(limitation.kind, PresenceLimitationKind.unsupportedEventsIgnored);
    expect(limitation.message, contains('newer app'));
    await worker.close();
  });

  test(
    'withheld capability-dependent uploads become a named limitation',
    () async {
      final eventStore = InMemoryEventStore();
      await eventStore.append(_event(id: 'core', createdAt: _base));
      await eventStore.append(
        _event(
          id: 'departure',
          type: RideEventType.riderLeft,
          createdAt: _base.add(const Duration(seconds: 1)),
        ),
      );
      final api = _LegacyRelayApi();
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
      final status = await synced.timeout(const Duration(seconds: 2));

      expect(status.unsupportedUploadCount, 1);
      expect(
        status.limitations.map((limitation) => limitation.kind),
        contains(PresenceLimitationKind.uploadCapabilityMissing),
      );
      expect(worker.compatibility?.supports('membership-v1'), isFalse);
      await worker.close();
    },
  );

  test('a transport failure message never carries the relay host', () async {
    final api = _ThrowingApi();
    final worker = InternetRelayWorker(
      api: api,
      eventStore: InMemoryEventStore(),
      cursorStore: InMemoryInternetCursorStore(),
      pollInterval: const Duration(days: 1),
      retryPolicy: const InternetRetryPolicy(
        initialDelay: Duration(milliseconds: 1),
        maximumDelay: Duration(milliseconds: 1),
      ),
      randomValue: () => 0.5,
    );
    final retrying = worker.statuses.firstWhere(
      (status) => status.phase == InternetRelayPhase.retrying,
    );

    await worker.start(_session);
    final status = await retrying.timeout(const Duration(seconds: 2));

    expect(status.message, isNot(contains('relay.internal.example')));
    expect(status.message, isNot(contains('super-secret-token')));
    expect(status.message, 'Internet relay is temporarily unavailable.');
    await worker.close();
  });
}

/// Refuses one specific event with a non-retryable error, the way the relay
/// refuses a body it will never accept.
class _PoisonEventApi implements InternetRelayApi {
  _PoisonEventApi({required this.refusedEventId, this.download = const []});

  final String refusedEventId;
  final List<RideEvent> download;
  final List<int> uploadSizes = [];
  final Set<String> acceptedEventIds = {};
  var _cursor = 0;
  var _delivered = false;

  @override
  InternetRelayConfiguration get configuration =>
      InternetRelayConfiguration(baseUri: Uri.parse('https://relay.example'));

  @override
  Future<InternetSyncResult> synchronize({
    required RideSession session,
    required String? cursor,
    required List<RideEvent> events,
  }) async {
    uploadSizes.add(events.length);
    if (events.any((event) => event.id == refusedEventId)) {
      throw const InternetRelayException(
        'Event fields are invalid',
        statusCode: 400,
      );
    }
    _cursor += 1;
    acceptedEventIds.addAll(events.map((event) => event.id));
    final delivering = _delivered ? const <RideEvent>[] : download;
    _delivered = true;
    return InternetSyncResult(
      cursor: 'cursor-$_cursor',
      acceptedEventIds: events.map((event) => event.id).toSet(),
      events: delivering,
    );
  }

  @override
  void close() {}
}

class _RejectingApi implements InternetRelayApi {
  _RejectingApi(this._error);

  final InternetRelayException _error;

  @override
  InternetRelayConfiguration get configuration =>
      InternetRelayConfiguration(baseUri: Uri.parse('https://relay.example'));

  @override
  Future<InternetSyncResult> synchronize({
    required RideSession session,
    required String? cursor,
    required List<RideEvent> events,
  }) async => throw _error;

  @override
  void close() {}
}

class _FixedResultApi implements InternetRelayApi {
  _FixedResultApi(this._result);

  final InternetSyncResult _result;

  @override
  InternetRelayConfiguration get configuration =>
      InternetRelayConfiguration(baseUri: Uri.parse('https://relay.example'));

  @override
  Future<InternetSyncResult> synchronize({
    required RideSession session,
    required String? cursor,
    required List<RideEvent> events,
  }) async => _result;

  @override
  void close() {}
}

class _LegacyRelayApi implements InternetRelayApi, RelayCompatibilityApi {
  var _cursor = 0;

  @override
  InternetRelayConfiguration get configuration =>
      InternetRelayConfiguration(baseUri: Uri.parse('https://relay.example'));

  @override
  Future<RelayCompatibilityResult> checkCompatibility() async =>
      RelayCompatibilityResult(
        disposition: RelayCompatibilityDisposition.legacyCompatible,
        serverProtocol: 1,
        minimumClientProtocol: 1,
        capabilities: const {},
        checkedAt: DateTime.utc(2026, 7, 25),
        validUntil: DateTime.utc(2026, 7, 25, 0, 5),
      );

  @override
  Future<InternetSyncResult> synchronize({
    required RideSession session,
    required String? cursor,
    required List<RideEvent> events,
  }) async {
    _cursor += 1;
    return InternetSyncResult(
      cursor: 'cursor-$_cursor',
      acceptedEventIds: events.map((event) => event.id).toSet(),
      events: const [],
    );
  }

  @override
  void close() {}
}

/// Stands in for a socket or TLS failure whose own message names the host.
class _ThrowingApi implements InternetRelayApi {
  @override
  InternetRelayConfiguration get configuration =>
      InternetRelayConfiguration(baseUri: Uri.parse('https://relay.example'));

  @override
  Future<InternetSyncResult> synchronize({
    required RideSession session,
    required String? cursor,
    required List<RideEvent> events,
  }) async => throw StateError(
    'Connection to relay.internal.example:8443 failed for super-secret-token',
  );

  @override
  void close() {}
}

final _base = DateTime.utc(2026, 7, 25, 10);

final _session = RideSession(
  rideId: 'ride-isolation',
  rideCode: '123456',
  inviteSecret: '0123456789abcdef0123456789abcdef',
  joinToken: 'test-join-token-0123456789',
  localRiderId: 'local-device',
  displayName: 'Oliver',
  role: RideRole.rider,
  joinedAt: DateTime.utc(2026, 7, 25, 9),
);

RideEvent _event({
  required String id,
  required DateTime createdAt,
  String deviceId = 'local-device',
  RideEventType type = RideEventType.statusMessage,
}) {
  final unsigned = RideEvent(
    id: id,
    rideId: _session.rideId,
    deviceId: deviceId,
    type: type,
    priority: EventPriority.routine,
    createdAt: createdAt,
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
