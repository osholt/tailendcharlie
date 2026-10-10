// ignore_for_file: implementation_imports
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:ride_relay/features/map/ride_vector_tile_layer.dart';
import 'package:vector_map_tiles/src/cache/byte_storage.dart';
import 'package:vector_map_tiles/src/cache/storage_cache.dart';
import 'package:vector_map_tiles/src/executors/shared_executor.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart' as vmt;
import 'package:vector_tile_renderer/vector_tile_renderer.dart' as vtr;

class _RecordingStorage extends ByteStorage {
  final writes = <String>[];
  @override
  Future<void> write(String path, Uint8List bytes) async => writes.add(path);
  @override
  Future<Uint8List?> read(String path) async => null;
  @override
  Future<void> delete(String path) async {}
  @override
  Future<bool> exists(String key) async => false;
  @override
  Future<List<ByteStorageEntry>> list() async => const [];
}

class _EmptyTiles extends vmt.VectorTileProvider {
  final requested = <vmt.TileIdentity>[];

  @override
  Future<Uint8List> provide(vmt.TileIdentity tile) async {
    requested.add(tile);
    return Uint8List(0);
  }

  @override
  int get maximumZoom => 14;
  @override
  int get minimumZoom => 1;
  @override
  vmt.TileOffset get tileOffset => vmt.TileOffset.DEFAULT;
}

vmt.Style _style(_EmptyTiles provider) => vmt.Style(
  theme: vtr.ThemeReader().read({
    'version': 8,
    'layers': [
      {
        'id': 'background',
        'type': 'background',
        'paint': {'background-color': '#336699'},
      },
      {
        'id': 'water',
        'type': 'fill',
        'source': 'openmaptiles',
        'source-layer': 'water',
        'paint': {'fill-color': '#112233'},
      },
    ],
  }),
  providers: vmt.TileProviders({'openmaptiles': provider}),
);

void main() {
  group('defaultTileIsolates', () {
    test('keeps two cores for the UI and raster threads', () {
      expect(defaultTileIsolates(processors: 2), 2);
      expect(defaultTileIsolates(processors: 4), 2);
      expect(defaultTileIsolates(processors: 6), 3);
    });

    test('never grows past what drawing can spare', () {
      expect(defaultTileIsolates(processors: 8), 3);
      expect(defaultTileIsolates(processors: 16), 3);
    });
  });

  group('what the package would have persisted', () {
    test('the discarding storage keeps nothing', () async {
      final storage = DiscardingByteStorage();
      await storage.write('tile.pbf', Uint8List.fromList([1, 2, 3]));
      expect(await storage.read('tile.pbf'), isNull);
      expect(await storage.exists('tile.pbf'), isFalse);
      expect(await storage.list(), isEmpty);
    });

    testWidgets('a rendered tile is neither encoded nor written', (
      tester,
    ) async {
      final storage = _RecordingStorage();
      final cache = UnstoredImageCache(
        vtr.ThemeReader().read({'version': 8, 'layers': []}),
        StorageCache(storage, Duration.zero, 0),
      );
      final tile = vmt.TileIdentity(15, 1, 1);
      await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        ui.Canvas(recorder).drawColor(const Color(0xFF000000), BlendMode.src);
        final image = await recorder.endRecording().toImage(4, 4);
        await cache.put(tile, image);
        expect(await cache.retrieve(tile), isNull);
        image.dispose();
      });
      expect(
        storage.writes,
        isEmpty,
        reason: 'PNG-encoding and writing each tile cost a third of drawing it',
      );
    });
  });

  testWidgets('draws real tile images through the scheduler', (tester) async {
    final provider = _EmptyTiles();
    final controller = MapController();
    // The decoder isolates are shared and reference counted. Start them
    // outside the test's fake-async zone, whose timers never fire, so the
    // layer finds them running.
    await tester.runAsync(() async => acquireSharedExecutor(concurrency: 2));
    addTearDown(releaseSharedExecutor);
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 400,
          height: 400,
          child: FlutterMap(
            mapController: controller,
            options: const MapOptions(
              initialCenter: LatLng(51.45, -2.59),
              initialZoom: 12,
            ),
            children: [
              RideVectorTileLayer(
                style: _style(provider),
                maximumZoom: 18,
                isolates: 2,
                settleDelay: Duration.zero,
              ),
            ],
          ),
        ),
      ),
    );
    // Rendering runs on isolates and the engine's raster thread, which the
    // fake-async test clock cannot drive.
    await tester.runAsync(() async {
      for (var i = 0; i < 100 && provider.requested.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pump();
    expect(provider.requested, isNotEmpty);
    expect(tester.takeException(), isNull);
    expect(find.byType(RawImage), findsWidgets);

    // Leaving the map must release the isolates and images without error.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
