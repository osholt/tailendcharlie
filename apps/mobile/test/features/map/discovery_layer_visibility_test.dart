import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/domain/route_store.dart';
import 'package:ride_relay/features/map/discovery_layer_visibility.dart';
import 'package:ride_relay/features/map/ride_map.dart';
import 'package:ride_relay/services/basemap_configuration.dart';
import 'package:ride_relay/services/biker_place_catalogue.dart';
import 'package:ride_relay/services/gpx_import_source.dart';
import 'package:ride_relay/services/motorcycle_discovery.dart';
import 'package:ride_relay/services/offline_tile_cache.dart';
import 'package:ride_relay/services/route_importer.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'maplibre_recording_harness.dart';

/// #846: the orange and blue discovery highlights sat beside the route line while
/// riding and were confusing. They are for choosing where to go, so they are
/// hidden while navigating and kept for planning, route review and browsing -
/// without ever touching what the rider chose in the layer menu.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/maplibre_gl_0'),
          (_) async => null,
        );
  });

  group('which modes draw the discovery layers', () {
    test('every mode is decided', () {
      expect(
        {
          for (final context in DiscoveryLayerContext.values)
            context: discoveryLayersShownIn(context),
        },
        {
          DiscoveryLayerContext.freeRoamBrowsing: true,
          DiscoveryLayerContext.planning: true,
          DiscoveryLayerContext.routeReview: true,
          DiscoveryLayerContext.freeRoamNavigation: false,
          DiscoveryLayerContext.rideNavigation: false,
        },
      );
    });

    test('a map with nothing being followed is free roam', () {
      expect(
        discoveryLayerContextFor(
          navigating: false,
          rideStarted: false,
          hasRoute: false,
        ),
        DiscoveryLayerContext.freeRoamBrowsing,
      );
    });

    test('a route that nobody is following yet is planning', () {
      // A route looked over in free roam, or a group ride that has not started.
      expect(
        discoveryLayerContextFor(
          navigating: false,
          rideStarted: false,
          hasRoute: true,
        ),
        DiscoveryLayerContext.planning,
      );
    });

    test('a started ride that is following a route is navigating', () {
      for (final hasRoute in [true, false]) {
        expect(
          discoveryLayerContextFor(
            navigating: true,
            rideStarted: true,
            hasRoute: hasRoute,
          ),
          DiscoveryLayerContext.rideNavigation,
        );
      }
    });

    test('following a route in free roam is navigating without a ride', () {
      expect(
        discoveryLayerContextFor(
          navigating: true,
          rideStarted: false,
          hasRoute: true,
        ),
        DiscoveryLayerContext.freeRoamNavigation,
      );
    });

    test('only navigating hides the layers, whatever else is true', () {
      for (final navigating in [false, true]) {
        for (final rideStarted in [false, true]) {
          for (final hasRoute in [false, true]) {
            final context = discoveryLayerContextFor(
              navigating: navigating,
              rideStarted: rideStarted,
              hasRoute: hasRoute,
            );
            expect(
              discoveryLayersShownIn(context),
              !navigating,
              reason:
                  'navigating=$navigating rideStarted=$rideStarted '
                  'hasRoute=$hasRoute resolved to $context',
            );
          }
        }
      }
    });
  });

  group('the free-roam map (flutter_map, the iOS renderer)', () {
    testWidgets('browsing draws the layers, a started ride hides them, and '
        'ending it brings the same layers back', (tester) async {
      final scene = await _pumpScene(tester, rideStarted: false);
      _expectLayers(tester, drawn: true);

      await scene.update(rideStarted: true);
      _expectLayers(tester, drawn: false);

      await scene.update(rideStarted: false);
      _expectLayers(tester, drawn: true);
      await scene.finish();
    });

    testWidgets('following a route in free roam, without a ride, hides them', (
      tester,
    ) async {
      final scene = await _pumpScene(
        tester,
        rideStarted: false,
        navigating: false,
      );
      _expectLayers(tester, drawn: true);

      await scene.update(rideStarted: false, navigating: true);
      _expectLayers(tester, drawn: false);

      await scene.update(rideStarted: false, navigating: false);
      _expectLayers(tester, drawn: true);
      await scene.finish();
    });

    testWidgets('a route being planned keeps them', (tester) async {
      final scene = await _pumpScene(tester, rideStarted: false, route: _route);

      _expectLayers(tester, drawn: true);
      await scene.finish();
    });

    testWidgets('hiding them never changes what the rider chose', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        'map_layer_biker_cafes_visible': true,
        'map_layer_discovery_twisty_highlight_visible': true,
        'map_layer_discovery_good_biking_road_visible': false,
        'map_layer_discovery_mountain_pass_visible': false,
      });
      final chosen = await _savedLayerChoices();
      final scene = await _pumpScene(tester, rideStarted: false);
      _expectLayers(tester, drawn: true);

      await scene.update(rideStarted: true);
      _expectLayers(tester, drawn: false);
      expect(
        await _savedLayerChoices(),
        chosen,
        reason: 'the layers are hidden while navigating, not switched off',
      );

      await scene.update(rideStarted: false);
      _expectLayers(tester, drawn: true);
      expect(await _savedLayerChoices(), chosen);
      await scene.finish();
    });
  });

  testWidgets(
    'MapLibre (the Android renderer) empties its discovery sources while '
    'navigating and refills them when navigation ends',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync('discovery-ml');
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
      final position = ValueNotifier<GeoPoint?>(_position);
      addTearDown(position.dispose);

      Widget screen({required bool rideStarted}) => MaterialApp(
        home: RideMapScreen(
          routeStore: InMemoryRouteStore(),
          routeImporter: RouteImporter(source: const _NoFileSource()),
          offlineTileCache: cache,
          currentPosition: position,
          rideStarted: rideStarted,
          discoveryCatalogueLoader: () async =>
              const MotorcycleDiscoveryCatalogue([_twisty]),
          bikerPlaceCatalogueLoader: () async => _cafes,
        ),
      );

      final calls = await recordMapLibreStyleSetUp(
        tester,
        screen(rideStarted: false),
      );
      Future<void> until(bool Function() condition) async {
        final deadline = DateTime.now().add(const Duration(seconds: 20));
        while (!condition() && DateTime.now().isBefore(deadline)) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 20));
        }
      }

      // The last GeoJSON a source was handed is what the native map draws.
      int features(String sourceId) {
        final writes = [
          for (final call in calls)
            if ((call.method == 'source#addGeoJson' ||
                    call.method == 'source#setGeoJson') &&
                (call.arguments as Map)['sourceId'] == sourceId)
              call,
        ];
        final geoJson =
            jsonDecode((writes.last.arguments as Map)['geojson'] as String)
                as Map;
        return (geoJson['features'] as List).length;
      }

      // The control: with no ride the highlight and the café reach the native map.
      await until(
        () =>
            features('ride-relay-discovery-lines') == 1 &&
            features('ride-relay-discovery-points') == 2,
      );
      expect(features('ride-relay-discovery-lines'), 1);
      expect(features('ride-relay-discovery-points'), 2);

      // Navigating: the same map is told to draw neither.
      await tester.pumpWidget(screen(rideStarted: true));
      await until(
        () =>
            features('ride-relay-discovery-lines') == 0 &&
            features('ride-relay-discovery-points') == 0,
      );
      expect(features('ride-relay-discovery-lines'), 0);
      expect(features('ride-relay-discovery-points'), 0);

      // Navigation ends: they come back.
      await tester.pumpWidget(screen(rideStarted: false));
      await until(() => features('ride-relay-discovery-lines') == 1);
      expect(features('ride-relay-discovery-lines'), 1);
      expect(features('ride-relay-discovery-points'), 2);

      await tester.pump(const Duration(seconds: 2));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 11));
      await tester.pump();
    },
  );
}

