import 'motorcycle_discovery.dart';

/// A rider's one-tap answer about a catalogued road (#159).
///
/// Deliberately binary rather than a five-star scale. The catalogue review
/// process needs a decision - does this candidate belong in the directory - and
/// a mean of unanchored stars still has to be thresholded into one before it can
/// be used, so the stars only add a step where riders and reviewers can disagree
/// about what three means. A binary answer is also genuinely one tap: two large
/// targets a gloved thumb can hit after three hours in the saddle, rather than
/// five small ones.
enum RoadRatingVerdict {
  worthIncluding('worth_including'),
  notWorthIncluding('not_worth_including');

  const RoadRatingVerdict(this.apiValue);

  final String apiValue;

  static RoadRatingVerdict? fromApiValue(String? value) => RoadRatingVerdict
      .values
      .where((verdict) => verdict.apiValue == value)
      .firstOrNull;
}

/// One queued rating, held on this phone until its own randomised release time.
///
/// [releaseAfter] never leaves the phone. It exists so ratings do not leave in
/// the same minute as the ride's own relay traffic: the relay sees the source IP
/// of both, and a rating that arrives while the ride is still syncing could be
/// correlated with it by anyone holding the relay's logs. Hours of independent,
/// per-rating delay removes that handle.
class RoadRating {
  const RoadRating({
    required this.featureId,
    required this.category,
    required this.verdict,
    required this.catalogueVersion,
    required this.releaseAfter,
    this.sourceFeatureId,
  });

  /// The catalogue feature's own ID. A content hash over the OSM source ways,
  /// so it moves when the extract moves - which is why [sourceFeatureId] is
  /// carried alongside it.
  final String featureId;

  /// The stable re-match key across OSM extracts.
  final String? sourceFeatureId;

  final MotorcycleDiscoveryCategory category;
  final RoadRatingVerdict verdict;

  /// Which published catalogue the rider was looking at, so a rating is never
  /// counted against geometry the rider never saw.
  final String catalogueVersion;

  final DateTime releaseAfter;

  /// The entire request body. There is no rider ID, device ID, ride ID,
  /// installation ID, position or timestamp here, and there is deliberately
  /// nowhere to put one: the relay's schema forbids unknown fields, so a later
  /// change that tried to add one would be rejected rather than quietly stored.
  Map<String, Object?> toRequestJson() => {
    'featureId': featureId,
    if (sourceFeatureId != null) 'sourceFeatureId': sourceFeatureId,
    'category': category.apiValue,
    'verdict': verdict.apiValue,
    'catalogueVersion': catalogueVersion,
  };

  /// The on-device form, which adds only the local release time.
  Map<String, Object?> toJson() => {
    ...toRequestJson(),
    'releaseAfter': releaseAfter.toUtc().toIso8601String(),
  };

  factory RoadRating.fromJson(Map<String, Object?> json) {
    final verdict = RoadRatingVerdict.fromApiValue(json['verdict'] as String?);
    final category = MotorcycleDiscoveryCategory.fromApiValue(
      json['category'] as String?,
    );
    final featureId = json['featureId'];
    final catalogueVersion = json['catalogueVersion'];
    final releaseAfter = DateTime.tryParse(
      json['releaseAfter'] as String? ?? '',
    );
    if (verdict == null ||
        category == null ||
        featureId is! String ||
        featureId.isEmpty ||
        featureId.length > 128 ||
        catalogueVersion is! String ||
        catalogueVersion.isEmpty ||
        releaseAfter == null) {
      throw const FormatException('Queued road rating is invalid.');
    }
    final sourceFeatureId = json['sourceFeatureId'];
    return RoadRating(
      featureId: featureId,
      sourceFeatureId: sourceFeatureId is String && sourceFeatureId.isNotEmpty
          ? sourceFeatureId
          : null,
      category: category,
      verdict: verdict,
      catalogueVersion: catalogueVersion,
      releaseAfter: releaseAfter.toUtc(),
    );
  }
}
