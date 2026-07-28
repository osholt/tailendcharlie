import 'dart:convert';

import 'package:flutter/services.dart';

import '../domain/imported_route.dart';

enum MotorcycleDiscoveryCategory {
  twistyHighlight('twisty_highlight', 'Twisty highlights'),
  mountainPass('mountain_pass', 'Mountain passes'),
  goodBikingRoad('good_biking_road', 'Good biking roads');

  const MotorcycleDiscoveryCategory(this.apiValue, this.label);

  final String apiValue;
  final String label;

  static MotorcycleDiscoveryCategory? fromApiValue(String? value) =>
      MotorcycleDiscoveryCategory.values
          .where((category) => category.apiValue == value)
          .firstOrNull;
}

/// Where a candidate's speed limit came from.
///
/// The catalogue distinguishes these because a road with no mapped limit must
/// read as *not known*, never as unrestricted and never as a guess (#145, #160).
/// [absent] is the case the catalogue itself has no opinion on - an older
/// catalogue, or a field a generator has not written yet - and is reported just
/// as honestly as [unknown] rather than defaulted to something reassuring.
enum DiscoverySpeedLimitProvenance {
  tagged('tagged'),
  inferredFromMaxspeedType('inferred-from-maxspeed-type'),
  unknown('unknown'),
  absent(null);

  const DiscoverySpeedLimitProvenance(this.apiValue);

  final String? apiValue;

  static DiscoverySpeedLimitProvenance fromApiValue(Object? value) =>
      DiscoverySpeedLimitProvenance.values
          .where((provenance) => provenance.apiValue == value)
          .firstOrNull ??
      DiscoverySpeedLimitProvenance.unknown;
}

/// A candidate's mapped speed limit, or the reason there is none.
class DiscoverySpeedLimit {
  const DiscoverySpeedLimit({
    required this.provenance,
    this.value,
    this.mixed = false,
    this.range = const [],
    this.note,
  });

  static const DiscoverySpeedLimit absent = DiscoverySpeedLimit(
    provenance: DiscoverySpeedLimitProvenance.absent,
  );

  /// The limit as the catalogue states it, e.g. `50 mph`. Null whenever it is
  /// not known - which is the only honest reading of an untagged road.
  final String? value;
  final DiscoverySpeedLimitProvenance provenance;

  /// The road carries more than one limit over its length.
  final bool mixed;

  /// The lowest and highest limits on a [mixed] road, when recorded.
  final List<String> range;

  /// The catalogue's own explanation, used in preference to any wording of ours.
  final String? note;

  bool get isKnown =>
      value != null &&
      provenance != DiscoverySpeedLimitProvenance.unknown &&
      provenance != DiscoverySpeedLimitProvenance.absent;

  factory DiscoverySpeedLimit.fromJson(Map<String, Object?> json) =>
      DiscoverySpeedLimit(
        value: _trimmedOrNull(json['value']),
        provenance: DiscoverySpeedLimitProvenance.fromApiValue(
          json['provenance'],
        ),
        mixed: json['mixed'] == true,
        range:
            (json['range'] as List?)
                ?.map(_trimmedOrNull)
                .whereType<String>()
                .toList(growable: false) ??
            const [],
        note: _trimmedOrNull(json['note']),
      );
}

/// Whether an OpenStreetMap `enforcement=average_speed` relation covers a road.
class DiscoveryAverageSpeedCheck {
  const DiscoveryAverageSpeedCheck({
    required this.recorded,
    this.present = false,
    this.relation,
    this.enforcedLimit,
    this.description,
  });

  /// The catalogue said nothing at all about average-speed enforcement.
  static const DiscoveryAverageSpeedCheck absent = DiscoveryAverageSpeedCheck(
    recorded: false,
  );

  /// Whether the catalogue carries the field at all. False means "we did not
  /// look", which is a different statement from "we looked and found nothing".
  final bool recorded;

  /// True only when a relation actually covers the road.
  final bool present;
  final String? relation;
  final String? enforcedLimit;
  final String? description;

  factory DiscoveryAverageSpeedCheck.fromJson(Map<String, Object?> json) =>
      DiscoveryAverageSpeedCheck(
        recorded: true,
        present: json['present'] == true,
        relation: _trimmedOrNull(json['relation']),
        enforcedLimit: _trimmedOrNull(json['enforcedLimit']),
        description: _trimmedOrNull(json['description']),
      );
}

/// How far a candidate has been researched.
enum DiscoveryResearchStatus {
  researched('researched'),
  pending('pending'),

  /// The catalogue does not say. Treated as no better than [pending] on screen:
  /// an entry with no stated review state must not read as a verified one.
  unstated(null);

