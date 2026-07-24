import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/foreground_location_controller.dart';
import 'package:ride_relay/domain/geo_point.dart';
import 'package:ride_relay/domain/rider_location.dart';
import 'package:ride_relay/services/device_location_source.dart';

void main() {
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