const _position = GeoPoint(latitude: 53.3, longitude: -1.8);

const _twisty = MotorcycleDiscoveryFeature(
  id: 'twisty-nearby',
  category: MotorcycleDiscoveryCategory.twistyHighlight,
  name: 'Nearby twisty road',
  points: [
    GeoPoint(latitude: 53.29, longitude: -1.82),
    GeoPoint(latitude: 53.31, longitude: -1.78),
  ],
  sourceName: 'Test',
  sourceUrl: 'https://example.test/road',
  confidence: 'test',
  lastVerified: '2026-10-04',
  warning: 'Test fixture',
);

const _cafes = BikerPlaceCatalogue(
  places: [
    BikerPlace(
      id: 'cafe-nearby',
      name: 'Nearby biker café',
      address: 'Test',
      // Far enough from the highlight's midpoint that the two are not folded
      // into one marker at the zoom the map is opened at.
      point: GeoPoint(latitude: 53.38, longitude: -1.68),
      source: 'Test',
    ),
  ],
);

final _route = ImportedRoute(
  id: 'discovery-route',
  name: 'Discovery route',
  importedAt: DateTime.utc(2026, 10, 4),
  sourceFileName: 'route.gpx',
  paths: const [
    RoutePath(
      kind: RoutePathKind.track,
      points: [
        GeoPoint(latitude: 53.29, longitude: -1.83),
        GeoPoint(latitude: 53.30, longitude: -1.80),
        GeoPoint(latitude: 53.31, longitude: -1.77),
      ],
    ),
  ],
  waypoints: const [],
);

