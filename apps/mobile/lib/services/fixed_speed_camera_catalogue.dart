import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart';

import '../domain/geo_point.dart';
import 'geo_calculations.dart';

/// A permanent roadside camera, from OpenStreetMap.
///
/// Distinct from a rider's sighting in the two ways that matter: it does not
/// move, so it never expires on its own, and nobody on this ride vouched for
/// it, so it is credited to the extract rather than to a rider.
class FixedSpeedCamera {
  const FixedSpeedCamera({
    required this.osmId,
    required this.position,
    this.role,
    this.speedLimit,
    this.operatorName,
  });

  /// The OpenStreetMap node, as `node/<id>`. Stable across extracts, which is
  /// what lets the same camera seen by two riders merge instead of doubling.
  final String osmId;

  final GeoPoint position;

  /// What kind of camera, where the extract says: `maxspeed`, `average`,
  /// `traffic_signals`. Absent on plenty of nodes.
  final String? role;

  /// Posted limit the camera enforces, where tagged.
  final String? speedLimit;

  final String? operatorName;

  /// What a rider reads under the warning. Deliberately says nothing it cannot
  /// support: an untagged camera is described only as a fixed camera.
  String get description {
    final parts = <String>[
      switch (role) {
        'average' => 'Average speed camera',
        'traffic_signals' => 'Traffic light camera',
        _ => 'Fixed speed camera',
      },
      if (speedLimit case final limit? when limit.isNotEmpty) '$limit limit',
    ];
    return parts.join(' · ');
  }
}

/// The bundled fixed-camera layer, with the provenance the licence requires.
///
/// Loaded from an asset rather than fetched: a fixed camera does not move, so
/// there is nothing to be live about, and a rider in a Welsh valley with no
/// signal gets the same warning as one on the M4.
class FixedSpeedCameraCatalogue {
  const FixedSpeedCameraCatalogue({
    required this.cameras,
    required this.attribution,
    required this.extractDate,
    required this.boundedRegion,
  });

  /// Where the asset lives. Kept next to the discovery catalogue it was
  /// generated alongside.
  static const assetKey = 'assets/fixed_speed_cameras.geojson';

  final List<FixedSpeedCamera> cameras;

  /// ODbL attribution, shown wherever these are drawn.
  final String attribution;

  /// The date of the OpenStreetMap extract, so a rider can judge its age.
  final String extractDate;

  /// The area the extract covers. Outside it the layer holds nothing at all,
  /// which is a different thing from there being no cameras.
  final String boundedRegion;

  static const empty = FixedSpeedCameraCatalogue(
    cameras: [],
    attribution: '',
    extractDate: '',
    boundedRegion: '',
  );

  bool get isEmpty => cameras.isEmpty;

  static Future<FixedSpeedCameraCatalogue> load({AssetBundle? bundle}) async {
    final source = await (bundle ?? rootBundle).loadString(assetKey);
    return parse(source);
  }

  static FixedSpeedCameraCatalogue parse(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Camera catalogue is not a GeoJSON object.');
    }
    final properties = decoded['properties'];
    final meta = properties is Map<String, dynamic>
        ? properties
        : const <String, dynamic>{};
    final features = decoded['features'];
    final cameras = <FixedSpeedCamera>[];
    if (features is List) {
      for (final feature in features) {
        final camera = _camera(feature);
        if (camera != null) cameras.add(camera);
      }
    }
    return FixedSpeedCameraCatalogue(
      cameras: List.unmodifiable(cameras),
      attribution: meta['attribution'] as String? ?? '',
      extractDate: meta['extractDate'] as String? ?? '',
      boundedRegion: meta['boundedRegion'] as String? ?? '',
    );
  }

  static FixedSpeedCamera? _camera(Object? feature) {
    if (feature is! Map<String, dynamic>) return null;
    final geometry = feature['geometry'];
    if (geometry is! Map<String, dynamic>) return null;
    if (geometry['type'] != 'Point') return null;
    final coordinates = geometry['coordinates'];
    if (coordinates is! List || coordinates.length < 2) return null;
    final longitude = (coordinates[0] as num?)?.toDouble();
    final latitude = (coordinates[1] as num?)?.toDouble();
    if (longitude == null || latitude == null) return null;
    final properties = feature['properties'];
    final tags = properties is Map<String, dynamic>
        ? properties
        : const <String, dynamic>{};
    final osmId = tags['osmId'] as String?;
    if (osmId == null || osmId.isEmpty) return null;
    return FixedSpeedCamera(
      osmId: osmId,
      position: GeoPoint(latitude: latitude, longitude: longitude),
      role: tags['role'] as String?,
      speedLimit: tags['maxspeed'] as String?,
      operatorName: tags['operator'] as String?,
    );
  }

  /// Cameras within [corridorMeters] of the ride.
  ///
  /// A camera enforces the road it stands on, so the corridor is tight on
  /// purpose. A wider one drags in cameras on a parallel road the group is not
  /// riding, and a warning that fires for someone else's road is the fastest
  /// way to teach a rider to ignore all of them.
  List<FixedSpeedCamera> near(
    List<GeoPoint> route, {
    double corridorMeters = 250,
  }) {
    if (route.length < 2 || cameras.isEmpty) return const [];
    // A whole-country layer against a long route is a lot of point-to-segment
    // work, so reject on the route's bounding box first. That is a cheap
    // comparison and it discards almost everything.
    var minLatitude = route.first.latitude;
    var maxLatitude = route.first.latitude;
    var minLongitude = route.first.longitude;
    var maxLongitude = route.first.longitude;
    for (final point in route) {
      if (point.latitude < minLatitude) minLatitude = point.latitude;
      if (point.latitude > maxLatitude) maxLatitude = point.latitude;
      if (point.longitude < minLongitude) minLongitude = point.longitude;
      if (point.longitude > maxLongitude) maxLongitude = point.longitude;
    }
    const metersPerDegreeLatitude = 111320.0;
    final latitudePadding = corridorMeters / metersPerDegreeLatitude;
    // Longitude degrees shorten towards the poles. Using the latitude furthest
    // from the equator keeps the box generous rather than clipping a camera at
    // the northern edge of a Scottish route.
    final widestLatitude = maxLatitude.abs() > minLatitude.abs()
        ? maxLatitude
        : minLatitude;
    final longitudeScale =
        metersPerDegreeLatitude * math.cos(widestLatitude * math.pi / 180);
    final longitudePadding = longitudeScale <= 1
        ? 180.0
        : corridorMeters / longitudeScale;

    final matches = <FixedSpeedCamera>[];
    for (final camera in cameras) {
      final position = camera.position;
      if (position.latitude < minLatitude - latitudePadding ||
          position.latitude > maxLatitude + latitudePadding ||
          position.longitude < minLongitude - longitudePadding ||
          position.longitude > maxLongitude + longitudePadding) {
        continue;
      }
      if (GeoCalculations.distanceToPolylineMeters(position, route) <=
          corridorMeters) {
        matches.add(camera);
      }
    }
    return List.unmodifiable(matches);
  }
}
