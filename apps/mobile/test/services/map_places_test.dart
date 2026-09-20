import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/services/basemap_configuration.dart';
import 'package:ride_relay/services/flutter_vector_resource_cache.dart';
import 'package:ride_relay/services/flutter_vector_style.dart';
import 'package:ride_relay/services/map_places.dart';
import 'package:ride_relay/services/map_style_repository.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart' as vmt;

// Minimal real MVT: three point features and an irrelevant shop, in tile units.
List<int> varint(int value) =>
    value < 128 ? [value] : [(value & 127) | 128, ...varint(value >> 7)];
List<int> field(int tag, List<int> bytes) => [
  ...varint(tag * 8 + 2),
  ...varint(bytes.length),
  ...bytes,
];
Uint8List fixture() {
  final values = [
    'fuel',
    'cafe',
    'parking',
    'shop',
    'Test station',
    'Test café',
  ];
  return Uint8List.fromList(
    field(3, [
      ...field(1, utf8.encode('poi')),
      for (var i = 0; i < 4; i++)
        ...field(2, [
          8,
          i + 1,
          ...field(2, [
            0,
            i,
            if (i < 2) ...[1, i + 4],
          ]),
          24,
          1,
          ...field(4, [9, ...varint(4096 + i * 200), ...varint(4096)]),
        ]),
      ...field(3, utf8.encode('class')),
      ...field(3, utf8.encode('name')),
      for (final value in values) ...field(4, field(1, utf8.encode(value))),
      40,
      ...varint(4096),
      120,
      2,
    ]),
  );
}

const corners = [
  GeoPoint(latitude: 51.45, longitude: -2.59),
  GeoPoint(latitude: 51.451, longitude: -2.589),
];

void main() {
  test('real point geometry, category, fallback label and tile projection', () {
    final places = decodeMapPlaces(fixture(), vmt.TileIdentity(1, 1, 1));
    expect(places.map((p) => p.kind), MapPlaceKind.values);
    expect(places.map((p) => p.name), ['Test station', 'Test café', 'parking']);
    expect(places.first.point.longitude, closeTo(90, 0.0001));
    expect(places.first.point.latitude, closeTo(-66.51326, 0.0001));
    expect(places.first.label, 'Fuel · Test station');
  });

  test('large views stay bounded and invalid views never enumerate tiles', () {
    final tiles = MapPlacesService.tilesFor(const [
      GeoPoint(latitude: 49, longitude: -6),
      GeoPoint(latitude: 60, longitude: 2),
    ]);
    expect(tiles.length, 64);
    expect(tiles.every((t) => t.z == 14), true);
    expect(tiles.toSet().length, 64);
    expect(MapPlacesService.tilesFor(corners).length, 1);
    expect(MapPlacesService.tilesFor(const []), isEmpty);
    expect(
      MapPlacesService.tilesFor(const [
        GeoPoint(latitude: 0, longitude: -179),
        GeoPoint(latitude: 1, longitude: 179),
      ]),
      isEmpty,
    );
  });

  test('overview visibility follows category zoom and avoids duplicates', () {
    final points = [
      for (var i = 0; i < 3; i++)
        MapPlace(
          id: '$i',
          name: '$i',
          kind: MapPlaceKind.values[i],
          point: GeoPoint(latitude: 51.45 + i * .02, longitude: -2.59),
        ),
    ];
    const bounds = [
      GeoPoint(latitude: 51.4, longitude: -2.7),
      GeoPoint(latitude: 51.6, longitude: -2.4),
    ];
    expect(selectMapPlaces(points, bounds, 10), isEmpty);
    expect(selectMapPlaces(points, bounds, 11).length, 1);
    expect(selectMapPlaces(points, bounds, 12).length, 2);
    expect(selectMapPlaces([...points, ...points], bounds, 13).length, 3);
    expect(selectMapPlaces(points, bounds, 14), isEmpty);
    expect(selectMapPlaces(points, corners, 13).length, 1);
  });

  test('z14 POIs appear at overview zoom and reopen with zero HTTP', () async {
    final dir = await Directory.systemTemp.createTemp('map-places');
    addTearDown(() => dir.delete(recursive: true));
    final config = BasemapConfiguration.fromEnvironment();
    var requests = 0, offline = false;
    final resolution = MapStyleResolution(
      jsonEncode({
        'version': 8,
        'sources': {
          'openmaptiles': {
            'type': 'vector',
            'url': 'https://maps.test/tiles.json',
          },
        },
        'layers': [
          {
            'id': 'bg',
            'type': 'background',
            'paint': {'background-color': '#fff'},
          },
        ],
      }),
      MapStyleOutcome.live,
    );
    Future<vmt.Style> load() => readFlutterVectorStyle(
      config,
      resolution: resolution,
      resourceCache: FlutterVectorResourceCache(dir),
      clientFactory: () => MockClient((request) async {
        requests++;
        if (offline) throw const SocketException('offline');
        if (request.url.path.endsWith('.json')) {
          return http.Response(
            jsonEncode({
              'tiles': ['https://maps.test/{z}/{x}/{y}.pbf'],
              'minzoom': 0,
              'maxzoom': 14,
            }),
            200,
          );
        }
        expect(request.url.path, startsWith('/14/'));
        return http.Response.bytes(fixture(), 200);
      }),
    );
    final first = await MapPlacesService(
      config,
      loadStyle: load,
    ).load(corners, keepGoing: () => true);
    expect(first.length, 3);
    final before = requests;
    offline = true;
    final reopened = MapPlacesService(config, loadStyle: load);
    expect(
      (await reopened.load(corners, keepGoing: () => true)).map((p) => p.id),
      first.map((p) => p.id),
    );
    expect(requests, before);
    expect(await reopened.load(corners, keepGoing: () => false), isEmpty);
  });

  test('unrelated providers are never queried using OMT schema', () async {
    final service = MapPlacesService(
      const BasemapConfiguration(styleUrl: 'https://custom.test/style'),
      loadStyle: () => throw StateError('must not load'),
    );
    expect(await service.load(corners, keepGoing: () => true), isEmpty);
  });
}
