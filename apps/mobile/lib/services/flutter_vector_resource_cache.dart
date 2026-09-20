import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart' as vtr;

/// The Flutter renderer cannot read MapLibre's native offline database. Cache
/// its actual HTTP resources (TileJSON, sprites and PBFs) by URL, so downloaded
/// resources and live rendering use exactly the same keys.
class FlutterVectorResourceCache {
  FlutterVectorResourceCache(
    this.directory, {
    this.maximumBytes = 1024 * 1024 * 1024,
  });
  final Directory directory;
  final int maximumBytes;
  Future<void> _writes = Future.value();
  int? _bytes;
  static final Map<String, Future<FlutterVectorResourceCache>> _instances = {};

  static Future<FlutterVectorResourceCache> open(String namespace) =>
      _instances.putIfAbsent(namespace, () async {
        final support = await getApplicationSupportDirectory();
        final result = FlutterVectorResourceCache(
          Directory(
            path.join(support.path, 'flutter_vector_offline', key(namespace)),
          ),
        );
        await result.directory.create(recursive: true);
        return result;
      });

  static String key(String value) =>
      sha256.convert(utf8.encode(value)).toString();
  File file(String key) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(key)) {
      throw ArgumentError('Invalid cache key');
    }
    return File(path.join(directory.path, key));
  }

  Future<Uint8List?> read(String resourceKey) async {
    try {
      final bytes = await file(resourceKey).readAsBytes();
      return bytes.isEmpty ? null : bytes;
    } on FileSystemException {
      return null;
    }
  }

  Future<void> write(String resourceKey, Uint8List data) {
    final operation = _writes.then((_) async {
      if (data.isEmpty || data.length > 16 * 1024 * 1024) {
        throw const FileSystemException('Invalid or oversized map resource');
      }
      await directory.create(recursive: true);
      if (_bytes == null) {
        var size = 0;
        await for (final entry in directory.list()) {
          if (entry is File) size += await entry.length();
        }
        _bytes = size;
      }
      final target = file(resourceKey);
      final previous = await target.exists() ? await target.length() : 0;
      if (_bytes! - previous + data.length > maximumBytes) {
        throw const FileSystemException(
          'Offline map storage is full. Clear downloaded maps before retrying.',
        );
      }
      final temporary = File('${target.path}.tmp');
      await temporary.writeAsBytes(data, flush: true);
      await temporary.rename(target.path);
      _bytes = _bytes! - previous + data.length;
    });
    _writes = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> clear() async {
    await _writes;
    if (await directory.exists()) await directory.delete(recursive: true);
    await directory.create(recursive: true);
    _bytes = 0;
  }
}

class CachedVectorHttpClient extends http.BaseClient {
  CachedVectorHttpClient(
    this.inner,
    this.cache, {
    this.resources,
    this.requireWrite = false,
  });
  final http.Client inner;
  final FlutterVectorResourceCache cache;
  final Set<String>? resources;
  final bool requireWrite;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.method != 'GET') return inner.send(request);
    final key = FlutterVectorResourceCache.key(request.url.toString());
    final saved = await cache.read(key);
    if (saved != null) {
      resources?.add(key);
      return http.StreamedResponse(Stream.value(saved), 200);
    }
    final response = await inner
        .send(request)
        .timeout(const Duration(seconds: 15));
    final bytes = await response.stream.toBytes().timeout(
      const Duration(seconds: 15),
    );
    if (response.statusCode == 200 && bytes.isNotEmpty) {
      if (request.url.path.endsWith('.pbf') ||
          request.url.path.endsWith('.mvt')) {
        vtr.VectorTileReader().read(bytes);
      }
      try {
        await cache.write(key, bytes);
        resources?.add(key);
      } on FileSystemException {
        if (requireWrite) rethrow;
      }
    }
    return http.StreamedResponse(
      Stream.value(bytes),
      response.statusCode,
      headers: response.headers,
    );
  }

  @override
  void close() => inner.close();
}
