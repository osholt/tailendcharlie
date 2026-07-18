import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'basemap_configuration.dart';

class MapStyleRepository {
  MapStyleRepository({
    required this.directory,
    required this.configuration,
    http.Client? client,
    this.maximumStyleBytes = 2 * 1024 * 1024,
    this.refreshAfter = const Duration(hours: 24),
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null;

  static const fallbackStyle =
      '{"version":8,"name":"Tail End Charlie offline fallback","sources":{},'
      '"layers":[{"id":"background","type":"background",'
      '"paint":{"background-color":"#111820"}}]}';

  final Directory directory;
  final BasemapConfiguration configuration;
  final int maximumStyleBytes;
  final Duration refreshAfter;
  final http.Client _client;
  final bool _ownsClient;

  static Future<MapStyleRepository> openDefault(
    BasemapConfiguration configuration,
  ) async {
    final support = await getApplicationSupportDirectory();
    return MapStyleRepository(
      directory: Directory(path.join(support.path, 'map_styles')),
      configuration: configuration,
    );
  }

  Future<String> resolve() async {
    if (!configuration.usesMapLibre) return fallbackStyle;
    final cached = _cacheFile();
    final cachedStyle = await _readValid(cached);
    if (cachedStyle != null &&
        DateTime.now().difference(await cached.lastModified()) < refreshAfter) {
      return cachedStyle;
    }
    try {
      final style = await _downloadAndNormalize();
      if (configuration.persistentCachingAllowed) {
        await directory.create(recursive: true);
        final temporary = File('${cached.path}.tmp');
        await temporary.writeAsString(style, flush: true);
        if (await cached.exists()) await cached.delete();
        await temporary.rename(cached.path);
      }
      return style;
    } on Object {
      return cachedStyle ?? fallbackStyle;
    }
  }

  Future<String> _downloadAndNormalize() async {
    final styleUri = Uri.parse(configuration.styleUrl);
    final request = http.Request('GET', styleUri)
      ..headers['User-Agent'] = 'me.osholt.ride_relay';
    final response = await _client
        .send(request)
        .timeout(const Duration(seconds: 5));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw const FormatException('Map style request failed.');
    }
    final declaredLength = response.contentLength;
    if (declaredLength != null && declaredLength > maximumStyleBytes) {
      throw const FormatException('Map style is too large.');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.stream) {
      bytes.add(chunk);
      if (bytes.length > maximumStyleBytes) {
        throw const FormatException('Map style is too large.');
      }
    }
    final decoded = jsonDecode(utf8.decode(bytes.takeBytes()));
    if (decoded is! Map) throw const FormatException('Map style is invalid.');
    final style = Map<String, dynamic>.from(decoded);
    if (style['version'] != 8 ||
        style['sources'] is! Map ||
        style['layers'] is! List) {
      throw const FormatException('Map style is invalid.');
    }
    _normalizeResourceUrl(style, 'sprite', styleUri);
    _normalizeResourceUrl(style, 'glyphs', styleUri);
    final sources = Map<String, dynamic>.from(style['sources'] as Map);
    for (final entry in sources.entries) {
      if (entry.value is! Map) continue;
      final source = Map<String, dynamic>.from(entry.value as Map);
      _normalizeResourceUrl(source, 'url', styleUri);
      _normalizeResourceUrl(source, 'data', styleUri);
      final tiles = source['tiles'];
      if (tiles is List) {
        source['tiles'] = tiles
            .map(
              (value) => value is String ? _absolute(value, styleUri) : value,
            )
            .toList(growable: false);
      }
      sources[entry.key] = source;
    }
    style['sources'] = sources;
    return jsonEncode(style);
  }

  Future<String?> _readValid(File file) async {
    if (!await file.exists() || await file.length() > maximumStyleBytes) {
      return null;
    }
    try {
      final value = await file.readAsString();
      final decoded = jsonDecode(value);
      if (decoded is Map &&
          decoded['version'] == 8 &&
          decoded['sources'] is Map &&
          decoded['layers'] is List) {
        return value;
      }
    } on Object {
      // A damaged cache must never hide the locally rendered route.
    }
    return null;
  }

  File _cacheFile() {
    final digest = sha256.convert(utf8.encode(configuration.styleUrl));
    return File(path.join(directory.path, '$digest.json'));
  }

  static void _normalizeResourceUrl(
    Map<String, dynamic> target,
    String key,
    Uri base,
  ) {
    final value = target[key];
    if (value is String) target[key] = _absolute(value, base);
  }

  static String _absolute(String value, Uri base) {
    final parsed = Uri.tryParse(value);
    if (parsed == null || parsed.hasScheme || value.startsWith('/')) {
      return value.startsWith('/') ? _resolveTemplate(base, value) : value;
    }
    return _resolveTemplate(base, value);
  }

  static String _resolveTemplate(Uri base, String value) => base
      .resolve(value)
      .toString()
      .replaceAll('%7B', '{')
      .replaceAll('%7D', '}');

  void dispose() {
    if (_ownsClient) _client.close();
  }
}
