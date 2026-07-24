import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/observer_grant_store.dart';
import '../domain/ride_session.dart';
import '../internet/internet_relay_client.dart';
import '../internet/observer_access_client.dart';

class ObserverAccessController extends ChangeNotifier {
  ObserverAccessController(
    this._api,
    this._store, {
    DateTime Function()? clock,
    this.publishInterval = const Duration(seconds: 10),
  }) : _clock = clock ?? DateTime.now;

  final ObserverAccessApi _api;
  final ObserverGrantStore _store;
  final DateTime Function() _clock;
  final Duration publishInterval;
  RideSession? _session;
  List<ObserverGrantCredentials> _credentials = const [];
  ObserverInvite? _latestInvite;
  ObserverPublishedSnapshot? _pendingSnapshot;
  Future<void>? _publishLoop;
  Timer? _publishTimer;
  Future<void> _grantMutationChain = Future.value();
  DateTime? _lastSnapshotGeneratedAt;
  DateTime? _lastDispatchedAt;
  DateTime? _lastDispatchedStatusAt;
  DateTime? _lastDispatchedAssistanceAt;
  DateTime? _retryNotBefore;
  int _retryAttempt = 0;
  ObserverLocalAssistanceState? _localAssistanceState;
  bool _busy = false;
  String? _errorMessage;

  List<ObserverGrant> get grants =>
      List.unmodifiable(_credentials.map((value) => value.grant));
  ObserverInvite? get latestInvite => _latestInvite;
  bool get busy => _busy;
  String? get errorMessage => _errorMessage;
  bool get configured => _api.configuration.configurationError == null;
  bool get hasActiveGrants =>
      _credentials.any((value) => value.grant.isActiveAt(_clock()));
  ObserverPublishedAssistance? get localAssistance =>
      _localAssistanceState?.assistance;
  DateTime get localAssistanceUpdatedAt =>
      _localAssistanceState?.updatedAt ?? _session?.joinedAt ?? _clock();

  DateTime nextSnapshotGeneratedAt() {
    final now = _clock().toUtc();
    final last = _lastSnapshotGeneratedAt;
    final generatedAt = last == null || now.isAfter(last)
        ? now
        : last.add(const Duration(microseconds: 1));
    _lastSnapshotGeneratedAt = generatedAt;
    return generatedAt;
  }

  Future<void> attach(RideSession session) async {
    if (_session?.rideId == session.rideId) {
      _session = session;
      return;
    }
    _session = session;
    _lastSnapshotGeneratedAt = null;
    _lastDispatchedAt = null;
    _lastDispatchedStatusAt = null;
    _lastDispatchedAssistanceAt = null;
    final loaded = await _store.load(session.rideId);
    _credentials = List.unmodifiable(
      loaded.where((value) => value.grant.isActiveAt(_clock())),
    );
    if (_credentials.isEmpty) {
      _localAssistanceState = null;
      await _store.deleteLocalAssistance(session.rideId);
    } else {
      _localAssistanceState = await _store.loadLocalAssistance(session.rideId);
    }
    if (_credentials.length != loaded.length) await _persist();
    notifyListeners();
  }

  void updateSession(RideSession session) {
    if (_session?.rideId != session.rideId) return;
    _session = session;
  }

  Future<void> refresh() async {
    if (_session == null || _busy) return;
    await _run(() async {
      final retained = <ObserverGrantCredentials>[];
      for (final credentials in _credentials) {
        if (!credentials.grant.isActiveAt(_clock())) continue;
        try {
          final grant = await _api.inspect(credentials);
          retained.add(
            ObserverGrantCredentials(
              grant: grant,
              managementToken: credentials.managementToken,
              publisherToken: credentials.publisherToken,
              observerToken: credentials.observerToken,
            ),
          );
        } on InternetRelayException catch (error) {
          if (error.statusCode != 404) rethrow;
        }
      }
      await _serializeGrantMutation(() async {
        final reviewed = {for (final value in retained) value.grant.id: value};
        _credentials = List.unmodifiable(
          _credentials
              .where((value) => reviewed.containsKey(value.grant.id))
              .map((value) => reviewed[value.grant.id]!),
        );
        await _persist();
      });
    });
  }

