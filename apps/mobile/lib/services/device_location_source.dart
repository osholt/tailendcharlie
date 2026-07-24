import 'dart:async';

import 'package:geolocator/geolocator.dart';

import '../domain/geo_point.dart';
import '../domain/rider_location.dart';

enum DeviceLocationState {
  idle,
  serviceDisabled,
  permissionDenied,
  permissionDeniedForever,
  ready,
  sampling,
  failed,
}

class DeviceLocationStatus {
  const DeviceLocationStatus({
    required this.state,
    required this.message,
    this.lastSample,
  });

  const DeviceLocationStatus.idle()
    : state = DeviceLocationState.idle,
      message = 'Location sharing has not been started.',
      lastSample = null;

  final DeviceLocationState state;
  final String message;
  final LocationSample? lastSample;

  bool get canSample =>
      state == DeviceLocationState.ready ||
      state == DeviceLocationState.sampling;
}

enum DeviceLocationPermission { denied, deniedForever, whileInUse, always }

abstract interface class DeviceLocationPlatform {
  Future<bool> isServiceEnabled();

  Future<DeviceLocationPermission> checkPermission();

  Future<DeviceLocationPermission> requestPermission();

  Stream<LocationSample> positionStream();
}

class GeolocatorDeviceLocationPlatform implements DeviceLocationPlatform {
  const GeolocatorDeviceLocationPlatform();

  @override
  Future<bool> isServiceEnabled() => Geolocator.isLocationServiceEnabled();

  @override
  Future<DeviceLocationPermission> checkPermission() async =>
      _mapPermission(await Geolocator.checkPermission());

  @override
  Future<DeviceLocationPermission> requestPermission() async =>
      _mapPermission(await Geolocator.requestPermission());

  @override
  Stream<LocationSample> positionStream() => Geolocator.getPositionStream(
    locationSettings: const LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 10,
    ),
  ).map(_mapPosition);

  static DeviceLocationPermission _mapPermission(LocationPermission value) =>
      switch (value) {
        LocationPermission.denied => DeviceLocationPermission.denied,
        LocationPermission.deniedForever =>
          DeviceLocationPermission.deniedForever,
        LocationPermission.whileInUse => DeviceLocationPermission.whileInUse,
        LocationPermission.always => DeviceLocationPermission.always,
        LocationPermission.unableToDetermine => DeviceLocationPermission.denied,
      };

  static LocationSample _mapPosition(Position position) => LocationSample(
    position: GeoPoint(
      latitude: position.latitude,
      longitude: position.longitude,
    ),
    recordedAt: position.timestamp,
    accuracyMeters: position.accuracy,
    speedMetersPerSecond: position.speed < 0 ? null : position.speed,
    headingDegrees: position.heading < 0 || position.heading >= 360
        ? null
        : position.heading,
  );
}

/// Foreground-only location source.
///
/// [inspect] never requests permission. [requestAccess] must be called from an
/// explicit user action, and [start] only works after access is granted.
class DeviceLocationSource {
  DeviceLocationSource([
    this._platform = const GeolocatorDeviceLocationPlatform(),
  ]);

  final DeviceLocationPlatform _platform;
  final _statusController = StreamController<DeviceLocationStatus>.broadcast();
  StreamSubscription<LocationSample>? _positionSubscription;
  int _positionGeneration = 0;
  DeviceLocationStatus _status = const DeviceLocationStatus.idle();

  DeviceLocationStatus get status => _status;
  Stream<DeviceLocationStatus> get statuses => _statusController.stream;

  Future<DeviceLocationStatus> inspect() async {
    if (!await _platform.isServiceEnabled()) {
      return _emit(
        const DeviceLocationStatus(
          state: DeviceLocationState.serviceDisabled,
          message: 'Location Services are switched off.',
        ),
      );
    }
    return _statusForPermission(await _platform.checkPermission());
  }

