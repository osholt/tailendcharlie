import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../domain/event_store.dart';
import '../domain/quick_message.dart';
import '../domain/ride_event.dart';
import '../domain/ride_role.dart';
import '../domain/ride_session.dart';
import '../domain/session_store.dart';
import '../services/nearby_bridge.dart';

typedef Clock = DateTime Function();
typedef IdFactory = String Function();

class RideController extends ChangeNotifier {
  RideController(
    this._eventStore,
    this._sessionStore,
    this._nearbyBridge, {
    Clock? clock,
    IdFactory? idFactory,
    Random? random,
  }) : _clock = clock ?? DateTime.now,
       _idFactory = idFactory ?? const Uuid().v7,
       _random = random ?? Random.secure();

  static const _codeAlphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

  final EventStore _eventStore;
  final SessionStore _sessionStore;
  final NearbyBridge _nearbyBridge;
  final Clock _clock;
  final IdFactory _idFactory;
  final Random _random;

  RideSession? _session;
  List<RideEvent> _events = const [];
  NearbyCapabilities _nearbyCapabilities =
      const NearbyCapabilities.unavailable();
  bool _busy = false;
  String? _errorMessage;
  RideRole? _roleBeforeMarker;

  RideSession? get session => _session;
  EventStore get eventStore => _eventStore;
  List<RideEvent> get events => List.unmodifiable(_events);
  NearbyCapabilities get nearbyCapabilities => _nearbyCapabilities;
  bool get busy => _busy;
  String? get errorMessage => _errorMessage;
  bool get hasActiveRide => _session != null;

  bool get markerActive {
    var active = false;
    for (final event in _events) {
      if (event.type == RideEventType.markerStarted) {
        active = true;
      } else if (event.type == RideEventType.markerEnded) {
        active = false;
      }
    }
    return active;
  }

  int get markerPassCount {
    final uniqueRiders = <String>{};
    if (!markerActive) {
      return 0;
    }
    for (final event in _events.where(
      (event) => event.type == RideEventType.markerPass,
    )) {
      final riderId = event.payload['riderId'];
      if (riderId is String) {
        uniqueRiders.add(riderId);
      }
    }
    return uniqueRiders.length;
  }

  int get pendingEventCount =>
      _events.where((event) => !event.acknowledged).length;

  String get inviteText {
    final activeSession = _requireSession();
    final uri = Uri(
      scheme: 'riderelay',
      host: 'join',
      queryParameters: {
        'code': activeSession.rideCode,
        'secret': activeSession.inviteSecret,
      },
    );
    return 'Join my Ride Relay group with code '
        '${activeSession.rideCode}\n$uri';
  }

  Future<void> initialize() async {
    _nearbyCapabilities = await _nearbyBridge.capabilities();
    _session = await _sessionStore.load();
    final activeSession = _session;
    if (activeSession != null) {
      _events = await _eventStore.eventsForRide(activeSession.rideId);
    }
    notifyListeners();
  }

  Future<void> reloadEvents() async {
    final activeSession = _session;
    if (activeSession == null) {
      return;
    }
    _events = await _eventStore.eventsForRide(activeSession.rideId);
    notifyListeners();
  }

  Future<void> createRide(String displayName) async {
    await _run(() async {
      final now = _clock();
      final session = RideSession(
        rideId: _idFactory(),
        rideCode: _generateCode(),
        inviteSecret: '${_idFactory()}${_idFactory()}',
        localRiderId: _idFactory(),
        displayName: _normaliseName(displayName),
        role: RideRole.lead,
        joinedAt: now,
      );
      _session = session;
      await _sessionStore.save(session);
      await _record(
        type: RideEventType.rideCreated,
        payload: {
          'displayName': session.displayName,
          'role': session.role.name,
        },
      );
    });
  }

  Future<void> joinRide(String code, String displayName) async {
    await _run(() async {
      final normalisedCode = code.trim().toUpperCase();
      if (normalisedCode.length != 6 ||
          normalisedCode
              .split('')
              .any((character) => !_codeAlphabet.contains(character))) {
        throw const FormatException('Enter a valid six-character ride code.');
      }
      final now = _clock();
      final session = RideSession(
        rideId: 'pending-$normalisedCode',
        rideCode: normalisedCode,
        inviteSecret: '',
        localRiderId: _idFactory(),
        displayName: _normaliseName(displayName),
        role: RideRole.rider,
        joinedAt: now,
      );
      _session = session;
      await _sessionStore.save(session);
      await _record(
        type: RideEventType.riderJoined,
        payload: {
          'displayName': session.displayName,
          'role': session.role.name,
        },
      );
    });
  }

