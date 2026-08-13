import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/services/approximate_place_index.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final index = ApproximatePlaceIndex.fromJson(
    jsonEncode({
      'schemaVersion': 1,
      'attribution': 'Test places',
      'places': [
        [5145000, -210000, 'Kingswood', 2],
        [5146000, -205000, 'Small hamlet', 5],
        [5146000, -204900, 'Larger town', 1],
        [5145800, -150000, 'Chippenham', 1],
      ],
    }),
  );

  test('finds the nearest settlement without a network service', () {
    expect(
      index.nearestName(const GeoPoint(latitude: 51.4501, longitude: -2.1001)),
      'Kingswood',
    );
  });

  test('uses prominence only to break a close-distance tie', () {
    expect(
      index.nearestName(const GeoPoint(latitude: 51.46, longitude: -2.0495)),
      'Larger town',
    );
  });

  test('labels a journey and a loop in riding order', () {
    const kingswood = GeoPoint(latitude: 51.45, longitude: -2.1);
    const chippenham = GeoPoint(latitude: 51.458, longitude: -1.5);

    expect(
      approximateEndpointLabel(index: index, start: kingswood, end: chippenham),
      'Kingswood to Chippenham',
    );
    expect(
      approximateEndpointLabel(index: index, start: kingswood, end: kingswood),
      'Kingswood loop',
    );
  });

  test('uses neutral copy outside the bundled Great Britain index', () {
    expect(
      approximateEndpointLabel(
        index: index,
        start: const GeoPoint(latitude: -33.86, longitude: 151.2),
        end: const GeoPoint(latitude: -33.9, longitude: 151.25),
      ),
      'Approximate places unavailable offline',
    );
  });

  test('rejects a malformed index', () {
    expect(
      () => ApproximatePlaceIndex.fromJson('{"schemaVersion":2}'),
      throwsFormatException,
    );
  });

  test('the bundled Great Britain index is packaged and readable', () async {
    final bundled = await ApproximatePlaceIndex.load();

    expect(
      bundled.nearestName(
        const GeoPoint(latitude: 51.44797, longitude: -2.52850),
      ),
      'Kingswood',
    );
    expect(
      bundled.nearestName(
        const GeoPoint(latitude: 51.45823, longitude: -2.11394),
      ),
      'Chippenham',
    );
    expect(bundled.attribution, contains('OS data'));
  });
}
