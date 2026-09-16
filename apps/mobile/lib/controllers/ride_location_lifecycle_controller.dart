import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Keeps ride-grade background GPS scoped to a ride that has actually started.
///
/// A prepared ride still gets one position so the gathering map is useful, but
/// it does not need a high-accuracy background stream or Android wake lock. An
/// active ride does: position sharing, recording, route progress and spoken
/// guidance all depend on fixes while the screen is locked or another app is in
/// front.
class RideLocationLifecycleController {
  RideLocationLifecycleController(
    this._stop,
    this._refreshIdleFix,
    this._restartActiveStream,
  );

  final AsyncCallback _stop;
  final AsyncCallback _refreshIdleFix;
  final AsyncCallback _restartActiveStream;
  bool _awayFromForeground = false;

  /// Gives the waiting-to-start map a current position without opening the
  /// ride-grade background stream.
  Future<void> prepareWaitingRideMap() => _refreshIdleFix();

  Future<void> transition(
    AppLifecycleState state, {
    required bool rideStarted,
    required bool rideEnded,
  }) async {
    final rideActive = rideStarted && !rideEnded;
    if (state == AppLifecycleState.resumed) {
      if (!_awayFromForeground) return;
      _awayFromForeground = false;
      if (rideEnded) return;
      if (rideActive) {
        await _restartActiveStream();
      } else {
        await _refreshIdleFix();
      }
      return;
    }

    // iOS reports inactive -> hidden -> paused for one trip. Stopping the same
    // stream three times adds plugin traffic during the suspension window.
    if (_awayFromForeground) return;
    _awayFromForeground = true;
    if (!rideActive) await _stop();
  }
}
