import 'dart:math' as math;

import '../domain/imported_route.dart';

/// Largest gap whose intervening z17/z19 cells may be treated as ridden.
///
/// The app normally records a fix about every 20 metres. A much larger jump is
/// a loss of evidence, not a straight road, so heatmaps keep the real endpoint
/// cells but never manufacture coverage between them.
const maximumRecordedHeatmapInterpolationMeters = 250.0;

bool recordedHeatmapSegmentIsContinuous(GeoPoint start, GeoPoint end) {
  const earthRadiusMeters = 6371000.0;
  final startLatitude = start.latitude * math.pi / 180;
  final endLatitude = end.latitude * math.pi / 180;
  final latitudeDelta = endLatitude - startLatitude;
  final longitudeDelta = (end.longitude - start.longitude) * math.pi / 180;
  final haversine =
      math.sin(latitudeDelta / 2) * math.sin(latitudeDelta / 2) +
      math.cos(startLatitude) *
          math.cos(endLatitude) *
          math.sin(longitudeDelta / 2) *
          math.sin(longitudeDelta / 2);
  final boundedHaversine = haversine.clamp(0.0, 1.0);
  final distance =
      earthRadiusMeters *
      2 *
      math.atan2(math.sqrt(boundedHaversine), math.sqrt(1 - boundedHaversine));
  return distance <= maximumRecordedHeatmapInterpolationMeters;
}

/// Splits a recorded path wherever joining two fixes would invent coverage.
List<List<GeoPoint>> continuousRecordedHeatmapSegments(List<GeoPoint> points) {
  if (points.isEmpty) return const [];
  final segments = <List<GeoPoint>>[
    <GeoPoint>[points.first],
  ];
  for (final point in points.skip(1)) {
    if (!recordedHeatmapSegmentIsContinuous(segments.last.last, point)) {
      segments.add(<GeoPoint>[]);
    }
    segments.last.add(point);
  }
  return [for (final segment in segments) List<GeoPoint>.unmodifiable(segment)];
}
