import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/rider_location.dart';
import '../services/device_location_source.dart';

typedef LocationSampleHandler = Future<void> Function(LocationSample sample);
typedef LocationSampleErrorHandler =
    void Function(Object error, StackTrace stackTrace);

/// User-controlled foreground sampler that forwards fixes to the ride layer.
class ForegroundLocationController extends ChangeNotifier {
  ForegroundLocationController(
    this._source,
    this._onSample, {
    this.onSampleError,
  });

  final DeviceLocationSource _source;
  final LocationSampleHandler _onSample;
  final LocationSampleErrorHandler? onSampleError;
  StreamSubscription<DeviceLocationStatus>? _statusSubscription;
  DeviceLocationStatus _status = const DeviceLocationStatus.idle();
  Future<void> _sampleQueue = Future.value();
  DateTime? _lastForwardedAt;
  bool _sharingRequested = false;
  bool _disposed = false;

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
      _sharingRequested = true;
      final started = await _source.start();
      if (!_disposed) {
        _status = started;
        notifyListeners();
      }
    } else {
      _sharingRequested = false;
    }
  }

  /// Resumes a sharing choice after restart without displaying a new
  /// permission prompt. If access has since been removed, it stays stopped.
  Future<void> resumeIfAuthorized() async {
    if (_disposed) return;
    _statusSubscription ??= _source.statuses.listen(_handleStatus);
    _status = await _source.inspect();
    notifyListeners();
    if (_status.canSample) {
      _sharingRequested = true;
      final started = await _source.start();
      if (!_disposed) {
        _status = started;
        notifyListeners();
      }
    } else {
      _sharingRequested = false;
    }
  }

  Future<void> restartAfterForegroundResume() async {
    if (_disposed || !_sharingRequested) return;
    final restarted = await _source.restart();
    if (!_disposed) {
      _status = restarted;
      notifyListeners();
    }
  }

  Future<void> stop() {
    _sharingRequested = false;
    return _source.stop();
  }

  void _handleStatus(DeviceLocationStatus status) {
    if (_disposed) return;
    _status = status;
    notifyListeners();
    final sample = status.lastSample;
    if (status.state != DeviceLocationState.sampling ||
        sample == null ||
        sample.recordedAt == _lastForwardedAt) {
      return;
    }
    _lastForwardedAt = sample.recordedAt;
    final previous = _sampleQueue;
    _sampleQueue = () async {
      try {
        await previous;
      } on Object {
        // Each fix is independent. A failed ride-state write must never poison
        // the serial queue and suppress every later native GPS update.
      }
      try {
        await _onSample(sample);
      } on Object catch (error, stackTrace) {
        if (!_disposed) onSampleError?.call(error, stackTrace);
      }
    }();
  }

  @override
  void dispose() {
    _disposed = true;
    _sharingRequested = false;
    unawaited(_statusSubscription?.cancel());
    unawaited(_source.dispose());
    super.dispose();
  }
}
