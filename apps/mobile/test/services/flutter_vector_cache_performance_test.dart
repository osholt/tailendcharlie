import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ride_relay/services/flutter_vector_resource_cache.dart';

class DelayedCache extends FlutterVectorResourceCache {
  DelayedCache(super.directory);
  final gate = Completer<void>();
  @override
  Future<void> write(String key, Uint8List bytes) async {
    await gate.future;
    await super.write(key, bytes);
  }
}

void main() {
  late Directory directory;
  setUp(
    () async => directory = await Directory.systemTemp.createTemp('tile-speed'),
  );
  tearDown(() async => directory.delete(recursive: true));
  test(
    'warm downloaded tiles avoid disk reads; RAM is bounded and clearable',
    () async {
      final cache = FlutterVectorResourceCache(
        directory,
        maximumMemoryBytes: 8,
      );
      final a = FlutterVectorResourceCache.key('a');
      final b = FlutterVectorResourceCache.key('b');
      await cache.write(a, Uint8List.fromList([1, 2, 3, 4]));
      await cache.file(a).delete();
      expect(await cache.read(a), [1, 2, 3, 4]);
      expect(await cache.containsOnDisk(a), false);
      await cache.write(b, Uint8List.fromList([5, 6, 7, 8, 9]));
      expect(
        await cache.read(a),
        isNull,
        reason: 'Oldest tile must be evicted within RAM budget',
      );
      await cache.clear();
      expect(await cache.read(b), isNull);
    },
  );
  test('concurrent cold reads share one disk operation', () async {
    final cache = FlutterVectorResourceCache(directory);
    final key = FlutterVectorResourceCache.key('tile');
    await cache.file(key).writeAsBytes([1, 2, 3]);
    final first = cache.read(key);
    expect(identical(first, cache.read(key)), true);
    expect(await first, [1, 2, 3]);
  });
  test(
    'ambient rendering does not await disk; offline download does',
    () async {
      for (final strict in [false, true]) {
        final cache = DelayedCache(directory);
        final client = CachedVectorHttpClient(
          MockClient((_) async => http.Response('tile-json', 200)),
          cache,
          requireWrite: strict,
        );
        var done = false;
        final response = client
            .get(Uri.parse('https://maps.test/source-$strict.json'))
            .then((value) {
              done = true;
              return value;
            });
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(done, !strict);
        cache.gate.complete();
        expect((await response).statusCode, 200);
        // Ambient writes were released separately from the rendering response.
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await cache.flushed;
        client.close();
      }
    },
  );
}