  const DiscoveryResearchStatus(this.apiValue);

  final String? apiValue;

  bool get isVerified => this == DiscoveryResearchStatus.researched;

  static DiscoveryResearchStatus fromApiValue(Object? value) =>
      DiscoveryResearchStatus.values
          .where((status) => status.apiValue == value)
          .firstOrNull ??
      DiscoveryResearchStatus.unstated;
}

/// How directly the catalogue's cited source supports an editorial claim.
///
/// A listing can establish that a road appears in a directory, but cannot be
/// presented as verification of riding quality. Missing and unknown values are
/// deliberately no stronger than [unstated] (#215).
enum DiscoverySourceVerification {
  fetched('fetched'),
  listingOnly('listing-only'),
  unstated(null);

  const DiscoverySourceVerification(this.apiValue);

  final String? apiValue;

  bool get isFetched => this == DiscoverySourceVerification.fetched;

  static DiscoverySourceVerification fromApiValue(Object? value) =>
      DiscoverySourceVerification.values
          .where((verification) => verification.apiValue == value)
          .firstOrNull ??
      DiscoverySourceVerification.unstated;
}

class MotorcycleDiscoveryFeature {
  const MotorcycleDiscoveryFeature({
    required this.id,
    required this.category,
    required this.name,
    required this.points,
    required this.sourceName,
    required this.sourceUrl,
    required this.confidence,
    required this.lastVerified,
    required this.warning,
    this.score,
    this.sourceFeatureId,
    this.speedLimit = DiscoverySpeedLimit.absent,
    this.averageSpeedCheck = DiscoveryAverageSpeedCheck.absent,
    this.fixedSpeedCameras,
    this.busyPeriods,
    this.riderNote,
    this.enforcementNote,
    this.researchStatus = DiscoveryResearchStatus.unstated,
    this.sourceVerification = DiscoverySourceVerification.unstated,
    this.evidenceSources = const [],
  });

  final String id;
  final MotorcycleDiscoveryCategory category;
  final String name;
  final List<GeoPoint> points;
  final String sourceName;
  final String sourceUrl;
  final String confidence;
  final String lastVerified;
  final String warning;
  final int? score;

  /// The upstream feature this candidate was derived from.
  ///
  /// [id] is a content hash over the OSM source ways, so it changes whenever the
  /// extract does; `sourceFeatureId` is what the catalogue tooling re-matches on
  /// across releases. A rider rating has to carry it or the rating is orphaned
  /// by the next publication (#159).
  final String? sourceFeatureId;
  final DiscoverySpeedLimit speedLimit;
  final DiscoveryAverageSpeedCheck averageSpeedCheck;

  /// Fixed speed cameras near the road. Null means the catalogue does not count
  /// them, which is not the same as counting zero.
  final int? fixedSpeedCameras;

  /// When the road is busy, where a researcher has established it.
  final String? busyPeriods;

  /// One or two sentences for a rider.
  final String? riderNote;

  /// A researched caveat about enforcement that OpenStreetMap does not record.
  final String? enforcementNote;
  final DiscoveryResearchStatus researchStatus;
  final DiscoverySourceVerification sourceVerification;
  final List<String> evidenceSources;

  bool get isPoint => points.length == 1;
  GeoPoint get anchor => points[points.length ~/ 2];
}

class MotorcycleDiscoveryCatalogue {
  const MotorcycleDiscoveryCatalogue(
    this.features, {
    this.version = unknownVersion,
  });

  /// What a build reports when the asset carries no `catalogueVersion`.
  ///
  /// Named rather than blank so a rating can never be filed against an
  /// unidentifiable catalogue without that being obvious in the tally.
  static const unknownVersion = 'unknown';

  final List<MotorcycleDiscoveryFeature> features;

  /// The published catalogue release this data came from, e.g.
  /// `uk-osm-2026-07-23-v1`. Sent with a rider rating so the review process
  /// never counts an answer against geometry that has since changed (#159).
  final String version;

  static Future<MotorcycleDiscoveryCatalogue> loadAsset() async =>
      MotorcycleDiscoveryCatalogue.fromJson(
        await rootBundle.loadString('assets/discovery_catalogue.geojson'),
      );

