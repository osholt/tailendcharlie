import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ride_relay/controllers/speed_adaptive_zoom_controller.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/domain/route_store.dart';
import 'package:ride_relay/features/map/ride_map.dart';
import 'package:ride_relay/services/basemap_configuration.dart';
import 'package:ride_relay/services/gpx_import_source.dart';
import 'package:ride_relay/services/navigation_camera.dart';
import 'package:ride_relay/services/navigation_speed_zoom.dart';
import 'package:ride_relay/services/offline_tile_cache.dart';
import 'package:ride_relay/services/route_importer.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #936: the live follow camera takes its zoom from the rider's speed, does it
/// only when the setting is on, and gives the zoom up to the rider the moment
/// they pinch or drag the map.
///
/// The pure mapping and smoothing are covered in
/// `test/services/navigation_speed_zoom_test.dart`; this is the wiring: the fix
/// reaches the governor, the governor's answer reaches the planner, and the
/// planner's zoom is what the map is driven to.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/maplibre_gl_0'),
          (_) async => null,
        );
  });

  final start = DateTime.utc(2026, 10, 10, 9);

  MapNavigationPosition fix(int second, double speed, {double step = 0.0002}) =>
      MapNavigationPosition(
        point: GeoPoint(latitude: 53, longitude: -1.02 + second * step),
        recordedAt: start.add(Duration(seconds: second)),
        speedMetersPerSecond: speed,
        headingDegrees: 90,
        accuracyMeters: 5,
      );

  /// Mounts the map in portrait with [navigation] as the rider and records each
  /// viewport the follow camera commands.
  Future<List<NavigationCameraViewport>> mount(
    WidgetTester tester,
    ValueNotifier<MapNavigationPosition?> navigation, {
    SpeedAdaptiveZoomController? setting,
  }) async {
    tester.view.devicePixelRatio = 3;
    tester.view.physicalSize = const Size(402 * 3, 874 * 3);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final directory = Directory.systemTemp.createTempSync('speed-zoom');
    addTearDown(() => directory.deleteSync(recursive: true));
    final cache = OfflineTileCache(
      rootDirectory: directory,
      configuration: const BasemapConfiguration(),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );
    addTearDown(cache.dispose);
    final viewports = <NavigationCameraViewport>[];
    await tester.pumpWidget(
      MaterialApp(
        home: RideMapScreen(
          routeStore: InMemoryRouteStore(_route),
          routeImporter: RouteImporter(source: const _NoFileSource()),
          offlineTileCache: cache,
          navigationPosition: navigation,
          speedAdaptiveZoom: setting,
          onNavigationViewportChanged: viewports.add,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    return viewports;
  }

  /// The follow camera commands at most one move per 400 ms of wall-clock time,
  /// and the fake test clock does not move that one, so wait it out for real.
  Future<void> pumpFix(
    WidgetTester tester,
    ValueNotifier<MapNavigationPosition?> navigation,
    MapNavigationPosition next,
  ) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 420)),
    );
    navigation.value = next;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  Future<void> tearDownMap(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 11));
    await tester.pump();
  }

  testWidgets('town speed is framed closer than the resting zoom, by default', (
    tester,
  ) async {
    final navigation = ValueNotifier<MapNavigationPosition?>(fix(0, 11));
    addTearDown(navigation.dispose);
    final viewports = await mount(tester, navigation);
    try {
      expect(viewports, isNotEmpty);
      final resting = NavigationCameraPlanner.plan(
        speedMetersPerSecond: 0,
        landscape: false,
      ).zoom;
      expect(
        viewports.last.zoom,
        closeTo(resting + NavigationSpeedZoom.offsetFor(11), 0.001),
      );
      expect(viewports.last.zoom, greaterThan(resting + 0.4));
    } finally {
      await tearDownMap(tester);
    }
  });

  testWidgets('with the setting off the zoom is the one the app always had', (
    tester,
  ) async {
    final setting = SpeedAdaptiveZoomController.inMemory(enabled: false);
    addTearDown(setting.dispose);
    final navigation = ValueNotifier<MapNavigationPosition?>(fix(0, 11));
    addTearDown(navigation.dispose);
    final viewports = await mount(tester, navigation, setting: setting);
    try {
      expect(viewports, isNotEmpty);
      final legacy = NavigationCameraPlanner.plan(
        speedMetersPerSecond: 11,
        landscape: false,
      ).zoom;
      expect(viewports.last.zoom, closeTo(legacy, 0.001));
    } finally {
      await tearDownMap(tester);
    }
  });

  testWidgets('a faster road opens the view out', (tester) async {
    final navigation = ValueNotifier<MapNavigationPosition?>(fix(0, 11));
    addTearDown(navigation.dispose);
    final viewports = await mount(tester, navigation);
    try {
      final town = viewports.last.zoom;
      for (var second = 1; second <= 8; second++) {
        await pumpFix(tester, navigation, fix(second, 27));
      }
      expect(
        viewports.last.zoom,
        lessThan(town - 0.5),
        reason: 'eight seconds at 60 mph is well out of the town framing',
      );
    } finally {
      await tearDownMap(tester);
    }
  });

  for (final gesture in ['drag', 'pinch']) {
    testWidgets('a $gesture keeps the zoom the rider chose until Follow me', (
      tester,
    ) async {
      final navigation = ValueNotifier<MapNavigationPosition?>(fix(0, 27));
      addTearDown(navigation.dispose);
      final viewports = await mount(tester, navigation);
      try {
        expect(viewports, isNotEmpty);
        final map = find.byType(FlutterMap);
        final controller = tester.widget<FlutterMap>(map).mapController!;
        final zoomBefore = controller.camera.zoom;

        // The rider takes the map: the gesture hands the camera over.
        if (gesture == 'drag') {
          await tester.drag(map, const Offset(0, 120));
        } else {
          final centre = tester.getCenter(map);
          final one = await tester.startGesture(centre - const Offset(30, 0));
          final two = await tester.startGesture(centre + const Offset(30, 0));
          await tester.pump();
          await one.moveBy(const Offset(-90, 0));
          await two.moveBy(const Offset(90, 0));
          await tester.pump();
          await one.up();
          await two.up();
        }
        await tester.pump(const Duration(milliseconds: 300));
        if (gesture == 'pinch') {
          expect(
            controller.camera.zoom,
            greaterThan(zoomBefore),
            reason: 'the pinch really did zoom the map',
          );
        }
        final chosen = controller.camera.zoom;
        final commandsWhenTaken = viewports.length;

        // The road changes character under them. A camera that still followed
        // would come back to a speed-chosen zoom.
        for (var second = 1; second <= 6; second++) {
          await pumpFix(tester, navigation, fix(second, 8));
        }
        expect(
          viewports.length,
          commandsWhenTaken,
          reason: 'the follow camera must not command a map that is theirs',
        );
        expect(controller.camera.zoom, closeTo(chosen, 0.001));

        // Follow me gives the camera back, at the zoom the speed now calls for.
        await tester.tap(find.byKey(const Key('navigation-follow-button')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 800));
        expect(viewports.length, greaterThan(commandsWhenTaken));
      } finally {
        await tearDownMap(tester);
      }
    });
  }
}

// Synthetic road; none is a rider's start, finish or home.
final _route = ImportedRoute(
  id: 'speed-zoom',
  name: 'Speed zoom',
  importedAt: DateTime.utc(2026, 10, 10),
  sourceFileName: 'route.gpx',
  paths: const [
    RoutePath(
      kind: RoutePathKind.track,
      points: [
        GeoPoint(latitude: 53, longitude: -1.02),
        GeoPoint(latitude: 53, longitude: -1.00),
      ],
    ),
  ],
  waypoints: const [],
);

class _NoFileSource implements GpxImportSource {
  const _NoFileSource();

  @override
  Future<PickedGpxFile?> pickGpxFile() async => null;
}
