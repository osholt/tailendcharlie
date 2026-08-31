import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/distance_unit.dart';
import 'package:ride_relay/services/road_jurisdiction.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the bundled layer resolves France road conventions offline', () async {
    final catalogue = await RoadJurisdictionCatalogue.load();

    final paris = catalogue.resolve(latitude: 48.8566, longitude: 2.3522);
    final corsica = catalogue.resolve(latitude: 42.0396, longitude: 9.0129);
    final franceSimulationStart = catalogue.resolve(
      latitude: 45.09125,
      longitude: 1.94011,
    );

    expect(paris?.countryCode, 'FR');
    expect(paris?.drivingSide, RoadDrivingSide.right);
    expect(paris?.distanceUnit, DistanceUnit.kilometres);
    expect(corsica?.countryCode, 'FR');
    expect(franceSimulationStart?.countryCode, 'FR');
  });

  test(
    'the bundled layer preserves UK conventions across the Channel',
    () async {
      final catalogue = await RoadJurisdictionCatalogue.load();

      final bristol = catalogue.resolve(latitude: 51.4545, longitude: -2.5879);

      expect(bristol?.countryCode, 'GB');
      expect(bristol?.drivingSide, RoadDrivingSide.left);
      expect(bristol?.distanceUnit, DistanceUnit.miles);
    },
  );

  test('polygon holes are excluded rather than treated as country surface', () {
    final catalogue = RoadJurisdictionCatalogue.parse('''
      {"type":"FeatureCollection","features":[{
        "type":"Feature",
        "properties":{"countryCode":"FR","name":"France","drivingSide":"right","distanceUnit":"kilometres"},
        "geometry":{"type":"Polygon","coordinates":[
          [[0,0],[10,0],[10,10],[0,10],[0,0]],
          [[4,4],[6,4],[6,6],[4,6],[4,4]]
        ]}
      }]}
    ''');

    expect(catalogue.resolve(latitude: 2, longitude: 2), isNotNull);
    expect(catalogue.resolve(latitude: 5, longitude: 5), isNull);
  });
}
