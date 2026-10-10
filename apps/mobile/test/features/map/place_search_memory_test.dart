import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/distance_unit.dart';
import 'package:ride_relay/domain/imported_route.dart' show GeoPoint;
import 'package:ride_relay/domain/ride_plan.dart';
import 'package:ride_relay/features/map/circular_ride_sheet.dart';
import 'package:ride_relay/features/map/place_search_sheet.dart';
import 'package:ride_relay/features/map/ride_plan_panels.dart';
import 'package:ride_relay/services/place_memory.dart';
import 'package:ride_relay/services/road_routing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #937 on the plan surface: the start, stop and destination pickers offer the
/// saved places and history too, and a place on the plan - a stop, the
/// destination, a pin the rider dropped - can be saved from its row.
///
/// Every coordinate is synthetic; none is a rider's home or workplace.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  const bath = DestinationMatch(
    label: 'Bath, Somerset, England',
    point: GeoPoint(latitude: 51.38, longitude: -2.36),
  );

  RidePlanPlace spot(String label, double latitude) => RidePlanPlace(
    point: GeoPoint(latitude: latitude, longitude: -1),
    label: label,
    description: '$label, Shire, England',
  );

  group('the place picker', () {
    testWidgets('offers Your location, saved places and history on a start', (
      tester,
    ) async {
      final memory = PlaceMemory.inMemory();
      addTearDown(memory.dispose);
      await memory.setHome(spot('12 Example Road', 52));
      await memory.remember(spot('Bath Spa', 51.1));
      await _open(tester, _Search({}), memory: memory);

      expect(
        find.byKey(const Key('place-search-current-location')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('place-search-saved-home')), findsOneWidget);
      expect(find.byKey(const Key('place-search-recent-0')), findsOneWidget);
      expect(find.byKey(const Key('place-search-add-work')), findsOneWidget);
    });

    testWidgets('choosing Home returns it named Home, with its address', (
      tester,
    ) async {
      final memory = PlaceMemory.inMemory();
      addTearDown(memory.dispose);
      await memory.setHome(spot('12 Example Road', 52));
      PlaceSearchChoice? choice;
      await _open(
        tester,
        _Search({}),
        memory: memory,
        onChoice: (c) => choice = c,
      );

      await tester.tap(find.byKey(const Key('place-search-saved-home')));
      await tester.pumpAndSettle();

      final place = (choice as PlaceSearchPlace).place;
      expect(place.label, 'Home');
      expect(place.description, '12 Example Road, Shire, England');
      expect(place.point.latitude, 52);
    });

    testWidgets('typing narrows the rows and does not search', (tester) async {
      final memory = PlaceMemory.inMemory();
      addTearDown(memory.dispose);
      await memory.setHome(spot('12 Example Road', 52));
      await memory.remember(spot('Bath Spa', 51.1));
      await memory.remember(spot('Bakewell', 53.2));
      final search = _Search({
        'bath': [bath],
      });
      await _open(tester, search, memory: memory);

      for (final typed in ['b', 'ba', 'bat', 'bath']) {
        await tester.enterText(
          find.byKey(const Key('place-search-field')),
          typed,
        );
        await tester.pump();
      }
      expect(find.text('Bath Spa'), findsOneWidget);
      expect(find.text('Bakewell'), findsNothing);
      expect(find.byKey(const Key('place-search-saved-home')), findsNothing);
      // docs/geocoder-decision.md: no request per keystroke.
      expect(search.calls, isEmpty);

      await tester.tap(find.byKey(const Key('place-search-submit')));
      await tester.pumpAndSettle();
      expect(search.calls, ['bath']);
    });

    testWidgets('a chosen result is remembered as the plan names it', (
      tester,
    ) async {
      final memory = PlaceMemory.inMemory();
      addTearDown(memory.dispose);
      PlaceSearchChoice? choice;
      await _open(
        tester,
        _Search({
          'bath': [bath],
        }),
        memory: memory,
        onChoice: (c) => choice = c,
      );
      await tester.enterText(
        find.byKey(const Key('place-search-field')),
        'bath',
      );
      await tester.tap(find.byKey(const Key('place-search-submit')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('place-search-result-${bath.label}')));
      await tester.pumpAndSettle();

      expect((choice as PlaceSearchPlace).place.label, 'Bath');
      expect(memory.recents.single.label, 'Bath');
      expect(memory.recents.single.description, bath.label);
    });

    testWidgets('choosing Your location is not remembered as a place', (
      tester,
    ) async {
      final memory = PlaceMemory.inMemory();
      addTearDown(memory.dispose);
      PlaceSearchChoice? choice;
      await _open(
        tester,
        _Search({}),
        memory: memory,
        onChoice: (c) => choice = c,
      );
      await tester.tap(find.byKey(const Key('place-search-current-location')));
      await tester.pumpAndSettle();
      expect(choice, isA<PlaceSearchCurrentLocation>());
      expect(memory.recents, isEmpty);
    });

    testWidgets('a result can be saved from the picker without choosing it', (
      tester,
    ) async {
      final memory = PlaceMemory.inMemory();
      addTearDown(memory.dispose);
      PlaceSearchChoice? choice;
      await _open(
        tester,
        _Search({
          'bath': [bath],
        }),
        memory: memory,
        onChoice: (c) => choice = c,
      );
      await tester.enterText(
        find.byKey(const Key('place-search-field')),
        'bath',
      );
      await tester.tap(find.byKey(const Key('place-search-submit')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('place-search-save-${bath.label}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('save-place-as-work')));
      await tester.pumpAndSettle();

      expect(memory.work!.point.latitude, 51.38);
      expect(choice, isNull, reason: 'the picker is still open');
      expect(memory.recents, isEmpty);
    });

    testWidgets('without saved places it is the plain search it was', (
      tester,
    ) async {
      final memory = PlaceMemory.inMemory();
      addTearDown(memory.dispose);
      await memory.setHome(spot('12 Example Road', 52));
      await _open(tester, _Search({}), memory: memory, showPlaceMemory: false);
      expect(find.byKey(const Key('place-search-place-memory')), findsNothing);
      expect(find.byKey(const Key('place-search-saved-home')), findsNothing);
    });
  });

  group('the circular ride\'s start', () {
    Future<void> openStartPicker(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => CircularRideSheet.show(
                  context,
                  start: const GeoPoint(latitude: 51, longitude: -2),
                  distanceUnit: DistanceUnit.miles,
                  searchService: _Search({}),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('circular-ride-change-start')));
      await tester.pumpAndSettle();
    }

    testWidgets('can be Home', (tester) async {
      final seeded = await PlaceMemory.open();
      await seeded.setHome(spot('12 Example Road', 52));
      seeded.dispose();
      await openStartPicker(tester);

      await tester.tap(find.byKey(const Key('place-search-saved-home')));
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byKey(const Key('circular-ride-start')),
          matching: find.text('Home'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('Work can be set from the rider\'s location', (tester) async {
      await openStartPicker(tester);
      await tester.tap(find.byKey(const Key('place-search-add-work')));
      await tester.pumpAndSettle();

      // The start picker has "Your location" of its own, and so has the picker
      // that chooses where Work is: the loop knows where the rider is.
      final offered = find.byKey(const Key('place-search-current-location'));
      expect(offered, findsNWidgets(2));
      await tester.tap(offered.last);
      await tester.pumpAndSettle();

      final stored = await PlaceMemory.open();
      addTearDown(stored.dispose);
      expect(stored.work!.point.latitude, 51);
      expect(stored.work!.point.longitude, -2);
    });
  });

  group('saving a place from the plan', () {
    RidePlan samplePlan() => RidePlan(
      start: PlaceStart(spot('Meet', 52.0)),
      stops: [spot('Cafe', 52.1)],
      destination: RidePlanPlace(
        point: const GeoPoint(latitude: 52.2, longitude: -1),
        label: RidePlanPlace.droppedPinLabel,
      ),
    );

    Future<void> pump(
      WidgetTester tester, {
      RidePlan? plan,
      ValueChanged<RidePlanPlace>? onSave,
      bool busy = false,
    }) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: RidePlanItinerary(
              plan: plan ?? samplePlan(),
              currentLocationKnown: true,
              busy: busy,
              onChangeStart: () {},
              onChangeDestination: () {},
              onAddStop: () {},
              onMoveStop: (_, _) {},
              onRemoveStop: (_) {},
              onSavePlace: onSave,
            ),
          ),
        ),
      ),
    );

    testWidgets('each place has a save button, a dropped pin included', (
      tester,
    ) async {
      final saved = <RidePlanPlace>[];
      await pump(tester, onSave: saved.add);

      await tester.tap(find.byKey(const Key('ride-plan-save-start')));
      await tester.tap(find.byKey(const Key('ride-plan-save-stop-0')));
      await tester.tap(find.byKey(const Key('ride-plan-save-destination')));
      expect(saved.map((place) => place.label), [
        'Meet',
        'Cafe',
        RidePlanPlace.droppedPinLabel,
      ]);
      expect(saved.last.point.latitude, 52.2);
    });

    testWidgets('a start that follows the rider has nothing to save', (
      tester,
    ) async {
      await pump(
        tester,
        plan: RidePlan(destination: spot('Town', 52.3)),
        onSave: (_) {},
      );
      expect(find.byKey(const Key('ride-plan-save-start')), findsNothing);
      expect(
        find.byKey(const Key('ride-plan-save-destination')),
        findsOneWidget,
      );
    });

    testWidgets('no callback, no buttons', (tester) async {
      await pump(tester);
      expect(find.byIcon(Icons.bookmark_add_outlined), findsNothing);
    });

    testWidgets('the buttons wait while a re-plan is in flight', (
      tester,
    ) async {
      var saved = 0;
      await pump(tester, onSave: (_) => saved += 1, busy: true);
      await tester.tap(find.byKey(const Key('ride-plan-save-destination')));
      expect(saved, 0);
    });
  });
}

Future<void> _open(
  WidgetTester tester,
  DestinationSearchService search, {
  PlaceMemory? memory,
  bool showPlaceMemory = true,
  ValueChanged<PlaceSearchChoice?>? onChoice,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(useMaterial3: true),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              final choice = await PlaceSearchSheet.show(
                context,
                searchService: search,
                title: 'Start from',
                offerCurrentLocation: true,
                currentPoint: const GeoPoint(latitude: 51, longitude: -2),
                showPlaceMemory: showPlaceMemory,
                memory: memory,
              );
              onChoice?.call(choice);
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

class _Search implements DestinationSearchService {
  _Search(this.results);

  final Map<String, List<DestinationMatch>> results;
  final List<String> calls = [];

  @override
  Future<List<DestinationMatch>> search(String query) async {
    calls.add(query);
    return results[query.toLowerCase()] ?? const [];
  }
}
