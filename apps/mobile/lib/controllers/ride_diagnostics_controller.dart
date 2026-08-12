import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/ride_diagnostics_log_store.dart';
import '../services/ride_diagnostics_configuration.dart';

/// Whether this ride is being recorded for diagnostics (#419).
///
/// The second of the two gates. [RideDiagnosticsConfiguration.enabled] is the
/// first and decides whether the code is in the binary at all; this decides
/// whether it runs, and defaults to **off**.
///
/// ## It refuses to be on in an ordinary build
///
/// [isOn] reads `false` whenever the define is absent, whatever storage says. A
/// phone that carried an instrumented build, was switched on, and then took an
/// ordinary build over the top must not quietly keep recording — the stored
/// `true` is still there, and only this check stands between it and a store build
/// writing a location log. `TestControlController` guards its own switch the same
/// way and for the same reason.
class RideDiagnosticsController extends ChangeNotifier
    implements ValueListenable<bool> {
  RideDiagnosticsController._(this._preferences, this.logStore) {
    _switchedOn = _preferences?.getBool(preferenceKey) ?? false;
  }

  static const preferenceKey = 'ride_diagnostics_recording_enabled';

  final SharedPreferences? _preferences;
  bool _switchedOn = false;

  /// Where recorded logs are kept between rides (#456).
  ///
  /// Hung off the controller rather than plumbed separately because this is
  /// already carried to every surface that offers the switch — and the fault
  /// being fixed was precisely that one of several doors to the same room was
  /// left unwired (#439, and again here). A new parameter threaded through the
  /// same widgets would be a third chance to make that mistake.
  ///
  /// Null in an ordinary build, where nothing may be recorded and so nothing may
  /// be stored.
  final RideDiagnosticsLogStore? logStore;

  static Future<RideDiagnosticsController> load() async {
    SharedPreferences? preferences;
    try {
      preferences = await SharedPreferences.getInstance();
    } catch (_) {
      // A rider whose preferences will not open still gets a ride; they just do
      // not get recording, which is the safe direction to fail in.
      preferences = null;
    }
    RideDiagnosticsLogStore? store;
    if (RideDiagnosticsConfiguration.enabled) {
      try {
        store = await FileRideDiagnosticsLogStore.openDefault();
      } catch (_) {
        // Recording still works and can still be shared from the ride itself;
        // only the keeping-it-afterwards part is lost.
        store = null;
      }
    }
    return RideDiagnosticsController._(preferences, store);
  }

  /// In-memory only, for tests and for a build with no storage.
  factory RideDiagnosticsController.inMemory({
    bool switchedOn = false,
    RideDiagnosticsLogStore? logStore,
  }) {
    final controller = RideDiagnosticsController._(null, logStore);
    controller._switchedOn = switchedOn;
    return controller;
  }

  /// Whether anything should be recorded right now.
  ///
  /// Both gates, in one place, so a caller cannot consult only the one it
  /// remembers.
  bool get isOn => RideDiagnosticsConfiguration.enabled && _switchedOn;

  /// Whether the switch itself can be offered at all.
  bool get isAvailable => RideDiagnosticsConfiguration.enabled;

  @override
  bool get value => isOn;

  Future<void> setEnabled(bool enabled) async {
    if (!RideDiagnosticsConfiguration.enabled) return;
    if (_switchedOn == enabled) return;
    _switchedOn = enabled;
    await _preferences?.setBool(preferenceKey, enabled);
    notifyListeners();
  }
}
