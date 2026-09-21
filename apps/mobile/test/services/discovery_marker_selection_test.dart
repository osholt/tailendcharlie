import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/services/discovery_marker_selection.dart';

DiscoveryMarkerCandidate<String> marker(String id, double lat, double lon) =>
    DiscoveryMarkerCandidate(
      id: id,
      point: GeoPoint(latitude: lat, longitude: lon),
      value: id,
    );
void main() {
  test('dense cafés cannot take the entire riding-road budget', () {
    final items = [
      for (var i = 0; i < 100; i++)
        DiscoveryMarkerCandidate(
          id: 'cafe-$i',
          group: 'cafes',
          point: GeoPoint(latitude: 50 + i * .01, longitude: -2),
          value: 'cafe-$i',
        ),
      const DiscoveryMarkerCandidate(
        id: 'road',
        group: 'roads',
        point: GeoPoint(latitude: 52, longitude: -2),
        value: 'road',
      ),
    ];
    expect(selectDiscoveryMarkers(items, zoom: 16), contains('road'));
    expect(selectDiscoveryMarkers(items, zoom: 16).length, 64);
  });
  test('sparse roads and cafés remain visible at regional zoom', () {
    final items = [marker('road', 51.5, -2.5), marker('cafe', 51.7, -2.3)];
    expect(
      selectDiscoveryMarkers(items, zoom: 10),
      unorderedEquals(['road', 'cafe']),
    );
    expect(selectDiscoveryMarkers(items, zoom: 5), isEmpty);
  });
  test('density suppresses close neighbours and zooming reveals them', () {
    final items = [
      marker('a', 51.5, -2.5),
      marker('b', 51.5005, -2.5005),
      marker('c', 51.7, -2.3),
    ];
    expect(selectDiscoveryMarkers(items, zoom: 10), ['a', 'c']);
    expect(selectDiscoveryMarkers(items, zoom: 18), ['a', 'b', 'c']);
    expect(selectDiscoveryMarkers(items.reversed, zoom: 10), ['a', 'c']);
  });
  test('only the viewport consumes the density budget; panning changes it', () {
    final items = [marker('a-offscreen', 50, -5), marker('b-here', 51.5, -2.5)];
    expect(
      selectDiscoveryMarkers(
        items,
        zoom: 10,
        maximumMarkers: 1,
        viewport: const [
          GeoPoint(latitude: 51.4, longitude: -2.6),
          GeoPoint(latitude: 51.6, longitude: -2.4),
        ],
      ),
      ['b-here'],
    );
    expect(
      selectDiscoveryMarkers(
        items,
        zoom: 10,
        viewport: const [
          GeoPoint(latitude: 49.9, longitude: -5.1),
          GeoPoint(latitude: 50.1, longitude: -4.9),
        ],
      ),
      ['a-offscreen'],
    );
  });
  test('native and Flutter map pixels produce the same physical spacing', () {
    final items = List.generate(20, (i) => marker('$i', 51.5 + i * .01, -2.5));
    expect(
      selectDiscoveryMarkers(items, zoom: 11, tileSize: 256),
      selectDiscoveryMarkers(items, zoom: 10, tileSize: 512),
    );
  });
  test(
    'dense catalogues have a bounded count and empty selections stay empty',
    () {
      final items = List.generate(200, (i) => marker('$i', 50 + i * .01, -2));
      expect(selectDiscoveryMarkers(items, zoom: 16).length, 64);
      expect(selectDiscoveryMarkers<String>([], zoom: 12), isEmpty);
    },
  );
}
