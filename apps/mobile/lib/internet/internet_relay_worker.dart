import 'dart:async';
import 'dart:math';

import '../domain/event_store.dart';
import '../domain/ride_event.dart';
import '../domain/ride_session.dart';
import '../relay/live_presence.dart';
import '../services/ride_event_authenticator.dart';
import 'internet_cursor_store.dart';
import 'internet_relay_client.dart';

enum InternetRelayPhase {
  unconfigured,
  stopped,
  syncing,
  synced,
  retrying,
  updateRequired,
  serverUpgradeRequired,
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
    this.actionUrl,
    this.quarantinedEventCount = 0,
    this.ignoredEventCount = 0,
    this.unsupportedUploadCount = 0,
    this.limitations = const [],
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

  /// Events still eligible to upload. Quarantined events are excluded so the
  /// count cannot grow forever behind one refused event.
  final int pendingEventCount;
  final Uri? actionUrl;

  /// Events the relay refused outright, set aside so the rest of the ride keeps
  /// synchronizing. They stay in the durable journal.
  final int quarantinedEventCount;

  /// Downloaded events this build could not understand and skipped.
  final int ignoredEventCount;

  /// Events withheld because the relay does not advertise their capability.
  final int unsupportedUploadCount;

  /// Named, user-readable degradations. Never carries a hostname or raw error
  /// text.
  final List<PresenceLimitation> limitations;

  bool get isDegraded => limitations.isNotEmpty;
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
    Duration pollInterval = const Duration(seconds: 4),
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
  bool _closed = false;
  int _failureCount = 0;
  int _generation = 0;
  RelayCompatibilityResult? _compatibility;

  /// Events the relay refused outright. They stay in the durable journal but
  /// are never re-offered, so one refused event cannot block the queue head
  /// forever and hide every later join and position.
  final Set<String> _quarantinedEventIds = {};

  /// Set to 1 while isolating which event in a refused batch is at fault.
  int? _uploadProbeSize;

  /// Forces the next attempt to download only. Receiving must never be held
  /// hostage to sending: upload and download share one request, so a rejected
  /// upload otherwise discards the batch that would have revealed a new rider.
  bool _downloadOnlyNextAttempt = false;
  int _ignoredEventCount = 0;
  int _unsupportedUploadCount = 0;

  InternetRelayStatus get status => _status;
  Stream<InternetRelayStatus> get statuses => _statusController.stream;
  Stream<RideEvent> get receivedEvents => _receivedEventController.stream;

  /// The negotiated relay contract, once checked.
  RelayCompatibilityResult? get compatibility => _compatibility;

  /// Event IDs the relay refused and this worker stopped offering.
  Set<String> get quarantinedEventIds => Set.unmodifiable(_quarantinedEventIds);

