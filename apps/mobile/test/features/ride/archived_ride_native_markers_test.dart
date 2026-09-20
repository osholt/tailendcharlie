import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as ml;
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/features/ride/previous_rides_screen.dart';
import 'package:ride_relay/services/map_style_repository.dart';

void main() {
  testWidgets(
    'endpoints are geographic native layers throughout camera movement',
    (tester) async {
      final original = ml.MapLibrePlatform.createInstance;
      final calls = <MethodCall>[];
      const channel = MethodChannel('plugins.flutter.io/maplibre_gl_0');
      const views = MethodChannel('flutter/platform_views');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(views, (call) async {
            if (call.method == 'create') return 0;
            if (call.method == 'resize') {
              final args = call.arguments as Map;
              return {'width': args['width'], 'height': args['height']};
            }
            return null;
          });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return null;
          });
      ml.MapLibrePlatform.createInstance = () {
        final platform = ml.MapLibreMethodChannel();
        unawaited(platform.initPlatform(0));
        return platform;
      };
      addTearDown(() {
        ml.MapLibrePlatform.createInstance = original;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(views, null);
      });
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
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ArchivedRideMap(
              plannedRoute: null,
              traveledRoute: route,
              mapStyleString: MapStyleRepository.fallbackStyle,
            ),
          ),
        ),
      );
      await tester.pump();
      final map = tester.widget<ml.MapLibreMap>(find.byType(ml.MapLibreMap));
      final platform = ml.MapLibreMethodChannel();
      await platform.initPlatform(0);
      final controller = ml.MapLibreMapController(
        maplibrePlatform: platform,
        annotationOrder: const [],
        annotationConsumeTapEvents: const [],
      );
      map.onMapCreated!(controller);
      map.onStyleLoadedCallback!();
      // Native rasterisation runs on the engine; let it finish before testing
      // the camera callbacks, then drain the existing initial-fit timer.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 350)),
      );
      await tester.pump(const Duration(seconds: 1));
      final sourceCall = calls.singleWhere(
        (c) =>
            c.method == 'source#addGeoJson' &&
            (c.arguments as Map)['sourceId'] == 'archived-endpoint-source',
      );
      final features =
          (jsonDecode((sourceCall.arguments as Map)['geojson'] as String)
                  as Map)['features']
              as List;
      expect((features.first['geometry'] as Map)['coordinates'], [
        -2.59,
        51.45,
      ]);
      expect((features.last['geometry'] as Map)['coordinates'], [-2.57, 51.46]);
      expect(
        calls.any(
          (c) =>
              c.method == 'circleLayer#add' &&
              (c.arguments as Map)['sourceId'] == 'archived-endpoint-source',
        ),
        isTrue,
      );
      for (var i = 0; i < 10; i++) {
        map.onCameraMove?.call(
          ml.CameraPosition(
            target: ml.LatLng(51.45 + i * .001, -2.59),
            zoom: 12 + i * .2,
            bearing: i * 15,
          ),
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(
        calls.where((c) => c.method.contains('toScreenLocation')),
        isEmpty,
        reason: 'pins must not depend on delayed screen projections',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );
}
