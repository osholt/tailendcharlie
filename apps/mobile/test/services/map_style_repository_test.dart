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

  test(
    'repaints the fetched dark style toward a more legible palette',
    () async {
      final repository = MapStyleRepository(
        directory: directory,
        configuration: _darkConfiguration,
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'version': 8,
              'sources': <String, Object?>{},
              'layers': [
                {
                  'id': 'background',
                  'type': 'background',
                  'paint': {'background-color': 'rgb(12,12,12)'},
                },
                {
                  'id': 'highway_minor',
                  'type': 'line',
                  'paint': {'line-color': '#181818', 'line-opacity': 0.9},
                },
                {'id': 'unrelated_layer', 'type': 'fill', 'paint': {}},
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          ),
        ),
      );

      final style = jsonDecode(await repository.resolve()) as Map;
      final layers = (style['layers'] as List).cast<Map>();
      final background = layers.singleWhere((l) => l['id'] == 'background');
      final minor = layers.singleWhere((l) => l['id'] == 'highway_minor');
      final unrelated = layers.singleWhere((l) => l['id'] == 'unrelated_layer');

      expect(
        (background['paint'] as Map)['background-color'],
        isNot('rgb(12,12,12)'),
      );
      expect((minor['paint'] as Map)['line-color'], isNot('#181818'));
      expect((minor['paint'] as Map)['line-opacity'], 0.9);
      expect(unrelated['paint'], isEmpty);
    },
  );

  test('does not repaint the day style', () async {
    final repository = MapStyleRepository(
      directory: directory,
      configuration: _configuration,
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'version': 8,
            'sources': <String, Object?>{},
            'layers': [
              {
                'id': 'background',
                'type': 'background',
                'paint': {'background-color': 'rgb(12,12,12)'},
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );

    final style = jsonDecode(await repository.resolve()) as Map;
    final background = (style['layers'] as List).cast<Map>().single;

    expect((background['paint'] as Map)['background-color'], 'rgb(12,12,12)');
  });
}

const _configuration = BasemapConfiguration(
  styleUrl: 'https://maps.example.test/styles/ride-relay.json',
  attribution: '© OpenStreetMap contributors',
  cacheNamespace: 'open-map-v1',
  persistentCachingAllowed: true,
);

const _darkConfiguration = BasemapConfiguration(
  styleUrl: 'https://maps.example.test/styles/dark.json',
  darkStyleUrl: 'https://maps.example.test/styles/dark.json',
  attribution: '© OpenStreetMap contributors',
  cacheNamespace: 'open-map-v1-dark',
  persistentCachingAllowed: true,
);
