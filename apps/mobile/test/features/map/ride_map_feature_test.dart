import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ride_relay/controllers/speed_limit_display_controller.dart';
import 'package:ride_relay/domain/distance_unit.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/domain/route_store.dart';
import 'package:ride_relay/domain/route_alert.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/features/map/ride_map.dart';
import 'package:ride_relay/services/basemap_configuration.dart';
import 'package:ride_relay/services/gpx_import_source.dart';
import 'package:ride_relay/services/leader_ride_status.dart';
import 'package:ride_relay/services/map_style_repository.dart';
import 'package:ride_relay/services/offline_tile_cache.dart';
import 'package:ride_relay/services/route_importer.dart';
import 'package:ride_relay/services/road_routing.dart';
import 'package:ride_relay/services/speed_limit.dart';

void main() {
  test('Android group mini-map uses the local fallback', () {
    expect(
      shouldUseTiledGroupMiniMap(
        mapLibreEnabled: true,
        platform: TargetPlatform.android,
      ),
      isFalse,
    );
    expect(
      shouldUseTiledGroupMiniMap(
        mapLibreEnabled: true,
        platform: TargetPlatform.iOS,
      ),
      isTrue,
    );
  });

  test('local group mini-map follows light and dark appearance', () {
    expect(
      groupMiniMapBackgroundColor(Brightness.light),
      const Color(0xFFE9EEF3),
    );
    expect(
      groupMiniMapBackgroundColor(Brightness.dark),
      const Color(0xFF151E28),
    );
    expect(groupMiniMapGridColor(Brightness.light), const Color(0xFFB8C4D0));
    expect(groupMiniMapGridColor(Brightness.dark), const Color(0xFF263443));
  });

  testWidgets('group mini-map appears before a route is loaded', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync(
      'map-no-route-mini-map-test',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final riders = ValueNotifier<List<MapOverlayMarker>>([
      const MapOverlayMarker(
        id: 'rider-alex',
        point: GeoPoint(latitude: 53.34, longitude: -1.78),
        label: 'Alex',
      ),
      const MapOverlayMarker(
        id: 'rider-charlie',
        point: GeoPoint(latitude: 53.35, longitude: -1.79),
        label: 'Charlie',
      ),
    ]);
    addTearDown(riders.dispose);
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
          overlayMarkers: riders,
          groupRiderCount: 3,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('group-mini-map')), findsOneWidget);
    expect(find.text('3 RIDERS'), findsOneWidget);
  });

  testWidgets('opt-in mapped speed limit appears in the map view', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync(
      'map-speed-limit-test',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final cache = OfflineTileCache(
      rootDirectory: directory,
      configuration: const BasemapConfiguration(),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );
    final now = DateTime.utc(2026, 7, 24, 10);
    final navigation = ValueNotifier<MapNavigationPosition>(
      MapNavigationPosition(
        point: const GeoPoint(latitude: 51.5000, longitude: -0.12),
        recordedAt: now,
        accuracyMeters: 5,
        headingDegrees: 0,
      ),
    );
    addTearDown(navigation.dispose);
    final speedLimitDisplay = SpeedLimitDisplayController.inMemory(
      provider: _WidgetSpeedLimitProvider(),
      enabled: true,
      clock: () => now,
    );
    addTearDown(speedLimitDisplay.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: RideMapScreen(
          routeStore: InMemoryRouteStore(),
          routeImporter: RouteImporter(source: const _NoFileSource()),
          offlineTileCache: cache,
          navigationPosition: navigation,
          speedLimitDisplay: speedLimitDisplay,
        ),
      ),
    );
    await tester.pump();
    navigation.value = MapNavigationPosition(
      point: const GeoPoint(latitude: 51.5004, longitude: -0.12),
      recordedAt: now.add(const Duration(seconds: 1)),
      accuracyMeters: 5,
      headingDegrees: 0,
    );
    await speedLimitDisplay.waitForIdle();
    await tester.pump();

    expect(find.byKey(const Key('posted-speed-limit-badge')), findsOneWidget);
    expect(find.text('30'), findsOneWidget);
    expect(find.text('MPH · MAPPED'), findsOneWidget);
  });

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

    final routeStore = _RecordingRouteStore();
    final publishedRoutes = <ImportedRoute?>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: RideMapScreen(
          routeStore: routeStore,
          routeImporter: RouteImporter(source: const _NoFileSource()),
          offlineTileCache: cache,
          overlayMarkers: overlays,
          leaderStatus: leaderStatus,
          distanceUnit: DistanceUnit.miles,
          onRouteChanged: publishedRoutes.add,
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

    expect(find.text('Review route'), findsOneWidget);
    expect(
      find.text("King's Oak Academy to Cross Hands Hotel"),
      findsOneWidget,
    );
    await tester.scrollUntilVisible(
      find.byKey(const Key('confirm-reviewed-route')),
      250,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.byKey(const Key('confirm-reviewed-route')));
    for (var i = 0; i < 5; i += 1) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.byTooltip('Navigate or export route'), findsOneWidget);
    expect(routeStore.savedRoutes, hasLength(1));
    expect(publishedRoutes.whereType<ImportedRoute>(), hasLength(1));
    expect(find.textContaining('basemap configured'), findsNothing);
    expect(find.text('Download map for offline use'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('cancel keeps the authoritative route unchanged', (tester) async {
    final directory = Directory.systemTemp.createTempSync('map-cancel-test');
    addTearDown(() => directory.deleteSync(recursive: true));
    final original = _testRoute(id: 'original', name: 'Original route');
    final candidate = _testRoute(id: 'candidate', name: 'Candidate route');
    final store = _RecordingRouteStore(original);
    final published = <ImportedRoute?>[];
    final cache = OfflineTileCache(
      rootDirectory: directory,
      configuration: const BasemapConfiguration(),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: RideMapScreen(
          routeStore: store,
          routeImporter: RouteImporter(source: const _NoFileSource()),
          offlineTileCache: cache,
          changeRouteRequestToken: Object(),
          demoRouteLoader: () async => candidate,
          onRouteChanged: published.add,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Load demo route'));
    await tester.pumpAndSettle();

    expect(find.text('Review route'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const Key('cancel-reviewed-route')),
      250,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.byKey(const Key('cancel-reviewed-route')));
    await tester.pumpAndSettle();

    expect((await store.loadActiveRoute())?.id, original.id);
    expect(store.savedRoutes, isEmpty);
    expect(published.map((route) => route?.id), [original.id]);
  });

  testWidgets('loading a saved route is not reported as a new route commit', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync(
      'map-loaded-route-test',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final original = _testRoute(id: 'original', name: 'Original route');
    final store = _RecordingRouteStore(original);
    final loaded = <ImportedRoute?>[];
    final committed = <ImportedRoute?>[];
    final cache = OfflineTileCache(
      rootDirectory: directory,
      configuration: const BasemapConfiguration(),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: RideMapScreen(
          routeStore: store,
          routeImporter: RouteImporter(source: const _NoFileSource()),
          offlineTileCache: cache,
          onRouteChanged: loaded.add,
          onRouteCommitted: committed.add,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(loaded.map((route) => route?.id), [original.id]);
    expect(committed, isEmpty);
  });

  testWidgets('follow me does not misreport a missing fix as denied access', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync(
      'map-follow-location-test',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final route = _testRoute(id: 'follow', name: 'Follow route');
    final cache = OfflineTileCache(
      rootDirectory: directory,
      configuration: const BasemapConfiguration(),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: RideMapScreen(
          routeStore: _RecordingRouteStore(route),
          routeImporter: RouteImporter(source: const _NoFileSource()),
          offlineTileCache: cache,
          acquireCurrentPosition: () async => null,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('navigation-follow-button')));
    await tester.pump();

    expect(find.textContaining('Check Location Services'), findsOneWidget);
    expect(find.textContaining('Allow location access'), findsNothing);
  });

  testWidgets('switching to a new ride store removes a legacy route', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync(
      'map-new-ride-store-test',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final previousRideStore = InMemoryRouteStore(
      _testRoute(id: 'previous', name: 'Previous ride route'),
    );
    final newRideStore = InMemoryRouteStore();
    final cache = OfflineTileCache(
      rootDirectory: directory,
      configuration: const BasemapConfiguration(),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );
    RouteStore activeStore = previousRideStore;
    late StateSetter rebuild;

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return RideMapFeature(
              routeStore: activeStore,
              offlineTileCache: cache,
              mapStyleString: MapStyleRepository.fallbackStyle,
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Previous ride route'), findsOneWidget);

    rebuild(() => activeStore = newRideStore);
    await tester.pumpAndSettle();

    expect(find.text('Previous ride route'), findsNothing);
    expect(find.text('Choose a route'), findsOneWidget);
    expect(await newRideStore.loadActiveRoute(), isNull);
  });

  testWidgets('editing recalculates before one confirmed route is saved', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync('map-edit-test');
    addTearDown(() => directory.deleteSync(recursive: true));
    final store = _RecordingRouteStore();
    final search = _RecordingDestinationSearch();
    final routing = _StraightRoadRoutingService();
    final cache = OfflineTileCache(
      rootDirectory: directory,
      configuration: const BasemapConfiguration(),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: RideMapScreen(
          routeStore: store,
          routeImporter: RouteImporter(source: const _NoFileSource()),
          offlineTileCache: cache,
          acquireCurrentPosition: () async =>
              const GeoPoint(latitude: 51.45, longitude: -2.59),
          destinationRoutePlanner: DestinationRoutePlanner(
            searchService: search,
            routingService: routing,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enter destination'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('destination-field')), 'Wrong');
    await tester.tap(find.byKey(const Key('plan-destination-button')));
    await tester.pumpAndSettle();

    expect(find.textContaining('Wrong place'), findsWidgets);
    expect(store.savedRoutes, isEmpty);
    await tester.scrollUntilVisible(
      find.byKey(const Key('edit-reviewed-route')),
      250,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.byKey(const Key('edit-reviewed-route')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('destination-field')))
          .controller
          ?.text,
      'Wrong',
    );

    await tester.enterText(
      find.byKey(const Key('destination-field')),
      'Correct',
    );
    await tester.tap(find.byKey(const Key('plan-destination-button')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Correct place'), findsWidgets);
    await tester.scrollUntilVisible(
      find.byKey(const Key('confirm-reviewed-route')),
      250,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.byKey(const Key('confirm-reviewed-route')));
    await tester.pumpAndSettle();

    expect(search.queries, ['Wrong', 'Correct']);
    expect(store.savedRoutes, hasLength(1));
    expect(store.savedRoutes.single.name, 'To Correct place');
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
        maneuvers: const [
          RouteManeuver(
            position: GeoPoint(latitude: 53, longitude: -1.005),
            type: 'roundabout',
            modifier: 'right',
            name: 'Station Road',
            exitNumber: 3,
            drivingSide: 'left',
            lanes: [
              RouteLane(indications: ['left'], valid: false),
              RouteLane(indications: ['straight', 'right'], valid: true),
            ],
          ),
        ],
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
            groupRiderCount: 1,
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
      expect(find.byKey(const Key('mini-map-you-legend')), findsOneWidget);
      expect(find.byKey(const Key('mini-map-north-indicator')), findsOneWidget);
      expect(find.byKey(const Key('mini-map-scale')), findsOneWidget);
      expect(
        find.byKey(const Key('navigation-guidance-banner')),
        findsOneWidget,
      );
      expect(find.textContaining('Take exit 3 right'), findsOneWidget);
      expect(find.byIcon(Icons.roundabout_left), findsOneWidget);
      expect(find.byKey(const Key('lane-guidance')), findsOneWidget);
      expect(find.text('Station Road'), findsOneWidget);
      final arrowLayer = tester.widget<MarkerLayer>(
        find.byKey(const Key('trail-direction-arrow-layer')),
      );
      expect(arrowLayer.markers, isNotEmpty);
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
      expect(portraitMiniMap.top, greaterThanOrEqualTo(104));
      riders.value = [
        ...riders.value,
        const MapOverlayMarker(
          id: 'rider-maya',
          point: GeoPoint(latitude: 53, longitude: -1.013),
          label: 'Maya',
        ),
      ];
      await tester.pump();
      expect(find.byKey(const Key('group-mini-map')), findsOneWidget);
      expect(find.text('4 RIDERS'), findsOneWidget);
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
      expect(find.text('Follow me'), findsOneWidget);
      expect(find.byTooltip('Follow my location'), findsOneWidget);
      expect(find.byType(AppBar), findsNothing);

      await tester.tap(find.text('Follow me'));
      await tester.pump();
      expect(find.byKey(const Key('navigation-follow-button')), findsNothing);

      navigation.value = MapNavigationPosition(
        point: const GeoPoint(latitude: 53, longitude: -1.01),
        recordedAt: DateTime.utc(2026, 7, 17, 12, 1),
        speedMetersPerSecond: 0,
        headingDegrees: 90,
      );
      await tester.pump();
      expect(find.byType(AppBar), findsNothing);

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

  testWidgets('shows the paused-ride banner and a working leave button', (
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
    var leaves = 0;

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: RideMapScreen(
          routeStore: InMemoryRouteStore(route),
          routeImporter: RouteImporter(source: const _NoFileSource()),
          offlineTileCache: cache,
          ridePaused: true,
          onLeaveRide: () async => leaves += 1,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // Pausing/resuming and ending the ride are leader actions that live in
    // the ride menu (see active_ride_shell.dart), not on the map itself -
    // this only covers the paused-state banner the map still shows.
    expect(find.text('GROUP RIDE PAUSED'), findsOneWidget);
    await tester.tap(find.byKey(const Key('leave-ride-button')));
    await tester.pump();
    expect(leaves, 1);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}

class _NoFileSource implements GpxImportSource {
  const _NoFileSource();

  @override
  Future<PickedGpxFile?> pickGpxFile() async => null;
}

class _RecordingRouteStore implements RouteStore {
  _RecordingRouteStore([this.route]);

  ImportedRoute? route;
  final savedRoutes = <ImportedRoute>[];

  @override
  Future<void> clearActiveRoute() async => route = null;

  @override
  Future<ImportedRoute?> loadActiveRoute() async => route;

  @override
  Future<void> saveActiveRoute(ImportedRoute value) async {
    savedRoutes.add(value);
    route = value;
  }
}

class _RecordingDestinationSearch implements DestinationSearchService {
  final queries = <String>[];

  @override
  Future<List<DestinationMatch>> search(String query) async {
    queries.add(query);
    return [
      DestinationMatch(
        label: '$query place',
        point: GeoPoint(
          latitude: query == 'Wrong' ? 52 : 51.5,
          longitude: query == 'Wrong' ? -1 : -2.5,
        ),
      ),
    ];
  }
}

class _StraightRoadRoutingService implements RoadRoutingService {
  @override
  Future<RoadRouteResult> routeThrough(List<GeoPoint> waypoints) async =>
      RoadRouteResult(
        points: waypoints,
        distanceMeters: 12000,
        duration: const Duration(minutes: 22),
      );
}

class _WidgetSpeedLimitProvider implements SpeedLimitProvider {
  @override
  Future<SpeedLimitLookupResult> lookup({
    required SpeedLimitLocation previous,
    required SpeedLimitLocation current,
  }) async => SpeedLimitLookupResult.known(
    PostedSpeedLimit(
      milesPerHour: 30,
      source: 'Test',
      checkedAt: current.recordedAt,
      matchDistanceMeters: 2,
    ),
  );

  @override
  void close() {}
}

ImportedRoute _testRoute({required String id, required String name}) =>
    ImportedRoute(
      id: id,
      name: name,
      importedAt: DateTime.utc(2026, 7, 23),
      sourceFileName: '$id.gpx',
      paths: const [
        RoutePath(
          kind: RoutePathKind.track,
          points: [
            GeoPoint(latitude: 51.45, longitude: -2.59),
            GeoPoint(latitude: 51.46, longitude: -2.58),
          ],
        ),
      ],
      waypoints: const [],
    );
