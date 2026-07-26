import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ride_relay/data/in_memory_event_store.dart';
import 'package:ride_relay/domain/event_store.dart';
import 'package:ride_relay/domain/ride_event.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/ride_session.dart';
import 'package:ride_relay/internet/internet_cursor_store.dart';
import 'package:ride_relay/internet/internet_relay_client.dart';
import 'package:ride_relay/internet/internet_relay_worker.dart';
import 'package:ride_relay/services/ride_event_authenticator.dart';

/// Two simulated devices sharing one relay, over the **real** HTTP client and
/// worker, against a fake relay that keeps the FastAPI service's rules —
/// including its idempotency replay cache.
///
/// Issue #132: upload and download share one request. A device with nothing to
/// send repeats a byte-identical body on every poll, which the relay used to
/// answer from that cache, so an idle phone received nothing at all until it
/// happened to have an event of its own to send. Every earlier harness stubbed
/// the transport, so the replay rule was never in the loop and a device always
/// had something queued: the defect could not appear.
void main() {
  late _Relay relay;

  setUp(() => relay = _Relay());

  _Device device(String riderId, {RideRole role = RideRole.rider}) {
    final store = InMemoryEventStore();
    final cursors = InMemoryInternetCursorStore();
    final worker = InternetRelayWorker(
      api: HttpInternetRelayClient(
        configuration: InternetRelayConfiguration(
          baseUri: Uri.parse('https://relay.example/api'),
        ),
        client: MockClient(relay.handle),
        clock: () => relay.now,
      ),
      eventStore: store,
      cursorStore: cursors,
      // Every poll in these tests is driven explicitly.
      pollInterval: const Duration(days: 1),
      randomValue: () => 0.5,
    );
    addTearDown(worker.close);
    return _Device(_session(riderId, role), worker, store, cursors);
  }

  test(
    'an idle device with an empty outbound queue still receives a peer',
    () async {
      final leader = device('leader', role: RideRole.lead);
      final follower = device('follower');

      // The leader is parked on a desk: it uploads its own creation event once
      // and then has nothing further to send, exactly like a stationary phone
      // whose GPS emits no new fix.
      await leader.enqueue('leader-created', RideEventType.rideCreated);
      await leader.start();
      await follower.start();

      // Two byte-identical idle polls before the follower says anything.
      await leader.poll();
      await leader.poll();

      await follower.enqueue(
        'follower-position-1',
        RideEventType.riderLocationUpdated,
      );
      await follower.poll();

      // One more idle poll on the leader. Its queue is still empty and its
      // cursor has not moved, so the request body is unchanged.
      await leader.poll();

      expect(await leader.receivedIds(), contains('follower-position-1'));
      expect(leader.worker.status.pendingEventCount, 0);
    },
  );

  test('the same holds with the roles the other way round', () async {
    final leader = device('leader', role: RideRole.lead);
    final follower = device('follower');
    await follower.enqueue('follower-joined', RideEventType.riderJoined);
    await follower.start();
    await leader.start();

    // This time the follower is the idle device.
    await follower.poll();
    await follower.poll();
    await leader.enqueue(
      'leader-position-1',
      RideEventType.riderLocationUpdated,
    );
    await leader.poll();
    await follower.poll();

    expect(await follower.receivedIds(), contains('leader-position-1'));
  });

  test(
    'positions keep arriving in both directions while one device is idle',
    () async {
      final leader = device('leader', role: RideRole.lead);
      final follower = device('follower');
      await leader.start();
      await follower.start();

      final leaderSaw = <String>[];
      for (var step = 0; step < 3; step += 1) {
        await follower.enqueue(
          'follower-position-$step',
          RideEventType.riderLocationUpdated,
        );
        await follower.poll();
        // The leader never enqueues anything at any point.
        await leader.poll();
        leaderSaw.add('follower-position-$step');
        expect(await leader.receivedIds(), containsAll(leaderSaw));
      }
    },
  );

  test(
    'a repeated upload after a lost acknowledgement still delivers the peer',
    () async {
      final leader = device('leader', role: RideRole.lead);
      final follower = device('follower');
      await leader.enqueue(
        'leader-position-1',
        RideEventType.riderLocationUpdated,
      );
      await leader.start();
      await follower.start();

      // The relay stored the batch but the acknowledgement never landed, so the
      // same batch is offered again with the same cursor: a byte-identical body.
      await leader.forgetAcknowledgements();
      await follower.enqueue(
        'follower-position-1',
        RideEventType.riderLocationUpdated,
      );
      await follower.poll();
      await leader.poll();

      expect(await leader.receivedIds(), contains('follower-position-1'));
      // The re-offered event is stored once, not twice.
      expect(
        relay.storedIds.where((id) => id == 'leader-position-1').length,
        1,
      );
    },
  );

  test('device clocks that disagree do not stop journal delivery', () async {
    final leader = device('leader', role: RideRole.lead);
    final follower = device('follower');
    await leader.start();
    await follower.start();

    // The follower's phone clock is four minutes behind the relay.
    await follower.enqueue(
      'follower-position-1',
      RideEventType.riderLocationUpdated,
      createdAt: relay.now.subtract(const Duration(minutes: 4)),
    );
    await follower.poll();
    await leader.poll();

    expect(await leader.receivedIds(), contains('follower-position-1'));
  });
}

