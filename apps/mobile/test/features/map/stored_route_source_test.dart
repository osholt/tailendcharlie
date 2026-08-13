import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ride_relay/domain/completed_ride.dart';
import 'package:ride_relay/domain/completed_ride_store.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/domain/recorded_route_store.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/route_store.dart';
import 'package:ride_relay/features/map/ride_map.dart';
import 'package:ride_relay/services/basemap_configuration.dart';
import 'package:ride_relay/services/gpx_import_source.dart';
import 'package:ride_relay/services/imported_track_matcher.dart';
import 'package:ride_relay/services/offline_tile_cache.dart';
import 'package:ride_relay/services/approximate_place_index.dart';
import 'package:ride_relay/services/route_importer.dart';
import 'package:ride_relay/services/stored_route_library.dart';

/// A rider who has just ridden a route, or recorded one, can ride it again
/// without exporting a GPX and importing it back (#155). These drive the real
/// map screen, because the point of the feature is that the route it produces
/// goes through the same pipeline as an imported file: the same review step,
/// the same `RouteStore`, the same published route.
void main() {
  testWidgets('a recorded route can be ridden without touching a file', (
    tester,
  ) async {
    final recorded = InMemoryRecordedRouteStore();
    await recorded.save(_recording(id: 'scouted', name: 'Scouted loop'));
    final store = _RecordingRouteStore();
    final published = <ImportedRoute?>[];

    await _pumpMap(
      tester,
      store: store,
      recorded: recorded,
      onRouteCommitted: published.add,
    );

    await tester.tap(find.byKey(const Key('use-stored-route-empty-button')));
    await tester.pumpAndSettle();

    expect(find.text('Ride library'), findsWidgets);
    expect(find.text('RECORDED ROUTES'), findsOneWidget);
    expect(find.text('Scouted loop'), findsOneWidget);

    await tester.tap(
      find.byKey(const Key('stored-route-candidate-recorded:scouted')),
    );
    await tester.pumpAndSettle();

    // The rider is told plainly what they are about to ride.
    expect(find.textContaining('Tidied: a recording'), findsOneWidget);
    await tester.tap(find.byKey(const Key('use-stored-route')));
    await _followOriginalTrack(tester);

    expect(find.text('Review route'), findsOneWidget);
    expect(find.textContaining('tidied recording'), findsOneWidget);
    await _confirmReview(tester);

    expect(store.savedRoutes, hasLength(1));
    expect(store.savedRoutes.single.name, 'Scouted loop');
    expect(published.whereType<ImportedRoute>(), hasLength(1));
    // No file dialogue was involved: the importer would have returned null.
    expect(store.savedRoutes.single.sourceFileName, 'recorded-route');
  });

  testWidgets('a previous ride is selectable from route selection', (
    tester,
  ) async {
    final rides = InMemoryCompletedRideStore();
    await rides.save(
      _completedRide(
        rideId: 'ride-1',
        rideCode: 'AB12CD',
        traveledRoute: _recording(id: 'trail', name: 'Trail'),
      ),
    );
    final store = _RecordingRouteStore();

    await _pumpMap(
      tester,
      store: store,
      rides: rides,
      openChangeRouteSheet: true,
    );

    // The route-change sheet is where a GPX file is chosen, so stored geometry
    // has to be offered there too.
    await tester.tap(find.byKey(const Key('use-stored-route-sheet-item')));
    await tester.pumpAndSettle();

    expect(find.text('PREVIOUS RIDES'), findsOneWidget);
    expect(find.text('Sunday run'), findsOneWidget);
    expect(find.textContaining('ride AB12CD'), findsOneWidget);

    await tester.tap(
      find.byKey(const Key('stored-route-candidate-ride:ride-1:track')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('use-stored-route')));
    await _followOriginalTrack(tester);

    await _confirmReview(tester);

    expect(store.savedRoutes.single.name, 'Sunday run');
    expect(store.savedRoutes.single.sourceFileName, 'ride-AB12CD-track');
  });

  testWidgets('a previous ride can be ridden in the opposite direction', (
    tester,
  ) async {
    final rides = InMemoryCompletedRideStore();
    await rides.save(
      _completedRide(
        rideId: 'ride-1',
        rideCode: 'AB12CD',
        traveledRoute: _recording(id: 'trail', name: 'Trail'),
      ),
    );
    final store = _RecordingRouteStore();

    await _pumpMap(tester, store: store, rides: rides);

    await tester.tap(find.byKey(const Key('use-stored-route-empty-button')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('stored-route-candidate-ride:ride-1:track')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('stored-route-reverse')));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('original finish to the original start'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('use-stored-route')));
    await _followOriginalTrack(tester);

    expect(find.text('Review route'), findsOneWidget);
    expect(find.textContaining('Reversed'), findsWidgets);
    await _confirmReview(tester);

    final saved = store.savedRoutes.single;
    expect(saved.name, 'Sunday run (reversed)');
    final points = saved.paths.single.points;
    expect(points.first.latitude, closeTo(51.47, 1e-9));
    expect(points.last.latitude, closeTo(51.45, 1e-9));
  });

  testWidgets(
    'a reversed previous ride ignores a one-fix fragment when adding directions',
    (tester) async {
      final rides = InMemoryCompletedRideStore();
      await rides.save(
        _completedRide(
          rideId: 'ride-392725',
          rideCode: '392725',
          traveledRoute: _recordingWithTrailingFix(),
        ),
      );
      final store = _RecordingRouteStore();
      final matcher = _RecordingTrackMatcher();

      await _pumpMap(
        tester,
        store: store,
        rides: rides,
        importedTrackMatcher: matcher,
      );

      await tester.tap(find.byKey(const Key('use-stored-route-empty-button')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('stored-route-candidate-ride:ride-392725:track')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('stored-route-reverse')));
      await tester.tap(find.byKey(const Key('use-stored-route')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Add turn directions?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('generate-navigable-route')));
      await tester.pumpAndSettle();

      expect(matcher.originals, hasLength(1));
      final reversed = matcher.originals.single;
      expect(reversed.paths.first.points, hasLength(1));
      expect(reversed.paths[1].points.length, greaterThanOrEqualTo(2));
      expect(reversed.paths[1].points.first.latitude, closeTo(51.47, 1e-9));
      expect(reversed.paths[1].points.last.latitude, closeTo(51.45, 1e-9));
      expect(find.text('Review route'), findsOneWidget);
      expect(
        find.byKey(const Key('route-review-original-line')),
        findsOneWidget,
      );

      await _confirmReview(tester);
      expect(store.savedRoutes.single.maneuvers, isNotEmpty);
      expect(store.savedRoutes.single.paths, hasLength(1));
    },
  );

  testWidgets('a ride whose data has been removed is not offered', (
    tester,
  ) async {
    final rides = InMemoryCompletedRideStore();
    await rides.save(
      _completedRide(
        rideId: 'ride-gone',
        rideCode: 'GONE01',
        // Retention is ride-scoped and is not being extended: with no
        // geometry left there is nothing to ride.
        traveledRoute: null,
      ),
    );

    await _pumpMap(tester, store: _RecordingRouteStore(), rides: rides);

    await tester.tap(find.byKey(const Key('use-stored-route-empty-button')));
    await tester.pumpAndSettle();

    expect(find.text('No saved routes yet'), findsOneWidget);
    expect(find.text('Sunday run'), findsNothing);
    expect(find.text('PREVIOUS RIDES'), findsNothing);
  });

  testWidgets('the raw recorded track stays available and is labelled', (
    tester,
  ) async {
    final recorded = InMemoryRecordedRouteStore();
    await recorded.save(_recording(id: 'scouted', name: 'Scouted loop'));
    final store = _RecordingRouteStore();

    await _pumpMap(tester, store: store, recorded: recorded);

    await tester.tap(find.byKey(const Key('use-stored-route-empty-button')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('stored-route-candidate-recorded:scouted')),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Raw track'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Raw track: every fix'), findsOneWidget);

    await tester.tap(find.byKey(const Key('use-stored-route')));
    await _followOriginalTrack(tester);

    expect(find.textContaining('raw recorded track'), findsOneWidget);
    await _confirmReview(tester);

    expect(store.savedRoutes, hasLength(1));
  });

  testWidgets('GPX import is still offered alongside stored routes', (
    tester,
  ) async {
    await _pumpMap(tester, store: _RecordingRouteStore());

    expect(find.text('Import GPX'), findsOneWidget);
    expect(find.text('Enter destination'), findsOneWidget);
    expect(find.text('Use demo route'), findsOneWidget);
    expect(
      find.byKey(const Key('use-stored-route-empty-button')),
      findsOneWidget,
    );
  });
}

