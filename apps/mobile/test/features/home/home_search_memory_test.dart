import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/imported_route.dart' show GeoPoint;
import 'package:ride_relay/domain/ride_plan.dart';
import 'package:ride_relay/features/home/home_destination_search.dart';
import 'package:ride_relay/services/place_memory.dart';
import 'package:ride_relay/services/road_routing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #937: Where to? remembers where the rider has been and offers Home, Work and
/// places they have named.
///
/// > I would like for the search box to show a history of where I have searched
/// > before, and allow common destinations 'home', 'work' or other custom saved
/// > locations to be available too.
///
/// Every coordinate is synthetic; none is a rider's home or workplace.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  const bath = DestinationMatch(
    label: 'Bath, Somerset, England',
    point: GeoPoint(latitude: 51.38, longitude: -2.36),
  );
  const bristol = DestinationMatch(
    label: 'Bristol, England',
    point: GeoPoint(latitude: 51.45, longitude: -2.59),
  );

  RidePlanPlace spot(String label, double latitude, {String? description}) =>
      RidePlanPlace(
        point: GeoPoint(latitude: latitude, longitude: -1),
        label: label,
        description: description ?? '$label, Shire, England',
      );

  group('what the empty search shows', () {
    testWidgets('offers Home, Work and a new place when nothing is saved', (
      tester,
    ) async {
      final memory = PlaceMemory.inMemory();
      addTearDown(memory.dispose);
      await _pump(tester, _Search({}), (_) {}, memory: memory);

      expect(find.byKey(const Key('home-search-add-home')), findsOneWidget);
      expect(find.byKey(const Key('home-search-add-work')), findsOneWidget);
      expect(find.byKey(const Key('home-search-add-custom')), findsOneWidget);
      expect(find.text('RECENT'), findsNothing);
      expect(
        find.byKey(const Key('home-search-clear-history')),
        findsNothing,
        reason: 'nothing to clear',
      );
    });

    testWidgets('puts saved places first and history under them, above the '
        'other ways in', (tester) async {
      final memory = PlaceMemory.inMemory();
      addTearDown(memory.dispose);
      await memory.setHome(spot('12 Example Road', 52));
      await memory.addCustom('Campsite', spot('Lakeside', 53));
      await memory.remember(spot('Bath', 51.1));
      await memory.remember(spot('Bristol', 51.2));
      await _pump(tester, _Search({}), (_) {}, memory: memory);

      double top(Key key) => tester.getTopLeft(find.byKey(key)).dy;
      final order = [
        top(const Key('home-search-saved-home')),
        top(const Key('home-search-add-work')),
        top(const Key('home-search-saved-custom-0')),
        top(const Key('home-search-recent-0')),
        top(const Key('home-search-recent-1')),
        top(const Key('home-search-circular-ride')),
      ];
      expect([...order]..sort(), order, reason: 'in that order, top to bottom');
      // Newest first.
      expect(
        find.descendant(
          of: find.byKey(const Key('home-search-recent-0')),
          matching: find.text('Bristol'),
        ),
        findsOneWidget,
      );
      // A set Home is not offered again.
      expect(find.byKey(const Key('home-search-add-home')), findsNothing);
    });
  });

  group('typing', () {
    testWidgets('narrows the list as it goes and never searches', (
      tester,
    ) async {
      final memory = PlaceMemory.inMemory();
      addTearDown(memory.dispose);
      await memory.setHome(spot('12 Example Road', 52));
      await memory.remember(spot('Bath Spa', 51.1));
      await memory.remember(spot('Bakewell', 53.2));
      final search = _Search({
        'bath': [bath],
      });
      await _pump(tester, search, (_) {}, memory: memory);
      expect(find.text('Bath Spa'), findsOneWidget);
      expect(find.text('Bakewell'), findsOneWidget);

      for (final typed in ['b', 'ba', 'bat', 'bath']) {
        await tester.enterText(
          find.byKey(const Key('home-search-field')),
          typed,
        );
        await tester.pump();
      }

      expect(find.text('Bath Spa'), findsOneWidget);
      expect(find.text('Bakewell'), findsNothing);
      expect(find.byKey(const Key('home-search-saved-home')), findsNothing);
      expect(
        find.byKey(const Key('home-search-add-work')),
        findsNothing,
        reason: 'set-up rows are for the empty search',
      );
      expect(find.byKey(const Key('home-search-clear-history')), findsNothing);
      // docs/geocoder-decision.md: no request per keystroke.
      expect(search.calls, isEmpty);

      await tester.tap(find.byKey(const Key('home-search-submit')));
      await tester.pumpAndSettle();
      expect(search.calls, ['bath'], reason: 'one request, on submit');
      expect(find.text('Bath, Somerset, England'), findsOneWidget);
    });

    testWidgets('clearing the field brings the whole list back', (
      tester,
    ) async {
      final memory = PlaceMemory.inMemory();
      addTearDown(memory.dispose);
      await memory.remember(spot('Bath Spa', 51.1));
      await memory.remember(spot('Bakewell', 53.2));
      await _pump(tester, _Search({}), (_) {}, memory: memory);

      await tester.enterText(
        find.byKey(const Key('home-search-field')),
        'bake',
      );
      await tester.pump();
      expect(find.text('Bath Spa'), findsNothing);
      await tester.enterText(find.byKey(const Key('home-search-field')), '');
      await tester.pump();
      expect(find.text('Bath Spa'), findsOneWidget);
      expect(find.text('Bakewell'), findsOneWidget);
    });
  });

  group('history', () {
    testWidgets('remembers a place that was chosen, once, newest first', (
      tester,
    ) async {
      final memory = PlaceMemory.inMemory();
      addTearDown(memory.dispose);
      HomeSearchOutcome? outcome;
      final search = _Search({
        'bath': [bath],
        'bristol': [bristol],
      });
      Future<void> chooseFrom(String query, String label) async {
        await _pump(tester, search, (value) => outcome = value, memory: memory);
        await tester.enterText(
          find.byKey(const Key('home-search-field')),
          query,
        );
        await tester.tap(find.byKey(const Key('home-search-submit')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(Key('home-search-result-$label')));
        await tester.pumpAndSettle();
      }

      await chooseFrom('bath', 'Bath, Somerset, England');
      await chooseFrom('bristol', 'Bristol, England');
      await chooseFrom('bath', 'Bath, Somerset, England');

      expect((outcome as HomeSearchDestination).choice.label, bath.label);
      expect(memory.recents.map((recent) => recent.label), ['Bath', 'Bristol']);
      expect(memory.recents.first.description, 'Bath, Somerset, England');
    });

    testWidgets('a search that was typed but not chosen from is not kept', (
      tester,
    ) async {
      final memory = PlaceMemory.inMemory();
      addTearDown(memory.dispose);
      await _pump(
        tester,
        _Search({
          'bath': [bath],
        }),
        (_) {},
        memory: memory,
      );
      await tester.enterText(
        find.byKey(const Key('home-search-field')),
        'bath',
      );
      await tester.tap(find.byKey(const Key('home-search-submit')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('home-search-circular-ride')));
      await tester.pumpAndSettle();
      expect(memory.recents, isEmpty);
    });

    testWidgets('choosing a recent place goes there and moves it to the top', (
      tester,
    ) async {
      final memory = PlaceMemory.inMemory();
      addTearDown(memory.dispose);
      await memory.remember(spot('Bath Spa', 51.1));
      await memory.remember(spot('Bakewell', 53.2));
      HomeSearchOutcome? outcome;
      await _pump(tester, _Search({}), (v) => outcome = v, memory: memory);

      await tester.tap(find.byKey(const Key('home-search-recent-1')));
      await tester.pumpAndSettle();

      final choice = (outcome as HomeSearchDestination).choice;
      expect(choice.label, 'Bath Spa');
      expect(choice.point.latitude, 51.1);
      expect(choice.place!.description, 'Bath Spa, Shire, England');
      expect(memory.recents.map((recent) => recent.label), [
        'Bath Spa',
        'Bakewell',
      ]);
    });

    testWidgets('can be cleared after asking, and saved places stay', (
      tester,
    ) async {
      final memory = PlaceMemory.inMemory();
      addTearDown(memory.dispose);
      await memory.setHome(spot('12 Example Road', 52));
      await memory.remember(spot('Bath Spa', 51.1));
      await _pump(tester, _Search({}), (_) {}, memory: memory);

      await tester.tap(find.byKey(const Key('home-search-clear-history')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('clear-search-history-dialog')),
        findsOneWidget,
      );
      await tester.tap(find.text('Keep'));
      await tester.pumpAndSettle();
      expect(memory.recents, hasLength(1), reason: 'asked, and said no');

      await tester.tap(find.byKey(const Key('home-search-clear-history')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('clear-search-history-confirm')));
      await tester.pumpAndSettle();
      expect(memory.recents, isEmpty);
      expect(memory.home, isNotNull);
      expect(find.text('Bath Spa'), findsNothing);
      expect(find.byKey(const Key('home-search-saved-home')), findsOneWidget);
    });

    testWidgets('one place can be removed from the history', (tester) async {
      final memory = PlaceMemory.inMemory();
      addTearDown(memory.dispose);
      await memory.remember(spot('Bath Spa', 51.1));
      await memory.remember(spot('Bakewell', 53.2));
      await _pump(tester, _Search({}), (_) {}, memory: memory);

      await tester.tap(find.byKey(const Key('home-search-recent-menu-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('home-search-recent-remove-0')));
      await tester.pumpAndSettle();
      expect(memory.recents.map((recent) => recent.label), ['Bath Spa']);
    });
  });

  group('saved places', () {
    testWidgets('choosing Home goes there, named Home, with its address', (
      tester,
    ) async {
      final memory = PlaceMemory.inMemory();
      addTearDown(memory.dispose);
      await memory.setHome(
        spot(
          '12 Example Road',
          52,
          description: '12 Example Road, Town, England',
        ),
      );
      HomeSearchOutcome? outcome;
      await _pump(tester, _Search({}), (v) => outcome = v, memory: memory);

      await tester.tap(find.byKey(const Key('home-search-saved-home')));
      await tester.pumpAndSettle();

      final choice = (outcome as HomeSearchDestination).choice;
      expect(choice.place!.label, 'Home');
      expect(choice.place!.description, '12 Example Road, Town, England');
      expect(choice.point.latitude, 52);
      expect(
        memory.recents,
        isEmpty,
        reason: 'Home is already at the top; it is not also history',
      );
    });

    testWidgets('a search result can be saved as Home', (tester) async {
      final memory = PlaceMemory.inMemory();
      addTearDown(memory.dispose);
      await _pump(
        tester,
        _Search({
          'bath': [bath],
        }),
        (_) {},
        memory: memory,
      );
      await tester.enterText(
        find.byKey(const Key('home-search-field')),
        'bath',
      );
      await tester.tap(find.byKey(const Key('home-search-submit')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(Key('home-search-save-${bath.label}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('save-place-as-home')));
      await tester.pumpAndSettle();

      expect(memory.home!.point.latitude, 51.38);
      expect(memory.home!.description, bath.label);
      expect(memory.recents, isEmpty, reason: 'saving is not choosing');
    });

    testWidgets('a search result can be saved under a name of the rider\'s '
        'own, and a bad name is explained', (tester) async {
      final memory = PlaceMemory.inMemory();
      addTearDown(memory.dispose);
      await memory.setWork(spot('Office', 52));
      await _pump(
        tester,
        _Search({
          'bath': [bath],
        }),
        (_) {},
        memory: memory,
      );
      await tester.enterText(
        find.byKey(const Key('home-search-field')),
        'bath',
      );
      await tester.tap(find.byKey(const Key('home-search-submit')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(Key('home-search-save-${bath.label}')));
      await tester.pumpAndSettle();
      expect(
        find.text('Work (replaces Work)'),
        findsOneWidget,
        reason: 'it says what saving over a set place does',
      );
      await tester.tap(find.byKey(const Key('save-place-as-other')));
      await tester.pumpAndSettle();

      Future<void> type(String name) async {
        await tester.enterText(
          find.byKey(const Key('saved-place-name-field')),
          name,
        );
        await tester.pump();
      }

      await type('work');
      expect(find.textContaining('Home and Work'), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(find.byKey(const Key('saved-place-name-save')))
            .onPressed,
        isNull,
      );
      await type('Spa weekend');
      await tester.tap(find.byKey(const Key('saved-place-name-save')));
      await tester.pumpAndSettle();

      expect(memory.custom.single.name, 'Spa weekend');
      expect(memory.custom.single.point.latitude, 51.38);
      expect(find.text('Spa weekend'), findsOneWidget);
    });

    testWidgets('Home can be set from a search, through the nested picker', (
      tester,
    ) async {
      final memory = PlaceMemory.inMemory();
      addTearDown(memory.dispose);
      final search = _Search({
        'bristol': [bristol],
      });
      await _pump(tester, search, (_) {}, memory: memory);
      await memory.remember(spot('Bath Spa', 51.1));
      await tester.pump();

      await tester.tap(find.byKey(const Key('home-search-add-home')));
      await tester.pumpAndSettle();
      expect(find.text('Set Home'), findsOneWidget);
      // The picker that chooses where Home points is a plain search: no saved
      // places and no history, so it cannot nest.
      expect(find.byKey(const Key('place-search-place-memory')), findsNothing);

      await tester.enterText(
        find.byKey(const Key('place-search-field')),
        'bristol',
      );
      await tester.tap(find.byKey(const Key('place-search-submit')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('place-search-result-${bristol.label}')));
      await tester.pumpAndSettle();

      expect(memory.home!.point.latitude, 51.45);
      expect(memory.home!.description, bristol.label);
      expect(
        memory.recents.map((recent) => recent.label),
        ['Bath Spa'],
        reason: 'a place chosen to be Home is not also a destination',
      );
    });

    testWidgets('Work can be set from the rider\'s current location', (
      tester,
    ) async {
      final memory = PlaceMemory.inMemory();
      addTearDown(memory.dispose);
      await _pump(
        tester,
        _Search({}),
        (_) {},
        memory: memory,
        currentPoint: const GeoPoint(latitude: 52.5, longitude: -1.5),
      );

      await tester.tap(find.byKey(const Key('home-search-add-work')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('place-search-current-location')));
      await tester.pumpAndSettle();

      expect(memory.work!.point.latitude, 52.5);
      expect(memory.work!.point.longitude, -1.5);
      expect(
        memory.work!.description,
        isNull,
        reason: '"Your location" is a placeholder, not an address',
      );
    });

    testWidgets('without a position the picker does not offer one', (
      tester,
    ) async {
      final memory = PlaceMemory.inMemory();
      addTearDown(memory.dispose);
      await _pump(
        tester,
        _Search({}),
        (_) {},
        memory: memory,
        hasPosition: false,
      );
      await tester.tap(find.byKey(const Key('home-search-add-work')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('place-search-field')), findsOneWidget);
      expect(
        find.byKey(const Key('place-search-current-location')),
        findsNothing,
      );
    });

    testWidgets('a place of the rider\'s own can be added, renamed, moved and '
        'deleted from its menu', (tester) async {
      final memory = PlaceMemory.inMemory();
      addTearDown(memory.dispose);
      final search = _Search({
        'bristol': [bristol],
      });
      await _pump(tester, search, (_) {}, memory: memory);

      // Add: name first, then where it is.
      await tester.tap(find.byKey(const Key('home-search-add-custom')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('saved-place-name-field')),
        'Campsite',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('saved-place-name-save')));
      await tester.pumpAndSettle();
      expect(find.text('Where is Campsite?'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('place-search-field')),
        'bristol',
      );
      await tester.tap(find.byKey(const Key('place-search-submit')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('place-search-result-${bristol.label}')));
      await tester.pumpAndSettle();
      final id = memory.custom.single.id;
      expect(memory.custom.single.name, 'Campsite');

      // Rename.
      await tester.tap(find.byKey(Key('home-search-saved-menu-$id')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('home-search-saved-rename-$id')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('saved-place-name-field')),
        'Lake campsite',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('saved-place-name-save')));
      await tester.pumpAndSettle();
      expect(memory.custom.single.name, 'Lake campsite');
      expect(find.text('Lake campsite'), findsOneWidget);

      // Move.
      search.results['bath'] = [bath];
      await tester.tap(find.byKey(Key('home-search-saved-menu-$id')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('home-search-saved-change-$id')));
      await tester.pumpAndSettle();
      expect(find.text('Move Lake campsite to'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('place-search-field')),
        'bath',
      );
      await tester.tap(find.byKey(const Key('place-search-submit')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('place-search-result-${bath.label}')));
      await tester.pumpAndSettle();
      expect(memory.custom.single.name, 'Lake campsite');
      expect(memory.custom.single.point.latitude, 51.38);

      // Delete, after asking.
      await tester.tap(find.byKey(Key('home-search-saved-menu-$id')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('home-search-saved-delete-$id')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Keep'));
      await tester.pumpAndSettle();
      expect(memory.custom, hasLength(1));
      await tester.tap(find.byKey(Key('home-search-saved-menu-$id')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('home-search-saved-delete-$id')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('delete-saved-place-confirm')));
      await tester.pumpAndSettle();
      expect(memory.custom, isEmpty);
    });

    testWidgets('Home and Work cannot be renamed, only moved or deleted', (
      tester,
    ) async {
      final memory = PlaceMemory.inMemory();
      addTearDown(memory.dispose);
      await memory.setHome(spot('12 Example Road', 52));
      await _pump(tester, _Search({}), (_) {}, memory: memory);

      await tester.tap(find.byKey(const Key('home-search-saved-menu-home')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('home-search-saved-change-home')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('home-search-saved-delete-home')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('home-search-saved-rename-home')),
        findsNothing,
      );
    });

    testWidgets('a recent place can be saved from its menu', (tester) async {
      final memory = PlaceMemory.inMemory();
      addTearDown(memory.dispose);
      await memory.remember(spot('Bath Spa', 51.1));
      await _pump(tester, _Search({}), (_) {}, memory: memory);

      await tester.tap(find.byKey(const Key('home-search-recent-menu-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('home-search-recent-save-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('save-place-as-work')));
      await tester.pumpAndSettle();

      expect(memory.work!.point.latitude, 51.1);
      expect(memory.recents, hasLength(1), reason: 'it stays in the history');
    });

    testWidgets('stops offering to add places at twelve', (tester) async {
      final memory = PlaceMemory.inMemory();
      addTearDown(memory.dispose);
      for (var index = 0; index < PlaceMemory.customLimit; index++) {
        await memory.addCustom(
          'Place $index',
          spot('Spot $index', 50.0 + index),
        );
      }
      await _pump(tester, _Search({}), (_) {}, memory: memory);
      expect(find.byKey(const Key('home-search-add-custom')), findsNothing);
    });
  });

  group('on the phone', () {
    testWidgets('the sheet opens the phone\'s own places and writes to them', (
      tester,
    ) async {
      final first = await PlaceMemory.open();
      await first.setHome(spot('12 Example Road', 52));
      first.dispose();

      await _pump(tester, _Search({}), (_) {});
      expect(find.byKey(const Key('home-search-saved-home')), findsOneWidget);

      // And what the rider does there is written back to the phone.
      await tester.tap(find.byKey(const Key('home-search-add-work')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('place-search-current-location')));
      await tester.pumpAndSettle();
      final reopened = await PlaceMemory.open();
      addTearDown(reopened.dispose);
      expect(reopened.work!.point.latitude, 51.0);
    });
  });
}

Future<void> _pump(
  WidgetTester tester,
  DestinationSearchService search,
  void Function(HomeSearchOutcome?) onResult, {
  PlaceMemory? memory,
  bool hasPosition = true,
  GeoPoint? currentPoint,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(useMaterial3: true),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async => onResult(
              await HomeDestinationSearchSheet.show(
                context,
                searchService: search,
                hasPosition: hasPosition,
                currentPoint: hasPosition
                    ? currentPoint ??
                          const GeoPoint(latitude: 51.0, longitude: -2.0)
                    : null,
                memory: memory,
              ),
            ),
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