class _Device {
  _Device(this.session, this.worker, this.store, this.cursors);

  final RideSession session;
  final InternetRelayWorker worker;
  final EventStore store;
  final InternetCursorStore cursors;

  Future<void> start() async {
    final settled = worker.statuses.firstWhere(
      (status) => status.phase != InternetRelayPhase.syncing,
    );
    await worker.start(session);
    await settled.timeout(const Duration(seconds: 5));
    expect(worker.status.phase, InternetRelayPhase.synced);
  }

  Future<void> poll() async {
    await worker.synchronizeNow();
    expect(worker.status.phase, InternetRelayPhase.synced);
  }

  Future<void> enqueue(
    String id,
    RideEventType type, {
    DateTime? createdAt,
  }) async {
    await store.append(
      _event(
        id: id,
        deviceId: session.localRiderId,
        type: type,
        createdAt: createdAt,
      ),
    );
  }

  /// Simulates an acknowledgement write that never reached durable storage, so
  /// the same batch is offered again unchanged.
  Future<void> forgetAcknowledgements() async {
    final events = await store.eventsForRide(session.rideId);
    for (final event in events) {
      if (event.deviceId != session.localRiderId) continue;
      await store.append(event.copyWith(acknowledged: false));
    }
  }

  Future<Set<String>> receivedIds() async => (await store.eventsForRide(
    session.rideId,
  )).map((event) => event.id).toSet();
}

/// A fake relay with the same contract as `apps/server`: sequence-ordered
/// events, an opaque cursor, and an idempotency replay cache keyed by the
/// request body's digest.
class _Relay {
  DateTime now = DateTime.utc(2026, 7, 26, 12);
  final List<Map<String, Object?>> _events = [];
  final Map<String, _Replay> _replays = {};

  List<String> get storedIds => [
    for (final event in _events) event['id']! as String,
  ];

  Future<http.Response> handle(http.Request request) async {
    if (request.url.path.endsWith('/v1/compatibility')) {
      return http.Response(
        jsonEncode({
          'serverProtocol': 1,
          'minimumClientProtocol': 1,
          'maximumClientProtocol': 1,
          'capabilities': RelayProtocolCapabilities.current.toList(),
          'requiredCapabilities': <String>[],
          'cacheSeconds': 300,
          'updateUrls': {'default': 'https://tailendcharlie.app'},
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    final body = Map<String, Object?>.from(
      jsonDecode(request.body) as Map<String, Object?>,
    );
    final key = request.headers['idempotency-key']!;
    final uploaded = (body['events']! as List).cast<Map<String, Object?>>();
    final cursor = int.tryParse((body['cursor'] as String?) ?? '') ?? 0;

    // Idempotency covers the upload only: the download is always rebuilt from
    // this request's cursor. Replaying it is what deafened an idle device.
    final replay = uploaded.isEmpty ? null : _replays[key];
    final accepted = replay == null
        ? [
            for (final event in uploaded)
              if (_store(event)) event['id']! as String,
          ]
        : replay.acceptedEventIds;
    if (replay == null && uploaded.isNotEmpty) {
      _replays[key] = _Replay(accepted);
    }
    final pending = _events.skip(cursor).toList(growable: false);
    return http.Response(
      jsonEncode({
        'protocolVersion': 1,
        'cursor': '${cursor + pending.length}',
        'acceptedEventIds': accepted,
        'events': pending,
      }),
      200,
      headers: {'content-type': 'application/json'},
    );
  }

  /// Returns true when the event was accepted; a repeated event id is accepted
  /// again but stored once, as the relay's unique event id enforces.
  bool _store(Map<String, Object?> event) {
    final id = event['id'];
    if (_events.any((stored) => stored['id'] == id)) return true;
    _events.add(event);
    return true;
  }
}

class _Replay {
  const _Replay(this.acceptedEventIds);

  final List<String> acceptedEventIds;
}

const _rideId = 'ride-two-device';
const _secret = '0123456789abcdef0123456789abcdef';

RideSession _session(String riderId, RideRole role) => RideSession(
  rideId: _rideId,
  rideCode: '123456',
  inviteSecret: _secret,
  joinToken: 'test-join-token-0123456789',
  localRiderId: riderId,
  displayName: riderId,
  role: role,
  joinedAt: DateTime.utc(2026, 7, 26, 12),
);

RideEvent _event({
  required String id,
  required String deviceId,
  required RideEventType type,
  DateTime? createdAt,
}) {
  final unsigned = RideEvent(
    id: id,
    rideId: _rideId,
    deviceId: deviceId,
    type: type,
    priority: EventPriority.routine,
    createdAt: createdAt ?? DateTime.utc(2026, 7, 26, 12),
    payload: const {'displayName': 'Rider', 'role': 'rider'},
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
    signature: RideEventAuthenticator.sign(unsigned, _secret),
  );
}
