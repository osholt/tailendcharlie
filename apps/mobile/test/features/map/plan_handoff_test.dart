import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ride_relay/controllers/shared_route_controller.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/domain/route_store.dart';
import 'package:ride_relay/features/map/ride_map_feature.dart';
import 'package:ride_relay/features/map/route_review_screen.dart';
import 'package:ride_relay/services/basemap_configuration.dart';
import 'package:ride_relay/services/gpx_import_source.dart';
import 'package:ride_relay/services/offline_tile_cache.dart';
import 'package:ride_relay/services/route_importer.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A route confirmed on the plan surface reaches the map as it is (#847, #624).
void main() {
  Future<InMemoryRouteStore> pumpHandoff(
    WidgetTester tester,
    PendingInAppRoute pending,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final directory = Directory.systemTemp.createTempSync('plan-handoff');
    addTearDown(() => directory.deleteSync(recursive: true));
    final cache = OfflineTileCache(
      rootDirectory: directory,
      configuration: const BasemapConfiguration(),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );
    addTearDown(cache.dispose);
    final store = InMemoryRouteStore();
    await tester.pumpWidget(
      MaterialApp(
        home: RideMapScreen(
          routeStore: store,
          routeImporter: RouteImporter(source: const _NoFileSource()),
          offlineTileCache: cache,
          rideStarted: false,
          changeRouteRequestToken: Object(),
          pendingInAppRoute: pending,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return store;
  }

  testWidgets('a confirmed plan is taken without a second review', (
    tester,
  ) async {
    final store = await pumpHandoff(
      tester,
      PendingInAppRoute(route: _confirmedPlan(), reviewed: true),
    );

    expect(find.byType(RouteReviewScreen), findsNothing);
    expect(find.text('Add turn directions?'), findsNothing);
    expect((await store.loadActiveRoute())?.id, 'confirmed-plan');
  });

  testWidgets('a route nobody has reviewed still opens the review', (
    tester,
  ) async {
    final store = await pumpHandoff(
      tester,
      PendingInAppRoute(route: _confirmedPlan()),
    );

    expect(find.byType(RouteReviewScreen), findsOneWidget);
    expect(await store.loadActiveRoute(), isNull);
  });
}

ImportedRoute _confirmedPlan() => ImportedRoute(
  id: 'confirmed-plan',
  name: 'To Town',
  importedAt: DateTime.utc(2026, 10, 4),
  sourceFileName: 'ride-relay-destination-confirmed-plan.gpx',
  paths: const [
    RoutePath(
      kind: RoutePathKind.track,
      points: [
        GeoPoint(latitude: 52.0, longitude: -1.0),
        GeoPoint(latitude: 52.3, longitude: -1.0),
      ],
    ),
  ],
  waypoints: const [
    RouteWaypoint(
      point: GeoPoint(latitude: 52.0, longitude: -1.0),
      name: 'Start',
      description: 'Current location',
    ),
    RouteWaypoint(
      point: GeoPoint(latitude: 52.3, longitude: -1.0),
      name: 'Town',
    ),
  ],
  maneuvers: const [
    RouteManeuver(
      position: GeoPoint(latitude: 52.3, longitude: -1.0),
      type: 'arrive',
    ),
  ],
);

class _NoFileSource implements GpxImportSource {
  const _NoFileSource();

  @override
  Future<PickedGpxFile?> pickGpxFile() async => null;
}
