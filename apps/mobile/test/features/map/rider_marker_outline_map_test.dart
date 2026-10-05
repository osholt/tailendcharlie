import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/domain/rider_color.dart';
import 'package:ride_relay/domain/rider_marker_outline.dart';
import 'package:ride_relay/domain/route_store.dart';
import 'package:ride_relay/features/map/motorcycle_icon.dart';
import 'package:ride_relay/features/map/ride_map.dart';
import 'package:ride_relay/features/map/ride_map_palette.dart';
import 'package:ride_relay/services/basemap_configuration.dart';
import 'package:ride_relay/services/gpx_import_source.dart';
import 'package:ride_relay/services/offline_tile_cache.dart';
import 'package:ride_relay/services/route_importer.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'maplibre_recording_harness.dart';

/// #845: the leader and the Tail End Charlie are stars on every map, and the
/// marker follows a change of role as it happens.
///
/// Each renderer gets its own test, because each draws the shape itself: the
/// flutter_map markers (iOS) and the group overview's painter paint it, and the
/// MapLibre layers (Android) are given an image per shape and choose between
/// them with an expression.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/maplibre_gl_0'),
          (_) async => null,
        );
  });

  final leadColour = RiderColor.orange.color;
  final tecColour = RiderColor.purple.color;
  final followerColour = RiderColor.blue.color;
  final localColour = RiderColor.pink.color;

  MapOverlayMarker rider(
    String id,
    Color colour,
    RiderMarkerOutline outline, {
    double latitude = 53.0004,
    double longitude = -1.0135,
  }) => MapOverlayMarker(
    id: 'rider-$id',
    point: GeoPoint(latitude: latitude, longitude: longitude),
    label: id,
    color: colour,
    // A rider always carries a style; without one the map falls back to the
    // generic hazard badge.
    motorcycleStyle: MotorcycleIconStyle.roadster,
    outline: outline,
  );

  group('the flutter_map markers (the main map on iOS)', () {
    testWidgets(
      'draw the leader and the Tail End Charlie as stars, and follow a '
      'handover as it happens',
      (tester) async {
        final directory = Directory.systemTemp.createTempSync('outline-fm');
        addTearDown(() => directory.deleteSync(recursive: true));
        final cache = OfflineTileCache(
          rootDirectory: directory,
          configuration: const BasemapConfiguration(),
          httpClient: MockClient((_) async => http.Response('', 404)),
        );
        addTearDown(cache.dispose);
        final overlays = ValueNotifier<List<MapOverlayMarker>>([
          rider(
            'lead',
            leadColour,
            RiderMarkerOutline.star,
            longitude: -1.0135,
          ),
          rider('tec', tecColour, RiderMarkerOutline.star, longitude: -1.0128),
          rider(
            'follower',
            followerColour,
            RiderMarkerOutline.circle,
            longitude: -1.0120,
          ),
        ]);
        addTearDown(overlays.dispose);
        final position = ValueNotifier<GeoPoint?>(
          const GeoPoint(latitude: 53, longitude: -1.015),
        );
        addTearDown(position.dispose);
        final localOutline = ValueNotifier(RiderMarkerOutline.star);
        addTearDown(localOutline.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: ValueListenableBuilder<RiderMarkerOutline>(
              valueListenable: localOutline,
              builder: (context, outline, _) => RideMapScreen(
                routeStore: InMemoryRouteStore(),
                routeImporter: RouteImporter(source: const _NoFileSource()),
                offlineTileCache: cache,
                currentPosition: position,
                overlayMarkers: overlays,
                groupRiderCount: 4,
                localBadgeColor: localColour,
                localMarkerOutline: outline,
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        try {
          RiderMarkerOutline drawn(Color fill) => [
            for (final paint in tester.widgetList<CustomPaint>(
              find.byType(CustomPaint),
            ))
              if (paint.painter case final RiderMarkerShapePainter painter)
                if (painter.color == fill) painter.outline,
          ].single;

          // A leader's phone: the leader and the TEC are stars, the follower is
          // not, and the rider's own marker is a star too.
          expect(drawn(leadColour), RiderMarkerOutline.star);
          expect(drawn(tecColour), RiderMarkerOutline.star);
          expect(drawn(followerColour), RiderMarkerOutline.circle);
          expect(drawn(localColour), RiderMarkerOutline.star);

          // Handover: the follower is now the leader and the old leader rides in
          // the group. Nothing else changes - not the colours, not the places.
          overlays.value = [
            rider(
              'lead',
              leadColour,
              RiderMarkerOutline.circle,
              longitude: -1.0135,
            ),
            rider(
              'tec',
              tecColour,
              RiderMarkerOutline.star,
              longitude: -1.0128,
            ),
            rider(
              'follower',
              followerColour,
              RiderMarkerOutline.star,
              longitude: -1.0120,
            ),
          ];
          localOutline.value = RiderMarkerOutline.circle;
          await tester.pump();

          expect(drawn(leadColour), RiderMarkerOutline.circle);
          expect(drawn(tecColour), RiderMarkerOutline.star);
          expect(drawn(followerColour), RiderMarkerOutline.star);
          expect(drawn(localColour), RiderMarkerOutline.circle);
        } finally {
          await tester.pump(const Duration(seconds: 2));
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(seconds: 11));
          await tester.pump();
        }
      },
    );
  });

  group('the map feature', () {
    testWidgets('hands this phone\'s marker shape on to the screen it builds', (
      tester,
    ) async {
      final directory = Directory.systemTemp.createTempSync('outline-feature');
      addTearDown(() => directory.deleteSync(recursive: true));
      final cache = OfflineTileCache(
        rootDirectory: directory,
        configuration: const BasemapConfiguration(),
        httpClient: MockClient((_) async => http.Response('', 404)),
      );
      addTearDown(cache.dispose);

      Future<RiderMarkerOutline> outlineWhenGiven(
        RiderMarkerOutline outline,
      ) async {
        await tester.pumpWidget(
          MaterialApp(
            home: RideMapFeature(
              routeStore: InMemoryRouteStore(),
              offlineTileCache: cache,
              mapStyleString:
                  '{"version":8,"sources":{},"layers":[{"id":"background","type":"background"}]}',
              localMarkerOutline: outline,
            ),
          ),
        );
        await tester.pump();
        for (var frame = 0; frame < 5; frame += 1) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        final screen = tester.widget<RideMapScreen>(find.byType(RideMapScreen));
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        return screen.localMarkerOutline;
      }

      expect(
        await outlineWhenGiven(RiderMarkerOutline.star),
        RiderMarkerOutline.star,
      );
      expect(
        await outlineWhenGiven(RiderMarkerOutline.circle),
        RiderMarkerOutline.circle,
      );
    });
  });

  group('the group overview', () {
    const local = GeoPoint(latitude: 53, longitude: -1.01);

    List<GroupMiniMapMarker> markers({
      required List<MapOverlayMarker> riders,
      RiderMarkerOutline localOutline = RiderMarkerOutline.circle,
    }) => groupMiniMapMarkers(
      riders: riders,
      localPosition: local,
      localColor: localColour,
      localOutline: localOutline,
      localSymbol: riderSymbolDefault,
      localDisplayName: 'You',
      localMotorcycleStyle: motorcycleIconStyleDefault,
    );

    test('hands every renderer the shape each rider is drawn in', () {
      final overview = markers(
        riders: [
          rider('lead', leadColour, RiderMarkerOutline.star),
          rider('follower', followerColour, RiderMarkerOutline.circle),
        ],
        localOutline: RiderMarkerOutline.star,
      );

      expect(overview.map((marker) => marker.outline), [
        RiderMarkerOutline.star,
        RiderMarkerOutline.circle,
        RiderMarkerOutline.star,
      ]);
      // And the edge colour is still its own thing: a star is outlined in the
      // same dark casing, the local rider's in white (#844).
      expect(overview.map((marker) => marker.outlineColor), [
        RideMapPalette.otherRiderOutline,
        RideMapPalette.otherRiderOutline,
        RideMapPalette.localRiderOutline,
      ]);
    });

    test('the iOS overview draws each rider\'s badge in that shape, in the '
        'colours the main map uses', () {
      final overview = markers(
        riders: [
          rider('lead', leadColour, RiderMarkerOutline.star),
          rider('follower', followerColour, RiderMarkerOutline.circle),
        ],
        localOutline: RiderMarkerOutline.star,
      );

      final badges = [
        for (final marker in overview)
          groupMiniMapVectorMarker(marker).child as RiderMarkerBadge,
      ];

      expect(badges.map((badge) => badge.outline), [
        RiderMarkerOutline.star,
        RiderMarkerOutline.circle,
        RiderMarkerOutline.star,
      ]);
      expect(
        badges.map((badge) => badge.badgeColor),
        overview.map((marker) => marker.fill),
      );
      expect(
        badges.map((badge) => badge.borderColor),
        overview.map((marker) => marker.outlineColor),
      );
    });

    test('a rider is a circle unless told otherwise', () {
      expect(
        markers(
          riders: [
            rider('follower', followerColour, RiderMarkerOutline.circle),
          ],
        ).map((marker) => marker.outline),
        everyElement(RiderMarkerOutline.circle),
      );
    });

    testWidgets('paints the leader as a star and the follower as a circle', (
      tester,
    ) async {
      final directory = Directory.systemTemp.createTempSync('outline-mini');
      addTearDown(() => directory.deleteSync(recursive: true));
      final cache = OfflineTileCache(
        rootDirectory: directory,
        configuration: const BasemapConfiguration(),
        httpClient: MockClient((_) async => http.Response('', 404)),
      );
      addTearDown(cache.dispose);
      final overlays = ValueNotifier<List<MapOverlayMarker>>([
        rider('lead', leadColour, RiderMarkerOutline.star, longitude: -1.0135),
        rider(
          'follower',
          followerColour,
          RiderMarkerOutline.circle,
          longitude: -1.0120,
        ),
      ]);
      addTearDown(overlays.dispose);
      final position = ValueNotifier<GeoPoint?>(
        const GeoPoint(latitude: 53, longitude: -1.015),
      );
      addTearDown(position.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: RideMapScreen(
            routeStore: InMemoryRouteStore(),
            routeImporter: RouteImporter(source: const _NoFileSource()),
            offlineTileCache: cache,
            currentPosition: position,
            overlayMarkers: overlays,
            groupRiderCount: 3,
            localBadgeColor: localColour,
            localMarkerOutline: RiderMarkerOutline.star,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      try {
        final overview = tester.renderObject<RenderBox>(
          find.byKey(const Key('group-mini-map-local-fallback')),
        );
        final canvas = TestRecordingCanvas();
        overview.paint(TestRecordingPaintingContext(canvas), Offset.zero);
        // Keyed by the 32-bit colour: the engine keeps floats, and a colour read back
        // from a paint is not `==` to the one it was made from.
        final fills = <int, Path>{
          for (final invocation in canvas.invocations)
            if (invocation.invocation.memberName == #drawPath)
              if (invocation.invocation.positionalArguments case [
                final Path path,
                final Paint paint,
              ])
                if (paint.style == PaintingStyle.fill)
                  paint.color.toARGB32(): path,
        };

        // A valley of the star is closer to its centre than the circle's edge,
        // so a probe between the points is inside a circle and outside a star.
        bool isStar(Color fill) {
          final path = fills[fill.toARGB32()]!;
          final box = path.getBounds();
          final radius = box.width / 2;
          // The five valleys of a star with one point up, at 36 degrees from the
          // points; the probe sits at 0.9 of the circle's radius.
          final probe =
              box.center +
              Offset.fromDirection((36 - 90) * 3.141592653589793 / 180) *
                  radius *
                  0.9;
          return !path.contains(probe);
        }

        expect(
          fills.keys,
          containsAll([leadColour.toARGB32(), followerColour.toARGB32()]),
        );
        expect(isStar(leadColour), isTrue, reason: 'the leader is a star');
        expect(
          isStar(followerColour),
          isFalse,
          reason: 'the follower is a circle',
        );
        expect(isStar(localColour), isTrue, reason: 'the local rider leads');
      } finally {
        await tester.pump(const Duration(seconds: 2));
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 11));
        await tester.pump();
      }
    });
  });

  group('the MapLibre layers (the main map on Android)', () {
    /// Mounts the map with [overlays] and a local rider drawn as [local], on a
    /// screen of [ratio] pixels to a dp. The marker rasters are cached for the
    /// whole run, and one built in an earlier test's fake clock never resolves
    /// in this one, so each test names a ratio no other test in the file uses.
    Future<void> withMap(
      WidgetTester tester, {
      required double ratio,
      required ValueNotifier<List<MapOverlayMarker>> overlays,
      required RiderMarkerOutline local,
      required Future<void> Function(
        List<MethodCall> calls,
        ValueNotifier<RiderMarkerOutline> localOutline,
      )
      check,
    }) async {
      tester.view.devicePixelRatio = ratio;
      tester.view.physicalSize = Size(390 * ratio, 844 * ratio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final directory = Directory.systemTemp.createTempSync('outline-ml');
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
      addTearDown(overlays.dispose);
      final localOutline = ValueNotifier(local);
      addTearDown(localOutline.dispose);
      final position = ValueNotifier<GeoPoint?>(
        const GeoPoint(latitude: 53, longitude: -1.015),
      );
      addTearDown(position.dispose);
      final calls = await recordMapLibreStyleSetUp(
        tester,
        MaterialApp(
          home: ValueListenableBuilder<RiderMarkerOutline>(
            valueListenable: localOutline,
            builder: (context, outline, _) => RideMapScreen(
              routeStore: InMemoryRouteStore(),
              routeImporter: RouteImporter(source: const _NoFileSource()),
              offlineTileCache: cache,
              currentPosition: position,
              overlayMarkers: overlays,
              localBadgeColor: localColour,
              localMarkerOutline: outline,
            ),
          ),
        ),
      );
      try {
        await check(calls, localOutline);
      } finally {
        await tester.pump(const Duration(seconds: 2));
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 11));
        await tester.pump();
      }
    }

    /// The features last written to [sourceId], by id.
    Map<String, Map<Object?, Object?>> features(
      List<MethodCall> calls,
      String sourceId,
    ) {
      final json =
          jsonDecode(
                [
                      for (final call in calls)
                        if ((call.method == 'source#addGeoJson' ||
                                call.method == 'source#setGeoJson') &&
                            (call.arguments as Map)['sourceId'] == sourceId)
                          call,
                    ].last.arguments['geojson']
                    as String,
              )
              as Map;
      return {
        for (final feature in json['features'] as List)
          ((feature as Map)['id'] ?? (feature['properties'] as Map)['id'])
                  as String:
              feature['properties'] as Map<Object?, Object?>,
      };
    }

    List<String> outlinesOf(Map<String, Map<Object?, Object?>> features) => [
      for (final entry in features.entries)
        '${entry.key}:${entry.value['outline']}',
    ];

    testWidgets('are given a star for the leader and the Tail End Charlie and '
        'a circle for everyone else', (tester) async {
      await withMap(
        tester,
        ratio: 2.1,
        overlays: ValueNotifier([
          rider('lead', leadColour, RiderMarkerOutline.star),
          rider('tec', tecColour, RiderMarkerOutline.star),
          rider('follower', followerColour, RiderMarkerOutline.circle),
        ]),
        local: RiderMarkerOutline.star,
        check: (calls, _) async {
          final overlay = features(calls, 'ride-relay-overlays');
          expect(
            overlay.keys,
            containsAll(['rider-lead', 'rider-tec', 'rider-follower']),
          );
          expect(overlay['rider-lead']!['outline'], 'star');
          expect(overlay['rider-tec']!['outline'], 'star');
          expect(overlay['rider-follower']!['outline'], 'circle');
          expect(
            features(calls, 'ride-relay-position').values.single['outline'],
            'star',
            reason: 'the local rider leads',
          );
          expect(outlinesOf(overlay), hasLength(3));

          // Every one of the four shapes is an image the layers can ask for,
          // registered by the time a star is on the map.
          final images = calls.images;
          for (final directional in [false, true]) {
            for (final outline in RiderMarkerOutline.values) {
              expect(
                images,
                contains(
                  riderMarkerShapeImageName(
                    outline: outline,
                    directional: directional,
                  ),
                ),
              );
            }
          }
          // The badge layers choose among them by the feature's own property.
          for (final layer in [
            'ride-relay-overlay-badges',
            'ride-relay-position-badge',
          ]) {
            expect(
              (calls.layer(layer)['properties'] as Map)['icon-image'],
              riderShapeImageExpression,
              reason: layer,
            );
          }
        },
      );
    });

    testWidgets('are not given the star images when nobody is one', (
      tester,
    ) async {
      // Each star is a distance field that takes a frame or two to rasterise,
      // so a ride of circles never pays for them.
      await withMap(
        tester,
        ratio: 2.2,
        overlays: ValueNotifier([
          rider('follower', followerColour, RiderMarkerOutline.circle),
        ]),
        local: RiderMarkerOutline.circle,
        check: (calls, _) async {
          expect(calls.images, contains(riderDirectionShapeImage));
          expect(calls.images, contains(riderUnknownShapeImage));
          expect(calls.images, isNot(contains(riderStarDirectionShapeImage)));
          expect(calls.images, isNot(contains(riderStarUnknownShapeImage)));
          expect(
            features(
              calls,
              'ride-relay-overlays',
            )['rider-follower']!['outline'],
            'circle',
          );
        },
      );
    });

    testWidgets('follow a handover: the new leader gets the star images and '
        'the shape of the marker changes without anyone moving', (
      tester,
    ) async {
      final overlays = ValueNotifier([
        rider('lead', leadColour, RiderMarkerOutline.circle),
        rider('follower', followerColour, RiderMarkerOutline.circle),
      ]);
      await withMap(
        tester,
        ratio: 2.3,
        overlays: overlays,
        local: RiderMarkerOutline.circle,
        check: (calls, localOutline) async {
          expect(calls.images, isNot(contains(riderStarDirectionShapeImage)));
          expect(
            features(calls, 'ride-relay-position').values.single['outline'],
            'circle',
          );

          // The local rider is handed the lead, standing still.
          localOutline.value = RiderMarkerOutline.star;
          overlays.value = [
            rider('lead', leadColour, RiderMarkerOutline.circle),
            rider('follower', followerColour, RiderMarkerOutline.star),
          ];
          for (var i = 0; i < 40; i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 25)),
            );
            await tester.pump(const Duration(milliseconds: 25));
            if (features(
                  calls,
                  'ride-relay-position',
                ).values.single['outline'] ==
                'star') {
              break;
            }
          }

          expect(
            features(calls, 'ride-relay-position').values.single['outline'],
            'star',
            reason: 'the position source is rewritten for a change of role',
          );
          expect(
            features(
              calls,
              'ride-relay-overlays',
            )['rider-follower']!['outline'],
            'star',
          );
          expect(
            features(calls, 'ride-relay-overlays')['rider-lead']!['outline'],
            'circle',
          );
          expect(calls.images, contains(riderStarDirectionShapeImage));
          expect(calls.images, contains(riderStarUnknownShapeImage));
        },
      );
    });
  });
}

class _NoFileSource implements GpxImportSource {
  const _NoFileSource();

  @override
  Future<PickedGpxFile?> pickGpxFile() async => null;
}
