import 'dart:math' as math;

import '../domain/geo_point.dart' as geo;
import '../domain/imported_route.dart' show GeoPoint;
import 'geo_calculations.dart';
import 'motorcycle_discovery.dart';
import 'trail_display_simplifier.dart';

/// One catalogued road the recorded track says the rider actually rode.
class RiddenRoad {
  const RiddenRoad({
    required this.feature,
    required this.matchedFraction,
    required this.riddenMeters,
  });

  final MotorcycleDiscoveryFeature feature;

  /// The share of the road's sampled length that ran inside the corridor.
  final double matchedFraction;

  /// [matchedFraction] expressed against the road's own length, which is what
  /// the "did they really ride it" threshold is applied to.
  final double riddenMeters;
}

/// Works out which catalogued roads a finished ride crossed (#159).
///
/// Deliberately conservative in both directions. Asking about a road the rider
/// only clipped at a junction produces a worthless answer, and asking about a
/// road they rode the length of but under-matched produces no answer at all, so
/// the test is "did a real stretch of this road run under the recorded track"
/// rather than "did the track come near it".
class RiddenRoadMatcher {
  const RiddenRoadMatcher({
    this.corridorMeters = 50,
    this.minimumRiddenMeters = 2000,
    this.shortRoadFraction = 0.6,
    this.maximumQuestions = 3,
    this.maximumCandidates = 80,
    this.samplesPerRoad = 24,
  }) : assert(corridorMeters > 0),
       assert(maximumQuestions > 0),
       assert(samplesPerRoad >= 2);

  /// How far from the recorded track a point on the road may sit and still count
  /// as ridden. 50 m absorbs ordinary GPS error and a dual carriageway's two
  /// halves without swallowing the next road over.
  final double corridorMeters;

  /// A rider has to have covered this much of a road before being asked about
  /// it. Every catalogued road is at least 2.5 km long, so this is the real
  /// gate: two kilometres is enough to have an opinion, and far more than a
  /// junction crossing or a hundred metres of shared alignment.
  final double minimumRiddenMeters;

  /// For a road shorter than [minimumRiddenMeters] - a reclassified pass, or a
  /// future catalogue with a lower length floor - this share of its length is
  /// asked for instead, so a short road is not unaskable.
  final double shortRoadFraction;

  /// The cap the issue asks for. Three questions, one tap each.
  final int maximumQuestions;

  /// A bound on the work done after the bounding-box prefilter, so a ride
  /// through a dense catalogue region cannot turn into an unbounded scan.
  final int maximumCandidates;

  /// How many points along a road are tested. The catalogue resamples geometry
  /// at 100 m, so 24 samples describe a 2.5 km road point for point and a 25 km
  /// road every kilometre - fine enough for a fraction, cheap enough to run on
  /// every candidate.
  final int samplesPerRoad;

  /// A pass carries no score because the bend metric does not apply to a summit
  /// node, not because it scored nothing. Ranking it as zero would mean a rider
  /// is never asked about the one category the review process checks
  /// exhaustively, so an unscored candidate ranks with the best.
  static const unscoredRank = 100;

  /// The roads to ask about, best first, capped at [maximumQuestions].
  ///
  /// [excludedFeatureIds] is the set the rider has already been asked about, on
  /// this ride or any earlier one. One rider gets one vote per road.
  List<RiddenRoad> match({
    required MotorcycleDiscoveryCatalogue catalogue,
    required List<GeoPoint> riddenTrack,
    Set<String> excludedFeatureIds = const {},
  }) {
    if (riddenTrack.length < 2) return const [];
    // 15 m is well inside the corridor, so simplification cannot change a
    // verdict, and it bounds the polyline distance work on a long ride.
    final track = const TrailDisplaySimplifier(
      toleranceMeters: 15,
      maximumPoints: 600,
    ).simplify(riddenTrack).map(_toGeo).toList(growable: false);
    if (track.length < 2) return const [];

    final candidates = _candidates(catalogue, track, excludedFeatureIds);
    final matches = <RiddenRoad>[];
    for (final feature in candidates) {
      final match = _evaluate(feature, track);
      if (match != null) matches.add(match);
    }
    matches.sort((first, second) {
      final byRank = _rank(second.feature).compareTo(_rank(first.feature));
      if (byRank != 0) return byRank;
      final byLength = second.riddenMeters.compareTo(first.riddenMeters);
      if (byLength != 0) return byLength;
      return first.feature.id.compareTo(second.feature.id);
    });
    return List.unmodifiable(matches.take(maximumQuestions));
  }

