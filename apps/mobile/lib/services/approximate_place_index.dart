import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart';

import '../domain/imported_route.dart';

/// A local settlement index for human-readable saved-route endpoints.
///
/// Route starts and finishes are particularly sensitive. This index is bundled
/// with the app so naming them never sends a coordinate to a reverse geocoder
/// (#490).
class ApproximatePlaceIndex {
  ApproximatePlaceIndex._(this._places, this.attribution);

  static const assetKey = 'assets/route_places.json';
  static const maximumMatchDistanceMeters = 50 * 1000.0;
  static const _coarseLocalityDistanceMeters = 8 * 1000.0;
  static const _coarseLocalityProminence = 1;
  static const _latitudeSearchWindowE5 = 100000;
  static Future<ApproximatePlaceIndex>? _defaultIndex;

  final List<_ApproximatePlace> _places;
  final String attribution;

  static Future<ApproximatePlaceIndex> load({AssetBundle? bundle}) {
    if (bundle != null) return _load(bundle);
    return _defaultIndex ??= _load(rootBundle);
  }

  static Future<ApproximatePlaceIndex> _load(AssetBundle bundle) async =>
      fromJson(await bundle.loadString(assetKey));

  static ApproximatePlaceIndex fromJson(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map || decoded['schemaVersion'] != 1) {
      throw const FormatException('Unsupported route place index.');
    }
    final rawPlaces = decoded['places'];
    final attribution = decoded['attribution'];
    if (rawPlaces is! List || attribution is! String) {
      throw const FormatException('Route place index is invalid.');
    }
    final places = <_ApproximatePlace>[];
    for (final value in rawPlaces) {
      if (value is! List || value.length < 4) {
        throw const FormatException('Route place entry is invalid.');
      }
      final latitudeE5 = value[0];
      final longitudeE5 = value[1];
      final name = value[2];
      final prominence = value[3];
      if (latitudeE5 is! int ||
          longitudeE5 is! int ||
          name is! String ||
          name.trim().isEmpty ||
          prominence is! int) {
        throw const FormatException('Route place entry is invalid.');
      }
      places.add(
        _ApproximatePlace(
          latitudeE5: latitudeE5,
          longitudeE5: longitudeE5,
          name: name.trim(),
          prominence: prominence,
        ),
      );
    }
    places.sort((left, right) => left.latitudeE5.compareTo(right.latitudeE5));
    return ApproximatePlaceIndex._(List.unmodifiable(places), attribution);
  }

  /// Nearest named settlement within 50 km, or null outside Great Britain.
  String? nearestName(GeoPoint point) {
    if (_places.isEmpty) return null;
    final latitudeE5 = (point.latitude * 100000).round();
    final start = _lowerBound(latitudeE5 - _latitudeSearchWindowE5);
    final end = _lowerBound(latitudeE5 + _latitudeSearchWindowE5 + 1);
    _ApproximatePlace? best;
    var bestDistance = double.infinity;
    _ApproximatePlace? bestCoarse;
    var bestCoarseDistance = double.infinity;
    for (var index = start; index < end; index += 1) {
      final candidate = _places[index];
      final distance = _distanceMeters(point, candidate);
      if (distance < bestDistance - 250 ||
          ((distance - bestDistance).abs() <= 250 &&
              (best == null || candidate.prominence < best.prominence))) {
        best = candidate;
        bestDistance = distance;
      }
      // Saved rides need a recognisable locality, not the nearest estate or
      // hamlet. Prefer the closest town-level label when one is genuinely
      // local, while retaining the nearest settlement in rural areas.
      if (candidate.prominence <= _coarseLocalityProminence &&
          distance <= _coarseLocalityDistanceMeters &&
          distance < bestCoarseDistance) {
        bestCoarse = candidate;
        bestCoarseDistance = distance;
      }
    }
    if (bestCoarse != null) return bestCoarse.name;
    return bestDistance <= maximumMatchDistanceMeters ? best?.name : null;
  }

  int _lowerBound(int latitudeE5) {
    var low = 0;
    var high = _places.length;
    while (low < high) {
      final middle = low + ((high - low) >> 1);
      if (_places[middle].latitudeE5 < latitudeE5) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low;
  }

  static double _distanceMeters(GeoPoint point, _ApproximatePlace candidate) {
    final latitude = point.latitude * math.pi / 180;
    final candidateLatitude = candidate.latitudeE5 / 100000 * math.pi / 180;
    final deltaLatitude = candidateLatitude - latitude;
    final deltaLongitude =
        (candidate.longitudeE5 / 100000 - point.longitude) * math.pi / 180;
    final x = deltaLongitude * math.cos((latitude + candidateLatitude) / 2);
    return 6371000 * math.sqrt(x * x + deltaLatitude * deltaLatitude);
  }
}

String approximateEndpointLabel({
  required ApproximatePlaceIndex index,
  required GeoPoint? start,
  required GeoPoint? end,
}) {
  final startName = start == null ? null : index.nearestName(start);
  final endName = end == null ? null : index.nearestName(end);
  if (startName != null && endName != null) {
    return startName == endName ? '$startName loop' : '$startName to $endName';
  }
  if (startName != null) return 'Starts near $startName';
  if (endName != null) return 'Ends near $endName';
  return 'Approximate places unavailable offline';
}

class _ApproximatePlace {
  const _ApproximatePlace({
    required this.latitudeE5,
    required this.longitudeE5,
    required this.name,
    required this.prominence,
  });

  final int latitudeE5;
  final int longitudeE5;
  final String name;
  final int prominence;
}
