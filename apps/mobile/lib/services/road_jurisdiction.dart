import 'dart:convert';

import 'package:flutter/services.dart';

import '../domain/distance_unit.dart';

enum RoadDrivingSide { left, right }

class RoadJurisdiction {
  const RoadJurisdiction._({
    required this.countryCode,
    required this.name,
    required this.drivingSide,
    required this.distanceUnit,
    required this._polygons,
  });

  final String countryCode;
  final String name;
  final RoadDrivingSide drivingSide;
  final DistanceUnit distanceUnit;
  final List<_RoadPolygon> _polygons;

  bool contains({required double latitude, required double longitude}) =>
      _polygons.any(
        (polygon) => polygon.contains(latitude: latitude, longitude: longitude),
      );
}

/// Offline country boundaries carrying only road conventions.
///
/// Routing remains authoritative for the road itself. This layer supplies the
/// fact a route engine may omit (Valhalla) or occasionally get wrong (OSRM):
/// which way traffic circulates. It also lets automatic journey units follow
/// the road country rather than the phone's shop locale.
class RoadJurisdictionCatalogue {
  const RoadJurisdictionCatalogue(this.jurisdictions);

  static const assetKey = 'assets/road_jurisdictions.geojson';
  static const empty = RoadJurisdictionCatalogue([]);

  final List<RoadJurisdiction> jurisdictions;

  static Future<RoadJurisdictionCatalogue> load({AssetBundle? bundle}) async =>
      parse(await (bundle ?? rootBundle).loadString(assetKey));

  static RoadJurisdictionCatalogue parse(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map<String, dynamic> || decoded['features'] is! List) {
      throw const FormatException(
        'Road-jurisdiction layer is not a GeoJSON feature collection.',
      );
    }
    final jurisdictions = <RoadJurisdiction>[];
    for (final raw in decoded['features'] as List) {
      final jurisdiction = _parseJurisdiction(raw);
      if (jurisdiction != null) jurisdictions.add(jurisdiction);
    }
    return RoadJurisdictionCatalogue(List.unmodifiable(jurisdictions));
  }

  RoadJurisdiction? resolve({
    required double latitude,
    required double longitude,
  }) {
    if (!latitude.isFinite ||
        !longitude.isFinite ||
        latitude < -90 ||
        latitude > 90 ||
        longitude < -180 ||
        longitude > 180) {
      return null;
    }
    for (final jurisdiction in jurisdictions) {
      if (jurisdiction.contains(latitude: latitude, longitude: longitude)) {
        return jurisdiction;
      }
    }
    return null;
  }

  static RoadJurisdiction? _parseJurisdiction(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final properties = raw['properties'];
    final geometry = raw['geometry'];
    if (properties is! Map<String, dynamic> ||
        geometry is! Map<String, dynamic>) {
      return null;
    }
    final countryCode = properties['countryCode'];
    final name = properties['name'];
    final side = RoadDrivingSide.values
        .where((value) => value.name == properties['drivingSide'])
        .firstOrNull;
    final unit = DistanceUnit.values
        .where((value) => value.name == properties['distanceUnit'])
        .firstOrNull;
    if (countryCode is! String ||
        countryCode.length != 2 ||
        name is! String ||
        side == null ||
        unit == null) {
      return null;
    }
    final polygons = _parsePolygons(geometry);
    if (polygons.isEmpty) return null;
    return RoadJurisdiction._(
      countryCode: countryCode,
      name: name,
      drivingSide: side,
      distanceUnit: unit,
      polygons: polygons,
    );
  }
}

List<_RoadPolygon> _parsePolygons(Map<String, dynamic> geometry) {
  final coordinates = geometry['coordinates'];
  if (coordinates is! List) return const [];
  return switch (geometry['type']) {
    'Polygon' => [?_parsePolygon(coordinates)],
    'MultiPolygon' => [
      for (final raw in coordinates)
        if (raw is List) ?_parsePolygon(raw),
    ],
    _ => const [],
  };
}

