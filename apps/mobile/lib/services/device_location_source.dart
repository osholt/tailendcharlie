import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
// AppleSettings, AndroidSettings and ForegroundNotificationConfig all come from
// this one re-export, so the platform packages stay transitive.
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
    this.backgroundCapable = false,
  });

  const DeviceLocationStatus.idle()
    : state = DeviceLocationState.idle,
      message = 'Location sharing has not been started.',
      lastSample = null,
      backgroundCapable = false;

  final DeviceLocationState state;
  final String message;
  final LocationSample? lastSample;
  final bool backgroundCapable;

  bool get canSample =>
      state == DeviceLocationState.ready ||
      state == DeviceLocationState.sampling;
}

enum DeviceLocationPermission { denied, deniedForever, whileInUse, always }

abstract interface class DeviceLocationPlatform {
  Future<bool> isServiceEnabled();

  Future<DeviceLocationPermission> checkPermission();

  Future<DeviceLocationPermission> requestPermission();

  Future<DeviceLocationPermission> requestBackgroundPermission();

  Stream<LocationSample> positionStream();
}

class GeolocatorDeviceLocationPlatform implements DeviceLocationPlatform {
  const GeolocatorDeviceLocationPlatform();

  static const _backgroundPermissionChannel = MethodChannel(
    'me.osholt.ride_relay/background_location',
  );

  @override
  Future<bool> isServiceEnabled() => Geolocator.isLocationServiceEnabled();

  @override
  Future<DeviceLocationPermission> checkPermission() async =>
      _mapPermission(await Geolocator.checkPermission());

  @override
  Future<DeviceLocationPermission> requestPermission() async =>
      _mapPermission(await Geolocator.requestPermission());

  @override
  Future<DeviceLocationPermission> requestBackgroundPermission() async {
    if (defaultTargetPlatform == TargetPlatform.android) {
      return DeviceLocationPermission.always;
    }
    if (defaultTargetPlatform != TargetPlatform.iOS) {
      return checkPermission();
    }
    final value = await _backgroundPermissionChannel.invokeMethod<String>(
      'requestAlways',
    );
    return switch (value) {
      'always' => DeviceLocationPermission.always,
      'whileInUse' => DeviceLocationPermission.whileInUse,
      'deniedForever' => DeviceLocationPermission.deniedForever,
      _ => DeviceLocationPermission.denied,
    };
  }

  /// The platform filter, and deliberately not the reporting threshold.
  ///
  /// 10 m is how often the OS wakes this app with a fix. `PositionReportPolicy`
  /// then decides which of those fixes becomes a durable position report, at
  /// 20 m. The two are different layers and this one has to stay the smaller of
  /// the two:
  ///
  ///  - It gives the policy two or more candidate fixes per reported position,
  ///    which is what lets a fix be reported at a corner apex rather than 20 m
  ///    past it.
  ///  - It is the only thing that distinguishes "this rider has not moved" from
  ///    "this rider's GPS has stopped". Raising it to 20 m would collapse that
  ///    distinction, and the app would have no evidence left to tell a parked
  ///    rider apart from a dead receiver.
  ///
  /// Lowering it is not free either: sub-10 m wander on a stationary phone is
  /// mostly noise, and every delivered fix costs a wake-up. 10 m stays.
  static const platformDistanceFilterMeters = 10;

  @override
  Stream<LocationSample> positionStream() => Geolocator.getPositionStream(
    locationSettings: rideLocationSettings(defaultTargetPlatform),
  ).map(_mapPosition);

  /// Settings that keep fixes arriving while the app is not in the foreground.
  ///
  /// A plain [LocationSettings] is foreground-only, and that broke the premise of
  /// the app: a rider with the phone in a pocket or another navigation app in
  /// front contributed no position to the group and recorded a trail that jumped
  /// in a straight line across a bay (#205).
  ///
  /// Exposed for test because the two platform branches are the whole fix, and
  /// they cannot be exercised on a device from a unit test.
  @visibleForTesting
  static LocationSettings rideLocationSettings(
    TargetPlatform platform,
  ) => switch (platform) {
    TargetPlatform.iOS || TargetPlatform.macOS => AppleSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: platformDistanceFilterMeters,
      allowBackgroundLocationUpdates: true,
      // Core Location would otherwise decide the rider has stopped moving
      // and power the receiver down. On a ride, a stop is a coffee stop.
      pauseLocationUpdatesAutomatically: false,
      // The blue indicator is the honest signal that this app is using
      // location. The native bridge separately promotes access to Always:
      // field testing showed that While Using did not reliably survive another
      // navigation app taking the foreground (#205).
      showBackgroundLocationIndicator: true,
      activityType: ActivityType.otherNavigation,
    ),
    TargetPlatform.android => AndroidSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: platformDistanceFilterMeters,
      // Android grants background location through a location-typed
      // foreground service. geolocator_android owns the service; this is the
      // notification that has to accompany it, and the rider can stop the
      // ride from the app it points at.
      foregroundNotificationConfig: const ForegroundNotificationConfig(
        notificationTitle: 'Sharing your position with your ride',
        notificationText:
            'Tail End Charlie is recording your ride and keeping the group '
            'up to date. This stops when the ride ends.',
        notificationChannelName: 'Active ride',
        setOngoing: true,
        enableWakeLock: true,
      ),
    ),
    _ => const LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: platformDistanceFilterMeters,
    ),
  };

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

/// Ride-scoped location source.
///
/// Runs only between [start] and [stop], and within that window keeps running
/// while the app is in the background — a rider using another navigation app is
/// the ordinary case, not an edge case (#205). Outside that window the app holds
/// no location session at all.
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
    if (permission == DeviceLocationPermission.whileInUse) {
      permission = await _platform.requestBackgroundPermission();
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
        message: inspected.backgroundCapable
            ? 'Sharing your position for this ride, including in the background.'
            : 'Sharing while Tail End Charlie is visible. Allow “Always” '
                  'location access to keep sharing with another app in front.',
        lastSample: _status.lastSample,
        backgroundCapable: inspected.backgroundCapable,
      ),
    );
    final generation = ++_positionGeneration;
    _positionSubscription = _platform.positionStream().listen(
      (sample) => _emit(
        DeviceLocationStatus(
          state: DeviceLocationState.sampling,
          message: _status.backgroundCapable
              ? 'Location is active for this ride, including in the background.'
              : 'Location is active only while Tail End Charlie is visible.',
          lastSample: sample,
          backgroundCapable: _status.backgroundCapable,
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
          backgroundCapable: _status.backgroundCapable,
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
        backgroundCapable: _status.backgroundCapable,
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
        backgroundCapable: _status.backgroundCapable,
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
                message: permission == DeviceLocationPermission.always
                    ? 'Location is active for this ride, including in the background.'
                    : 'Location is active only while Tail End Charlie is visible.',
                lastSample: _status.lastSample,
                backgroundCapable:
                    permission == DeviceLocationPermission.always,
              ),
            )
          : _emit(
              DeviceLocationStatus(
                state: DeviceLocationState.ready,
                message: permission == DeviceLocationPermission.always
                    ? 'Location is ready. It runs for the length of a ride.'
                    : 'Location is ready, but background sharing needs “Always” '
                          'access.',
                lastSample: _status.lastSample,
                backgroundCapable:
                    permission == DeviceLocationPermission.always,
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
