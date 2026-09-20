import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:ride_relay/domain/imported_route.dart' show GeoPoint;
import 'package:ride_relay/domain/distance_unit.dart';
import 'package:ride_relay/domain/ride_library_organisation.dart';
import 'package:ride_relay/features/map/ride_library_browser.dart';
import 'package:ride_relay/services/basemap_configuration.dart';

void main() {
  RideLibraryEntry entry({
    String id = 'one',
    String title = 'Sunday ride',
    String place = 'Bristol',
    double distance = 60000,
    int? rating = 4,
    VoidCallback? open,
    RideLibraryOrganisation organisation = const RideLibraryOrganisation(),
  }) => RideLibraryEntry(
    id: id,
    title: title,
    locationLabel: place,
    distanceMeters: distance,
    rating: rating,
    organisation: organisation,
    open: open ?? () {},
    paths: const [
      [
        GeoPoint(latitude: 51, longitude: -3),
        GeoPoint(latitude: 51, longitude: -1),
      ],
    ],
  );

  test('tags and nested folders combine with other library filters', () {
    final ride = entry(
      organisation: RideLibraryOrganisation.fromInput(
        tags: '#Fun #twisty, FUN',
        folder: ' Trips / France ',
      ),
    );
    expect(ride.organisation.tags, ['fun', 'twisty']);
    expect(
      libraryEntryMatches(
        ride,
        query: 'Bristol #fun',
        folder: 'Trips',
        tag: 'twisty',
      ),
      isTrue,
    );
    expect(libraryEntryMatches(ride, query: '#wet'), isFalse);
    expect(libraryEntryMatches(ride, folder: 'Trip'), isFalse);
    expect(libraryEntryMatches(ride, folder: ''), isFalse);
    expect(libraryEntryMatches(entry(), folder: ''), isTrue);
  });

  test(
    'location, length and rating filters combine and exclude unrated rides',
    () {
      final ride = entry();
      expect(
        libraryEntryMatches(
          ride,
          query: ' bristol ',
          length: LibraryLength.medium,
          minimumRating: 4,
        ),
        isTrue,
      );
      expect(libraryEntryMatches(ride, query: 'Bath'), isFalse);
      expect(libraryEntryMatches(ride, length: LibraryLength.short), isFalse);
      expect(libraryEntryMatches(ride, minimumRating: 5), isFalse);
      expect(
        libraryEntryMatches(entry(rating: null), minimumRating: 3),
        isFalse,
      );
      expect(
        libraryEntryMatches(
          ride,
          length: LibraryLength.short,
          lengthUnitMeters: 1609.344,
        ),
        isTrue,
      );
    },
  );

  test(
    'area filter includes crossing segments and excludes distant parallel roads',
    () {
      final area = LatLngBounds(
        const LatLng(50.9, -2.5),
        const LatLng(51.1, -1.5),
      );
      expect(libraryEntryMatches(entry(), area: area), isTrue);
      expect(
        libraryPathIntersectsArea(const [
          GeoPoint(latitude: 52, longitude: -3),
          GeoPoint(latitude: 52, longitude: -1),
        ], area),
        isFalse,
      );
      expect(
        libraryPathIntersectsArea(const [
          GeoPoint(latitude: 51, longitude: -4),
          GeoPoint(latitude: 51, longitude: -3),
        ], area),
        isFalse,
      );
    },
  );

  testWidgets(
    'search filters the list and a map marker opens the selected ride',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var opened = false;
      final entries = [
        entry(open: () => opened = true),
        entry(id: 'two', title: 'French tour', place: 'France'),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RideLibraryBrowser(
              entries: entries,
              distanceUnit: DistanceUnit.kilometres,
              basemap: const BasemapConfiguration(),
              allowRating: true,
              listBuilder: (ids, _) => ListView(
                children: [
                  for (final item in entries)
                    if (ids.contains(item.id))
                      ListTile(title: Text(item.title)),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.enterText(
        find.byKey(const Key('library-search')),
        'Bristol',
      );
      await tester.pump();
      expect(find.text('Sunday ride'), findsOneWidget);
      expect(find.text('French tour'), findsNothing);
      await tester.tap(find.byKey(const Key('library-view-toggle')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ride-library-map')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('library-marker-one')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('library-map-selection')));
      expect(opened, isTrue);
      await tester.ensureVisible(find.byKey(const Key('library-area-filter')));
      await tester.tap(find.byKey(const Key('library-area-filter')));
      await tester.pump();
      expect(find.text('Clear filters'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
