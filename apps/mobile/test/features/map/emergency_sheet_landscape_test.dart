// The emergency actions sheet has to fit a phone held sideways (#193).
//
// Found while fixing #177: pressing SOS in landscape opened this sheet and its
// `Column` overran the bottom by 58 px at 390 px of height, which is any current
// iPhone in landscape. The framework then clipped whatever was last - the
// explanatory note - without saying so.
//
// This is the screen a rider sees immediately after asking for help, so the test
// runs the shortest viewports a supported device presents.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/route_store.dart';
import 'package:ride_relay/features/map/ride_map.dart';
import 'package:ride_relay/features/map/ride_map_feature.dart';
import 'package:ride_relay/services/basemap_configuration.dart';
import 'package:ride_relay/services/gpx_import_source.dart';
import 'package:ride_relay/services/offline_tile_cache.dart';
import 'package:ride_relay/services/route_importer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> openSheet(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final directory = Directory.systemTemp.createTempSync('emergency-sheet');
    addTearDown(() => directory.deleteSync(recursive: true));

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: RideMapScreen(
          routeStore: InMemoryRouteStore(_route),
          routeImporter: RouteImporter(source: const _NoFileSource()),
          offlineTileCache: OfflineTileCache(
            rootDirectory: directory,
            configuration: const BasemapConfiguration(),
            httpClient: MockClient((_) async => http.Response('', 404)),
          ),
          emergencyContacts: const [
            MapEmergencyContact(
              riderId: 'lead',
              displayName: 'Oliver',
              role: RideRole.lead,
            ),
            MapEmergencyContact(
              riderId: 'tec',
              displayName: 'Charlie',
              role: RideRole.tailEndCharlie,
            ),
          ],
          onEmergencyAlert: () async {},
          onEmergencyIssue: (_) async {},
          onLeaveRide: () async {},
          onReportHazard: (_) async {},
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('emergency-alert-button')));
    await tester.pumpAndSettle();
  }

  // 390 is an iPhone 14/15/16 in landscape; 375 an iPhone SE; 320 the shortest
  // viewport worth supporting at all.
  for (final height in [390.0, 375.0, 320.0]) {
    testWidgets('the sheet fits a ${height.toInt()} px landscape viewport', (
      tester,
    ) async {
      await openSheet(tester, Size(844, height));

      expect(
        tester.takeException(),
        isNull,
        reason: 'a RenderFlex overflow clips whatever is last, silently',
      );
      expect(find.text('You are stopped'), findsOneWidget);
    });
  }

  testWidgets('every issue the rider might raise is reachable', (tester) async {
    await openSheet(tester, const Size(844, 390));

    // The four issue buttons are the point of the sheet. Scrolling to them is
    // acceptable; not being able to reach them is not.
    for (final label in [
      'Mechanical',
      'Need help',
      'Route blocked',
      'Need fuel',
    ]) {
      final button = find.text(label);
      if (button.evaluate().isEmpty) {
        await tester.scrollUntilVisible(button, 80);
        await tester.pumpAndSettle();
      }
      expect(button, findsOneWidget, reason: '$label is unreachable');
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('portrait is unchanged', (tester) async {
    await openSheet(tester, const Size(390, 844));

    expect(tester.takeException(), isNull);
    expect(find.text('You are stopped'), findsOneWidget);
    expect(find.text('Mechanical'), findsOneWidget);
    // The note still fits without scrolling where there is room for it.
    expect(find.textContaining('Pick who to text'), findsOneWidget);
  });
}

final _route = ImportedRoute(
  id: 'emergency-sheet',
  name: 'Emergency sheet route',
  importedAt: DateTime.utc(2026, 7, 27),
  sourceFileName: 'emergency-sheet.gpx',
  paths: const [
    RoutePath(
      kind: RoutePathKind.track,
      points: [
        GeoPoint(latitude: 51.46, longitude: -2.5),
        GeoPoint(latitude: 51.47, longitude: -2.49),
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