  factory MotorcycleDiscoveryCatalogue.fromJson(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map || decoded['type'] != 'FeatureCollection') {
      throw const FormatException('Discovery catalogue must be GeoJSON.');
    }
    final rawFeatures = decoded['features'];
    if (rawFeatures is! List || rawFeatures.length > 10_000) {
      throw const FormatException(
        'Discovery catalogue feature list is invalid.',
      );
    }
    final properties = decoded['properties'];
    final rawVersion = properties is Map
        ? properties['catalogueVersion']
        : null;
    return MotorcycleDiscoveryCatalogue(
      List.unmodifiable(rawFeatures.map(_parseFeature)),
      version: rawVersion is String && rawVersion.trim().isNotEmpty
          ? rawVersion.trim()
          : unknownVersion,
    );
  }

  List<MotorcycleDiscoveryFeature> visible({
    required Set<MotorcycleDiscoveryCategory> categories,
    double west = -180,
    double south = -90,
    double east = 180,
    double north = 90,
  }) => features
      .where(
        (feature) =>
            categories.contains(feature.category) &&
            feature.points.any(
              (point) =>
                  point.longitude >= west &&
                  point.longitude <= east &&
                  point.latitude >= south &&
                  point.latitude <= north,
            ),
      )
      .toList(growable: false);

  static MotorcycleDiscoveryFeature _parseFeature(Object? raw) {
    if (raw is! Map || raw['properties'] is! Map || raw['geometry'] is! Map) {
      throw const FormatException('Discovery feature is invalid.');
    }
    final properties = Map<String, Object?>.from(raw['properties'] as Map);
    final geometry = Map<String, Object?>.from(raw['geometry'] as Map);
    final categoryValue = properties['category'];
    final categories = MotorcycleDiscoveryCategory.values.where(
      (category) => category.apiValue == categoryValue,
    );
    if (categories.isEmpty) {
      throw FormatException('Unsupported discovery category: $categoryValue');
    }
    final rawCoordinates = geometry['coordinates'];
    final pointCoordinates = geometry['type'] == 'Point'
        ? [rawCoordinates]
        : rawCoordinates;
    if (pointCoordinates is! List || pointCoordinates.isEmpty) {
      throw const FormatException('Discovery geometry is empty.');
    }
    final points = pointCoordinates
        .map((rawPoint) {
          if (rawPoint is! List ||
              rawPoint.length != 2 ||
              rawPoint[0] is! num ||
              rawPoint[1] is! num) {
            throw const FormatException('Discovery coordinate is invalid.');
          }
          return GeoPoint(
            longitude: (rawPoint[0] as num).toDouble(),
            latitude: (rawPoint[1] as num).toDouble(),
          );
        })
        .toList(growable: false);
    return MotorcycleDiscoveryFeature(
      id: _required(properties, 'id'),
      category: categories.single,
      name: _required(properties, 'name'),
      points: points,
      sourceName: _required(properties, 'sourceName'),
      sourceUrl: _required(properties, 'sourceUrl'),
      confidence: _required(properties, 'confidence'),
      lastVerified: _required(properties, 'lastVerified'),
      warning: _required(properties, 'warning'),
      score: (properties['score'] as num?)?.round(),
      sourceFeatureId: switch (properties['sourceFeatureId']) {
        final String value when value.trim().isNotEmpty => value.trim(),
        _ => null,
      },
      // Every enrichment field is optional. The catalogue is generated by a
      // separate pipeline (#158) and an older or partial one must still load,
      // degrading to "not recorded" rather than to a comfortable default.
      speedLimit: switch (properties['speedLimit']) {
        final Map<Object?, Object?> value => DiscoverySpeedLimit.fromJson(
          Map<String, Object?>.from(value),
        ),
        _ => DiscoverySpeedLimit.absent,
      },
      averageSpeedCheck: switch (properties['averageSpeedCheck']) {
        final Map<Object?, Object?> value =>
          DiscoveryAverageSpeedCheck.fromJson(Map<String, Object?>.from(value)),
        _ => DiscoveryAverageSpeedCheck.absent,
      },
      fixedSpeedCameras: switch (properties['fixedSpeedCameras']) {
        final num value when value.isFinite && value >= 0 => value.round(),
        _ => null,
      },
      busyPeriods: _trimmedOrNull(properties['busyPeriods']),
      riderNote: _trimmedOrNull(properties['riderNote']),
      enforcementNote: _trimmedOrNull(properties['enforcementNote']),
      researchStatus: DiscoveryResearchStatus.fromApiValue(
        properties['researchStatus'],
      ),
      sourceVerification: DiscoverySourceVerification.fromApiValue(
        properties['sourceVerification'],
      ),
      evidenceSources:
          (properties['evidenceSources'] as List?)
              ?.map(_trimmedOrNull)
              .whereType<String>()
              .toList(growable: false) ??
          const [],
    );
  }

  static String _required(Map<String, Object?> values, String key) {
    final value = values[key];
    if (value is! String || value.trim().isEmpty) {
      throw FormatException('Discovery $key is required.');
    }
    return value.trim();
  }
}

String? _trimmedOrNull(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}
