import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/services/biker_place_catalogue.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('loads the packaged web-planner catalogue', () async {
    final catalogue = await BikerPlaceCatalogue.loadAsset();

    expect(catalogue.places.length, greaterThan(250));
    expect(catalogue.checkedAt, '2026-07-22');
    expect(catalogue.places.every((place) => place.name.isNotEmpty), isTrue);
  });

  test('parses the shared web planner point-of-interest catalogue', () {
    final catalogue = BikerPlaceCatalogue.fromJson('''
      {
        "checkedAt": "2026-07-22",
        "sourceUrl": "https://example.com/catalogue",
        "places": [
          {
            "sourceId": 42,
            "name": "Rider Cafe",
            "address": "High Street",
            "latitude": 51.5,
            "longitude": -2.5,
            "source": "Bike + Brew 2026",
            "sourceUrl": "https://example.com/cafe"
          }
        ]
      }
    ''');

    expect(catalogue.checkedAt, '2026-07-22');
    expect(catalogue.places.single.id, '42');
    expect(catalogue.places.single.name, 'Rider Cafe');
    expect(catalogue.places.single.point.latitude, 51.5);
    expect(catalogue.places.single.point.longitude, -2.5);
  });

  test('rejects duplicate catalogue identifiers', () {
    expect(
      () => BikerPlaceCatalogue.fromJson('''
        {
          "places": [
            {"sourceId": 1, "name": "One", "latitude": 51, "longitude": -2},
            {"sourceId": 1, "name": "Two", "latitude": 52, "longitude": -1}
          ]
        }
      '''),
      throwsFormatException,
    );
  });

  test('limits the mobile preview to places around the route', () {
    const catalogue = BikerPlaceCatalogue(
      places: [
        BikerPlace(
          id: 'near',
          name: 'Near',
          address: '',
          point: GeoPoint(latitude: 51.5, longitude: -2.5),
          source: 'Test',
        ),
        BikerPlace(
          id: 'far',
          name: 'Far',
          address: '',
          point: GeoPoint(latitude: 55, longitude: -4),
          source: 'Test',
        ),
      ],
    );

    expect(
      catalogue
          .nearRoute(const [
            GeoPoint(latitude: 51.4, longitude: -2.6),
            GeoPoint(latitude: 51.6, longitude: -2.4),
          ])
          .map((place) => place.id),
      ['near'],
    );
  });
}
