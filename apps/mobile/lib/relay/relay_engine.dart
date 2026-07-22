import 'dart:async';
import 'dart:math';

import 'package:uuid/uuid.dart';

import '../domain/event_store.dart';
import '../domain/ride_event.dart';
import 'peer_transport.dart';
import 'relay_protocol.dart';
import 'relay_queue.dart';

typedef RelayClock = DateTime Function();
typedef RelayIdFactory = String Function();
typedef RelayDelay = Future<void> Function(Duration duration);

enum RelayConnectionState {
  stopped,
  starting,
  searching,
  connected,
  backingOff,
  unavailable,
  failed,
}

class RelayStatus {
  const RelayStatus({
    required this.state,
    this.peerIds = const {},
    this.queuedEventCount = 0,
    this.rejectedFrameCount = 0,
    this.lastExchangeAt,
    this.retryAt,
    this.message,
  });

  const RelayStatus.stopped()
    : state = RelayConnectionState.stopped,
      peerIds = const {},
      queuedEventCount = 0,
      rejectedFrameCount = 0,
      lastExchangeAt = null,
      retryAt = null,
      message = null;

  final RelayConnectionState state;
  final Set<String> peerIds;
  final int queuedEventCount;
  final int rejectedFrameCount;
  final DateTime? lastExchangeAt;
  final DateTime? retryAt;
  final String? message;

  RelayStatus copyWith({
    RelayConnectionState? state,
    Set<String>? peerIds,
    int? queuedEventCount,
    int? rejectedFrameCount,
    DateTime? lastExchangeAt,
    DateTime? retryAt,
    bool clearRetryAt = false,
    String? message,
    bool clearMessage = false,
  }) => RelayStatus(
    state: state ?? this.state,
    peerIds: peerIds ?? this.peerIds,
    queuedEventCount: queuedEventCount ?? this.queuedEventCount,
    rejectedFrameCount: rejectedFrameCount ?? this.rejectedFrameCount,
    lastExchangeAt: lastExchangeAt ?? this.lastExchangeAt,
    retryAt: clearRetryAt ? null : (retryAt ?? this.retryAt),
    message: clearMessage ? null : (message ?? this.message),
  );
}

class ReconnectBackoff {
  const ReconnectBackoff({
    this.initial = const Duration(seconds: 1),
    this.maximum = const Duration(seconds: 30),
    this.multiplier = 2,
    this.jitterFraction = 0.2,
  });

  final Duration initial;
  final Duration maximum;
  final double multiplier;
  final double jitterFraction;

  Duration delayFor(int attempt, {required double randomUnit}) {
    final exponent = attempt <= 1 ? 0 : attempt - 1;
    final base = min(
      maximum.inMilliseconds.toDouble(),
      initial.inMilliseconds * pow(multiplier, exponent),
    );
    final clampedRandom = randomUnit.clamp(0, 1);
    final jitter = (clampedRandom * 2 - 1) * jitterFraction;
    return Duration(
      milliseconds: (base * (1 + jitter)).round().clamp(
        0,
        maximum.inMilliseconds,
      ),
    );
  }
}

class RelayEngineConfig {
  const RelayEngineConfig({
    required this.rideId,
    required this.rideSecret,
    required this.localDeviceId,
    required this.endpointName,
    this.serviceId = 'me.osholt.ride_relay.relay.v1',
  });

  final String rideId;
  final String rideSecret;
  final String localDeviceId;
  final String endpointName;
  final String serviceId;
}

/// Durable, transport-neutral, application-layer relay.
///
/// Delivery is at-least-once. Application acknowledgements prevent needless
/// repeats to the same endpoint, while event IDs make replay idempotent.
class RelayEngine {
  RelayEngine({
    required PeerTransport transport,
    required EventStore eventStore,
    required RelayQueueStore queue,
    RelayProtocol protocol = const RelayProtocol(),
    ReconnectBackoff backoff = const ReconnectBackoff(),
    RelayClock? clock,
    RelayIdFactory? idFactory,
    RelayDelay? delay,
    Random? random,
  }) : this._(
         transport,
         eventStore,
         queue,
         protocol,
         backoff,
         clock ?? DateTime.now,
         idFactory ?? const Uuid().v7,
         delay ?? Future<void>.delayed,
         random ?? Random.secure(),
       );

  RelayEngine._(
    this._transport,
    this._eventStore,
    this._queue,
    this._protocol,
    this._backoff,
    this._clock,
    this._idFactory,
    this._delay,
    this._random,
  );

  static const maxQueuedEvents = 512;
  static const _flushInterval = Duration(seconds: 5);

  final PeerTransport _transport;
  final EventStore _eventStore;
  final RelayQueueStore _queue;
  final RelayProtocol _protocol;
  final ReconnectBackoff _backoff;
  final RelayClock _clock;
  final RelayIdFactory _idFactory;
  final RelayDelay _delay;
  final Random _random;
  final _statusController = StreamController<RelayStatus>.broadcast();
  final _receivedEventController = StreamController<RideEvent>.broadcast();

