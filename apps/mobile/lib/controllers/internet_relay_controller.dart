import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/ride_event.dart';
import '../domain/ride_session.dart';
import '../internet/internet_relay_worker.dart';

class InternetRelayController extends ChangeNotifier {
  InternetRelayController(this._worker) : _status = _worker.status {
    _statusSubscription = _worker.statuses.listen((status) {
      _status = status;
      notifyListeners();
    });
  }

  final InternetRelayWorker _worker;
  late final StreamSubscription<InternetRelayStatus> _statusSubscription;
  InternetRelayStatus _status;

  InternetRelayStatus get status => _status;
  Stream<RideEvent> get receivedEvents => _worker.receivedEvents;

  /// Whether the negotiated relay contract can carry [capability].
  ///
  /// Null until the first negotiation, so a feature whose whole point is a
  /// relayed event can say "not checked yet" rather than guessing. Used by the
  /// leader-assigned TEC role and the leader-visible rejoin route (#128) to name
  /// the limitation instead of appearing to have worked.
  bool? supportsCapability(String capability) =>
      _worker.supportsCapability(capability);

  Future<void> start(RideSession session) => _worker.start(session);

  void wake() => _worker.wake();

  Future<void> synchronizeNow() => _worker.synchronizeNow();

  Future<void> stop() => _worker.stop();

  Future<void> close() async {
    await _statusSubscription.cancel();
    await _worker.close();
    dispose();
  }
}
