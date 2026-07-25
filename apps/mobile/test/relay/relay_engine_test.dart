import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/data/in_memory_event_store.dart';
import 'package:ride_relay/domain/geo_point.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/ride_event.dart';
import 'package:ride_relay/domain/rider_location.dart';
import 'package:ride_relay/relay/in_memory_relay_queue.dart';
import 'package:ride_relay/relay/peer_transport.dart';
import 'package:ride_relay/relay/relay_engine.dart';

void main() {
  const secret = '0123456789abcdef0123456789abcdef';
  final now = DateTime.utc(2026, 7, 16, 12);

  test('store-forwards A to B to C with dedupe and acknowledgements', () async {
    final transportA = FakePeerTransport('peer-a');
    final transportB = FakePeerTransport('peer-b');
    final transportC = FakePeerTransport('peer-c');
    final storeA = InMemoryEventStore();
    final storeB = InMemoryEventStore();
    final storeC = InMemoryEventStore();
    final queueA = InMemoryRelayQueue();
    final queueB = InMemoryRelayQueue();
    final queueC = InMemoryRelayQueue();
    var id = 0;
    RelayEngine engine(
      FakePeerTransport transport,
      InMemoryEventStore store,
      InMemoryRelayQueue queue,
    ) => RelayEngine(
      transport: transport,
      eventStore: store,
      queue: queue,
      clock: () => now,
      idFactory: () => 'frame-${id++}',
    );

    final engineA = engine(transportA, storeA, queueA);
    final engineB = engine(transportB, storeB, queueB);
    final engineC = engine(transportC, storeC, queueC);
    await engineA.start(
      const RelayEngineConfig(
        rideId: 'ride-1',
        rideSecret: secret,
        localDeviceId: 'device-a',
        endpointName: 'A',
      ),
    );
    await engineB.start(
      const RelayEngineConfig(
        rideId: 'ride-1',
        rideSecret: secret,
        localDeviceId: 'device-b',
        endpointName: 'B',
      ),
    );
    await engineC.start(
      const RelayEngineConfig(
        rideId: 'ride-1',
        rideSecret: secret,
        localDeviceId: 'device-c',
        endpointName: 'C',
      ),
    );

    await _drain();
    transportA.connect(transportB);
    final event = RideEvent(
      id: 'event-1',
      rideId: 'ride-1',
      deviceId: 'device-a',
      type: RideEventType.statusMessage,
      priority: EventPriority.critical,
      createdAt: now,
      payload: const {'message': 'emergencyStop'},
      signature: 'a' * 64,
    );
    await storeA.append(event);
    await engineA.enqueueLocal(event);
    await _drain();

    expect(engineA.status.peerIds, contains('peer-b'));
    expect(engineB.status.peerIds, contains('peer-a'));
    expect(engineB.status.rejectedFrameCount, 0);
    expect(await storeB.eventsForRide('ride-1'), hasLength(1));
    expect(
      await queueA.pendingForPeer('ride-1', 'peer-b', now: now, limit: 12),
      isEmpty,
    );

    transportA.disconnect(transportB);
    transportB.connect(transportC);
    await engineB.flush();
    await _drain();

    expect(await storeC.eventsForRide('ride-1'), hasLength(1));
    await engineB.flush();
    await _drain();
    expect(await storeC.eventsForRide('ride-1'), hasLength(1));

    await engineA.dispose();
    await engineB.dispose();
    await engineC.dispose();
  });

  test('rejects frames from a different ride secret', () async {
    final transportA = FakePeerTransport('peer-a');
    final transportB = FakePeerTransport('peer-b');
    final engineA = RelayEngine(
      transport: transportA,
      eventStore: InMemoryEventStore(),
      queue: InMemoryRelayQueue(),
      clock: () => now,
      idFactory: () => 'frame-a',
    );
    final storeB = InMemoryEventStore();
    final engineB = RelayEngine(
      transport: transportB,
      eventStore: storeB,
      queue: InMemoryRelayQueue(),
      clock: () => now,
      idFactory: () => 'frame-b',
    );
    await engineA.start(
      const RelayEngineConfig(
        rideId: 'ride-1',
        rideSecret: secret,
        localDeviceId: 'device-a',
        endpointName: 'A',
      ),
    );
    await engineB.start(
      const RelayEngineConfig(
        rideId: 'ride-1',
        rideSecret: 'fedcba9876543210fedcba9876543210',
        localDeviceId: 'device-b',
        endpointName: 'B',
      ),
    );
    await _drain();
    transportA.connect(transportB);
    await engineA.enqueueLocal(
      RideEvent(
        id: 'event-1',
        rideId: 'ride-1',
        deviceId: 'device-a',
        type: RideEventType.statusMessage,
        priority: EventPriority.important,
        createdAt: now,
        payload: const {},
        signature: 'a' * 64,
      ),
    );
    await _drain();

    expect(await storeB.eventsForRide('ride-1'), isEmpty);
    expect(engineB.status.rejectedFrameCount, greaterThanOrEqualTo(1));
    await engineA.dispose();
    await engineB.dispose();
  });

  test('carries nearby presence without journalling or queueing it', () async {
    final transportA = FakePeerTransport('peer-a');
    final transportB = FakePeerTransport('peer-b');
    final storeA = InMemoryEventStore();
    final storeB = InMemoryEventStore();
    final queueA = InMemoryRelayQueue();
    final queueB = InMemoryRelayQueue();
    var id = 0;
    RelayEngine engine(
      FakePeerTransport transport,
      InMemoryEventStore store,
      InMemoryRelayQueue queue,
    ) => RelayEngine(
      transport: transport,
      eventStore: store,
      queue: queue,
      clock: () => now,
      idFactory: () => 'presence-frame-${id++}',
    );
    final engineA = engine(transportA, storeA, queueA);
    final engineB = engine(transportB, storeB, queueB);
    await engineA.start(
      const RelayEngineConfig(
        rideId: 'ride-1',
        rideSecret: secret,
        localDeviceId: 'device-a',
        endpointName: 'A',
      ),
    );
    await engineB.start(
      const RelayEngineConfig(
        rideId: 'ride-1',
        rideSecret: secret,
        localDeviceId: 'device-b',
        endpointName: 'B',
      ),
    );
    await _drain();
    transportA.connect(transportB);
    await _drain();
    final received = engineB.receivedPresence.first;

    await engineA.publishPresence(
      RiderLocation(
        riderId: 'device-a',
        displayName: 'Alex',
        role: RideRole.rider,
        sample: LocationSample(
          position: const GeoPoint(latitude: 51.1, longitude: -2.4),
          recordedAt: now,
          accuracyMeters: 4,
        ),
        receivedAt: now,
      ),
    );

    expect((await received).position?.sample.position.latitude, 51.1);
    expect(await storeA.eventsForRide('ride-1'), isEmpty);
    expect(await storeB.eventsForRide('ride-1'), isEmpty);
    expect(await queueA.count('ride-1', now: now), 0);
    expect(await queueB.count('ride-1', now: now), 0);
    await engineA.dispose();
    await engineB.dispose();
  });

  test('backoff grows deterministically and is bounded', () {
    const backoff = ReconnectBackoff();
    expect(backoff.delayFor(1, randomUnit: 0.5), const Duration(seconds: 1));
    expect(backoff.delayFor(4, randomUnit: 0.5), const Duration(seconds: 8));
    expect(backoff.delayFor(99, randomUnit: 1), const Duration(seconds: 30));
  });
}

