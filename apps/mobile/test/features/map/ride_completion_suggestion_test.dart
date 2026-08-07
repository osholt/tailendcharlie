import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/features/map/ride_map_feature.dart';
import 'package:ride_relay/services/basemap_configuration.dart';
import 'package:ride_relay/services/offline_tile_cache.dart';
import 'package:ride_relay/services/ride_completion_detector.dart';
import 'package:ride_relay/domain/route_store.dart';

/// #380: the arrival prompt arrived full screen and covered the map for the
/// last of the approach — the moment a rider still needs the navigation. It is
/// now a card in the bottom band with everything else, so the map stays visible
/// and the rider can ignore it.
void main() {
  const assessment = RideCompletionAssessment(
    routeProgressFraction: 0.94,
    minimumRouteProgressFraction: 0.9,
    destinationRadiusMeters: 90,
    riderCount: 4,
    freshRiderCount: 4,
    arrivedRiderCount: 4,
  );

  final route = ImportedRoute(
    id: 'r',
    name: 'Friday to the Ferry',
    importedAt: DateTime.utc(2026, 8, 7),
    sourceFileName: 'r.gpx',
    waypoints: const [],
    paths: const [
      RoutePath(
        kind: RoutePathKind.track,
        points: [
          GeoPoint(latitude: 51.45, longitude: -2.58),
          GeoPoint(latitude: 51.46, longitude: -2.57),
        ],
      ),
    ],
  );

  late Directory directory;
  setUp(() => directory = Directory.systemTemp.createTempSync('recap-tiles'));
  tearDown(() => directory.deleteSync(recursive: true));

  Future<void> pump(
    WidgetTester tester, {
    required ValueNotifier<RideCompletionAssessment?> suggestion,
    VoidCallback? onEnd,
    VoidCallback? onDismiss,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: RideMapFeature(
          routeStore: InMemoryRouteStore(route),
          offlineTileCache: OfflineTileCache(
            rootDirectory: directory,
            configuration: const BasemapConfiguration(
              styleUrl: 'https://127.0.0.1:1/style',
              attribution: 'OpenFreeMap contributors',
            ),
            httpClient: MockClient((_) async => http.Response('', 404)),
          ),
          mapStyleString:
              '{"version":8,"sources":{},"layers":'
              '[{"id":"background","type":"background"}]}',
          completionSuggestion: suggestion,
          onEndCompletedRide: onEnd,
          onDismissCompletionSuggestion: onDismiss,
        ),
      ),
    );
    await tester.pump();
    for (var frame = 0; frame < 5; frame += 1) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('the arrival suggestion never covers the map', (tester) async {
    final suggestion = ValueNotifier<RideCompletionAssessment?>(assessment);
    addTearDown(suggestion.dispose);
    await pump(tester, suggestion: suggestion);

    expect(find.byKey(const Key('ride-completion-suggestion')), findsOneWidget);
    // The thing that made this a bug: a dialog over the whole surface while
    // the rider still had navigating to do. MaterialApp carries a ModalBarrier
    // of its own, so the meaningful assertion is that no dialog was pushed.
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(Dialog), findsNothing);
    expect(find.text('Has everyone finished?'), findsOneWidget);
    expect(find.textContaining('4 of 4'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  // The rule the upper band exists for: on a mounted phone that is where the
  // rider reads the road ahead, so nothing that is not the ride menu, group
  // overview or speed sign is allowed to sit there.
  testWidgets('it stays out of the band where the road is read', (
    tester,
  ) async {
    final suggestion = ValueNotifier<RideCompletionAssessment?>(assessment);
    addTearDown(suggestion.dispose);
    await pump(tester, suggestion: suggestion);

    final card = tester.getRect(
      find.byKey(const Key('ride-completion-suggestion')),
    );
    final screen = tester.getRect(find.byType(RideMapScreen));
    expect(
      card.top,
      greaterThan(screen.center.dy),
      reason: 'card $card should sit below the middle of $screen',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('either answer reaches the ride, and it can be ignored', (
    tester,
  ) async {
    final suggestion = ValueNotifier<RideCompletionAssessment?>(assessment);
    addTearDown(suggestion.dispose);
    var ends = 0;
    var dismissals = 0;
    await pump(
      tester,
      suggestion: suggestion,
      onEnd: () => ends += 1,
      onDismiss: () => dismissals += 1,
    );

    await tester.tap(find.byKey(const Key('continue-completed-ride')));
    await tester.pump();
    expect(dismissals, 1);

    await tester.tap(find.byKey(const Key('confirm-completed-ride')));
    await tester.pump();
    expect(ends, 1);

    // Withdrawn by the ride — the group left the destination radius — takes the
    // card with it rather than leaving a stale question on the map.
    suggestion.value = null;
    await tester.pump();
    expect(find.byKey(const Key('ride-completion-suggestion')), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
