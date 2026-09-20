import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/completed_ride.dart';
import 'package:ride_relay/domain/completed_ride_store.dart';
import 'package:ride_relay/domain/distance_unit.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/domain/recorded_route_store.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/ride_library_organisation.dart';
import 'package:ride_relay/features/map/stored_route_picker.dart';
import 'package:ride_relay/features/map/flutter_vector_route_preview.dart';
import 'package:ride_relay/services/approximate_place_index.dart';
import 'package:ride_relay/services/basemap_configuration.dart';
import 'package:ride_relay/services/stored_route_library.dart';

void main() {
  final places = ApproximatePlaceIndex.fromJson(
    jsonEncode({
      'schemaVersion': 1,
      'attribution': 'Test offline places',
      'places': [
        [5145000, -210000, 'Kingswood', 2],
        [5145800, -150000, 'Chippenham', 1],
      ],
    }),
  );

  testWidgets('shows approximate endpoints beside an unhelpful ride title', (
    tester,
  ) async {
    final recorded = InMemoryRecordedRouteStore();
    await recorded.save(_route(id: '392725', name: 'Ride 392725'));

    await _pump(tester, recorded: recorded, places: places);

    expect(find.text('Ride library'), findsOneWidget);
    expect(find.text('IMPORTED ROUTES'), findsOneWidget);
    expect(find.text('Ride 392725'), findsOneWidget);
    expect(find.textContaining('Kingswood to Chippenham'), findsOneWidget);
    expect(find.text('Test offline places'), findsOneWidget);
  });

  testWidgets(
    'rename, bin and restore are available on imported files and rides',
    (tester) async {
      final recorded = InMemoryRecordedRouteStore();
      await recorded.save(_route(id: '31', name: 'Imported tour'));
      final rides = InMemoryCompletedRideStore();
      await rides.save(_completedRide());
      await _pump(tester, recorded: recorded, completed: rides, places: places);
      await tester.tap(find.byKey(const Key('library-actions-route-31')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('library-name-field')),
        'France plan',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect((await recorded.list()).single.name, 'France plan');
      await tester.tap(find.byKey(const Key('library-actions-route-31')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Move to Bin'));
      await tester.pumpAndSettle();
      expect(find.text('France plan'), findsNothing);
      expect(
        (await recorded.list()).single.libraryStatus,
        RideLibraryStatus.deleted,
      );
      await tester.tap(find.byKey(const Key('ride-library-rides-tab')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('library-actions-ride-ride-209271')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Move to Bin'));
      await tester.pumpAndSettle();
      expect(find.text('Ride 209271'), findsNothing);
      await tester.tap(find.byKey(const Key('ride-library-bin-tab')));
      await tester.pumpAndSettle();
      expect(find.text('France plan'), findsOneWidget);
      expect(find.text('Ride 209271'), findsOneWidget);
      await tester.tap(find.byKey(const Key('library-actions-route-31')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Restore'));
      await tester.pumpAndSettle();
      expect(find.text('France plan'), findsNothing);
      expect(
        (await recorded.list()).single.libraryStatus,
        RideLibraryStatus.active,
      );
      expect((await recorded.list()).single.deletedAt, isNull);
      await tester.tap(
        find.byKey(const Key('library-actions-ride-ride-209271')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Restore'));
      await tester.pumpAndSettle();
      expect(
        (await rides.list()).single.libraryStatus,
        RideLibraryStatus.active,
      );
      await tester.tap(find.byKey(const Key('ride-library-rides-tab')));
      await tester.pumpAndSettle();
      expect(find.text('Ride 209271'), findsOneWidget);
    },
  );

  testWidgets(
    'tags, folder and map colour can be edited for a GPX and a ride',
    (tester) async {
      final recorded = InMemoryRecordedRouteStore();
      await recorded.save(_route(id: '32', name: 'Tour plan'));
      final rides = InMemoryCompletedRideStore();
      await rides.save(_completedRide());
      await _pump(tester, recorded: recorded, completed: rides, places: places);
      for (final id in ['route-32', 'ride-ride-209271']) {
        if (id.startsWith('ride-')) {
          await tester.tap(find.byKey(const Key('ride-library-rides-tab')));
          await tester.pumpAndSettle();
        }
        await tester.tap(find.byKey(Key('library-actions-$id')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Tags, folder & colour'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('library-tags-field')),
          '#Fun #wet',
        );
        await tester.enterText(
          find.byKey(const Key('library-folder-field')),
          'Trips/France',
        );
        await tester.ensureVisible(find.byKey(const Key('library-colour-4')));
        await tester.tap(find.byKey(const Key('library-colour-4')));
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
      }
      for (final organisation in [
        (await recorded.list()).single.organisation,
        (await rides.list()).single.organisation,
      ]) {
        expect(organisation.tags, ['fun', 'wet']);
        expect(organisation.folder, 'Trips/France');
        expect(organisation.colourArgb, RideLibraryOrganisation.colours[4]);
      }
      await tester.tap(find.byKey(const Key('library-view-toggle')));
      await tester.pumpAndSettle();
      final marker = tester.widget<IconButton>(
        find.byKey(const ValueKey('library-marker-ride-209271')),
      );
      expect(
        (marker.icon as Icon).color,
        Color(RideLibraryOrganisation.colours[4]),
      );
    },
  );

  testWidgets('a long combined library is scrollable', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final recorded = InMemoryRecordedRouteStore();
    for (var index = 0; index < 30; index += 1) {
      await recorded.save(
        _route(
          id: '$index',
          name: 'Saved route $index',
          sourceFileName: 'recorded.gpx',
        ),
      );
    }

    await _pump(tester, recorded: recorded, places: places);
    await tester.tap(find.byKey(const Key('ride-library-rides-tab')));
    await tester.pumpAndSettle();
    final last = find.byKey(const Key('stored-route-candidate-recorded:0'));
    await tester.scrollUntilVisible(
      last,
      500,
      scrollable: find.descendant(
        of: find.byKey(const PageStorageKey<String>('ride-library-rides')),
        matching: find.byType(Scrollable),
      ),
    );

    expect(last, findsOneWidget);
    expect(find.text('Saved route 0'), findsOneWidget);
  });

  testWidgets('routes with the same title remain separate library entries', (
    tester,
  ) async {
    final recorded = InMemoryRecordedRouteStore();
    await recorded.save(_route(id: '10', name: 'Sunday loop'));
    await recorded.save(_route(id: '11', name: 'Sunday loop'));

    await _pump(tester, recorded: recorded, places: places);

    expect(find.text('Sunday loop'), findsNWidgets(2));
    expect(
      find.byKey(const Key('stored-route-candidate-recorded:10')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('stored-route-candidate-recorded:11')),
      findsOneWidget,
    );
  });

  testWidgets('configured basemap tiles appear in thumbnails and preview', (
    tester,
  ) async {
    final recorded = InMemoryRecordedRouteStore();
    await recorded.save(_route(id: '12', name: 'Tile preview route'));
    const basemap = BasemapConfiguration(
      styleUrl: 'https://example.test/style.json',
      attribution: 'Test tiles',
    );

    await _pump(
      tester,
      recorded: recorded,
      places: places,
      basemapConfiguration: basemap,
    );

    expect(find.byType(FlutterVectorRoutePreview), findsOneWidget);
    await tester.tap(
      find.byKey(const Key('stored-route-candidate-recorded:12')),
    );
    await tester.pump();

    expect(find.byKey(const Key('stored-route-map-preview')), findsOneWidget);
    expect(find.byType(FlutterVectorRoutePreview), findsNWidgets(2));
    // Complete the bounded style request before tearing down this network-free test.
    await tester.pump(const Duration(seconds: 11));
    await tester.pump();
  });

  testWidgets('a previous ride opens its details directly from the library', (
    tester,
  ) async {
    final recorded = InMemoryRecordedRouteStore();
    await recorded.save(_route(id: '1', name: 'Saved route'));
    final completed = InMemoryCompletedRideStore();
    await completed.save(_completedRide());
    var opened = 0;

    await _pump(
      tester,
      recorded: recorded,
      completed: completed,
      places: places,
      openPreviousRide: (_, ride) async {
        opened += 1;
        expect(ride.rideId, 'ride-209271');
        return null;
      },
    );
    expect(
      find.byKey(const Key('ride-library-details-and-exports')),
      findsNothing,
    );
    await tester.tap(find.byKey(const Key('ride-library-rides-tab')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('ride-library-record-ride-209271')));
    await tester.pump();

    expect(opened, 1);
  });

  testWidgets('recordings and completed rides share one tab beside imports', (
    tester,
  ) async {
    final recorded = InMemoryRecordedRouteStore();
    await recorded.save(
      _route(id: '21', name: 'Imported GPX', sourceFileName: 'tour.gpx'),
    );
    await recorded.save(
      _route(id: '22', name: 'Phone recording', sourceFileName: 'recorded.gpx'),
    );
    final completed = InMemoryCompletedRideStore();
    await completed.save(_completedRide());

    await _pump(
      tester,
      recorded: recorded,
      completed: completed,
      places: places,
      openPreviousRide: (_, _) async => null,
    );

    expect(find.text('Imported GPX'), findsOneWidget);
    expect(find.text('Phone recording'), findsNothing);
    expect(
      find.byKey(const Key('ride-library-record-ride-209271')),
      findsNothing,
    );

    await tester.tap(find.byKey(const Key('ride-library-rides-tab')));
    await tester.pumpAndSettle();
    expect(find.text('Phone recording'), findsOneWidget);
    expect(find.text('Imported GPX'), findsNothing);

    await tester.tap(find.byKey(const Key('ride-library-rides-tab')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('ride-library-record-ride-209271')),
      findsOneWidget,
    );
    expect(find.text('Phone recording'), findsOneWidget);
  });
}

Future<void> _pump(
  WidgetTester tester, {
  required RecordedRouteStore recorded,
  required ApproximatePlaceIndex places,
  CompletedRideStore? completed,
  BasemapConfiguration basemapConfiguration = const BasemapConfiguration(),
  Future<StoredRouteSelection?> Function(BuildContext, CompletedRide)?
  openPreviousRide,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(useMaterial3: true),
      home: StoredRoutePickerScreen(
        library: StoredRouteLibrary(
          recordedRoutes: recorded,
          completedRides: completed ?? InMemoryCompletedRideStore(),
          approximatePlaceIndex: places,
        ),
        distanceUnit: DistanceUnit.miles,
        basemapConfiguration: basemapConfiguration,
        openPreviousRide: openPreviousRide,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

ImportedRoute _route({
  required String id,
  required String name,
  String sourceFileName = 'tour.gpx',
}) => ImportedRoute(
  id: id,
  name: name,
  importedAt: DateTime.utc(2026, 8, 13).add(Duration(minutes: int.parse(id))),
  sourceFileName: sourceFileName,
  paths: const [
    RoutePath(
      kind: RoutePathKind.track,
      points: [
        GeoPoint(latitude: 51.45, longitude: -2.1),
        GeoPoint(latitude: 51.458, longitude: -1.5),
      ],
    ),
  ],
  waypoints: const [],
);

CompletedRide _completedRide() => CompletedRide(
  rideId: 'ride-209271',
  rideCode: '209271',
  rideName: 'Ride 209271',
  localDisplayName: 'Oliver',
  localRole: RideRole.lead,
  startedAt: DateTime.utc(2026, 8, 15, 10),
  endedAt: DateTime.utc(2026, 8, 15, 11),
  archivedAt: DateTime.utc(2026, 8, 15, 11),
  riderCount: 1,
  eventCount: 100,
  totalDistanceMeters: 17000,
  markerSessions: const [],
  plannedRoute: null,
  traveledRoute: _route(id: '209271', name: 'Ride 209271'),
);
