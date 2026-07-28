// Which catalogued roads a finished ride actually crossed (#159).
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/imported_route.dart' show GeoPoint;
import 'package:ride_relay/services/motorcycle_discovery.dart';
import 'package:ride_relay/services/ridden_road_matcher.dart';

/// A straight west-to-east line of [count] points starting at [longitude],
/// spaced roughly 100 m apart at this latitude, matching the catalogue's own
/// resampling interval.
List<GeoPoint> _line({
  required double latitude,
  required double longitude,
  required int count,
  double spacing = 0.0015,
}) => [
  for (var index = 0; index < count; index += 1)
    GeoPoint(latitude: latitude, longitude: longitude + index * spacing),
];

MotorcycleDiscoveryFeature _road({
  required String id,
  required List<GeoPoint> points,
  int? score = 90,
  MotorcycleDiscoveryCategory category =
      MotorcycleDiscoveryCategory.goodBikingRoad,
  String? sourceFeatureId,
}) => MotorcycleDiscoveryFeature(
  id: id,
  category: category,
  name: id,
  points: points,
  sourceName: 'OpenStreetMap via Geofabrik',
  sourceUrl: 'https://www.openstreetmap.org/way/1',
  confidence: 'medium',
  lastVerified: '2026-07-24',
  warning: 'Descriptive discovery hint only.',
  score: score,
  sourceFeatureId: sourceFeatureId,
);

void main() {
  const matcher = RiddenRoadMatcher();

  test('a ride crossing no catalogued road matches nothing', () {
    final catalogue = MotorcycleDiscoveryCatalogue([
      _road(
        id: 'far-away',
        points: _line(latitude: 55, longitude: -3, count: 40),
      ),
    ]);

    final matches = matcher.match(
      catalogue: catalogue,
      riddenTrack: _line(latitude: 51, longitude: 0, count: 40),
    );

    expect(matches, isEmpty);
  });

  test('a ride down the length of one road matches it', () {
    final geometry = _line(latitude: 52, longitude: -3, count: 40);
    final catalogue = MotorcycleDiscoveryCatalogue([
      _road(id: 'ridden', points: geometry),
    ]);

    final matches = matcher.match(catalogue: catalogue, riddenTrack: geometry);

    expect(matches.map((match) => match.feature.id), ['ridden']);
    expect(matches.single.matchedFraction, 1);
    expect(matches.single.riddenMeters, greaterThan(2000));
  });

  test('clipping a road at a junction is not riding it', () {
    // The track covers only the first few hundred metres of a 4 km road.
    final geometry = _line(latitude: 52, longitude: -3, count: 40);
    final catalogue = MotorcycleDiscoveryCatalogue([
      _road(id: 'clipped', points: geometry),
    ]);

    final matches = matcher.match(
      catalogue: catalogue,
      riddenTrack: _line(latitude: 52, longitude: -3, count: 4),
    );

    expect(matches, isEmpty);
  });

  test('a ride crossing many roads is capped at three, highest score first', () {
    final catalogue = MotorcycleDiscoveryCatalogue([
      for (final entry in {
        'score-60': 60,
        'score-99': 99,
        'score-72': 72,
        'score-85': 85,
        'score-40': 40,
      }.entries)
        _road(
          id: entry.key,
          score: entry.value,
          // Every road shares the ridden alignment, offset in latitude by less
          // than the corridor so each one matches.
          points: _line(
            latitude: 52 + entry.value * 0.0000001,
            longitude: -3,
            count: 40,
          ),
        ),
    ]);

    final matches = matcher.match(
      catalogue: catalogue,
      riddenTrack: _line(latitude: 52, longitude: -3, count: 40),
    );

    expect(matches.map((match) => match.feature.id), [
      'score-99',
      'score-85',
      'score-72',
    ]);
  });

  test('a road already put to the rider is not asked about again', () {
    final geometry = _line(latitude: 52, longitude: -3, count: 40);
    final catalogue = MotorcycleDiscoveryCatalogue([
      _road(id: 'answered', points: geometry, score: 99),
      _road(
        id: 'unanswered',
        points: _line(latitude: 52.000005, longitude: -3, count: 40),
        score: 80,
      ),
    ]);

    final matches = matcher.match(
      catalogue: catalogue,
      riddenTrack: geometry,
      excludedFeatureIds: const {'answered'},
    );

    expect(matches.map((match) => match.feature.id), ['unanswered']);
  });

  test('an unscored pass ranks with the best rather than last', () {
    final geometry = _line(latitude: 52, longitude: -3, count: 40);
    final catalogue = MotorcycleDiscoveryCatalogue([
      _road(id: 'road-95', points: geometry, score: 95),
      _road(
        // A summit node halfway along the ridden alignment.
        id: 'summit',
        points: [GeoPoint(latitude: 52.0000005, longitude: -3 + 20 * 0.0015)],
        score: null,
        category: MotorcycleDiscoveryCategory.mountainPass,
      ),
    ]);

    final matches = matcher.match(catalogue: catalogue, riddenTrack: geometry);

    expect(matches.map((match) => match.feature.id), ['summit', 'road-95']);
  });

  test('a track with fewer than two fixes matches nothing', () {
    final catalogue = MotorcycleDiscoveryCatalogue([
      _road(id: 'road', points: _line(latitude: 52, longitude: -3, count: 40)),
    ]);

    expect(matcher.match(catalogue: catalogue, riddenTrack: const []), isEmpty);
    expect(
      matcher.match(
        catalogue: catalogue,
        riddenTrack: [GeoPoint(latitude: 52, longitude: -3)],
      ),
      isEmpty,
    );
  });

  test('the catalogue reports its published release and stable source key', () {
    final catalogue = MotorcycleDiscoveryCatalogue.fromJson('''
{
 "type": "FeatureCollection",
 "properties": {"catalogueVersion": "uk-osm-2026-07-23-v1"},
 "features": [
  {
   "type": "Feature",
   "properties": {
    "id": "osm-good-biking-road-aaaa",
    "sourceFeatureId": "derived/osm-good-biking-road-aaaa",
    "category": "good_biking_road",
    "name": "B9078",
    "sourceName": "OpenStreetMap via Geofabrik",
    "sourceUrl": "https://www.openstreetmap.org/way/1",
    "confidence": "medium",
    "lastVerified": "2026-07-24",
    "warning": "Descriptive discovery hint only.",
    "score": 97
   },
   "geometry": {"type": "LineString", "coordinates": [[-3, 52], [-2.99, 52]]}
  }
 ]
}
''');

    expect(catalogue.version, 'uk-osm-2026-07-23-v1');
    expect(
      catalogue.features.single.sourceFeatureId,
      'derived/osm-good-biking-road-aaaa',
    );
  });

  test('a catalogue with no declared release says so rather than guessing', () {
    final catalogue = MotorcycleDiscoveryCatalogue.fromJson(
      '{"type":"FeatureCollection","features":[]}',
    );

    expect(catalogue.version, MotorcycleDiscoveryCatalogue.unknownVersion);
  });
}
