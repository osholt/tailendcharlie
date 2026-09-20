import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart' as vmt;

import 'basemap_configuration.dart';
import 'map_style_repository.dart';
import 'flutter_vector_resource_cache.dart';

/// StyleReader accepts a URL only. Supply the same resolved document as the
/// native map, while leaving its source/sprite parsing to the library. The
/// scoped HTTP client avoids fetching the unmodified provider style again.
Future<vmt.Style> readFlutterVectorStyle(
  BasemapConfiguration configuration, {
  MapStyleResolution? resolution,
  http.Client Function()? clientFactory,
  FlutterVectorResourceCache? resourceCache,
  Set<String>? resources,
  bool requireWrite = false,
}) => _readFlutterVectorStyle(
  configuration,
  resolution: resolution,
  clientFactory: clientFactory,
  resourceCache: resourceCache,
  resources: resources,
  requireWrite: requireWrite,
).timeout(const Duration(seconds: 10));

Future<vmt.Style> _readFlutterVectorStyle(
  BasemapConfiguration configuration, {
  MapStyleResolution? resolution,
  http.Client Function()? clientFactory,
  FlutterVectorResourceCache? resourceCache,
  Set<String>? resources,
  bool requireWrite = false,
}) async {
  if (resourceCache == null && configuration.persistentCachingAllowed) {
    try {
      resourceCache = await FlutterVectorResourceCache.open(
        configuration.cacheNamespace,
      ).timeout(const Duration(seconds: 2));
    } on Object {
      if (requireWrite) rethrow;
    }
  }
  final cache = resourceCache;
  final styleKey = FlutterVectorResourceCache.key(
    'presentation-v3:${configuration.styleUrl}:${configuration.restrainedLightStyle}:${configuration.dark}',
  );
  if (resolution == null && cache != null) {
    final saved = await cache.read(styleKey);
    if (saved != null) {
      try {
        final document = utf8.decode(saved);
        jsonDecode(document);
        resolution = MapStyleResolution(document, MapStyleOutcome.cached);
      } on Object {
        /* Refetch a corrupt style. */
      }
    }
  }
  if (resolution == null) {
    final repository = await MapStyleRepository.openDefault(configuration);
    try {
      resolution = await repository.resolve();
    } finally {
      repository.dispose();
    }
  }
  if (!resolution.hasBasemap) {
    throw StateError('The basemap style is unavailable.');
  }
  final document = Map<String, dynamic>.from(
    jsonDecode(resolution.style) as Map,
  );
  MapStyleRepository.applyPresentation(document, configuration);
  resolution = MapStyleResolution(jsonEncode(document), resolution.outcome);
  if (cache != null) {
    try {
      await cache.write(
        styleKey,
        Uint8List.fromList(utf8.encode(resolution.style)),
      );
      resources?.add(styleKey);
    } on Object {
      if (requireWrite) rethrow;
    }
  }
  final resolved = resolution;
  http.Client client() {
    final inner = (clientFactory ?? IOClient.new)();
    return cache == null
        ? inner
        : CachedVectorHttpClient(
            inner,
            cache,
            resources: resources,
            requireWrite: requireWrite,
          );
  }

  Future<T> scoped<T>(Future<T> Function() operation) =>
      http.runWithClient(operation, client);
  final style = await http.runWithClient(
    () => vmt.StyleReader(
      uri: configuration.styleUrl,
      httpHeaders: const {'User-Agent': 'me.osholt.ride_relay'},
    ).read(),
    () =>
        _ResolvedStyleClient(configuration.styleUrl, resolved.style, client()),
  );
  if (requireWrite &&
      jsonDecode(resolved.style)['sprite'] != null &&
      style.sprites == null) {
    throw StateError('Map symbols were not downloaded. Retry when connected.');
  }
  return vmt.Style(
    name: style.name,
    theme: style.theme,
    center: style.center,
    zoom: style.zoom,
    providers: vmt.TileProviders({
      for (final entry in style.providers.tileProviderBySource.entries)
        entry.key: _CachedProvider(entry.value, scoped),
    }),
    sprites: style.sprites == null
        ? null
        : vmt.SpriteStyle(
            index: style.sprites!.index,
            atlasProvider: () => scoped(style.sprites!.atlasProvider),
          ),
  );
}

class _CachedProvider extends vmt.VectorTileProvider {
  _CachedProvider(this.inner, this.scoped);
  final vmt.VectorTileProvider inner;
  final Future<T> Function<T>(Future<T> Function()) scoped;
  @override
  Future<Uint8List> provide(vmt.TileIdentity tile) =>
      scoped(() => inner.provide(tile));
  @override
  int get maximumZoom => inner.maximumZoom;
  @override
  int get minimumZoom => inner.minimumZoom;
  @override
  vmt.TileOffset get tileOffset => inner.tileOffset;
  @override
  vmt.TileProviderType get type => inner.type;
}

class _ResolvedStyleClient extends http.BaseClient {
  _ResolvedStyleClient(this.url, this.style, this.inner);
  final String url;
  final String style;
  final http.Client inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (request.url.toString() == url) {
      return Future.value(
        http.StreamedResponse(
          Stream.value(utf8.encode(style)),
          200,
          headers: {'content-type': 'application/json'},
        ),
      );
    }
    return inner.send(request);
  }

  @override
  void close() => inner.close();
}