Future<void> _pumpMap(
  WidgetTester tester, {
  required _RecordingRouteStore store,
  RecordedRouteStore? recorded,
  CompletedRideStore? rides,
  ValueChanged<ImportedRoute?>? onRouteCommitted,
  ImportedTrackMatcher? importedTrackMatcher,
  // The Ride page's "Change route" asks the map to open its route-change sheet.
  // Left off, the empty-route card is what a rider sees, and its own controls
  // are the ones under test.
  bool openChangeRouteSheet = false,
}) async {
  final directory = Directory.systemTemp.createTempSync('stored-route-test');
  addTearDown(() => directory.deleteSync(recursive: true));
  final cache = OfflineTileCache(
    rootDirectory: directory,
    configuration: const BasemapConfiguration(),
    httpClient: MockClient((_) async => http.Response('', 404)),
  );
  final recordedStore = recorded ?? InMemoryRecordedRouteStore();
  addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(useMaterial3: true),
      home: RideMapScreen(
        // These tests exercise the pre-ride route chooser. A live route-less
        // ride deliberately dismisses that chooser so it cannot block the map.
        rideStarted: false,
        routeStore: store,
        routeImporter: RouteImporter(source: const _NoFileSource()),
        offlineTileCache: cache,
        recordedRouteStore: recordedStore,
        storedRouteLibrary: StoredRouteLibrary(
          recordedRoutes: recordedStore,
          completedRides: rides ?? InMemoryCompletedRideStore(),
          idFactory: () => 'stored-route-id',
          clock: () => DateTime.utc(2026, 7, 28),
          approximatePlaceIndex: _testPlaces,
        ),
        changeRouteRequestToken: openChangeRouteSheet ? Object() : null,
        onRouteCommitted: onRouteCommitted,
        importedTrackMatcher: importedTrackMatcher,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

final _testPlaces = ApproximatePlaceIndex.fromJson(
  jsonEncode({
    'schemaVersion': 1,
    'attribution': 'Test offline places',
    'places': [
      [5145000, -259000, 'Kingswood', 2],
      [5147000, -259000, 'Chippenham', 1],
    ],
  }),
);

Future<void> _confirmReview(WidgetTester tester) async {
  await tester.scrollUntilVisible(
    find.byKey(const Key('confirm-reviewed-route')),
    250,
    scrollable: find.byType(Scrollable).last,
  );
  await tester.tap(find.byKey(const Key('confirm-reviewed-route')));
  await tester.pumpAndSettle();
}

Future<void> _followOriginalTrack(WidgetTester tester) async {
  // While the decision is open the underlying import button intentionally
  // keeps spinning, so pump only through the dialog transition before making
  // the explicit offline choice. `pumpAndSettle` would wait on that spinner.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  expect(find.text('Add turn directions?'), findsOneWidget);
  await tester.tap(find.byKey(const Key('follow-original-track')));
  await tester.pumpAndSettle();
}

/// Two hundred metres of riding, a wait at a junction where the fix wanders,
/// then a leg east - the shape of every real recording.
ImportedRoute _recording({required String id, required String name}) {
  const metresPerDegreeLatitude = 111132.0;
  return ImportedRoute(
    id: id,
    name: name,
    importedAt: DateTime.utc(2026, 7, 26),
    sourceFileName: 'recorded.gpx',
    paths: [
      RoutePath(
        kind: RoutePathKind.track,
        points: [
          for (var index = 0; index < 10; index += 1)
            GeoPoint(
              latitude: 51.45 + index * 200 / metresPerDegreeLatitude,
              longitude: -2.59,
            ),
          const GeoPoint(latitude: 51.47, longitude: -2.59),
        ],
      ),
    ],
    waypoints: const [],
  );
}

ImportedRoute _recordingWithTrailingFix() {
  final main = _recording(id: 'trail', name: 'Trail');
  return ImportedRoute(
    id: main.id,
    name: main.name,
    importedAt: main.importedAt,
    sourceFileName: main.sourceFileName,
    paths: [
      ...main.paths,
      const RoutePath(
        kind: RoutePathKind.track,
        points: [GeoPoint(latitude: 51.4701, longitude: -2.5901)],
      ),
    ],
    waypoints: const [],
  );
}

CompletedRide _completedRide({
  required String rideId,
  required String rideCode,
  ImportedRoute? traveledRoute,
}) => CompletedRide(
  rideId: rideId,
  rideCode: rideCode,
  rideName: 'Sunday run',
  localDisplayName: 'Alex',
  localRole: RideRole.lead,
  startedAt: DateTime.utc(2026, 7, 26, 9),
  endedAt: DateTime.utc(2026, 7, 26, 12),
  archivedAt: DateTime.utc(2026, 7, 26, 12, 5),
  riderCount: 3,
  eventCount: 40,
  totalDistanceMeters: 42000,
  markerSessions: const [],
  plannedRoute: null,
  traveledRoute: traveledRoute,
);

class _RecordingRouteStore implements RouteStore {
  ImportedRoute? route;
  final savedRoutes = <ImportedRoute>[];

  @override
  Future<void> clearActiveRoute() async => route = null;

  @override
  Future<ImportedRoute?> loadActiveRoute() async => route;

  @override
  Future<void> saveActiveRoute(ImportedRoute value) async {
    savedRoutes.add(value);
    route = value;
  }
}

class _NoFileSource implements GpxImportSource {
  const _NoFileSource();

  @override
  Future<PickedGpxFile?> pickGpxFile() async => null;
}

class _RecordingTrackMatcher implements ImportedTrackMatcher {
  final originals = <ImportedRoute>[];

  @override
  Future<ImportedTrackMatch> match(ImportedRoute original) async {
    originals.add(original);
    final drawable = original.paths
        .where((path) => path.points.length >= 2)
        .toList(growable: false);
    return ImportedTrackMatch(
      route: ImportedRoute(
        id: 'matched-reversed-track',
        name: '${original.name} (navigable)',
        importedAt: DateTime.utc(2026, 8, 12),
        sourceFileName: 'matched-${original.sourceFileName}',
        paths: drawable,
        waypoints: original.waypoints,
        maneuvers: [
          RouteManeuver(
            position: drawable.single.points[1],
            type: 'turn',
            modifier: 'right',
          ),
        ],
      ),
      confidence: 0.95,
      traceCoverage: 1,
      meanDeviationMeters: 2,
      maximumDeviationMeters: 5,
    );
  }
}
