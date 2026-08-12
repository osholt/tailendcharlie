// The end-of-ride road rating card (#159).
//
// The two things a rider must be able to see before answering - that it is
// optional and that it is anonymous - are asserted from the rendered widgets, not
// from a constant, so a copy edit that buried either one fails here. The card
// must also never stand between the rider and sharing, the recap or filing.

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/distance_unit_controller.dart';
import 'package:ride_relay/controllers/ride_controller.dart';
import 'package:ride_relay/controllers/road_rating_controller.dart';
import 'package:ride_relay/data/in_memory_event_store.dart';
import 'package:ride_relay/data/in_memory_session_store.dart';
import 'package:ride_relay/domain/completed_ride_store.dart';
import 'package:ride_relay/domain/imported_route.dart' show GeoPoint;
import 'package:ride_relay/domain/ride_session.dart';
import 'package:ride_relay/features/ride/ended_ride_screen.dart';
import 'package:ride_relay/features/ride/road_rating_card.dart';
import 'package:ride_relay/internet/internet_relay_client.dart';
import 'package:ride_relay/services/motorcycle_discovery.dart';
import 'package:ride_relay/services/nearby_bridge.dart';
import 'package:ride_relay/services/road_rating.dart';
import 'package:ride_relay/services/road_rating_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _now = DateTime.utc(2026, 7, 28, 18);

List<GeoPoint> _line({double latitude = 52, int count = 40}) => [
  for (var index = 0; index < count; index += 1)
    GeoPoint(latitude: latitude, longitude: -3 + index * 0.0015),
];

MotorcycleDiscoveryCatalogue _catalogue({int roads = 1}) =>
    MotorcycleDiscoveryCatalogue([
      for (var index = 0; index < roads; index += 1)
        MotorcycleDiscoveryFeature(
          id: 'road-$index',
          category: MotorcycleDiscoveryCategory.goodBikingRoad,
          name: 'Bwlch y Groes $index',
          points: _line(latitude: 52 + index * 0.0000005),
          sourceName: 'OpenStreetMap via Geofabrik',
          sourceUrl: 'https://www.openstreetmap.org/way/1',
          confidence: 'medium',
          lastVerified: '2026-07-24',
          warning: 'Descriptive discovery hint only.',
          score: 99 - index,
          sourceFeatureId: 'derived/road-$index',
        ),
    ], version: 'uk-osm-2026-07-23-v1');

Future<RoadRatingController> _ratings({int roads = 1}) async =>
    RoadRatingController(
      store: await RoadRatingStore.openDefault(),
      loadCatalogue: () async => _catalogue(roads: roads),
      clock: () => _now,
      random: Random(7),
    );

