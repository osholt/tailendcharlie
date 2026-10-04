import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/domain/route_store.dart';
import 'package:ride_relay/features/map/ride_map.dart';
import 'package:ride_relay/services/basemap_configuration.dart';
import 'package:ride_relay/services/gpx_import_source.dart';
import 'package:ride_relay/services/offline_tile_cache.dart';
import 'package:ride_relay/services/route_importer.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'maplibre_recording_harness.dart';

/// #842: the purple line that shows a follower how far ahead the leader is was
/// painted beneath the orange travelled track, so it disappeared wherever the
/// two overlapped. Every renderer now paints route lines, then the leader's
/// trail, then rider markers.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/maplibre_gl_0'),
          (_) async => null,
        );
  });

  group('the shared line order', () {
    test(
      'paints every route line before the leader trail, then the rejoin',
      () {
        const order = RouteTrailStyle.lineOrder;

        int at(RideMapLine line) => order.indexOf(line);
        for (final route in [
          RideMapLine.riddenRoute,
          RideMapLine.riderTrail,
          RideMapLine.remainingRoute,
          RideMapLine.offRouteTrail,
        ]) {
          expect(
            at(route),
            lessThan(at(RideMapLine.leaderTrail)),
            reason: '$route is a route line, so the leader trail goes over it',
          );
        }
        expect(
          at(RideMapLine.rejoinTrail),
          order.length - 1,
          reason:
              'the rejoin route is what the rider is being asked to follow, '
              'so nothing may cover it',
        );
      },
    );

    test('names every line exactly once', () {
      expect(
        RouteTrailStyle.lineOrder.toSet(),
        RideMapLine.values.toSet(),
        reason: 'a line left out of the order would never be drawn',
      );
      expect(
        RouteTrailStyle.lineOrder.length,
        RideMapLine.values.length,
        reason: 'and one listed twice would be drawn twice',
      );
    });

    test('every trail kind resolves to its own line', () {
      for (final kind in RiderTrailKind.values) {
        expect(RouteTrailStyle.lineForTrail(kind).trailKind, kind);
      }
    });
  });

  testWidgets(
    'flutter_map (the iOS renderer) paints the leader trail over the route lines',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync('line-order-fm');
      addTearDown(() => directory.deleteSync(recursive: true));
      final cache = OfflineTileCache(
        rootDirectory: directory,
        configuration: const BasemapConfiguration(),
        httpClient: MockClient((_) async => http.Response('', 404)),
      );
      addTearDown(cache.dispose);
      final trails = ValueNotifier<List<MapOverlayTrace>>([
        _trace('leader', RiderTrailKind.leader),
        _trace('rider', RiderTrailKind.rider),
        _trace('off-route', RiderTrailKind.offRoute),
        _trace('rejoin', RiderTrailKind.rejoin),
      ]);
      addTearDown(trails.dispose);
      final overlays = ValueNotifier<List<MapOverlayMarker>>(const [
        MapOverlayMarker(
          id: 'rider-blake',
          point: GeoPoint(latitude: 53.001, longitude: -1.01),
          label: 'Blake',
        ),
      ]);
      addTearDown(overlays.dispose);
      final navigation = ValueNotifier<MapNavigationPosition?>(
        MapNavigationPosition(
          point: const GeoPoint(latitude: 53, longitude: -1.01),
          recordedAt: DateTime.utc(2026, 10, 4, 12),
          speedMetersPerSecond: 12,
          headingDegrees: 90,
        ),
      );
      addTearDown(navigation.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: RideMapScreen(
            routeStore: InMemoryRouteStore(_route),
            routeImporter: RouteImporter(source: const _NoFileSource()),
            offlineTileCache: cache,
            navigationPosition: navigation,
            riderTrails: trails,
            overlayMarkers: overlays,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await _thenTearDownMap(tester, () async {
        final layer = tester.widget<PolylineLayer>(find.byType(PolylineLayer));
        final colours = [for (final line in layer.polylines) line.color];
        int first(RouteLineStyle style) => colours.indexOf(style.color);
        int last(RouteLineStyle style) => colours.lastIndexOf(style.color);

        expect(first(RouteTrailStyle.leaderTrail), isNonNegative);
        for (final route in [
          RouteTrailStyle.travelled,
          RouteTrailStyle.routeAhead,
          RouteTrailStyle.offRouteTrail,
        ]) {
          expect(first(route), isNonNegative, reason: 'the line must be drawn');
          expect(
            last(route),
            lessThan(first(RouteTrailStyle.leaderTrail)),
            reason: 'the leader trail is painted over ${route.color}',
          );
        }
        expect(
          first(RouteTrailStyle.rejoinBreadcrumb),
          greaterThan(last(RouteTrailStyle.leaderTrail)),
          reason: 'the rejoin route stays on top of every other line',
        );

        // Rider markers are separate layers, added after the polylines.
        final children = tester
            .widget<FlutterMap>(find.byType(FlutterMap))
            .children;
        expect(
          children.indexWhere((child) => child is PolylineLayer),
          lessThan(
            children.indexWhere(
              (child) =>
                  child is ValueListenableBuilder<List<MapOverlayMarker>>,
            ),
          ),
          reason: 'rider markers are painted over every line',
        );
      });
    },
  );

  testWidgets(
    'the group overview paints the route, then the leader trail, then the riders',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync('line-order-mini');
      addTearDown(() => directory.deleteSync(recursive: true));
      final cache = OfflineTileCache(
        rootDirectory: directory,
        configuration: const BasemapConfiguration(),
        httpClient: MockClient((_) async => http.Response('', 404)),
      );
      addTearDown(cache.dispose);
      const riderColour = Color(0xFF123456);
      final overlays = ValueNotifier<List<MapOverlayMarker>>(const [
        MapOverlayMarker(
          id: 'rider-blake',
          point: GeoPoint(latitude: 53.0004, longitude: -1.0135),
          label: 'Blake',
          color: riderColour,
        ),
      ]);
      addTearDown(overlays.dispose);
      final trails = ValueNotifier<List<MapOverlayTrace>>([
        MapOverlayTrace(
          id: 'leader',
          label: 'Blake leader trail',
          kind: RiderTrailKind.leader,
          points: _denseLine(latitude: 53.0002),
        ),
      ]);
      addTearDown(trails.dispose);
      final position = ValueNotifier<GeoPoint?>(
        const GeoPoint(latitude: 53, longitude: -1.015),
      );
      addTearDown(position.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: RideMapScreen(
            routeStore: InMemoryRouteStore(_denseRoute),
            routeImporter: RouteImporter(source: const _NoFileSource()),
            offlineTileCache: cache,
            currentPosition: position,
            overlayMarkers: overlays,
            riderTrails: trails,
            groupRiderCount: 2,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await _thenTearDownMap(tester, () async {
        final overview = tester.renderObject(
          find.byKey(const Key('group-mini-map-local-fallback')),
        );
        expect(
          overview,
          paints
            // Each line is a casing and then its colour.
            ..path(color: RouteTrailStyle.casing)
            ..path(color: RouteTrailStyle.miniMapRoute.color)
            ..path(color: RouteTrailStyle.casing)
            ..path(color: RouteTrailStyle.miniMapLeaderTrail.color)
            ..path(color: riderColour),
          reason: 'route, then the leader trail over it, then the rider on top',
        );
      });
    },
  );

  testWidgets(
    'MapLibre (the Android renderer) adds the leader trail after the route lines '
    'and before every rider marker',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync('line-order-ml');
      addTearDown(() => directory.deleteSync(recursive: true));
      final cache = OfflineTileCache(
        rootDirectory: directory,
        configuration: const BasemapConfiguration(
          styleUrl: 'https://tiles.example.com/styles/liberty',
          attribution: 'Example contributors',
        ),
        httpClient: MockClient((_) async => http.Response('', 404)),
      );
      addTearDown(cache.dispose);

      final calls = await recordMapLibreStyleSetUp(
        tester,
        MaterialApp(
          home: RideMapScreen(
            routeStore: InMemoryRouteStore(),
            routeImporter: RouteImporter(source: const _NoFileSource()),
            offlineTileCache: cache,
          ),
        ),
      );

      await _thenTearDownMap(tester, () async {
        final lines = calls.layerIds('lineLayer#add');
        expect(
          lines.where(
            (id) =>
                id.startsWith('ride-relay-route-') ||
                id.startsWith('ride-relay-trail-'),
          ),
          [
            'ride-relay-route-ridden-border',
            'ride-relay-route-ridden',
            'ride-relay-trail-rider-casing',
            'ride-relay-trail-rider-line',
            'ride-relay-route-remaining-border',
            'ride-relay-route-remaining',
            'ride-relay-trail-offRoute-casing',
            'ride-relay-trail-offRoute-line',
            'ride-relay-trail-leader-casing',
            'ride-relay-trail-leader-line',
            'ride-relay-trail-rejoin-casing',
            'ride-relay-trail-rejoin-line',
          ],
          reason: 'route lines, then the leader trail, then the rejoin route',
        );

        // MapLibre paints layers in the order they were added, so everything
        // that is a rider marker has to come after the last line.
        final everything = calls.allLayerIds;
        final lastLine = everything.lastIndexOf('ride-relay-trail-rejoin-line');
        for (final marker in [
          'ride-relay-position-badge',
          'ride-relay-position-icon',
          'ride-relay-overlay-badges',
          'ride-relay-overlay-icons',
        ]) {
          expect(everything, contains(marker));
          expect(
            everything.indexOf(marker),
            greaterThan(lastLine),
            reason: '$marker is a rider marker and goes over every line',
          );
        }
      });
    },
  );
}