  RelayEngineConfig? _config;
  RelayStatus _status = const RelayStatus.stopped();
  StreamSubscription<PeerTransportStatus>? _transportStatusSubscription;
  StreamSubscription<PeerPacket>? _packetSubscription;
  Timer? _flushTimer;
  int _retryAttempt = 0;
  int _retryGeneration = 0;
  bool _running = false;
  bool _flushing = false;
  bool _flushRequested = false;

  RelayStatus get status => _status;
  Stream<RelayStatus> get statuses => _statusController.stream;
  Stream<RideEvent> get receivedEvents => _receivedEventController.stream;

  Future<void> start(RelayEngineConfig config) async {
    if (config.rideId.isEmpty ||
        config.localDeviceId.isEmpty ||
        config.rideSecret.length < 16) {
      throw ArgumentError('A complete, authenticated ride session is required');
    }
    await stop();
    _config = config;
    _running = true;
    _transportStatusSubscription = _transport.statuses.listen(
      _onTransportStatus,
    );
    _packetSubscription = _transport.packets.listen(_onPacket);
    _flushTimer = Timer.periodic(_flushInterval, (_) => unawaited(flush()));
    await _queue.prune(now: _clock(), maxItems: maxQueuedEvents);
    await _refreshQueueCount();
    unawaited(_connect());
  }

  Future<void> enqueueLocal(RideEvent event) async {
    final config = _requireConfig();
    if (event.rideId != config.rideId) {
      throw ArgumentError('Cannot relay an event from another ride');
    }
    final now = _clock();
    final defaultLifetime = switch (event.type) {
      RideEventType.routeRevisionChunk ||
      RideEventType.routeRevisionPublished ||
      RideEventType.routeCleared => const Duration(hours: 72),
      _ => switch (event.priority) {
        EventPriority.routine => const Duration(hours: 2),
        EventPriority.important => const Duration(hours: 8),
        EventPriority.critical => const Duration(hours: 24),
      },
    };
    final defaultExpiry = now.add(defaultLifetime);
    final eventExpiry = event.expiresAt;
    final expiresAt = eventExpiry != null && eventExpiry.isBefore(defaultExpiry)
        ? eventExpiry
        : defaultExpiry;
    if (!expiresAt.isAfter(now)) {
      return;
    }
    await _queue.enqueue(
      QueuedRelayEvent(
        event: event,
        firstSeenAt: now,
        expiresAt: expiresAt,
        hopCount: 0,
      ),
    );
    await _queue.prune(now: now, maxItems: maxQueuedEvents);
    await _refreshQueueCount();
    await flush();
  }

  Future<void> flush() async {
    final config = _config;
    if (!_running || config == null || _status.peerIds.isEmpty) {
      return;
    }
    if (_flushing) {
      _flushRequested = true;
      return;
    }
    _flushing = true;
    try {
      final now = _clock();
      await _queue.prune(now: now, maxItems: maxQueuedEvents);
      for (final peerId in _status.peerIds) {
        final items = await _queue.pendingForPeer(
          config.rideId,
          peerId,
          now: now,
          limit: RelayProtocol.maxEventsPerFrame,
        );
        if (items.isEmpty) {
          continue;
        }
        final bytes = _protocol.encode(
          RelayFrame(
            kind: RelayFrameKind.events,
            rideId: config.rideId,
            senderId: config.localDeviceId,
            frameId: _idFactory(),
            sentAt: now,
            events: items,
          ),
          secret: config.rideSecret,
        );
        await _transport.send(bytes, peerIds: {peerId});
      }
      await _refreshQueueCount();
    } on Object catch (error) {
      _emit(_status.copyWith(message: 'Relay send failed: $error'));
    } finally {
      _flushing = false;
      if (_flushRequested) {
        _flushRequested = false;
        unawaited(flush());
      }
    }
  }

  Future<void> _connect() async {
    final config = _config;
    if (!_running || config == null) {
      return;
    }
    _emit(
      _status.copyWith(
        state: RelayConnectionState.starting,
        clearRetryAt: true,
        clearMessage: true,
      ),
    );
    try {
      await _transport.start(
        PeerTransportConfig(
          serviceId: config.serviceId,
          endpointName: config.endpointName,
        ),
      );
    } on Object catch (error) {
      _scheduleReconnect('Nearby start failed: $error');
    }
  }