  Future<void> create({
    required String label,
    required Duration duration,
  }) async {
    final session = _session;
    if (session == null || _busy) return;
    await _run(() async {
      final credentials = await _api.create(
        session,
        label: label,
        duration: duration,
      );
      try {
        await _serializeGrantMutation(() async {
          _credentials = List<ObserverGrantCredentials>.unmodifiable([
            credentials,
            ..._credentials.where(
              (value) => value.grant.id != credentials.grant.id,
            ),
          ]);
          await _persist();
        });
      } on Object {
        await _serializeGrantMutation(() async {
          _credentials = List.unmodifiable(
            _credentials.where(
              (value) => value.grant.id != credentials.grant.id,
            ),
          );
          await _persist();
        });
        try {
          await _api.revoke(credentials);
        } on Object {
          // The server-side grant will still expire automatically. Never
          // expose its read token if secure local persistence failed.
        }
        rethrow;
      }
      _latestInvite = ObserverInvite(
        credentials: credentials,
        shareUri: _api.shareUri(credentials),
      );
    });
  }

  Future<void> revoke(String grantId) async {
    if (_busy) return;
    final credentials = _credentials
        .where((value) => value.grant.id == grantId)
        .firstOrNull;
    if (credentials == null) return;
    await _run(() async {
      await _api.revoke(credentials);
      await _serializeGrantMutation(() async {
        _credentials = List.unmodifiable(
          _credentials.where((value) => value.grant.id != grantId),
        );
        await _persist();
        if (_latestInvite?.grant.id == grantId) _latestInvite = null;
      });
    });
  }

  Future<void> recordLocalAssistance(String? kind) async {
    if (!hasActiveGrants) return;
    if (kind != null && kind != 'assistance' && kind != 'emergencyStop') {
      throw ArgumentError.value(kind, 'kind', 'Unsupported assistance state');
    }
    final observedNow = _clock();
    final previousUpdatedAt = _localAssistanceState?.updatedAt;
    final now =
        previousUpdatedAt == null || observedNow.isAfter(previousUpdatedAt)
        ? observedNow
        : previousUpdatedAt.add(const Duration(microseconds: 1));
    final assistance = kind == null
        ? null
        : ObserverPublishedAssistance(kind: kind, reportedAt: now);
    await _serializeGrantMutation(() async {
      final session = _session;
      if (session == null) return;
      _localAssistanceState = ObserverLocalAssistanceState(
        updatedAt: now,
        assistance: assistance,
      );
      await _store.saveLocalAssistance(session.rideId, _localAssistanceState!);
    });
    notifyListeners();
  }

  void publishSnapshot(ObserverPublishedSnapshot snapshot) {
    _pendingSnapshot = snapshot;
    _ensurePublishing();
  }

  void _ensurePublishing({bool force = false}) {
    final snapshot = _pendingSnapshot;
    if (snapshot == null || _publishLoop != null) return;
    final immediate =
        _lastDispatchedAt == null ||
        snapshot.statusUpdatedAt != _lastDispatchedStatusAt ||
        snapshot.assistanceUpdatedAt != _lastDispatchedAssistanceAt;
    final retryDelay = _retryNotBefore?.difference(_clock());
    if (!force &&
        !immediate &&
        retryDelay != null &&
        retryDelay > Duration.zero) {
      _schedulePublish(retryDelay);
      return;
    }
    final elapsed = _lastDispatchedAt == null
        ? publishInterval
        : _clock().difference(_lastDispatchedAt!);
    if (!force && !immediate && elapsed < publishInterval) {
      _schedulePublish(publishInterval - elapsed);
      return;
    }
    _publishTimer?.cancel();
    _publishTimer = null;
    final loop = _publishOne();
    _publishLoop = loop;
    unawaited(
      loop.then<void>(
        (_) {
          _publishLoop = null;
          _ensurePublishing();
        },
        onError: (Object error, StackTrace stackTrace) {
          _publishLoop = null;
          if (kDebugMode) {
            debugPrint('Observer snapshot publish failed: $error');
          }
          _ensurePublishing();
        },
      ),
    );
  }

  void _schedulePublish(Duration delay) {
    _publishTimer ??= Timer(delay, () {
      _publishTimer = null;
      _ensurePublishing(force: true);
    });
  }

