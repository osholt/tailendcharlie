import 'dart:math' as math;

import '../domain/imported_route.dart';

/// Below continental scale even spaced icons obscure more than they explain.
const discoveryMinimumZoom = 6.0;

class DiscoveryMarkerCandidate<T> {
  const DiscoveryMarkerCandidate({
    required this.id,
    required this.point,
    required this.value,
    this.group = '',
  });
  final String id;
  final GeoPoint point;
  final T value;
  final String group;
}

/// Keep useful discoveries at regional zooms, with one shared space budget for
/// cafés and roads. Positions use logical map pixels, independent of device DPI.
/// Stable IDs keep markers from changing simply because catalogue order changes.
List<T> selectDiscoveryMarkers<T>(
  Iterable<DiscoveryMarkerCandidate<T>> candidates, {
  required double zoom,
  List<GeoPoint> viewport = const [],
  double separationPixels = 56,
  int maximumMarkers = 64,
  double tileSize = 256,
}) {
  if (!zoom.isFinite || zoom < discoveryMinimumZoom || maximumMarkers <= 0) {
    return [];
  }
  final worldSize = tileSize * math.pow(2, zoom);
  math.Point<double> project(GeoPoint point) {
    final sin = math.sin(
      point.latitude.clamp(-85.051129, 85.051129) * math.pi / 180,
    );
    return math.Point(
      (point.longitude + 180) / 360 * worldSize,
      (.5 - math.log((1 + sin) / (1 - sin)) / (4 * math.pi)) * worldSize,
    );
  }

  final bounds = viewport.map(project).toList();
  final west = bounds.isEmpty
      ? double.negativeInfinity
      : bounds.map((p) => p.x).reduce(math.min);
  final east = bounds.isEmpty
      ? double.infinity
      : bounds.map((p) => p.x).reduce(math.max);
  final north = bounds.isEmpty
      ? double.negativeInfinity
      : bounds.map((p) => p.y).reduce(math.min);
  final south = bounds.isEmpty
      ? double.infinity
      : bounds.map((p) => p.y).reduce(math.max);
  final groups = <String, List<DiscoveryMarkerCandidate<T>>>{};
  for (final candidate in candidates) {
    final point = project(candidate.point);
    if (point.x < west ||
        point.x > east ||
        point.y < north ||
        point.y > south) {
      continue;
    }
    groups.putIfAbsent(candidate.group, () => []).add(candidate);
  }
  for (final group in groups.values) {
    group.sort((a, b) => a.id.compareTo(b.id));
  }
  final keys = groups.keys.toList()..sort();
  // Alternate categories before applying the shared spacing/count budget so
  // many cafés cannot use every slot before the first riding road is considered.
  final sorted = <DiscoveryMarkerCandidate<T>>[
    for (
      var index = 0;
      groups.values.any((group) => index < group.length);
      index++
    )
      for (final key in keys)
        if (index < groups[key]!.length) groups[key]![index],
  ];
  final selected = <T>[];
  final positions = <math.Point<double>>[];
  for (final candidate in sorted) {
    final point = project(candidate.point);
    if (!point.x.isFinite ||
        !point.y.isFinite ||
        point.x < west ||
        point.x > east ||
        point.y < north ||
        point.y > south) {
      continue;
    }
    if (positions.any((old) => old.distanceTo(point) < separationPixels)) {
      continue;
    }
    selected.add(candidate.value);
    positions.add(point);
    if (selected.length >= maximumMarkers) break;
  }
  return selected;
}
