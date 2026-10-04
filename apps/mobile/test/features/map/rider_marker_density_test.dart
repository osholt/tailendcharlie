import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/domain/route_store.dart';
import 'package:ride_relay/features/map/motorcycle_icon.dart';
import 'package:ride_relay/features/map/ride_map.dart';
import 'package:ride_relay/services/basemap_configuration.dart';
import 'package:ride_relay/services/gpx_import_source.dart';
import 'package:ride_relay/services/offline_tile_cache.dart';
import 'package:ride_relay/services/route_importer.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'maplibre_recording_harness.dart';

/// #843: on Android other riders were small black bike glyphs with no coloured
/// disc, at about half the size of the same marker on iOS.
///
/// MapLibre draws an image `width / pixelRatio` logical pixels wide, and the
/// plugin's Android build gives every image the device's density as its pixel
/// ratio (`inDensity = 0` leaves the bitmap at the device default, which is not
/// one to one). The disc was rasterised as if the ratio were one, so it came out
/// `1 / density` of its size, and the glyph's size was a constant that happened to
/// suit the phone it was tuned on - so the glyph swallowed the disc.
///
/// These tests read what the Dart side hands the plugin - each image's size and
/// each layer's `icon-size` - and check that, on every density, an image drawn at
/// the ratio the plugin applies comes out at the logical size the marker has on
/// iOS.
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
    test('a bike glyph is the same share of its badge on every density', () {
      for (final ratio in densities) {
        for (final badge in [14.0, 34.0, 38.0]) {
          final logicalWidth =
              riderGlyphRasterWidth *
              riderGlyphIconSize(badgeDiameter: badge, pixelRatio: ratio) /
              ratio;

          expect(
            logicalWidth,
            closeTo(badge * riderGlyphBoxFill, 0.001),
            reason: 'a $badge badge at $ratio pixels to a dp',
          );
        }
      }
    });

    test('initials fill the badge on every density', () {
      for (final ratio in densities) {
        final logicalSide =
            riderSymbolRasterSize *
            riderInitialsIconSize(badgeDiameter: 34, pixelRatio: ratio) /
            ratio;

        expect(
          logicalSide,
          closeTo(34, 0.001),
          reason: '$ratio pixels to a dp',
        );
      }
    });

    test('an outline is never wider than the distance field can hold', () {
      for (final badge in [14.0, 34.0, 38.0]) {
        final iconSize = badge / riderMarkerShapeUnits;
        for (final requested in [0.5, 1.0, 2.0, 3.0]) {
          final halo = riderBadgeHaloWidth(
            badgeDiameter: badge,
            requested: requested,
          );

          expect(halo, lessThanOrEqualTo(requested));
          expect(
            halo / iconSize,
            lessThanOrEqualTo(riderBadgeSdfHaloLimit + 1e-9),
            reason:
                'a $requested px outline on a $badge badge would overflow the '
                'six units of distance the shape encodes',
          );
        }
      }
      // What is asked for is given while it fits.
      expect(riderBadgeHaloWidth(badgeDiameter: 34, requested: 0.5), 0.5);
    });

    test(
      'an emoji raster is painted at the font size the Flutter badge gives it',
      () async {
        final raster = await rasterizeRiderSymbolPng(
          symbol: const RiderSymbol.emoji('🔥'),
          displayName: 'Blake',
          motorcycleStyle: motorcycleIconStyleDefault,
        );

        // The same emoji painted straight at the font size `RiderMarkerBadge`
        // gives it, as a share of a 128 unit badge.
        final recorder = ui.PictureRecorder();
        TextPainter(
            textDirection: TextDirection.ltr,
            text: TextSpan(
              text: '🔥',
              style: TextStyle(
                fontSize: riderSymbolRasterSize * riderEmojiFontFill,
                height: 1,
              ),
            ),
          )
          ..layout()
          ..paint(Canvas(recorder), Offset.zero);
        final reference = await (await recorder.endRecording().toImage(
          riderSymbolRasterSize.round(),
          riderSymbolRasterSize.round(),
        )).toByteData(format: ui.ImageByteFormat.png);

        expect(
          await _inkWidth(raster.bytes),
          closeTo(await _inkWidth(reference!.buffer.asUint8List()), 2),
          reason: 'it used to be painted at 0.72 of the raster, 30% too large',
        );
      },
    );
  });

  group('the marker the native map is given', () {
    for (final ratio in [1.0, 2.0, 2.625, 3.0, 3.5]) {
      testWidgets('is the size of the iOS marker at $ratio pixels to a dp', (
        tester,
      ) async {
        tester.view.devicePixelRatio = ratio;
        tester.view.physicalSize = Size(390 * ratio, 844 * ratio);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final directory = Directory.systemTemp.createTempSync('density');
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
        final overlays = ValueNotifier<List<MapOverlayMarker>>(const [
          MapOverlayMarker(
            id: 'rider-bike',
            point: GeoPoint(latitude: 53.001, longitude: -1.011),
            label: 'Blake',
            motorcycleStyle: MotorcycleIconStyle.adventureTourer,
          ),
          MapOverlayMarker(
            id: 'rider-initials',
            point: GeoPoint(latitude: 53.002, longitude: -1.012),
            label: 'Maya',
            motorcycleStyle: MotorcycleIconStyle.roadster,
            riderSymbol: RiderSymbol.initials(),
          ),
          MapOverlayMarker(
            id: 'rider-emoji',
            point: GeoPoint(latitude: 53.003, longitude: -1.013),
            label: 'Ravi',
            motorcycleStyle: MotorcycleIconStyle.roadster,
            riderSymbol: RiderSymbol.emoji('🔥'),
          ),
        ]);
        addTearDown(overlays.dispose);

        final calls = await recordMapLibreStyleSetUp(
          tester,
          MaterialApp(
            home: RideMapScreen(
              routeStore: InMemoryRouteStore(),
              routeImporter: RouteImporter(source: const _NoFileSource()),
              offlineTileCache: cache,
              overlayMarkers: overlays,
            ),
          ),
        );
        try {
          // What MapLibre does with an image: `width / pixelRatio` logical
          // pixels, then `icon-size`. The plugin's pixel ratio on Android is the
          // device's, which is what `devicePixelRatio` is here.
          double drawn(String image, num iconSize) =>
              _pngWidth(calls.images[image]!['bytes'] as Uint8List) /
              ratio *
              iconSize;
          Map<Object?, Object?> properties(String layer) =>
              calls.layer(layer)['properties'] as Map<Object?, Object?>;
          List<Object?> expression(String layer) =>
              properties(layer)['icon-size'] as List<Object?>;

          // The disc: a 144 unit raster of a 128 unit shape, so a 34 box.
          const box = 34.0;
          final disc = properties('ride-relay-overlay-badges')['icon-size'];
          for (final name in [
            riderDirectionShapeImage,
            riderUnknownShapeImage,
          ]) {
            expect(
              drawn(name, disc as num),
              closeTo(box * 144 / 128, 0.25),
              reason: '$name is the badge, in logical pixels',
            );
          }

          // The bike: the share of the badge the Flutter glyph is.
          final glyphSize = expression('ride-relay-overlay-icons').last as num;
          expect(
            drawn(MotorcycleIconStyle.adventureTourer.name, glyphSize),
            closeTo(box * riderGlyphBoxFill, 0.25),
            reason: 'the bike glyph',
          );

          // Initials and an emoji: a square raster mapped onto the badge.
          final squareSize = expression('ride-relay-overlay-icons')[2] as num;
          final initialsImage = calls.images.keys.singleWhere(
            (name) => name.startsWith('rider-symbol-initials-'),
          );
          final emojiImage = calls.images.keys.singleWhere(
            (name) => name.startsWith('rider-symbol-emoji-'),
          );
          for (final name in [initialsImage, emojiImage]) {
            expect(
              drawn(name, squareSize),
              closeTo(box, 0.25),
              reason: '$name fills the badge',
            );
          }

          // The local rider is the larger 38 box, on the same rules.
          const localBox = 38.0;
          expect(
            drawn(
              riderUnknownShapeImage,
              properties('ride-relay-position-badge')['icon-size'] as num,
            ),
            closeTo(localBox * 144 / 128, 0.25),
          );
          expect(
            drawn(
              MotorcycleIconStyle.adventureTourer.name,
              properties('ride-relay-position-icon')['icon-size'] as num,
            ),
            closeTo(localBox * riderGlyphBoxFill, 0.25),
          );

          // The outline: a halo wider than the shape's distance field holds is no
          // longer an outline but a solid square behind the marker.
          for (final layer in [
            'ride-relay-overlay-badges',
            'ride-relay-position-badge',
          ]) {
            final halo = properties(layer)['icon-halo-width'] as num;
            final size = properties(layer)['icon-size'] as num;
            expect(halo, greaterThan(0), reason: '$layer keeps an outline');
            expect(
              halo / size,
              lessThanOrEqualTo(riderBadgeSdfHaloLimit + 1e-9),
              reason: '$layer must not fill its whole image',
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

/// The width in pixels from a PNG's IHDR chunk.
int _pngWidth(Uint8List bytes) =>
    ByteData.sublistView(bytes, 16, 20).getUint32(0);

class _NoFileSource implements GpxImportSource {
  const _NoFileSource();

  @override
  Future<PickedGpxFile?> pickGpxFile() async => null;
}
