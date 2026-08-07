// The recap export's rider-facing behaviour (#157).
//
//   "The image export still isn't rendering map tiles and should have a toggle
//    for light and dark mode just for that image."
//
// The basemap itself is a MapLibre platform view and cannot be exercised here at
// all - a host test renders no platform view, so asserting tiles appear would be
// asserting nothing, which is how #141 went wrong three times. What *is* tested
// here is everything around it: the toggle is scoped to the image, a card with no
// basemap still exports, and a route-less ride does not fail.
//
// The one claim only a phone can settle - that the shared file contains tiles -
// is called out in the pull request rather than implied by a green test.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/distance_unit.dart';
import 'package:ride_relay/domain/imported_route.dart' show GeoPoint;
import 'package:ride_relay/features/ride/ride_recap_card.dart';
import 'package:ride_relay/features/ride/ride_recap_screen.dart';
import 'package:ride_relay/services/basemap_configuration.dart';
import 'package:ride_relay/services/ride_summary_exporter.dart';

void main() {
  final summary = RideSummary(
    rideId: 'ride',
    rideCode: '123456',
    displayName: 'Oliver',
    startedAt: DateTime.utc(2026, 7, 27, 9),
    endedAt: DateTime.utc(2026, 7, 27, 11),
    generatedAt: DateTime.utc(2026, 7, 27, 11),
    eventCount: 40,
    markerSessions: const [],
    riderCount: 3,
    totalDistanceMeters: 37670,
  );

  const route = [
    GeoPoint(latitude: 51.46, longitude: -2.5),
    GeoPoint(latitude: 51.47, longitude: -2.49),
    GeoPoint(latitude: 51.48, longitude: -2.47),
  ];

  Future<void> pumpScreen(
    WidgetTester tester, {
    List<GeoPoint> points = route,
    Brightness appBrightness = Brightness.dark,
    BasemapConfiguration basemap = const BasemapConfiguration(),
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: appBrightness),
        home: RideRecapScreen(
          summary: summary,
          routePoints: points,
          distanceUnit: DistanceUnit.miles,
          basemapConfiguration: basemap,
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('the export carries its own light/dark toggle', (tester) async {
    await pumpScreen(tester);

    expect(find.byKey(const Key('recap-brightness-toggle')), findsOneWidget);
    expect(find.text('Light'), findsOneWidget);
    expect(find.text('Dark'), findsOneWidget);
  });

  testWidgets('a light app starts the image light', (tester) async {
    await pumpScreen(tester, appBrightness: Brightness.light);

    expect(
      tester.widget<RideRecapCard>(find.byType(RideRecapCard)).dark,
      isFalse,
      reason: 'the first Share should do what the rider expects',
    );
  });

  testWidgets('a dark app starts the image dark', (tester) async {
    await pumpScreen(tester, appBrightness: Brightness.dark);

    expect(
      tester.widget<RideRecapCard>(find.byType(RideRecapCard)).dark,
      isTrue,
    );
  });

  testWidgets('the toggle changes the card and nothing else', (tester) async {
    await pumpScreen(tester, appBrightness: Brightness.dark);
    final themeBefore = Theme.of(
      tester.element(find.byType(RideRecapCard)),
    ).brightness;

    await tester.tap(find.text('Light'));
    await tester.pumpAndSettle();

    expect(
      tester.widget<RideRecapCard>(find.byType(RideRecapCard)).dark,
      isFalse,
      reason: 'the image follows the toggle',
    );
    expect(
      Theme.of(tester.element(find.byType(RideRecapCard))).brightness,
      themeBefore,
      reason: 'the app theme must not follow the image',
    );
  });

  testWidgets('an unconfigured basemap shows no attribution to claim', (
    tester,
  ) async {
    // A build with no style has no tiles and therefore no licence to display.
    await pumpScreen(tester, basemap: const BasemapConfiguration());

    final card = tester.widget<RideRecapCard>(find.byType(RideRecapCard));
    expect(card.basemapAttribution, isNull);
    expect(card.mapLayer, isNull);
    // And it still renders, rather than failing because there is no map.
    expect(find.byKey(const Key('share-recap-image-button')), findsOneWidget);
  });

  testWidgets('a route-less ride still exports', (tester) async {
    // #124: a ride with no route is valid, and its recap says so.
    await pumpScreen(tester, points: const []);

    expect(find.text('No recorded route for this ride'), findsOneWidget);
    expect(find.byKey(const Key('share-recap-image-button')), findsOneWidget);
    expect(
      tester.widget<RideRecapCard>(find.byType(RideRecapCard)).mapLayer,
      isNull,
      reason: 'nothing to frame a basemap around',
    );
  });

  testWidgets('a single-point ride is treated as route-less', (tester) async {
    await pumpScreen(
      tester,
      points: const [GeoPoint(latitude: 51.46, longitude: -2.5)],
    );

    expect(
      tester.widget<RideRecapCard>(find.byType(RideRecapCard)).mapLayer,
      isNull,
    );
  });

  testWidgets('an interactive map is not covered by a fixed route sketch', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RideRecapCard(
            summary: summary,
            routePoints: route,
            mapLayer: const ColoredBox(
              key: Key('interactive-recap-map'),
              color: Colors.blue,
            ),
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('interactive-recap-map')), findsOneWidget);
    expect(find.byKey(const Key('recap-route-sketch')), findsNothing);
  });

  testWidgets('configured recap uses a Flutter-rendered capture-safe map', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: RideRecapScreen(
          summary: summary,
          routePoints: route,
          basemapConfiguration: const BasemapConfiguration(
            styleUrl: 'https://example.com/style.json',
            darkStyleUrl: 'https://example.com/dark.json',
            attribution: 'Map data',
          ),
          mapBuilder: (key, paths, configuration, onReady, onFailure) =>
              ColoredBox(key: key, color: Colors.blue),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('recap-basemap-light')), findsOneWidget);
    expect(find.byKey(const Key('recap-route-sketch')), findsNothing);
    expect(find.text('Map data'), findsOneWidget);
  });

  testWidgets('a failed vector map falls back to the route outline', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: RideRecapScreen(
          summary: summary,
          routePoints: route,
          basemapConfiguration: const BasemapConfiguration(
            styleUrl: 'https://example.com/style.json',
            attribution: 'Map data',
          ),
          mapBuilder: (key, paths, configuration, onReady, onFailure) =>
              _FailingMap(key: key, onFailure: onFailure),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('recap-route-sketch')), findsOneWidget);
    expect(find.textContaining('shows the route outline only'), findsOneWidget);
    expect(find.text('Map data'), findsNothing);
  });

  // #364: a style that loads but whose tiles never arrive called neither
  // onReady nor onFailure, so the screen sat in "still loading" for ever.
  // Share refused every time with no end to it, which is the reported "the
  // export takes a really long time and then has no map".
  testWidgets('a basemap that never resolves stops blocking the export', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: RideRecapScreen(
          summary: summary,
          routePoints: route,
          basemapConfiguration: const BasemapConfiguration(
            styleUrl: 'https://example.com/style.json',
            attribution: 'Map data',
          ),
          // Reports neither ready nor failed, for as long as anyone waits.
          mapBuilder: (key, paths, configuration, onReady, onFailure) =>
              const SizedBox.shrink(),
        ),
      ),
    );
    await tester.pump();

    // Still waiting: the export is held back rather than shipping a blank map.
    expect(find.byKey(const Key('recap-route-sketch')), findsNothing);

    await tester.pump(const Duration(seconds: 13));
    await tester.pump();

    expect(find.byKey(const Key('recap-route-sketch')), findsOneWidget);
    expect(
      find.textContaining('did not finish loading in time'),
      findsOneWidget,
    );
    expect(find.text('Map data'), findsNothing);
  });
}

class _FailingMap extends StatefulWidget {
  const _FailingMap({super.key, required this.onFailure});

  final ValueChanged<Object> onFailure;

  @override
  State<_FailingMap> createState() => _FailingMapState();
}

class _FailingMapState extends State<_FailingMap> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => widget.onFailure(StateError('offline')),
    );
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}
