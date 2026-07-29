import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/route_recorder_controller.dart';
import 'package:ride_relay/domain/geo_point.dart';
import 'package:ride_relay/domain/imported_route.dart' show RoutePathKind;
import 'package:ride_relay/domain/rider_location.dart';
import 'package:ride_relay/services/device_location_source.dart';

void main() {
  test(
    'records fixes only while recording, ignoring stale duplicates',
    () async {
      final platform = _FakeLocationPlatform();
      final source = DeviceLocationSource(platform);
      final controller = RouteRecorderController(source);
      addTearDown(controller.dispose);

      await controller.start();
      expect(controller.state, RouteRecorderState.recording);

      platform.positions.add(_sample(51, -1, 0));
      await Future<void>.delayed(Duration.zero);
      platform.positions.add(_sample(51.01, -1, 1));
      await Future<void>.delayed(Duration.zero);
      // A duplicate/older timestamp must not be recorded twice.
      platform.positions.add(_sample(51.01, -1, 1));
      await Future<void>.delayed(Duration.zero);

      expect(controller.pointCount, 2);
      expect(controller.distanceMeters, greaterThan(0));
      expect(controller.elapsed, const Duration(seconds: 1));
    },
  );

  test(
    'pause stops recording new fixes; resuming continues the trail',
    () async {
      final platform = _FakeLocationPlatform();
      final source = DeviceLocationSource(platform);
      final controller = RouteRecorderController(source);
      addTearDown(controller.dispose);

      await controller.start();
      platform.positions.add(_sample(51, -1, 0));
      await Future<void>.delayed(Duration.zero);

      await controller.pause();
      expect(controller.state, RouteRecorderState.paused);
      platform.positions.add(_sample(52, -1, 1));
      await Future<void>.delayed(Duration.zero);
      expect(controller.pointCount, 1);

      await controller.start();
      platform.positions.add(_sample(51.01, -1, 2));
      await Future<void>.delayed(Duration.zero);
      expect(controller.pointCount, 2);
    },
  );

  test('discard clears the recorded trail', () async {
    final platform = _FakeLocationPlatform();
    final source = DeviceLocationSource(platform);
    final controller = RouteRecorderController(source);
    addTearDown(controller.dispose);

    await controller.start();
    platform.positions.add(_sample(51, -1, 0));
    await Future<void>.delayed(Duration.zero);
    expect(controller.pointCount, 1);

    await controller.discard();
    expect(controller.pointCount, 0);
    expect(controller.state, RouteRecorderState.idle);
  });

  test(
    'build(start:, end:) previews a trimmed range without mutating samples',
    () async {
      final platform = _FakeLocationPlatform();
      final source = DeviceLocationSource(platform);
      final controller = RouteRecorderController(source);
      addTearDown(controller.dispose);

      await controller.start();
      for (var i = 0; i < 5; i += 1) {
        platform.positions.add(_sample(51 + i * 0.001, -1, i));
        await Future<void>.delayed(Duration.zero);
      }
      expect(controller.pointCount, 5);

      final trimmed = controller.build(
        name: 'Trimmed',
        id: 'r',
        start: 1,
        end: 3,
      );

      expect(trimmed, isNotNull);
      expect(trimmed!.paths.single.points, hasLength(3));
      expect(trimmed.paths.single.points.first.latitude, closeTo(51.001, 1e-9));
      expect(trimmed.paths.single.points.last.latitude, closeTo(51.003, 1e-9));
      // The underlying recording is untouched by a trim preview.
      expect(controller.pointCount, 5);
    },
  );

  test(
    'build(start:, end:) rejects a range selecting fewer than two points',
    () async {
      final platform = _FakeLocationPlatform();
      final source = DeviceLocationSource(platform);
      final controller = RouteRecorderController(source);
      addTearDown(controller.dispose);

      await controller.start();
      for (var i = 0; i < 5; i += 1) {
        platform.positions.add(_sample(51 + i * 0.001, -1, i));
        await Future<void>.delayed(Duration.zero);
      }

      expect(
        controller.build(name: 'Too short', id: 'r', start: 2, end: 2),
        isNull,
      );
    },
  );

  test('removePoint drops a single stray fix', () async {
    final platform = _FakeLocationPlatform();
    final source = DeviceLocationSource(platform);
    final controller = RouteRecorderController(source);
    addTearDown(controller.dispose);

    await controller.start();
    platform.positions.add(_sample(51, -1, 0));
    await Future<void>.delayed(Duration.zero);
    platform.positions.add(_sample(60, -1, 1)); // a stray fix, far away
    await Future<void>.delayed(Duration.zero);
    platform.positions.add(_sample(51.01, -1, 2));
    await Future<void>.delayed(Duration.zero);
    expect(controller.pointCount, 3);

    controller.removePoint(1);

    expect(controller.pointCount, 2);
    expect(controller.samples.every((s) => s.position.latitude < 52), isTrue);
  });

  test(
    'build produces a GPX-exportable track, or null with too few fixes',
    () async {
      final platform = _FakeLocationPlatform();
      final source = DeviceLocationSource(platform);
      final controller = RouteRecorderController(source);
      addTearDown(controller.dispose);

      expect(controller.build(name: 'Test', id: 'route-1'), isNull);

      await controller.start();
      platform.positions.add(_sample(51, -1, 0));
      await Future<void>.delayed(Duration.zero);
      platform.positions.add(_sample(51.01, -1, 1));
      await Future<void>.delayed(Duration.zero);

      final route = controller.build(name: '  ', id: 'route-1');

      expect(route, isNotNull);
      expect(route!.id, 'route-1');
      expect(route.name, 'Recorded route');
      expect(route.paths, hasLength(1));
      expect(route.paths.single.kind, RoutePathKind.track);
      expect(route.paths.single.points, hasLength(2));
    },
  );
}

LocationSample _sample(double latitude, double longitude, int second) =>
    LocationSample(
      position: GeoPoint(latitude: latitude, longitude: longitude),
      recordedAt: DateTime.utc(2026, 7, 16, 12, 0, second),
      accuracyMeters: 5,
    );

class _FakeLocationPlatform implements DeviceLocationPlatform {
  final positions = StreamController<LocationSample>.broadcast();

  @override
  Future<bool> isServiceEnabled() async => true;

  @override
  Future<DeviceLocationPermission> checkPermission() async =>
      DeviceLocationPermission.whileInUse;

  @override
  Future<DeviceLocationPermission> requestPermission() async =>
      DeviceLocationPermission.whileInUse;

  @override
  Future<DeviceLocationPermission> requestBackgroundPermission() async =>
      DeviceLocationPermission.whileInUse;

  @override
  Stream<LocationSample> positionStream() => positions.stream;
}
