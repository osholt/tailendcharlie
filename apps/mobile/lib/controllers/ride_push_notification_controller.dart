import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/ride_session.dart';
import '../internet/push_registration_client.dart';

enum PushPermissionState { unknown, granted, denied, unavailable }

/// The `category` the relay puts in a push's data.
///
/// An open string on purpose: the relay may add categories before every phone
/// knows them, and a phone must open the ride for one it has never heard of
/// rather than refuse it (#881).
abstract final class PushCategory {
  static const safety = 'safety';

  /// A leader's one-tap broadcast to the group (#854): "Pull over".
  static const leaderBroadcast = 'leaderBroadcast';

  /// A rider's one-tap alert (#849).
  static const groupAlert = 'groupAlert';
}

class PushOpenRequest {
  const PushOpenRequest({
    required this.rideId,
    required this.eventId,
    required this.category,
  });

  final String rideId;
  final String eventId;
  final String category;

  /// Whether this is a leader's broadcast or a rider's alert.
  ///
  /// Both are drawn on the map - the quick-message banner and the alert border -
  /// so that is where a tap on either belongs (#881). Builds before this one do
  /// not know the two categories and open the ride list instead, which is safe.
  bool get isGroupInstruction =>
      category == PushCategory.leaderBroadcast ||
      category == PushCategory.groupAlert;
}

class PushTokenResult {
  const PushTokenResult({required this.permission, this.token});

  final PushPermissionState permission;
  final DevicePushToken? token;
}

abstract interface class PushTokenSource {
  bool get isConfigured;
  Stream<DevicePushToken> get tokenRotations;
  Stream<PushOpenRequest> get openedNotifications;

  Future<PushTokenResult> requestPermissionAndToken();

  Future<PushTokenResult> currentPermissionAndToken();

  Future<void> close();
}

class RidePushNotificationController extends ChangeNotifier
    with WidgetsBindingObserver {
  RidePushNotificationController({
    required this.tokenSource,
    required this.registrationApi,
    required SharedPreferences preferencesStore,
  }) : _preferencesStore = preferencesStore,
       _preferences = PushPreferences(
         safety: preferencesStore.getBool(_safetyKey) ?? true,
         status: preferencesStore.getBool(_statusKey) ?? true,
         administrative: preferencesStore.getBool(_administrativeKey) ?? true,
       ) {
    WidgetsBinding.instance.addObserver(this);
  }

  static const _safetyKey = 'push_preferences_safety_v1';
  static const _statusKey = 'push_preferences_status_v1';
  static const _administrativeKey = 'push_preferences_administrative_v1';

  final PushTokenSource tokenSource;
  final PushRegistrationApi registrationApi;
  final SharedPreferences _preferencesStore;
  final StreamController<PushOpenRequest> _opened =
      StreamController.broadcast();
  StreamSubscription<DevicePushToken>? _rotationSubscription;
  StreamSubscription<PushOpenRequest>? _openSubscription;
  RideSession? _session;
  PushPreferences _preferences;
  PushPermissionState _permission = PushPermissionState.unknown;
  String? _statusMessage;
  bool _busy = false;
  bool _closed = false;

  PushPreferences get preferences => _preferences;
  PushPermissionState get permission => _permission;
  String? get statusMessage => _statusMessage;
  bool get available => tokenSource.isConfigured;
  bool get busy => _busy;
  Stream<PushOpenRequest> get openedNotifications => _opened.stream;

  Future<void> start(RideSession session) async {
    if (_closed || _session?.rideId == session.rideId) return;
    _session = session;
    if (!tokenSource.isConfigured) {
      await _revokeSilently(session);
      _permission = PushPermissionState.unavailable;
      _statusMessage =
          'Push notifications are not configured for this build. In-app alerts remain available.';
      notifyListeners();
      return;
    }
    _rotationSubscription ??= tokenSource.tokenRotations.listen(
      _registerRotatedToken,
    );
    _openSubscription ??= tokenSource.openedNotifications.listen(_opened.add);
    _busy = true;
    notifyListeners();
    try {
      final result = await tokenSource.requestPermissionAndToken();
      _permission = result.permission;
      if (result.token case final token?) {
        await registrationApi.register(
          session: session,
          token: token,
          preferences: _preferences,
        );
        _statusMessage =
            'Urgent background ride alerts are enabled. Delivery is best-effort and is not an emergency-service substitute.';
      } else if (result.permission == PushPermissionState.denied) {
        await _revokeSilently(session);
        _statusMessage =
            'Notifications are blocked by system settings. In-app alerts still work while Tail End Charlie is open.';
      } else {
        _statusMessage =
            'A push token is not available yet. Tail End Charlie will retry when the app resumes.';
      }
    } on Object {
      _statusMessage =
          'Notification registration is temporarily unavailable. Durable in-app alerts are unaffected.';
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> updatePreferences({
    required bool safety,
    required bool status,
    required bool administrative,
  }) async {
    _preferences = PushPreferences(
      safety: safety,
      status: status,
      administrative: administrative,
    );
    await Future.wait([
      _preferencesStore.setBool(_safetyKey, safety),
      _preferencesStore.setBool(_statusKey, status),
      _preferencesStore.setBool(_administrativeKey, administrative),
    ]);
    notifyListeners();
    await refreshRegistration();
  }

  Future<void> refreshRegistration() async {
    final session = _session;
    if (_closed || session == null || !tokenSource.isConfigured || _busy) {
      return;
    }
    _busy = true;
    notifyListeners();
    try {
      final result = await tokenSource.currentPermissionAndToken();
      _permission = result.permission;
      if (result.token case final token?) {
        await registrationApi.register(
          session: session,
          token: token,
          preferences: _preferences,
        );
        _statusMessage = 'Notification token and ride role are up to date.';
      } else if (result.permission == PushPermissionState.denied) {
        await _revokeSilently(session);
        _statusMessage =
            'Notifications are blocked by system settings. The ride registration was removed.';
      } else {
        _statusMessage =
            'A push token is not available yet. Tail End Charlie will retry when the app resumes.';
      }
    } on Object {
      _statusMessage =
          'Notification refresh failed; durable in-app alerts remain available.';
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> stop({bool revoke = true}) async {
    final session = _session;
    _session = null;
    if (revoke && session != null) {
      await _revokeSilently(session);
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    WidgetsBinding.instance.removeObserver(this);
    await _rotationSubscription?.cancel();
    await _openSubscription?.cancel();
    await tokenSource.close();
    registrationApi.close();
    await _opened.close();
    dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(refreshRegistration());
    }
  }

  Future<void> _registerRotatedToken(DevicePushToken token) async {
    final session = _session;
    if (session == null || _closed) return;
    try {
      await registrationApi.register(
        session: session,
        token: token,
        preferences: _preferences,
      );
      _statusMessage = 'Notification token was refreshed.';
      notifyListeners();
    } on Object {
      _statusMessage =
          'Notification token refresh failed; in-app alerts remain available.';
      notifyListeners();
    }
  }

  Future<void> _revokeSilently(RideSession session) async {
    try {
      await registrationApi.revoke(session);
    } on Object {
      // The registration remains ride-scoped and the server excludes
      // departed/expired membership even if best-effort revocation fails.
    }
  }
}
