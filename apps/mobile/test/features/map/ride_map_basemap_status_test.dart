import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as ml;
import 'package:ride_relay/domain/route_store.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/services/maplibre_offline_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
  final originalMapLibrePlatformFactory = ml.MapLibrePlatform.createInstance;
  late Directory directory;

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/maplibre_gl_0'),
          (_) async => null,
        );
    ml.MapLibrePlatform.createInstance = () {
      final platform = ml.MapLibreMethodChannel();
      unawaited(platform.initPlatform(0));
      return platform;
    };
  });

  tearDownAll(() {
    ml.MapLibrePlatform.createInstance = originalMapLibrePlatformFactory;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/maplibre_gl_0'),
          null,
        );
  });

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
    await tester.pump(const Duration(seconds: 11));
    await tester.pump();
  }

  for (final automatic in [true, false]) {
    testWidgets(
      'offline map preparation respects saved automatic=$automatic and completion',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          'automatic_offline_route_maps': automatic,
        });
        final manager = _OfflineManager();
        final cache = cacheFor(_mapLibre);
        addTearDown(cache.dispose);
        final route = ImportedRoute(
          id: 'offline',
          name: 'Offline test',
          importedAt: DateTime.utc(2026),
          sourceFileName: 'offline.gpx',
          paths: const [
            RoutePath(
              kind: RoutePathKind.track,
              points: [
                GeoPoint(latitude: 51, longitude: -1),
                GeoPoint(latitude: 51.01, longitude: -1),
              ],
            ),
          ],
          waypoints: const [],
        );
        await tester.pumpWidget(
          MaterialApp(
            home: RideMapScreen(
              routeStore: InMemoryRouteStore(route),
              routeImporter: RouteImporter(source: const _NoFileSource()),
              offlineTileCache: cache,
              mapLibreOfflineManager: manager,
              prepareOfflineMaps: true,
              rideStarted: false,
            ),
          ),
        );
        for (var i = 0; i < 5; i++) {
          await tester.pump();
        }
        expect(find.text('Offline map ready'), findsNothing);
        expect(manager.downloads, automatic ? 1 : 0);
        if (automatic) {
          expect(find.text('Downloading route map…'), findsOneWidget);
          manager.finished.complete(
            const TileDownloadSummary(
              totalTiles: 100,
              downloadedTiles: 100,
              reusedTiles: 0,
              downloadedBytes: 1024,
              cancelled: false,
            ),
          );
          for (var i = 0; i < 3; i++) {
            await tester.pump();
          }
          expect(find.text('Offline map ready'), findsOneWidget);
        } else {
          expect(find.text('Offline map not ready'), findsOneWidget);
          await tester.tap(find.byKey(const Key('offline-route-status')));
          await tester.pumpAndSettle();
          expect(
            tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
            isFalse,
          );
        }
        await unmount(tester);
      },
    );
  }

  testWidgets('changing day/night appearance reloads the map dependencies', (
    tester,
  ) async {
    final store = InMemoryRouteStore();
    final cache = cacheFor(_mapLibre);
    addTearDown(cache.dispose);
    var resolutions = 0;
    Future<void> show(BasemapConfiguration configuration) async {
      await tester.pumpWidget(
        MaterialApp(
          home: RideMapFeature(
            routeStore: store,
            offlineTileCache: cache,
            mapStyleString: MapStyleRepository.fallbackStyle,
            basemapConfiguration: configuration,
            onMapStyleResolved: (_) => resolutions++,
          ),
        ),
      );
      await tester.pump();
    }

    const day = BasemapConfiguration(
      styleUrl: 'https://example.test/day.json',
      darkStyleUrl: 'https://example.test/night.json',
      attribution: 'Test map',
    );
    await show(day);
    expect(resolutions, 1);
    await show(day.forBrightness(dark: true));
    expect(
      resolutions,
      2,
      reason: 'a theme change must not keep the previous resolved style',
    );
    await show(day.forBrightness(dark: false, restrainedLightStyle: false));
    expect(resolutions, 3);
    await unmount(tester);
  });

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

  test('a rejected native source refresh activates the route fallback', () {
    final source = File(
      'lib/features/map/ride_map_feature.dart',
    ).readAsStringSync();
    final recoveryStart = source.indexOf(
      'void _recoverFromMapLibreSourceFailure(Object error)',
    );
    final recoveryEnd = source.indexOf(
      '\n  Map<String, dynamic> _remainingRouteGeoJson()',
      recoveryStart,
    );
    final recovery = source.substring(recoveryStart, recoveryEnd);

    expect(recoveryStart, greaterThanOrEqualTo(0));
    expect(recoveryEnd, greaterThan(recoveryStart));
    expect(
      recovery,
      contains('setState(() => _mapLibreLayerPreparationFailed = true)'),
      reason:
          'the existing Flutter route renderer must replace the empty source',
    );
    expect(
      RegExp(r'_recoverFromMapLibreSourceFailure\(error\);').allMatches(source),
      hasLength(2),
      reason: 'both initial activation and later source updates must recover',
    );
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

class _OfflineManager extends MapLibreOfflineManager {
  _OfflineManager() : super(configuration: _mapLibre);
  final finished = Completer<TileDownloadSummary>();
  int downloads = 0;
  @override
  Future<bool> isRouteReady(ImportedRoute route) async => false;
  @override
  Future<TileDownloadSummary> downloadRouteRegion(
    ImportedRoute route, {
    int minimumZoom = 0,
    int maximumZoom = 18,
    int maximumTiles = 20000,
    int maximumBytes = 500 * 1024 * 1024,
    TileDownloadProgressCallback? onProgress,
    TileDownloadCancellationToken? cancellationToken,
  }) {
    downloads++;
    return finished.future;
  }
}
