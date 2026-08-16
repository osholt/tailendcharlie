import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/foreground_location_controller.dart';
import 'package:ride_relay/controllers/map_style_mode_controller.dart';
import 'package:ride_relay/controllers/speed_limit_display_controller.dart';
import 'package:ride_relay/domain/distance_unit.dart';
import 'package:ride_relay/domain/imported_route.dart' show GeoPoint;
import 'package:ride_relay/domain/rider_location.dart';
import 'package:ride_relay/features/home/home_map_backdrop.dart';
import 'package:ride_relay/services/device_location_source.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late MapStyleModeController mapStyleMode;
  late SpeedLimitDisplayController speedLimitDisplay;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    mapStyleMode = await MapStyleModeController.load();
    speedLimitDisplay = SpeedLimitDisplayController.inMemory();
  });

  Future<void> pump(
    WidgetTester tester, {
    required ForegroundLocationController location,
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: HomeMapBackdrop(
          mapStyleMode: mapStyleMode,
          speedLimitDisplay: speedLimitDisplay,
          distanceUnit: DistanceUnit.kilometres,
          enableNativeServices: false,
          locationController: location,
        ),
      ),
    ),
  );

  testWidgets('opening the app never asks for location (#405)', (tester) async {
    // The whole point of opening on the map is that it is useful before the
    // rider has decided anything. Meeting them with a permission prompt before
    // the app has shown what it is for would trade one gate for another.
    final platform = _RecordingLocationPlatform();
    final location = ForegroundLocationController(
      DeviceLocationSource(platform),
      (_) async {},
    );
    addTearDown(location.dispose);

    await pump(tester, location: location);
    await tester.pumpAndSettle();

    expect(
      platform.permissionRequests,
      0,
      reason: 'the backdrop must resume, never request, on open',
    );
    expect(find.byKey(const Key('home-show-my-location')), findsOneWidget);
  });

  testWidgets('the rider can ask for their location themselves', (
    tester,
  ) async {
    final platform = _RecordingLocationPlatform();
    final location = ForegroundLocationController(
      DeviceLocationSource(platform),
      (_) async {},
    );
    addTearDown(location.dispose);

    await pump(tester, location: location);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home-show-my-location')));
    await tester.pumpAndSettle();

    expect(platform.permissionRequests, 1);
  });

  testWidgets('a rider who already granted access is not asked again', (
    tester,
  ) async {
    final platform = _RecordingLocationPlatform(
      granted: DeviceLocationPermission.always,
    );
    addTearDown(platform.closeStreams);
    final location = ForegroundLocationController(
      DeviceLocationSource(platform),
      (_) async {},
    );
    addTearDown(location.dispose);

    await pump(tester, location: location);
    await tester.pumpAndSettle();

    expect(platform.permissionRequests, 0);
  });
  // #577. Free roam lost the rider's position and offered no way back: the
  // recovery control was hidden on `sharing`, which says only that sampling
  // was requested, and nothing restarted the sampler after a background trip.
  group('free roam can be found again without restarting the app', () {
    testWidgets('resuming from the background restarts the sampler', (
      tester,
    ) async {
      final platform = _RecordingLocationPlatform(
        granted: DeviceLocationPermission.always,
      );
      addTearDown(platform.closeStreams);
      // The controller's own restart is exercised by the ride shell, which has
      // called it since #205. What was missing here, and all this asserts, is
      // that free roam asks for it at all.
      final location = _RecordingLocationController(
        DeviceLocationSource(platform),
        (_) async {},
      );
      addTearDown(location.dispose);

      await pump(tester, location: location);
      await tester.pumpAndSettle();
      expect(location.restarts, 0);

      // Through the binding, so forgetting `addObserver` fails here too.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();

      expect(
        location.restarts,
        1,
        reason:
            'free roam had no lifecycle observer at all, which is why '
            'only quitting the app recovered a lost position',
      );
    });

    testWidgets(
      'a sampler that has produced no fix still offers the way back',
      (tester) async {
        // The precise reported state: sharing is on, so the old rule hid the
        // control, but there is no rider on the map and search will not start.
        final platform = _RecordingLocationPlatform(
          granted: DeviceLocationPermission.always,
        );
        final location = ForegroundLocationController(
          DeviceLocationSource(platform),
          (_) async {},
        );
        addTearDown(location.dispose);

        await pump(tester, location: location);
        await tester.pumpAndSettle();

        expect(location.sharing, isTrue, reason: 'the sampler is running');
        expect(find.byKey(const Key('home-show-my-location')), findsOneWidget);
      },
    );

    testWidgets('a rider who is on the map is not nagged to be found', (
      tester,
    ) async {
      final platform = _RecordingLocationPlatform(
        granted: DeviceLocationPermission.always,
      );
      addTearDown(platform.closeStreams);
      final position = ValueNotifier<GeoPoint?>(null);
      addTearDown(position.dispose);
      final location = ForegroundLocationController(
        DeviceLocationSource(platform),
        (_) async {},
      );
      addTearDown(location.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HomeMapBackdrop(
              mapStyleMode: mapStyleMode,
              speedLimitDisplay: speedLimitDisplay,
              distanceUnit: DistanceUnit.kilometres,
              enableNativeServices: false,
              locationController: location,
              position: position,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('home-show-my-location')), findsOneWidget);

      position.value = const GeoPoint(latitude: 51.46, longitude: -2.59);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('home-show-my-location')), findsNothing);
    });
  });
}

/// Records that the backdrop asked for a restart, without standing up the
/// platform stream machinery an actual restart would need. Whether a restart
/// works is `ForegroundLocationController`'s business; whether free roam asks
/// for one is this widget's, and is what #577 was.
class _RecordingLocationController extends ForegroundLocationController {
  _RecordingLocationController(super.source, super.onSample);

  int restarts = 0;

  @override
  Future<void> restartAfterForegroundResume() async => restarts += 1;
}

/// Counts prompts. The test is about *when* a prompt happens, so the count is
/// the assertion rather than an incidental detail.
class _RecordingLocationPlatform implements DeviceLocationPlatform {
  _RecordingLocationPlatform({this.granted = DeviceLocationPermission.denied});

  final DeviceLocationPermission granted;
  int permissionRequests = 0;

  @override
  Future<bool> isServiceEnabled() async => true;

  @override
  Future<DeviceLocationPermission> checkPermission() async => granted;

  @override
  Future<DeviceLocationPermission> requestPermission() async {
    permissionRequests += 1;
    return granted;
  }

  @override
  Future<DeviceLocationPermission> requestBackgroundPermission() async {
    permissionRequests += 1;
    return granted;
  }

  /// Counts how many times a native stream was created. A restart is a new
  /// subscription, which is the observable difference (#577).
  int streamSubscriptions = 0;
  final _streams = <StreamController<LocationSample>>[];

  /// Open and silent, which is the state under test: a live subscription that
  /// has delivered nothing. `Stream.empty()` completes at once, and the source
  /// then leaves `sampling` — the opposite of the case being reproduced.
  @override
  Stream<LocationSample> positionStream() {
    streamSubscriptions += 1;
    final controller = StreamController<LocationSample>();
    _streams.add(controller);
    return controller.stream;
  }

  Future<void> closeStreams() async {
    for (final controller in _streams) {
      await controller.close();
    }
  }
}