  Future<DeviceLocationStatus> requestAccess() async {
    if (!await _platform.isServiceEnabled()) {
      return _emit(
        const DeviceLocationStatus(
          state: DeviceLocationState.serviceDisabled,
          message: 'Location Services are switched off.',
        ),
      );
    }
    var permission = await _platform.checkPermission();
    if (permission == DeviceLocationPermission.denied) {
      permission = await _platform.requestPermission();
    }
    return _statusForPermission(permission);
  }

  Future<DeviceLocationStatus> start() async {
    final inspected = await inspect();
    if (!inspected.canSample) {
      return inspected;
    }
    if (_positionSubscription != null) {
      return _status;
    }
    _emit(
      DeviceLocationStatus(
        state: DeviceLocationState.sampling,
        message: 'Sharing foreground location for this ride.',
        lastSample: _status.lastSample,
      ),
    );
    final generation = ++_positionGeneration;
    _positionSubscription = _platform.positionStream().listen(
      (sample) => _emit(
        DeviceLocationStatus(
          state: DeviceLocationState.sampling,
          message: 'Foreground location is active.',
          lastSample: sample,
        ),
      ),
      onError: (Object error, StackTrace stackTrace) =>
          _handlePositionError(generation, error),
      onDone: () => _handlePositionDone(generation),
    );
    return _status;
  }

  /// Recreates the native stream after an app lifecycle interruption while
  /// preserving the last fix. The caller is responsible for remembering that
  /// the rider previously opted in.
  Future<DeviceLocationStatus> restart() async {
    await stop();
    return start();
  }

  Future<void> stop() async {
    final subscription = _positionSubscription;
    final wasActive = subscription != null;
    _positionSubscription = null;
    _positionGeneration += 1;
    await subscription?.cancel();
    if (wasActive && _status.canSample) {
      _emit(
        DeviceLocationStatus(
          state: DeviceLocationState.ready,
          message: 'Location sharing is stopped.',
          lastSample: _status.lastSample,
        ),
      );
    }
  }

  Future<void> dispose() async {
    await stop();
    await _statusController.close();
  }

  void _handlePositionError(int generation, Object error) {
    if (generation != _positionGeneration) return;
    final subscription = _positionSubscription;
    _positionSubscription = null;
    _positionGeneration += 1;
    unawaited(subscription?.cancel());
    _emit(
      DeviceLocationStatus(
        state: DeviceLocationState.failed,
        message: 'Location updates stopped: $error',
        lastSample: _status.lastSample,
      ),
    );
  }

  void _handlePositionDone(int generation) {
    if (generation != _positionGeneration) return;
    _positionSubscription = null;
    _positionGeneration += 1;
    _emit(
      DeviceLocationStatus(
        state: DeviceLocationState.ready,
        message: 'Location sharing is stopped.',
        lastSample: _status.lastSample,
      ),
    );
  }

  DeviceLocationStatus _statusForPermission(
    DeviceLocationPermission permission,
  ) => switch (permission) {
    DeviceLocationPermission.denied => _emit(
      const DeviceLocationStatus(
        state: DeviceLocationState.permissionDenied,
        message: 'Location access has not been granted.',
      ),
    ),
    DeviceLocationPermission.deniedForever => _emit(
      const DeviceLocationStatus(
        state: DeviceLocationState.permissionDeniedForever,
        message: 'Location access is blocked in device settings.',
      ),
    ),
    DeviceLocationPermission.whileInUse || DeviceLocationPermission.always =>
      _positionSubscription != null
          ? _emit(
              DeviceLocationStatus(
                state: DeviceLocationState.sampling,
                message: 'Foreground location is active.',
                lastSample: _status.lastSample,
              ),
            )
          : _emit(
              DeviceLocationStatus(
                state: DeviceLocationState.ready,
                message: 'Location is available while the app is open.',
                lastSample: _status.lastSample,
              ),
            ),
  };

  DeviceLocationStatus _emit(DeviceLocationStatus status) {
    _status = status;
    if (!_statusController.isClosed) {
      _statusController.add(status);
    }
    return status;
  }
}
