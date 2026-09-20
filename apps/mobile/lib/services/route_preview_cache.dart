import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../domain/imported_route.dart';
import 'basemap_configuration.dart';

/// Rendered images, separate from the provider's tile cache. Geometry edits,
/// theme, colour and viewport changes produce a new immutable cache identity.
class RoutePreviewCache {
  RoutePreviewCache(this.directory, {this.maximumBytes = 64 * 1024 * 1024});
  final Directory directory;
  final int maximumBytes;
  Future<void> _writes = Future.value();
  static Future<RoutePreviewCache>? _default;
  static Future<RoutePreviewCache> openDefault() => _default ??= _open();
  static Future<RoutePreviewCache> _open() async {
    try {
      final support = await getApplicationSupportDirectory();
      return RoutePreviewCache(
        Directory(path.join(support.path, 'route_preview_images')),
      );
    } on Object {
      _default = null;
      rethrow;
    }
  }

  static String key({
    required List<List<GeoPoint>> paths,
    required BasemapConfiguration configuration,
    required int colourArgb,
    required int width,
    required int height,
    required double pixelRatio,
  }) => sha256
      .convert(
        utf8.encode(
          jsonEncode({
            'version': 1,
            'paths': [
              for (final points in paths)
                [
                  for (final point in points) [point.latitude, point.longitude],
                ],
            ],
            'style': configuration.styleUrl,
            'light': configuration.restrainedLightStyle,
            'attribution': configuration.attribution,
            'colour': colourArgb,
            'width': width,
            'height': height,
            'pixelRatio': pixelRatio,
          }),
        ),
      )
      .toString();

  File _file(String key) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(key)) {
      throw ArgumentError('Invalid preview cache key');
    }
    return File(path.join(directory.path, '$key.png'));
  }

  Future<Uint8List?> read(String key) async {
    final file = _file(key);
    try {
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      if (!_png(bytes)) {
        await file.delete();
        return null;
      }
      await file.setLastModified(DateTime.now());
      return bytes;
    } on FileSystemException {
      return null;
    }
  }

  Future<void> remove(String key) async {
    final file = _file(key);
    if (await file.exists()) await file.delete();
  }

  Future<void> save(String key, Uint8List bytes) {
    final operation = _writes.then((_) => _save(key, bytes));
    _writes = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> _save(String key, Uint8List bytes) async {
    if (!_png(bytes) ||
        bytes.length > 2 * 1024 * 1024 ||
        bytes.length > maximumBytes) {
      return;
    }
    await directory.create(recursive: true);
    final file = _file(key);
    final temporary = File('${file.path}.${const Uuid().v4()}.tmp');
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
    final files = <(File, FileStat)>[];
    await for (final entity in directory.list()) {
      if (entity is File && entity.path.endsWith('.png')) {
        files.add((entity, await entity.stat()));
      }
    }
    files.sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
    var total = files.fold(0, (sum, entry) => sum + entry.$2.size);
    for (final entry in files) {
      if (total <= maximumBytes) break;
      try {
        await entry.$1.delete();
        total -= entry.$2.size;
      } on FileSystemException {
        /* Cache eviction is best effort. */
      }
    }
  }

  static bool _png(Uint8List bytes) =>
      bytes.length >= 8 &&
      bytes[0] == 137 &&
      bytes[1] == 80 &&
      bytes[2] == 78 &&
      bytes[3] == 71 &&
      bytes[4] == 13 &&
      bytes[5] == 10 &&
      bytes[6] == 26 &&
      bytes[7] == 10;
}
