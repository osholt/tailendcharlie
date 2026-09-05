import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:ride_relay/controllers/foreground_location_controller.dart';
import 'package:ride_relay/domain/geo_point.dart';
import 'package:ride_relay/domain/rider_location.dart';
import 'package:ride_relay/services/device_location_source.dart';
import 'package:xml/xml.dart';

void main() {
  // #205. A plain LocationSettings is foreground-only, so a rider with the phone
  // in a pocket or another navigation app in front contributed nothing to the
  // group and recorded a trail that jumped in a straight line across a bay.
  group('ride location settings keep running in the background', () {
    test(
      'iOS keeps both location and spoken audio alive while locked (#726)',
      () {
        final document = XmlDocument.parse(
          File('ios/Runner/Info.plist').readAsStringSync(),
        );
        final key = document
            .findAllElements('key')
            .singleWhere((element) => element.innerText == 'UIBackgroundModes');
        final siblings = key.parent!.childElements.toList(growable: false);
        final value = siblings[siblings.indexOf(key) + 1];
        final modes = value.childElements
            .where((element) => element.name.local == 'string')
            .map((element) => element.innerText)
            .toSet();

        expect(value.name.local, 'array');
        expect(modes, containsAll(<String>{'location', 'audio'}));
      },
    );

    test('iOS asks Core Location not to stop or pause', () {
      final settings = GeolocatorDeviceLocationPlatform.rideLocationSettings(
        TargetPlatform.iOS,
      );

      expect(settings, isA<AppleSettings>());
      final apple = settings as AppleSettings;
      expect(apple.allowBackgroundLocationUpdates, isTrue);
      // A stop on a ride is a coffee stop, not the end of the journey.
      expect(apple.pauseLocationUpdatesAutomatically, isFalse);
      // The honest signal to the rider that location is in use.
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
      expect(
        config.enableWakeLock,
        isTrue,
        reason:
            'the navigation isolate must keep processing fixes while locked',
      );
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

  test(
    'home refresh gets a current fix without starting ride stream',
    () async {
      final platform = _FakeLocationPlatform(
        permission: DeviceLocationPermission.whileInUse,
      );
      final received = <LocationSample>[];
      final controller = ForegroundLocationController(
        DeviceLocationSource(platform),
        (sample) async => received.add(sample),
      );
      await controller.initialize();

      await controller.refreshIfAuthorized();
      await Future<void>.delayed(Duration.zero);

      expect(controller.sharing, isFalse);
      expect(controller.latestSample, _sample);
      expect(received, [_sample]);
      expect(platform.currentPositionRequests, 1);
      expect(platform.streamRequests, 0);
      expect(platform.backgroundPermissionRequests, 0);
      controller.dispose();
      await platform.dispose();
    },
  );

  test('explicit home fix asks only for foreground permission', () async {
    final platform = _FakeLocationPlatform(
      requestedPermission: DeviceLocationPermission.whileInUse,
    );
    final source = DeviceLocationSource(platform);

    final status = await source.requestOneShot();

    expect(status.lastSample, _sample);
    expect(platform.permissionRequests, 1);
    expect(platform.backgroundPermissionRequests, 0);
    expect(platform.streamRequests, 0);
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
    'explicit request promotes while-in-use access for background GPS',
    () async {
      final platform = _FakeLocationPlatform(
        requestedPermission: DeviceLocationPermission.whileInUse,
        backgroundPermission: DeviceLocationPermission.always,
      );
      final source = DeviceLocationSource(platform);

      final access = await source.requestAccess();

      expect(platform.permissionRequests, 1);
      expect(platform.backgroundPermissionRequests, 1);
      expect(access.backgroundCapable, isTrue);
      expect(access.message, contains('length of a ride'));
      await source.dispose();
      await platform.dispose();
    },
  );

  test(
    'while-in-use fallback states that background sharing is limited',
    () async {
      final platform = _FakeLocationPlatform(
        permission: DeviceLocationPermission.whileInUse,
        backgroundPermission: DeviceLocationPermission.whileInUse,
      );
      final source = DeviceLocationSource(platform);

      final access = await source.requestAccess();
      final started = await source.start();

      expect(access.backgroundCapable, isFalse);
      expect(started.backgroundCapable, isFalse);
      expect(started.message, contains('Tail End Charlie is visible'));
      await source.dispose();
      await platform.dispose();
    },
  );

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
    this.backgroundPermission,
  });

  final bool serviceEnabled;
  DeviceLocationPermission permission;
  final DeviceLocationPermission requestedPermission;
  final DeviceLocationPermission? backgroundPermission;
  final positions = StreamController<LocationSample>.broadcast();
  int permissionRequests = 0;
  int backgroundPermissionRequests = 0;
  int streamRequests = 0;
  LocationSample? cachedPosition;
  LocationSample current = _sample;
  int currentPositionRequests = 0;

  @override
  Future<DeviceLocationPermission> checkPermission() async => permission;

  @override
  Future<bool> isServiceEnabled() async => serviceEnabled;

  @override
  Future<LocationSample?> lastKnownPosition() async => cachedPosition;

  @override
  Future<LocationSample> currentPosition() async {
    currentPositionRequests += 1;
    return current;
  }

  @override
  Future<DeviceLocationPermission> requestBackgroundPermission() async {
    backgroundPermissionRequests += 1;
    permission = backgroundPermission ?? permission;
    return permission;
  }

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
