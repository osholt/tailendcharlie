import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/rider_location.dart';
import '../services/device_location_source.dart';

typedef LocationSampleHandler = Future<void> Function(LocationSample sample);

/// User-controlled foreground sampler that forwards fixes to the ride layer.
class ForegroundLocationController extends ChangeNotifier {
  ForegroundLocationController(this._source, this._onSample);

  final DeviceLocationSource _source;
  final LocationSampleHandler _onSample;
  StreamSubscription<DeviceLocationStatus>? _statusSubscription;
  DeviceLocationStatus _status = const DeviceLocationStatus.idle();
  Future<void> _sampleQueue = Future.value();
  DateTime? _lastForwardedAt;

  DeviceLocationStatus get status => _status;
  bool get sharing => status.state == DeviceLocationState.sampling;
  LocationSample? get activeSample => sharing ? status.lastSample : null;

  Future<void> initialize() async {
    _statusSubscription ??= _source.statuses.listen(_handleStatus);
    _status = await _source.inspect();
    notifyListeners();
  }

  /// Must be invoked by an explicit user action.
  Future<void> requestAndStart() async {
    _statusSubscription ??= _source.statuses.listen(_handleStatus);
    final access = await _source.requestAccess();
    _status = access;
    notifyListeners();
    if (access.canSample) {
      await _source.start();
    }
  }

  /// Resumes a sharing choice after restart without displaying a new
  /// permission prompt. If access has since been removed, it stays stopped.
  Future<void> resumeIfAuthorized() async {
    _statusSubscription ??= _source.statuses.listen(_handleStatus);
    _status = await _source.inspect();
    notifyListeners();
    if (_status.canSample) {
      _status = await _source.start();
      notifyListeners();
    }
  }

  Future<void> stop() => _source.stop();

  Future<void> _handleStatus(DeviceLocationStatus status) async {
    _status = status;
    notifyListeners();
    final sample = status.lastSample;
    if (status.state != DeviceLocationState.sampling ||
        sample == null ||
        sample.recordedAt == _lastForwardedAt) {
      return;
    }
    _lastForwardedAt = sample.recordedAt;
    _sampleQueue = _sampleQueue.then((_) => _onSample(sample));
    await _sampleQueue;
  }

  @override
  void dispose() {
    unawaited(_statusSubscription?.cancel());
    unawaited(_source.dispose());
    super.dispose();
  }
}