  void _onTransportStatus(PeerTransportStatus transportStatus) {
    if (!_running) {
      return;
    }
    final mapped = switch (transportStatus.state) {
      PeerTransportState.unavailable => RelayConnectionState.unavailable,
      PeerTransportState.stopped => RelayConnectionState.stopped,
      PeerTransportState.starting => RelayConnectionState.starting,
      PeerTransportState.searching => RelayConnectionState.searching,
      PeerTransportState.connected => RelayConnectionState.connected,
      PeerTransportState.failed => RelayConnectionState.failed,
    };
    _emit(
      _status.copyWith(
        state: mapped,
        peerIds: transportStatus.peerIds,
        message: transportStatus.message,
        clearMessage: transportStatus.message == null,
      ),
    );
    if (transportStatus.state == PeerTransportState.connected) {
      _retryAttempt = 0;
      _retryGeneration++;
      unawaited(flush());
    } else if (transportStatus.state == PeerTransportState.failed) {
      _scheduleReconnect(transportStatus.message ?? 'Nearby transport failed');
    }
  }

  Future<void> _onPacket(PeerPacket packet) async {
    final config = _config;
    if (!_running || config == null) {
      return;
    }
    final RelayFrame frame;
    try {
      frame = _protocol.decode(
        packet.bytes,
        secret: config.rideSecret,
        expectedRideId: config.rideId,
        now: _clock(),
      );
    } on RelayProtocolException {
      _emit(
        _status.copyWith(rejectedFrameCount: _status.rejectedFrameCount + 1),
      );
      return;
    }
    if (frame.senderId == config.localDeviceId) {
      return;
    }

    final now = _clock();
    if (frame.kind == RelayFrameKind.acknowledgement) {
      await _queue.acknowledge(packet.peerId, frame.acknowledgedEventIds);
      await _refreshQueueCount(lastExchangeAt: now);
      return;
    }

    final acknowledged = <String>[];
    for (final item in frame.events) {
      acknowledged.add(item.event.id);
      if (await _queue.contains(item.event.id)) {
        continue;
      }
      await _eventStore.append(item.event);
      _receivedEventController.add(item.event);
      final nextHop = item.hopCount + 1;
      await _queue.enqueue(
        QueuedRelayEvent(
          event: item.event,
          firstSeenAt: item.firstSeenAt,
          expiresAt: item.expiresAt,
          hopCount: nextHop,
          acknowledgedPeers: {packet.peerId},
        ),
      );
    }
    await _sendAcknowledgement(packet.peerId, acknowledged);
    await _queue.prune(now: now, maxItems: maxQueuedEvents);
    await _refreshQueueCount(lastExchangeAt: now);
    await flush();
  }

  Future<void> _sendAcknowledgement(
    String peerId,
    List<String> eventIds,
  ) async {
    if (eventIds.isEmpty) {
      return;
    }
    final config = _requireConfig();
    final bytes = _protocol.encode(
      RelayFrame(
        kind: RelayFrameKind.acknowledgement,
        rideId: config.rideId,
        senderId: config.localDeviceId,
        frameId: _idFactory(),
        sentAt: _clock(),
        acknowledgedEventIds: eventIds,
      ),
      secret: config.rideSecret,
    );
    await _transport.send(bytes, peerIds: {peerId});
  }

  void _scheduleReconnect(String message) {
    if (!_running) {
      return;
    }
    final generation = ++_retryGeneration;
    final delay = _backoff.delayFor(
      ++_retryAttempt,
      randomUnit: _random.nextDouble(),
    );
    final retryAt = _clock().add(delay);
    _emit(
      _status.copyWith(
        state: RelayConnectionState.backingOff,
        retryAt: retryAt,
        message: message,
      ),
    );
    unawaited(() async {
      await _delay(delay);
      if (_running && generation == _retryGeneration) {
        await _transport.stop();
        await _connect();
      }
    }());
  }

  Future<void> _refreshQueueCount({DateTime? lastExchangeAt}) async {
    final config = _config;
    if (config == null) {
      return;
    }
    final count = await _queue.count(config.rideId, now: _clock());
    _emit(
      _status.copyWith(queuedEventCount: count, lastExchangeAt: lastExchangeAt),
    );
  }

  void _emit(RelayStatus status) {
    _status = status;
    if (!_statusController.isClosed) {
      _statusController.add(status);
    }
  }

  RelayEngineConfig _requireConfig() {
    final config = _config;
    if (config == null) {
      throw StateError('Relay is not configured');
    }
    return config;
  }

  Future<void> stop() async {
    _running = false;
    _retryGeneration++;
    _flushTimer?.cancel();
    _flushTimer = null;
    await _transportStatusSubscription?.cancel();
    await _packetSubscription?.cancel();
    _transportStatusSubscription = null;
    _packetSubscription = null;
    await _transport.stop();
    _config = null;
    _retryAttempt = 0;
    _emit(const RelayStatus.stopped());
  }

  Future<void> dispose() async {
    await stop();
    await _queue.close();
    await _transport.dispose();
    await _statusController.close();
    await _receivedEventController.close();
  }
}
