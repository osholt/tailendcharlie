import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/domain/rider_color.dart';
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

/// #844: the main map and the group overview drew the same riders in different
/// colours - the overview painted the local rider orange whatever colour they
/// had chosen and outlined everyone in white where the main map used a dark
/// edge - so a rider could not match a marker on one map to the other. Both now
/// take their colours from [RideMapPalette].
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/maplibre_gl_0'),
          (_) async => null,
        );
  });

  group('the palette', () {
    test(
      'a marker is filled with the rider\'s own colour, whatever their role',
      () {
        for (final colour in RiderColor.values) {
          expect(RideMapPalette.riderFill(colour.color), colour.color);
        }
      },
    );

    test(
      'other riders get the dark casing and the local rider a white edge',
      () {
        expect(
          RideMapPalette.riderOutline(local: false),
          RouteTrailStyle.casing,
        );
        expect(
          RideMapPalette.riderOutline(local: true),
          const Color(0xFFFFFFFF),
        );
      },
    );

    test('the MapLibre paint strings name the same colours', () {
      String hex(Color colour) =>
          '#${colour.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}'
              .toUpperCase();

      expect(
        RideMapPalette.otherRiderOutlineHex.toUpperCase(),
        hex(RideMapPalette.otherRiderOutline),
      );
      expect(
        RideMapPalette.localRiderOutlineHex.toUpperCase(),
        hex(RideMapPalette.localRiderOutline),
      );
    });

    test(
      'every line has a main-map style, and the overview shares its colour',
      () {
        for (final line in RideMapLine.values) {
          expect(
            RideMapPalette.lineStyle(line),
            isNotNull,
            reason: '$line must be drawable on the main map',
          );
          final overview = RideMapPalette.lineStyle(line, overview: true);
          if (overview == null) continue;
          expect(
            overview.color,
            RideMapPalette.lineStyle(line)!.color,
            reason:
                '$line is drawn on both maps, so a rider looks for the same '
                'colour on each',
          );
        }
      },
    );

    test('the overview draws the route ahead and the leader\'s trail only', () {
      expect(
        [
          for (final line in RideMapLine.values)
            if (RideMapPalette.lineStyle(line, overview: true) != null) line,
        ],
        [RideMapLine.remainingRoute, RideMapLine.leaderTrail],
      );
    });

    test('every trail kind resolves to the style the trail itself reports', () {
      for (final kind in RiderTrailKind.values) {
        expect(
          MapOverlayTrace(
            id: 'x',
            label: 'x',
            points: const [],
            kind: kind,
          ).style.color,
          RouteTrailStyle.forTrail(kind).color,
        );
      }
    });
  });

  group('the group overview\'s markers', () {
    const local = GeoPoint(latitude: 53, longitude: -1.01);

    List<GroupMiniMapMarker> markersFor({
      required List<MapOverlayMarker> riders,
      required Color localColour,
    }) => groupMiniMapMarkers(
      riders: riders,
      localPosition: local,
      localColor: localColour,
      localSymbol: riderSymbolDefault,
      localDisplayName: 'You',
      localMotorcycleStyle: motorcycleIconStyleDefault,
    );

    test('another rider is drawn in the colour the main map draws them in', () {
      for (final colour in RiderColor.values) {
        final markers = markersFor(
          riders: [
            MapOverlayMarker(
              id: 'rider-blake',
              point: const GeoPoint(latitude: 53.001, longitude: -1.011),
              label: 'Blake',
              color: colour.color,
            ),
          ],
          localColour: const Color(0xFF000001),
        );

        expect(markers.first.fill, colour.color, reason: colour.label);
        expect(markers.first.outline, RouteTrailStyle.casing);
      }
    });

    test('the local rider is drawn in their own colour, not a fixed one', () {
      for (final colour in RiderColor.values) {
        final marker = markersFor(
          riders: const [],
          localColour: colour.color,
        ).single;

        expect(marker.isLocal, isTrue);
        expect(marker.fill, colour.color, reason: colour.label);
        expect(marker.outline, const Color(0xFFFFFFFF));
      }
    });

    test('other riders come first and the local rider is on top', () {
      final markers = markersFor(
        riders: const [
          MapOverlayMarker(
            id: 'rider-a',
            point: GeoPoint(latitude: 53.001, longitude: -1.011),
            label: 'A',
          ),
          MapOverlayMarker(
            id: 'rider-b',
            point: GeoPoint(latitude: 53.002, longitude: -1.012),
            label: 'B',
          ),
        ],
        localColour: RiderColor.pink.color,
      );

      expect(markers.map((marker) => marker.id), [
        'rider-a',
        'rider-b',
        'mini-local-rider',
      ]);
    });

    test('no position, no local marker', () {
      expect(
        groupMiniMapMarkers(
          riders: const [],
          localPosition: null,
          localColor: RiderColor.pink.color,
          localSymbol: riderSymbolDefault,
          localDisplayName: 'You',
          localMotorcycleStyle: motorcycleIconStyleDefault,
        ),
        isEmpty,
      );
    });
  });

  group('the same riders on both maps', () {
    const remoteColour = Color(0xFF123456);
    final localColour = RiderColor.pink.color;

    testWidgets('flutter_map (the main map on iOS) and the overview paint the '
        'same fills and the same outlines', (tester) async {
      final directory = Directory.systemTemp.createTempSync('palette-fm');
      addTearDown(() => directory.deleteSync(recursive: true));
      final cache = OfflineTileCache(
        rootDirectory: directory,
        configuration: const BasemapConfiguration(),
        httpClient: MockClient((_) async => http.Response('', 404)),
      );
      addTearDown(cache.dispose);
      final overlays = ValueNotifier<List<MapOverlayMarker>>(const [
        MapOverlayMarker(
          id: 'rider-blake',
          point: GeoPoint(latitude: 53.0004, longitude: -1.0135),
          label: 'Blake',
          color: remoteColour,
          // A rider always carries a style; without one the map falls back to
          // the generic hazard badge.
          motorcycleStyle: MotorcycleIconStyle.roadster,
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
            groupRiderCount: 2,
            localBadgeColor: localColour,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      try {
        // The main map: every marker is a RiderMarkerBadge painting a shape.
        final painters = [
          for (final paint in tester.widgetList<CustomPaint>(
            find.byType(CustomPaint),
          ))
            if (paint.painter case final RiderMarkerShapePainter painter)
              painter,
        ];
        RiderMarkerShapePainter main(Color fill) =>
            painters.singleWhere((painter) => painter.color == fill);
        expect(main(remoteColour).borderColor, RouteTrailStyle.casing);
        expect(main(localColour).borderColor, const Color(0xFFFFFFFF));

        // The overview, drawn by its local painter, takes the same two riders
        // in the same two colours with the same two outlines.
        expect(
          tester.renderObject(
            find.byKey(const Key('group-mini-map-local-fallback')),
          ),
          paints
            ..path(color: remoteColour)
            ..path(color: RouteTrailStyle.casing, style: PaintingStyle.stroke)
            ..path(color: localColour)
            ..path(color: const Color(0xFFFFFFFF), style: PaintingStyle.stroke),
        );

        // And the legend names the local rider's colour, not a fixed orange.
        final legend = tester.widget<DecoratedBox>(
          find.descendant(
            of: find.byKey(const Key('mini-map-you-legend')),
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is DecoratedBox &&
                  (widget.decoration is BoxDecoration) &&
                  (widget.decoration as BoxDecoration).shape == BoxShape.circle,
            ),
          ),
        );
        expect((legend.decoration as BoxDecoration).color, localColour);
      } finally {
        await tester.pump(const Duration(seconds: 2));
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 11));
        await tester.pump();
      }
    });

    testWidgets('MapLibre (the main map on Android) draws the same colours', (
      tester,
    ) async {
      final directory = Directory.systemTemp.createTempSync('palette-ml');
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
          id: 'rider-blake',
          point: GeoPoint(latitude: 53.0004, longitude: -1.0135),
          label: 'Blake',
          color: remoteColour,
          motorcycleStyle: MotorcycleIconStyle.roadster,
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
            localBadgeColor: localColour,
          ),
        ),
      );
      try {
        Map<Object?, Object?> properties(String layerId) =>
            calls.layer(layerId)['properties'] as Map<Object?, Object?>;
        String hex(Color colour) =>
            '#${colour.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}';

        // Another rider: the colour is data on the feature, the edge is the dark
        // casing.
        expect(
          properties('ride-relay-overlay-badges')['icon-halo-color'],
          RideMapPalette.otherRiderOutlineHex,
        );
        // The local rider: their own colour, and the white edge the other
        // renderers give them.
        expect(
          properties('ride-relay-position-badge')['icon-color'],
          hex(localColour),
        );
        expect(
          properties('ride-relay-position-badge')['icon-halo-color'],
          RideMapPalette.localRiderOutlineHex,
        );

        final overlayJson =
            jsonDecode(
                  [
                        for (final call in calls)
                          if ((call.method == 'source#addGeoJson' ||
                                  call.method == 'source#setGeoJson') &&
                              (call.arguments as Map)['sourceId'] ==
                                  'ride-relay-overlays')
                            call,
                      ].last.arguments['geojson']
                      as String,
                )
                as Map;
        final feature = (overlayJson['features'] as List).single as Map;
        expect(
          (feature['properties'] as Map)['color'],
          hex(remoteColour),
          reason: 'the feature carries the rider\'s own colour',
        );
      } finally {
        await tester.pump(const Duration(seconds: 2));
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 11));
        await tester.pump();
      }
    });
  });
}

class _NoFileSource implements GpxImportSource {
  const _NoFileSource();

  @override
  Future<PickedGpxFile?> pickGpxFile() async => null;
}