_RoadPolygon? _parsePolygon(List raw) {
  final rings = <List<_RoadCoordinate>>[];
  for (final rawRing in raw) {
    if (rawRing is! List) continue;
    final ring = <_RoadCoordinate>[];
    for (final rawCoordinate in rawRing) {
      if (rawCoordinate is! List || rawCoordinate.length < 2) continue;
      final longitude = (rawCoordinate[0] as num?)?.toDouble();
      final latitude = (rawCoordinate[1] as num?)?.toDouble();
      if (latitude == null ||
          longitude == null ||
          !latitude.isFinite ||
          !longitude.isFinite) {
        continue;
      }
      ring.add(_RoadCoordinate(latitude, longitude));
    }
    if (ring.length >= 4) rings.add(List.unmodifiable(ring));
  }
  if (rings.isEmpty) return null;
  return _RoadPolygon(List.unmodifiable(rings));
}

class _RoadCoordinate {
  const _RoadCoordinate(this.latitude, this.longitude);

  final double latitude;
  final double longitude;
}

class _RoadPolygon {
  _RoadPolygon(this.rings)
    : south = rings.first
          .map((point) => point.latitude)
          .reduce((a, b) => a < b ? a : b),
      north = rings.first
          .map((point) => point.latitude)
          .reduce((a, b) => a > b ? a : b),
      west = rings.first
          .map((point) => point.longitude)
          .reduce((a, b) => a < b ? a : b),
      east = rings.first
          .map((point) => point.longitude)
          .reduce((a, b) => a > b ? a : b);

  final List<List<_RoadCoordinate>> rings;
  final double south;
  final double north;
  final double west;
  final double east;

  bool contains({required double latitude, required double longitude}) {
    if (latitude < south ||
        latitude > north ||
        longitude < west ||
        longitude > east ||
        !_ringContains(rings.first, latitude, longitude)) {
      return false;
    }
    // GeoJSON's first ring is the country surface and later rings are holes.
    return !rings
        .skip(1)
        .any((hole) => _ringContains(hole, latitude, longitude));
  }
}

bool _ringContains(
  List<_RoadCoordinate> ring,
  double latitude,
  double longitude,
) {
  var inside = false;
  var previous = ring.last;
  for (final current in ring) {
    if (_onSegment(previous, current, latitude, longitude)) return true;
    final crosses =
        (current.latitude > latitude) != (previous.latitude > latitude);
    if (crosses) {
      final atLongitude =
          (previous.longitude - current.longitude) *
              (latitude - current.latitude) /
              (previous.latitude - current.latitude) +
          current.longitude;
      if (longitude < atLongitude) inside = !inside;
    }
    previous = current;
  }
  return inside;
}

bool _onSegment(
  _RoadCoordinate first,
  _RoadCoordinate second,
  double latitude,
  double longitude,
) {
  const epsilon = 1e-10;
  final cross =
      (longitude - first.longitude) * (second.latitude - first.latitude) -
      (latitude - first.latitude) * (second.longitude - first.longitude);
  if (cross.abs() > epsilon) return false;
  return latitude >=
          (first.latitude < second.latitude
                  ? first.latitude
                  : second.latitude) -
              epsilon &&
      latitude <=
          (first.latitude > second.latitude
                  ? first.latitude
                  : second.latitude) +
              epsilon &&
      longitude >=
          (first.longitude < second.longitude
                  ? first.longitude
                  : second.longitude) -
              epsilon &&
      longitude <=
          (first.longitude > second.longitude
                  ? first.longitude
                  : second.longitude) +
              epsilon;
}

Future<RoadJurisdictionCatalogue>? _bundledRoadJurisdictions;

Future<RoadJurisdictionCatalogue> bundledRoadJurisdictions() =>
    _bundledRoadJurisdictions ??= RoadJurisdictionCatalogue.load().catchError(
      (Object _) => RoadJurisdictionCatalogue.empty,
    );
