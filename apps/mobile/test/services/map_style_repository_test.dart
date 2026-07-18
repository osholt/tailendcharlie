import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ride_relay/services/basemap_configuration.dart';
import 'package:ride_relay/services/map_style_repository.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('ride-relay-style-test');
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test(
    'falls back to a local style when configured service is offline',
    () async {
      final repository = MapStyleRepository(
        directory: directory,
        configuration: _configuration,
        client: MockClient((_) async => throw const SocketException('offline')),
      );

      final style = jsonDecode(await repository.resolve()) as Map;

      expect(style['name'], 'Tail End Charlie offline fallback');
      expect(style['sources'], isEmpty);
    },
  );

  test('normalizes and caches relative style resources', () async {
    final repository = MapStyleRepository(
      directory: directory,
      configuration: _configuration,
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'version': 8,
            'sprite': './sprite',
            'glyphs': './fonts/{fontstack}/{range}.pbf',
            'sources': {
              'basemap': {
                'type': 'vector',
                'tiles': ['../tiles/basemap/{z}/{x}/{y}'],
              },
            },
            'layers': [],
          }),
          200,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );

    final style = jsonDecode(await repository.resolve()) as Map;
    final source = (style['sources'] as Map)['basemap'] as Map;

    expect(style['sprite'], 'https://maps.example.test/styles/sprite');
    expect(
      (source['tiles'] as List).single,
      'https://maps.example.test/tiles/basemap/{z}/{x}/{y}',
    );
    expect(await directory.list().where((item) => item is File).length, 1);
  });
}

const _configuration = BasemapConfiguration(
  styleUrl: 'https://maps.example.test/styles/ride-relay.json',
  attribution: '© OpenStreetMap contributors',
  cacheNamespace: 'open-map-v1',
  persistentCachingAllowed: true,
);
