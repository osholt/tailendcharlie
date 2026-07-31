// A tab change must not undo what the rider has already decided (#282).
//
//   "if you are riding to start point and there has been "alerts" that you have
//    cleared if you go into ride details and then back to map it will show the
//    alerts again and you also have to press the ride to start again!!"
//
// Both halves of that report are one cause. The active-ride tabs are a `switch`
// on the selected index rather than an IndexedStack - deliberately, so a
// MapLibre view is not left composing behind another tab - so moving to Ride
// details and back **disposes and rebuilds the map**. Every decision the rider
// had made that lived in the map's own State went with it: the dismissed
// enforcement alert, and the accepted "navigate to start" leg that then had to be
// accepted again.
//
// The fix is not to keep the map mounted, which would give back the
// responsiveness work in #165/#260. It is for the shell, which outlives the tabs,
// to hold those decisions and hand them back. This file asserts that contract
// from the map's side: it reports a dismissal upward, and it honours one it is
// given.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ride_relay/domain/geo_point.dart' as awareness_geo;
import 'package:ride_relay/domain/hazard.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/domain/route_store.dart';
import 'package:ride_relay/features/map/ride_map.dart';
import 'package:ride_relay/services/basemap_configuration.dart';
import 'package:ride_relay/services/enforcement_alert_detector.dart';
import 'package:ride_relay/services/gpx_import_source.dart';
import 'package:ride_relay/services/offline_tile_cache.dart';
import 'package:ride_relay/services/route_importer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final now = DateTime.utc(2026, 7, 31, 12);

  EnforcementAlert camera(String id) => EnforcementAlert(
    hazard: HazardReport(
      id: id,
      rideId: 'ride-1',
      type: HazardType.speedCamera,
      severity: HazardSeverity.serious,
      position: const awareness_geo.GeoPoint(latitude: 51.5, longitude: -3.18),
      reportedAt: now,
      updatedAt: now,
      expiresAt: now.add(const Duration(minutes: 10)),
      reporterId: 'relay-traffic',
      source: HazardSource.externalProvider,
      providerId: 'relay-traffic',
    ),
    distanceMeters: 1207,
  );

  /// Mounts the map as the shell does. [dismissedEnforcementAlertId] is what the
  /// shell hands back after a tab change.
  Future<List<String>> pump(
    WidgetTester tester, {
    required ValueNotifier<EnforcementAlert?> alert,
    String? dismissedEnforcementAlertId,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final directory = Directory.systemTemp.createTempSync('tab-change');
    addTearDown(() => directory.deleteSync(recursive: true));
    final cache = OfflineTileCache(
      rootDirectory: directory,
      configuration: const BasemapConfiguration(),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );

    final reported = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: RideMapScreen(
          routeStore: InMemoryRouteStore(_route),
          routeImporter: RouteImporter(source: const _NoFileSource()),
          offlineTileCache: cache,
          enforcementAlert: alert,
          dismissedEnforcementAlertId: dismissedEnforcementAlertId,
          onDismissEnforcementAlert: reported.add,
          onReportHazard: (_) async {},
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    return reported;
  }

  testWidgets('dismissing an enforcement alert is reported to the shell', (
    tester,
  ) async {
    final alert = ValueNotifier<EnforcementAlert?>(null);
    addTearDown(alert.dispose);

    final reported = await pump(tester, alert: alert);
    alert.value = camera('camera-1');
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('enforcement-alert-overlay')),
      findsOneWidget,
      reason: 'the rest of this test is meaningless if it never appeared',
    );

    await tester.tap(find.byKey(const Key('enforcement-alert-overlay')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('enforcement-alert-overlay')), findsNothing);
    expect(
      reported,
      ['camera-1'],
      reason: 'the shell has to be told, or it cannot hand the decision back',
    );
  });

  testWidgets('a dismissal handed back by the shell is honoured', (
    tester,
  ) async {
    // This is the tab change itself: a brand new map State, the same alert still
    // live, and the decision restored from the shell. Before the fix there was no
    // way to express this, which is exactly why the alert came back.
    final alert = ValueNotifier<EnforcementAlert?>(camera('camera-1'));
    addTearDown(alert.dispose);

    await pump(tester, alert: alert, dismissedEnforcementAlertId: 'camera-1');

    expect(
      find.byKey(const Key('enforcement-alert-overlay')),
      findsNothing,
      reason: 'a cleared alert must stay cleared across a tab change',
    );
  });

  testWidgets('a different alert still warns after an earlier dismissal', (
    tester,
  ) async {
    // Dismissal is per hazard on purpose: passing one camera and approaching the
    // next must still warn. A fix that suppressed everything would be worse than
    // the bug.
    final alert = ValueNotifier<EnforcementAlert?>(camera('camera-2'));
    addTearDown(alert.dispose);

    await pump(tester, alert: alert, dismissedEnforcementAlertId: 'camera-1');

    expect(
      find.byKey(const Key('enforcement-alert-overlay')),
      findsOneWidget,
      reason: 'only the dismissed hazard is suppressed',
    );
  });
}

final _route = ImportedRoute(
  id: 'tab-change',
  name: 'Tab change route',
  importedAt: DateTime.utc(2026, 7, 31, 11),
  sourceFileName: 'tab-change.gpx',
  waypoints: const [],
  paths: const [
    RoutePath(
      kind: RoutePathKind.track,
      points: [
        GeoPoint(latitude: 51.5, longitude: -3.2),
        GeoPoint(latitude: 51.51, longitude: -3.19),
      ],
    ),
  ],
);

class _NoFileSource implements GpxImportSource {
  const _NoFileSource();

  @override
  Future<PickedGpxFile?> pickGpxFile() async => null;
}
