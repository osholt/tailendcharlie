import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:ride_relay/domain/distance_unit.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/domain/route_store.dart';
import 'package:ride_relay/features/map/ride_map.dart';
import 'package:ride_relay/features/map/route_review_screen.dart';
import 'package:ride_relay/services/basemap_configuration.dart';
import 'package:ride_relay/services/gpx_import_source.dart';
import 'package:ride_relay/services/offline_tile_cache.dart';
import 'package:ride_relay/services/route_importer.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'maplibre_recording_harness.dart';

/// #935: the route's start, stops and end are drawn upright on screen however
/// the map is turned.
///
/// > The start and end markers on the map rotate with the tiles rather than
/// > pointing straight up.
///
/// Each renderer draws them itself and fails in its own way, so each gets its
/// own test: flutter_map (the iOS map) draws a pin widget, which turned with the
/// tiles unless its layer counter-rotates; MapLibre (the Android map) draws a
/// circle layer, which has no heading to lose but could be tilted flat.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/maplibre_gl_0'),
          (_) async => null,
        );
  });

  /// How far the widget [finder] is turned on the screen, in degrees: the
  /// rotation of every ancestor transform composed together.
  double screenRotationDegrees(WidgetTester tester, Finder finder) {
    final matrix = tester.renderObject<RenderBox>(finder).getTransformTo(null);
    return math.atan2(matrix.entry(1, 0), matrix.entry(0, 0)) * 180 / math.pi;
  }

  group('flutter_map (the iOS map)', () {
    testWidgets('the route pins on the ride map stay upright as the map turns', (
      tester,
    ) async {
      final directory = Directory.systemTemp.createTempSync('upright-fm');
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
            routeStore: InMemoryRouteStore(_routeWithPins),
            routeImporter: RouteImporter(source: const _NoFileSource()),
            offlineTileCache: cache,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      try {
        final pins = find.descendant(
          of: find.byKey(const Key('ride-route-waypoint-layer')),
          matching: find.byIcon(Icons.location_on),
        );
        expect(pins, findsNWidgets(3), reason: 'start, a stop and the end');
        final controller = MapController.of(tester.element(pins.first));

        for (final turn in [0.0, 90.0, 135.0, -120.0, 200.0]) {
          // Centred on the route at a zoom that keeps all three pins on screen
          // whichever way it is turned: a marker off screen is not built.
          controller.moveAndRotate(_routeCentre, 14, turn);
          await tester.pump();
          // Guard the guard: the map really has turned, so an upright pin is
          // the layer's doing and not a map that never moved.
          expect(
            (controller.camera.rotation - turn).abs(),
            lessThan(0.001),
            reason: 'the map must have turned to $turn degrees',
          );
          for (var pin = 0; pin < 3; pin++) {
            expect(
              screenRotationDegrees(tester, pins.at(pin)),
              closeTo(0, 0.01),
              reason:
                  'pin $pin must point straight up with the map turned '
                  '$turn degrees',
            );
          }
        }
      } finally {
        await tester.pump(const Duration(seconds: 2));
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 11));
        await tester.pump();
      }
    });

    testWidgets('the numbered pins on the route review stay upright too', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: RouteReviewScreen(
            route: _routeWithPins,
            distanceUnit: DistanceUnit.miles,
            basemapConfiguration: const BasemapConfiguration(),
          ),
        ),
      );
      await tester.pump();

      final pins = find.descendant(
        of: find.byKey(const Key('route-review-waypoints')),
        matching: find.byIcon(Icons.location_on),
      );
      expect(pins, findsNWidgets(3));
      final controller = MapController.of(tester.element(pins.first));
      for (final turn in [90.0, 135.0, -120.0]) {
        controller.moveAndRotate(_routeCentre, 14, turn);
        await tester.pump();
        expect(
          (controller.camera.rotation - turn).abs(),
          lessThan(0.001),
          reason: 'the map must have turned to $turn degrees',
        );
        for (var pin = 0; pin < 3; pin++) {
          expect(
            screenRotationDegrees(tester, pins.at(pin)),
            closeTo(0, 0.01),
            reason: 'review pin $pin must stay upright at $turn degrees',
          );
        }
      }
    });
  });

  group('MapLibre (the Android map)', () {
    testWidgets(
      'draws the start, stops and end as circles that face the screen, and '
      'adds no map-aligned symbol for them',
      (tester) async {
        final directory = Directory.systemTemp.createTempSync('upright-ml');
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
              routeStore: InMemoryRouteStore(_routeWithPins),
              routeImporter: RouteImporter(source: const _NoFileSource()),
              offlineTileCache: cache,
            ),
          ),
        );

        try {
          final layer = calls.layer('ride-relay-waypoint-circles');
          final properties = layer['properties'] as Map;
          expect(
            properties['circle-pitch-alignment'],
            'viewport',
            reason:
                'a circle on a tilted map stays a circle facing the rider '
                'instead of lying on the ground as an ellipse',
          );
          // A circle layer cannot turn with the map, so what must not happen is
          // somebody replacing it with a symbol that does. A symbol sourced
          // from the waypoints has to say it faces the screen.
          for (final call in calls) {
            if (call.method != 'symbolLayer#add') continue;
            final arguments = call.arguments as Map;
            if (arguments['sourceId'] != 'ride-relay-waypoints') continue;
            final symbol = arguments['properties'] as Map;
            expect(symbol['icon-rotation-alignment'], 'viewport');
            expect(symbol['icon-pitch-alignment'], 'viewport');
          }
        } finally {
          await tester.pump(const Duration(seconds: 2));
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(seconds: 11));
          await tester.pump();
        }
      },
    );
  });
}

// Synthetic places; none is a rider's start, finish or home.
const _routeCentre = LatLng(53.0005, -1.01);

final _routeWithPins = ImportedRoute(
  id: 'upright-pins',
  name: 'Upright pins',
  importedAt: DateTime.utc(2026, 10, 10),
  sourceFileName: 'route.gpx',
  paths: const [
    RoutePath(
      kind: RoutePathKind.track,
      points: [
        GeoPoint(latitude: 53, longitude: -1.02),
        GeoPoint(latitude: 53.001, longitude: -1.01),
        GeoPoint(latitude: 53, longitude: -1.00),
      ],
    ),
  ],
  waypoints: const [
    RouteWaypoint(
      point: GeoPoint(latitude: 53, longitude: -1.02),
      name: 'Start',
    ),
    RouteWaypoint(
      point: GeoPoint(latitude: 53.001, longitude: -1.01),
      name: 'Stop',
    ),
    RouteWaypoint(point: GeoPoint(latitude: 53, longitude: -1.00), name: 'End'),
  ],
);

class _NoFileSource implements GpxImportSource {
  const _NoFileSource();

  @override
  Future<PickedGpxFile?> pickGpxFile() async => null;
}
