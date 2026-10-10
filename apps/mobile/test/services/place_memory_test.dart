import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/imported_route.dart' show GeoPoint;
import 'package:ride_relay/domain/ride_plan.dart';
import 'package:ride_relay/services/place_memory.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #937: the places a rider chose before and the places they named.
///
/// Every coordinate here is synthetic; none is a rider's home or workplace.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  RidePlanPlace place(
    String label, {
    double latitude = 52,
    double longitude = -1,
    String? description,
  }) => RidePlanPlace(
    point: GeoPoint(latitude: latitude, longitude: longitude),
    label: label,
    description: description,
  );

  /// A distinct spot per index, so unrelated places are never "the same place".
  RidePlanPlace spot(int index, {String? label}) => place(
    label ?? 'Place $index',
    latitude: 52 + index * 0.01,
    description: '${label ?? 'Place $index'}, Shire, England',
  );

  final noon = DateTime.utc(2026, 10, 10, 12);

  group('recent places', () {
    test('newest first, each place once', () async {
      final memory = PlaceMemory.inMemory();
      addTearDown(memory.dispose);
      await memory.remember(spot(1), at: noon);
      await memory.remember(spot(2), at: noon.add(const Duration(minutes: 1)));
      await memory.remember(spot(3), at: noon.add(const Duration(minutes: 2)));
      expect(memory.recents.map((recent) => recent.label), [
        'Place 3',
        'Place 2',
        'Place 1',
      ]);

      await memory.remember(spot(1), at: noon.add(const Duration(hours: 1)));
      expect(memory.recents.map((recent) => recent.label), [
        'Place 1',
        'Place 3',
        'Place 2',
      ]);
      expect(memory.recents.first.usedAt, noon.add(const Duration(hours: 1)));
    });

    test(
      'the same words in another case or spacing are the same place',
      () async {
        final memory = PlaceMemory.inMemory();
        addTearDown(memory.dispose);
        await memory.remember(
          place('Bath', description: 'Bath, Somerset, England'),
        );
        await memory.remember(
          place(
            'BATH',
            latitude: 53,
            description: '  bath,  somerset,   england ',
          ),
        );
        expect(memory.recents, hasLength(1));
        expect(
          memory.recents.single.label,
          'BATH',
          reason: 'the newer wording',
        );
      },
    );

    test('the same spot under another name is the same place', () async {
      final memory = PlaceMemory.inMemory();
      addTearDown(memory.dispose);
      await memory.remember(place('The Old Mill'));
      await memory.remember(place('Mill Lane', latitude: 52.0001));
      expect(memory.recents.map((recent) => recent.label), ['Mill Lane']);

      await memory.remember(place('Elsewhere', latitude: 52.01));
      expect(memory.recents, hasLength(2), reason: 'a kilometre is not a spot');
    });

    test('keeps ten and drops the oldest', () async {
      final memory = PlaceMemory.inMemory();
      addTearDown(memory.dispose);
      for (var index = 0; index < 14; index++) {
        await memory.remember(spot(index));
      }
      expect(memory.recents, hasLength(PlaceMemory.recentLimit));
      expect(memory.recents.first.label, 'Place 13');
      expect(memory.recents.last.label, 'Place 4');
    });

    test('a place with no name is not kept', () async {
      final memory = PlaceMemory.inMemory();
      addTearDown(memory.dispose);
      await memory.remember(place('   '));
      expect(memory.recents, isEmpty);
    });

    test(
      'one can be forgotten and all can be cleared, saved places stay',
      () async {
        final memory = PlaceMemory.inMemory();
        addTearDown(memory.dispose);
        await memory.setHome(place('Home address'));
        for (var index = 0; index < 3; index++) {
          await memory.remember(spot(index));
        }
        await memory.forget(memory.recents[1]);
        expect(memory.recents.map((recent) => recent.label), [
          'Place 2',
          'Place 0',
        ]);

        await memory.clearRecents();
        expect(memory.recents, isEmpty);
        expect(memory.home, isNotNull);
      },
    );

    test('tells listeners each time the list changes', () async {
      final memory = PlaceMemory.inMemory();
      addTearDown(memory.dispose);
      var notified = 0;
      memory.addListener(() => notified += 1);
      await memory.remember(spot(1));
      await memory.clearRecents();
      await memory.clearRecents();
      expect(notified, 2, reason: 'clearing an empty list changes nothing');
    });
  });

  group('saved places', () {
    test('Home and Work are one each and are replaced, not added to', () async {
      final memory = PlaceMemory.inMemory();
      addTearDown(memory.dispose);
      await memory.setHome(spot(1));
      await memory.setWork(spot(2));
      await memory.setHome(spot(3));
      expect(memory.saved.map((saved) => saved.name), ['Home', 'Work']);
      expect(memory.home!.description, 'Place 3, Shire, England');
      expect(memory.home!.kind, SavedPlaceKind.home);
      expect(memory.home!.id, SavedPlace.homeId);
    });

    test(
      'lists Home, then Work, then the rider\'s own in the order added',
      () async {
        final memory = PlaceMemory.inMemory();
        addTearDown(memory.dispose);
        await memory.addCustom('Campsite', spot(1));
        await memory.setWork(spot(2));
        await memory.addCustom('Mum\'s', spot(3));
        await memory.setHome(spot(4));
        expect(memory.saved.map((saved) => saved.name), [
          'Home',
          'Work',
          'Campsite',
          "Mum's",
        ]);
      },
    );

    test('a saved place is named as the rider named it on the plan', () async {
      final memory = PlaceMemory.inMemory();
      addTearDown(memory.dispose);
      final home = await memory.setHome(
        place('12 Example Road', description: '12 Example Road, Town, England'),
      );
      final onPlan = home.toPlanPlace();
      expect(onPlan.label, 'Home');
      expect(onPlan.description, '12 Example Road, Town, England');
      expect(onPlan.point.latitude, 52);
    });

    test(
      'a dropped pin or the rider\'s own location has no address to keep',
      () async {
        final memory = PlaceMemory.inMemory();
        addTearDown(memory.dispose);
        final pin = await memory.setHome(place(RidePlanPlace.droppedPinLabel));
        final here = await memory.setWork(place(currentLocationPlaceLabel));
        expect(pin.description, isNull);
        expect(here.description, isNull);
      },
    );

    test('a label with no description is the address', () async {
      final memory = PlaceMemory.inMemory();
      addTearDown(memory.dispose);
      final saved = await memory.setHome(place('Costa, High Street'));
      expect(saved.description, 'Costa, High Street');
    });

    test('names are checked, and the reason is plain', () {
      final memory = PlaceMemory.inMemory();
      addTearDown(memory.dispose);
      expect(memory.nameProblem('   '), contains('name'));
      expect(memory.nameProblem('x' * 41), contains('40'));
      expect(memory.nameProblem('x' * 40), isNull);
      expect(memory.nameProblem('home'), contains('Home and Work'));
      expect(memory.nameProblem(' WORK '), contains('Home and Work'));
      expect(memory.nameProblem('Campsite'), isNull);
    });

    test('two places cannot share a name, in any case', () async {
      final memory = PlaceMemory.inMemory();
      addTearDown(memory.dispose);
      final campsite = await memory.addCustom('Campsite', spot(1));
      expect(memory.nameProblem('CAMPSITE'), contains('already'));
      expect(await memory.addCustom('campsite', spot(2)), isNull);
      expect(memory.custom, hasLength(1));
      expect(
        memory.nameProblem('campsite', exceptId: campsite!.id),
        isNull,
        reason: 'a place may keep its own name when it is renamed',
      );
    });

    test('keeps twelve of the rider\'s own', () async {
      final memory = PlaceMemory.inMemory();
      addTearDown(memory.dispose);
      for (var index = 0; index < PlaceMemory.customLimit; index++) {
        expect(await memory.addCustom('Place $index', spot(index)), isNotNull);
      }
      expect(memory.canAddCustom, isFalse);
      expect(await memory.addCustom('One more', spot(99)), isNull);
      expect(memory.custom, hasLength(PlaceMemory.customLimit));
      // Home and Work do not count against it.
      await memory.setHome(spot(50));
      await memory.setWork(spot(51));
      expect(memory.saved, hasLength(PlaceMemory.customLimit + 2));
    });

    test('a custom place can be renamed, Home and Work cannot', () async {
      final memory = PlaceMemory.inMemory();
      addTearDown(memory.dispose);
      await memory.setHome(spot(1));
      final campsite = (await memory.addCustom('Campsite', spot(2)))!;
      await memory.addCustom('Club', spot(3));

      expect(await memory.rename(campsite.id, '  Lake campsite '), isTrue);
      expect(memory.custom.first.name, 'Lake campsite');
      expect(memory.custom.first.point, campsite.point);
      expect(await memory.rename(campsite.id, 'club'), isFalse);
      expect(await memory.rename(campsite.id, ''), isFalse);
      expect(await memory.rename(SavedPlace.homeId, 'Base'), isFalse);
      expect(memory.home!.name, 'Home');
      expect(await memory.rename('missing', 'Anything'), isFalse);
    });

    test('a saved place can be moved without losing its name', () async {
      final memory = PlaceMemory.inMemory();
      addTearDown(memory.dispose);
      final campsite = (await memory.addCustom('Campsite', spot(2)))!;
      await memory.setWork(spot(3));

      expect(
        await memory.relocate(
          campsite.id,
          place('New field', latitude: 53, description: 'New field, Shire'),
        ),
        isTrue,
      );
      expect(memory.custom.single.name, 'Campsite');
      expect(memory.custom.single.id, campsite.id);
      expect(memory.custom.single.point.latitude, 53);
      expect(memory.custom.single.description, 'New field, Shire');

      expect(await memory.relocate(SavedPlace.workId, spot(9)), isTrue);
      expect(memory.work!.name, 'Work');
      expect(memory.work!.point.latitude, 52.09);
      expect(await memory.relocate('missing', spot(1)), isFalse);
    });

    test('any saved place can be deleted, and Home can be set again', () async {
      final memory = PlaceMemory.inMemory();
      addTearDown(memory.dispose);
      await memory.setHome(spot(1));
      final campsite = (await memory.addCustom('Campsite', spot(2)))!;
      await memory.delete(SavedPlace.homeId);
      await memory.delete(campsite.id);
      await memory.delete('missing');
      expect(memory.saved, isEmpty);
      await memory.setHome(spot(3));
      expect(memory.home!.description, 'Place 3, Shire, England');
    });
  });

  group('filtering as the rider types', () {
    late PlaceMemory memory;

    setUp(() async {
      memory = PlaceMemory.inMemory();
      await memory.setHome(
        place('12 Example Road', description: '12 Example Road, Town, England'),
      );
      await memory.addCustom('Campsite', spot(1, label: 'Lakeside Farm'));
      await memory.remember(spot(2, label: 'Bath Spa'));
      await memory.remember(spot(3, label: 'Bakewell'));
    });

    tearDown(() => memory.dispose());

    test('an empty query is everything', () {
      expect(memory.savedMatching(''), hasLength(2));
      expect(memory.savedMatching('   '), hasLength(2));
      expect(memory.recentsMatching(''), hasLength(2));
    });

    test('matches the name or the address, in any case', () {
      expect(memory.savedMatching('hom').map((saved) => saved.name), ['Home']);
      expect(memory.savedMatching('EXAMPLE').map((saved) => saved.name), [
        'Home',
      ]);
      expect(memory.savedMatching('lakeside').map((saved) => saved.name), [
        'Campsite',
      ]);
      expect(memory.recentsMatching('spa').map((recent) => recent.label), [
        'Bath Spa',
      ]);
    });

    test('every word has to be there, in any order', () {
      expect(memory.recentsMatching('spa bath'), hasLength(1));
      expect(memory.recentsMatching('bath bakewell'), isEmpty);
      expect(memory.recentsMatching('shire'), hasLength(2));
    });

    test('nothing matching is an empty list, not a search', () {
      expect(memory.savedMatching('zzz'), isEmpty);
      expect(memory.recentsMatching('zzz'), isEmpty);
    });
  });

  group('on the phone', () {
    test('survives closing and opening again', () async {
      SharedPreferences.setMockInitialValues({});
      final memory = await PlaceMemory.open();
      await memory.setHome(
        place('12 Example Road', description: '12 Example Road, Town'),
      );
      await memory.addCustom('Campsite', spot(1));
      await memory.remember(spot(2), at: noon);
      await memory.remember(spot(3), at: noon.add(const Duration(hours: 1)));
      memory.dispose();

      final again = await PlaceMemory.open();
      addTearDown(again.dispose);
      expect(again.saved.map((saved) => saved.name), ['Home', 'Campsite']);
      expect(again.home!.description, '12 Example Road, Town');
      expect(again.custom.single.point.latitude, 52.01);
      expect(again.recents.map((recent) => recent.label), [
        'Place 3',
        'Place 2',
      ]);
      expect(again.recents.first.usedAt, noon.add(const Duration(hours: 1)));
    });

    test(
      'stores only where a place is, never when a track recorded it',
      () async {
        SharedPreferences.setMockInitialValues({});
        final memory = await PlaceMemory.open();
        await memory.remember(
          RidePlanPlace(
            point: GeoPoint(
              latitude: 52,
              longitude: -1,
              elevationMeters: 88,
              recordedAt: DateTime.utc(2026, 9, 1, 7, 30),
            ),
            label: 'Lay-by',
          ),
        );
        await memory.setHome(
          RidePlanPlace(
            point: GeoPoint(
              latitude: 52,
              longitude: -1,
              recordedAt: DateTime.utc(2026, 9, 1, 7, 30),
            ),
            label: 'Somewhere',
          ),
        );
        memory.dispose();

        final stored = (await SharedPreferences.getInstance()).getString(
          PlaceMemory.preferenceKey,
        )!;
        expect(stored, isNot(contains('recordedAt')));
        expect(stored, isNot(contains('elevation')));
        final decoded = jsonDecode(stored) as Map;
        expect(decoded['v'], 1);
      },
    );

    test('holds nothing under its key once it holds nothing', () async {
      SharedPreferences.setMockInitialValues({});
      final memory = await PlaceMemory.open();
      await memory.remember(spot(1));
      await memory.setHome(spot(2));
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.containsKey(PlaceMemory.preferenceKey), isTrue);
      await memory.clearRecents();
      await memory.delete(SavedPlace.homeId);
      expect(preferences.containsKey(PlaceMemory.preferenceKey), isFalse);
      memory.dispose();
    });

    test('opens empty from a document it cannot read', () async {
      for (final broken in ['not json', '[]', '{"saved": 3}', '']) {
        SharedPreferences.setMockInitialValues({
          PlaceMemory.preferenceKey: broken,
        });
        final memory = await PlaceMemory.open();
        addTearDown(memory.dispose);
        expect(memory.isEmpty, isTrue, reason: broken);
      }
    });

    test('skips what it cannot make sense of and keeps the rest', () async {
      SharedPreferences.setMockInitialValues({
        PlaceMemory.preferenceKey: jsonEncode({
          'v': 1,
          'recents': [
            {
              'label': 'Good',
              'point': {'latitude': 52, 'longitude': -1},
              'usedAt': '2026-10-10T12:00:00Z',
            },
            {
              'label': 'Off the map',
              'point': {'latitude': 95, 'longitude': -1},
              'usedAt': '2026-10-10T12:00:00Z',
            },
            {
              'label': '',
              'point': {'latitude': 52, 'longitude': -1},
            },
            'rubbish',
          ],
          'saved': [
            {
              'id': 'home',
              'kind': 'home',
              'name': 'Home',
              'point': {'latitude': 52, 'longitude': -1},
            },
            {
              'id': 'home',
              'kind': 'home',
              'name': 'Home again',
              'point': {'latitude': 53, 'longitude': -1},
            },
            {
              'id': 'impostor',
              'kind': 'work',
              'name': 'Work',
              'point': {'latitude': 52, 'longitude': -1},
            },
            {
              'id': 'x',
              'kind': 'teleporter',
              'name': 'Nope',
              'point': {'latitude': 52, 'longitude': -1},
            },
            {
              'id': 'custom-1',
              'kind': 'custom',
              'name': 'Campsite',
              'point': {'latitude': 52.5, 'longitude': -1},
            },
          ],
        }),
      });
      final memory = await PlaceMemory.open();
      addTearDown(memory.dispose);
      expect(memory.recents.map((recent) => recent.label), ['Good']);
      expect(memory.saved.map((saved) => saved.name), ['Home', 'Campsite']);
      expect(memory.home!.point.latitude, 52, reason: 'the first Home wins');
    });
  });
}
