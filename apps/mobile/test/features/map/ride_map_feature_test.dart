import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as ml;
import 'package:ride_relay/controllers/speed_limit_display_controller.dart';
import 'package:ride_relay/controllers/global_ride_heatmap_controller.dart';
import 'package:ride_relay/controllers/personal_ride_heatmap_controller.dart';
import 'package:ride_relay/domain/completed_ride.dart';
import 'package:ride_relay/domain/completed_ride_store.dart';
import 'package:ride_relay/domain/distance_unit.dart';
import 'package:ride_relay/domain/geo_point.dart' as awareness_geo;
import 'package:ride_relay/domain/hazard.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/domain/quick_message.dart';
import 'package:ride_relay/domain/recorded_route_store.dart';
import 'package:ride_relay/domain/route_authority.dart';
import 'package:ride_relay/domain/route_store.dart';
import 'package:ride_relay/domain/route_alert.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/features/map/hazard_map_symbol.dart';
import 'package:ride_relay/features/map/ride_map.dart';
import 'package:ride_relay/services/basemap_configuration.dart';
import 'package:ride_relay/services/biker_place_catalogue.dart';
import 'package:ride_relay/services/enforcement_alert_detector.dart';
import 'package:ride_relay/services/enforcement_alert_presentation.dart';
import 'package:ride_relay/services/ride_completion_detector.dart';
import 'package:ride_relay/services/gpx_import_source.dart';
import 'package:ride_relay/services/global_ride_heatmap.dart';
import 'package:ride_relay/services/imported_track_matcher.dart';
import 'package:ride_relay/services/leader_ride_status.dart';
import 'package:ride_relay/services/map_style_repository.dart';
import 'package:ride_relay/services/motorcycle_discovery.dart';
import 'package:ride_relay/services/navigation_camera.dart';
import 'package:ride_relay/services/offline_tile_cache.dart';
import 'package:ride_relay/services/received_quick_message.dart';
import 'package:ride_relay/services/route_importer.dart';
import 'package:ride_relay/services/road_routing.dart';
import 'package:ride_relay/services/speed_limit.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('motorcycle discovery hides on wide-area views', () {
    expect(
      motorcycleDiscoveryVisibleAtZoom(motorcycleDiscoveryMinimumZoom - 0.01),
      isFalse,
    );
    expect(
      motorcycleDiscoveryVisibleAtZoom(motorcycleDiscoveryMinimumZoom),
      isTrue,
    );
  });

  test(
    'personal heatmap changes from density to continuous cells at street zoom',
    () {
      expect(
        personalHeatmapUsesContinuousCells(
          personalHeatmapContinuousMinimumZoom - 0.01,
        ),
        isFalse,
      );
      expect(
        personalHeatmapUsesContinuousCells(
          personalHeatmapContinuousMinimumZoom,
        ),
        isTrue,
      );
    },
  );

  test('navigation panels preserve map context and rider clearance', () {
    expect(rideMapPrimaryPanelFill.toARGB32(), 0xD9252E39);
    expect(
      landscapeGuidancePanelWidth(
        viewportWidth: 844,
        safeRight: 0,
        leftHandTraffic: true,
      ),
      closeTo(320, 0.1),
    );
    expect(
      landscapeGuidancePanelWidth(
        viewportWidth: 844,
        safeRight: 59,
        leftHandTraffic: true,
      ),
      closeTo(276.3, 0.1),
      reason: 'a landscape notch keeps a wide but bounded guidance card',
    );
    expect(
      landscapeGuidancePanelWidth(
        viewportWidth: 667,
        safeRight: 44,
        leftHandTraffic: true,
      ),
      closeTo(232.3, 0.1),
      reason: 'compact landscape keeps a readable but bounded guidance card',
    );
  });

  test('the app compass replaces the fixed native control', () {
    final source = File(
      'lib/features/map/ride_map_feature.dart',
    ).readAsStringSync();

    expect(source, contains('compassEnabled: false'));
    expect(source, contains("Key('speed-compass-cluster')"));
    expect(source, contains("Key('ride-compass-position')"));
    expect(source, contains("properties: {'bearing': _lastHeadingDegrees}"));
    expect(source, contains("iconRotate: ['get', 'bearing']"));
    expect(source, contains("iconRotationAlignment: 'map'"));
  });

  test('the compass mode selects north-up or direction of travel (#656)', () {
    expect(
      navigationCameraBearingFor(
        orientation: NavigationMapOrientation.northUp,
        travelBearingDegrees: 287,
      ),
      0,
    );
    expect(
      navigationCameraBearingFor(
        orientation: NavigationMapOrientation.directionOfTravel,
        travelBearingDegrees: 287,
      ),
      287,
    );
  });

  test('the group mini-map does not repeat the provider banner', () {
    final source = File(
      'lib/features/map/ride_map_feature.dart',
    ).readAsStringSync();

    expect(source, isNot(contains('OpenFreeMap · © OSM')));
  });

  test('completed planned geometry is absent from both map renderers', () {
    final source = File(
      'lib/features/map/ride_map_feature.dart',
    ).readAsStringSync();

    expect(source, isNot(contains('_riddenRouteSource')));
    expect(source, isNot(contains('_progressGeometry.riddenPaths')));
    expect(source, contains('_progressGeometry.remainingPaths'));
    expect(source, contains('_trailPolylines(dashed: false)'));
    expect(
      source,
      contains('tileSize: _basemap.usesMapLibre ? 512 : 256'),
      reason: 'both renderer camera targets must carry the lateral intent',
    );
  });

  testWidgets('personal ride heatmap is optional and below the active route', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      PersonalRideHeatmapController.preferenceKey: true,
    });
    final archive = InMemoryCompletedRideStore();
    final travelled = ImportedRoute(
      id: 'travelled',
      name: 'Travelled',
      importedAt: DateTime.utc(2026, 8, 12),
      sourceFileName: 'archive',
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
    await archive.save(_completedHeatmapRide(travelled));
    final heatmap = await PersonalRideHeatmapController.load(store: archive);
    addTearDown(heatmap.dispose);
    final directory = Directory.systemTemp.createTempSync('personal-heatmap');
    addTearDown(() => directory.deleteSync(recursive: true));
    final cache = OfflineTileCache(
      rootDirectory: directory,
      configuration: const BasemapConfiguration(),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );
    addTearDown(cache.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: RideMapScreen(
          routeStore: InMemoryRouteStore(travelled),
          routeImporter: RouteImporter(source: const _NoFileSource()),
          offlineTileCache: cache,
          completedRideStore: archive,
          personalRideHeatmap: heatmap,
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('personal-rides-heatmap-layer')),
      findsOneWidget,
    );
    final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
    final heatmapIndex = map.children.indexWhere(
      (child) => child.key == const Key('personal-rides-heatmap-layer'),
    );
    final routeIndex = map.children.indexWhere(
      (child) => child is PolylineLayer,
    );
    expect(heatmapIndex, greaterThanOrEqualTo(0));
    expect(routeIndex, greaterThan(heatmapIndex));

    await tester.tap(find.byKey(const Key('map-layer-actions')));
    await tester.pumpAndSettle();
    expect(find.text('Personal rides heatmap'), findsOneWidget);
    await tester.tap(find.byKey(const Key('personal-rides-heatmap-toggle')));
    await tester.pumpAndSettle();

    expect(heatmap.visible, isFalse);
    expect(find.byKey(const Key('personal-rides-heatmap-layer')), findsNothing);
  });

  test('environment map factory can preserve original daytime tiles', () {
    final map = RideMapFeature.fromEnvironment(restrainedLightMapStyle: false);

    expect(map.basemapConfiguration.restrainedLightStyle, isFalse);
  });

  testWidgets('global heatmap is a separate optional layer below the route', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      GlobalRideHeatmapController.visibleKey: true,
      GlobalRideHeatmapController.cacheKey: jsonEncode({
        'type': 'FeatureCollection',
        'snapshotVersion': 'test',
        'snapshotDate': '2026-08-16',
        'features': [
          {
            'type': 'Feature',
            'properties': {'weight': 0.5},
            'geometry': {
              'type': 'Point',
              'coordinates': [-2.58, 51.46],
            },
          },
        ],
      }),
    });
    final global = await GlobalRideHeatmapController.load(
      client: GlobalHeatmapClient(
        baseUri: Uri.parse('https://relay.example/api/'),
        client: MockClient((_) async => throw Exception('offline')),
      ),
    );
    addTearDown(global.dispose);
    final directory = Directory.systemTemp.createTempSync('global-heatmap');
    addTearDown(() => directory.deleteSync(recursive: true));
    final cache = OfflineTileCache(
      rootDirectory: directory,
      configuration: const BasemapConfiguration(),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );
    addTearDown(cache.dispose);
    final route = ImportedRoute(
      id: 'route',
      name: 'Route',
      importedAt: DateTime.utc(2026, 8, 16),
      sourceFileName: 'route.gpx',
      paths: const [
        RoutePath(
          kind: RoutePathKind.route,
          points: [
            GeoPoint(latitude: 51.45, longitude: -2.59),
            GeoPoint(latitude: 51.47, longitude: -2.57),
          ],
        ),
      ],
      waypoints: const [],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: RideMapScreen(
          routeStore: InMemoryRouteStore(route),
          routeImporter: RouteImporter(source: const _NoFileSource()),
          offlineTileCache: cache,
          globalRideHeatmap: global,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('global-rides-heatmap-layer')), findsOneWidget);
    final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
    final globalIndex = map.children.indexWhere(
      (child) => child.key == const Key('global-rides-heatmap-layer'),
    );
    final routeIndex = map.children.indexWhere(
      (child) => child is PolylineLayer,
    );
    expect(routeIndex, greaterThan(globalIndex));

    await tester.tap(find.byKey(const Key('map-layer-actions')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('global-rides-heatmap-toggle')));
    await tester.pumpAndSettle();
    expect(global.visible, isFalse);
    expect(find.byKey(const Key('global-rides-heatmap-layer')), findsNothing);
  });

  testWidgets('free roam shows persisted café and twisty map layers', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final directory = Directory.systemTemp.createTempSync('discovery-layers');
    addTearDown(() => directory.deleteSync(recursive: true));
    final cache = OfflineTileCache(
      rootDirectory: directory,
      configuration: const BasemapConfiguration(),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );
    final currentPosition = ValueNotifier<GeoPoint?>(null);
    addTearDown(currentPosition.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: RideMapScreen(
          routeStore: InMemoryRouteStore(),
          routeImporter: RouteImporter(source: const _NoFileSource()),
          offlineTileCache: cache,
          currentPosition: currentPosition,
          discoveryCatalogueLoader: () async =>
              const MotorcycleDiscoveryCatalogue([
                MotorcycleDiscoveryFeature(
                  id: 'twisty-nearby',
                  category: MotorcycleDiscoveryCategory.twistyHighlight,
                  name: 'Nearby twisty road',
                  points: [
                    GeoPoint(latitude: 51.45, longitude: -2.55),
                    GeoPoint(latitude: 51.48, longitude: -2.50),
                  ],
                  sourceName: 'Test',
                  sourceUrl: 'https://example.test/road',
                  confidence: 'test',
                  lastVerified: '2026-08-16',
                  warning: 'Test fixture',
                ),
              ]),
          bikerPlaceCatalogueLoader: () async => const BikerPlaceCatalogue(
            places: [
              BikerPlace(
                id: 'cafe-nearby',
                name: 'Nearby biker café',
                address: 'Bristol',
                point: GeoPoint(latitude: 51.46, longitude: -2.52),
                source: 'Test',
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('map-layer-actions')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Motorcycle discovery layers'));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<CheckboxListTile>(
            find.byKey(const Key('biker-cafes-layer-toggle')),
          )
          .value,
      isTrue,
    );
    expect(
      tester
          .widget<CheckboxListTile>(
            find.byKey(const Key('discovery-layer-twisty_highlight')),
          )
          .value,
      isTrue,
    );

    Navigator.of(
      tester.element(find.byKey(const Key('biker-cafes-layer-toggle'))),
    ).pop();
    currentPosition.value = const GeoPoint(
      latitude: 51.4676,
      longitude: -2.5067,
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('free-roam-discovery-lines-layer')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('free-roam-biker-cafes-layer')),
      findsOneWidget,
    );
  });

  // #574. A handful of chosen stops are places; several hundred are the shape
  // of the line, and drawn at badge size they cover the road they describe.
  group('waypoint density decides how waypoints are drawn', () {
    test('a handful of chosen stops keep a badge worth hitting', () {
      expect(waypointCircleStyle(0).radius, 7);
      expect(waypointCircleStyle(1).radius, 7);
      expect(waypointCircleStyle(denseWaypointThreshold).radius, 7);
      expect(waypointCircleStyle(denseWaypointThreshold).opacity, 1);
    });

    test('past the threshold they become geometry, not markers', () {
      final dense = waypointCircleStyle(denseWaypointThreshold + 1);
      expect(dense.radius, lessThan(7));
      expect(dense.opacity, lessThan(1));
      // The 296 km import that was reported. Whatever the count, the style
      // must not grow back towards a badge.
      expect(waypointCircleStyle(6962).radius, dense.radius);
    });

    test('the change is big enough to see', () {
      // A dot that is only slightly smaller is still a carpet.
      expect(
        waypointCircleStyle(denseWaypointThreshold + 1).radius,
        lessThan(waypointCircleStyle(denseWaypointThreshold).radius / 1.5),
      );
    });
  });

  test('group mini-map avoids a second MapLibre surface on Android', () {
    expect(
      groupMiniMapRenderer(
        mapLibreEnabled: true,
        platform: TargetPlatform.android,
      ),
      GroupMiniMapRenderer.flutterVector,
    );
    expect(
      groupMiniMapRenderer(mapLibreEnabled: true, platform: TargetPlatform.iOS),
      GroupMiniMapRenderer.mapLibre,
    );
    expect(
      groupMiniMapRenderer(
        mapLibreEnabled: false,
        platform: TargetPlatform.android,
      ),
      GroupMiniMapRenderer.local,
    );
  });

  testWidgets('Android keeps a useful local mini-map while vector tiles load', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final directory = Directory.systemTemp.createTempSync(
      'android-vector-mini-map',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final currentPosition = ValueNotifier<GeoPoint?>(
      const GeoPoint(latitude: 51.46, longitude: -2.59),
    );
    final riders = ValueNotifier<List<MapOverlayMarker>>([
      const MapOverlayMarker(
        id: 'rider-alex',
        point: GeoPoint(latitude: 54.15, longitude: -4.48),
        label: 'Alex',
      ),
    ]);
    addTearDown(currentPosition.dispose);
    addTearDown(riders.dispose);
    final cache = OfflineTileCache(
      rootDirectory: directory,
      configuration: const BasemapConfiguration(
        styleUrl: 'https://127.0.0.1:1/style',
        attribution: 'OpenFreeMap contributors',
      ),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );
    addTearDown(cache.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: RideMapScreen(
          routeStore: InMemoryRouteStore(),
          routeImporter: RouteImporter(source: const _NoFileSource()),
          offlineTileCache: cache,
          currentPosition: currentPosition,
          overlayMarkers: riders,
          groupRiderCount: 2,
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('group-mini-map')), findsOneWidget);
    expect(
      find.byType(ml.MapLibreMap),
      findsOneWidget,
      reason: 'only the primary map may mount a native Android surface',
    );
    expect(
      find.byKey(const Key('group-mini-map-local-fallback')),
      findsOneWidget,
      reason: 'tile startup or failure must never leave a blank rectangle',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    debugDefaultTargetPlatformOverride = null;
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

  testWidgets('a routed rejoin takes over the live turn guidance', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync(
      'rejoin-navigation-guidance',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final originalRoute = ImportedRoute(
      id: 'original-route',
      name: 'Original route',
      importedAt: DateTime.utc(2026, 7, 29, 10),
      sourceFileName: 'original.gpx',
      paths: const [
        RoutePath(
          kind: RoutePathKind.track,
          points: [
            GeoPoint(latitude: 51, longitude: -2),
            GeoPoint(latitude: 51, longitude: -1.98),
          ],
        ),
      ],
      waypoints: const [],
    );
    final rejoinRoute = ImportedRoute(
      id: 'rejoin-route',
      name: 'Advisory rejoin route',
      importedAt: DateTime.utc(2026, 7, 29, 10, 5),
      sourceFileName: 'rejoin.gpx',
      paths: const [
        RoutePath(
          kind: RoutePathKind.track,
          points: [
            GeoPoint(latitude: 51.01, longitude: -2),
            GeoPoint(latitude: 51.01, longitude: -1.99),
            GeoPoint(latitude: 51, longitude: -1.98),
          ],
        ),
      ],
      waypoints: const [],
      maneuvers: const [
        RouteManeuver(
          position: GeoPoint(latitude: 51.01, longitude: -1.995),
          type: 'turn',
          modifier: 'right',
          name: 'Rejoin Road',
        ),
      ],
    );
    final rejoin = ValueNotifier<ImportedRoute?>(rejoinRoute);
    final navigation = ValueNotifier<MapNavigationPosition?>(
      MapNavigationPosition(
        point: const GeoPoint(latitude: 51.01, longitude: -1.999),
        recordedAt: DateTime.utc(2026, 7, 29, 10, 5),
        speedMetersPerSecond: 8,
        headingDegrees: 90,
        accuracyMeters: 5,
      ),
    );
    addTearDown(rejoin.dispose);
    addTearDown(navigation.dispose);
    final cache = OfflineTileCache(
      rootDirectory: directory,
      configuration: const BasemapConfiguration(),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );
    addTearDown(cache.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: RideMapScreen(
          routeStore: InMemoryRouteStore(originalRoute),
          routeImporter: RouteImporter(source: const _NoFileSource()),
          offlineTileCache: cache,
          navigationPosition: navigation,
          rejoinNavigationRoute: rejoin,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('navigation-guidance-banner')), findsOneWidget);
    expect(find.text('Rejoin Road'), findsOneWidget);

    rejoin.value = null;
    await tester.pump();

    expect(find.byKey(const Key('navigation-guidance-banner')), findsNothing);
  });

  testWidgets('pre-start map keeps riding controls and guidance hidden', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync(
      'pre-start-map-chrome',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final route = ImportedRoute(
      id: 'pre-start',
      name: 'Pre-start route',
      importedAt: DateTime.utc(2026, 7, 30),
      sourceFileName: 'pre-start.gpx',
      paths: const [
        RoutePath(
          kind: RoutePathKind.route,
          points: [
            GeoPoint(latitude: 51, longitude: -2),
            GeoPoint(latitude: 51, longitude: -1.98),
          ],
        ),
      ],
      waypoints: const [],
      maneuvers: const [
        RouteManeuver(
          position: GeoPoint(latitude: 51, longitude: -1.99),
          type: 'turn',
          modifier: 'right',
          name: 'Test Road',
        ),
      ],
    );
    final navigation = ValueNotifier<MapNavigationPosition?>(
      MapNavigationPosition(
        point: const GeoPoint(latitude: 51, longitude: -1.999),
        recordedAt: DateTime.utc(2026, 7, 30, 10),
        speedMetersPerSecond: 0,
        headingDegrees: 90,
        accuracyMeters: 5,
      ),
    );
    addTearDown(navigation.dispose);
    final cache = OfflineTileCache(
      rootDirectory: directory,
      configuration: const BasemapConfiguration(),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );
    addTearDown(cache.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: RideMapScreen(
          routeStore: InMemoryRouteStore(route),
          routeImporter: RouteImporter(source: const _NoFileSource()),
          offlineTileCache: cache,
          navigationPosition: navigation,
          rideStarted: false,
          onEmergencyAlert: () async {},
          onLeaveRide: () async {},
          onReportHazard: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    for (final key in const [
      'navigation-guidance-banner',
      'navigation-guidance-status-banner',
      'route-start-guidance-banner',
      'emergency-alert-button',
      'report-sighting-button',
      'navigation-follow-button',
      'posted-speed-limit-position',
      'ride-compass-position',
    ]) {
      expect(
        find.byKey(Key(key)),
        findsNothing,
        reason: '$key belongs to an active ride, not the pre-start map',
      );
    }

    // `leave-ride-button` was in that list until #579, and is deliberately no
    // longer. The rule this test protects — the pre-start map is not a riding
    // surface — is unchanged, and every other control above still obeys it.
    // Leaving is not a riding control though: it is a *lifecycle* one, and the
    // moment it is most wanted is exactly the moment before a ride starts,
    // when somebody has created one by mistake or changed their mind about a
    // solo run. It cost a dig through the ride menu, which is what was
    // reported on the 16 August ride.
    expect(
      find.byKey(const Key('leave-ride-button')),
      findsOneWidget,
      reason: 'leaving is a lifecycle control, not a riding one (#579)',
    );
  });

  testWidgets('a distant planned route offers directions to its start', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync(
      'route-start-guidance',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final route = ImportedRoute(
      id: 'distant-route',
      name: 'Distant route',
      importedAt: DateTime.utc(2026, 7, 30),
      sourceFileName: 'distant.gpx',
      paths: const [
        RoutePath(
          kind: RoutePathKind.route,
          points: [
            GeoPoint(latitude: 51, longitude: -2),
            GeoPoint(latitude: 51, longitude: -1.98),
          ],
        ),
      ],
      waypoints: const [],
    );
    final navigation = ValueNotifier<MapNavigationPosition?>(
      MapNavigationPosition(
        point: const GeoPoint(latitude: 51.1, longitude: -2),
        recordedAt: DateTime.utc(2026, 7, 30, 10),
        speedMetersPerSecond: 0,
        headingDegrees: 180,
        accuracyMeters: 5,
      ),
    );
    addTearDown(navigation.dispose);
    final routing = _RouteStartRoutingService();
    final cache = OfflineTileCache(
      rootDirectory: directory,
      configuration: const BasemapConfiguration(),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );
    addTearDown(cache.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: RideMapScreen(
          routeStore: InMemoryRouteStore(route),
          routeImporter: RouteImporter(source: const _NoFileSource()),
          offlineTileCache: cache,
          navigationPosition: navigation,
          roadRoutingService: routing,
          distanceUnit: DistanceUnit.miles,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('route-start-guidance-banner')),
      findsOneWidget,
    );
    expect(find.textContaining('Planned route starts'), findsOneWidget);
    expect(find.text('To start'), findsOneWidget);
    expect(
      find.byKey(const Key('navigation-guidance-status-banner')),
      findsNothing,
    );

    await tester.tap(find.byKey(const Key('navigate-to-route-start')));
    await tester.pumpAndSettle();

    expect(routing.calls, hasLength(1));
    expect(routing.calls.single.first, navigation.value!.point);
    expect(routing.calls.single.last, route.paths.first.points.first);
    expect(find.byKey(const Key('route-start-guidance-banner')), findsNothing);
    expect(find.byKey(const Key('navigation-guidance-banner')), findsOneWidget);
    expect(find.text('Road to start'), findsOneWidget);
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

  testWidgets('a reported camera and police sighting draw their symbols', (
    tester,
  ) async {
    // Issue #135, and the wiring #141 warns about: the decision travels on the
    // marker, so the renderer that runs in tests has to be drawing the same
    // symbol the native one is handed an image of.
    final directory = Directory.systemTemp.createTempSync(
      'map-hazard-symbol-test',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final reportedAt = DateTime.utc(2026, 7, 27, 12);
    HazardReport report({required String id, required HazardType type}) =>
        HazardReport(
          id: id,
          rideId: 'ride-1',
          type: type,
          severity: HazardSeverity.serious,
          position: const awareness_geo.GeoPoint(
            latitude: 53.34,
            longitude: -1.78,
          ),
          reportedAt: reportedAt,
          updatedAt: reportedAt,
          expiresAt: reportedAt.add(const Duration(hours: 2)),
          reporterId: 'rider-1',
          reporterName: 'Alex',
          source: HazardSource.rider,
        );
    final camera = HazardMapSymbols.forReport(
      report(id: 'camera', type: HazardType.speedCamera),
      now: reportedAt,
    );
    final police = HazardMapSymbols.forReport(
      report(id: 'police', type: HazardType.policeActivity),
      now: reportedAt.add(const Duration(minutes: 75)),
    );
    final overlays = ValueNotifier<List<MapOverlayMarker>>([
      MapOverlayMarker(
        id: 'hazard-camera',
        point: const GeoPoint(latitude: 53.34, longitude: -1.78),
        label: 'Speed camera · Alex just now',
        color: camera.fill,
        hazardSymbol: camera,
      ),
      MapOverlayMarker(
        id: 'hazard-police',
        point: const GeoPoint(latitude: 53.35, longitude: -1.79),
        label: 'Police activity · Alex 1 h ago · ageing',
        color: police.fill,
        hazardSymbol: police,
      ),
      // No symbol: the older generic badge, still drawn the way it always was.
      const MapOverlayMarker(
        id: 'legacy',
        point: GeoPoint(latitude: 53.36, longitude: -1.8),
        label: 'Road works',
      ),
    ]);
    addTearDown(overlays.dispose);
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
        ),
      ),
    );
    await tester.pumpAndSettle();

    final badges = tester
        .widgetList<HazardMapSymbolBadge>(find.byType(HazardMapSymbolBadge))
        .toList();
    expect(badges, hasLength(2));
    expect(badges.map((badge) => badge.symbol.glyph), [
      HazardMapGlyph.camera,
      HazardMapGlyph.police,
    ]);
    // A fresh camera and an ageing police sighting must not look the same.
    expect(badges.first.symbol.freshness, HazardMapFreshness.fresh);
    expect(badges.last.symbol.freshness, HazardMapFreshness.ageing);
    expect(badges.first.symbol.fill, isNot(badges.last.symbol.fill));
    // And the marker with no symbol keeps the generic icon badge.
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    expect(find.byTooltip('Speed camera · Alex just now'), findsOneWidget);
  });

  testWidgets(
    'follower waits for the leader instead of seeing route controls',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'map-follower-no-route-test',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
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
            routeAuthority: RouteAuthority.follower,
            rideStarted: false,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Waiting for the leader’s route'), findsOneWidget);
      expect(find.text('Choose a route'), findsNothing);
      expect(
        find.byKey(const Key('plan-destination-empty-button')),
        findsNothing,
      );
      expect(find.text('Import GPX'), findsNothing);
      expect(find.text('Use demo route'), findsNothing);
      expect(
        find.byKey(const Key('dismiss-waiting-route-prompt')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('dismiss-waiting-route-prompt')));
      await tester.pumpAndSettle();
      expect(find.text('Waiting for the leader’s route'), findsNothing);
    },
  );

  testWidgets('a started route-less ride does not block a follower', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync(
      'map-started-follower-no-route-test',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final cache = OfflineTileCache(
      rootDirectory: directory,
      configuration: const BasemapConfiguration(),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: RideMapScreen(
          routeStore: InMemoryRouteStore(),
          routeImporter: RouteImporter(source: const _NoFileSource()),
          offlineTileCache: cache,
          routeAuthority: RouteAuthority.follower,
          rideStarted: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Waiting for the leader’s route'), findsNothing);
    expect(find.text('Choose a route'), findsNothing);
  });

  testWidgets('leader can dismiss the route chooser and use the live map', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync(
      'map-leader-no-route-test',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final cache = OfflineTileCache(
      rootDirectory: directory,
      configuration: const BasemapConfiguration(),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );
    final store = InMemoryRouteStore();

    await tester.pumpWidget(
      MaterialApp(
        home: RideMapScreen(
          routeStore: store,
          routeImporter: RouteImporter(source: const _NoFileSource()),
          offlineTileCache: cache,
          rideStarted: false,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Choose a route'), findsOneWidget);
    expect(
      find.byKey(const Key('continue-without-route-button')),
      findsOneWidget,
    );
    expect(find.textContaining('A route is optional'), findsOneWidget);

    await tester.tap(find.byKey(const Key('continue-without-route-button')));
    await tester.pumpAndSettle();

    expect(find.text('Choose a route'), findsNothing);
    expect(await store.loadActiveRoute(), isNull);
  });

  testWidgets('a started route-less ride does not block its leader', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync(
      'map-started-leader-no-route-test',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final cache = OfflineTileCache(
      rootDirectory: directory,
      configuration: const BasemapConfiguration(),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: RideMapScreen(
          routeStore: InMemoryRouteStore(),
          routeImporter: RouteImporter(source: const _NoFileSource()),
          offlineTileCache: cache,
          rideStarted: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Choose a route'), findsNothing);
  });

  testWidgets('every route source is reachable on a small iPhone viewport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final directory = Directory.systemTemp.createTempSync(
      'map-small-route-chooser-test',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final cache = OfflineTileCache(
      rootDirectory: directory,
      configuration: const BasemapConfiguration(),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: RideMapScreen(
          routeStore: InMemoryRouteStore(),
          routeImporter: RouteImporter(source: const _NoFileSource()),
          offlineTileCache: cache,
          rideStarted: false,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Enter destination'), findsOneWidget);
    expect(find.text('Use a saved route'), findsOneWidget);
    await tester.ensureVisible(find.text('Import GPX'));
    expect(find.text('Import GPX'), findsOneWidget);
    await tester.ensureVisible(find.text('Use demo route'));
    expect(find.text('Use demo route'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('route picker has an explicit route-less exit', (tester) async {
    final directory = Directory.systemTemp.createTempSync(
      'map-route-picker-exit-test',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final cache = OfflineTileCache(
      rootDirectory: directory,
      configuration: const BasemapConfiguration(),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: RideMapScreen(
          routeStore: InMemoryRouteStore(),
          routeImporter: RouteImporter(source: const _NoFileSource()),
          offlineTileCache: cache,
          rideStarted: false,
          changeRouteRequestToken: Object(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('continue-without-route-sheet-item')),
      findsOneWidget,
    );
    expect(
      find.text('Use the live group map without navigation'),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const Key('continue-without-route-sheet-item')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('continue-without-route-sheet-item')),
      findsNothing,
    );
    expect(find.text('Choose a route'), findsNothing);
  });

  testWidgets('draws rider and leader trails with no route imported', (
    tester,
  ) async {
    // #100: trails come from position history, so nothing about them may depend
    // on a route being loaded or matched.
    final directory = Directory.systemTemp.createTempSync('map-no-route-trail');
    addTearDown(() => directory.deleteSync(recursive: true));
    final trails = ValueNotifier<List<MapOverlayTrace>>([
      const MapOverlayTrace(
        id: 'trail-blake',
        label: 'Blake leader trail',
        kind: RiderTrailKind.leader,
        points: [
          GeoPoint(latitude: 53, longitude: -1.02),
          GeoPoint(latitude: 53.004, longitude: -1.014),
        ],
      ),
      const MapOverlayTrace(
        id: 'trail-me',
        label: 'You trail',
        points: [
          GeoPoint(latitude: 53, longitude: -1.03),
          GeoPoint(latitude: 53.004, longitude: -1.024),
        ],
      ),
    ]);
    addTearDown(trails.dispose);
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
          riderTrails: trails,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final layer = tester.widget<PolylineLayer>(find.byType(PolylineLayer));
    expect(
      layer.polylines.map((line) => line.color),
      containsAll([
        RouteTrailStyle.leaderTrail.color,
        RouteTrailStyle.travelled.color,
      ]),
    );
    // Direction cues follow the trails too, without a route (#31).
    final arrows = tester.widget<MarkerLayer>(
      find.byKey(const Key('trail-direction-arrow-layer')),
    );
    expect(arrows.markers, isNotEmpty);
  });

  testWidgets('the map menu lists every turn for the loaded route', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync(
      'map-maneuver-list-test',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final route = ImportedRoute(
      id: 'listed',
      name: 'Listed route',
      importedAt: DateTime.utc(2026, 7, 25),
      sourceFileName: 'listed.gpx',
      paths: const [
        RoutePath(
          kind: RoutePathKind.track,
          points: [
            GeoPoint(latitude: 51.45, longitude: -2.59),
            GeoPoint(latitude: 51.46, longitude: -2.59),
            GeoPoint(latitude: 51.47, longitude: -2.59),
          ],
        ),
      ],
      waypoints: const [],
      maneuvers: const [
        RouteManeuver(
          position: GeoPoint(latitude: 51.46, longitude: -2.59),
          type: 'roundabout',
          modifier: 'slight left',
          name: 'Wells Road',
          exitNumber: 2,
          drivingSide: 'left',
          bearingBeforeDegrees: 0,
          bearingAfterDegrees: 300,
        ),
        RouteManeuver(
          position: GeoPoint(latitude: 51.4602, longitude: -2.59),
          type: 'exit roundabout',
          modifier: 'slight left',
          name: 'Wells Road',
          drivingSide: 'left',
          bearingBeforeDegrees: 40,
          bearingAfterDegrees: 2,
        ),
        RouteManeuver(
          position: GeoPoint(latitude: 51.47, longitude: -2.59),
          type: 'arrive',
        ),
      ],
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
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('All turns for this route'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('maneuver-list')), findsOneWidget);
    expect(find.text('2nd exit, straight on'), findsOneWidget);
    expect(find.text('Arrive at the destination'), findsOneWidget);
  });

  testWidgets('turn guidance reduces the TEC gap to a single-line chip', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync(
      'map-compact-tec-test',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final route = ImportedRoute(
      id: 'guided',
      name: 'Guided route',
      importedAt: DateTime.utc(2026, 7, 24),
      sourceFileName: 'guided.gpx',
      paths: const [
        RoutePath(
          kind: RoutePathKind.track,
          points: [
            GeoPoint(latitude: 51.45, longitude: -2.59),
            GeoPoint(latitude: 51.451, longitude: -2.58),
          ],
        ),
      ],
      waypoints: const [],
      maneuvers: const [
        RouteManeuver(
          position: GeoPoint(latitude: 51.451, longitude: -2.58),
          type: 'turn',
          modifier: 'right',
        ),
      ],
    );
    final navigation = ValueNotifier(
      MapNavigationPosition(
        point: const GeoPoint(latitude: 51.45, longitude: -2.59),
        recordedAt: DateTime.utc(2026, 7, 24, 12),
        speedMetersPerSecond: 10,
        headingDegrees: 90,
      ),
    );
    final leaderStatus = ValueNotifier<LeaderRideStatus?>(
      const LeaderRideStatus(
        tecName: 'Charlie',
        distanceToTecMeters: 3200,
        estimatedTimeToTec: Duration(minutes: 4),
        offCourseAlerts: [],
      ),
    );
    addTearDown(navigation.dispose);
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
          routeStore: InMemoryRouteStore(route),
          routeImporter: RouteImporter(source: const _NoFileSource()),
          offlineTileCache: cache,
          navigationPosition: navigation,
          leaderStatus: leaderStatus,
          distanceUnit: DistanceUnit.miles,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final chip = find.byKey(const Key('leader-tec-gap'));
    expect(chip, findsOneWidget);
    expect(find.text('TEC GAP'), findsNothing);
    expect(find.text('TEC'), findsOneWidget);
    expect(find.textContaining('2.0 mi · ~4 min'), findsOneWidget);
    expect(find.textContaining('Charlie ·'), findsNothing);
    expect(tester.getSize(chip).height, lessThanOrEqualTo(44));
    expect(tester.getSize(chip).width, lessThanOrEqualTo(360));
  });

  testWidgets('a registered TEC without a position yet still says so', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync(
      'map-tec-waiting-position-test',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final route = ImportedRoute(
      id: 'waiting-for-location',
      name: 'Waiting route',
      importedAt: DateTime.utc(2026, 7, 24),
      sourceFileName: 'waiting.gpx',
      paths: const [
        RoutePath(
          kind: RoutePathKind.track,
          points: [
            GeoPoint(latitude: 51.45, longitude: -2.59),
            GeoPoint(latitude: 51.451, longitude: -2.58),
          ],
        ),
      ],
      waypoints: const [],
      maneuvers: const [
        RouteManeuver(
          position: GeoPoint(latitude: 51.451, longitude: -2.58),
          type: 'turn',
          modifier: 'right',
        ),
      ],
    );
    final navigation = ValueNotifier<MapNavigationPosition?>(null);
    // A TEC that is registered but has never reported a position: no name, no
    // distance, no estimate and no location age.
    final leaderStatus = ValueNotifier<LeaderRideStatus?>(
      const LeaderRideStatus(
        tecAvailability: TecAvailability.awaitingLocation,
        offCourseAlerts: [],
      ),
    );
    addTearDown(navigation.dispose);
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
          routeStore: InMemoryRouteStore(route),
          routeImporter: RouteImporter(source: const _NoFileSource()),
          offlineTileCache: cache,
          navigationPosition: navigation,
          leaderStatus: leaderStatus,
          distanceUnit: DistanceUnit.miles,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final chip = find.byKey(const Key('leader-tec-gap'));
    expect(chip, findsOneWidget);
    expect(find.textContaining('Waiting for location'), findsOneWidget);
    expect(find.byKey(const Key('navigation-guidance-banner')), findsNothing);
    // The status band now lives in the lower part of the screen so the road
    // ahead stays visible at the top.
    final screenHeight =
        tester.view.physicalSize.height / tester.view.devicePixelRatio;
    expect(tester.getTopLeft(chip).dy, greaterThan(screenHeight / 2));
  });

  testWidgets('no registered TEC hides the distance-to-TEC surface entirely', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync('map-no-tec-test');
    addTearDown(() => directory.deleteSync(recursive: true));
    final leaderStatus = ValueNotifier<LeaderRideStatus?>(
      // No TEC identity of any kind: nobody holds the role.
      const LeaderRideStatus(offCourseAlerts: []),
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
          routeStore: InMemoryRouteStore(
            _testRoute(id: 'no-tec', name: 'No TEC route'),
          ),
          routeImporter: RouteImporter(source: const _NoFileSource()),
          offlineTileCache: cache,
          leaderStatus: leaderStatus,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('leader-tec-gap')), findsNothing);
    expect(find.textContaining('waiting for location'), findsNothing);
    expect(find.textContaining('Tail End Charlie'), findsNothing);

    // Assigning a TEC mid-ride brings the surface back without a restart.
    leaderStatus.value = const LeaderRideStatus(
      tecAvailability: TecAvailability.stale,
      tecName: 'Charlie',
      tecLocationAge: Duration(minutes: 4),
      offCourseAlerts: [],
    );
    await tester.pump();

    expect(find.byKey(const Key('leader-tec-gap')), findsOneWidget);
    expect(find.textContaining('4 min ago'), findsOneWidget);

    leaderStatus.value = const LeaderRideStatus(offCourseAlerts: []);
    await tester.pump();

    expect(find.byKey(const Key('leader-tec-gap')), findsNothing);
  });

  testWidgets('initial speed-limit lookup starts after the first map frame', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync(
      'map-speed-limit-first-frame-test',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final cache = OfflineTileCache(
      rootDirectory: directory,
      configuration: const BasemapConfiguration(),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );
    final provider = _DeferredWidgetSpeedLimitProvider();
    final speedLimitDisplay = SpeedLimitDisplayController.inMemory(
      provider: provider,
    );
    final navigation = ValueNotifier<MapNavigationPosition?>(
      MapNavigationPosition(
        point: const GeoPoint(latitude: 51.46, longitude: -2.59),
        recordedAt: DateTime.utc(2026, 8, 12, 17, 28),
        accuracyMeters: 5,
      ),
    );
    addTearDown(speedLimitDisplay.dispose);
    addTearDown(navigation.dispose);

    await tester.pumpWidget(
      AnimatedBuilder(
        animation: speedLimitDisplay,
        builder: (context, _) => MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: RideMapScreen(
            routeStore: InMemoryRouteStore(),
            routeImporter: RouteImporter(source: const _NoFileSource()),
            offlineTileCache: cache,
            navigationPosition: navigation,
            speedLimitDisplay: speedLimitDisplay,
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(
      provider.calls,
      1,
      reason: 'the lookup still starts on the first frame',
    );
    expect(speedLimitDisplay.status, SpeedLimitDisplayStatus.checking);

    provider.complete();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a rider who turned limits off can turn them back on', (
    tester,
  ) async {
    // #126 makes this on by default, so the map only offers the informed opt-in
    // to a rider who has explicitly turned it off.
    final directory = Directory.systemTemp.createTempSync(
      'map-speed-limit-opt-in-test',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final cache = OfflineTileCache(
      rootDirectory: directory,
      configuration: const BasemapConfiguration(),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );
    final speedLimitDisplay = SpeedLimitDisplayController.inMemory(
      provider: _WidgetSpeedLimitProvider(),
      enabled: false,
    );
    addTearDown(speedLimitDisplay.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: RideMapScreen(
          routeStore: InMemoryRouteStore(),
          routeImporter: RouteImporter(source: const _NoFileSource()),
          offlineTileCache: cache,
          speedLimitDisplay: speedLimitDisplay,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('speed-limit-opt-in-chip')), findsOneWidget);
    expect(find.byKey(const Key('posted-speed-limit-badge')), findsNothing);

    await tester.tap(find.byKey(const Key('speed-limit-opt-in-chip')));
    await tester.pumpAndSettle();
    expect(find.text('Show mapped speed limits?'), findsOneWidget);
    expect(find.textContaining('foreground GPS positions'), findsOneWidget);

    await tester.tap(find.byKey(const Key('confirm-speed-limit-opt-in')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('speed-limit-opt-in-chip')), findsNothing);
    expect(find.byKey(const Key('posted-speed-limit-badge')), findsOneWidget);
    // No caption under the readout (#125); the state is carried by the
    // accessibility label instead of nine-point text over the map.
    expect(find.byKey(const Key('posted-speed-limit-caption')), findsNothing);
    expect(
      tester
          .widget<Semantics>(find.byKey(const Key('posted-speed-limit-badge')))
          .properties
          .label,
      allOf(
        contains('Mapped speed limit unavailable'),
        // Named for the condition, not for a wait to move (#126).
        contains('Finding your road'),
      ),
    );
  });

  testWidgets('the mapped speed limit appears in the map view', (tester) async {
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
      speedMetersPerSecond: 20,
    );
    await speedLimitDisplay.waitForIdle();
    await tester.pump();

    expect(find.byKey(const Key('posted-speed-limit-badge')), findsOneWidget);
    expect(find.text('30'), findsOneWidget);
    // The caption is gone from the visual layer and its wording lives in the
    // accessibility label (#125).
    expect(find.byKey(const Key('posted-speed-limit-caption')), findsNothing);
    expect(
      tester
          .widget<Semantics>(find.byKey(const Key('posted-speed-limit-badge')))
          .properties
          .label,
      allOf(
        contains('Mapped speed limit 30 miles per hour'),
        contains('Mapped, not live'),
        contains('You are riding at 45 miles per hour by GPS'),
      ),
    );
    // 20 m/s is 45 mph, shown below the sign at the sign's own font size.
    final riderSpeed = tester.widget<Text>(
      find.byKey(const Key('posted-speed-limit-rider-speed')),
    );
    expect(riderSpeed.data, '45');
    expect(riderSpeed.style?.fontSize, 26);

    // This fix is moving, and since #124 a moving rider is followed with or
    // without a route, so a camera animation is genuinely in flight here. Let it
    // finish before the tree is torn down, or the map is disposed with an active
    // ticker.
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('tapping the compass toggles its orientation mode (#656)', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync('map-compass-mode');
    addTearDown(() => directory.deleteSync(recursive: true));
    final cache = OfflineTileCache(
      rootDirectory: directory,
      configuration: const BasemapConfiguration(),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );
    addTearDown(cache.dispose);
    final now = DateTime.utc(2026, 8, 23, 15);
    final navigation = ValueNotifier<MapNavigationPosition?>(
      MapNavigationPosition(
        point: const GeoPoint(latitude: 51.46765, longitude: -2.50679),
        recordedAt: now,
        accuracyMeters: 4,
        headingDegrees: 287,
        speedMetersPerSecond: 12,
      ),
    );
    addTearDown(navigation.dispose);
    final speedLimitDisplay = SpeedLimitDisplayController.inMemory(
      provider: _WidgetSpeedLimitProvider(),
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
    await speedLimitDisplay.waitForIdle();
    await tester.pumpAndSettle();

    Semantics compass() => tester.widget<Semantics>(
      find.byKey(const Key('ride-compass-position')),
    );
    expect(compass().properties.label, contains('Direction of travel'));
    expect(compass().properties.label, contains('Tap for north up'));

    await tester.tap(find.byKey(const Key('ride-compass-position')));
    await tester.pumpAndSettle();
    expect(compass().properties.label, contains('North up'));
    expect(compass().properties.label, contains('Tap for direction of travel'));

    await tester.tap(find.byKey(const Key('ride-compass-position')));
    await tester.pumpAndSettle();
    expect(compass().properties.label, contains('Direction of travel'));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('an explicitly unrestricted road renders infinity', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync(
      'map-unlimited-speed-limit-test',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final cache = OfflineTileCache(
      rootDirectory: directory,
      configuration: const BasemapConfiguration(),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );
    final now = DateTime.utc(2026, 7, 28, 10);
    final navigation = ValueNotifier<MapNavigationPosition>(
      MapNavigationPosition(
        point: const GeoPoint(latitude: 51.5, longitude: -0.12),
        recordedAt: now,
        accuracyMeters: 5,
        headingDegrees: 0,
      ),
    );
    addTearDown(navigation.dispose);
    final speedLimitDisplay = SpeedLimitDisplayController.inMemory(
      provider: const _WidgetSpeedLimitProvider(unlimited: true),
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
    await speedLimitDisplay.waitForIdle();
    await tester.pump();

    expect(find.text('∞'), findsOneWidget);
    expect(
      tester
          .widget<Semantics>(find.byKey(const Key('posted-speed-limit-badge')))
          .properties
          .label,
      contains('Mapped speed limit unrestricted'),
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  // #210: a stationary rider sends no fixes at all, because the platform stream
  // carries a distance filter. The readout therefore has to age out on its own,
  // or it sits there claiming 18 mph while the bike is parked in a lay-by.
  testWidgets('the rider speed readout ages out when the bike stops', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync('map-stale-speed');
    addTearDown(() => directory.deleteSync(recursive: true));
    final cache = OfflineTileCache(
      rootDirectory: directory,
      configuration: const BasemapConfiguration(),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );
    final now = DateTime.utc(2026, 7, 28, 9, 24);
    final navigation = ValueNotifier<MapNavigationPosition>(
      MapNavigationPosition(
        point: const GeoPoint(latitude: 54.15, longitude: -4.48),
        recordedAt: now,
        accuracyMeters: 5,
        headingDegrees: 0,
      ),
    );
    addTearDown(navigation.dispose);
    final speedLimitDisplay = SpeedLimitDisplayController.inMemory(
      provider: _WidgetSpeedLimitProvider(),
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
      point: const GeoPoint(latitude: 54.1504, longitude: -4.48),
      recordedAt: now.add(const Duration(seconds: 1)),
      accuracyMeters: 5,
      headingDegrees: 0,
      speedMetersPerSecond: 8,
    );
    await speedLimitDisplay.waitForIdle();
    await tester.pump();

    Text readout() => tester.widget<Text>(
      find.byKey(const Key('posted-speed-limit-rider-speed')),
    );

    // 8 m/s is 18 mph — the number the tester photographed.
    expect(readout().data, '18');

    // No further fix arrives, because the bike has not moved 10 m.
    await tester.pump(const Duration(seconds: 4));

    expect(readout().data, '–');

    // Pulling away reads the real speed straight away rather than climbing out
    // of the value that was held while stopped.
    navigation.value = MapNavigationPosition(
      point: const GeoPoint(latitude: 54.1508, longitude: -4.48),
      recordedAt: now.add(const Duration(seconds: 6)),
      accuracyMeters: 5,
      headingDegrees: 0,
      speedMetersPerSecond: 4,
    );
    await tester.pump();

    expect(readout().data, '9');

    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('a fix without a speed holds the readout instead of blanking it', (
    tester,
  ) async {
    // #285: "Current speed pops on for 2-3 secs then off for 4-5 seconds."
    //
    // Not the silence window expiring - that is #210's rule and is asserted
    // above. This was a fix *arriving* with no usable speed, which cleared the
    // readout outright. On Android plenty of fixes carry no speed, so the number
    // was wiped several times a minute while the rider was moving normally.
    final directory = Directory.systemTemp.createTempSync('speed-hold');
    addTearDown(() => directory.deleteSync(recursive: true));
    final cache = OfflineTileCache(
      rootDirectory: directory,
      configuration: const BasemapConfiguration(),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );
    final now = DateTime.utc(2026, 7, 31, 9);
    final navigation = ValueNotifier<MapNavigationPosition>(
      MapNavigationPosition(
        point: const GeoPoint(latitude: 54.15, longitude: -4.48),
        recordedAt: now,
        accuracyMeters: 5,
        headingDegrees: 0,
      ),
    );
    addTearDown(navigation.dispose);
    final speedLimitDisplay = SpeedLimitDisplayController.inMemory(
      provider: _WidgetSpeedLimitProvider(),
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

    Text readout() => tester.widget<Text>(
      find.byKey(const Key('posted-speed-limit-rider-speed')),
    );

    navigation.value = MapNavigationPosition(
      point: const GeoPoint(latitude: 54.1504, longitude: -4.48),
      recordedAt: now.add(const Duration(seconds: 1)),
      accuracyMeters: 5,
      headingDegrees: 0,
      speedMetersPerSecond: 8,
    );
    await speedLimitDisplay.waitForIdle();
    await tester.pump();
    expect(readout().data, '18');

    // The rider keeps moving, but this fix reports no speed.
    navigation.value = MapNavigationPosition(
      point: const GeoPoint(latitude: 54.1508, longitude: -4.48),
      recordedAt: now.add(const Duration(seconds: 2)),
      accuracyMeters: 5,
      headingDegrees: 0,
    );
    await tester.pump();

    expect(
      readout().data,
      '18',
      reason:
          'a speed-less fix means the platform reported no speed, not that '
          'the rider stopped',
    );

    // And it is still held once older than the freshness window, as long as
    // fixes keep arriving - marked as held rather than presented as current.
    navigation.value = MapNavigationPosition(
      point: const GeoPoint(latitude: 54.1512, longitude: -4.48),
      recordedAt: now.add(const Duration(seconds: 6)),
      accuracyMeters: 5,
      headingDegrees: 0,
    );
    await tester.pump();
    expect(readout().data, '18');
    expect(
      readout().style?.color,
      isNot(const Color(0xFFFFFFFF)),
      reason:
          'a held number must be visibly distinguishable from a current one',
    );

    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('reports a gloved enforcement sighting from the map', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync('map-report');
    addTearDown(() => directory.deleteSync(recursive: true));
    final cache = OfflineTileCache(
      rootDirectory: directory,
      configuration: const BasemapConfiguration(),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );
    final reported = <HazardType>[];

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: RideMapScreen(
          routeStore: InMemoryRouteStore(),
          routeImporter: RouteImporter(source: const _NoFileSource()),
          offlineTileCache: cache,
          onReportHazard: (type) async => reported.add(type),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final button = find.byKey(const Key('report-sighting-button'));
    expect(button, findsOneWidget);
    // Comfortably past the 48dp minimum target, for gloves at speed.
    expect(tester.getSize(button).shortestSide, greaterThanOrEqualTo(56));
    // The default test window is landscape, where #125 moves REPORT down into
    // the bottom-left rail with the other actions and pushes the speed sign into
    // the right-hand rail, clear of the centre column.
    final size = tester.view.physicalSize / tester.view.devicePixelRatio;
    final reportRect = tester.getRect(button);
    final speedRect = tester.getRect(
      find.byKey(const Key('posted-speed-limit-position')),
    );
    expect(reportRect.left, lessThanOrEqualTo(size.width * 0.1));
    expect(reportRect.bottom, greaterThanOrEqualTo(size.height * 0.8));
    expect(speedRect.left, greaterThanOrEqualTo(size.width * 0.55));
    expect(speedRect.right, closeTo(size.width - 10, 1));

    await tester.tap(button);
    await tester.pumpAndSettle();
    final option = find.byKey(const Key('report-speed-camera-option'));
    expect(option, findsOneWidget);
    expect(tester.getSize(option).height, greaterThanOrEqualTo(72));

    // Both targets are reachable without scrolling (#133). Stacked, the second
    // one fell below a sheet the framework caps at nine sixteenths of a landscape
    // screen, so reporting police needed a scroll.
    final police = find.byKey(const Key('report-police-option'));
    expect(
      find.byKey(const Key('report-options-side-by-side')),
      findsOneWidget,
    );
    for (final target in [option, police]) {
      final rect = tester.getRect(target);
      expect(rect.height, greaterThanOrEqualTo(72));
      expect(rect.width, greaterThanOrEqualTo(160));
      expect(
        rect.bottom,
        lessThanOrEqualTo(size.height),
        reason: 'a report target must not fall below the fold',
      );
      expect(rect.top, greaterThanOrEqualTo(0));
    }
    // Side by side, not overlapping, and both above the control that opened them
    // so a second stray tap cannot land on one.
    final cameraRect = tester.getRect(option);
    final policeRect = tester.getRect(police);
    expect(policeRect.left, greaterThanOrEqualTo(cameraRect.right));
    expect(cameraRect.top, closeTo(policeRect.top, 1));
    expect(cameraRect.bottom, lessThanOrEqualTo(reportRect.top));

    await tester.tap(option);
    await tester.pumpAndSettle();

    expect(reported, [HazardType.speedCamera]);
    expect(find.textContaining('Speed camera reported'), findsOneWidget);
  });

  testWidgets('the report sheet stacks rather than shrink a target', (
    tester,
  ) async {
    // The other half of #133's report fix. Side by side is only right while each
    // half can still hold a full-size target: a portrait phone is too narrow, and
    // so is a landscape one once the text is large enough, because the width one
    // option needs scales with its label. The answer in both cases is to stack and
    // let the sheet grow - never to shrink a target a gloved hand has to hit.
    // Portrait is the case a rider meets every ride.
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final directory = Directory.systemTemp.createTempSync('map-report-narrow');
    addTearDown(() => directory.deleteSync(recursive: true));
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
          onReportHazard: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('report-sighting-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('report-options-side-by-side')), findsNothing);
    final size = tester.view.physicalSize / tester.view.devicePixelRatio;
    final camera = tester.getRect(
      find.byKey(const Key('report-speed-camera-option')),
    );
    final police = tester.getRect(
      find.byKey(const Key('report-police-option')),
    );
    expect(camera.bottom, lessThanOrEqualTo(police.top));
    for (final rect in [camera, police]) {
      expect(rect.height, greaterThanOrEqualTo(72), reason: 'a target shrank');
      expect(rect.top, greaterThanOrEqualTo(0));
      // Still reachable without scrolling: stacking is only acceptable because
      // the sheet is now free to grow to the height it needs (#133).
      expect(rect.bottom, lessThanOrEqualTo(size.height));
    }

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('the map has no report control outside a ride', (tester) async {
    final directory = Directory.systemTemp.createTempSync('map-no-report');
    addTearDown(() => directory.deleteSync(recursive: true));
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
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('report-sighting-button')), findsNothing);
  });

  testWidgets('an approaching speed camera warns without taking the map', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync('map-enforcement');
    addTearDown(() => directory.deleteSync(recursive: true));
    final cache = OfflineTileCache(
      rootDirectory: directory,
      configuration: const BasemapConfiguration(),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );
    final now = DateTime.utc(2026, 7, 25, 12);
    final alert = ValueNotifier<EnforcementAlert?>(null);
    addTearDown(alert.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: RideMapScreen(
          routeStore: InMemoryRouteStore(),
          routeImporter: RouteImporter(source: const _NoFileSource()),
          offlineTileCache: cache,
          distanceUnit: DistanceUnit.miles,
          enforcementAlert: alert,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('enforcement-alert-overlay')), findsNothing);

    alert.value = EnforcementAlert(
      hazard: HazardReport(
        id: 'tomtom-camera-1',
        rideId: 'ride-1',
        type: HazardType.speedCamera,
        severity: HazardSeverity.serious,
        position: const awareness_geo.GeoPoint(
          latitude: 51.5,
          longitude: -3.18,
        ),
        reportedAt: now,
        updatedAt: now,
        expiresAt: now.add(const Duration(minutes: 10)),
        reporterId: 'relay-traffic',
        source: HazardSource.externalProvider,
        providerId: 'relay-traffic',
        details: 'Mobile speed camera · TomTom · updated just now',
      ),
      distanceMeters: 1207,
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('enforcement-alert-overlay')), findsOneWidget);
    expect(find.text('SPEED CAMERA'), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const Key('enforcement-alert-distance')))
          .data,
      '0.7 mi',
    );

    // #418: the warning arms a mile out, so a full-screen one took the map away
    // for the whole approach — and the only way back was a hand off the bars.
    // It is bounded now, and the map is behind it.
    final overlay = tester.getRect(
      find.byKey(const Key('enforcement-alert-overlay')),
    );
    final screen = tester.getRect(find.byType(RideMapScreen));
    // 0.75 was too generous and the first fix passed it while still covering
    // over 80% of an iPhone screen in the field — the bound has to be one a
    // rider would recognise as "part of the screen".
    expect(
      overlay.height,
      lessThan(screen.height * 0.4),
      reason: 'the warning must leave the map usable, not merely visible',
    );

    // A dismiss tap still works; it is no longer the only way out. The detector
    // already returns null once the hazard is behind the rider
    // (`enforcement_alert_detector.dart`), so passing the camera clears it.
    await tester.tap(find.byKey(const Key('enforcement-alert-overlay')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('enforcement-alert-overlay')), findsNothing);

    // A provider/GPS gap ends this approach. If the same catalogue camera then
    // re-arms, its transient popup must not inherit the previous dismissal.
    alert.value = null;
    await tester.pump();
    alert.value = EnforcementAlert(
      hazard:
          alert.value?.hazard ??
          HazardReport(
            id: 'tomtom-camera-1',
            rideId: 'ride-1',
            type: HazardType.speedCamera,
            severity: HazardSeverity.serious,
            position: const awareness_geo.GeoPoint(
              latitude: 51.5,
              longitude: -3.18,
            ),
            reportedAt: now,
            updatedAt: now,
            expiresAt: now.add(const Duration(minutes: 10)),
            reporterId: 'relay-traffic',
            source: HazardSource.externalProvider,
            providerId: 'relay-traffic',
            details: 'Mobile speed camera · TomTom · updated just now',
          ),
      distanceMeters: 700,
    );
    await tester.pump();
    expect(find.byKey(const Key('enforcement-alert-overlay')), findsOneWidget);
  });

  testWidgets('the camera warning is a top bubble clear of the rider marker, '
      'then a border alone (#446)', (tester) async {
    // Third time on this. #418's first fix still covered over 80% of a phone
    // screen; its second reached about a third of a landscape one. Each round
    // traded size for the same argument, so this measures the two things that
    // actually matter: where the bubble is, and that it goes away.
    tester.view.physicalSize = const Size(2400, 1080);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final directory = Directory.systemTemp.createTempSync('camera-bubble-test');
    addTearDown(() => directory.deleteSync(recursive: true));
    final cache = OfflineTileCache(
      rootDirectory: directory,
      configuration: const BasemapConfiguration(),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );
    final now = DateTime.now();
    final alert = ValueNotifier<EnforcementAlert?>(null);
    addTearDown(alert.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: RideMapScreen(
          routeStore: InMemoryRouteStore(),
          routeImporter: RouteImporter(source: const _NoFileSource()),
          offlineTileCache: cache,
          distanceUnit: DistanceUnit.miles,
          enforcementAlert: alert,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('enforcement-alert-border')), findsNothing);

    alert.value = EnforcementAlert(
      hazard: HazardReport(
        id: 'tomtom-camera-2',
        rideId: 'ride-1',
        type: HazardType.speedCamera,
        severity: HazardSeverity.serious,
        position: const awareness_geo.GeoPoint(
          latitude: 51.5,
          longitude: -3.18,
        ),
        reportedAt: now,
        updatedAt: now,
        expiresAt: now.add(const Duration(minutes: 10)),
        reporterId: 'relay-traffic',
        source: HazardSource.externalProvider,
        providerId: 'relay-traffic',
        details: 'Fixed speed camera · 40 mph · TomTom',
      ),
      distanceMeters: 1207,
    );
    await tester.pump();

    final bubble = tester.getRect(
      find.byKey(const Key('enforcement-alert-overlay')),
    );
    final screen = tester.getRect(find.byType(RideMapScreen));

    // The rider marker is forward-biased around the map centre. The field report
    // asked for this transient announcement at the top instead.
    expect(
      bubble.bottom,
      lessThan(screen.center.dy),
      reason: 'the bubble must stay clear of the rider marker',
    );
    expect(
      bubble.width,
      lessThanOrEqualTo(enforcementBubbleMaxWidth),
      reason: 'a notification, not a band across a landscape screen',
    );
    // Kept from #418 as a floor, not a ceiling: this should now be far under it.
    expect(bubble.height, lessThan(screen.height * 0.4));

    // The border is up from the moment the warning arms and is what carries the
    // alarm once the bubble has gone. Its *decoration* is asserted, not merely
    // its presence: with only a findsOneWidget here, deleting the border from the
    // decoration left the keyed box in place and the test passed. Found by
    // mutation, which is the whole reason for running them.
    expectRedBorder(tester);
    final border = tester.getRect(
      find.byKey(const Key('enforcement-alert-border')),
    );
    final alertLayer = tester.getRect(
      find.byKey(const Key('enforcement-alert-layer')),
    );
    expect(border.left, closeTo(alertLayer.left + enforcementBorderInset, 0.1));
    expect(border.top, closeTo(alertLayer.top + enforcementBorderInset, 0.1));
    expect(
      border.right,
      closeTo(alertLayer.right - enforcementBorderInset, 0.1),
    );
    expect(
      border.bottom,
      closeTo(alertLayer.bottom - enforcementBorderInset, 0.1),
      reason: 'the stroke must follow the visible rounded screen contour',
    );

    // Ten seconds, fixed. Distance keeps changing on an approach; the life does
    // not depend on it.
    alert.value = EnforcementAlert(
      hazard: alert.value!.hazard,
      distanceMeters: 400,
    );
    await tester.pump(enforcementBubbleLife + const Duration(seconds: 1));

    expect(
      find.byKey(const Key('enforcement-alert-overlay')),
      findsNothing,
      reason: 'the announcement is finished after ten seconds',
    );
    expectRedBorder(
      tester,
      reason: 'the border holds for the rest of approach',
    );

    // Passing the camera clears both, because the detector stops returning it.
    alert.value = null;
    await tester.pump();
    expect(find.byKey(const Key('enforcement-alert-border')), findsNothing);
  });

  testWidgets('the speed sign is enlarged on a camera approach (#446)', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync('camera-sign-test');
    addTearDown(() => directory.deleteSync(recursive: true));
    final cache = OfflineTileCache(
      rootDirectory: directory,
      configuration: const BasemapConfiguration(),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );
    final speedLimitDisplay = SpeedLimitDisplayController.inMemory(
      provider: _WidgetSpeedLimitProvider(),
      enabled: true,
    );
    addTearDown(speedLimitDisplay.dispose);
    final now = DateTime.now();
    final alert = ValueNotifier<EnforcementAlert?>(null);
    addTearDown(alert.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: RideMapScreen(
          routeStore: InMemoryRouteStore(),
          routeImporter: RouteImporter(source: const _NoFileSource()),
          offlineTileCache: cache,
          speedLimitDisplay: speedLimitDisplay,
          enforcementAlert: alert,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final ordinary = tester
        .getRect(find.byKey(const Key('posted-speed-limit-badge')))
        .width;

    alert.value = EnforcementAlert(
      hazard: HazardReport(
        id: 'tomtom-camera-3',
        rideId: 'ride-1',
        type: HazardType.speedCamera,
        severity: HazardSeverity.serious,
        position: const awareness_geo.GeoPoint(
          latitude: 51.5,
          longitude: -3.18,
        ),
        reportedAt: now,
        updatedAt: now,
        expiresAt: now.add(const Duration(minutes: 10)),
        reporterId: 'relay-traffic',
        source: HazardSource.externalProvider,
        providerId: 'relay-traffic',
        details: 'Fixed speed camera · 40 mph · TomTom',
      ),
      distanceMeters: 900,
    );
    await tester.pump();

    final onApproach = tester
        .getRect(find.byKey(const Key('posted-speed-limit-badge')))
        .width;

    // Reported as "I didn't notice a larger speed limit sign and speed on the
    // approach", so the assertion is that it is measurably larger rather than
    // merely different.
    expect(
      onApproach,
      greaterThan(ordinary * 1.3),
      reason: 'the enlargement has to be noticeable at a glance',
    );

    // And it lasts past the bubble: the rider looks down after the
    // announcement, not during it.
    await tester.pump(enforcementBubbleLife + const Duration(seconds: 1));
    expect(
      tester.getRect(find.byKey(const Key('posted-speed-limit-badge'))).width,
      onApproach,
    );
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
          rideStarted: false,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Enter destination'), findsOneWidget);
    expect(find.text('Import GPX'), findsOneWidget);
    expect(find.text('ROUTE-ONLY OFFLINE MAP'), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    expect(find.byKey(const Key('leader-tec-gap')), findsOneWidget);
    expect(find.text('TEC'), findsOneWidget);
    expect(find.textContaining('Alex is clearly off course'), findsOneWidget);
    expect(find.textContaining('2.0 mi'), findsOneWidget);
    expect(find.textContaining('0.1 mi'), findsOneWidget);

    await tester.ensureVisible(find.text('Use demo route'));
    await tester.tap(find.text('Use demo route'));
    for (var i = 0; i < 5; i += 1) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.byKey(const Key('route-review-title')), findsOneWidget);
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

  testWidgets(
    'an imported track can generate and review a navigable candidate',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'map-track-matching-test',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final original = _testRoute(id: 'source-track', name: 'Sunday route');
      final candidate = ImportedRoute(
        id: 'matched-track',
        name: 'Sunday route (navigable)',
        importedAt: DateTime.utc(2026, 8, 3),
        sourceFileName: 'matched-source-track.gpx',
        paths: original.paths,
        waypoints: original.waypoints,
        maneuvers: const [
          RouteManeuver(
            position: GeoPoint(latitude: 51.455, longitude: -2.585),
            type: 'turn',
            modifier: 'left',
          ),
        ],
      );
      final matcher = _StubImportedTrackMatcher(
        ImportedTrackMatch(
          route: candidate,
          matchedLengthMeters: 1000,
          originalLengthMeters: 1000,
          meanDeviationMeters: 4,
          maximumDeviationMeters: 11,
        ),
      );
      final savedRoutes = InMemoryRecordedRouteStore();
      final routeStore = _RecordingRouteStore();
      final cache = OfflineTileCache(
        rootDirectory: directory,
        configuration: const BasemapConfiguration(),
        httpClient: MockClient((_) async => http.Response('', 404)),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: RideMapScreen(
            routeStore: routeStore,
            routeImporter: RouteImporter(source: const _NoFileSource()),
            offlineTileCache: cache,
            demoRouteLoader: () async => original,
            importedTrackMatcher: matcher,
            recordedRouteStore: savedRoutes,
            rideStarted: false,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await tester.ensureVisible(find.text('Use demo route'));
      await tester.tap(find.text('Use demo route'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Add turn directions?'), findsOneWidget);
      expect(find.textContaining('kept in Saved routes'), findsOneWidget);

      await tester.tap(find.byKey(const Key('generate-navigable-route')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(matcher.originals, [same(original)]);
      expect(find.byKey(const Key('route-review-title')), findsOneWidget);
      expect(find.text('Sunday route (navigable)'), findsOneWidget);
      expect(
        find.byKey(const Key('route-review-original-line')),
        findsOneWidget,
      );
      expect(await savedRoutes.list(), [same(original)]);

      await tester.tap(find.byKey(const Key('confirm-reviewed-route')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(routeStore.route?.id, 'matched-track');

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets('an imported track can stay as the original offline line', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync(
      'map-original-track-test',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final original = _testRoute(id: 'source-track', name: 'Sunday route');
    final matcher = _StubImportedTrackMatcher(
      ImportedTrackMatch(
        route: original,
        matchedLengthMeters: 1000,
        originalLengthMeters: 1000,
        meanDeviationMeters: 0,
        maximumDeviationMeters: 0,
      ),
    );
    final savedRoutes = InMemoryRecordedRouteStore();
    final routeStore = _RecordingRouteStore();
    final cache = OfflineTileCache(
      rootDirectory: directory,
      configuration: const BasemapConfiguration(),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: RideMapScreen(
          routeStore: routeStore,
          routeImporter: RouteImporter(source: const _NoFileSource()),
          offlineTileCache: cache,
          demoRouteLoader: () async => original,
          importedTrackMatcher: matcher,
          recordedRouteStore: savedRoutes,
          rideStarted: false,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.ensureVisible(find.text('Use demo route'));
    await tester.tap(find.text('Use demo route'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('follow-original-track')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const Key('route-review-title')), findsOneWidget);
    expect(matcher.originals, isEmpty);
    expect(await savedRoutes.list(), [same(original)]);

    await tester.tap(find.byKey(const Key('confirm-reviewed-route')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(routeStore.route?.id, original.id);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('a failed track match keeps the active route unchanged', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync(
      'map-track-match-failure-test',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final original = _testRoute(id: 'source-track', name: 'Sunday route');
    final matcher = _StubImportedTrackMatcher.failure(
      const FormatException(
        'The road match was not confident enough. '
        'The original line is unchanged.',
      ),
    );
    final savedRoutes = InMemoryRecordedRouteStore();
    final routeStore = _RecordingRouteStore();
    final cache = OfflineTileCache(
      rootDirectory: directory,
      configuration: const BasemapConfiguration(),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: RideMapScreen(
          routeStore: routeStore,
          routeImporter: RouteImporter(source: const _NoFileSource()),
          offlineTileCache: cache,
          demoRouteLoader: () async => original,
          importedTrackMatcher: matcher,
          recordedRouteStore: savedRoutes,
          rideStarted: false,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.ensureVisible(find.text('Use demo route'));
    await tester.tap(find.text('Use demo route'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('generate-navigable-route')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(routeStore.route, isNull);
    expect(routeStore.savedRoutes, isEmpty);
    expect(await savedRoutes.list(), [same(original)]);
    expect(find.textContaining('not confident enough'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('cancel keeps the authoritative route unchanged', (tester) async {
    final directory = Directory.systemTemp.createTempSync('map-cancel-test');
    addTearDown(() => directory.deleteSync(recursive: true));
    final original = _testRoute(id: 'original', name: 'Original route');
    final candidate = _testRoute(
      id: 'candidate',
      name: 'Candidate route',
      maneuvers: const [
        RouteManeuver(
          position: GeoPoint(latitude: 51.455, longitude: -2.585),
          type: 'turn',
        ),
      ],
    );
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
    await tester.ensureVisible(find.text('Load demo route'));
    await tester.tap(find.text('Load demo route'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('route-review-title')), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const Key('cancel-reviewed-route')),
      250,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.ensureVisible(find.byKey(const Key('cancel-reviewed-route')));
    await tester.pumpAndSettle();
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
          rideStarted: false,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enter destination'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('destination-field')), 'Wrong');
    // The sheet carries the route preferences (#182), so the plan button can
    // start below the fold.
    await tester.scrollUntilVisible(
      find.byKey(const Key('plan-destination-button')),
      250,
      scrollable: find.byType(Scrollable).last,
    );
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
    // The sheet carries the route preferences (#182), so the plan button can
    // start below the fold.
    await tester.scrollUntilVisible(
      find.byKey(const Key('plan-destination-button')),
      250,
      scrollable: find.byType(Scrollable).last,
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

  testWidgets('aligns portrait ETA with the mini-map below the top controls', (
    tester,
  ) async {
    // ActiveRideShell owns the moving ride-menu button (#404), so the map does
    // not receive onOpenRideMenu in production. ETA and the mini-map still owe
    // the top row enough room for that menu, the clock and speed/compass.
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final directory = Directory.systemTemp.createTempSync(
      'map-shell-menu-space-test',
    );
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
        recordedAt: DateTime.utc(2026, 8, 14, 11),
        speedMetersPerSecond: 10,
        headingDegrees: 90,
      ),
    );
    addTearDown(navigation.dispose);
    final route = ImportedRoute(
      id: 'shell-menu-route',
      name: 'Shell menu route',
      importedAt: DateTime.utc(2026, 8, 14),
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

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: RideMapFeature(
          routeStore: InMemoryRouteStore(route),
          offlineTileCache: cache,
          mapStyleString:
              '{"version":8,"sources":{},"layers":[{"id":"background","type":"background"}]}',
          navigationPosition: navigation,
        ),
      ),
    );
    await tester.pump();
    for (var frame = 0; frame < 5; frame += 1) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.byKey(const Key('ride-menu-button')), findsNothing);
    final progress = find.byKey(const Key('route-progress-panel-position'));
    expect(progress, findsOneWidget);
    expect(
      tester.getRect(progress).top,
      closeTo(portraitNavigationHeaderTopOffset, 1),
    );

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
      final riderX = 844 * navigationCameraLandscapeRiderFractionLeftTraffic;
      expect(overlayBounds.left, greaterThan(riderX + 19));
      expect(overlayBounds.right, closeTo(844 - 10, 1));
      expect(overlayBounds.bottom, greaterThan(330));

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
          id: 'trail-alex',
          label: 'Alex off-route trace',
          kind: RiderTrailKind.offRoute,
          points: [
            GeoPoint(latitude: 53, longitude: -1.01),
            GeoPoint(latitude: 53.001, longitude: -1.011),
          ],
        ),
        const MapOverlayTrace(
          id: 'trail-blake',
          label: 'Blake leader trail',
          kind: RiderTrailKind.leader,
          points: [
            GeoPoint(latitude: 53, longitude: -1.02),
            GeoPoint(latitude: 53.002, longitude: -1.014),
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
          // The engine reports joining the ring and leaving it separately, and
          // the entry modifier describes the entry rather than the exit taken.
          RouteManeuver(
            position: GeoPoint(latitude: 53, longitude: -1.005),
            type: 'roundabout',
            modifier: 'slight left',
            name: 'Station Road',
            exitNumber: 3,
            drivingSide: 'left',
            bearingBeforeDegrees: 90,
            bearingAfterDegrees: 20,
            lanes: [
              RouteLane(indications: ['left'], valid: false),
              RouteLane(indications: ['straight', 'right'], valid: true),
            ],
          ),
          RouteManeuver(
            position: GeoPoint(latitude: 53, longitude: -1.0048),
            type: 'exit roundabout',
            modifier: 'slight right',
            name: 'Station Road',
            drivingSide: 'left',
            bearingBeforeDegrees: 150,
            bearingAfterDegrees: 180,
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
            riderTrails: traces,
            onOpenRideMenu: () async => menuOpens += 1,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.byType(AppBar), findsNothing);
      expect(find.byKey(const Key('ride-menu-button')), findsOneWidget);
      expect(find.byKey(const Key('group-mini-map')), findsOneWidget);
      expect(find.byKey(const Key('route-progress-panel')), findsOneWidget);
      final landscapeProgress = tester.getRect(
        find.byKey(const Key('route-progress-panel-position')),
      );
      final landscapeMiniMap = tester.getRect(
        find.byKey(const Key('group-mini-map')),
      );
      expect(landscapeProgress.left, closeTo(10, 1));
      expect(landscapeProgress.bottom, lessThan(landscapeMiniMap.top));
      expect(landscapeMiniMap.left, closeTo(10, 1));
      expect(landscapeMiniMap.bottom, closeTo(390 - 10, 1));
      expect(find.byKey(const Key('ride-clock')), findsOneWidget);
      expect(find.text('3 RIDERS'), findsOneWidget);
      expect(find.byKey(const Key('mini-map-you-legend')), findsOneWidget);
      expect(find.byKey(const Key('mini-map-north-indicator')), findsOneWidget);
      expect(find.byKey(const Key('mini-map-scale')), findsOneWidget);
      expect(
        find.byKey(const Key('navigation-guidance-banner')),
        findsOneWidget,
      );
      final landscapeGuidance = tester.getRect(
        find.byKey(const Key('navigation-guidance-banner')),
      );
      expect(landscapeGuidance.right, closeTo(844 - 10, 1));
      expect(landscapeGuidance.bottom, closeTo(390 - 10, 1));
      expect(landscapeGuidance.width, greaterThanOrEqualTo(300));
      expect(
        landscapeGuidance.top,
        greaterThan(390 * navigationCameraRestRiderFractionLandscape + 20),
        reason: 'the wider card must remain below the rider and road ahead',
      );
      expect(find.textContaining('3rd exit, right'), findsOneWidget);
      // The symbol beside it is a drawn roundabout, so the visible wording does
      // not repeat the word, while the label a screen reader is given - which
      // has no symbol to read - still names the junction.
      expect(find.textContaining('Roundabout, 3rd'), findsNothing);
      final semantics = tester.ensureSemantics();
      expect(
        tester
            .getSemantics(find.byKey(const Key('navigation-guidance-banner')))
            .label,
        contains('Roundabout, 3rd exit, right'),
      );
      semantics.dispose();
      // One instruction for one junction: the exit step is not announced again.
      expect(find.byKey(const Key('following-maneuver')), findsNothing);
      // The ring is drawn, not borrowed from a glyph that means the opposite.
      expect(find.byIcon(Icons.roundabout_left), findsNothing);
      expect(find.byIcon(Icons.roundabout_right), findsNothing);
      expect(find.byKey(const Key('lane-guidance')), findsOneWidget);
      expect(find.text('Station Road'), findsOneWidget);
      final arrowLayer = tester.widget<MarkerLayer>(
        find.byKey(const Key('trail-direction-arrow-layer')),
      );
      expect(arrowLayer.markers, isNotEmpty);
      // The maintainer's contract for #141: the control is on screen until the
      // camera is *locked into* the navigation viewport, and a map showing the
      // whole imported route is an overview rather than that viewport. #133 hid
      // the control on `_navigationMode` alone, which is why a phone could sit on
      // a route overview with no way to the viewport and nothing offering one.
      expect(find.byKey(const Key('navigation-follow-button')), findsOneWidget);
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
      final portraitProgress = tester.getRect(
        find.byKey(const Key('route-progress-panel-position')),
      );
      expect(portraitMiniMap.width, 150);
      // The 104 pixel canvas plus the rider-count caption, which is now in the
      // layout rather than hung below the box on a negative offset (#133) - so
      // this rect is the whole footprint an overlap test has to respect.
      expect(portraitMiniMap.height, 128);
      expect(
        tester.getRect(find.byKey(const Key('group-mini-map-canvas'))).height,
        104,
      );
      // The portrait mini-map sits below the top row occupied by menu, clock,
      // compass and speed, and stays out of the bottom band the camera's
      // forward bias pays for.
      final portraitSize =
          tester.view.physicalSize / tester.view.devicePixelRatio;
      expect(portraitMiniMap.top, lessThan(portraitSize.height / 3));
      expect(portraitMiniMap.right, closeTo(portraitSize.width - 12, 1));
      expect(portraitProgress.left, closeTo(12, 1));
      expect(
        portraitProgress.top,
        closeTo(portraitNavigationHeaderTopOffset, 1),
      );
      expect(portraitProgress.top, closeTo(portraitMiniMap.top, 1));
      expect(portraitProgress.right, lessThanOrEqualTo(portraitMiniMap.left));
      // Portrait has one clock in the persistent top row, above the cards.
      final portraitClock = find.byKey(const Key('ride-clock'));
      expect(portraitClock, findsOneWidget);
      expect(tester.getRect(portraitClock).top, closeTo(12, 1));
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
      Polyline lineWithColor(Color color) => layer.polylines.firstWhere(
        (line) => line.color == color,
        orElse: () => throw StateError('no $color line drawn'),
      );
      final ahead = lineWithColor(RouteTrailStyle.routeAhead.color);
      expect(
        ahead.pattern,
        StrokePattern.dashed(segments: RouteTrailStyle.routeAhead.dashPixels!),
      );
      expect(ahead.strokeWidth, RouteTrailStyle.routeAhead.widthPixels);
      expect(ahead.borderColor, RouteTrailStyle.casing);
      expect(ahead.color.a, 1.0);
      expect(
        layer.polylines.map((line) => line.color),
        isNot(contains(RouteTrailStyle.travelled.color)),
        reason: 'completed planned route must not be painted behind the rider',
      );
      // The leader's trail is the widest line and is drawn under the plan; an
      // off-route trail is dashed and drawn over it.
      final leader = lineWithColor(RouteTrailStyle.leaderTrail.color);
      expect(leader.strokeWidth, RouteTrailStyle.leaderTrail.widthPixels);
      expect(
        layer.polylines.indexOf(leader),
        lessThan(layer.polylines.indexOf(ahead)),
      );
      final offRoute = lineWithColor(RouteTrailStyle.offRouteTrail.color);
      expect(
        offRoute.pattern.segments,
        RouteTrailStyle.offRouteTrail.dashPixels,
      );
      expect(
        layer.polylines.indexOf(offRoute),
        greaterThan(layer.polylines.indexOf(ahead)),
      );

      await tester.drag(find.byType(FlutterMap), const Offset(80, 0));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('navigation-follow-button')), findsOneWidget);
      expect(find.text('Follow me'), findsOneWidget);
      expect(find.byTooltip('Follow my location'), findsOneWidget);
      expect(find.byType(AppBar), findsNothing);

      // Tapping takes the camera and starts easing it to the viewport. One pump
      // later it has not arrived, and a control that vanished the instant it was
      // pressed would tell the rider they were locked in before they were (#141).
      await tester.tap(find.text('Follow me'));
      await tester.pump();
      expect(find.byKey(const Key('navigation-follow-button')), findsOneWidget);

      navigation.value = MapNavigationPosition(
        point: const GeoPoint(latitude: 53, longitude: -1.01),
        recordedAt: DateTime.utc(2026, 7, 17, 12, 1),
        speedMetersPerSecond: 0,
        headingDegrees: 90,
      );
      await tester.pump();
      expect(find.byType(AppBar), findsNothing);

      // Following the rider is throttled against the wall clock, so a camera
      // animation can still be in flight here. Let it finish before the tree is
      // torn down, or the map is disposed with an active ticker.
      await tester.pumpAndSettle();
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
    // #173: the label has to name the recipient problem. An empty To: field on
    // iOS, and an Android chooser offering WhatsApp an empty number, both read
    // as a fault when nothing at the control says the rider picks who to text.
    expect(find.text('Text someone from your contacts'), findsOneWidget);
    expect(find.text('Open Messages'), findsNothing);
    expect(find.textContaining('Pick who to text'), findsOneWidget);
    // #188 dropped the old note's claim that a ride invite carries no phone
    // numbers: a rider may now have been given the leader's or TEC's. Neither
    // of these two has shared one, so no dial control is offered.
    expect(find.byKey(const Key('emergency-contact-call-lead')), findsNothing);
    expect(find.byKey(const Key('emergency-contact-call-tec')), findsNothing);
    await tester.tap(find.text('Mechanical'));
    await tester.pumpAndSettle();
    expect(sentIssues, ['mechanical']);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('offers Call and Message where a number was shared, and says so '
      'plainly where it was not', (tester) async {
    // #188. The leader has given this rider their number; the TEC has not.
    // Neither is required to, so the sheet has to read correctly either way and
    // must never hide the role that shared nothing - "they have not shared a
    // number" is information a stopped rider needs.
    final directory = Directory.systemTemp.createTempSync('contact-map-test');
    addTearDown(() => directory.deleteSync(recursive: true));
    final cache = OfflineTileCache(
      rootDirectory: directory,
      configuration: const BasemapConfiguration(),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );
    final used = <String>[];

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: RideMapScreen(
          routeStore: InMemoryRouteStore(null),
          routeImporter: RouteImporter(source: const _NoFileSource()),
          offlineTileCache: cache,
          emergencyContacts: const [
            MapEmergencyContact(
              riderId: 'lead',
              displayName: 'Oliver',
              role: RideRole.lead,
              phoneNumber: '+44 7700 900321',
              contactShareEventId: 'lead-share',
            ),
            MapEmergencyContact(
              riderId: 'tec',
              displayName: 'Charlie',
              role: RideRole.tailEndCharlie,
            ),
          ],
          onEmergencyAlert: () async {},
          onEmergencyIssue: (_) async {},
          onEmergencyContactUsed: (contact) =>
              used.add(contact.contactShareEventId ?? contact.riderId),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    await tester.tap(find.byKey(const Key('emergency-alert-button')));
    await tester.pumpAndSettle();

    // Both roles are listed, by name and role.
    expect(find.byKey(const Key('emergency-contact-lead')), findsOneWidget);
    expect(find.byKey(const Key('emergency-contact-tec')), findsOneWidget);
    expect(find.text('Oliver (leader)'), findsOneWidget);
    expect(find.text('Charlie (TEC)'), findsOneWidget);

    // The leader shared, so both dial controls are offered.
    expect(
      find.byKey(const Key('emergency-contact-call-lead')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('emergency-contact-message-lead')),
      findsOneWidget,
    );

    // The TEC did not, so it is stated rather than hidden - and there is
    // nothing to tap.
    expect(find.byKey(const Key('emergency-contact-call-tec')), findsNothing);
    expect(
      find.byKey(const Key('emergency-contact-message-tec')),
      findsNothing,
    );
    expect(
      find.textContaining('Charlie has not shared a phone number'),
      findsOneWidget,
    );

    // The number itself is never rendered: it is for dialling, not for reading
    // off a screen beside somebody's name.
    expect(find.textContaining('900321'), findsNothing);

    // #173's contacts-book fallback survives, because a rider whose leader and
    // TEC have shared nothing still needs a way out.
    expect(find.text('Text someone from your contacts'), findsOneWidget);

    // Dialling marks the share used, which is what keeps it past the ride-end
    // purge.
    await tester.tap(find.byKey(const Key('emergency-contact-call-lead')));
    await tester.pumpAndSettle();
    expect(used, ['lead-share']);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('a rider whose leader and TEC shared nothing keeps a working '
      'sheet', (tester) async {
    // The "optional throughout" half of #188: an app that has been given no
    // numbers at all still opens, still lists the roles, and still offers the
    // contacts-book route. Nothing about the feature is load-bearing.
    final directory = Directory.systemTemp.createTempSync(
      'no-contact-map-test',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final cache = OfflineTileCache(
      rootDirectory: directory,
      configuration: const BasemapConfiguration(),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: RideMapScreen(
          routeStore: InMemoryRouteStore(null),
          routeImporter: RouteImporter(source: const _NoFileSource()),
          offlineTileCache: cache,
          emergencyContacts: const [
            MapEmergencyContact(
              riderId: 'lead',
              displayName: 'Oliver',
              role: RideRole.lead,
            ),
          ],
          onEmergencyAlert: () async {},
          onEmergencyIssue: (_) async {},
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    await tester.tap(find.byKey(const Key('emergency-alert-button')));
    await tester.pumpAndSettle();

    expect(find.text('You are stopped'), findsOneWidget);
    expect(find.byKey(const Key('emergency-contact-call-lead')), findsNothing);
    expect(
      find.textContaining('Oliver has not shared a phone number'),
      findsOneWidget,
    );
    expect(find.text('Text someone from your contacts'), findsOneWidget);
    expect(find.text('Mechanical'), findsOneWidget);

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

  testWidgets('the maximum overlay set clears the upper band and itself', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final directory = Directory.systemTemp.createTempSync('map-chrome-test');
    addTearDown(() => directory.deleteSync(recursive: true));
    final route = ImportedRoute(
      id: 'chrome',
      name: 'Chrome route',
      importedAt: DateTime.utc(2026, 7, 25),
      sourceFileName: 'chrome.gpx',
      paths: const [
        RoutePath(
          kind: RoutePathKind.track,
          points: [
            GeoPoint(latitude: 53, longitude: -1.02),
            GeoPoint(latitude: 53, longitude: -1.01),
            GeoPoint(latitude: 53, longitude: -1),
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
    final navigation = ValueNotifier<MapNavigationPosition?>(
      MapNavigationPosition(
        point: const GeoPoint(latitude: 53, longitude: -1.015),
        recordedAt: DateTime.utc(2026, 7, 25, 12),
        speedMetersPerSecond: 13,
        headingDegrees: 90,
      ),
    );
    addTearDown(navigation.dispose);
    final leaderStatus = ValueNotifier<LeaderRideStatus?>(
      const LeaderRideStatus(
        tecName: 'Charlie',
        distanceToTecMeters: 3200,
        estimatedTimeToTec: Duration(minutes: 4),
        tecLocationAge: Duration(seconds: 10),
        offCourseAlerts: [
          LeaderOffCourseAlert(
            riderId: 'rider-alex',
            displayName: 'Alex',
            level: RouteAlertLevel.urgent,
            distanceFromRouteMeters: 420,
          ),
        ],
      ),
    );
    addTearDown(leaderStatus.dispose);
    final riders = ValueNotifier<List<MapOverlayMarker>>([
      const MapOverlayMarker(
        id: 'rider-alex',
        point: GeoPoint(latitude: 53, longitude: -1.011),
        label: 'Alex',
      ),
      const MapOverlayMarker(
        id: 'rider-charlie',
        point: GeoPoint(latitude: 53, longitude: -1.017),
        label: 'Charlie',
      ),
    ]);
    addTearDown(riders.dispose);
    final cache = OfflineTileCache(
      rootDirectory: directory,
      configuration: const BasemapConfiguration(),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );

    final overlayKeys = <String>[
      'route-progress-panel-position',
      'navigation-guidance-banner',
      'leader-off-course-alert',
      'leader-tec-gap',
      'group-mini-map',
      'ride-menu-button',
      'emergency-alert-button',
      'leave-ride-button',
      'report-sighting-button',
      'posted-speed-limit-position',
      'ride-compass-position',
    ];

    Future<void> verifyLayout({required bool landscape}) async {
      tester.view.physicalSize = landscape
          ? const Size(844, 390)
          : const Size(390, 844);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();

      final size = tester.view.physicalSize / tester.view.devicePixelRatio;
      expect(find.byType(AppBar), findsNothing);
      expect(find.text('GROUP RIDE PAUSED'), findsOneWidget);

      final rects = <String, Rect>{
        'ride-paused-banner': tester.getRect(find.text('GROUP RIDE PAUSED')),
      };
      for (final key in overlayKeys) {
        final finder = find.byKey(Key(key));
        expect(finder, findsOneWidget, reason: '$key is missing in $size');
        rects[key] = tester.getRect(finder);
      }

      // The small menu remains glove-sized. Portrait deliberately moves it
      // below the aligned ETA/mini-map row; landscape keeps it top-leading.
      final rideMenu = rects['ride-menu-button']!;
      expect(rideMenu.top, lessThan(size.height / 3));
      expect(rideMenu.width, lessThanOrEqualTo(48));
      expect(rideMenu.height, lessThanOrEqualTo(48));
      expect(rideMenu.left, lessThanOrEqualTo(size.width * 0.1));

      for (final entry in rects.entries) {
        expect(entry.value.left, greaterThanOrEqualTo(0));
        expect(entry.value.right, lessThanOrEqualTo(size.width));
        expect(entry.value.bottom, lessThanOrEqualTo(size.height));
      }

      // "Follow me" is absent unless the rider has earned it by taking the
      // camera over (#125). Following is active here, so it must not be present.
      expect(find.byKey(const Key('navigation-follow-button')), findsNothing);

      // Nothing covers anything else at the maximum simultaneous overlay count.
      final entries = rects.entries.toList(growable: false);
      for (var first = 0; first < entries.length; first += 1) {
        for (var second = first + 1; second < entries.length; second += 1) {
          final a = entries[first].value.deflate(0.5);
          final b = entries[second].value.deflate(0.5);
          expect(
            a.overlaps(b),
            isFalse,
            reason:
                '${entries[first].key} overlaps ${entries[second].key} in $size',
          );
        }
      }

      if (landscape) {
        // Landscape divides the screen around the traffic-side rider anchor:
        // status and actions are left, guidance is bottom-right, and nothing
        // crosses the rider or the road immediately ahead of it (#533).
        final riderX =
            size.width * navigationCameraLandscapeRiderFractionLeftTraffic;
        for (final key in const [
          'ride-paused-banner',
          'route-progress-panel-position',
          'leader-off-course-alert',
          'leader-tec-gap',
          'group-mini-map',
          'ride-menu-button',
          'emergency-alert-button',
          'leave-ride-button',
          'report-sighting-button',
        ]) {
          expect(
            rects[key]!.right,
            lessThan(riderX - 19),
            reason: '$key crosses the rider anchor in $size',
          );
        }
        for (final key in const [
          'posted-speed-limit-position',
          'ride-compass-position',
        ]) {
          expect(
            rects[key]!.left,
            greaterThan(riderX + 19),
            reason: '$key crosses the rider anchor in $size',
          );
        }

        // ETA stacks above the group overview in the bottom-left column, just
        // as it does on CarPlay. Speed remains where it was at top-right.
        final progress = rects['route-progress-panel-position']!;
        final miniMap = rects['group-mini-map']!;
        final speedLimit = rects['posted-speed-limit-position']!;
        expect(progress.left, closeTo(10, 1));
        expect(progress.bottom, lessThanOrEqualTo(miniMap.top));
        expect(miniMap.left, closeTo(10, 1));
        expect(miniMap.bottom, closeTo(size.height - 10, 1));
        expect(speedLimit.right, closeTo(size.width - 10, 1));
        expect(speedLimit.top, closeTo(10, 1));
        final compass = rects['ride-compass-position']!;
        expect(compass.right, closeTo(speedLimit.left - 8, 1));
        expect(compass.top, closeTo(speedLimit.top, 1));
        expect(compass.width, closeTo(58, 0.1));

        // The turn banner owns a wider bottom-right corner below the rider; the
        // safety actions use a vertical stack beside the mini-map.
        final guidance = rects['navigation-guidance-banner']!;
        expect(guidance.right, closeTo(size.width - 10, 1));
        expect(guidance.bottom, closeTo(size.height - 10, 1));
        expect(guidance.width, greaterThanOrEqualTo(270));
        final cameraPlan = NavigationCameraPlanner.plan(
          speedMetersPerSecond: navigationCameraFramingTopSpeedMetersPerSecond,
          landscape: true,
          viewportHeightPixels: size.height,
          viewportWidthPixels: size.width,
          bottomChromeFraction: (guidance.height + 10) / size.height,
        );
        expect(
          cameraPlan.riderViewportFraction * size.height + 19,
          lessThanOrEqualTo(guidance.top),
          reason: 'the camera must lift the rider above the wider card',
        );
        expect(rects['leader-tec-gap']!.bottom, lessThanOrEqualTo(miniMap.top));
        expect(
          rects['emergency-alert-button']!.left,
          greaterThanOrEqualTo(miniMap.right + 10),
        );
        final sos = rects['emergency-alert-button']!;
        final leave = rects['leave-ride-button']!;
        final report = rects['report-sighting-button']!;
        expect(sos.bottom, lessThanOrEqualTo(leave.top));
        expect(leave.bottom, lessThanOrEqualTo(report.top));
        expect(sos.left, closeTo(leave.left, 1));
        expect(leave.left, closeTo(report.left, 1));
      } else {
        // SOS above LEAVE (#133), not shoulder to shoulder: a mis-hit reaching
        // for SOS used to land on LEAVE and drop the rider out of the ride.
        final sos = rects['emergency-alert-button']!;
        final leave = rects['leave-ride-button']!;
        final report = rects['report-sighting-button']!;
        expect(
          sos.bottom,
          lessThanOrEqualTo(leave.top),
          reason: 'SOS must sit above LEAVE, not beside it, in $size',
        );
        expect(
          sos.left,
          closeTo(leave.left, 1),
          reason: 'the safety stack must be one column in $size',
        );
        // REPORT keeps its place beside the pair (#125) rather than adding a run.
        expect(report.left, greaterThanOrEqualTo(sos.right));
        expect(report.top, greaterThanOrEqualTo(sos.top));
        expect(report.bottom, lessThanOrEqualTo(leave.bottom + 1));
        // Every target stays glove-sized: stacking must not have shrunk one to
        // buy the height back.
        for (final target in [sos, leave, report]) {
          expect(target.height, greaterThanOrEqualTo(48));
          expect(target.width, greaterThanOrEqualTo(48));
        }
        // Speed and compass own the top-right corner rather than the bottom
        // target run. They stay above ETA/the mini-map and clear of the hand
        // reaching for the safety stack.
        final speedLimit = rects['posted-speed-limit-position']!;
        final compass = rects['ride-compass-position']!;
        expect(speedLimit.right, closeTo(size.width - 12, 1));
        expect(speedLimit.top, closeTo(12, 1));
        expect(compass.right, closeTo(speedLimit.left - 8, 1));
        expect(compass.top, closeTo(speedLimit.top, 1));
        expect(compass.width, closeTo(58, 0.1));

        // The turn banner is the last surface above the targets (#133), so all
        // the map above it is map. Nothing status-like may come between them.
        final guidance = rects['navigation-guidance-banner']!;
        expect(
          guidance.bottom,
          lessThanOrEqualTo(sos.top),
          reason:
              'the turn banner must sit directly above the targets in $size',
        );
        const targetKeys = {
          'emergency-alert-button',
          'leave-ride-button',
          'report-sighting-button',
          'posted-speed-limit-position',
          'ride-compass-position',
        };
        for (final entry in rects.entries) {
          if (entry.key == 'ride-menu-button' ||
              entry.key == 'group-mini-map' ||
              entry.key == 'route-progress-panel-position' ||
              targetKeys.contains(entry.key) ||
              entry.key == 'navigation-guidance-banner') {
            continue;
          }
          expect(
            entry.value.bottom,
            lessThanOrEqualTo(guidance.top),
            reason:
                '${entry.key} sits between the turn banner and the targets '
                'in $size',
          );
        }

        // Menu, clock and speed/compass form the top row. ETA and the mini-map
        // read as one header underneath it.
        final progress = rects['route-progress-panel-position']!;
        final miniMap = rects['group-mini-map']!;
        expect(progress.left, closeTo(12, 1));
        expect(progress.top, closeTo(portraitNavigationHeaderTopOffset, 1));
        expect(miniMap.right, closeTo(size.width - 12, 1));
        expect(miniMap.top, closeTo(progress.top, 1));
        expect(rideMenu.top, closeTo(12, 1));
        final clock = tester.getRect(find.byKey(const Key('ride-clock')));
        expect(clock.top, closeTo(12, 1));
        expect(rideMenu.bottom, lessThanOrEqualTo(progress.top));
        expect(clock.bottom, lessThanOrEqualTo(progress.top));
        expect(speedLimit.bottom, lessThanOrEqualTo(progress.top));

        // Portrait chrome is one measured band whose height the camera reads to
        // clamp its forward bias (#105). This is the absolute worst case - every
        // surface live at once - and the number that must keep coming down
        // rather than creeping back up. The same scenario measured 0.809 before
        // #125, 0.704 after it, and 0.573 now that the group overview has left
        // the band (#133); the ordinary riding case, and what the freed space
        // buys the camera, is asserted in its own test below.
        expect(_bottomChromeFraction(tester, size), lessThan(0.60));
      }
    }

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: RideMapScreen(
          routeStore: InMemoryRouteStore(route),
          routeImporter: RouteImporter(source: const _NoFileSource()),
          offlineTileCache: cache,
          navigationPosition: navigation,
          leaderStatus: leaderStatus,
          overlayMarkers: riders,
          groupRiderCount: 3,
          ridePaused: true,
          distanceUnit: DistanceUnit.miles,
          onOpenRideMenu: () async {},
          onEmergencyAlert: () async {},
          onLeaveRide: () async {},
          onReportHazard: (_) async {},
        ),
      ),
    );

    await verifyLayout(landscape: false);

    // Once a manual pan earns the portrait Follow me control, it belongs above
    // the turn pane rather than covering the rider marker or road ahead.
    await tester.dragFrom(const Offset(190, 280), const Offset(0, 90));
    await tester.pumpAndSettle();
    final follow = tester.getRect(
      find.byKey(const Key('navigation-follow-button')),
    );
    final guidance = tester.getRect(
      find.byKey(const Key('navigation-guidance-banner')),
    );
    expect(
      follow.bottom,
      lessThanOrEqualTo(guidance.top),
      reason: 'Follow me must be directly above the turn directions pane',
    );
    await tester.tap(find.byKey(const Key('navigation-follow-button')));
    await tester.pumpAndSettle();

    await verifyLayout(landscape: true);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  Future<void> pumpArrival(
    WidgetTester tester, {
    required ValueNotifier<RideCompletionAssessment?> suggestion,
    bool ridePaused = false,
    VoidCallback? onEnd,
    VoidCallback? onDismiss,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final directory = Directory.systemTemp.createTempSync('map-arrival');
    addTearDown(() => directory.deleteSync(recursive: true));
    final route = ImportedRoute(
      id: 'arrival-behaviour',
      name: 'Arrival',
      importedAt: DateTime.utc(2026, 8, 7),
      sourceFileName: 'arrival.gpx',
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
          groupRiderCount: 3,
          ridePaused: ridePaused,
          distanceUnit: DistanceUnit.miles,
          rideCompletionSuggestion: suggestion,
          onEndRideForEveryone: onEnd,
          onDismissRideCompletion: onDismiss,
          onOpenRideMenu: () async {},
          onEmergencyAlert: () async {},
          onLeaveRide: () async {},
          onReportHazard: (_) async {},
        ),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();
  }

  const arrived = RideCompletionAssessment(
    routeProgressFraction: 1,
    minimumRouteProgressFraction: 0.9,
    destinationRadiusMeters: 120,
    riderCount: 3,
    freshRiderCount: 3,
    arrivedRiderCount: 3,
  );

  testWidgets('the arrival question no longer covers the map', (tester) async {
    // The reported fault: the prompt arrived as a `showDialog`, which puts a
    // barrier across the whole surface at the one moment a rider still needs
    // to see where they are going.
    final suggestion = ValueNotifier<RideCompletionAssessment?>(arrived);
    addTearDown(suggestion.dispose);

    await pumpArrival(tester, suggestion: suggestion);

    expect(find.byKey(const Key('ride-completion-suggestion')), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    // Nothing is intercepting taps across the map.
    expect(
      find.byType(ModalBarrier).evaluate().where((element) {
        final barrier = element.widget as ModalBarrier;
        return barrier.dismissible || barrier.color != null;
      }),
      isEmpty,
    );
    // And the rider keeps the controls they were using.
    expect(find.byKey(const Key('emergency-alert-button')), findsOneWidget);
  });

  testWidgets('a paused ride never shows the arrival question', (tester) async {
    // `_maybeAutomaticallyEndRide` returns early on a paused ride, so this can
    // never happen through the shell. Guarded here too, because this is the
    // layer whose band height is measured against the cap.
    final suggestion = ValueNotifier<RideCompletionAssessment?>(arrived);
    addTearDown(suggestion.dispose);

    await pumpArrival(tester, suggestion: suggestion, ridePaused: true);

    expect(find.byKey(const Key('ride-completion-suggestion')), findsNothing);
  });

  testWidgets('the rider can wave the arrival question away', (tester) async {
    final suggestion = ValueNotifier<RideCompletionAssessment?>(arrived);
    addTearDown(suggestion.dispose);
    var dismissed = 0;

    await pumpArrival(
      tester,
      suggestion: suggestion,
      onDismiss: () {
        dismissed += 1;
        suggestion.value = null;
      },
    );
    await tester.tap(find.byKey(const Key('continue-completed-ride')));
    await tester.pumpAndSettle();

    expect(dismissed, 1);
    expect(find.byKey(const Key('ride-completion-suggestion')), findsNothing);
  });

  testWidgets('ending for everyone still asks first', (tester) async {
    // #380 was about the suggestion not blocking. Ending for everyone is
    // irreversible for the group, so it still has to go through the
    // confirmation that carries `endRideConsequence` - the map only asks.
    final suggestion = ValueNotifier<RideCompletionAssessment?>(arrived);
    addTearDown(suggestion.dispose);
    var ended = 0;

    await pumpArrival(tester, suggestion: suggestion, onEnd: () => ended += 1);
    await tester.tap(find.byKey(const Key('confirm-completed-ride')));
    await tester.pumpAndSettle();

    expect(ended, 1);
    // The map did not end anything itself; it handed the decision on.
    expect(find.byKey(const Key('ride-completion-suggestion')), findsOneWidget);
  });

  testWidgets('the arrival band stays inside the cap with the suggestion up', (
    tester,
  ) async {
    // #380 moved the arrival question out of a modal and into the band, and the
    // ticket required that be measured rather than assumed. This is the worst
    // case the suggestion can actually appear in: everything that can be live
    // at arrival, minus the two surfaces the shell guarantees it never shares
    // the band with. `_maybeAutomaticallyEndRide` returns early on a paused
    // ride and on an active marker, so the paused banner and the junction card
    // cannot be up at the same time as this.
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final directory = Directory.systemTemp.createTempSync('map-arrival-band');
    addTearDown(() => directory.deleteSync(recursive: true));

    final route = ImportedRoute(
      id: 'arrival',
      name: 'Arrival route',
      importedAt: DateTime.utc(2026, 8, 7),
      sourceFileName: 'arrival.gpx',
      paths: const [
        RoutePath(
          kind: RoutePathKind.track,
          points: [
            GeoPoint(latitude: 53, longitude: -1.02),
            GeoPoint(latitude: 53, longitude: -1.01),
            GeoPoint(latitude: 53, longitude: -1),
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

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: RideMapScreen(
          routeStore: InMemoryRouteStore(route),
          routeImporter: RouteImporter(source: const _NoFileSource()),
          offlineTileCache: cache,
          navigationPosition: ValueNotifier(
            MapNavigationPosition(
              point: const GeoPoint(latitude: 53, longitude: -1.005),
              recordedAt: DateTime.utc(2026, 8, 7, 12),
              speedMetersPerSecond: 8,
              headingDegrees: 90,
            ),
          ),
          groupRiderCount: 3,
          distanceUnit: DistanceUnit.miles,
          rideCompletionSuggestion: ValueNotifier(
            const RideCompletionAssessment(
              routeProgressFraction: 1,
              minimumRouteProgressFraction: 0.9,
              destinationRadiusMeters: 120,
              riderCount: 3,
              freshRiderCount: 3,
              arrivedRiderCount: 3,
            ),
          ),
          onEndRideForEveryone: () {},
          onDismissRideCompletion: () {},
          onOpenRideMenu: () async {},
          onEmergencyAlert: () async {},
          onLeaveRide: () async {},
          onReportHazard: (_) async {},
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('ride-completion-suggestion')), findsOneWidget);
    final size = tester.view.physicalSize / tester.view.devicePixelRatio;
    // 0.438 measured, against the 0.60 cap. The modal it replaces covered the
    // whole viewport, so this is the number that matters: the arrival question
    // now costs a rider less than half the screen instead of all of it.
    expect(_bottomChromeFraction(tester, size), lessThan(0.60));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('the decluttered portrait band lets the camera look ahead', (
    tester,
  ) async {
    // #125 frees vertical space for #105's forward bias. Ordinary riding - a
    // turn banner, the action row and the speed sign, no paused ride, no
    // off-course alert, no group overview - is the case that has to stop
    // clamping. The same scenario measured a 431 pixel band before this change,
    // which held the rider at 0.429 of the viewport and aimed the camera 60
    // pixels *behind* the bike.
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final directory = Directory.systemTemp.createTempSync('map-camera-band');
    addTearDown(() => directory.deleteSync(recursive: true));

    final route = ImportedRoute(
      id: 'bias',
      name: 'Bias route',
      importedAt: DateTime.utc(2026, 7, 26),
      sourceFileName: 'bias.gpx',
      paths: const [
        RoutePath(
          kind: RoutePathKind.track,
          points: [
            GeoPoint(latitude: 53, longitude: -1.02),
            GeoPoint(latitude: 53, longitude: -1.01),
            GeoPoint(latitude: 53, longitude: -1),
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
    final navigation = ValueNotifier<MapNavigationPosition?>(
      MapNavigationPosition(
        point: const GeoPoint(latitude: 53, longitude: -1.015),
        recordedAt: DateTime.utc(2026, 7, 26, 12),
        speedMetersPerSecond: 13,
        headingDegrees: 90,
        accuracyMeters: 5,
      ),
    );
    addTearDown(navigation.dispose);
    final speedLimitDisplay = SpeedLimitDisplayController.inMemory();
    addTearDown(speedLimitDisplay.dispose);
    NavigationCameraViewport? projectedViewport;
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
          navigationPosition: navigation,
          distanceUnit: DistanceUnit.miles,
          speedLimitDisplay: speedLimitDisplay,
          onOpenRideMenu: () async {},
          onEmergencyAlert: () async {},
          onLeaveRide: () async {},
          onReportHazard: (_) async {},
          onNavigationViewportChanged: (viewport) {
            projectedViewport = viewport;
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();

    final size = tester.view.physicalSize / tester.view.devicePixelRatio;
    expect(find.byKey(const Key('navigation-guidance-banner')), findsOneWidget);
    final bottomChromeFraction = _bottomChromeFraction(tester, size);
    expect(bottomChromeFraction, lessThan(0.38));

    final plan = NavigationCameraPlanner.plan(
      speedMetersPerSecond: 13,
      landscape: false,
      viewportHeightPixels: size.height,
      latitudeDegrees: 53,
      bottomChromeFraction: bottomChromeFraction,
    );
    // Positive bias means the camera is aimed up the road rather than behind the
    // rider, and the marker sits below the centre of the frame where #105 wants
    // it. The band no longer pushes it past the middle.
    expect(plan.forwardBiasPixels, greaterThan(0));
    expect(plan.riderViewportFraction, greaterThan(0.5));
    expect(projectedViewport, isNotNull);
    expect(projectedViewport!.latitude, closeTo(53, 0.01));
    expect(projectedViewport!.longitude, greaterThan(-1.015));
    expect(projectedViewport!.zoom, closeTo(plan.zoom, 0.01));
    expect(projectedViewport!.tilt, 0);
    expect(projectedViewport!.sourceViewportHeightPixels, size.height);
    expect(projectedViewport!.sourceViewportWidthPixels, size.width);
    expect(
      projectedViewport!.riderViewportFraction,
      inInclusiveRange(navigationCameraMinimumRiderFraction, 0.72),
    );
    expect(projectedViewport!.riderHorizontalViewportFraction, 0.5);
    expect(projectedViewport!.mapStyleUrl, isEmpty);
    expect(projectedViewport!.mapStyleJson, MapStyleRepository.fallbackStyle);
    // Each round of decluttering has to buy the camera real look-ahead, so both
    // previous bands are held against this one: 431 pixels before #125, 342
    // after it, 296 now that the group overview has left the band (#133).
    for (final previousBand in [431.0, 342.0]) {
      final previous = NavigationCameraPlanner.plan(
        speedMetersPerSecond: 13,
        landscape: false,
        viewportHeightPixels: size.height,
        latitudeDegrees: 53,
        bottomChromeFraction: previousBand / size.height,
      );
      expect(
        plan.riderViewportFraction,
        greaterThan(previous.riderViewportFraction),
        reason: 'the band must keep buying look-ahead, not give it back',
      );
      expect(plan.lookAheadMeters, greaterThan(previous.lookAheadMeters));
    }

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  // #608. `build` anchors the bottom rail at `overlayBottom` — the system inset
  // plus a host's bar — and says of it that the camera's bottom-chrome fraction
  // "measures this band too and has to agree with what is drawn in it". It did
  // not: the two measurements the camera was given report how tall the rail is
  // and not how far above the display's bottom edge it starts, so the camera
  // aimed as though the band ran to the very bottom of the map.
  testWidgets('the follow camera counts the host bar the rail is drawn above', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync('host-band');
    addTearDown(() => directory.deleteSync(recursive: true));

    final route = ImportedRoute(
      id: 'band',
      name: 'Band route',
      importedAt: DateTime.utc(2026, 8, 19),
      sourceFileName: 'band.gpx',
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
      maneuvers: const [],
    );

    Future<double> riderFractionWith({
      required double hostBottomInset,
      required bool landscape,
    }) async {
      SharedPreferences.setMockInitialValues({});
      // Landscape matters more than portrait here, and is where the report
      // came from: the viewport is less than half as tall, so the same bar is a
      // far larger share of it and the rest fraction is higher to begin with.
      tester.view.devicePixelRatio = 3;
      tester.view.physicalSize = landscape
          ? const Size(874 * 3, 402 * 3)
          : const Size(402 * 3, 874 * 3);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final navigation = ValueNotifier<MapNavigationPosition?>(
        MapNavigationPosition(
          point: const GeoPoint(latitude: 53, longitude: -1.015),
          recordedAt: DateTime.utc(2026, 8, 19, 12),
          speedMetersPerSecond: 13,
          headingDegrees: 90,
          accuracyMeters: 5,
        ),
      );
      addTearDown(navigation.dispose);
      final speedLimitDisplay = SpeedLimitDisplayController.inMemory();
      addTearDown(speedLimitDisplay.dispose);
      final cache = OfflineTileCache(
        rootDirectory: directory,
        configuration: const BasemapConfiguration(),
        httpClient: MockClient((_) async => http.Response('', 404)),
      );
      addTearDown(cache.dispose);
      NavigationCameraViewport? viewport;

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: RideMapScreen(
            routeStore: InMemoryRouteStore(route),
            routeImporter: RouteImporter(source: const _NoFileSource()),
            offlineTileCache: cache,
            navigationPosition: navigation,
            distanceUnit: DistanceUnit.miles,
            speedLimitDisplay: speedLimitDisplay,
            routeAuthority: RouteAuthority.personal,
            hostChrome: HostMapChrome(
              title: const Text('Where to?'),
              actions: const [],
              bottomInset: hostBottomInset,
            ),
            onNavigationViewportChanged: (value) => viewport = value,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();

      expect(viewport, isNotNull);
      final fraction = viewport!.riderViewportFraction;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      return fraction;
    }

    // The bar Home stands on this map (`HomeRideActions.reservedHeight`).
    for (final landscape in [false, true]) {
      final where = landscape ? 'landscape' : 'portrait';
      final withBar = await riderFractionWith(
        hostBottomInset: 84,
        landscape: landscape,
      );
      final withoutBar = await riderFractionWith(
        hostBottomInset: 0,
        landscape: landscape,
      );

      expect(
        withBar,
        lessThanOrEqualTo(withoutBar),
        reason:
            'in $where a bar standing on the map is 84 pixels the camera may '
            'not aim into, so it must never push the rider down the frame',
      );

      // And the rider-facing claim: the marker, not its centre, clear of the
      // bar. The reported symptom was in landscape, where the viewport is 402
      // points tall and the bar plus its safe inset is a quarter of it.
      final height = landscape ? 402.0 : 874.0;
      const markerRadius = 22.0;
      expect(
        withBar * height + markerRadius,
        lessThan(height - 84),
        reason: 'the marker is still behind the bar in $where',
      );
    }
  });

  // #613. Landscape puts the rider two thirds across the frame on the left and
  // one third across on the right, so this boolean does not degrade the view —
  // it mirrors it. Ride 723888, 17 miles around Bristol, came back with 46
  // manoeuvres annotated `right` and 23 `left`, and the majority vote this
  // replaces therefore framed a British ride for the continent.
  testWidgets(
    'a British route keeps the bike in the right third of landscape',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final directory = Directory.systemTemp.createTempSync('traffic-side');
      addTearDown(() => directory.deleteSync(recursive: true));
      tester.view.devicePixelRatio = 3;
      tester.view.physicalSize = const Size(874 * 3, 402 * 3);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      RouteManeuver step(double longitude, String? side) => RouteManeuver(
        position: GeoPoint(latitude: 51.45, longitude: longitude),
        type: 'turn',
        modifier: 'right',
        name: 'Cornbrash Park',
        drivingSide: side,
      );

      final route = ImportedRoute(
        id: 'side',
        name: 'Bristol',
        importedAt: DateTime.utc(2026, 8, 19),
        sourceFileName: 'bristol.gpx',
        paths: const [
          RoutePath(
            kind: RoutePathKind.track,
            points: [
              GeoPoint(latitude: 51.45, longitude: -2.6),
              GeoPoint(latitude: 51.45, longitude: -2.1),
            ],
          ),
        ],
        waypoints: const [],
        // The ride's own proportions: `right` in the clear majority, `left`
        // stated on a minority of steps.
        maneuvers: [
          step(-2.55, 'right'),
          step(-2.50, 'right'),
          step(-2.45, 'left'),
          step(-2.40, 'right'),
          step(-2.35, 'right'),
          step(-2.30, 'left'),
          step(-2.25, 'right'),
        ],
      );

      final navigation = ValueNotifier<MapNavigationPosition?>(
        MapNavigationPosition(
          point: const GeoPoint(latitude: 51.45, longitude: -2.4),
          recordedAt: DateTime.utc(2026, 8, 19, 17),
          speedMetersPerSecond: 13,
          headingDegrees: 90,
          accuracyMeters: 5,
        ),
      );
      addTearDown(navigation.dispose);
      final speedLimitDisplay = SpeedLimitDisplayController.inMemory();
      addTearDown(speedLimitDisplay.dispose);
      final cache = OfflineTileCache(
        rootDirectory: directory,
        configuration: const BasemapConfiguration(),
        httpClient: MockClient((_) async => http.Response('', 404)),
      );
      addTearDown(cache.dispose);
      NavigationCameraViewport? viewport;

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: RideMapScreen(
            routeStore: InMemoryRouteStore(route),
            routeImporter: RouteImporter(source: const _NoFileSource()),
            offlineTileCache: cache,
            navigationPosition: navigation,
            distanceUnit: DistanceUnit.miles,
            speedLimitDisplay: speedLimitDisplay,
            routeAuthority: RouteAuthority.personal,
            onNavigationViewportChanged: (value) => viewport = value,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();

      expect(viewport, isNotNull);
      expect(
        viewport!.riderHorizontalViewportFraction,
        closeTo(navigationCameraLandscapeRiderFractionLeftTraffic, 1e-9),
        reason:
            'one third across is the continental frame, and this ride was in '
            'Bristol',
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  // #619. Reported from ride 723888: "the sos and other buttons somehow end up
  // aligned to the middle of the screen" in landscape. The layout decides where
  // the safety cluster goes by asking whether a mini-map exists, and the solo
  // mini-map was `SizedBox.shrink()` — an invisible widget that answered yes.
  // Every solo ride therefore reserved 240pt of corner for nothing and exiled
  // SOS/LEAVE/REPORT to the middle of the map.
  group('the landscape safety cluster anchors to what is actually drawn', () {
    Future<Rect> clusterRect(
      WidgetTester tester, {
      required List<MapOverlayMarker> riders,
      required int groupRiderCount,
    }) async {
      SharedPreferences.setMockInitialValues({});
      final directory = Directory.systemTemp.createTempSync('cluster-anchor');
      addTearDown(() => directory.deleteSync(recursive: true));
      tester.view.devicePixelRatio = 3;
      tester.view.physicalSize = const Size(874 * 3, 402 * 3);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final cache = OfflineTileCache(
        rootDirectory: directory,
        configuration: const BasemapConfiguration(),
        httpClient: MockClient((_) async => http.Response('', 404)),
      );
      addTearDown(cache.dispose);
      final currentPosition = ValueNotifier<GeoPoint?>(
        const GeoPoint(latitude: 51.46, longitude: -2.59),
      );
      addTearDown(currentPosition.dispose);
      final overlays = ValueNotifier<List<MapOverlayMarker>>(riders);
      addTearDown(overlays.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: RideMapScreen(
            routeStore: InMemoryRouteStore(),
            routeImporter: RouteImporter(source: const _NoFileSource()),
            offlineTileCache: cache,
            rideStarted: true,
            currentPosition: currentPosition,
            overlayMarkers: overlays,
            groupRiderCount: groupRiderCount,
            onEmergencyAlert: () async {},
            onLeaveRide: () async {},
            onReportHazard: (_) async {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      final rect = tester.getRect(
        find.byKey(const Key('map-landscape-action-position')),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      return rect;
    }

    testWidgets('a solo ride keeps SOS, LEAVE and REPORT in the corner', (
      tester,
    ) async {
      final rect = await clusterRect(
        tester,
        riders: const [],
        groupRiderCount: 1,
      );
      expect(
        rect.left,
        lessThan(120),
        reason:
            'no mini-map is drawn on a solo ride, so nothing may push the '
            'safety cluster off its corner — mid-screen is where the road is',
      );
    });

    testWidgets('a group ride sits the cluster beside the real mini-map', (
      tester,
    ) async {
      final rect = await clusterRect(
        tester,
        riders: const [
          MapOverlayMarker(
            id: 'rider-alex',
            point: GeoPoint(latitude: 51.47, longitude: -2.58),
            label: 'Alex',
          ),
        ],
        groupRiderCount: 2,
      );
      // The mini-map is genuinely there (two riders), so #533's layout holds:
      // the cluster clears it to the right rather than stacking on top of it.
      expect(rect.left, greaterThan(230));
    });
  });

  // #615. Ride 723888's rider followed a route for 48 minutes and could not
  // find how to stop: the only exit was the overflow menu's "Remove route",
  // an unlabelled ellipsis and a scroll away. The ETA card is the surface that
  // says "you are navigating", so it carries the way to stop — in words (#306).
  group('free roam can stop navigating from the card that says it is', () {
    Future<
      ({InMemoryRouteStore store, ValueNotifier<MapNavigationPosition?> nav})
    >
    pumpNavigating(WidgetTester tester, {required bool freeRoam}) async {
      SharedPreferences.setMockInitialValues({});
      final directory = Directory.systemTemp.createTempSync('stop-navigating');
      addTearDown(() => directory.deleteSync(recursive: true));
      final route = ImportedRoute(
        id: 'stop',
        name: 'To Bath',
        importedAt: DateTime.utc(2026, 8, 20),
        sourceFileName: 'bath.gpx',
        paths: const [
          RoutePath(
            kind: RoutePathKind.track,
            points: [
              GeoPoint(latitude: 51.45, longitude: -2.60),
              GeoPoint(latitude: 51.44, longitude: -2.50),
              GeoPoint(latitude: 51.39, longitude: -2.36),
            ],
          ),
        ],
        waypoints: const [],
        maneuvers: const [
          RouteManeuver(
            position: GeoPoint(latitude: 51.44, longitude: -2.50),
            type: 'turn',
            modifier: 'right',
            name: 'A4',
            drivingSide: 'left',
          ),
        ],
      );
      final store = InMemoryRouteStore(route);
      final navigation = ValueNotifier<MapNavigationPosition?>(
        MapNavigationPosition(
          point: const GeoPoint(latitude: 51.449, longitude: -2.59),
          recordedAt: DateTime.utc(2026, 8, 20, 9),
          speedMetersPerSecond: 13,
          headingDegrees: 95,
          accuracyMeters: 5,
        ),
      );
      addTearDown(navigation.dispose);
      final cache = OfflineTileCache(
        rootDirectory: directory,
        configuration: const BasemapConfiguration(),
        httpClient: MockClient((_) async => http.Response('', 404)),
      );
      addTearDown(cache.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: RideMapScreen(
            routeStore: store,
            routeImporter: RouteImporter(source: const _NoFileSource()),
            offlineTileCache: cache,
            navigationPosition: navigation,
            routeAuthority: RouteAuthority.personal,
            hostChrome: freeRoam
                ? HostMapChrome(
                    title: const Text('Where to?'),
                    actions: const [],
                  )
                : null,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      return (store: store, nav: navigation);
    }

    testWidgets('stopping is offered in words, asks once, and clears', (
      tester,
    ) async {
      await pumpNavigating(tester, freeRoam: true);
      expect(find.byKey(const Key('route-progress-panel')), findsOneWidget);

      await tester.tap(find.byKey(const Key('stop-navigating')));
      await tester.pumpAndSettle();
      // One confirmation, in free roam's own words — not the group-route
      // dialog, which speaks of removing the route for every rider (#626).
      expect(find.text('Stop navigating?'), findsOneWidget);
      expect(find.textContaining('every rider'), findsNothing);

      await tester.tap(find.byKey(const Key('confirm-stop-navigating')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('route-progress-panel')), findsNothing);
      expect(find.byKey(const Key('stop-navigating')), findsNothing);
    });

    testWidgets('a ride keeps its route out of one rider\'s reach', (
      tester,
    ) async {
      // In a ride the route belongs to the group and leaves through the ride's
      // own controls; the card must not offer a personal exit there.
      await pumpNavigating(tester, freeRoam: false);
      expect(find.byKey(const Key('route-progress-panel')), findsOneWidget);
      expect(find.byKey(const Key('stop-navigating')), findsNothing);
    });
  });

  testWidgets('a ride with no route keeps SOS, Leave and the ride menu', (
    tester,
  ) async {
    // #124's P0 regression: `_route != null` gated the emergency alert and the
    // leave action, so a group riding without a GPX had neither. This is the one
    // that must never come back.
    final directory = Directory.systemTemp.createTempSync('map-routeless-ride');
    addTearDown(() => directory.deleteSync(recursive: true));
    final navigation = ValueNotifier<MapNavigationPosition?>(null);
    addTearDown(navigation.dispose);
    final cache = OfflineTileCache(
      rootDirectory: directory,
      configuration: const BasemapConfiguration(),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );
    var alerts = 0;
    var leaves = 0;
    var menus = 0;

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: RideMapScreen(
          // No route, and none arriving.
          routeStore: InMemoryRouteStore(),
          routeImporter: RouteImporter(source: const _NoFileSource()),
          offlineTileCache: cache,
          navigationPosition: navigation,
          ridePaused: true,
          onEmergencyAlert: () async => alerts += 1,
          onLeaveRide: () async => leaves += 1,
          onOpenRideMenu: () async => menus += 1,
          onReportHazard: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Before a fix arrives, and with no route: the safety actions are already
    // there, and so is the paused-ride state.
    expect(find.byKey(const Key('emergency-alert-button')), findsOneWidget);
    expect(find.byKey(const Key('leave-ride-button')), findsOneWidget);
    expect(find.byKey(const Key('report-sighting-button')), findsOneWidget);
    expect(find.text('GROUP RIDE PAUSED'), findsOneWidget);

    await tester.tap(find.byKey(const Key('leave-ride-button')));
    await tester.pump();
    expect(leaves, 1);
    // SOS second, because a stopped rider's alert opens the assistance sheet
    // over the map. Dismiss it before carrying on.
    await tester.tap(find.byKey(const Key('emergency-alert-button')));
    await tester.pumpAndSettle();
    expect(alerts, 1);
    expect(find.text('You are stopped'), findsOneWidget);
    Navigator.of(
      tester.element(find.byKey(const Key('leave-ride-button'))),
    ).pop();
    await tester.pumpAndSettle();

    // A moving fix with no route: the follow camera engages, the riding canvas
    // takes the screen, and the ride menu appears in its corner. Route-derived
    // surfaces stay absent rather than empty.
    navigation.value = MapNavigationPosition(
      point: const GeoPoint(latitude: 53, longitude: -1.015),
      recordedAt: DateTime.utc(2026, 7, 26, 12),
      speedMetersPerSecond: 13,
      headingDegrees: 90,
      accuracyMeters: 5,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byType(AppBar), findsNothing);
    expect(find.byKey(const Key('emergency-alert-button')), findsOneWidget);
    expect(find.byKey(const Key('leave-ride-button')), findsOneWidget);
    expect(find.byKey(const Key('ride-menu-button')), findsOneWidget);
    expect(find.text('GROUP RIDE PAUSED'), findsOneWidget);
    expect(find.byKey(const Key('navigation-guidance-banner')), findsNothing);
    // Not a nag: a route-less ride is a mode, not a state to prompt about.
    expect(find.text('Choose a route'), findsNothing);
    // Follow mode has taken the camera but is still easing it into the viewport,
    // and until it arrives the rider has not been given the viewport (#141).
    expect(find.byKey(const Key('navigation-follow-button')), findsOneWidget);

    await tester.tap(find.byKey(const Key('ride-menu-button')));
    await tester.pump();
    expect(menus, 1);

    // The camera is following a route-less rider, so let its animation finish
    // before the tree is torn down.
    await tester.pumpAndSettle();
    // Arrived: the camera is the navigation viewport, so the way into it is not
    // offered any more. This is the pair of assertions the contract asks for -
    // present while easing, gone once locked.
    expect(find.byKey(const Key('navigation-follow-button')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('a route-less rider can recover the camera after a pan', (
    tester,
  ) async {
    // #124 plus #125: following works from position and heading alone, and
    // "Follow me" is earned by a manual pan rather than sitting there all ride.
    final directory = Directory.systemTemp.createTempSync('map-routeless-pan');
    addTearDown(() => directory.deleteSync(recursive: true));
    final navigation = ValueNotifier<MapNavigationPosition?>(
      MapNavigationPosition(
        point: const GeoPoint(latitude: 53, longitude: -1.015),
        recordedAt: DateTime.utc(2026, 7, 26, 12),
        speedMetersPerSecond: 13,
        headingDegrees: 90,
        accuracyMeters: 5,
      ),
    );
    addTearDown(navigation.dispose);
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
          navigationPosition: navigation,
          onLeaveRide: () async {},
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('navigation-follow-button')), findsNothing);

    await tester.drag(find.byType(FlutterMap), const Offset(0, 90));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('navigation-follow-button')), findsOneWidget);

    // Still off following, and now stopped: the affordance has to survive the
    // bike stopping, because that is exactly when the rider needs it.
    navigation.value = MapNavigationPosition(
      point: const GeoPoint(latitude: 53, longitude: -1.014),
      recordedAt: DateTime.utc(2026, 7, 26, 12, 1),
      speedMetersPerSecond: 0,
      headingDegrees: 90,
      accuracyMeters: 5,
    );
    await tester.pump();
    expect(find.byKey(const Key('navigation-follow-button')), findsOneWidget);

    await tester.tap(find.text('Follow me'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('navigation-follow-button')), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('a stationary rider who pans away is offered the way back', (
    tester,
  ) async {
    // The case that shipped broken twice. #125 gated "Follow me" on a flag set
    // only when a pan interrupted an *active* follow, and follow mode is driven
    // by movement - so on a phone standing on a desk, which is never following,
    // the pan suppressed nothing, the flag was never set, and the map could be
    // pushed off the rider with no way back. #133 replaced the flag with a
    // positional comparison, which a route overview satisfies by accident.
    //
    // The condition is now whether the camera *is* the navigation viewport
    // (#141): a standing bike is not following, so the control is there from the
    // start, tapping it goes to the viewport and it goes away once the camera
    // arrives, and a single pan brings it straight back.
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final directory = Directory.systemTemp.createTempSync('map-still-pan');
    addTearDown(() => directory.deleteSync(recursive: true));
    // Standing still: a real fix, a real heading, and no movement at all.
    final navigation = ValueNotifier<MapNavigationPosition?>(
      MapNavigationPosition(
        point: const GeoPoint(latitude: 53, longitude: -1.015),
        recordedAt: DateTime.utc(2026, 7, 26, 12),
        speedMetersPerSecond: 0,
        headingDegrees: 90,
        accuracyMeters: 5,
      ),
    );
    addTearDown(navigation.dispose);
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
          navigationPosition: navigation,
          onLeaveRide: () async {},
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();

    // A standing bike is never following, so the camera is not the navigation
    // viewport and the way into it is offered. This is the assertion the
    // maintainer's third report turned around: #125 and #133 both wanted nothing
    // here, and a rider on a desk had no way to a viewport they had never been in.
    expect(find.byKey(const Key('navigation-follow-button')), findsOneWidget);

    // Tapping goes to the viewport - following the rider icon at the planned
    // zoom - and only then is the control done.
    await tester.tap(find.text('Follow me'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('navigation-follow-button')), findsNothing);

    // One pan is enough. No distance judgement stands between the rider and the
    // way back: giving the camera up is what puts the control on screen.
    await tester.drag(find.byType(FlutterMap), const Offset(0, 140));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('navigation-follow-button')), findsOneWidget);
    expect(find.text('Follow me'), findsOneWidget);

    // A further fix from the same standing bike must not clear it: nothing about
    // standing still puts the map back on the rider.
    navigation.value = MapNavigationPosition(
      point: const GeoPoint(latitude: 53, longitude: -1.015),
      recordedAt: DateTime.utc(2026, 7, 26, 12, 1),
      speedMetersPerSecond: 0,
      headingDegrees: 90,
      accuracyMeters: 5,
    );
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('navigation-follow-button')), findsOneWidget);

    await tester.tap(find.text('Follow me'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('navigation-follow-button')), findsNothing);

    // A pan of eight pixels - the smallest this recognises as deliberate - is
    // enough. #133's 56 px band was 1363 m of ground at the zoom a phone actually
    // sat at, measured on an SE, so a map pushed 468 m off the rider still called
    // itself framed.
    await tester.drag(find.byType(FlutterMap), const Offset(0, 9));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('navigation-follow-button')), findsOneWidget);

    // Let the tooltip timers the taps above started run out before the tree goes.
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('the configured basemap gives the ride a tracked camera', (
    tester,
  ) async {
    // #141, read off a phone. Every other test here runs on the unconfigured
    // development basemap, which is `flutter_map` - and `flutter_map`'s
    // `MapController.camera` is always live. A shipped build has a style URL, so
    // the ride surface is MapLibre, and MapLibre only reports its camera when
    // `trackCameraPosition` is set: iOS sends `camera#onMove` behind
    // `if !trackCameraPosition { return }` and `camera#onIdle` with an empty
    // payload, and Android gates both the same way. Without it
    // `MapLibreMapController.cameraPosition` keeps the value it was constructed
    // with for the whole ride.
    //
    // That is what defeated #133's measurement on the phone while its widget
    // tests passed: the drift was computed against the camera the map opened on,
    // never against the camera the rider had panned to, so "Follow me" was
    // decided from a number that could not change. The two previous attempts
    // were both verified on the render path a shipped build does not use.
    final directory = Directory.systemTemp.createTempSync('map-tracked-camera');
    addTearDown(() => directory.deleteSync(recursive: true));
    final navigation = ValueNotifier<MapNavigationPosition?>(
      MapNavigationPosition(
        point: const GeoPoint(latitude: 53, longitude: -1.015),
        recordedAt: DateTime.utc(2026, 7, 26, 12),
        speedMetersPerSecond: 0,
        headingDegrees: 90,
        accuracyMeters: 5,
      ),
    );
    addTearDown(navigation.dispose);
    // The shape a shipped build has: a style URL and an attribution, which is
    // what `usesMapLibre` asks for.
    final cache = OfflineTileCache(
      rootDirectory: directory,
      configuration: const BasemapConfiguration(
        styleUrl: 'https://tiles.example.com/styles/liberty',
        attribution: 'Example contributors',
      ),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: RideMapScreen(
          routeStore: InMemoryRouteStore(),
          routeImporter: RouteImporter(source: const _NoFileSource()),
          offlineTileCache: cache,
          navigationPosition: navigation,
          onLeaveRide: () async {},
        ),
      ),
    );
    await tester.pump();

    // The render path a shipped build actually uses.
    expect(
      find.byType(ml.MapLibreMap),
      findsOneWidget,
      reason: 'a configured basemap must put the ride on MapLibre',
    );
    expect(find.byType(FlutterMap), findsNothing);
    expect(
      tester
          .widget<ml.MapLibreMap>(find.byType(ml.MapLibreMap))
          .trackCameraPosition,
      isTrue,
      reason:
          'the "Follow me" measurement reads MapLibreMapController.cameraPosition, '
          'which the platform only ever updates when trackCameraPosition is set',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('an action target keeps its bounds through every state', (
    tester,
  ) async {
    // #142: pressing SOS turned its label into "ALERT SENT", which widened the
    // control, and in landscape the `Wrap` holding the three targets could no
    // longer fit them across - so REPORT reflowed onto a run of its own at the
    // exact moment the rider had just raised an alert. The controls a rider
    // reaches for without looking must not move because one of them changed what
    // it says.
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final directory = Directory.systemTemp.createTempSync('map-action-bounds');
    addTearDown(() => directory.deleteSync(recursive: true));
    // Moving, so the assistance sheet a stopped rider gets stays out of the way
    // of the measurement.
    final navigation = ValueNotifier<MapNavigationPosition?>(
      MapNavigationPosition(
        point: const GeoPoint(latitude: 53, longitude: -1.015),
        recordedAt: DateTime.utc(2026, 7, 26, 12),
        speedMetersPerSecond: 13,
        headingDegrees: 90,
        accuracyMeters: 5,
      ),
    );
    addTearDown(navigation.dispose);
    final cache = OfflineTileCache(
      rootDirectory: directory,
      configuration: const BasemapConfiguration(),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );

    const actionKeys = [
      'emergency-alert-button',
      'leave-ride-button',
      'report-sighting-button',
    ];

    Map<String, Rect> measure() => {
      for (final key in actionKeys) key: tester.getRect(find.byKey(Key(key))),
    };

    Future<void> verifyStableThroughStates({required bool landscape}) async {
      // A held completer keeps the in-flight state on screen long enough to be
      // measured: SOS is disabled and shows a spinner where its icon was, which
      // is four pixels narrower than a Material icon and used to shrink the
      // control before the label had even changed.
      final sending = Completer<void>();
      tester.view.physicalSize = landscape
          ? const Size(852, 393)
          : const Size(393, 852);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: RideMapScreen(
            routeStore: InMemoryRouteStore(),
            routeImporter: RouteImporter(source: const _NoFileSource()),
            offlineTileCache: cache,
            navigationPosition: navigation,
            onEmergencyAlert: () => sending.future,
            onLeaveRide: () async {},
            onOpenRideMenu: () async {},
            onReportHazard: (_) async {},
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      final orientation = landscape ? 'landscape' : 'portrait';
      final idle = measure();
      expect(find.text('ALERT'), findsOneWidget);

      // The arrangement itself, which is the property the `Wrap` gave up: one
      // shape per orientation, and the same shape in every state.
      //
      // Portrait stacks SOS over LEAVE with REPORT alongside. Landscape stacks
      // all three vertically to keep the map clear across its lower edge.
      void expectArrangement(Map<String, Rect> rects, String state) {
        final sos = rects['emergency-alert-button']!;
        final leave = rects['leave-ride-button']!;
        final report = rects['report-sighting-button']!;
        if (landscape) {
          expect(
            sos.bottom,
            lessThanOrEqualTo(leave.top),
            reason: 'ALERT must sit above LEAVE in landscape/$state',
          );
          expect(
            leave.bottom,
            lessThanOrEqualTo(report.top),
            reason: 'LEAVE must sit above REPORT in landscape/$state',
          );
          expect(
            leave.left,
            closeTo(sos.left, 0.01),
            reason: 'landscape controls must share one left edge in $state',
          );
          expect(
            report.left,
            closeTo(sos.left, 0.01),
            reason: 'REPORT must stay in the landscape stack in $state',
          );
        } else {
          expect(
            sos.bottom,
            lessThanOrEqualTo(leave.top),
            reason: 'SOS must stay above LEAVE in portrait/$state',
          );
          expect(
            report.left,
            greaterThanOrEqualTo(sos.right),
            reason: 'REPORT must stay beside the pair in portrait/$state',
          );
          expect(
            report.bottom,
            closeTo(leave.bottom, 0.01),
            reason: 'REPORT must share the run in portrait/$state',
          );
        }
        // Glove-sized in every state and both orientations, whatever the labels
        // had to give up to fit (#142).
        for (final entry in rects.entries) {
          expect(
            entry.value.shortestSide,
            greaterThanOrEqualTo(48),
            reason: '${entry.key} is too small to hit in $orientation/$state',
          );
        }
      }

      expectArrangement(idle, 'idle');

      await tester.tap(find.byKey(const Key('emergency-alert-button')));
      await tester.pump();
      expect(
        measure(),
        idle,
        reason: 'sending an alert moved a target in $orientation',
      );
      expect(
        tester
            .widget<FloatingActionButton>(
              find.byKey(const Key('emergency-alert-button')),
            )
            .onPressed,
        isNull,
        reason: 'SOS must be disabled while the alert is in flight',
      );

      sending.complete();
      await tester.pumpAndSettle();
      expect(find.text('ALERT SENT'), findsOneWidget);
      expect(
        measure(),
        idle,
        reason: 'a sent alert moved a target in $orientation',
      );
      expectArrangement(measure(), 'alert sent');

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }

    await verifyStableThroughStates(landscape: false);
    await verifyStableThroughStates(landscape: true);
  });

  testWidgets('a paused ride does not move the action targets', (tester) async {
    // #142's other half: a control's own state must not move its neighbours, and
    // the paused banner appearing above the targets must not move them either -
    // the band grows upwards from a bottom anchor.
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final directory = Directory.systemTemp.createTempSync('map-paused-bounds');
    addTearDown(() => directory.deleteSync(recursive: true));
    final navigation = ValueNotifier<MapNavigationPosition?>(
      MapNavigationPosition(
        point: const GeoPoint(latitude: 53, longitude: -1.015),
        recordedAt: DateTime.utc(2026, 7, 26, 12),
        speedMetersPerSecond: 13,
        headingDegrees: 90,
        accuracyMeters: 5,
      ),
    );
    addTearDown(navigation.dispose);
    final cache = OfflineTileCache(
      rootDirectory: directory,
      configuration: const BasemapConfiguration(),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );

    Widget screen({required bool paused}) => MaterialApp(
      theme: ThemeData.dark(useMaterial3: true),
      home: RideMapScreen(
        routeStore: InMemoryRouteStore(),
        routeImporter: RouteImporter(source: const _NoFileSource()),
        offlineTileCache: cache,
        navigationPosition: navigation,
        ridePaused: paused,
        onEmergencyAlert: () async {},
        onLeaveRide: () async {},
        onReportHazard: (_) async {},
      ),
    );

    await tester.pumpWidget(screen(paused: false));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    final running = {
      for (final key in const [
        'emergency-alert-button',
        'leave-ride-button',
        'report-sighting-button',
      ])
        key: tester.getRect(find.byKey(Key(key))),
    };

    await tester.pumpWidget(screen(paused: true));
    await tester.pumpAndSettle();
    expect(find.text('GROUP RIDE PAUSED'), findsOneWidget);
    expect(
      {
        for (final key in const [
          'emergency-alert-button',
          'leave-ride-button',
          'report-sighting-button',
        ])
          key: tester.getRect(find.byKey(Key(key))),
      },
      running,
      reason: 'pausing the ride moved a target',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  test('every quick message kind has its own symbol on both phones', () {
    // The kind a rider chose to send and the kind another rider is shown are
    // the same symbol, and a kind only a newer build knows still gets one.
    final icons = {
      for (final message in QuickMessage.values)
        message: quickMessageIcon(message),
    };
    expect(icons.values.toSet(), hasLength(QuickMessage.values.length));
    expect(quickMessageIcon(null), isNotNull);
    expect(icons.values.contains(quickMessageIcon(null)), isFalse);
  });

  test('where the sender is reads as one of two honest forms', () {
    expect(
      describeQuickMessageOrigin(
        const QuickMessageOrigin(
          distanceMeters: 1931,
          alongRoute: true,
          senderIsBehind: true,
        ),
        DistanceUnit.miles,
      ),
      '1.2 mi back',
    );
    expect(
      describeQuickMessageOrigin(
        const QuickMessageOrigin(
          distanceMeters: 1931,
          alongRoute: true,
          senderIsBehind: false,
        ),
        DistanceUnit.miles,
      ),
      '1.2 mi ahead',
    );
    expect(
      describeQuickMessageOrigin(
        const QuickMessageOrigin(
          distanceMeters: 400,
          alongRoute: false,
          bearingDegrees: 45,
        ),
        DistanceUnit.kilometres,
      ),
      '400 m NE',
    );
    // A rider standing beside you is not "0 m back".
    expect(
      describeQuickMessageOrigin(
        const QuickMessageOrigin(
          distanceMeters: 4,
          alongRoute: true,
          senderIsBehind: true,
        ),
        DistanceUnit.miles,
      ),
      'right here',
    );
    // And a sender who has never reported one is said to be unknown rather than
    // drawn as though they were on top of you.
    expect(
      describeQuickMessageOrigin(null, DistanceUnit.miles),
      'position not reported',
    );
  });

  testWidgets('a routine quick message reaches a rider watching the map', (
    tester,
  ) async {
    // #151: the send path always worked and nothing presented the result. A
    // leader on the Map tab has to be told who, what, when and where, without
    // going to look, and "Need fuel" must not blank the map to do it.
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final directory = Directory.systemTemp.createTempSync('map-quick-message');
    addTearDown(() => directory.deleteSync(recursive: true));
    final cache = OfflineTileCache(
      rootDirectory: directory,
      configuration: const BasemapConfiguration(),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );
    final alerts = ValueNotifier<List<RideQuickMessageAlert>>([
      _quickMessageAlert(
        eventId: 'fuel-1',
        message: QuickMessage.fuel,
        senderDisplayName: 'Bill',
        origin: const QuickMessageOrigin(
          distanceMeters: 1931,
          alongRoute: true,
          senderIsBehind: true,
        ),
      ),
    ]);
    addTearDown(alerts.dispose);
    final acknowledged = <String>[];

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: RideMapScreen(
          routeStore: InMemoryRouteStore(
            _testRoute(id: 'quick', name: 'Quick route'),
          ),
          routeImporter: RouteImporter(source: const _NoFileSource()),
          offlineTileCache: cache,
          distanceUnit: DistanceUnit.miles,
          quickMessageAlerts: alerts,
          onAcknowledgeQuickMessage: (message) async =>
              acknowledged.add(message.eventId),
          onEmergencyAlert: () async {},
          onLeaveRide: () async {},
          onReportHazard: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('quick-message-alert')), findsOneWidget);
    expect(find.text('Bill needs fuel'), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('quick-message-detail'))).data,
      startsWith('1.2 mi back · '),
    );
    // Routine does not take the screen over. That is what priority is for.
    expect(find.byKey(const Key('quick-message-interrupt')), findsNothing);

    // One target ends it, and the sender is told.
    final button = tester.getRect(
      find.byKey(const Key('quick-message-acknowledge')),
    );
    expect(button.shortestSide, greaterThanOrEqualTo(48));
    await tester.tap(find.byKey(const Key('quick-message-acknowledge')));
    await tester.pumpAndSettle();
    expect(acknowledged, const ['fuel-1']);
  });

  testWidgets('an urgent quick message interrupts and leaves the row behind', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final directory = Directory.systemTemp.createTempSync('map-quick-urgent');
    addTearDown(() => directory.deleteSync(recursive: true));
    final cache = OfflineTileCache(
      rootDirectory: directory,
      configuration: const BasemapConfiguration(),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );
    final alerts = ValueNotifier<List<RideQuickMessageAlert>>([
      _quickMessageAlert(
        eventId: 'help-1',
        message: QuickMessage.assistance,
        senderDisplayName: 'Ana',
        origin: const QuickMessageOrigin(
          distanceMeters: 640,
          alongRoute: false,
          bearingDegrees: 225,
        ),
      ),
    ]);
    addTearDown(alerts.dispose);
    final dismissedInterrupts = <String>{};

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: RideMapScreen(
          routeStore: InMemoryRouteStore(
            _testRoute(id: 'quick', name: 'Quick route'),
          ),
          routeImporter: RouteImporter(source: const _NoFileSource()),
          offlineTileCache: cache,
          distanceUnit: DistanceUnit.kilometres,
          quickMessageAlerts: alerts,
          dismissedQuickMessageInterruptIds: dismissedInterrupts,
          onDismissQuickMessageInterrupt: dismissedInterrupts.add,
          onAcknowledgeQuickMessage: (_) async {},
          onEmergencyAlert: () async {},
          onLeaveRide: () async {},
          onReportHazard: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('quick-message-interrupt')), findsOneWidget);
    expect(find.text('ANA NEEDS HELP'), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const Key('quick-message-interrupt-origin')))
          .data,
      '640 M SW',
    );

    // Dismissing without acknowledging loses nothing: the persistent row is
    // still there, so a rider who glances away has not lost the alert.
    await tester.tapAt(
      tester.getTopLeft(find.byKey(const Key('quick-message-interrupt'))) +
          const Offset(12, 12),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('quick-message-interrupt')), findsNothing);
    expect(find.byKey(const Key('quick-message-alert')), findsOneWidget);
    expect(find.text('Ana needs help'), findsOneWidget);
    expect(dismissedInterrupts, const {'help-1'});

    // Opening the ride menu rebuilds the map tab. The interrupt must remember
    // that it was dismissed while leaving the persistent alert row available.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: RideMapScreen(
          routeStore: InMemoryRouteStore(
            _testRoute(id: 'quick', name: 'Quick route'),
          ),
          routeImporter: RouteImporter(source: const _NoFileSource()),
          offlineTileCache: cache,
          distanceUnit: DistanceUnit.kilometres,
          quickMessageAlerts: alerts,
          dismissedQuickMessageInterruptIds: dismissedInterrupts,
          onDismissQuickMessageInterrupt: dismissedInterrupts.add,
          onAcknowledgeQuickMessage: (_) async {},
          onEmergencyAlert: () async {},
          onLeaveRide: () async {},
          onReportHazard: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('quick-message-interrupt')), findsNothing);
    expect(find.byKey(const Key('quick-message-alert')), findsOneWidget);
  });

  testWidgets('the sender is shown that their own alert was seen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final directory = Directory.systemTemp.createTempSync('map-quick-receipt');
    addTearDown(() => directory.deleteSync(recursive: true));
    final cache = OfflineTileCache(
      rootDirectory: directory,
      configuration: const BasemapConfiguration(),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );
    final alerts = ValueNotifier<List<RideQuickMessageAlert>>(const []);
    addTearDown(alerts.dispose);
    // Moving, so the assistance sheet a stopped rider gets after an alert stays
    // out of the way of the surface under test.
    final navigation = ValueNotifier<MapNavigationPosition?>(
      MapNavigationPosition(
        point: const GeoPoint(latitude: 51.455, longitude: -2.585),
        recordedAt: DateTime.utc(2026, 7, 26, 12),
        speedMetersPerSecond: 13,
        headingDegrees: 45,
        accuracyMeters: 5,
      ),
    );
    addTearDown(navigation.dispose);
    final dismissedReceipts = <String>{};

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: RideMapScreen(
          routeStore: InMemoryRouteStore(
            _testRoute(id: 'quick', name: 'Quick route'),
          ),
          routeImporter: RouteImporter(source: const _NoFileSource()),
          offlineTileCache: cache,
          navigationPosition: navigation,
          quickMessageAlerts: alerts,
          dismissedQuickMessageReceiptIds: dismissedReceipts,
          onDismissQuickMessageReceipt: dismissedReceipts.add,
          onAcknowledgeQuickMessage: (_) async {},
          onEmergencyAlert: () async {},
          onLeaveRide: () async {},
          onReportHazard: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('emergency-alert-button')));
    await tester.pumpAndSettle();
    expect(find.text('ALERT SENT'), findsOneWidget);
    final sent = tester.getRect(
      find.byKey(const Key('emergency-alert-button')),
    );

    // The acknowledgement arrives. The control the rider already pressed says so,
    // and a row spells out who saw it.
    alerts.value = [
      _quickMessageAlert(
        eventId: 'own-sos',
        message: QuickMessage.emergencyStop,
        senderDisplayName: 'Me',
        raisedFromLocalRider: true,
        acknowledgedBy: 'Ana',
      ),
    ];
    await tester.pumpAndSettle();

    expect(find.text('ALERT SEEN'), findsOneWidget);
    expect(
      tester.getRect(find.byKey(const Key('emergency-alert-button'))),
      sent,
      reason: 'the acknowledged state must reuse the reserved slot (#142)',
    );
    expect(find.text('Ana saw: Emergency stop'), findsOneWidget);
    // A receipt is not an alert: there is nothing to acknowledge, only to clear.
    expect(find.byKey(const Key('quick-message-acknowledge')), findsNothing);
    await tester.tap(find.byKey(const Key('quick-message-receipt-dismiss')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('quick-message-alert')), findsNothing);
    expect(dismissedReceipts, const {'own-sos'});

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: RideMapScreen(
          routeStore: InMemoryRouteStore(
            _testRoute(id: 'quick', name: 'Quick route'),
          ),
          routeImporter: RouteImporter(source: const _NoFileSource()),
          offlineTileCache: cache,
          navigationPosition: navigation,
          quickMessageAlerts: alerts,
          dismissedQuickMessageReceiptIds: dismissedReceipts,
          onDismissQuickMessageReceipt: dismissedReceipts.add,
          onAcknowledgeQuickMessage: (_) async {},
          onEmergencyAlert: () async {},
          onLeaveRide: () async {},
          onReportHazard: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('quick-message-alert')), findsNothing);
  });

  testWidgets('several messages at once are one row and a count', (
    tester,
  ) async {
    // Three riders raising something must not put three rows into the band #125
    // and #133 emptied. The most urgent is on screen with a count behind it.
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final directory = Directory.systemTemp.createTempSync('map-quick-count');
    addTearDown(() => directory.deleteSync(recursive: true));
    final cache = OfflineTileCache(
      rootDirectory: directory,
      configuration: const BasemapConfiguration(),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );
    final alerts = ValueNotifier<List<RideQuickMessageAlert>>([
      _quickMessageAlert(
        eventId: 'blocked-1',
        message: QuickMessage.routeBlocked,
        senderDisplayName: 'Cal',
        origin: const QuickMessageOrigin(
          distanceMeters: 800,
          alongRoute: true,
          senderIsBehind: false,
        ),
      ),
      _quickMessageAlert(
        eventId: 'fuel-1',
        message: QuickMessage.fuel,
        senderDisplayName: 'Bill',
      ),
      _quickMessageAlert(
        eventId: 'stopped-1',
        message: QuickMessage.stopped,
        senderDisplayName: 'Dee',
      ),
    ]);
    addTearDown(alerts.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: RideMapScreen(
          routeStore: InMemoryRouteStore(
            _testRoute(id: 'quick', name: 'Quick route'),
          ),
          routeImporter: RouteImporter(source: const _NoFileSource()),
          offlineTileCache: cache,
          distanceUnit: DistanceUnit.miles,
          quickMessageAlerts: alerts,
          onAcknowledgeQuickMessage: (_) async {},
          onEmergencyAlert: () async {},
          onLeaveRide: () async {},
          onReportHazard: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('quick-message-alert')), findsOneWidget);
    expect(find.text('Cal says the route is blocked'), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('quick-message-detail'))).data,
      endsWith('+2 more'),
    );
  });

  testWidgets('an incoming alert moves nothing and stays out of the road', (
    tester,
  ) async {
    // #142's rule applied to a surface that arrives unbidden: the band grows
    // upwards from its bottom anchor, so the targets a rider reaches for without
    // looking do not move, resize or reflow when an alert lands on them. #104's
    // rule applied to the same surface: it is not a corner element, so it stays
    // out of the upper third, and in landscape out of the centre column.
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final directory = Directory.systemTemp.createTempSync('map-quick-layout');
    addTearDown(() => directory.deleteSync(recursive: true));
    final cache = OfflineTileCache(
      rootDirectory: directory,
      configuration: const BasemapConfiguration(),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );
    final navigation = ValueNotifier<MapNavigationPosition?>(
      MapNavigationPosition(
        point: const GeoPoint(latitude: 53, longitude: -1.015),
        recordedAt: DateTime.utc(2026, 7, 26, 12),
        speedMetersPerSecond: 13,
        headingDegrees: 90,
        accuracyMeters: 5,
      ),
    );
    addTearDown(navigation.dispose);
    final leaderStatus = ValueNotifier<LeaderRideStatus?>(
      const LeaderRideStatus(
        tecName: 'Charlie',
        distanceToTecMeters: 3200,
        estimatedTimeToTec: Duration(minutes: 4),
        tecLocationAge: Duration(seconds: 10),
        offCourseAlerts: [
          LeaderOffCourseAlert(
            riderId: 'rider-alex',
            displayName: 'Alex',
            level: RouteAlertLevel.urgent,
            distanceFromRouteMeters: 420,
          ),
        ],
      ),
    );
    addTearDown(leaderStatus.dispose);
    final alerts = ValueNotifier<List<RideQuickMessageAlert>>(const []);
    addTearDown(alerts.dispose);

    // The same route the chrome test uses, so the turn banner is live: a route
    // the rider is on, with one manoeuvre ahead of them.
    final route = ImportedRoute(
      id: 'quick-chrome',
      name: 'Quick chrome route',
      importedAt: DateTime.utc(2026, 7, 26),
      sourceFileName: 'quick-chrome.gpx',
      paths: const [
        RoutePath(
          kind: RoutePathKind.track,
          points: [
            GeoPoint(latitude: 53, longitude: -1.02),
            GeoPoint(latitude: 53, longitude: -1.01),
            GeoPoint(latitude: 53, longitude: -1),
          ],
        ),
      ],
      waypoints: const [],
      maneuvers: const [
        RouteManeuver(
          position: GeoPoint(latitude: 53, longitude: -1.005),
          type: 'turn',
          modifier: 'right',
          name: 'Station Road',
          drivingSide: 'left',
        ),
      ],
    );

    // Everything at once: a paused ride, an off-course rider, the TEC gap, the
    // turn banner and the action row, and now an alert on top of all of it.
    Widget screen() => MaterialApp(
      theme: ThemeData.dark(useMaterial3: true),
      home: RideMapScreen(
        routeStore: InMemoryRouteStore(route),
        routeImporter: RouteImporter(source: const _NoFileSource()),
        offlineTileCache: cache,
        navigationPosition: navigation,
        leaderStatus: leaderStatus,
        ridePaused: true,
        distanceUnit: DistanceUnit.miles,
        quickMessageAlerts: alerts,
        onAcknowledgeQuickMessage: (_) async {},
        onOpenRideMenu: () async {},
        onEmergencyAlert: () async {},
        onLeaveRide: () async {},
        onReportHazard: (_) async {},
      ),
    );

    const actionKeys = [
      'emergency-alert-button',
      'leave-ride-button',
      'report-sighting-button',
      'posted-speed-limit-position',
    ];
    Map<String, Rect> measureActions() => {
      for (final key in actionKeys) key: tester.getRect(find.byKey(Key(key))),
    };

    Future<void> verify({required bool landscape}) async {
      tester.view.physicalSize = landscape
          ? const Size(852, 393)
          : const Size(393, 852);
      alerts.value = const [];
      await tester.pumpWidget(screen());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      final size = tester.view.physicalSize / tester.view.devicePixelRatio;
      final before = measureActions();

      alerts.value = [
        _quickMessageAlert(
          eventId: 'fuel-1',
          message: QuickMessage.fuel,
          senderDisplayName: 'Bill',
          origin: const QuickMessageOrigin(
            distanceMeters: 1931,
            alongRoute: true,
            senderIsBehind: true,
          ),
        ),
      ];
      await tester.pumpAndSettle();
      final orientation = landscape ? 'landscape' : 'portrait';
      expect(find.byKey(const Key('quick-message-alert')), findsOneWidget);
      expect(
        measureActions(),
        before,
        reason: 'an incoming alert moved a target in $orientation',
      );

      final alert = tester.getRect(
        find.byKey(const Key('quick-message-alert')),
      );
      expect(alert.left, greaterThanOrEqualTo(0));
      expect(alert.right, lessThanOrEqualTo(size.width));
      expect(alert.bottom, lessThanOrEqualTo(size.height));
      // It grows the band upwards; the targets stay put underneath it.
      expect(
        alert.bottom,
        lessThanOrEqualTo(before['emergency-alert-button']!.top),
        reason: 'the alert must stack inside the band in $orientation',
      );
      // Nothing it shares the band with is covered.
      for (final key in const [
        'leader-off-course-alert',
        'leader-tec-gap',
        'navigation-guidance-banner',
        ...actionKeys,
      ]) {
        expect(
          alert.deflate(0.5).overlaps(tester.getRect(find.byKey(Key(key)))),
          isFalse,
          reason: 'the alert overlaps $key in $orientation',
        );
      }
      if (landscape) {
        // The centre column is where the rider's own marker and the road ahead
        // are. A rail surface never crosses it (#133).
        expect(
          alert.right <= size.width * 0.45 || alert.left >= size.width * 0.55,
          isTrue,
          reason: 'the alert crosses the centre column in $orientation',
        );
      } else {
        // The absolute worst case for #105's forward bias: every persistent
        // surface plus an unacknowledged alert. Reported in the PR; acknowledging
        // is one target away and hands the space straight back.
        expect(_bottomChromeFraction(tester, size), lessThan(0.65));
      }

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }

    await verify(landscape: false);
    await verify(landscape: true);
  });

  // #572, #573. The home screen used to paint its search field and its two
  // actions on top of this AppBar, in the same corner of the same safe area,
  // from a different widget tree. Both were drawn; only the later one could be
  // tapped, so the layer menu sat under the settings button.
  group('the top band has one owner', () {
    Future<void> pumpWithChrome(
      WidgetTester tester, {
      required bool hosted,
      bool started = false,
      bool navigating = false,
      VoidCallback? onMore,
    }) async {
      SharedPreferences.setMockInitialValues({});
      final directory = Directory.systemTemp.createTempSync('chrome-owner');
      addTearDown(() => directory.deleteSync(recursive: true));
      final cache = OfflineTileCache(
        rootDirectory: directory,
        configuration: const BasemapConfiguration(),
        httpClient: MockClient((_) async => http.Response('', 404)),
      );
      addTearDown(cache.dispose);
      final position = navigating
          ? ValueNotifier<GeoPoint?>(
              const GeoPoint(latitude: 51.45, longitude: -2.59),
            )
          : null;
      if (position != null) addTearDown(position.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: RideMapScreen(
            routeStore: InMemoryRouteStore(
              navigating
                  ? _testRoute(id: 'host-navigation', name: 'Host navigation')
                  : null,
            ),
            routeImporter: RouteImporter(source: const _NoFileSource()),
            offlineTileCache: cache,
            routeAuthority: RouteAuthority.personal,
            rideStarted: started,
            navigating: navigating ? true : null,
            currentPosition: position,
            discoveryCatalogueLoader: () async =>
                const MotorcycleDiscoveryCatalogue([]),
            bikerPlaceCatalogueLoader: () async => BikerPlaceCatalogue.empty,
            hostChrome: hosted
                ? HostMapChrome(
                    title: const Text('Where to?'),
                    onMore: onMore,
                    actions: [
                      IconButton(
                        key: const Key('host-emergency'),
                        tooltip: 'Emergency info',
                        onPressed: () {},
                        icon: const Icon(Icons.medical_information_outlined),
                      ),
                      IconButton(
                        key: const Key('host-settings'),
                        tooltip: 'Settings',
                        onPressed: () {},
                        icon: const Icon(Icons.settings_outlined),
                      ),
                    ],
                  )
                : null,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('every control in the corner is separately hittable', (
      tester,
    ) async {
      await pumpWithChrome(tester, hosted: true);

      final rects = <String, Rect>{
        'layer menu': tester.getRect(
          find.byKey(const Key('map-layer-actions')),
        ),
        'emergency info': tester.getRect(
          find.byKey(const Key('host-emergency')),
        ),
        'settings': tester.getRect(find.byKey(const Key('host-settings'))),
        'search field': tester.getRect(find.text('Where to?')),
      };
      for (final a in rects.entries) {
        for (final b in rects.entries) {
          if (a.key == b.key) continue;
          expect(
            a.value.overlaps(b.value),
            isFalse,
            reason: '${a.key} ${a.value} overlaps ${b.key} ${b.value}',
          );
        }
      }
    });

    testWidgets('the layer menu is the last thing in the row (#606)', (
      tester,
    ) async {
      await pumpWithChrome(tester, hosted: true);

      // Not whether it is there — #572 settled that. Where it is. With a host
      // sharing the row every one of the map's own icons is gated off, so a
      // menu built before the host's actions comes out *first*: an unlabelled
      // `...` between the search field and Join. That was reported from build
      // 67 as the menu having been removed, which is what an unfindable
      // control is (#306).
      final menu = tester.getCenter(find.byKey(const Key('map-layer-actions')));
      for (final host in ['host-emergency', 'host-settings']) {
        expect(
          menu.dx,
          greaterThan(tester.getCenter(find.byKey(Key(host))).dx),
          reason: 'the menu belongs after $host, at the end of the row',
        );
      }
    });

    testWidgets('the layer menu opens, every time', (tester) async {
      await pumpWithChrome(tester, hosted: true);

      // The reported symptom was that this could not be reached at all: the
      // settings button was over it and won the hit test.
      await tester.tap(find.byKey(const Key('map-layer-actions')));
      await tester.pumpAndSettle();

      expect(find.text('Motorcycle discovery layers'), findsOneWidget);
    });

    testWidgets('host secondary actions use the existing top overflow', (
      tester,
    ) async {
      var opened = 0;
      await pumpWithChrome(tester, hosted: true, onMore: () => opened += 1);

      await tester.tap(find.byKey(const Key('map-layer-actions')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('home-more-actions')));
      await tester.pumpAndSettle();

      expect(opened, 1);
    });

    testWidgets('free-roam navigation keeps More at the top in both layouts', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var opened = 0;

      for (final size in const [Size(390, 844), Size(844, 390)]) {
        tester.view.physicalSize = size;
        await pumpWithChrome(
          tester,
          hosted: true,
          navigating: true,
          onMore: () => opened += 1,
        );

        expect(find.byType(AppBar), findsNothing, reason: '$size');
        final menu = find.byKey(const Key('ride-menu-button'));
        expect(menu, findsOneWidget, reason: '$size');
        expect(find.byTooltip('More'), findsOneWidget, reason: '$size');
        final rect = tester.getRect(menu);
        final inset = size.width > size.height ? 10.0 : 12.0;
        expect(rect.left, closeTo(inset, 1), reason: '$size');
        expect(rect.top, closeTo(inset, 1), reason: '$size');

        await tester.tap(menu);
        await tester.pump();
      }

      expect(opened, 2);
    });

    testWidgets('a host that brought a title does not get a second way to a '
        'destination beside it', (tester) async {
      await pumpWithChrome(tester, hosted: true);

      expect(find.text('Where to?'), findsOneWidget);
      expect(find.byTooltip('Plan a destination'), findsNothing);
      expect(find.byTooltip('Import GPX route'), findsNothing);
      // Nothing to fit without a route, and a permanently greyed button is
      // width the search field needs.
      expect(find.byTooltip('Fit route'), findsNothing);
      // Both remain reachable where they always were.
      await tester.tap(find.byKey(const Key('map-layer-actions')));
      await tester.pumpAndSettle();
      expect(find.text('Import GPX route'), findsOneWidget);
    });

    testWidgets('a map with no host still owns its own title and actions', (
      tester,
    ) async {
      // Asserted on a *started* ride since #579. The rule this protects — the
      // host-chrome mechanism does not leak into a map that supplied none — is
      // unchanged. What changed is what an unstarted editable map puts in the
      // title: it now renders the same destination field free roam does,
      // rather than a plain title plus an `add_road` button, which is the
      // colocation #579 asked for. The unstarted case is asserted in "the way
      // to a destination is in one place" below.
      await pumpWithChrome(tester, hosted: false, started: true);

      expect(find.text('Navigation'), findsOneWidget);
      expect(find.byKey(const Key('map-destination-search')), findsNothing);
      expect(find.byTooltip('Import GPX route'), findsOneWidget);
      expect(find.byTooltip('Fit route'), findsOneWidget);
    });
  });

  // #579. Free roam asked for a destination through a search field on the map;
  // a created ride asked through an `add_road` icon button in the app bar.
  // Same intent, two affordances, two places.
  group('the way to a destination is in one place', () {
    Future<void> pumpMap(
      WidgetTester tester, {
      required bool started,
      RouteAuthority authority = RouteAuthority.leader,
      HostMapChrome? hostChrome,
      ValueListenable<GeoPoint?>? currentPosition,
      RouteStore? routeStore,
      Object? circularRideRequestToken,
      VoidCallback? onCircularRideRequestHandled,
    }) async {
      SharedPreferences.setMockInitialValues({});
      final directory = Directory.systemTemp.createTempSync('colocated');
      addTearDown(() => directory.deleteSync(recursive: true));
      final cache = OfflineTileCache(
        rootDirectory: directory,
        configuration: const BasemapConfiguration(),
        httpClient: MockClient((_) async => http.Response('', 404)),
      );
      addTearDown(cache.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: RideMapScreen(
            routeStore: routeStore ?? InMemoryRouteStore(),
            routeImporter: RouteImporter(source: const _NoFileSource()),
            offlineTileCache: cache,
            rideStarted: started,
            routeAuthority: authority,
            hostChrome: hostChrome,
            currentPosition: currentPosition,
            circularRideRequestToken: circularRideRequestToken,
            onCircularRideRequestHandled: onCircularRideRequestHandled,
            discoveryCatalogueLoader: () async =>
                const MotorcycleDiscoveryCatalogue([]),
            bikerPlaceCatalogueLoader: () async => BikerPlaceCatalogue.empty,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('a created ride that has not started asks the same way free '
        'roam does', (tester) async {
      await pumpMap(tester, started: false);

      expect(find.byKey(const Key('map-destination-search')), findsOneWidget);
      expect(find.text('Where to?'), findsOneWidget);
      // The icon button was the same control in a different place.
      expect(find.byTooltip('Plan a destination'), findsNothing);
    });

    testWidgets('free roam keeps its own field rather than getting two', (
      tester,
    ) async {
      await pumpMap(
        tester,
        started: false,
        authority: RouteAuthority.personal,
        hostChrome: HostMapChrome(title: const Text('Host field'), actions: []),
      );

      expect(find.text('Host field'), findsOneWidget);
      expect(find.byKey(const Key('map-destination-search')), findsNothing);
    });

    testWidgets('a circular-route request opens the map planner once', (
      tester,
    ) async {
      var handled = 0;
      final position = ValueNotifier(
        const GeoPoint(latitude: 51.45, longitude: -2.59),
      );
      addTearDown(position.dispose);
      await pumpMap(
        tester,
        started: false,
        authority: RouteAuthority.personal,
        currentPosition: position,
        circularRideRequestToken: Object(),
        onCircularRideRequestHandled: () => handled += 1,
      );

      expect(find.text('Create a circular ride'), findsOneWidget);
      expect(find.byKey(const Key('generate-circular-ride')), findsOneWidget);
      expect(handled, 1);
    });

    testWidgets('free roam is a map, not a card asking for a route (#600)', (
      tester,
    ) async {
      // The empty-route card was written for a ride that has been created and
      // has no route yet — it offers to "continue to the live group map",
      // which free roam has no group and no ride to continue to. It also
      // covers the map, which is the one thing free roam is for. Opening the
      // app to a card demanding a route is the ceremony #600 removes, and the
      // host's search field is directly above where the card would be.
      await pumpMap(
        tester,
        started: false,
        authority: RouteAuthority.personal,
        hostChrome: HostMapChrome(title: const Text('Host field'), actions: []),
      );

      expect(find.text('Choose a route'), findsNothing);
      expect(find.textContaining('A route is optional'), findsNothing);
      // Still a route-less map with the way to a route on it.
      expect(find.text('Host field'), findsOneWidget);
    });

    testWidgets('a created ride with no route still asks for one', (
      tester,
    ) async {
      // The card is not being deleted: a ride that has been created and has no
      // route is exactly what it is for, and it stays there.
      await pumpMap(tester, started: false);

      expect(find.text('Choose a route'), findsOneWidget);
    });

    testWidgets('knowing where a rider is does not take their chrome (#600)', (
      tester,
    ) async {
      // The navigation canvas takes the whole screen and the AppBar with it —
      // the search field, the layer menu, Settings. It used to switch on for
      // any position at all, so free roam lost its entire top band the moment
      // location was granted, and a rider standing on a map with no route had
      // no way to anything. That is why the discovery-layer menu "does not
      // appear most of the time" (#572, #593) survived two attempts at it.
      final position = ValueNotifier<GeoPoint?>(null);
      addTearDown(position.dispose);
      await pumpMap(
        tester,
        started: false,
        authority: RouteAuthority.personal,
        hostChrome: HostMapChrome(title: const Text('Host field'), actions: []),
        currentPosition: position,
      );

      expect(find.text('Host field'), findsOneWidget);

      position.value = const GeoPoint(latitude: 51.45, longitude: -2.58);
      await tester.pumpAndSettle();

      expect(find.text('Host field'), findsOneWidget);
      expect(find.byKey(const Key('map-layer-actions')), findsOneWidget);
    });

    testWidgets('a stored route reopened in free roam keeps its chrome too', (
      tester,
    ) async {
      // The same gate, on the other path. A map that mounts with a route
      // already in the store restores it before anything has said whether the
      // rider is navigating, and free roam is not — it reports that back
      // afterwards. Taking the chrome on the strength of a stored route and a
      // position would open the app straight into a screen with no way out.
      final store = InMemoryRouteStore(
        _testRoute(id: 'stored', name: 'Stored route'),
      );
      final position = ValueNotifier<GeoPoint?>(
        const GeoPoint(latitude: 51.45, longitude: -2.58),
      );
      addTearDown(position.dispose);

      await pumpMap(
        tester,
        started: false,
        authority: RouteAuthority.personal,
        hostChrome: HostMapChrome(title: const Text('Host field'), actions: []),
        currentPosition: position,
        routeStore: store,
      );

      expect(find.text('Host field'), findsOneWidget);
      expect(find.byKey(const Key('map-layer-actions')), findsOneWidget);
    });

    testWidgets('a hosted app bar fits on a phone with a route (#600)', (
      tester,
    ) async {
      // Free roam can hold a route of its own now, and a route adds two icon
      // buttons — Fit route and Navigate/export — to a row the host has already
      // spent on a search field and a labelled Join. On a phone that overflowed
      // the AppBar. The buttons are dropped and offered in the overflow menu
      // instead, which is what #573 settled for this row.
      //
      // At phone width, not the 800 px test default: the row fits at 800 and
      // the overflow only appears on the device it matters on.
      tester.view.physicalSize = const Size(393, 852);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = InMemoryRouteStore(
        _testRoute(id: 'stored', name: 'Stored route'),
      );

      await pumpMap(
        tester,
        started: false,
        authority: RouteAuthority.personal,
        hostChrome: HostMapChrome(
          title: const Text('Where to?'),
          actions: [
            TextButton.icon(
              onPressed: () {},
              icon: const Icon(Icons.group_add_outlined, size: 18),
              label: const Text('Join'),
            ),
            IconButton(
              onPressed: () {},
              icon: const Icon(Icons.medical_information_outlined),
            ),
            IconButton(
              onPressed: () {},
              icon: const Icon(Icons.settings_outlined),
            ),
          ],
        ),
        routeStore: store,
      );

      expect(tester.takeException(), isNull);
      expect(find.byTooltip('Fit route'), findsNothing);
      expect(find.byTooltip('Navigate or export route'), findsNothing);

      await tester.tap(find.byKey(const Key('map-layer-actions')));
      await tester.pumpAndSettle();

      // Nothing was lost by dropping them.
      expect(find.byKey(const Key('fit-route-menu-item')), findsOneWidget);
      expect(find.byKey(const Key('export-route-menu-item')), findsOneWidget);
    });

    testWidgets("the map's bottom rail clears the host's own bar (#573)", (
      tester,
    ) async {
      // Free roam stands a bar of actions on this map (#426). The map anchored
      // its bottom rail to the system inset alone, so its compass and controls
      // were drawn behind that bar — visible as clipped half-circles under it.
      tester.view.physicalSize = const Size(393, 852);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await pumpMap(
        tester,
        started: false,
        authority: RouteAuthority.personal,
        hostChrome: HostMapChrome(
          title: const Text('Where to?'),
          actions: const [],
          bottomInset: 84,
        ),
      );

      final rail = tester.getRect(find.byKey(portraitBottomChromeKey));
      final screen = tester.getSize(find.byType(MaterialApp));
      expect(
        rail.bottom,
        lessThanOrEqualTo(screen.height - 84),
        reason: "the rail runs into the host's bar at $rail",
      );
    });

    testWidgets('a chosen route keeps its name in the title', (tester) async {
      // The field replaces the title only while there is nothing to name.
      // Once a route is loaded its name is the more useful thing to show, and
      // this is the only place it appears on this surface.
      SharedPreferences.setMockInitialValues({});
      final directory = Directory.systemTemp.createTempSync('named-route');
      addTearDown(() => directory.deleteSync(recursive: true));
      final cache = OfflineTileCache(
        rootDirectory: directory,
        configuration: const BasemapConfiguration(),
        httpClient: MockClient((_) async => http.Response('', 404)),
      );
      addTearDown(cache.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: RideMapScreen(
            routeStore: InMemoryRouteStore(
              _testRoute(id: 'chosen', name: 'Sunday loop'),
            ),
            routeImporter: RouteImporter(source: const _NoFileSource()),
            offlineTileCache: cache,
            rideStarted: false,
            discoveryCatalogueLoader: () async =>
                const MotorcycleDiscoveryCatalogue([]),
            bikerPlaceCatalogueLoader: () async => BikerPlaceCatalogue.empty,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Sunday loop'), findsOneWidget);
      expect(find.byKey(const Key('map-destination-search')), findsNothing);
    });

    testWidgets('a started ride shows the route, not a search field', (
      tester,
    ) async {
      // The riding chrome is settled and is not what this changes.
      await pumpMap(tester, started: true);

      expect(find.byKey(const Key('map-destination-search')), findsNothing);
      expect(find.text('Navigation'), findsOneWidget);
    });

    testWidgets('a follower is not offered a way to change the route', (
      tester,
    ) async {
      await pumpMap(tester, started: false, authority: RouteAuthority.follower);

      expect(find.byKey(const Key('map-destination-search')), findsNothing);
      expect(find.byTooltip('Plan a destination'), findsNothing);
    });
  });

  // #600. `rideStarted` was doing two jobs: "a ride is running" and "the rider
  // is following a route". Everything a navigating rider needs was therefore
  // reachable only inside a ride, which is why searching a destination in free
  // roam had to create one first — the ride was carrying the navigation.
  group('navigating is not the same as being in a ride', () {
    Future<void> pumpMap(
      WidgetTester tester, {
      required bool started,
      bool? navigating,
      ImportedRoute? route,
    }) async {
      SharedPreferences.setMockInitialValues({});
      final directory = Directory.systemTemp.createTempSync('navigating');
      addTearDown(() => directory.deleteSync(recursive: true));
      final cache = OfflineTileCache(
        rootDirectory: directory,
        configuration: const BasemapConfiguration(),
        httpClient: MockClient((_) async => http.Response('', 404)),
      );
      addTearDown(cache.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: RideMapScreen(
            routeStore: InMemoryRouteStore(route),
            routeImporter: RouteImporter(source: const _NoFileSource()),
            offlineTileCache: cache,
            rideStarted: started,
            navigating: navigating,
            routeAuthority: RouteAuthority.personal,
            discoveryCatalogueLoader: () async =>
                const MotorcycleDiscoveryCatalogue([]),
            bikerPlaceCatalogueLoader: () async => BikerPlaceCatalogue.empty,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('free roam can navigate without a ride', (tester) async {
      // The whole point. None of this was reachable outside a ride before.
      await pumpMap(
        tester,
        started: false,
        navigating: true,
        route: _testRoute(id: 'to-the-cafe', name: 'To the café'),
      );

      expect(find.byKey(const Key('ride-clock-position')), findsOneWidget);
      // The destination field gives way to the route once you are going.
      expect(find.byKey(const Key('map-destination-search')), findsNothing);
      expect(find.text('Choose a route'), findsNothing);
    });

    testWidgets('a map that is not navigating stays a map', (tester) async {
      await pumpMap(tester, started: false, navigating: false);

      expect(find.byKey(const Key('ride-clock-position')), findsNothing);
      expect(find.byKey(const Key('map-destination-search')), findsOneWidget);
    });

    testWidgets('omitting it follows the ride, as every caller meant before', (
      tester,
    ) async {
      // The compatibility guarantee. `navigating` is nullable so that the
      // split changed nothing until a surface opted in.
      await pumpMap(
        tester,
        started: true,
        route: _testRoute(id: 'ride-route', name: 'Ride route'),
      );

      expect(find.byKey(const Key('ride-clock-position')), findsOneWidget);
    });

    testWidgets('SOS and reporting still need a group, not just a route', (
      tester,
    ) async {
      // These relay to other riders and mean nothing alone, so they stay on
      // `rideStarted` while everything else moved.
      SharedPreferences.setMockInitialValues({});
      final directory = Directory.systemTemp.createTempSync('nav-solo-safety');
      addTearDown(() => directory.deleteSync(recursive: true));
      final cache = OfflineTileCache(
        rootDirectory: directory,
        configuration: const BasemapConfiguration(),
        httpClient: MockClient((_) async => http.Response('', 404)),
      );
      addTearDown(cache.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: RideMapScreen(
            routeStore: InMemoryRouteStore(
              _testRoute(id: 'solo', name: 'Solo run'),
            ),
            routeImporter: RouteImporter(source: const _NoFileSource()),
            offlineTileCache: cache,
            rideStarted: false,
            navigating: true,
            routeAuthority: RouteAuthority.personal,
            onEmergencyAlert: () async {},
            onReportHazard: (_) async {},
            discoveryCatalogueLoader: () async =>
                const MotorcycleDiscoveryCatalogue([]),
            bikerPlaceCatalogueLoader: () async => BikerPlaceCatalogue.empty,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('emergency-alert-button')), findsNothing);
      expect(find.byKey(const Key('report-sighting-button')), findsNothing);
    });
  });

  // #579. LEAVE appeared only once the ride was under way, so a rider who had
  // created a ride by mistake — or changed their mind about a solo one — had
  // to dig through the ride menu to get out of it.
  group('leaving a ride that has not started', () {
    Future<void> pumpRideMap(
      WidgetTester tester, {
      required bool started,
      Future<void> Function()? onLeave,
    }) async {
      SharedPreferences.setMockInitialValues({});
      final directory = Directory.systemTemp.createTempSync('leave-pre-start');
      addTearDown(() => directory.deleteSync(recursive: true));
      final cache = OfflineTileCache(
        rootDirectory: directory,
        configuration: const BasemapConfiguration(),
        httpClient: MockClient((_) async => http.Response('', 404)),
      );
      addTearDown(cache.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: RideMapScreen(
            routeStore: InMemoryRouteStore(),
            routeImporter: RouteImporter(source: const _NoFileSource()),
            offlineTileCache: cache,
            rideStarted: started,
            onLeaveRide: onLeave,
            discoveryCatalogueLoader: () async =>
                const MotorcycleDiscoveryCatalogue([]),
            bikerPlaceCatalogueLoader: () async => BikerPlaceCatalogue.empty,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('a created ride can be left before it starts', (tester) async {
      var left = false;
      await pumpRideMap(
        tester,
        started: false,
        onLeave: () async => left = true,
      );

      final leave = find.byKey(const Key('leave-ride-button'));
      expect(leave, findsOneWidget);
      await tester.tap(leave);
      await tester.pumpAndSettle();
      expect(left, isTrue);
    });

    testWidgets('a started ride keeps it, as before', (tester) async {
      await pumpRideMap(tester, started: true, onLeave: () async {});

      expect(find.byKey(const Key('leave-ride-button')), findsOneWidget);
    });

    testWidgets('free roam has no ride to leave', (tester) async {
      // No ride, so nothing to offer — the control must not appear just
      // because the gate moved.
      await pumpRideMap(tester, started: false);

      expect(find.byKey(const Key('leave-ride-button')), findsNothing);
    });
  });

  // #575, the quiet half. The dialog was offered only when *every* drawable
  // path was a track, so a file carrying a <trk> beside a <rte> was silently
  // given a raw line and no explanation.
  group('offering to make an import navigable', () {
    ImportedRoute routeWith(
      List<RoutePath> paths, {
      List<RouteManeuver> turns = const [],
    }) => ImportedRoute(
      id: 'r',
      name: 'r',
      importedAt: DateTime.utc(2026, 8, 16),
      sourceFileName: 'r.gpx',
      paths: paths,
      waypoints: const [],
      maneuvers: turns,
    );

    const track = RoutePath(
      kind: RoutePathKind.track,
      points: [
        GeoPoint(latitude: 51, longitude: -2),
        GeoPoint(latitude: 51.01, longitude: -2.01),
      ],
    );
    const plannedRoute = RoutePath(
      kind: RoutePathKind.route,
      points: [
        GeoPoint(latitude: 52, longitude: -3),
        GeoPoint(latitude: 52.01, longitude: -3.01),
      ],
    );

    test('a track alone is offered', () {
      expect(canGenerateNavigableRoute(routeWith(const [track])), isTrue);
    });

    test('a track beside a different route is still offered', () {
      // This returned false, which is why the MyRouteApp import landed with no
      // turn instructions and nothing said about it.
      expect(
        canGenerateNavigableRoute(routeWith(const [track, plannedRoute])),
        isTrue,
      );
    });

    test('a file with no track is not offered', () {
      expect(
        canGenerateNavigableRoute(routeWith(const [plannedRoute])),
        isFalse,
      );
    });

    test('a route that already has turns is not offered', () {
      expect(
        canGenerateNavigableRoute(
          routeWith(
            const [track],
            turns: const [
              RouteManeuver(
                position: GeoPoint(latitude: 51, longitude: -2),
                type: 'turn',
              ),
            ],
          ),
        ),
        isFalse,
      );
    });
  });

  // #576. Free roam used to be given `canEditRoute: false` — the flag that
  // means "somebody else leads this ride" — so a rider alone on the map was
  // refused their own café stop by a leadership rule with no group behind it,
  // and the refusal arrived stringified through the routing catch as
  // "Could not route via ...: FormatException: Only the ride leader ...".
  group('route authority', () {
    test('only a follower is refused, and the refusal is a plain sentence', () {
      expect(RouteAuthority.personal.canEditRoute, isTrue);
      expect(RouteAuthority.personal.routeChangeRefusal, isNull);
      expect(RouteAuthority.leader.canEditRoute, isTrue);
      expect(RouteAuthority.leader.routeChangeRefusal, isNull);

      expect(RouteAuthority.follower.canEditRoute, isFalse);
      expect(
        RouteAuthority.follower.routeChangeRefusal,
        'Only the ride leader can replace the group route.',
      );
      // Whatever it says, it must not read as a fault in the rider's input.
      expect(
        RouteAuthority.follower.routeChangeRefusal,
        isNot(contains('Exception')),
      );
    });

    test('a ride maps its own state onto an authority', () {
      expect(
        RouteAuthority.forRide(isSimulation: false, isLocalRideLeader: true),
        RouteAuthority.leader,
      );
      expect(
        RouteAuthority.forRide(isSimulation: false, isLocalRideLeader: false),
        RouteAuthority.follower,
      );
      // The simulator relays nothing, so it is not answerable to a leader even
      // when it is playing a follower.
      expect(
        RouteAuthority.forRide(isSimulation: true, isLocalRideLeader: false),
        RouteAuthority.personal,
      );
    });

    Future<void> pumpMap(
      WidgetTester tester, {
      required RouteAuthority authority,
      Object? changeRouteRequestToken,
    }) async {
      SharedPreferences.setMockInitialValues({});
      final directory = Directory.systemTemp.createTempSync('route-authority');
      addTearDown(() => directory.deleteSync(recursive: true));
      final cache = OfflineTileCache(
        rootDirectory: directory,
        configuration: const BasemapConfiguration(),
        httpClient: MockClient((_) async => http.Response('', 404)),
      );
      addTearDown(cache.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: RideMapScreen(
            routeStore: InMemoryRouteStore(),
            routeImporter: RouteImporter(source: const _NoFileSource()),
            offlineTileCache: cache,
            roadRoutingService: _StraightRoadRoutingService(),
            routeAuthority: authority,
            rideStarted: false,
            changeRouteRequestToken: changeRouteRequestToken,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('free roam is offered the route controls, not told to wait '
        'for a leader who does not exist', (tester) async {
      await pumpMap(tester, authority: RouteAuthority.personal);

      expect(find.text('Waiting for the leader’s route'), findsNothing);
      expect(
        find.byKey(const Key('plan-destination-empty-button')),
        findsOneWidget,
      );
      // Was `byTooltip('Plan a destination')` until #579. The intent is
      // unchanged — this surface offers a way to a destination rather than
      // telling a solo rider to wait for a leader — but the affordance moved
      // into the title slot so it sits where free roam's does.
      expect(find.byKey(const Key('map-destination-search')), findsOneWidget);
    });

    testWidgets('a follower is still told the leader owns the group route', (
      tester,
    ) async {
      await pumpMap(tester, authority: RouteAuthority.follower);

      expect(find.text('Waiting for the leader’s route'), findsOneWidget);
      expect(
        find.byKey(const Key('plan-destination-empty-button')),
        findsNothing,
      );
      expect(find.byTooltip('Plan a destination'), findsNothing);
    });

    // The reported symptom itself: tapping a café on the free-roam map and
    // asking to route via it.
    Future<_RouteStartRoutingService> tapCafe(
      WidgetTester tester, {
      required RouteAuthority authority,
    }) async {
      SharedPreferences.setMockInitialValues({});
      final directory = Directory.systemTemp.createTempSync('cafe-authority');
      addTearDown(() => directory.deleteSync(recursive: true));
      final cache = OfflineTileCache(
        rootDirectory: directory,
        configuration: const BasemapConfiguration(),
        httpClient: MockClient((_) async => http.Response('', 404)),
      );
      addTearDown(cache.dispose);
      final routing = _RouteStartRoutingService();
      final currentPosition = ValueNotifier<GeoPoint?>(null);
      addTearDown(currentPosition.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: RideMapScreen(
            routeStore: InMemoryRouteStore(),
            routeImporter: RouteImporter(source: const _NoFileSource()),
            offlineTileCache: cache,
            currentPosition: currentPosition,
            roadRoutingService: routing,
            routeAuthority: authority,
            rideStarted: false,
            // Both loaders are supplied: they share one Future.wait with the
            // layer preferences, so an asset read that fails in a widget test
            // takes the café visibility down with it.
            discoveryCatalogueLoader: () async =>
                const MotorcycleDiscoveryCatalogue([]),
            bikerPlaceCatalogueLoader: () async => const BikerPlaceCatalogue(
              places: [
                BikerPlace(
                  id: 'nearby',
                  name: 'Nearby biker café',
                  address: 'Bristol',
                  point: GeoPoint(latitude: 51.46, longitude: -2.52),
                  source: 'Test',
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      currentPosition.value = const GeoPoint(
        latitude: 51.4676,
        longitude: -2.5067,
      );
      await tester.pumpAndSettle();

      // Invoked rather than tapped: flutter_map's own gesture arena claims
      // pointer events over the map, so a synthetic tap never reaches the
      // marker's detector in a widget test. This is the handler that marker
      // wires up, and the hit test is not what this fix changed.
      tester
          .widget<GestureDetector>(
            find.descendant(
              of: find.byKey(const Key('free-roam-biker-cafes-layer')),
              matching: find.byType(GestureDetector),
            ),
          )
          .onTap!();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('route-via-biker-cafe-nearby')));
      await tester.pumpAndSettle();
      return routing;
    }

    testWidgets('a rider alone on the map may route via a café', (
      tester,
    ) async {
      final routing = await tapCafe(tester, authority: RouteAuthority.personal);

      expect(
        routing.calls,
        isNotEmpty,
        reason: 'free roam has no leader, so nothing may refuse this',
      );
      expect(find.textContaining('ride leader'), findsNothing);
      expect(find.textContaining('Could not route via'), findsNothing);
    });

    testWidgets('a follower tapping a café is refused without a stringified '
        'exception', (tester) async {
      final routing = await tapCafe(tester, authority: RouteAuthority.follower);

      expect(routing.calls, isEmpty);
      expect(
        find.text('Only the ride leader can replace the group route.'),
        findsOneWidget,
      );
      expect(find.textContaining('FormatException'), findsNothing);
      expect(find.textContaining('Could not route via'), findsNothing);
    });

    // The other half of the reported symptom: a twisty-road highlight rather
    // than a café. It is a separate guard on a separate handler, so it needs
    // its own coverage — deleting it passed every café test.
    Future<_RouteStartRoutingService> tapHighlight(
      WidgetTester tester, {
      required RouteAuthority authority,
    }) async {
      SharedPreferences.setMockInitialValues({});
      final directory = Directory.systemTemp.createTempSync('discovery-auth');
      addTearDown(() => directory.deleteSync(recursive: true));
      final cache = OfflineTileCache(
        rootDirectory: directory,
        configuration: const BasemapConfiguration(),
        httpClient: MockClient((_) async => http.Response('', 404)),
      );
      addTearDown(cache.dispose);
      final routing = _RouteStartRoutingService();
      final currentPosition = ValueNotifier<GeoPoint?>(null);
      addTearDown(currentPosition.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: RideMapScreen(
            routeStore: InMemoryRouteStore(),
            routeImporter: RouteImporter(source: const _NoFileSource()),
            offlineTileCache: cache,
            currentPosition: currentPosition,
            roadRoutingService: routing,
            routeAuthority: authority,
            rideStarted: false,
            discoveryCatalogueLoader: () async =>
                const MotorcycleDiscoveryCatalogue([
                  MotorcycleDiscoveryFeature(
                    id: 'twisty-nearby',
                    category: MotorcycleDiscoveryCategory.twistyHighlight,
                    name: 'Nearby twisty road',
                    points: [GeoPoint(latitude: 51.46, longitude: -2.52)],
                    sourceName: 'Test',
                    sourceUrl: 'https://example.test/road',
                    confidence: 'test',
                    lastVerified: '2026-08-16',
                    warning: 'Test fixture',
                  ),
                ]),
            bikerPlaceCatalogueLoader: () async => BikerPlaceCatalogue.empty,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      currentPosition.value = const GeoPoint(
        latitude: 51.4676,
        longitude: -2.5067,
      );
      await tester.pumpAndSettle();

      // See tapCafe: flutter_map owns the hit test, so the marker's own
      // handler is invoked instead of synthesising a pointer event.
      tester
          .widget<GestureDetector>(
            find
                .ancestor(
                  of: find.byIcon(Icons.route),
                  matching: find.byType(GestureDetector),
                )
                .first,
          )
          .onTap!();
      await tester.pumpAndSettle();
      final addToRoute = find.byKey(const Key('discovery-add-to-route'));
      await tester.ensureVisible(addToRoute);
      await tester.pumpAndSettle();
      await tester.tap(addToRoute);
      await tester.pumpAndSettle();
      return routing;
    }

    testWidgets('a rider alone on the map may route via a highlight', (
      tester,
    ) async {
      final routing = await tapHighlight(
        tester,
        authority: RouteAuthority.personal,
      );

      expect(routing.calls, isNotEmpty);
      expect(find.textContaining('ride leader'), findsNothing);
    });

    testWidgets('a follower tapping a highlight is refused in plain words', (
      tester,
    ) async {
      final routing = await tapHighlight(
        tester,
        authority: RouteAuthority.follower,
      );

      expect(routing.calls, isEmpty);
      expect(
        find.text('Only the ride leader can replace the group route.'),
        findsOneWidget,
      );
      expect(find.textContaining('FormatException'), findsNothing);
      expect(find.textContaining('Could not route via'), findsNothing);
    });

    testWidgets('a follower asked to change the route is refused in words a '
        'rider can read', (tester) async {
      await pumpMap(
        tester,
        authority: RouteAuthority.follower,
        changeRouteRequestToken: Object(),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('Only the ride leader can replace the group route.'),
        findsOneWidget,
      );
      // The defect was never the refusal itself, it was how it reached a rider.
      expect(find.textContaining('FormatException'), findsNothing);
      expect(find.textContaining('Could not route via'), findsNothing);
    });
  });
}

CompletedRide _completedHeatmapRide(ImportedRoute traveledRoute) =>
    CompletedRide(
      rideId: 'heatmap-ride',
      rideCode: '392725',
      rideName: 'Previous ride',
      localDisplayName: 'Oliver',
      localRole: RideRole.lead,
      startedAt: DateTime.utc(2026, 8, 12, 9),
      endedAt: DateTime.utc(2026, 8, 12, 10),
      archivedAt: DateTime.utc(2026, 8, 12, 10, 1),
      riderCount: 1,
      eventCount: 0,
      totalDistanceMeters: 1000,
      markerSessions: const [],
      plannedRoute: null,
      traveledRoute: traveledRoute,
    );

/// A received quick message as the ride shell publishes one.
RideQuickMessageAlert _quickMessageAlert({
  required String eventId,
  required QuickMessage message,
  required String senderDisplayName,
  QuickMessageOrigin? origin,
  bool raisedFromLocalRider = false,
  String? acknowledgedBy,
}) => RideQuickMessageAlert(
  message: ReceivedQuickMessage(
    eventId: eventId,
    senderRiderId: 'rider-$eventId',
    senderDisplayName: senderDisplayName,
    label: message.label,
    priority: message.priority,
    raisedAt: DateTime.now().subtract(const Duration(minutes: 2)),
    raisedFromLocalRider: raisedFromLocalRider,
    message: message,
    acknowledgements: [
      if (acknowledgedBy != null)
        QuickMessageAcknowledgement(
          riderId: 'rider-ack',
          displayName: acknowledgedBy,
          acknowledgedAt: DateTime.now(),
        ),
    ],
  ),
  origin: origin,
);

/// #105's `bottomChromeFraction`: the portrait band, plus the margin below it,
/// over the map viewport height.
///
/// Measured from the laid-out band rather than summed from assumed overlay
/// heights, and deliberately measured with the unconfigured development basemap
/// these tests use - its "route-only offline map" badge adds 36 pixels no rider
/// ever sees, so every number here is the pessimistic one.
double _bottomChromeFraction(WidgetTester tester, Size size) =>
    (tester.getRect(find.byKey(portraitBottomChromeKey)).height + 12) /
    size.height;

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

class _StubImportedTrackMatcher implements ImportedTrackMatcher {
  _StubImportedTrackMatcher(this.result) : error = null;

  _StubImportedTrackMatcher.failure(this.error) : result = null;

  final ImportedTrackMatch? result;
  final Object? error;
  final originals = <ImportedRoute>[];

  @override
  Future<ImportedTrackMatch> match(ImportedRoute original) async {
    originals.add(original);
    if (error case final failure?) throw failure;
    return result!;
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
  Future<RoadRouteResult> routeThrough(
    List<GeoPoint> waypoints, {
    RoutePreferences? preferences,
    double? originBearingDegrees,
  }) async => RoadRouteResult(
    points: waypoints,
    distanceMeters: 12000,
    duration: const Duration(minutes: 22),
  );
}

class _RouteStartRoutingService implements RoadRoutingService {
  final calls = <List<GeoPoint>>[];

  @override
  Future<RoadRouteResult> routeThrough(
    List<GeoPoint> waypoints, {
    RoutePreferences? preferences,
    double? originBearingDegrees,
  }) async {
    calls.add(List<GeoPoint>.of(waypoints));
    return RoadRouteResult(
      points: waypoints,
      distanceMeters: 11000,
      duration: const Duration(minutes: 15),
      maneuvers: [
        RoadRouteManeuver(
          position: GeoPoint(
            latitude: (waypoints.first.latitude + waypoints.last.latitude) / 2,
            longitude:
                (waypoints.first.longitude + waypoints.last.longitude) / 2,
          ),
          type: 'turn',
          modifier: 'left',
          name: 'Road to start',
        ),
      ],
    );
  }
}

class _WidgetSpeedLimitProvider implements SpeedLimitProvider {
  const _WidgetSpeedLimitProvider({this.unlimited = false});

  final bool unlimited;

  @override
  Future<SpeedLimitLookupResult> lookup({
    required SpeedLimitLocation current,
    SpeedLimitLocation? previous,
  }) async => SpeedLimitLookupResult.known(
    unlimited
        ? PostedSpeedLimit.unlimited(
            source: 'Test',
            checkedAt: current.recordedAt,
            matchDistanceMeters: 2,
          )
        : PostedSpeedLimit(
            milesPerHour: 30,
            source: 'Test',
            checkedAt: current.recordedAt,
            matchDistanceMeters: 2,
          ),
  );

  @override
  void close() {}
}

class _DeferredWidgetSpeedLimitProvider implements SpeedLimitProvider {
  final _result = Completer<SpeedLimitLookupResult>();
  int calls = 0;

  @override
  Future<SpeedLimitLookupResult> lookup({
    required SpeedLimitLocation current,
    SpeedLimitLocation? previous,
  }) {
    calls += 1;
    return _result.future;
  }

  void complete() => _result.complete(
    SpeedLimitLookupResult.known(
      PostedSpeedLimit(
        milesPerHour: 30,
        source: 'Test',
        checkedAt: DateTime.utc(2026, 8, 12, 17, 28),
        matchDistanceMeters: 2,
      ),
    ),
  );

  @override
  void close() {}
}

ImportedRoute _testRoute({
  required String id,
  required String name,
  List<RouteManeuver> maneuvers = const [],
}) => ImportedRoute(
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
  maneuvers: maneuvers,
);

/// Asserts a real red border, not merely a box that once had one.
///
/// The border *is* the whole warning after ten seconds, so "the keyed widget
/// exists" is not enough: a `DecoratedBox` with `border: null` satisfies that and
/// shows nothing. Mutation testing caught exactly that.
void expectRedBorder(WidgetTester tester, {String? reason}) {
  final finder = find.byKey(const Key('enforcement-alert-border'));
  expect(finder, findsOneWidget, reason: reason);
  final decoration =
      tester.widget<DecoratedBox>(finder).decoration as BoxDecoration;
  expect(decoration.border, isNotNull, reason: reason);
  expect(decoration.border!.top.width, enforcementBorderWidth, reason: reason);
  expect(decoration.border!.top.color, const Color(0xFFFF3B30), reason: reason);
  expect(
    decoration.borderRadius,
    BorderRadius.circular(enforcementBorderRadius),
    reason: reason,
  );
}
