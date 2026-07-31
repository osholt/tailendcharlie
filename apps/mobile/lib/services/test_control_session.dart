import 'dart:async';

import 'package:flutter/widgets.dart';

import '../controllers/test_control_controller.dart';
import 'ride_screen_awake.dart';
import 'test_control_configuration.dart';
import 'test_control_server.dart';

/// Keeps a driven build usable: screen awake while the surface is on, and the
/// idle clock restarted whenever the app could actually serve again.
///
/// Both behaviours exist because a two-phone run kept failing for reasons that
/// had nothing to do with the ride under test:
///
/// - **The screen slept.** A phone that locks lets iOS suspend the app, and a
///   suspended app stops accepting connections. Only one phone was ever awake at
///   a time, so there was never a moment with two reachable surfaces. The
///   active-ride wake lock cannot cover this: it holds the screen *during* a
///   ride, but the driver has to reach both phones **before** the ride exists in
///   order to create and join it, and that pre-ride window is exactly when an
///   idle phone locks.
/// - **The session expired while nobody could talk to it.** Copying the access
///   token means leaving the app, which backgrounds it; the idle timeout then
///   counted suspended time and switched the surface off before the second phone
///   was ready.
///
/// A build that has been explicitly handed to another machine has no reason to
/// sleep, so this holds the screen for as long as the switch is on and releases
/// it the moment it goes off.
class TestControlSession with WidgetsBindingObserver {
  TestControlSession(
    this._control,
    this._server, {
    RideScreenAwakeCoordinator? screenAwake,
  }) : _screenAwake = screenAwake ?? RideScreenAwakeCoordinator();

  final TestControlController _control;
  final TestControlServer _server;
  final RideScreenAwakeCoordinator _screenAwake;

  bool _attached = false;

  /// Starts observing. Inert without the compile-time define, so an ordinary
  /// build registers no observer and holds no wake lock.
  void start() {
    if (!TestControlConfiguration.enabled) return;
    if (_attached) return;
    _attached = true;
    WidgetsBinding.instance.addObserver(this);
    _control.addListener(_onToggleChanged);
    _onToggleChanged();
  }

  Future<void> stop() async {
    if (!_attached) return;
    _attached = false;
    WidgetsBinding.instance.removeObserver(this);
    _control.removeListener(_onToggleChanged);
    await _screenAwake.stop();
    await _server.stop();
  }

  void _onToggleChanged() {
    if (_control.isOn) {
      unawaited(_server.start());
      _screenAwake.start();
    } else {
      unawaited(_server.stop());
      unawaited(_screenAwake.stop());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    // The app can serve again from now, so the idle clock starts again from now.
    // Without this, time spent suspended counts against a timeout the operator
    // had no way to refresh.
    _control.touch();
    // A suspended app's listener does not necessarily survive; re-binding is
    // cheap and start() is a no-op when it is already listening.
    if (_control.isOn) unawaited(_server.start());
  }
}
