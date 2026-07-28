import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:ride_relay/controllers/foreground_location_controller.dart';
import 'package:ride_relay/domain/geo_point.dart';
import 'package:ride_relay/domain/rider_location.dart';
import 'package:ride_relay/services/device_location_source.dart';

void main() {
  // #205. A plain LocationSettings is foreground-only, so a rider with the phone
  // in a pocket or another navigation app in front contributed nothing to the
  // group and recorded a trail that jumped in a straight line across a bay.
  group('ride location settings keep running in the background', () {
    test('iOS asks Core Location not to stop or pause', () {
      final settings = GeolocatorDeviceLocationPlatform.rideLocationSettings(
        TargetPlatform.iOS,
      );

      expect(settings, isA<AppleSettings>());
      final apple = settings as AppleSettings;
      expect(apple.allowBackgroundLocationUpdates, isTrue);
      // A stop on a ride is a coffee stop, not the end of the journey.
      expect(apple.pauseLocationUpdatesAutomatically, isFalse);
      // What makes a while-in-use authorisation sufficient, and the honest
      // signal to the rider that location is in use.
      expect(apple.showBackgroundLocationIndicator, isTrue);
      expect(apple.activityType, ActivityType.otherNavigation);
    });

    test('Android runs a foreground service the rider can see', () {
      final settings = GeolocatorDeviceLocationPlatform.rideLocationSettings(
        TargetPlatform.android,
      );

      expect(settings, isA<AndroidSettings>());
      final config = (settings as AndroidSettings).foregroundNotificationConfig;
      expect(config, isNotNull);
      expect(config!.setOngoing, isTrue);
      // It has to say what is happening and that it ends with the ride.
      expect(config.notificationText, contains('ride'));
      expect(config.notificationText, contains('stops when the ride ends'));
    });

    test('every platform keeps the 10 m platform filter', () {
      for (final platform in TargetPlatform.values) {
        expect(
          GeolocatorDeviceLocationPlatform.rideLocationSettings(
            platform,
          ).distanceFilter,
          GeolocatorDeviceLocationPlatform.platformDistanceFilterMeters,
          reason: '$platform',
        );
      }
    });
  });

  test('inspection reports denial without prompting', () async {
    final platform = _FakeLocationPlatform();
    final source = DeviceLocationSource(platform);

    final status = await source.inspect();

    expect(status.state, DeviceLocationState.permissionDenied);
    expect(platform.permissionRequests, 0);
    await source.dispose();
    await platform.dispose();
  });

  test('explicit request starts foreground stream and can stop it', () async {
    final platform = _FakeLocationPlatform(
      requestedPermission: DeviceLocationPermission.whileInUse,
    );
    final source = DeviceLocationSource(platform);

    expect((await source.requestAccess()).state, DeviceLocationState.ready);
    expect(platform.permissionRequests, 1);
    expect((await source.start()).state, DeviceLocationState.sampling);

    platform.positions.add(_sample);
    final sampled = await source.statuses.firstWhere(
      (status) => status.lastSample != null,
    );
    expect(sampled.lastSample?.position, _sample.position);

    await source.stop();
    expect(source.status.state, DeviceLocationState.ready);
    await source.dispose();
    await platform.dispose();
  });

  test(
    'foreground controller forwards samples to ride event handler',
    () async {
      final platform = _FakeLocationPlatform(
        permission: DeviceLocationPermission.whileInUse,
      );
      final source = DeviceLocationSource(platform);
      final received = <LocationSample>[];
      final controller = ForegroundLocationController(
        source,
        (sample) async => received.add(sample),
      );
      await controller.initialize();
      await controller.requestAndStart();

      platform.positions.add(_sample);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(received, [_sample]);
      controller.dispose();
      await platform.dispose();
    },
  );

  test(
    'requesting access again preserves the active fix and one stream',
    () async {
      final platform = _FakeLocationPlatform(
        permission: DeviceLocationPermission.whileInUse,
      );
      final source = DeviceLocationSource(platform);
      final controller = ForegroundLocationController(source, (_) async {});
      await controller.initialize();
      await controller.requestAndStart();

      platform.positions.add(_sample);
      await source.statuses.firstWhere(
        (status) => status.lastSample == _sample,
      );
      await Future<void>.delayed(Duration.zero);

      expect(controller.sharing, isTrue);
      expect(controller.activeSample, _sample);
      await controller.requestAndStart();

      expect(controller.sharing, isTrue);
      expect(controller.activeSample, _sample);
      expect(platform.streamRequests, 1);

      await controller.stop();
      await Future<void>.delayed(Duration.zero);
      expect(controller.activeSample, isNull);
      controller.dispose();
      await platform.dispose();
    },
  );

  test('one failed ride write does not stop later GPS fixes', () async {
    final platform = _FakeLocationPlatform(
      permission: DeviceLocationPermission.whileInUse,
    );
    final source = DeviceLocationSource(platform);
    final received = <LocationSample>[];
    final errors = <Object>[];
    var attempts = 0;
    final controller = ForegroundLocationController(source, (sample) async {
      attempts += 1;
      if (attempts == 1) throw StateError('ride state changed');
      received.add(sample);
    }, onSampleError: (error, _) => errors.add(error));
    await controller.initialize();
    await controller.requestAndStart();

    platform.positions
      ..add(_sample)
      ..add(_laterSample);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(attempts, 2);
    expect(received, [_laterSample]);
    expect(errors, hasLength(1));
    controller.dispose();
    await platform.dispose();
  });

  test('foreground resume restarts only an opted-in location stream', () async {
    final platform = _FakeLocationPlatform(
      permission: DeviceLocationPermission.whileInUse,
    );
    final source = DeviceLocationSource(platform);
    final controller = ForegroundLocationController(source, (_) async {});
    await controller.initialize();
    await controller.requestAndStart();
    expect(platform.streamRequests, 1);

    platform.positions.add(_sample);
    await source.statuses.firstWhere((status) => status.lastSample == _sample);
    await controller.restartAfterForegroundResume();

    expect(platform.streamRequests, 2);
    expect(controller.sharing, isTrue);
    expect(controller.activeSample, _sample);

    await controller.stop();
    await controller.restartAfterForegroundResume();
    expect(platform.streamRequests, 2);
    controller.dispose();
    await platform.dispose();
  });

  test('foreground resume recovers a native stream error', () async {
    final platform = _FakeLocationPlatform(
      permission: DeviceLocationPermission.whileInUse,
    );
    final source = DeviceLocationSource(platform);
    final controller = ForegroundLocationController(source, (_) async {});
    await controller.initialize();
    await controller.requestAndStart();

    platform.positions.addError(StateError('Core Location interrupted'));
    await source.statuses.firstWhere(
      (status) => status.state == DeviceLocationState.failed,
    );
    await controller.restartAfterForegroundResume();

    expect(platform.streamRequests, 2);
    expect(controller.sharing, isTrue);
    controller.dispose();
    await platform.dispose();
  });

  test('disabled service is surfaced and stream is not started', () async {
    final platform = _FakeLocationPlatform(serviceEnabled: false);
    final source = DeviceLocationSource(platform);

    expect(
      (await source.requestAccess()).state,
      DeviceLocationState.serviceDisabled,
    );
    expect(platform.streamRequests, 0);
    await source.dispose();
    await platform.dispose();
  });

  test('restart resume uses existing permission without prompting', () async {
    final platform = _FakeLocationPlatform(
      permission: DeviceLocationPermission.whileInUse,
    );
    final controller = ForegroundLocationController(
      DeviceLocationSource(platform),
      (_) async {},
    );
    await controller.initialize();

    await controller.resumeIfAuthorized();

    expect(controller.sharing, isTrue);
    expect(platform.permissionRequests, 0);
    expect(platform.streamRequests, 1);

    await controller.restartAfterForegroundResume();

    expect(controller.sharing, isTrue);
    expect(platform.permissionRequests, 0);
    expect(platform.streamRequests, 2);
    controller.dispose();
    await platform.dispose();
  });

  test('restart resume stays stopped when permission was removed', () async {
    final platform = _FakeLocationPlatform();
    final controller = ForegroundLocationController(
      DeviceLocationSource(platform),
      (_) async {},
    );
    await controller.initialize();

    await controller.resumeIfAuthorized();

    expect(controller.sharing, isFalse);
    expect(platform.permissionRequests, 0);
    expect(platform.streamRequests, 0);
    controller.dispose();
    await platform.dispose();
  });
}