/// Runs [body], and lets the map's own timers run out before the tree goes
/// whether it passed or not, so one failure cannot leak into the next test.
Future<void> _thenTearDownMap(
  WidgetTester tester,
  Future<void> Function() body,
) async {
  try {
    await body();
  } finally {
    // The follow camera may be easing towards the rider; let it arrive first.
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 11));
    await tester.pump();
  }
}

List<GeoPoint> _denseLine({required double latitude}) => [
  for (var step = 0; step <= 20; step++)
    GeoPoint(latitude: latitude, longitude: -1.02 + step * 0.001),
];

final _denseRoute = ImportedRoute(
  id: 'dense-route',
  name: 'Dense route',
  importedAt: DateTime.utc(2026, 10, 4),
  sourceFileName: 'route.gpx',
  paths: [
    RoutePath(kind: RoutePathKind.track, points: _denseLine(latitude: 53)),
  ],
  waypoints: const [],
);

MapOverlayTrace _trace(String id, RiderTrailKind kind) => MapOverlayTrace(
  id: id,
  label: id,
  kind: kind,
  points: const [
    GeoPoint(latitude: 53, longitude: -1.02),
    GeoPoint(latitude: 53.002, longitude: -1.014),
  ],
);

final _route = ImportedRoute(
  id: 'line-order',
  name: 'Line order',
  importedAt: DateTime.utc(2026, 10, 4),
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

class _NoFileSource implements GpxImportSource {
  const _NoFileSource();

  @override
  Future<PickedGpxFile?> pickGpxFile() async => null;
}
