import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/test_control_configuration.dart';

/// Whether the test-control surface is accepting requests, and the token that
/// authenticates them.
///
/// Deliberately *not* a plain bool. Three things have to be true for a request
/// to be served, and keeping them in one place makes the gate auditable:
/// [TestControlConfiguration.enabled] at compile time, [isOn] at runtime, and a
/// matching [token] on the request.
///
/// The enabled state persists across launches because the field-test sequences
/// that need it include app restarts - step 9 of `docs/field-test-plan.md`
/// restarts the app mid-ride, and a toggle that cleared on launch would make
/// that step undrivable. The token does **not** persist: a restart mints a new
/// one, so a token that leaked from an old session is dead.
class TestControlController extends ChangeNotifier
    implements ValueListenable<bool> {
  TestControlController._(this._preferences, this._isOn, this._now);

  static const preferenceKey = 'test_control_enabled';

  final SharedPreferences? _preferences;
  final DateTime Function() _now;

  bool _isOn;
  String? _token;
  DateTime? _lastRequestAt;

  static Future<TestControlController> load({DateTime Function()? now}) async {
    // A build without the compile-time define can never be on, whatever is in
    // storage - including a stored `true` from a previous instrumented build
    // installed over the top of it.
    if (!TestControlConfiguration.enabled) {
      return TestControlController._(null, false, now ?? DateTime.now);
    }
    final preferences = await SharedPreferences.getInstance();
    final controller = TestControlController._(
      preferences,
      preferences.getBool(preferenceKey) ?? false,
      now ?? DateTime.now,
    );
    if (controller._isOn) controller._mintToken();
    return controller;
  }

  @override
  bool get value => _isOn;

  bool get isOn => _isOn;

  /// The bearer token for this session, or null while off. Shown in the app so
  /// the operator can copy it into their tooling; never logged, and never sent
  /// anywhere by the app itself.
  String? get token => _token;

  /// When the surface will switch itself off if nothing else arrives.
  DateTime? get expiresAt =>
      _lastRequestAt?.add(TestControlConfiguration.defaultIdleTimeout);

  /// Restarts the idle clock. Called when the app comes back to the foreground.
  ///
  /// This exists because of a real failure, and the reasoning matters. iOS
  /// suspends a backgrounded app, and a suspended app serves nothing - so
  /// wall-clock time passes with no requests arriving through no fault of the
  /// person running the test. Setting up a two-phone run means leaving the app to
  /// copy a token, which backgrounds it; by the time both phones were ready, more
  /// than [TestControlConfiguration.defaultIdleTimeout] had elapsed and the first
  /// real request tripped the expiry and switched the surface off. The toggle went
  /// off silently, and from the outside that was indistinguishable from a crash.
  ///
  /// Counting only time the app could actually have served a request keeps the
  /// idle timeout meaningful - a phone left on a bench with the app open still
  /// closes its own port - without punishing the operator for the OS suspending
  /// it. Deliberately not called from `/v1/health`: liveness is unauthenticated,
  /// and letting an unauthenticated caller hold the session open indefinitely
  /// would defeat the timeout it is protecting.
  void touch() {
    if (!_isOn) return;
    _lastRequestAt = _now();
  }

  Future<void> turnOn() async {
    if (!TestControlConfiguration.enabled) return;
    if (_isOn) return;
    _isOn = true;
    _mintToken();
    _lastRequestAt = _now();
    await _preferences?.setBool(preferenceKey, true);
    notifyListeners();
  }

  Future<void> turnOff() async {
    if (!_isOn) return;
    _isOn = false;
    _token = null;
    _lastRequestAt = null;
    await _preferences?.setBool(preferenceKey, false);
    notifyListeners();
  }

  /// Constant-time-ish comparison of [candidate] against [token], and a refresh
  /// of the idle deadline when it matches.
  ///
  /// Rejects when off, when no token has been minted, or when the idle timeout
  /// has already passed - in that last case it also turns the surface off, so an
  /// abandoned session closes its own port rather than waiting for a timer.
  bool authorize(String? candidate) {
    if (!TestControlConfiguration.enabled || !_isOn) return false;
    final token = _token;
    if (token == null || candidate == null) return false;
    final deadline = expiresAt;
    if (deadline != null && _now().isAfter(deadline)) {
      turnOff();
      return false;
    }
    if (!_constantTimeEquals(token, candidate)) return false;
    _lastRequestAt = _now();
    return true;
  }

  void _mintToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(24, (_) => random.nextInt(256));
    _token = base64Url.encode(bytes).replaceAll('=', '');
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
}
