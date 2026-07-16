import 'dart:async';
import 'dart:math';

import '../domain/event_store.dart';
import '../domain/ride_event.dart';
import '../domain/ride_session.dart';
import '../services/ride_event_authenticator.dart';
import 'internet_cursor_store.dart';
import 'internet_relay_client.dart';

enum InternetRelayPhase {
  unconfigured,
  stopped,
  syncing,
  synced,
  retrying,
  unauthorized,
  failed,
}

class InternetRelayStatus {
  const InternetRelayStatus({
    required this.phase,
    required this.message,
    this.lastSuccessfulSync,
    this.nextAttemptAt,
    this.pendingEventCount = 0,
  });

  const InternetRelayStatus.stopped()
    : this(
        phase: InternetRelayPhase.stopped,
        message: 'Internet relay stopped',
      );

  final InternetRelayPhase phase;
  final String message;
  final DateTime? lastSuccessfulSync;
  final DateTime? nextAttemptAt;
  final int pendingEventCount;
}

class InternetRetryPolicy {
  const InternetRetryPolicy({
    this.initialDelay = const Duration(seconds: 2),
    this.maximumDelay = const Duration(minutes: 1),
  });

  final Duration initialDelay;
  final Duration maximumDelay;

  Duration delayFor(int failureCount, {required double randomValue}) {
    final exponent = (failureCount - 1).clamp(0, 10);
    final uncapped = initialDelay.inMilliseconds * pow(2, exponent);
    final capped = min(uncapped.round(), maximumDelay.inMilliseconds);
    final jitter = 0.8 + (randomValue.clamp(0, 1) * 0.4);
    return Duration(milliseconds: (capped * jitter).round());
  }
}

class InternetRelayWorker {
  factory InternetRelayWorker({
    required InternetRelayApi api,
    required EventStore eventStore,
    required InternetCursorStore cursorStore,
    InternetRetryPolicy retryPolicy = const InternetRetryPolicy(),
    Duration pollInterval = const Duration(seconds: 15),
    DateTime Function()? clock,
    double Function()? randomValue,
  }) => InternetRelayWorker._(
    api,
    eventStore,
    cursorStore,
    retryPolicy,
    pollInterval,
    clock ?? DateTime.now,
    randomValue ?? Random.secure().nextDouble,
  );

  InternetRelayWorker._(
    this._api,
    this._eventStore,
    this._cursorStore,
    this._retryPolicy,
    this._pollInterval,
    this._clock,
    this._randomValue,
  );

  final InternetRelayApi _api;
  final EventStore _eventStore;
  final InternetCursorStore _cursorStore;
  final InternetRetryPolicy _retryPolicy;
  final Duration _pollInterval;
  final DateTime Function() _clock;
  final double Function() _randomValue;
  final _statusController = StreamController<InternetRelayStatus>.broadcast();
  final _receivedEventController = StreamController<RideEvent>.broadcast();

  InternetRelayStatus _status = const InternetRelayStatus.stopped();
  RideSession? _session;
  Timer? _timer;
  bool _running = false;
  bool _syncing = false;
  bool _wakePending = false;
  bool _closed = false;
  int _failureCount = 0;
  int _generation = 0;

  InternetRelayStatus get status => _status;
  Stream<InternetRelayStatus> get statuses => _statusController.stream;
  Stream<RideEvent> get receivedEvents => _receivedEventController.stream;

  Future<void> start(RideSession session) async {
    if (_closed) throw StateError('Internet relay worker is closed.');
    _stop(emitStatus: false);
    _session = session;
    _status = const InternetRelayStatus.stopped();
    _failureCount = 0;
    _wakePending = false;
    final configurationError = _api.configuration.configurationError;
    if (configurationError != null) {
      _emit(
        InternetRelayStatus(
          phase: InternetRelayPhase.unconfigured,
          message: configurationError,
        ),
      );
      return;
    }
    if (session.inviteSecret.length < 16) {
      _emit(
        const InternetRelayStatus(
          phase: InternetRelayPhase.unauthorized,
          message: 'Authenticated ride invitation required',
        ),
      );
      return;
    }
    _running = true;
    unawaited(synchronizeNow());
  }

