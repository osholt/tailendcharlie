import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/test_control_configuration.dart';

/// Whether the test-control surface is accepting requests, and the token that
/// authenticates them.
///
/// Three things have to be true for a request to be served, and keeping them in
/// one place makes the gate auditable:
/// [TestControlConfiguration.enabled] at compile time, [isOn] at runtime, and a
/// matching [token] on the request.
///
/// ## Both values come from the iOS Settings app
///
/// Neither the switch nor the token is set inside the app. Both live in
/// `ios/Runner/Settings.bundle`, so a rider poking around this app finds no
/// control offering to let another machine drive it.
///
/// ## Why the operator supplies the token rather than the app minting one
///
/// The first version minted a random token on every launch and displayed it in
/// the app. That made the surface unusable in practice. Every install, every
/// relaunch and every crash issued a new token, so each one needed a person to
/// open the app, read 32 characters and pass them to whoever was driving - and
/// on iOS the act of leaving the app to send the token suspends it. Setting up
/// two phones took five attempts, and none of the failures had anything to do
/// with the ride under test.
///
/// An operator-supplied token fixes that at the root. It survives restarts,
/// reinstalls and suspension; it can be agreed in advance and written down once;
/// and it means a phone can be handed to a tester who never has to read anything
/// back. Restart, force-quit and eviction tests become drivable without a human
/// in the loop, which is the difference between testing that behaviour and not.
///
/// The trade is that a person chooses the secret, so [minimumTokenLength] is
/// enforced and the surface refuses to start without a long enough one - a weak
/// token is a worse failure than a missing one, because it looks like it works.
class TestControlController extends ChangeNotifier
    implements ValueListenable<bool> {
  TestControlController._(this._preferences, this._now) {
    _read();
  }

  static const preferenceKey = 'test_control_enabled';
  static const tokenPreferenceKey = 'test_control_token';

  /// Short enough to type into iOS Settings once, long enough not to guess.
  static const minimumTokenLength = 20;

  final SharedPreferences? _preferences;
  final DateTime Function() _now;

  bool _switchedOn = false;
  String? _token;
  DateTime? _lastActivityAt;

  static Future<TestControlController> load({DateTime Function()? now}) async {
    // A build without the compile-time define can never be on, whatever is in
    // storage - including values left by a previously installed driven build.
    if (!TestControlConfiguration.enabled) {
      return TestControlController._(null, now ?? DateTime.now);
    }
    return TestControlController._(
      await SharedPreferences.getInstance(),
      now ?? DateTime.now,
    );
  }

  @override
  bool get value => isOn;

  /// On only when the switch is set **and** a usable token has been supplied.
  /// A switch with no token is not "half on"; it serves nothing.
  bool get isOn => _switchedOn && _token != null;

  /// Whether the switch is set, regardless of the token. Used to explain the
  /// difference to whoever is looking at the phone.
  bool get switchRequested => _switchedOn;

  /// True when the switch is on but the token is missing or too short - the one
  /// state that needs explaining rather than just reporting.
  bool get needsToken => _switchedOn && _token == null;

  /// Never rendered anywhere. The operator set it, so they already have it, and
  /// printing a secret on a screen achieved nothing except making it shoulder-
  /// readable.
  String? get token => _token;

  int get tokenLength => _token?.length ?? 0;

  DateTime? get expiresAt =>
      _lastActivityAt?.add(TestControlConfiguration.defaultIdleTimeout);

  /// Re-reads both preferences. The switch and token live in the iOS Settings
  /// app, and showing that suspends this one, so a foreground resume is the only
  /// moment the app can notice a change. Called from `TestControlSession`.
  Future<void> refresh() async {
    if (!TestControlConfiguration.enabled) return;
    final preferences = _preferences;
    if (preferences == null) return;
    await preferences.reload();
    final wasOn = isOn;
    _read();
    if (isOn != wasOn) notifyListeners();
  }

  void _read() {
    final preferences = _preferences;
    if (preferences == null) return;
    _switchedOn = preferences.getBool(preferenceKey) ?? false;
    final raw = preferences.getString(tokenPreferenceKey)?.trim() ?? '';
    final previous = _token;
    _token = raw.length >= minimumTokenLength ? raw : null;
    if (_token != null && _token != previous) _lastActivityAt = _now();
    if (_token == null) _lastActivityAt = null;
  }

  /// Restarts the idle clock, on a foreground resume.
  ///
  /// iOS suspends a backgrounded app, and a suspended app serves nothing, so
  /// wall-clock time passes with no requests arriving through no fault of the
  /// operator. Counting only time the app could actually have served keeps the
  /// timeout meaningful - a phone left on a bench with the app open still closes
  /// its own port - without expiring a session nobody could reach.
  void touch() {
    if (!isOn) return;
    _lastActivityAt = _now();
  }

  /// Rejects when off, when no token is configured, or when the idle window has
  /// passed. In that last case the surface is treated as closed rather than
  /// rewriting the operator's preference: the switch is theirs, not ours.
  bool authorize(String? candidate) {
    if (!TestControlConfiguration.enabled || !isOn) return false;
    final token = _token;
    if (token == null || candidate == null) return false;
    final deadline = expiresAt;
    if (deadline != null && _now().isAfter(deadline)) return false;
    if (!_constantTimeEquals(token, candidate)) return false;
    _lastActivityAt = _now();
    return true;
  }

  /// Length-independent comparison so a wrong token cannot be narrowed down by
  /// timing. Overkill for a bench tool; cheap enough not to argue about.
  static bool _constantTimeEquals(String a, String b) {
    final left = utf8.encode(a);
    final right = utf8.encode(b);
    var difference = left.length ^ right.length;
    for (var i = 0; i < left.length && i < right.length; i += 1) {
      difference |= left[i] ^ right[i];
    }
    return difference == 0;
  }

  @visibleForTesting
  Future<void> setForTesting({required bool on, String? token}) async {
    await _preferences?.setBool(preferenceKey, on);
    if (token != null) {
      await _preferences?.setString(tokenPreferenceKey, token);
    }
    await refresh();
  }
}
