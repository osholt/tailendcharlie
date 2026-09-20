import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ride_relay/services/basemap_configuration.dart';
import 'package:ride_relay/services/flutter_vector_resource_cache.dart';
import 'package:ride_relay/services/flutter_vector_style.dart';
import 'package:ride_relay/services/map_style_repository.dart';

Map<String, dynamic> fixture() => {
  'version': 8,
  'sources': {
    'openmaptiles': {'type': 'vector', 'url': 'https://maps.test/planet'},
  },
  'layers': [
    for (final id in [
      'background',
      'provider-label',
      'tec-place-fuel',
      'tec-place-food',
    ])
      {
        'id': id,
        'type': 'background',
        'paint': {'background-color': '#000000'},
      },
  ],
};

void main() {
  for (final dark in [false, true]) {
    test(
      '${dark ? "dark" : "day"} cached build-99 style loses added business labels offline',
      () async {
        final directory = await Directory.systemTemp.createTemp('tec-pois');
        addTearDown(() => directory.delete(recursive: true));
        final configuration = BasemapConfiguration.fromEnvironment()
            .forBrightness(dark: dark);
        final cache = FlutterVectorResourceCache(directory);
        final key = FlutterVectorResourceCache.key(
          'presentation-v3:${configuration.styleUrl}:${configuration.restrainedLightStyle}:${configuration.dark}',
        );
        await cache.write(
          key,
          Uint8List.fromList(utf8.encode(jsonEncode(fixture()))),
        );
        await cache.write(
          FlutterVectorResourceCache.key('https://maps.test/planet'),
          Uint8List.fromList(
            utf8.encode(
              jsonEncode({
                'tiles': ['https://maps.test/{z}/{x}/{y}.pbf'],
                'minzoom': 0,
                'maxzoom': 14,
              }),
            ),
          ),
        );
        var requests = 0;
        final style = await readFlutterVectorStyle(
          configuration,
          resourceCache: cache,
          clientFactory: () => MockClient((_) async {
            requests++;
            throw const SocketException('offline');
          }),
        );
        expect(requests, 0);
        expect(style.theme.layers.map((l) => l.id), contains('provider-label'));
        expect(
          style.theme.layers.any((l) => l.id.startsWith('tec-place-')),
          false,
        );
        final cached = jsonDecode(utf8.decode((await cache.read(key))!));
        expect(
          (cached['layers'] as List).any(
            (l) => l['id'].startsWith('tec-place-'),
          ),
          false,
        );
      },
    );
  }

  test(
    'fresh provider styles keep their original layers without extra businesses',
    () async {
      final directory = await Directory.systemTemp.createTemp('tec-provider');
      addTearDown(() => directory.delete(recursive: true));
      final repository = MapStyleRepository(
        directory: directory,
        configuration: BasemapConfiguration.fromEnvironment(),
        client: MockClient(
          (_) async => http.Response(jsonEncode(fixture()), 200),
        ),
      );
      final resolved = await repository.resolve();
      final ids = (jsonDecode(resolved.style)['layers'] as List).map(
        (l) => l['id'],
      );
      expect(ids, ['background', 'provider-label']);
    },
  );

  test('custom providers are not rewritten using an unrelated POI schema', () {
    final style = fixture();
    MapStyleRepository.applyPresentation(
      style,
      const BasemapConfiguration(styleUrl: 'https://custom.test/style'),
    );
    expect((style['layers'] as List).length, 4);
  });
}