  Future<void> start(RideSession session) async {
    if (_closed) throw StateError('Internet relay worker is closed.');
    _stop(emitStatus: false);
    _session = session;
    _status = const InternetRelayStatus.stopped();
    _failureCount = 0;
    _compatibility = null;
    _quarantinedEventIds.clear();
    _uploadProbeSize = null;
    _downloadOnlyNextAttempt = false;
    _ignoredEventCount = 0;
    _unsupportedUploadCount = 0;
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
    if (_syncing) return;
    _timer?.cancel();
    _timer = null;
    _syncing = true;
    var nextDelay = _pollInterval;
    var uploadLimit = 0;
    var upload = const <RideEvent>[];
    try {
      if (_compatibility == null && _api is RelayCompatibilityApi) {
        final result = await (_api as RelayCompatibilityApi)
            .checkCompatibility();
        _compatibility = result;
        if (!result.canSynchronize) {
          throw InternetRelayException(
            result.message ?? 'Ride service compatibility check failed.',
            retryable:
                result.disposition ==
                RelayCompatibilityDisposition.temporarilyUnavailable,
            code: switch (result.disposition) {
              RelayCompatibilityDisposition.updateRequired => 'update_required',
              RelayCompatibilityDisposition.serverUpgradeRequired =>
                'server_upgrade_required',
              _ => 'temporarily_unavailable',
            },
            actionUrl: result.updateUri,
          );
        }
      }
      final pending = await _eventStore.pendingEvents(session.rideId);
      final offerable = pending
          .where((event) => !_quarantinedEventIds.contains(event.id))
          .toList(growable: false);
      _unsupportedUploadCount = offerable
          .where((event) => !_serverSupportsEvent(event))
          .length;
      final downloadOnly = _downloadOnlyNextAttempt;
      _downloadOnlyNextAttempt = false;
      uploadLimit = downloadOnly
          ? 0
          : (_uploadProbeSize ?? _api.configuration.maximumUploadEvents);
      upload = offerable
          .where(_serverSupportsEvent)
          .take(uploadLimit)
          .toList(growable: false);
      if (!_isCurrent(generation, session)) return;
      _emit(
        InternetRelayStatus(
          phase: InternetRelayPhase.syncing,
          message: downloadOnly
              ? 'Receiving ride updates while a refused update is isolated'
              : 'Synchronizing queued ride events',
          lastSuccessfulSync: _status.lastSuccessfulSync,
          pendingEventCount: offerable.length,
          quarantinedEventCount: _quarantinedEventIds.length,
          ignoredEventCount: _ignoredEventCount,
          unsupportedUploadCount: _unsupportedUploadCount,
          limitations: _limitations(),
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
      // A download-only attempt proves nothing about the batch, so the probe
      // survives it; otherwise the same refused batch would be offered again
      // and the isolation would never converge.
      if (upload.isNotEmpty) _uploadProbeSize = null;
      _ignoredEventCount += result.ignoredEventCount;
      final remaining = (await _eventStore.pendingEvents(session.rideId))
          .where((event) => !_quarantinedEventIds.contains(event.id))
          .toList(growable: false);
      _emit(
        InternetRelayStatus(
          phase: InternetRelayPhase.synced,
          message: 'Last server sync succeeded',
          lastSuccessfulSync: _clock(),
          pendingEventCount: remaining.length,
          quarantinedEventCount: _quarantinedEventIds.length,
          ignoredEventCount: _ignoredEventCount,
          unsupportedUploadCount: _unsupportedUploadCount,
          limitations: _limitations(),
        ),
      );
      if (remaining.isNotEmpty &&
          (result.acceptedEventIds.isNotEmpty || uploadLimit == 0)) {
        nextDelay = Duration.zero;
      }
    } on InternetRelayException catch (error) {
      if (!_isCurrent(generation, session)) return;
      _failureCount += 1;
      final cursorExpired = error.code == 'invalid_cursor';
      if (cursorExpired) {
        await _cursorStore.clear(session.rideId);
        nextDelay = Duration.zero;
      } else {
        nextDelay = _boundedRetryDelay(error.retryAfter);
      }
      final phase = switch (error.code) {
        'update_required' => InternetRelayPhase.updateRequired,
        'server_upgrade_required' => InternetRelayPhase.serverUpgradeRequired,
        _ =>
          error.unauthorized
              ? InternetRelayPhase.unauthorized
              : error.retryable
              ? InternetRelayPhase.retrying
              : InternetRelayPhase.failed,
      };
      final isolating = _isolateRefusedUpload(error, upload);
      if (isolating) {
        nextDelay = Duration.zero;
      } else if (!error.retryable) {
        nextDelay = const Duration(minutes: 1);
      }
      _emit(
        InternetRelayStatus(
          phase: phase,
          message: cursorExpired
              ? 'Refreshing the ride history after a relay update'
              : isolating
              ? 'The ride service refused an update; isolating it so the rest '
                    'of the ride keeps synchronizing'
              : error.message,
          lastSuccessfulSync: _status.lastSuccessfulSync,
          nextAttemptAt: _clock().add(nextDelay),
          pendingEventCount: _status.pendingEventCount,
          actionUrl: error.actionUrl,
          quarantinedEventCount: _quarantinedEventIds.length,
          ignoredEventCount: _ignoredEventCount,
          unsupportedUploadCount: _unsupportedUploadCount,
          limitations: _limitations(),
        ),
      );
    } on Object {
      if (!_isCurrent(generation, session)) return;
      _failureCount += 1;
      nextDelay = _boundedRetryDelay(null);
      _emit(
        InternetRelayStatus(
          phase: InternetRelayPhase.retrying,
          // Deliberately not interpolated: a transport or TLS error can carry
          // the relay hostname and port.
          message: 'Internet relay is temporarily unavailable.',
          lastSuccessfulSync: _status.lastSuccessfulSync,
          nextAttemptAt: _clock().add(nextDelay),
          pendingEventCount: _status.pendingEventCount,
          quarantinedEventCount: _quarantinedEventIds.length,
          ignoredEventCount: _ignoredEventCount,
          unsupportedUploadCount: _unsupportedUploadCount,
          limitations: _limitations(),
        ),
      );
    } finally {
      _syncing = false;
      if (_running && !_closed) {
        _schedule(generation == _generation ? nextDelay : Duration.zero);
      }
    }
  }

  /// Keeps one refused event from wedging the whole ride.
  ///
  /// Upload and download share a single request, so a rejected batch discards
  /// the download that would have carried a join or a position. On a refusal
  /// the next attempt downloads only, then narrows the batch to one event, and
  /// finally quarantines the single offender. Returns true while isolating.
  bool _isolateRefusedUpload(
    InternetRelayException error,
    List<RideEvent> upload,
  ) {
    if (upload.isEmpty || error.retryable || error.unauthorized) return false;
    // A negotiation verdict is about the whole client, not one event.
    if (error.code == 'update_required' ||
        error.code == 'server_upgrade_required' ||
        error.code == 'invalid_cursor' ||
        error.code == 'temporarily_unavailable') {
      return false;
    }
    _downloadOnlyNextAttempt = true;
    if (upload.length == 1) {
      _quarantinedEventIds.add(upload.single.id);
      _uploadProbeSize = null;
    } else {
      _uploadProbeSize = 1;
    }
    return true;
  }

  List<PresenceLimitation> _limitations() => [
    if (_quarantinedEventIds.isNotEmpty)
      PresenceLimitation.uploadQuarantined(_quarantinedEventIds.length),
    if (_unsupportedUploadCount > 0)
      PresenceLimitation.uploadCapabilityMissing(_unsupportedUploadCount),
    if (_ignoredEventCount > 0)
      PresenceLimitation.unsupportedEventsIgnored(_ignoredEventCount),
  ];

  Duration _boundedRetryDelay(Duration? serverDelay) {
    if (serverDelay != null) {
      final milliseconds = serverDelay.inMilliseconds.clamp(0, 300000);
      return Duration(milliseconds: milliseconds);
    }
    return _retryPolicy.delayFor(_failureCount, randomValue: _randomValue());
  }

  bool _serverSupportsEvent(RideEvent event) {
    final compatibility = _compatibility;
    if (compatibility == null) return true;
    final capability = switch (event.type) {
      RideEventType.rideStarted ||
      RideEventType.ridePaused ||
      RideEventType.rideResumed => RelayProtocolCapabilities.rideStart,
      RideEventType.riderLeft => RelayProtocolCapabilities.membership,
      RideEventType.routeRevisionChunk ||
      RideEventType.routeRevisionPublished ||
      RideEventType.routeCleared => RelayProtocolCapabilities.routeRevisions,
      _ => null,
    };
    return capability == null || compatibility.supports(capability);
  }

  void wake() {
    if (!_running || _closed) return;
    if (_syncing) return;
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
