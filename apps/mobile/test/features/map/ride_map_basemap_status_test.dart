import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ride_relay/domain/route_store.dart';
import 'package:ride_relay/features/map/ride_map.dart';
import 'package:ride_relay/services/basemap_configuration.dart';
import 'package:ride_relay/services/gpx_import_source.dart';
import 'package:ride_relay/services/map_style_repository.dart';
import 'package:ride_relay/services/offline_tile_cache.dart';
import 'package:ride_relay/services/route_importer.dart';

/// The live ride map used to have no basemap failure handling at all, while the
/// recap screen had `_mapFailed`. A failed style and a working map of empty
/// countryside were the same picture, which is why the field report — "just a
/// blob or dot where you are and a tail where you been" — could not be
/// diagnosed from a screenshot (#281). These hold the map to saying which.
void main() {
  late Directory directory;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('ride-map-basemap-status');
  });

  tearDown(() => directory.deleteSync(recursive: true));

  OfflineTileCache cacheFor(BasemapConfiguration configuration) =>
      OfflineTileCache(
        rootDirectory: directory,
        configuration: configuration,
        httpClient: MockClient((_) async => http.Response('', 404)),
      );

  Future<void> pumpMap(
    WidgetTester tester, {
    required BasemapConfiguration configuration,
    required MapStyleOutcome outcome,
  }) async {
    final cache = cacheFor(configuration);
    addTearDown(cache.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: RideMapScreen(
          routeStore: InMemoryRouteStore(),
          routeImporter: RouteImporter(source: const _NoFileSource()),
          offlineTileCache: cache,
          mapStyleOutcome: outcome,
        ),
      ),
    );
    await tester.pump();
  }

  /// Every test tears the map down so the load watchdog cannot outlive it.
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }

  testWidgets('a style that could not be fetched says so on the map', (
    tester,
  ) async {
    await pumpMap(
      tester,
      configuration: _mapLibre,
      outcome: MapStyleOutcome.unavailable,
    );

    expect(find.text('NO MAP BACKGROUND'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('tapping the badge explains the fault in words', (tester) async {
    await pumpMap(
      tester,
      configuration: _mapLibre,
      outcome: MapStyleOutcome.unavailable,
    );

    await tester.tap(find.byKey(const Key('basemap-status-badge')));
    await tester.pump();

    expect(
      find.textContaining('could not be downloaded'),
      findsOneWidget,
      reason: 'a rider needs something they can repeat back to us',
    );

    await unmount(tester);
  });

  testWidgets('a build with no style configured keeps its route-only badge', (
    tester,
  ) async {
    // Unchanged behaviour: this one is a statement of design, not a failure,
    // and the wording riders already know is the wording they keep.
    await pumpMap(
      tester,
      configuration: const BasemapConfiguration(),
      outcome: MapStyleOutcome.unconfigured,
    );

    expect(find.text('ROUTE-ONLY OFFLINE MAP'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('a working basemap shows no badge, so empty stays empty', (
    tester,
  ) async {
    // The absence carries the meaning. A map with no roads and no badge is
    // countryside; before this it could equally have been a broken map.
    await pumpMap(
      tester,
      configuration: _mapLibre,
      outcome: MapStyleOutcome.live,
    );

    expect(find.byKey(const Key('basemap-status-badge')), findsNothing);

    await unmount(tester);
  });

  testWidgets('a map view that never loads the style is reported, but only '
      'after it has had its chance', (tester) async {
    await pumpMap(
      tester,
      configuration: _mapLibre,
      outcome: MapStyleOutcome.live,
    );

    // The platform view never calls back in a widget test, which is exactly
    // the condition being modelled. It must stay silent while a slow, cold
    // device could still get there.
    await tester.pump(const Duration(seconds: 7));
    expect(find.byKey(const Key('basemap-status-badge')), findsNothing);

    await tester.pump(const Duration(seconds: 2));
    expect(find.text('MAP DID NOT LOAD'), findsOneWidget);
    expect(
      find.byKey(const Key('ride-map-flutter-vector-fallback')),
      findsOneWidget,
      reason: 'route and rider overlays must recover from a blank native view',
    );

    await unmount(tester);
  });

  testWidgets('a style that never arrived is not blamed on the view', (
    tester,
  ) async {
    await pumpMap(
      tester,
      configuration: _mapLibre,
      outcome: MapStyleOutcome.unavailable,
    );

    await tester.pump(const Duration(seconds: 30));

    expect(find.text('NO MAP BACKGROUND'), findsOneWidget);
    expect(
      find.text('MAP DID NOT LOAD'),
      findsNothing,
      reason:
          'the view had nothing to load; blaming it misdirects the next '
          'investigation',
    );

    await unmount(tester);
  });
}

const _mapLibre = BasemapConfiguration(
  styleUrl: 'https://maps.example.test/styles/ride-relay.json',
  attribution: 'OpenFreeMap contributors',
);

class _NoFileSource implements GpxImportSource {
  const _NoFileSource();

  @override
  Future<PickedGpxFile?> pickGpxFile() async => null;
}
