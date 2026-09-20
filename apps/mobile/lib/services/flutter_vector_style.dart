import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart' as vmt;

import 'basemap_configuration.dart';
import 'map_style_repository.dart';

/// StyleReader accepts a URL only. Supply the same resolved document as the
/// native map, while leaving its source/sprite parsing to the library. The
/// scoped HTTP client avoids fetching the unmodified provider style again.
Future<vmt.Style> readFlutterVectorStyle(
  BasemapConfiguration configuration, {
  MapStyleResolution? resolution,
  http.Client Function()? clientFactory,
}) => _readFlutterVectorStyle(
  configuration,
  resolution: resolution,
  clientFactory: clientFactory,
).timeout(const Duration(seconds: 10));

Future<vmt.Style> _readFlutterVectorStyle(
  BasemapConfiguration configuration, {
  MapStyleResolution? resolution,
  http.Client Function()? clientFactory,
}) async {
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
  final resolved = resolution;
  return http.runWithClient(
    () => vmt.StyleReader(
      uri: configuration.styleUrl,
      httpHeaders: const {'User-Agent': 'me.osholt.ride_relay'},
    ).read(),
    () => _ResolvedStyleClient(
      configuration.styleUrl,
      resolved.style,
      (clientFactory ?? IOClient.new)(),
    ),
  );
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
