import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/foreground_location_controller.dart';
import 'package:ride_relay/controllers/map_style_mode_controller.dart';
import 'package:ride_relay/controllers/speed_limit_display_controller.dart';
import 'package:ride_relay/domain/distance_unit.dart';
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
    final location = ForegroundLocationController(
      DeviceLocationSource(platform),
      (_) async {},
    );
    addTearDown(location.dispose);

    await pump(tester, location: location);
    await tester.pumpAndSettle();

    expect(platform.permissionRequests, 0);
  });
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

  @override
  Stream<LocationSample> positionStream() => const Stream.empty();
}
