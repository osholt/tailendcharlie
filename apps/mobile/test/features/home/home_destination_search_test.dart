import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/imported_route.dart' show GeoPoint;
import 'package:ride_relay/domain/recorded_route_store.dart';
import 'package:ride_relay/features/home/home_destination_search.dart';
import 'package:ride_relay/features/home/home_screen.dart';
import 'package:ride_relay/services/road_routing.dart';
import 'package:ride_relay/services/gpx_import_source.dart';

void main() {
  group('destination route handoff (#546)', () {
    test('creates the solo ride before exposing its selected route', () async {
      final events = <String>[];

      await createRideThenStageDestinationRoute(
        createRide: () async => events.add('ride-created'),
        stageRoute: () => events.add('route-staged'),
      );

      expect(events, ['ride-created', 'route-staged']);
    });

    test('does not leave a stale route when ride creation fails', () async {
      var staged = false;

      await expectLater(
        createRideThenStageDestinationRoute(
          createRide: () => Future<void>.error(StateError('create failed')),
          stageRoute: () => staged = true,
        ),
        throwsStateError,
      );

      expect(staged, isFalse);
    });
  });

  test('a web plan can be saved without creating or starting a ride', () async {
    final routes = InMemoryRecordedRouteStore();
    final file = PickedGpxFile(
      name: 'web-plan.gpx',
      bytes: Uint8List.fromList(
        utf8.encode(
          '<gpx version="1.1"><trk><name>Web loop</name><trkseg>'
          '<trkpt lat="51.46" lon="-2.51"/>'
          '<trkpt lat="51.50" lon="-2.40"/>'
          '</trkseg></trk></gpx>',
        ),
      ),
    );

    final saved = await saveSharedRouteToLibrary(
      file: file,
      recordedRoutes: routes,
    );
    final savedAgain = await saveSharedRouteToLibrary(
      file: file,
      recordedRoutes: routes,
    );

    expect(saved.name, 'Web loop');
    expect(savedAgain.id, saved.id);
    expect(await routes.list(), hasLength(1));
  });

  group('search for a destination, then arrange the ride (#431)', () {
    testWidgets('a search finds places and picking one is the whole answer', (
      tester,
    ) async {
      final search = _FakeSearch({
        'bath': [
          DestinationMatch(
            label: 'Bath, Somerset',
            point: GeoPoint(latitude: 51.38, longitude: -2.36),
          ),
          DestinationMatch(
            label: 'Bath Road, Bristol',
            point: GeoPoint(latitude: 51.44, longitude: -2.58),
          ),
        ],
      });
      HomeSearchOutcome? outcome;

      await _pumpSheet(tester, search, (value) => outcome = value);

      // Nothing is searched until it is submitted. Nominatim's usage policy
      // forbids autocomplete against the public API, so a result appearing on
      // keystroke would be a licence problem, not a feature.
      await tester.enterText(
        find.byKey(const Key('home-search-field')),
        'bath',
      );
      await tester.pump();
      expect(find.text('Bath, Somerset'), findsNothing);
      expect(search.calls, isEmpty);

      await tester.tap(find.byKey(const Key('home-search-submit')));
      await tester.pumpAndSettle();

      expect(search.calls, ['bath']);
      expect(find.text('Bath, Somerset'), findsOneWidget);
      expect(find.text('Bath Road, Bristol'), findsOneWidget);

      await tester.tap(find.text('Bath, Somerset'));
      await tester.pumpAndSettle();

      // Straight back out with the place. Picking one used to open a second
      // sheet asking solo or group before a rider could see any route at all;
      // solo is assumed and riding with others is offered later, from the map
      // (#600).
      expect(find.text('Ride solo'), findsNothing);
      expect(find.text('Ride as a group'), findsNothing);

      final destination = outcome as HomeSearchDestination;
      expect(destination.choice.label, 'Bath, Somerset');
      expect(destination.choice.point.latitude, 51.38);
    });

    testWidgets('nothing found is said, not shown as an empty list', (
      tester,
    ) async {
      final search = _FakeSearch({'nowhere': const []});

      await _pumpSheet(tester, search, (_) {});
      await tester.enterText(
        find.byKey(const Key('home-search-field')),
        'nowhere',
      );
      await tester.tap(find.byKey(const Key('home-search-submit')));
      await tester.pumpAndSettle();

      // "Nothing found" and "not searched yet" look identical otherwise.
      expect(find.byKey(const Key('home-search-error')), findsOneWidget);
      expect(find.textContaining('Nothing found'), findsOneWidget);
    });

    testWidgets('a failed search says something a rider can act on', (
      tester,
    ) async {
      final search = _FailingSearch();

      await _pumpSheet(tester, search, (_) {});
      await tester.enterText(
        find.byKey(const Key('home-search-field')),
        'bath',
      );
      await tester.tap(find.byKey(const Key('home-search-submit')));
      await tester.pumpAndSettle();

      final message = tester
          .widget<Text>(find.byKey(const Key('home-search-error')))
          .data!;
      expect(message, isNot(contains('FormatException')));
      expect(message, contains('connection'));
    });
  });

  group('a route has to start somewhere', () {
    testWidgets('with no position, the sheet says so before any choice', (
      tester,
    ) async {
      final search = _FakeSearch({
        'bath': [
          DestinationMatch(
            label: 'Bath, Somerset',
            point: GeoPoint(latitude: 51.38, longitude: -2.36),
          ),
        ],
      });

      await _pumpSheet(tester, search, (_) {}, hasPosition: false);

      // Said up front rather than discovered as a failure after choosing solo or
      // group, which is the point at which it would be annoying.
      expect(
        find.byKey(const Key('home-search-needs-position')),
        findsOneWidget,
      );

      await tester.enterText(
        find.byKey(const Key('home-search-field')),
        'bath',
      );
      await tester.tap(find.byKey(const Key('home-search-submit')));
      await tester.pumpAndSettle();

      final row = tester.widget<ListTile>(
        find.byKey(const Key('home-search-result-Bath, Somerset')),
      );
      expect(row.enabled, isFalse);
    });
  });

  group('the other ways in are on the same surface', () {
    testWidgets('circular, planned-code, join-code and stored-route options', (
      tester,
    ) async {
      // #431 named these specifically: "entering a code to recall a planned ride
      // etc." They sit beside the search rather than behind it.
      final outcomes = <HomeSearchOutcome?>[];
      for (final key in [
        'home-search-circular-ride',
        'home-search-planned-code',
        'home-search-join-code',
        'home-search-stored-route',
      ]) {
        await _pumpSheet(tester, _FakeSearch(const {}), outcomes.add);
        expect(find.byKey(Key(key)), findsOneWidget);
        await tester.tap(find.byKey(Key(key)));
        await tester.pumpAndSettle();
      }

      expect(outcomes.map((outcome) => (outcome as HomeSearchHandoff).kind), [
        HomeSearchHandoffKind.circularRide,
        HomeSearchHandoffKind.plannedRouteCode,
        HomeSearchHandoffKind.joinWithCode,
        HomeSearchHandoffKind.storedRoute,
      ]);
    });
  });

  group('the search control is readable, not just an icon', () {
    testWidgets('the bar says where to', (tester) async {
      // #306: a bare magnifying glass is the failure that issue was raised over.
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: Scaffold(body: HomeSearchBar(onTap: () {})),
        ),
      );

      expect(find.byIcon(Icons.search), findsOneWidget);
      expect(find.text('Where to?'), findsOneWidget);
    });
  });
}

Future<void> _pumpSheet(
  WidgetTester tester,
  DestinationSearchService search,
  void Function(HomeSearchOutcome?) onResult, {
  bool hasPosition = true,
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

class _FakeSearch implements DestinationSearchService {
  _FakeSearch(this.results);

  final Map<String, List<DestinationMatch>> results;
  final List<String> calls = [];

  @override
  Future<List<DestinationMatch>> search(String query) async {
    calls.add(query);
    return results[query.toLowerCase()] ?? const [];
  }
}

class _FailingSearch implements DestinationSearchService {
  @override
  Future<List<DestinationMatch>> search(String query) async =>
      throw Exception('no route to host');
}
