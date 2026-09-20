import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ride_relay/services/basemap_configuration.dart';
import 'package:ride_relay/services/flutter_vector_style.dart';
import 'package:ride_relay/services/map_style_repository.dart';

Map<String, dynamic> fixture() => {
  'version': 8,
  'sources': {
    'openmaptiles': {
      'type': 'vector',
      'url': 'https://maps.example.test/planet',
    },
  },
  'layers': [
    {
      'id': 'background',
      'type': 'background',
      'paint': {'background-color': '#000000'},
    },
  ],
};

void main() {
  for (final dark in [false, true]) {
    test(
      '${dark ? 'dark' : 'day'} map keeps useful POIs after offline reload',
      () async {
        final directory = await Directory.systemTemp.createTemp('tec-pois');
        addTearDown(() => directory.delete(recursive: true));
        final configuration = BasemapConfiguration.fromEnvironment()
            .forBrightness(dark: dark);
        var requests = 0;
        final repository = MapStyleRepository(
          directory: directory,
          configuration: configuration,
          client: MockClient((_) async {
            requests++;
            return http.Response(jsonEncode(fixture()), 200);
          }),
        );
        final first = await repository.resolve();
        final cached = await repository.resolve();
        expect(requests, 1);
        expect(cached.style, first.style);
        final layers = (jsonDecode(cached.style)['layers'] as List).cast<Map>();
        final fuel = layers.singleWhere(
          (layer) => layer['id'] == 'tec-place-fuel',
        );
        final food = layers.singleWhere(
          (layer) => layer['id'] == 'tec-place-food',
        );
        expect(fuel['source-layer'], 'poi');
        expect(fuel['minzoom'], 11);
        expect(food['minzoom'], 12);
        expect(jsonEncode(food['filter']), contains('cafe'));
        expect((food['layout'] as Map)['text-allow-overlap'], false);

        // Exercise the real Flutter style parser, with the exact native style.
        // A request for the raw provider style would regress both colour and POIs.
        final vectorStyle = await readFlutterVectorStyle(
          configuration,
          resolution: cached,
          clientFactory: () => MockClient((request) async {
            expect(request.url.toString(), 'https://maps.example.test/planet');
            return http.Response(
              jsonEncode({
                'tiles': ['https://maps.example.test/{z}/{x}/{y}.pbf'],
                'minzoom': 0,
                'maxzoom': 14,
              }),
              200,
            );
          }),
        );
        expect(
          vectorStyle.theme.layers.map((layer) => layer.id),
          containsAll(['tec-place-fuel', 'tec-place-food', 'tec-place-stops']),
        );
        expect(
          vectorStyle.theme.atZoom(11).layers.map((layer) => layer.id),
          contains('tec-place-fuel'),
        );
        expect(
          vectorStyle.theme.atZoom(11).layers.map((layer) => layer.id),
          isNot(contains('tec-place-food')),
        );
      },
    );
  }

  test('custom providers are not assigned an unrelated POI schema', () {
    final style = fixture();
    MapStyleRepository.applyPresentation(
      style,
      const BasemapConfiguration(
        styleUrl: 'https://maps.example.test/custom.json',
      ),
    );
    expect((style['layers'] as List).length, 1);
  });
}
