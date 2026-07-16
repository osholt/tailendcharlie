import 'dart:io';

import 'package:flutter/material.dart';
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
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Import GPX'), findsOneWidget);
    expect(find.text('ROUTE-ONLY OFFLINE MAP'), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);

    await tester.tap(find.text('Demo'));
    for (var i = 0; i < 5; i += 1) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.text('Peak District demo loop'), findsOneWidget);
    expect(find.text('7 route points · 2 waypoints'), findsOneWidget);
    expect(find.text('Replace'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}

class _NoFileSource implements GpxImportSource {
  const _NoFileSource();

  @override
  Future<PickedGpxFile?> pickGpxFile() async => null;
}