String _visibleText(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((text) => text.data)
    .whereType<String>()
    .join(' ');

void main() {
  late RideController controller;
  late InMemoryCompletedRideStore archive;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    archive = InMemoryCompletedRideStore();
    var id = 0;
    controller = RideController(
      InMemoryEventStore(),
      InMemorySessionStore(),
      NearbyBridge(),
      clock: () => DateTime.utc(2026, 7, 28, 12),
      idFactory: () => 'id-${id++}',
      random: Random(7),
      rideCodeDirectory: _OfflineRideCodeDirectory(),
      completedRideStore: archive,
    );
    await controller.initialize();
    await controller.createRide('Lead');
    await controller.startRide();
    await controller.endRide();
  });

  tearDown(() => controller.dispose());

  Future<void> pumpCard(
    WidgetTester tester,
    RoadRatingController ratings, {
    List<GeoPoint>? track,
  }) async {
    await ratings.prepare(riddenTrack: track ?? _line());
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: RoadRatingCard(controller: ratings)),
      ),
    );
  }

  testWidgets('a ride crossing no catalogued road shows no card', (
    tester,
  ) async {
    final ratings = await _ratings();
    addTearDown(ratings.dispose);

    await pumpCard(tester, ratings, track: const []);

    expect(find.byKey(const Key('road-rating-card')), findsNothing);
    expect(find.byKey(const Key('road-rating-yes-button')), findsNothing);
  });

  testWidgets('the rider is told it is optional and anonymous before answering', (
    tester,
  ) async {
    final ratings = await _ratings();
    addTearDown(ratings.dispose);

    await pumpCard(tester, ratings);

    // Visible on the same card as the buttons, above them, not behind a link.
    expect(find.byKey(const Key('road-rating-disclosure')), findsOneWidget);
    final copy = _visibleText(tester).toLowerCase();
    expect(copy, contains('optional'));
    expect(copy, contains('anonymous'));
    // And it says what is not sent, in the rider's words rather than a schema's.
    expect(copy, contains('no name'));
    expect(copy, contains('no ride'));
    expect(find.byKey(const Key('road-rating-yes-button')), findsOneWidget);
    expect(find.byKey(const Key('road-rating-no-button')), findsOneWidget);
  });

  testWidgets('one tap answers a road and moves to the next', (tester) async {
    final ratings = await _ratings(roads: 3);
    addTearDown(ratings.dispose);
    await pumpCard(tester, ratings);

    expect(find.text('1 of 3'), findsOneWidget);
    expect(find.text('Bwlch y Groes 0'), findsOneWidget);

    await tester.tap(find.byKey(const Key('road-rating-yes-button')));
    await tester.pumpAndSettle();

    expect(find.text('2 of 3'), findsOneWidget);
    expect(find.text('Bwlch y Groes 1'), findsOneWidget);
    expect(ratings.pendingCount, 1);
  });

  testWidgets('skipping is one tap and sends nothing', (tester) async {
    final ratings = await _ratings(roads: 2);
    addTearDown(ratings.dispose);
    await pumpCard(tester, ratings);

    await tester.tap(find.byKey(const Key('road-rating-skip-button')));
    await tester.pumpAndSettle();

    expect(find.text('2 of 2'), findsOneWidget);
    expect(ratings.pendingCount, 0);
  });

  testWidgets('not now dismisses the card entirely', (tester) async {
    final ratings = await _ratings(roads: 3);
    addTearDown(ratings.dispose);
    await pumpCard(tester, ratings);

    await tester.tap(find.byKey(const Key('road-rating-dismiss-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('road-rating-card')), findsNothing);
  });

  testWidgets('the card never claims an answer was sent when it was not', (
    tester,
  ) async {
    final ratings = await _ratings();
    addTearDown(ratings.dispose);
    await pumpCard(tester, ratings);

    await tester.tap(find.byKey(const Key('road-rating-yes-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('road-rating-done')), findsOneWidget);
    final copy = _visibleText(tester);
    expect(copy, contains('saved on this phone'));
    expect(copy, isNot(contains('have been sent')));
  });

  testWidgets('the way out is on screen without scrolling past the cards (#440)', (
    tester,
  ) async {
    // The reported defect: "the summary screen appears and there is no way back
    // to the map. No button dismisses it. Sharing the ride and the ride image
    // both work."
    //
    // Both halves of that are explained by list order. The exit was eighth, below
    // the relay status cards and this rating card; the shares were seventh and
    // eighth-from-last. A test that supplies none of those three cards has the
    // exit on screen and passes, which is why one did.
    //
    // So this pumps the screen the way a real ride has it — with a card that grows
    // — on a phone-sized viewport, and asserts the exit is reachable without
    // scrolling.
    tester.view.physicalSize = const Size(1170, 2532); // iPhone 13
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final ratings = await _ratings(roads: 3);
    addTearDown(ratings.dispose);
    // Prepared here rather than by the screen: the screen's own `_prepareRatings`
    // returns early when it is already prepared, and the ride in `setUp` has no
    // position events to build a track from.
    await ratings.prepare(riddenTrack: _line());

    await tester.pumpWidget(
      MaterialApp(
        home: EndedRideScreen(
          controller: controller,
          distanceUnits: DistanceUnitController.forLocale(
            const Locale('en', 'GB'),
          ),
          roadRatings: ratings,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The card must actually be there, or this test is asserting nothing.
    expect(find.byKey(const Key('road-rating-card')), findsOneWidget);

    final exit = find.byKey(const Key('leave-ended-ride-button'));
    expect(exit, findsOneWidget);

    final screen = tester.getRect(find.byType(EndedRideScreen));
    final button = tester.getRect(exit);
    expect(
      button.bottom,
      lessThanOrEqualTo(screen.bottom),
      reason: 'the way out must not be below the fold on a phone',
    );
    expect(
      button.top,
      greaterThanOrEqualTo(screen.top),
      reason: 'nor above it',
    );

    // And it is above the card, not after it: a card that grows must never be
    // able to push the exit off again.
    expect(
      button.top,
      lessThan(tester.getRect(find.byKey(const Key('road-rating-card'))).top),
    );

    // It says where it goes. #426 made home a free-roam map, and the report was
    // that there was no way back to the map.
    expect(find.text('Back to the map'), findsOneWidget);
  });

  testWidgets('the rating card does not gate sharing, the recap or filing', (
    tester,
  ) async {
    final ratings = await _ratings(roads: 3);
    addTearDown(ratings.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: EndedRideScreen(
          controller: controller,
          distanceUnits: DistanceUnitController.forLocale(
            const Locale('en', 'GB'),
          ),
          roadRatings: ratings,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Share ride summary'), findsOneWidget);
    expect(
      find.byKey(const Key('share-recap-image-entry-button')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('file-ended-ride-button')), findsOneWidget);
  });

  testWidgets('an answer survives the ride being filed and removed', (
    tester,
  ) async {
    final ratings = await _ratings();
    addTearDown(ratings.dispose);
    await pumpCard(tester, ratings);

    await tester.tap(find.byKey(const Key('road-rating-yes-button')));
    await tester.pumpAndSettle();
    expect(ratings.pendingCount, 1);

    // Files the ride to the archive and clears the live working copy.
    await controller.clearEndedRide();
    expect(controller.session, isNull);
    expect(await archive.list(), hasLength(1));

    // Reopened from durable storage, not from the controller's memory.
    final reopened = await RoadRatingStore.openDefault();
    expect(reopened.pending, hasLength(1));
    expect(reopened.pending.single.featureId, 'road-0');
    expect(reopened.pending.single.verdict, RoadRatingVerdict.worthIncluding);
  });

  testWidgets('a road already answered is not asked about on the next ride', (
    tester,
  ) async {
    final first = await _ratings(roads: 2);
    addTearDown(first.dispose);
    await pumpCard(tester, first);
    await tester.tap(find.byKey(const Key('road-rating-yes-button')));
    await tester.pumpAndSettle();

    final second = await _ratings(roads: 2);
    addTearDown(second.dispose);
    await second.prepare(riddenTrack: _line());

    expect(second.questions.map((road) => road.feature.id), ['road-1']);
  });
}

class _OfflineRideCodeDirectory implements RideCodeDirectory {
  @override
  Future<void> register(RideSession session) async {}

  @override
  Future<RideCodeCredentials> resolve(
    String rideCode, {
    String? joinToken,
  }) async => throw const RideCodeDirectoryException('Offline in tests.');

  @override
  void close() {}
}
