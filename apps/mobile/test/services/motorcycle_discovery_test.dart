import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/services/motorcycle_discovery.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('loads the packaged free-roam discovery catalogue', () async {
    final catalogue = await MotorcycleDiscoveryCatalogue.loadAsset();

    expect(catalogue.features, isNotEmpty);
    expect(
      catalogue.features.any(
        (feature) =>
            feature.category == MotorcycleDiscoveryCategory.twistyHighlight,
      ),
      isTrue,
    );
  });

  test('parses, attributes, and bounds discovery features', () {
    const source = '''{
      "type":"FeatureCollection",
      "features":[{
        "type":"Feature",
        "properties":{
          "id":"pass-1","category":"mountain_pass","name":"Test pass",
          "sourceName":"OpenStreetMap","sourceUrl":"https://openstreetmap.org",
          "confidence":"high","lastVerified":"2026-07-22",
          "warning":"Not a safety endorsement."
        },
        "geometry":{"type":"Point","coordinates":[-3.1,52.0]}
      }]
    }''';
    final catalogue = MotorcycleDiscoveryCatalogue.fromJson(source);
    expect(catalogue.features.single.sourceName, 'OpenStreetMap');
    expect(
      catalogue.visible(
        categories: {MotorcycleDiscoveryCategory.mountainPass},
        west: -3.2,
        south: 51.9,
        east: -3,
        north: 52.1,
      ),
      hasLength(1),
    );
    expect(
      catalogue.visible(
        categories: {MotorcycleDiscoveryCategory.goodBikingRoad},
      ),
      isEmpty,
    );
  });

  test('rejects unrecognised categories', () {
    expect(
      () => MotorcycleDiscoveryCatalogue.fromJson(
        '{"type":"FeatureCollection","features":[{"properties":{"category":"race_track"},"geometry":{"type":"Point","coordinates":[0,0]}}]}',
      ),
      throwsFormatException,
    );
  });
}