Future<void> _drain() async {
  for (var index = 0; index < 12; index++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class FakePeerTransport implements PeerTransport {
  FakePeerTransport(this.id);

  final String id;
  final _statuses = StreamController<PeerTransportStatus>.broadcast();
  final _packets = StreamController<PeerPacket>.broadcast();
  final Map<String, FakePeerTransport> _peers = {};

  @override
  Stream<PeerPacket> get packets => _packets.stream;

  @override
  Stream<PeerTransportStatus> get statuses => _statuses.stream;

  @override
  Future<void> start(PeerTransportConfig config) async {
    _statuses.add(
      const PeerTransportStatus(state: PeerTransportState.searching),
    );
  }

  void connect(FakePeerTransport other) {
    _peers[other.id] = other;
    other._peers[id] = this;
    _emitConnected();
    other._emitConnected();
  }

  void disconnect(FakePeerTransport other) {
    _peers.remove(other.id);
    other._peers.remove(id);
    _emitConnected();
    other._emitConnected();
  }

  void _emitConnected() {
    _statuses.add(
      PeerTransportStatus(
        state: _peers.isEmpty
            ? PeerTransportState.searching
            : PeerTransportState.connected,
        peerIds: _peers.keys.toSet(),
      ),
    );
  }

  @override
  Future<void> send(Uint8List bytes, {required Set<String> peerIds}) async {
    for (final peerId in peerIds) {
      final peer = _peers[peerId];
      if (peer == null) {
        throw StateError('Peer is disconnected');
      }
      peer._packets.add(
        PeerPacket(peerId: id, bytes: Uint8List.fromList(bytes)),
      );
    }
  }

  @override
  Future<void> stop() async {
    for (final peer in _peers.values.toList()) {
      disconnect(peer);
    }
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _statuses.close();
    await _packets.close();
  }
}