  static int _rank(MotorcycleDiscoveryFeature feature) =>
      feature.score ?? unscoredRank;

  static geo.GeoPoint _toGeo(GeoPoint point) =>
      geo.GeoPoint(latitude: point.latitude, longitude: point.longitude);

  /// Everything whose bounding box could touch the track's, highest-ranked
  /// first and capped, so the expensive per-point work runs on a bounded set.
  List<MotorcycleDiscoveryFeature> _candidates(
    MotorcycleDiscoveryCatalogue catalogue,
    List<geo.GeoPoint> track,
    Set<String> excludedFeatureIds,
  ) {
    var west = double.infinity;
    var east = double.negativeInfinity;
    var south = double.infinity;
    var north = double.negativeInfinity;
    for (final point in track) {
      west = math.min(west, point.longitude);
      east = math.max(east, point.longitude);
      south = math.min(south, point.latitude);
      north = math.max(north, point.latitude);
    }
    final latitudeMargin = corridorMeters / 111320;
    final cosine = math.cos(((south + north) / 2) * math.pi / 180).abs();
    final longitudeMargin = corridorMeters / (111320 * math.max(cosine, 0.2));
    final candidates =
        catalogue.features
            .where(
              (feature) =>
                  !excludedFeatureIds.contains(feature.id) &&
                  feature.points.any(
                    (point) =>
                        point.longitude >= west - longitudeMargin &&
                        point.longitude <= east + longitudeMargin &&
                        point.latitude >= south - latitudeMargin &&
                        point.latitude <= north + latitudeMargin,
                  ),
            )
            .toList()
          ..sort((first, second) {
            final byRank = _rank(second).compareTo(_rank(first));
            return byRank != 0 ? byRank : first.id.compareTo(second.id);
          });
    return candidates.length <= maximumCandidates
        ? candidates
        : candidates.sublist(0, maximumCandidates);
  }

  RiddenRoad? _evaluate(
    MotorcycleDiscoveryFeature feature,
    List<geo.GeoPoint> track,
  ) {
    if (feature.isPoint) {
      // A summit node has no length to cover: riding within the corridor of it
      // is riding it.
      final distance = GeoCalculations.distanceToPolylineMeters(
        _toGeo(feature.points.single),
        track,
      );
      if (distance > corridorMeters) return null;
      return RiddenRoad(feature: feature, matchedFraction: 1, riddenMeters: 0);
    }

    final samples = _sample(feature.points);
    var matched = 0;
    for (final sample in samples) {
      if (GeoCalculations.distanceToPolylineMeters(_toGeo(sample), track) <=
          corridorMeters) {
        matched += 1;
      }
    }
    if (matched == 0) return null;
    final fraction = matched / samples.length;
    final length = _lengthMeters(feature.points);
    final ridden = fraction * length;
    final required = math.min(minimumRiddenMeters, length * shortRoadFraction);
    if (ridden < required) return null;
    return RiddenRoad(
      feature: feature,
      matchedFraction: fraction,
      riddenMeters: ridden,
    );
  }

  List<GeoPoint> _sample(List<GeoPoint> points) {
    if (points.length <= samplesPerRoad) return points;
    return [
      for (var index = 0; index < samplesPerRoad; index += 1)
        points[((index * (points.length - 1)) / (samplesPerRoad - 1)).round()],
    ];
  }

  static double _lengthMeters(List<GeoPoint> points) {
    var total = 0.0;
    for (var index = 0; index < points.length - 1; index += 1) {
      total += GeoCalculations.distanceMeters(
        _toGeo(points[index]),
        _toGeo(points[index + 1]),
      );
    }
    return total;
  }
}