final _sample = LocationSample(
  position: const GeoPoint(latitude: 51, longitude: -1),
  recordedAt: DateTime.utc(2026, 7, 16, 12),
  accuracyMeters: 4,
);

final _laterSample = LocationSample(
  position: const GeoPoint(latitude: 51.001, longitude: -1),
  recordedAt: DateTime.utc(2026, 7, 16, 12, 0, 10),
  accuracyMeters: 4,
);

class _FakeLocationPlatform implements DeviceLocationPlatform {
  _FakeLocationPlatform({
    this.serviceEnabled = true,
    this.permission = DeviceLocationPermission.denied,
    this.requestedPermission = DeviceLocationPermission.denied,
  });

  final bool serviceEnabled;
  DeviceLocationPermission permission;
  final DeviceLocationPermission requestedPermission;
  final positions = StreamController<LocationSample>.broadcast();
  int permissionRequests = 0;
  int streamRequests = 0;

  @override
  Future<DeviceLocationPermission> checkPermission() async => permission;

  @override
  Future<bool> isServiceEnabled() async => serviceEnabled;

  @override
  Stream<LocationSample> positionStream() {
    streamRequests += 1;
    return positions.stream;
  }

  @override
  Future<DeviceLocationPermission> requestPermission() async {
    permissionRequests += 1;
    permission = requestedPermission;
    return permission;
  }

  Future<void> dispose() => positions.close();
}
