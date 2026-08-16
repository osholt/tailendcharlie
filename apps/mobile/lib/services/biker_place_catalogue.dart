import 'dart:convert';

import 'package:flutter/services.dart';

import '../domain/imported_route.dart';

/// A rider-friendly stop published by the same curated catalogue as the web
/// route planner.
class BikerPlace {
  const BikerPlace({
    required this.id,
    required this.name,
    required this.address,
    required this.point,
    required this.source,
    this.sourceUrl,
    this.category = 'cafe',
  });

  final String id;
  final String name;
  final String address;
  final GeoPoint point;
  final String source;
  final String? sourceUrl;
  final String category;

  bool get isCafe => category == 'cafe';

  factory BikerPlace.fromJson(Map<String, Object?> json) {
    final sourceId = json['sourceId'];
    final latitude = (json['latitude'] as num?)?.toDouble();
    final longitude = (json['longitude'] as num?)?.toDouble();
    final name = _requiredString(json, 'name');
    if (latitude == null ||
        longitude == null ||
        latitude < -90 ||
        latitude > 90 ||
        longitude < -180 ||
        longitude > 180) {
      throw FormatException('$name has an invalid map position.');
    }
    return BikerPlace(
      id: sourceId == null
          ? '${latitude.toStringAsFixed(6)},${longitude.toStringAsFixed(6)}'
          : sourceId.toString(),
      name: name,
      address: _optionalString(json['address']) ?? '',
      point: GeoPoint(latitude: latitude, longitude: longitude),
      source: _optionalString(json['source']) ?? 'Biker place catalogue',
      sourceUrl: _optionalString(json['sourceUrl']),
      category: _optionalString(json['category']) ?? 'cafe',
    );
  }
}

class BikerPlaceCatalogue {
  const BikerPlaceCatalogue({
    required this.places,
    this.checkedAt,
    this.sourceUrl,
  });

  static const empty = BikerPlaceCatalogue(places: []);

  final List<BikerPlace> places;
  final String? checkedAt;
  final String? sourceUrl;

  static Future<BikerPlaceCatalogue> loadAsset({AssetBundle? bundle}) async =>
      BikerPlaceCatalogue.fromJson(
        await (bundle ?? rootBundle).loadString('assets/biker_places.json'),
      );

  factory BikerPlaceCatalogue.fromJson(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map) {
      throw const FormatException('Biker place catalogue must be an object.');
    }
    final values = decoded['places'];
    if (values is! List || values.length > 10_000) {
      throw const FormatException('Biker place catalogue list is invalid.');
    }
    final ids = <String>{};
    final places = values
        .map((raw) {
          if (raw is! Map) {
            throw const FormatException('Biker place entry must be an object.');
          }
          final place = BikerPlace.fromJson(Map<String, Object?>.from(raw));
          if (!ids.add(place.id)) {
            throw FormatException('Biker place ${place.id} is duplicated.');
          }
          return place;
        })
        .toList(growable: false);
    return BikerPlaceCatalogue(
      places: List.unmodifiable(places),
      checkedAt: _optionalString(decoded['checkedAt']),
      sourceUrl: _optionalString(decoded['sourceUrl']),
    );
  }

  /// Places in and around the current route viewport.
  ///
  /// The web planner clusters the full catalogue. The embedded mobile preview
  /// deliberately keeps a smaller nearby set so dragging a route never has to
  /// resend hundreds of off-screen pins to the native map view.
  List<BikerPlace> nearRoute(
    Iterable<GeoPoint> routePoints, {
    double paddingDegrees = 0.6,
  }) {
    final iterator = routePoints.iterator;
    if (!iterator.moveNext()) return const [];
    var south = iterator.current.latitude;
    var north = south;
    var west = iterator.current.longitude;
    var east = west;
    while (iterator.moveNext()) {
      final point = iterator.current;
      if (point.latitude < south) south = point.latitude;
      if (point.latitude > north) north = point.latitude;
      if (point.longitude < west) west = point.longitude;
      if (point.longitude > east) east = point.longitude;
    }
    return places
        .where(
          (place) =>
              place.point.latitude >= south - paddingDegrees &&
              place.point.latitude <= north + paddingDegrees &&
              place.point.longitude >= west - paddingDegrees &&
              place.point.longitude <= east + paddingDegrees,
        )
        .toList(growable: false);
  }
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = _optionalString(json[key]);
  if (value == null) throw FormatException('Biker place $key is missing.');
  return value;
}

String? _optionalString(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}