  Future<void> _publishOne() async {
    final snapshot = _pendingSnapshot!;
    _pendingSnapshot = null;
    _lastDispatchedAt = _clock();
    _lastDispatchedStatusAt = snapshot.statusUpdatedAt;
    _lastDispatchedAssistanceAt = snapshot.assistanceUpdatedAt;
    final active = _credentials
        .where((value) => value.grant.isActiveAt(_clock()))
        .toList(growable: false);
    final unavailableIds = <String>{};
    var retryableFailure = false;
    Duration? requestedRetryDelay;
    for (var index = 0; index < active.length; index += 4) {
      final results = await Future.wait(
        active.skip(index).take(4).map((credentials) async {
          try {
            await _api.publish(credentials, snapshot);
            return (
              credentials: credentials,
              unavailable: false,
              retryable: false,
              retryAfter: null as Duration?,
            );
          } on InternetRelayException catch (error) {
            return (
              credentials: credentials,
              unavailable: error.statusCode == 404,
              retryable:
                  error.statusCode != 404 &&
                  error.statusCode != 409 &&
                  error.retryable,
              retryAfter: error.retryAfter,
            );
          } on Object {
            return (
              credentials: credentials,
              unavailable: false,
              retryable: true,
              retryAfter: null as Duration?,
            );
          }
        }),
      );
      for (final result in results) {
        if (result.unavailable) {
          unavailableIds.add(result.credentials.grant.id);
        }
        if (result.retryable) {
          retryableFailure = true;
          final retryAfter = result.retryAfter;
          if (retryAfter != null &&
              (requestedRetryDelay == null ||
                  retryAfter > requestedRetryDelay)) {
            requestedRetryDelay = retryAfter;
          }
        }
      }
    }
    if (unavailableIds.isNotEmpty || active.length != _credentials.length) {
      await _serializeGrantMutation(() async {
        final before = _credentials.length;
        _credentials = List.unmodifiable(
          _credentials.where(
            (value) =>
                value.grant.isActiveAt(_clock()) &&
                !unavailableIds.contains(value.grant.id),
          ),
        );
        if (_credentials.length != before) {
          await _persist();
          notifyListeners();
        }
      });
    }
    if (retryableFailure &&
        _credentials.any((value) => value.grant.isActiveAt(_clock()))) {
      _pendingSnapshot ??= snapshot;
      _retryAttempt = _retryAttempt >= 5 ? 5 : _retryAttempt + 1;
      final exponentialSeconds = 5 * (1 << (_retryAttempt - 1));
      final requestedSeconds = requestedRetryDelay?.inSeconds ?? 0;
      final seconds = requestedSeconds > exponentialSeconds
          ? requestedSeconds
          : exponentialSeconds;
      final boundedSeconds = seconds < 1
          ? 1
          : seconds > 60
          ? 60
          : seconds;
      _retryNotBefore = _clock().add(Duration(seconds: boundedSeconds));
    } else {
      _retryAttempt = 0;
      _retryNotBefore = null;
    }
  }

  @visibleForTesting
  Future<void> waitForPendingPublishes() async {
    while (_publishLoop != null) {
      final loop = _publishLoop!;
      await loop;
    }
  }

  @visibleForTesting
  Future<void> flushPendingSnapshot() async {
    _publishTimer?.cancel();
    _publishTimer = null;
    _ensurePublishing(force: true);
    await waitForPendingPublishes();
  }

  void clearError() {
    _errorMessage = null;
    notifyListeners();
  }

  Future<void> _persist() async {
    final session = _session;
    if (session == null) return;
    if (_credentials.isEmpty) {
      await _store.delete(session.rideId);
      _localAssistanceState = null;
      await _store.deleteLocalAssistance(session.rideId);
    } else {
      await _store.save(session.rideId, _credentials);
    }
  }

  Future<void> _serializeGrantMutation(Future<void> Function() action) {
    final next = _grantMutationChain
        .catchError((Object _) {
          // A failed secure-storage operation must not deadlock future grant
          // cleanup, creation or revocation attempts.
        })
        .then((_) => action());
    _grantMutationChain = next;
    return next;
  }

  Future<void> _run(Future<void> Function() action) async {
    _busy = true;
    _errorMessage = null;
    notifyListeners();
    try {
      await action();
    } on Object catch (error) {
      _errorMessage = error.toString().replaceFirst(
        'InternetRelayException: ',
        '',
      );
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _publishTimer?.cancel();
    _api.close();
    super.dispose();
  }
}