/// The highlight and the café are both drawn on the free-roam map, or neither.
void _expectLayers(WidgetTester tester, {required bool drawn}) {
  final matcher = drawn ? findsOneWidget : findsNothing;
  expect(
    find.byKey(const Key('free-roam-discovery-lines-layer')),
    matcher,
    reason: 'the discovery highlight',
  );
  expect(
    find.byKey(const Key('free-roam-biker-cafes-layer')),
    matcher,
    reason: 'the biker café',
  );
}

Future<Map<String, Object?>> _savedLayerChoices() async {
  final preferences = await SharedPreferences.getInstance();
  return {
    for (final key in preferences.getKeys().where(
      (key) => key.startsWith('map_layer_'),
    ))
      key: preferences.get(key),
  };
}

/// A free-roam map with a highlight and a café in view, that the test can flip
/// between browsing and navigating without remounting it.
Future<_Scene> _pumpScene(
  WidgetTester tester, {
  required bool rideStarted,
  bool? navigating,
  ImportedRoute? route,
}) async {
  final directory = Directory.systemTemp.createTempSync('discovery-fm');
  addTearDown(() => directory.deleteSync(recursive: true));
  final cache = OfflineTileCache(
    rootDirectory: directory,
    configuration: const BasemapConfiguration(),
    httpClient: MockClient((_) async => http.Response('', 404)),
  );
  addTearDown(cache.dispose);
  final position = ValueNotifier<GeoPoint?>(null);
  addTearDown(position.dispose);

  Widget build({required bool rideStarted, bool? navigating}) => MaterialApp(
    home: RideMapScreen(
      routeStore: InMemoryRouteStore(route),
      routeImporter: RouteImporter(source: const _NoFileSource()),
      offlineTileCache: cache,
      currentPosition: position,
      rideStarted: rideStarted,
      navigating: navigating,
      // Both loaders are supplied: they share one Future.wait with the layer
      // preferences, so an asset read that fails in a widget test takes the
      // café visibility down with it.
      discoveryCatalogueLoader: () async =>
          const MotorcycleDiscoveryCatalogue([_twisty]),
      bikerPlaceCatalogueLoader: () async => _cafes,
    ),
  );

  await tester.pumpWidget(build(rideStarted: rideStarted));
  await tester.pumpAndSettle();
  await tester.pump(const Duration(seconds: 1));
  await tester.pumpAndSettle();
  position.value = _position;
  await tester.pumpAndSettle();
  tester
      .widget<FlutterMap>(find.byType(FlutterMap).first)
      .mapController!
      .move(const LatLng(53.3, -1.8), 10.5);
  await tester.pumpAndSettle();
  return _Scene(tester, build);
}

class _Scene {
  _Scene(this.tester, this.build);

  final WidgetTester tester;
  final Widget Function({required bool rideStarted, bool? navigating}) build;

  Future<void> update({required bool rideStarted, bool? navigating}) async {
    await tester.pumpWidget(
      build(rideStarted: rideStarted, navigating: navigating),
    );
    // A map that is following a rider keeps animating, so settle by time.
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 2));
  }

  Future<void> finish() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 11));
    await tester.pump();
  }
}

class _NoFileSource implements GpxImportSource {
  const _NoFileSource();

  @override
  Future<PickedGpxFile?> pickGpxFile() async => null;
}
