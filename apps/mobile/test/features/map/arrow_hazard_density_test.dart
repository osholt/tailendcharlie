import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/domain/route_store.dart';
import 'package:ride_relay/features/map/hazard_map_symbol.dart';
import 'package:ride_relay/features/map/motorcycle_icon.dart';
import 'package:ride_relay/features/map/ride_map.dart';
import 'package:ride_relay/features/ride/previous_rides_screen.dart';
import 'package:ride_relay/services/basemap_configuration.dart';
import 'package:ride_relay/services/gpx_import_source.dart';
import 'package:ride_relay/services/map_style_repository.dart';
import 'package:ride_relay/services/offline_tile_cache.dart';
import 'package:ride_relay/services/route_importer.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'maplibre_recording_harness.dart';

/// #900: on Android the trail direction arrows and the hazard badges (the
/// cameras, the police sightings, the road defects and the one-tap alert) were a
/// third of the size iOS draws them at.
///
/// MapLibre draws an image `width / pixelRatio` logical pixels wide before
/// `icon-size` applies, and the plugin's Android build gives every image the
/// device's density as its pixel ratio (#843). The arrows' `icon-size` was a
/// constant of 0.15 and the badges' was `1 / hazardMapSymbolRasterScale`, both
/// right only where the ratio is one: on a three-pixel phone the arrows were
/// about seven logical pixels where iOS draws eighteen and the badges fourteen
/// where iOS draws forty-four. The arrows also had a two pixel `icon-halo` on an
/// image that is a plain mask, which is nothing at the right size and a solid
/// square behind each arrow at any other.
///
/// These tests read what the Dart side hands the plugin - each image's size and
/// each layer's `icon-size` - and check that, on every density, an image drawn at
/// the ratio the plugin applies comes out the size the same marker is on iOS.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/maplibre_gl_0'),
          (_) async => null,
        );
  });

  const densities = [1.0, 1.5, 2.0, 2.625, 3.0, 3.5, 4.0];

  group('the sizing rules', () {
    test('an arrow glyph is the size of the Icon flutter_map draws, on every '
        'density', () {
      for (final ratio in densities) {
        final size = iconGlyphIconSize(
          glyphSize: RouteTrailStyle.directionArrowSize,
          pixelRatio: ratio,
        );
        // What MapLibre does: `width / pixelRatio`, then `icon-size`; the glyph
        // is `iconGlyphFontShare` of the square it was rasterised into.
        final glyph = iconGlyphRasterSize * iconGlyphFontShare / ratio * size;
        expect(
          glyph,
          closeTo(RouteTrailStyle.directionArrowSize, 1e-9),
          reason: 'at $ratio pixels to a dp',
        );
      }
    });

    test('a hazard badge is the size of the Flutter one, on every density', () {
      for (final ratio in densities) {
        final size = hazardMapSymbolIconSize(pixelRatio: ratio);
        final badge =
            HazardMapSymbols.extentPixels *
            hazardMapSymbolRasterScale /
            ratio *
            size;
        expect(
          badge,
          closeTo(HazardMapSymbols.extentPixels, 1e-9),
          reason: 'at $ratio pixels to a dp',
        );
      }
    });

    test(
      'the old constants were a third of the size at three pixels to a dp',
      () {
        // The tuning these replace: 0.15 for the arrows, `1 / scale` for the
        // badges. Each was the iOS size where the ratio is about one.
        expect(
          iconGlyphRasterSize * iconGlyphFontShare / 3 * 0.15,
          lessThan(RouteTrailStyle.directionArrowSize / 2),
        );
        expect(
          HazardMapSymbols.extentPixels *
              hazardMapSymbolRasterScale /
              3 /
              hazardMapSymbolRasterScale,
          lessThan(HazardMapSymbols.extentPixels / 2),
        );
      },
    );
  });

  group('the arrows on iOS', () {
    testWidgets('are drawn at the size the native map is derived to', (
      tester,
    ) async {
      final directory = Directory.systemTemp.createTempSync('arrow-fm');
      addTearDown(() => directory.deleteSync(recursive: true));
      final cache = OfflineTileCache(
        rootDirectory: directory,
        configuration: const BasemapConfiguration(),
        httpClient: MockClient((_) async => http.Response('', 404)),
      );
      addTearDown(cache.dispose);
      final trails = ValueNotifier<List<MapOverlayTrace>>(const [
        MapOverlayTrace(
          id: 'trail-me',
          label: 'You trail',
          points: [
            GeoPoint(latitude: 53, longitude: -1.03),
            GeoPoint(latitude: 53.004, longitude: -1.024),
          ],
        ),
      ]);
      addTearDown(trails.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: RideMapScreen(
            routeStore: InMemoryRouteStore(),
            routeImporter: RouteImporter(source: const _NoFileSource()),
            offlineTileCache: cache,
            riderTrails: trails,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final arrows = find.descendant(
        of: find.byKey(const Key('trail-direction-arrow-layer')),
        matching: find.byIcon(Icons.navigation_rounded),
      );
      expect(arrows, findsWidgets);
      for (final icon in tester.widgetList<Icon>(arrows)) {
        expect(icon.size, RouteTrailStyle.directionArrowSize);
      }
    });
  });

  group('the arrows and the badges on the native map', () {
    for (final ratio in densities) {
      testWidgets('are the size iOS draws them at $ratio pixels to a dp', (
        tester,
      ) async {
        tester.view.devicePixelRatio = ratio;
        tester.view.physicalSize = Size(390 * ratio, 844 * ratio);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        // What iOS draws, measured: the ink of the Icon at its size.
        final flutterInk = await _inkOfIcon(tester);
        final directory = Directory.systemTemp.createTempSync('arrow-ml');
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
        try {
          final arrow = calls.layer('ride-relay-trail-direction-arrows');
          final casing = calls.layer('ride-relay-trail-direction-arrow-casing');
          num iconSize(Map<Object?, Object?> layer) =>
              (layer['properties'] as Map)['icon-size'] as num;
          final png =
              calls.images['ride-relay-trail-direction-arrow']!['bytes']
                  as Uint8List;
          final nativeInk = await tester.runAsync(() => _inkWidth(png));

          // What MapLibre draws: the image's width over the ratio, then icon-size.
          expect(
            nativeInk! / ratio * iconSize(arrow),
            closeTo(flutterInk, 0.4),
            reason: 'the arrow, in logical pixels, against the Icon on iOS',
          );
          // The edge: the same arrow, dark and larger, drawn first.
          expect(
            iconSize(casing),
            closeTo(
              iconSize(arrow) * RouteTrailStyle.directionArrowCasingScale,
              1e-9,
            ),
          );
          expect(
            iconSize(casing),
            greaterThan(iconSize(arrow) * 1.15),
            reason: 'an edge that is not wider than the arrow is no edge',
          );
          expect(
            (casing['properties'] as Map)['icon-color'],
            RouteTrailStyle.casingHex,
          );
          final order = calls.allLayerIds;
          expect(
            order.indexOf('ride-relay-trail-direction-arrow-casing'),
            lessThan(order.indexOf('ride-relay-trail-direction-arrows')),
            reason: 'the edge goes under the arrow',
          );
          // No halo on a plain mask: nothing at the right size, a solid square
          // behind the arrow at any other.
          for (final layer in [arrow, casing]) {
            expect(
              (layer['properties'] as Map).containsKey('icon-halo-width'),
              isFalse,
              reason: '${layer['layerId']}',
            );
          }

          // The badges - cameras, police, road defects and the one-tap alert -
          // are the size iOS draws them. Every one is baked at the same scale,
          // so each is the same number of pixels wide.
          final badgeSize =
              (calls.layer('ride-relay-hazard-symbols')['properties']
                      as Map)['icon-size']
                  as num;
          for (final symbol in HazardMapSymbols.catalogue) {
            final badge = calls.images[symbol.imageName]!['bytes'] as Uint8List;
            final width = ByteData.sublistView(badge, 16, 20).getUint32(0);
            expect(
              width / ratio * badgeSize,
              closeTo(HazardMapSymbols.extentPixels, 0.25),
              reason: '${symbol.imageName}, in logical pixels',
            );
          }
        } finally {
          await tester.pump(const Duration(seconds: 2));
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(seconds: 11));
          await tester.pump();
        }
      });
    }
  });

  group('the arrows on a recorded ride', () {
    for (final ratio in [1.0, 2.0, 3.0, 4.0]) {
      testWidgets('are the size of the live map\'s at $ratio pixels to a dp', (
        tester,
      ) async {
        tester.view.devicePixelRatio = ratio;
        tester.view.physicalSize = Size(390 * ratio, 844 * ratio);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final flutterInk = await _inkOfIcon(tester);
        final route = ImportedRoute(
          id: 'ridden',
          name: 'Recorded',
          importedAt: DateTime.utc(2026, 9, 20),
          sourceFileName: 'ride.gpx',
          waypoints: const [],
          paths: const [
            RoutePath(
              kind: RoutePathKind.track,
              points: [
                GeoPoint(latitude: 51.45, longitude: -2.59),
                GeoPoint(latitude: 51.46, longitude: -2.57),
              ],
            ),
          ],
        );
        final calls = await recordMapLibreStyleSetUp(
          tester,
          MaterialApp(
            home: Scaffold(
              body: ArchivedRideMap(
                plannedRoute: null,
                traveledRoute: route,
                mapStyleString: MapStyleRepository.fallbackStyle,
              ),
            ),
          ),
          until: (recorded) => recorded.any(
            (call) =>
                call.method == 'symbolLayer#add' &&
                (call.arguments as Map)['layerId'] ==
                    'archived-direction-arrows',
          ),
        );
        try {
          final arrow = calls.layer('archived-direction-arrows');
          final casing = calls.layer('archived-direction-arrow-casing');
          num iconSize(Map<Object?, Object?> layer) =>
              (layer['properties'] as Map)['icon-size'] as num;
          final png =
              calls.images['archived-direction-arrow']!['bytes'] as Uint8List;
          final nativeInk = await tester.runAsync(() => _inkWidth(png));

          expect(
            nativeInk! / ratio * iconSize(arrow),
            closeTo(flutterInk, 0.4),
            reason: 'the arrow, in logical pixels, against the Icon on iOS',
          );
          expect(
            iconSize(casing),
            greaterThan(iconSize(arrow) * 1.15),
            reason: 'the edge is a larger dark copy under the arrow',
          );
          final order = calls.allLayerIds;
          expect(
            order.indexOf('archived-direction-arrow-casing'),
            lessThan(order.indexOf('archived-direction-arrows')),
          );
          for (final layer in [arrow, casing]) {
            expect(
              (layer['properties'] as Map).containsKey('icon-halo-width'),
              isFalse,
              reason: '${layer['layerId']}',
            );
          }
        } finally {
          // The map's own timers (the initial fit) have to run out.
          await tester.pump(const Duration(seconds: 2));
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(seconds: 11));
          await tester.pump();
        }
      });
    }
  });
}

