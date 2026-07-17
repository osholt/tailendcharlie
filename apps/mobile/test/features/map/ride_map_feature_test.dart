import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ride_relay/domain/distance_unit.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/domain/route_store.dart';
import 'package:ride_relay/domain/route_alert.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/features/map/ride_map.dart';
import 'package:ride_relay/services/basemap_configuration.dart';
import 'package:ride_relay/services/gpx_import_source.dart';
import 'package:ride_relay/services/leader_ride_status.dart';
import 'package:ride_relay/services/offline_tile_cache.dart';
import 'package:ride_relay/services/route_importer.dart';

void main() {
  testWidgets('offers file import and loads bundled demo route offline', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync('map-widget-test');
    addTearDown(() => directory.deleteSync(recursive: true));
    final overlays = ValueNotifier<List<MapOverlayMarker>>([
      const MapOverlayMarker(
        id: 'hazard-1',
        point: GeoPoint(latitude: 53.34, longitude: -1.78),
        label: 'Road works',
      ),
    ]);
    addTearDown(overlays.dispose);
    final leaderStatus = ValueNotifier<LeaderRideStatus?>(
      const LeaderRideStatus(
        tecName: 'Charlie',
        distanceToTecMeters: 3200,
        estimatedTimeToTec: Duration(minutes: 4),
        offCourseAlerts: [
          LeaderOffCourseAlert(
            riderId: 'alex',
            displayName: 'Alex',
            level: RouteAlertLevel.urgent,
            distanceFromRouteMeters: 240,
          ),
        ],
      ),
    );
    addTearDown(leaderStatus.dispose);
    final cache = OfflineTileCache(
      rootDirectory: directory,
      configuration: const BasemapConfiguration(),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: RideMapScreen(
          routeStore: InMemoryRouteStore(),
          routeImporter: RouteImporter(source: const _NoFileSource()),
          offlineTileCache: cache,
          overlayMarkers: overlays,
          leaderStatus: leaderStatus,
          distanceUnit: DistanceUnit.miles,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Enter destination'), findsOneWidget);
    expect(find.text('Import GPX'), findsOneWidget);
    expect(find.text('ROUTE-ONLY OFFLINE MAP'), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    expect(find.text('TEC GAP'), findsOneWidget);
    expect(find.textContaining('Alex is clearly off course'), findsOneWidget);
    expect(find.textContaining('2.0 mi'), findsOneWidget);
    expect(find.textContaining('0.1 mi'), findsOneWidget);

    await tester.tap(find.text('Use demo route'));
    for (var i = 0; i < 5; i += 1) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(
      find.text("King's Oak Academy to Cross Hands Hotel"),
      findsOneWidget,
    );
    expect(find.byTooltip('Navigate or export route'), findsOneWidget);
    expect(find.textContaining('basemap configured'), findsNothing);
    expect(find.text('Download map for offline use'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('forwards the full-screen ride menu through the app wrapper', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync('map-wrapper-test');
    addTearDown(() => directory.deleteSync(recursive: true));
    final cache = OfflineTileCache(
      rootDirectory: directory,
      configuration: const BasemapConfiguration(),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );
    addTearDown(cache.dispose);
    final navigation = ValueNotifier<MapNavigationPosition?>(
      MapNavigationPosition(
        point: const GeoPoint(latitude: 53, longitude: -1.01),
        recordedAt: DateTime.utc(2026, 7, 18, 12),
        speedMetersPerSecond: 8,
        headingDegrees: 90,
      ),
    );
    addTearDown(navigation.dispose);
    final route = ImportedRoute(
      id: 'wrapper-route',
      name: 'Wrapper route',
      importedAt: DateTime.utc(2026, 7, 18),
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
    var menuOpens = 0;

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: RideMapFeature(
          routeStore: InMemoryRouteStore(route),
          offlineTileCache: cache,
          mapStyleString:
              '{"version":8,"sources":{},"layers":[{"id":"background","type":"background"}]}',
          navigationPosition: navigation,
          onOpenRideMenu: () async => menuOpens += 1,
        ),
      ),
    );
    await tester.pump();
    for (var frame = 0; frame < 5; frame += 1) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.byType(RideMapScreen), findsOneWidget);
    expect(find.byKey(const Key('ride-menu-button')), findsOneWidget);
    await tester.tap(find.byKey(const Key('ride-menu-button')));
    await tester.pump();
    expect(menuOpens, 1);

    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets(
    'keeps an automatic junction marker on the zoomed-out map overview',
    (tester) async {
      tester.view.physicalSize = const Size(844, 390);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final directory = Directory.systemTemp.createTempSync('marker-map-test');
      addTearDown(() => directory.deleteSync(recursive: true));
      final marker = ValueNotifier<MapJunctionMarkerOverlay?>(
        const MapJunctionMarkerOverlay(
          markerPoint: GeoPoint(latitude: 53, longitude: -1.01),
          markerRiderName: 'You',
          isLocalMarker: true,
          ridersPassed: 2,
          ridersExpected: 3,
          tecDistanceMeters: 210,
          instruction: 'You are holding the junction while riders pass.',
          stage: MapJunctionMarkerStage.waitingForRiders,
        ),
      );
      addTearDown(marker.dispose);
      final route = ImportedRoute(
        id: 'route',
        name: 'Marker route',
        importedAt: DateTime.utc(2026, 7, 17),
        sourceFileName: 'route.gpx',
        paths: const [
          RoutePath(
            kind: RoutePathKind.track,
            points: [
              GeoPoint(latitude: 53, longitude: -1.02),
              GeoPoint(latitude: 53, longitude: -1.01),
              GeoPoint(latitude: 53, longitude: -1.00),
            ],
          ),
        ],
        waypoints: const [],
      );
      final cache = OfflineTileCache(
        rootDirectory: directory,
        configuration: const BasemapConfiguration(),
        httpClient: MockClient((_) async => http.Response('', 404)),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: RideMapScreen(
            routeStore: InMemoryRouteStore(route),
            routeImporter: RouteImporter(source: const _NoFileSource()),
            offlineTileCache: cache,
            junctionMarkerOverlay: marker,
            onEmergencyAlert: () async {},
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();

      expect(find.byType(AppBar), findsNothing);
      expect(find.byKey(const Key('junction-marker-overlay')), findsOneWidget);
      expect(find.text('You are holding this junction.'), findsOneWidget);
      expect(find.text('2/3 passed'), findsOneWidget);
      expect(find.byKey(const Key('navigation-follow-button')), findsNothing);
      final overlayBounds = tester.getRect(
        find.byKey(const Key('junction-marker-overlay')),
      );
      expect(overlayBounds.left, greaterThan(400));
      expect(overlayBounds.top, greaterThan(100));
      expect(overlayBounds.bottom, greaterThan(350));

      marker.value = const MapJunctionMarkerOverlay(
        markerPoint: GeoPoint(latitude: 53, longitude: -1.01),
        markerRiderName: 'Maya',
        isLocalMarker: false,
        ridersPassed: 2,
        ridersExpected: 3,
        tecDistanceMeters: 210,
        instruction: 'Maya is holding the junction while riders pass.',
        stage: MapJunctionMarkerStage.waitingForRiders,
      );
      await tester.pump();

      expect(find.byKey(const Key('junction-marker-overlay')), findsNothing);
      expect(find.byType(AppBar), findsOneWidget);

      tester.view.physicalSize = const Size(390, 844);
      marker.value = const MapJunctionMarkerOverlay(
        markerPoint: GeoPoint(latitude: 53, longitude: -1.01),
        markerRiderName: 'You',
        isLocalMarker: true,
        ridersPassed: 2,
        ridersExpected: 3,
        tecDistanceMeters: 210,
        instruction: 'You are holding the junction while riders pass.',
        stage: MapJunctionMarkerStage.waitingForRiders,
      );
      await tester.pump();
      await tester.pumpAndSettle();

      final portraitBounds = tester.getRect(
        find.byKey(const Key('junction-marker-overlay')),
      );
      expect(portraitBounds.left, greaterThanOrEqualTo(12));
      expect(portraitBounds.right, lessThanOrEqualTo(378));
      final emergencyBounds = tester.getRect(
        find.byKey(const Key('emergency-alert-button')),
      );
      expect(emergencyBounds.bottom, lessThan(portraitBounds.top));

      marker.value = null;
      await tester.pump();

      expect(find.byKey(const Key('junction-marker-overlay')), findsNothing);
      expect(find.byType(AppBar), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets(
    'landscape moving mode hides chrome and styles progress and off-route trail',
    (tester) async {
      tester.view.physicalSize = const Size(844, 390);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final directory = Directory.systemTemp.createTempSync(
        'landscape-map-test',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final navigation = ValueNotifier<MapNavigationPosition?>(
        MapNavigationPosition(
          point: const GeoPoint(latitude: 53, longitude: -1.01),
          recordedAt: DateTime.utc(2026, 7, 17, 12),
          speedMetersPerSecond: 12,
          headingDegrees: 90,
        ),
      );
      addTearDown(navigation.dispose);
      final traces = ValueNotifier<List<MapOverlayTrace>>([
        const MapOverlayTrace(
          id: 'off-route-alex',
          label: 'Alex off-route trace',
          points: [
            GeoPoint(latitude: 53, longitude: -1.01),
            GeoPoint(latitude: 53.001, longitude: -1.011),
          ],
        ),
      ]);
      addTearDown(traces.dispose);
      final riders = ValueNotifier<List<MapOverlayMarker>>([
        const MapOverlayMarker(
          id: 'rider-alex',
          point: GeoPoint(latitude: 53, longitude: -1.011),
          label: 'Alex',
        ),
        const MapOverlayMarker(
          id: 'rider-charlie',
          point: GeoPoint(latitude: 53, longitude: -1.015),
          label: 'Charlie',
        ),
      ]);
      addTearDown(riders.dispose);
      final route = ImportedRoute(
        id: 'route',
        name: 'Landscape route',
        importedAt: DateTime.utc(2026, 7, 17),
        sourceFileName: 'route.gpx',
        paths: const [
          RoutePath(
            kind: RoutePathKind.track,
            points: [
              GeoPoint(latitude: 53, longitude: -1.02),
              GeoPoint(latitude: 53, longitude: -1.01),
              GeoPoint(latitude: 53, longitude: -1.00),
            ],
          ),
        ],
        waypoints: const [],
      );
      final cache = OfflineTileCache(
        rootDirectory: directory,
        configuration: const BasemapConfiguration(),
        httpClient: MockClient((_) async => http.Response('', 404)),
      );
      var menuOpens = 0;

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: RideMapScreen(
            routeStore: InMemoryRouteStore(route),
            routeImporter: RouteImporter(source: const _NoFileSource()),
            offlineTileCache: cache,
            navigationPosition: navigation,
            overlayMarkers: riders,
            offRouteTraces: traces,
            onOpenRideMenu: () async => menuOpens += 1,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.byType(AppBar), findsNothing);
      expect(find.byKey(const Key('ride-menu-button')), findsOneWidget);
      expect(find.byKey(const Key('group-mini-map')), findsOneWidget);
      expect(find.text('3 RIDERS'), findsOneWidget);
      expect(find.byKey(const Key('navigation-follow-button')), findsNothing);
      await tester.tap(find.byKey(const Key('ride-menu-button')));
      await tester.pump();
      expect(menuOpens, 1);
      tester.view.physicalSize = const Size(390, 844);
      await tester.pump();
      expect(find.byKey(const Key('ride-menu-button')), findsOneWidget);
      expect(find.byKey(const Key('group-mini-map')), findsOneWidget);
      final portraitMiniMap = tester.getRect(
        find.byKey(const Key('group-mini-map')),
      );
      expect(portraitMiniMap.width, 150);
      expect(portraitMiniMap.height, 104);
      tester.view.physicalSize = const Size(844, 390);
      await tester.pump();
      final layer = tester.widget<PolylineLayer>(find.byType(PolylineLayer));
      expect(
        layer.polylines.any(
          (line) =>
              line.pattern == const StrokePattern.dotted(spacingFactor: 1.8),
        ),
        isTrue,
      );
      expect(
        layer.polylines.any((line) => line.color == const Color(0xFFFF7A1A)),
        isTrue,
      );
      expect(
        layer.polylines.any((line) => line.color == const Color(0xFFE244C7)),
        isTrue,
      );

      await tester.drag(find.byType(FlutterMap), const Offset(80, 0));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('navigation-follow-button')), findsOneWidget);
      expect(find.text('Re-centre'), findsOneWidget);
      expect(find.byType(AppBar), findsNothing);

      await tester.tap(find.text('Re-centre'));
      await tester.pump();
      expect(find.byKey(const Key('navigation-follow-button')), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets('shows a stopped-rider assistance sheet after an alert', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync('emergency-map-test');
    addTearDown(() => directory.deleteSync(recursive: true));
    final route = ImportedRoute(
      id: 'route',
      name: 'Emergency route',
      importedAt: DateTime.utc(2026, 7, 17),
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
    final cache = OfflineTileCache(
      rootDirectory: directory,
      configuration: const BasemapConfiguration(),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );
    var alerts = 0;
    final sentIssues = <String>[];

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: RideMapScreen(
          routeStore: InMemoryRouteStore(route),
          routeImporter: RouteImporter(source: const _NoFileSource()),
          offlineTileCache: cache,
          emergencyContacts: const [
            MapEmergencyContact(
              riderId: 'lead',
              displayName: 'Oliver',
              role: RideRole.lead,
            ),
            MapEmergencyContact(
              riderId: 'tec',
              displayName: 'Charlie',
              role: RideRole.tailEndCharlie,
            ),
          ],
          onEmergencyAlert: () async => alerts += 1,
          onEmergencyIssue: (message) async => sentIssues.add(message.name),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    await tester.tap(find.byKey(const Key('emergency-alert-button')));
    await tester.pumpAndSettle();

    expect(alerts, 1);
    expect(find.text('You are stopped'), findsOneWidget);
    await tester.tap(find.text('Mechanical'));
    await tester.pumpAndSettle();
    expect(sentIssues, ['mechanical']);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('shows a leader pause control and paused state on the map', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync('pause-map-test');
    addTearDown(() => directory.deleteSync(recursive: true));
    final cache = OfflineTileCache(
      rootDirectory: directory,
      configuration: const BasemapConfiguration(),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );
    final route = ImportedRoute(
      id: 'route',
      name: 'Pause route',
      importedAt: DateTime.utc(2026, 7, 17),
      sourceFileName: 'route.gpx',
      paths: const [
        RoutePath(
          kind: RoutePathKind.track,
          points: [
            GeoPoint(latitude: 53, longitude: -1.02),
            GeoPoint(latitude: 53, longitude: -1),
          ],
        ),
      ],
      waypoints: const [],
    );
    var toggles = 0;
    final locationSharing = ValueNotifier(true);
    addTearDown(locationSharing.dispose);
    var locationToggles = 0;
    var leaves = 0;
    var ends = 0;

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: RideMapScreen(
          routeStore: InMemoryRouteStore(route),
          routeImporter: RouteImporter(source: const _NoFileSource()),
          offlineTileCache: cache,
          ridePaused: true,
          canToggleRidePause: true,
          onToggleRidePause: () async => toggles += 1,
          locationSharing: locationSharing,
          onToggleLocationSharing: () async => locationToggles += 1,
          onLeaveRide: () async => leaves += 1,
          canEndRide: true,
          onEndRide: () async => ends += 1,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('GROUP RIDE PAUSED'), findsOneWidget);
    expect(find.text('RESUME GROUP'), findsOneWidget);
    expect(find.text('PAUSE GPS'), findsOneWidget);
    await tester.tap(find.byKey(const Key('location-pause-button')));
    await tester.pump();
    expect(locationToggles, 1);
    await tester.tap(find.byKey(const Key('leave-ride-button')));
    await tester.pump();
    expect(leaves, 1);
    await tester.tap(find.byKey(const Key('ride-pause-button')));
    await tester.pump();
    expect(toggles, 1);
    expect(find.byKey(const Key('ride-end-button')), findsOneWidget);
    await tester.tap(find.byKey(const Key('ride-end-button')));
    await tester.pump();
    expect(ends, 1);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}

class _NoFileSource implements GpxImportSource {
  const _NoFileSource();

  @override
  Future<PickedGpxFile?> pickGpxFile() async => null;
}
