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
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.byType(AppBar), findsNothing);
      expect(find.byKey(const Key('group-mini-map')), findsOneWidget);
      expect(find.text('GROUP 3'), findsOneWidget);
      expect(find.byKey(const Key('navigation-follow-button')), findsNothing);
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
}

class _NoFileSource implements GpxImportSource {
  const _NoFileSource();

  @override
  Future<PickedGpxFile?> pickGpxFile() async => null;
}
