import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/completed_ride.dart';
import 'package:ride_relay/domain/completed_ride_store.dart';
import 'package:ride_relay/domain/distance_unit.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/domain/recorded_route_store.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/features/map/stored_route_picker.dart';
import 'package:ride_relay/services/approximate_place_index.dart';
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
    expect(find.text('RECORDED ROUTES'), findsOneWidget);
    expect(find.text('Ride 392725'), findsOneWidget);
    expect(find.textContaining('Kingswood to Chippenham'), findsOneWidget);
    expect(find.text('Test offline places'), findsOneWidget);
  });

  testWidgets('a long combined library is scrollable', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final recorded = InMemoryRecordedRouteStore();
    for (var index = 0; index < 30; index += 1) {
      await recorded.save(_route(id: '$index', name: 'Saved route $index'));
    }

    await _pump(tester, recorded: recorded, places: places);
    final last = find.byKey(const Key('stored-route-candidate-recorded:0'));
    await tester.scrollUntilVisible(
      last,
      500,
      scrollable: find.byType(Scrollable).first,
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
    await tester.tap(find.byKey(const Key('ride-library-record-ride-209271')));
    await tester.pump();

    expect(opened, 1);
  });
}

Future<void> _pump(
  WidgetTester tester, {
  required RecordedRouteStore recorded,
  required ApproximatePlaceIndex places,
  CompletedRideStore? completed,
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
        openPreviousRide: openPreviousRide,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

ImportedRoute _route({required String id, required String name}) =>
    ImportedRoute(
      id: id,
      name: name,
      importedAt: DateTime.utc(
        2026,
        8,
        13,
      ).add(Duration(minutes: int.parse(id))),
      sourceFileName: 'recorded.gpx',
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
