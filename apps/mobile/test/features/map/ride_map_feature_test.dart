import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ride_relay/controllers/speed_limit_display_controller.dart';
import 'package:ride_relay/domain/distance_unit.dart';
import 'package:ride_relay/domain/geo_point.dart' as awareness_geo;
import 'package:ride_relay/domain/hazard.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/domain/route_store.dart';
import 'package:ride_relay/domain/route_alert.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/features/map/ride_map.dart';
import 'package:ride_relay/services/basemap_configuration.dart';
import 'package:ride_relay/services/enforcement_alert_detector.dart';
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
            canEditRoute: false,
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
    },
  );

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
    expect(find.text('Roundabout, 2nd exit, straight on'), findsOneWidget);
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
    expect(find.textContaining('Charlie · 2.0 mi · ~4 min'), findsOneWidget);
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
    expect(
      find.textContaining('Tail End Charlie · waiting for location'),
      findsOneWidget,
    );
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

  testWidgets('map exposes an informed speed-limit opt-in', (tester) async {
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
    expect(
      tester
          .widget<Text>(find.byKey(const Key('posted-speed-limit-caption')))
          .data,
      startsWith('MOVE TO IDENTIFY ROAD'),
    );
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
      speedMetersPerSecond: 20,
    );
    await speedLimitDisplay.waitForIdle();
    await tester.pump();

    expect(find.byKey(const Key('posted-speed-limit-badge')), findsOneWidget);
    expect(find.text('30'), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const Key('posted-speed-limit-caption')))
          .data,
      'MPH · MAPPED LIMIT · GPS SPEED',
    );
    // 20 m/s is 45 mph, shown below the sign at the sign's own font size.
    final riderSpeed = tester.widget<Text>(
      find.byKey(const Key('posted-speed-limit-rider-speed')),
    );
    expect(riderSpeed.data, '45');
    expect(riderSpeed.style?.fontSize, 26);
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
    // The sighting button sits directly above the speed-limit control.
    expect(
      tester.getBottomLeft(button).dy,
      lessThanOrEqualTo(
        tester.getTopLeft(find.byKey(const Key('speed-limit-opt-in-chip'))).dy,
      ),
    );

    await tester.tap(button);
    await tester.pumpAndSettle();
    final option = find.byKey(const Key('report-speed-camera-option'));
    expect(option, findsOneWidget);
    expect(tester.getSize(option).height, greaterThanOrEqualTo(72));

    await tester.tap(option);
    await tester.pumpAndSettle();

    expect(reported, [HazardType.speedCamera]);
    expect(find.textContaining('Speed camera reported'), findsOneWidget);
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

  testWidgets('an approaching speed camera takes over the map', (tester) async {
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

    await tester.tap(find.byKey(const Key('enforcement-alert-overlay')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('enforcement-alert-overlay')), findsNothing);
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
    expect(find.byKey(const Key('leader-tec-gap')), findsOneWidget);
    expect(find.text('TEC'), findsOneWidget);
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
      expect(find.text('3 RIDERS'), findsOneWidget);
      expect(find.byKey(const Key('mini-map-you-legend')), findsOneWidget);
      expect(find.byKey(const Key('mini-map-north-indicator')), findsOneWidget);
      expect(find.byKey(const Key('mini-map-scale')), findsOneWidget);
      expect(
        find.byKey(const Key('navigation-guidance-banner')),
        findsOneWidget,
      );
      expect(
        find.textContaining('Roundabout, 3rd exit, right'),
        findsOneWidget,
      );
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
      final travelled = lineWithColor(RouteTrailStyle.travelled.color);
      expect(travelled.pattern, const StrokePattern.solid());
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
        greaterThan(layer.polylines.indexOf(travelled)),
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

    // Alerts that may interrupt, versus chrome that is always on screen.
    const urgentKeys = {'ride-paused-banner', 'leader-off-course-alert'};
    final overlayKeys = <String>[
      'navigation-guidance-banner',
      'leader-off-course-alert',
      'leader-tec-gap',
      'group-mini-map',
      'ride-menu-button',
      'emergency-alert-button',
      'leave-ride-button',
      'speed-limit-opt-in-chip',
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

      for (final entry in rects.entries) {
        // Persistent chrome keeps out of the upper band, which is reserved for
        // the road ahead. Urgent alerts are the one exception #104 allows: they
        // interrupt by growing the band upwards, never by anchoring to the top.
        if (!urgentKeys.contains(entry.key)) {
          expect(
            entry.value.top,
            greaterThanOrEqualTo(size.height / 3),
            reason: '${entry.key} intrudes into the upper band in $size',
          );
        }
        expect(entry.value.left, greaterThanOrEqualTo(0));
        expect(entry.value.right, lessThanOrEqualTo(size.width));
        expect(entry.value.bottom, lessThanOrEqualTo(size.height));
      }

      final persistentTop = rects.entries
          .where((entry) => !urgentKeys.contains(entry.key))
          .map((entry) => entry.value.top)
          .reduce((a, b) => a < b ? a : b);
      for (final key in urgentKeys) {
        expect(
          rects[key]!.bottom,
          lessThanOrEqualTo(persistentTop),
          reason: '$key must stack inside the band, not float over the map',
        );
      }

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
        // Landscape keeps the centre column clear so the rider's own marker
        // and the road ahead are never behind chrome.
        for (final entry in rects.entries) {
          final clearsCentre =
              entry.value.right <= size.width * 0.45 ||
              entry.value.left >= size.width * 0.55;
          expect(
            clearsCentre,
            isTrue,
            reason: '${entry.key} crosses the centre column in $size',
          );
        }
      } else {
        // Portrait chrome is one measured band whose height the camera reads to
        // clamp its forward bias. Every surface being live at once is the worst
        // case and still leaves the upper third of the map clear; this guards
        // against the band growing beyond that.
        final bandTop = rects.values
            .map((rect) => rect.top)
            .reduce((a, b) => a < b ? a : b);
        expect(size.height - bandTop, lessThan(size.height * 0.62));
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
        ),
      ),
    );

    await verifyLayout(landscape: false);
    await verifyLayout(landscape: true);

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