/// The width in logical pixels of the ink of the arrow `Icon` at the size iOS
/// draws it, measured from a render rather than read from a constant.
Future<double> _inkOfIcon(WidgetTester tester) async {
  final key = GlobalKey();
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: RepaintBoundary(
          key: key,
          child: const Icon(
            Icons.navigation_rounded,
            size: RouteTrailStyle.directionArrowSize,
            color: Color(0xFFFFFFFF),
          ),
        ),
      ),
    ),
  );
  const scale = 8.0;
  final ink = await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: scale);
    final png = (await image.toByteData(
      format: ui.ImageByteFormat.png,
    ))!.buffer.asUint8List();
    return _inkWidth(png);
  });
  await tester.pumpWidget(const SizedBox.shrink());
  return ink! / scale;
}

/// The width in pixels of everything drawn in a PNG.
Future<int> _inkWidth(Uint8List png) async {
  final image = await decodeImageFromList(png);
  final pixels = (await image.toByteData())!.buffer.asUint8List();
  var left = image.width;
  var right = -1;
  for (var y = 0; y < image.height; y += 1) {
    for (var x = 0; x < image.width; x += 1) {
      if (pixels[(y * image.width + x) * 4 + 3] == 0) continue;
      left = x < left ? x : left;
      right = x > right ? x : right;
    }
  }
  return right - left + 1;
}

class _NoFileSource implements GpxImportSource {
  const _NoFileSource();

  @override
  Future<PickedGpxFile?> pickGpxFile() async => null;
}