  Future<void> synchronizeNow() async {
    final session = _session;
    final generation = _generation;
    if (!_running || session == null || _closed) return;
    if (_syncing) {
      _wakePending = true;
      return;
    }
    _timer?.cancel();
    _timer = null;
    _syncing = true;
    _wakePending = false;
    var nextDelay = _pollInterval;
    try {
      final pending = await _eventStore.pendingEvents(session.rideId);
      final upload = pending
          .take(_api.configuration.maximumUploadEvents)
          .toList(growable: false);
      if (!_isCurrent(generation, session)) return;
      _emit(
        InternetRelayStatus(
          phase: InternetRelayPhase.syncing,
          message: 'Synchronizing queued ride events',
          lastSuccessfulSync: _status.lastSuccessfulSync,
          pendingEventCount: pending.length,
        ),
      );
      final knownEventIds = (await _eventStore.eventsForRide(
        session.rideId,
      )).map((event) => event.id).toSet();
      final result = await _api.synchronize(
        session: session,
        cursor: await _cursorStore.load(session.rideId),
        events: upload,
      );
      if (!_isCurrent(generation, session)) return;
      for (final event in result.events) {
        if (event.rideId != session.rideId ||
            event.schemaVersion != 1 ||
            !RideEventAuthenticator.verify(event, session.inviteSecret)) {
          throw InternetRelayException(
            'Server returned an unauthenticated event ${event.id}.',
          );
        }
      }
      for (final eventId in result.acceptedEventIds) {
        if (!_isCurrent(generation, session)) return;
        await _eventStore.markAcknowledged(eventId);
      }
      for (final event in result.events) {
        if (!_isCurrent(generation, session)) return;
        if (!knownEventIds.add(event.id)) continue;
        final stored = event.copyWith(acknowledged: true);
        await _eventStore.append(stored);
        if (_isCurrent(generation, session) &&
            !_receivedEventController.isClosed) {
          _receivedEventController.add(stored);
        }
      }
      if (!_isCurrent(generation, session)) return;
      await _cursorStore.save(session.rideId, result.cursor);
      if (!_isCurrent(generation, session)) return;
      _failureCount = 0;
      final remaining = await _eventStore.pendingEvents(session.rideId);
      _emit(
        InternetRelayStatus(
          phase: InternetRelayPhase.synced,
          message: 'Last server sync succeeded',
          lastSuccessfulSync: _clock(),
          pendingEventCount: remaining.length,
        ),
      );
      if (remaining.isNotEmpty && result.acceptedEventIds.isNotEmpty) {
        nextDelay = Duration.zero;
      }
    } on InternetRelayException catch (error) {
      if (!_isCurrent(generation, session)) return;
      _failureCount += 1;
      nextDelay = _boundedRetryDelay(error.retryAfter);
      final phase = error.unauthorized
          ? InternetRelayPhase.unauthorized
          : error.retryable
          ? InternetRelayPhase.retrying
          : InternetRelayPhase.failed;
      if (!error.retryable) {
        nextDelay = const Duration(minutes: 1);
      }
      _emit(
        InternetRelayStatus(
          phase: phase,
          message: error.message,
          lastSuccessfulSync: _status.lastSuccessfulSync,
          nextAttemptAt: _clock().add(nextDelay),
          pendingEventCount: _status.pendingEventCount,
        ),
      );
    } on Object catch (error) {
      if (!_isCurrent(generation, session)) return;
      _failureCount += 1;
      nextDelay = _boundedRetryDelay(null);
      _emit(
        InternetRelayStatus(
          phase: InternetRelayPhase.retrying,
          message: 'Internet relay is temporarily unavailable: $error',
          lastSuccessfulSync: _status.lastSuccessfulSync,
          nextAttemptAt: _clock().add(nextDelay),
          pendingEventCount: _status.pendingEventCount,
        ),
      );
    } finally {
      _syncing = false;
      if (_running && !_closed) {
        _schedule(
          generation == _generation && !_wakePending
              ? nextDelay
              : Duration.zero,
        );
      }
    }
  }

  Duration _boundedRetryDelay(Duration? serverDelay) {
    if (serverDelay != null) {
      final milliseconds = serverDelay.inMilliseconds.clamp(0, 300000);
      return Duration(milliseconds: milliseconds);
    }
    return _retryPolicy.delayFor(_failureCount, randomValue: _randomValue());
  }

  void wake() {
    if (!_running || _closed) return;
    if (_syncing) {
      _wakePending = true;
      return;
    }
    _timer?.cancel();
    _timer = null;
    unawaited(synchronizeNow());
  }

  void _schedule(Duration delay) {
    _timer?.cancel();
    _timer = Timer(delay, () => unawaited(synchronizeNow()));
  }

  Future<void> stop({bool emitStatus = true}) {
    _stop(emitStatus: emitStatus);
    return Future.value();
  }

  void _stop({required bool emitStatus}) {
    _generation += 1;
    _running = false;
    _timer?.cancel();
    _timer = null;
    _session = null;
    if (emitStatus && !_closed) {
      _emit(const InternetRelayStatus.stopped());
    }
  }

  bool _isCurrent(int generation, RideSession session) =>
      _running &&
      !_closed &&
      generation == _generation &&
      identical(session, _session);

  void _emit(InternetRelayStatus status) {
    _status = status;
    if (!_statusController.isClosed) _statusController.add(status);
  }

  Future<void> close() async {
    if (_closed) return;
    _stop(emitStatus: false);
    _closed = true;
    _api.close();
    await _statusController.close();
    await _receivedEventController.close();
  }
}