  Future<void> setRole(RideRole role) async {
    await _run(() async {
      final activeSession = _requireSession();
      final updated = activeSession.copyWith(role: role);
      _session = updated;
      await _sessionStore.save(updated);
      await _record(
        type: RideEventType.roleChanged,
        payload: {'role': role.name},
      );
    });
  }

  Future<void> sendQuickMessage(QuickMessage message) async {
    await _run(() async {
      await _record(
        type: RideEventType.statusMessage,
        priority: message.priority,
        expiresAt: _clock().add(const Duration(hours: 2)),
        payload: {'message': message.name, 'label': message.label},
      );
    });
  }

  Future<void> startMarker() async {
    if (markerActive) {
      return;
    }
    await _run(() async {
      final activeSession = _requireSession();
      _roleBeforeMarker = activeSession.role;
      final updated = activeSession.copyWith(role: RideRole.marker);
      _session = updated;
      await _sessionStore.save(updated);
      await _record(
        type: RideEventType.markerStarted,
        priority: EventPriority.important,
        payload: {'mode': 'manual'},
      );
    });
  }

  Future<void> recordMarkerPass(String riderId) async {
    if (!markerActive ||
        _events.any(
          (event) =>
              event.type == RideEventType.markerPass &&
              event.payload['riderId'] == riderId,
        )) {
      return;
    }
    await _run(() async {
      await _record(
        type: RideEventType.markerPass,
        payload: {'riderId': riderId},
      );
    });
  }

  Future<void> endMarker() async {
    if (!markerActive) {
      return;
    }
    await _run(() async {
      await _record(
        type: RideEventType.markerEnded,
        priority: EventPriority.important,
        payload: {'uniquePasses': markerPassCount},
      );
      final activeSession = _requireSession();
      final updated = activeSession.copyWith(
        role: _roleBeforeMarker ?? RideRole.rider,
      );
      _session = updated;
      _roleBeforeMarker = null;
      await _sessionStore.save(updated);
    });
  }

  Future<void> endRide() async {
    await _run(() async {
      await _record(
        type: RideEventType.rideEnded,
        priority: EventPriority.important,
        payload: const {},
      );
      await _sessionStore.clear();
      _session = null;
      _events = const [];
      _roleBeforeMarker = null;
    });
  }

  void clearError() {
    _errorMessage = null;
    notifyListeners();
  }

  Future<void> _record({
    required RideEventType type,
    required Map<String, Object?> payload,
    EventPriority priority = EventPriority.routine,
    DateTime? expiresAt,
  }) async {
    final activeSession = _requireSession();
    final now = _clock();
    final id = _idFactory();
    final unsignedBody = jsonEncode({
      'id': id,
      'rideId': activeSession.rideId,
      'deviceId': activeSession.localRiderId,
      'type': type.name,
      'priority': priority.name,
      'createdAt': now.toUtc().toIso8601String(),
      'payload': payload,
    });
    final signature = Hmac(
      sha256,
      utf8.encode(activeSession.inviteSecret),
    ).convert(utf8.encode(unsignedBody)).toString();
    final event = RideEvent(
      id: id,
      rideId: activeSession.rideId,
      deviceId: activeSession.localRiderId,
      type: type,
      priority: priority,
      createdAt: now,
      expiresAt: expiresAt,
      payload: payload,
      signature: signature,
    );
    await _eventStore.append(event);
    _events = [..._events, event];
  }

  Future<void> _run(Future<void> Function() operation) async {
    if (_busy) {
      return;
    }
    _busy = true;
    _errorMessage = null;
    notifyListeners();
    try {
      await operation();
    } on FormatException catch (error) {
      _errorMessage = error.message;
    } on Object catch (error, stackTrace) {
      _errorMessage = 'That action could not be saved. Please try again.';
      debugPrint('Ride action failed: $error\n$stackTrace');
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  RideSession _requireSession() {
    final activeSession = _session;
    if (activeSession == null) {
      throw StateError('No active ride');
    }
    return activeSession;
  }

  String _normaliseName(String value) {
    final name = value.trim();
    if (name.isEmpty) {
      throw const FormatException('Enter a rider name.');
    }
    return name.length <= 24 ? name : name.substring(0, 24);
  }

  String _generateCode() => List.generate(
    6,
    (_) => _codeAlphabet[_random.nextInt(_codeAlphabet.length)],
  ).join();

  @override
  void dispose() {
    _eventStore.close();
    super.dispose();
  }
}
