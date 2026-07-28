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
