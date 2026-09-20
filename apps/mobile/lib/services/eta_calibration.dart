import 'dart:math' as math;

import '../domain/completed_ride.dart';
import '../domain/imported_route.dart';
import 'ride_timing_analysis.dart';

/// Broad provider-average-speed bands describe road mix without transmitting
/// locations, trip dates, distances, timestamps or a rider's absolute speed.
String etaBand(ImportedRoute route) {
  final seconds = route.plannedDuration?.inSeconds ?? 0;
  if (seconds <= 0) return 'mixed';
  final kph = rideRouteLength(route) / seconds * 3.6;
  return kph < 40
      ? 'urban'
      : kph < 75
      ? 'mixed'
      : 'open';
}

class EtaCalibration {
  const EtaCalibration(this.ratios);
  static const empty = EtaCalibration({});
  final Map<String, List<double>> ratios;
  int get sampleCount =>
      ratios.values.fold(0, (n, values) => n + values.length);

  factory EtaCalibration.fromRides(
    Iterable<CompletedRide> rides, {
    DateTime? since,
  }) {
    final values = <String, List<double>>{};
    final seen = <String>{};
    final ordered = rides.toList()
      ..sort((a, b) => b.endedAt.compareTo(a.endedAt));
    for (final ride in ordered) {
      if (!ride.recordingComplete ||
          ride.libraryStatus != RideLibraryStatus.active ||
          !seen.add(ride.rideId) ||
          (since != null && !ride.startedAt.isAfter(since))) {
        continue;
      }
      final plan = ride.plannedRoute;
      final estimate = plan?.plannedDuration?.inSeconds ?? 0;
      if (plan == null || estimate < 600) continue;
      final band = etaBand(plan);
      if ((values[band]?.length ?? 0) >= 30) continue;
      final timing = RideTimingAnalysis.fromRoute(ride.traveledRoute);
      if (timing == null || !timing.reliable) continue;
      final plannedLength = rideRouteLength(plan);
      if (plannedLength < 10000) continue;
      final lengthRatio = timing.distanceMeters / plannedLength;
      if (lengthRatio < .9 || lengthRatio > 1.1) continue;
      final planPoints = [for (final path in plan.paths) ...path.points];
      if (planPoints.length < 2 ||
          ridePointDistance(planPoints.first, timing.points.first) > 300 ||
          ridePointDistance(planPoints.last, timing.points.last) > 300) {
        continue;
      }
      // Ensure similar length is also the same corridor. Segment projection
      // accommodates sparse GPXs without requiring exact point matches.
      final stride = math.max(1, (timing.points.length / 80).ceil());
      var matched = 0;
      var tested = 0;
      for (var i = 0; i < timing.points.length; i += stride) {
        tested++;
        if (_nearPlan(timing.points[i], plan)) matched++;
      }
      if (matched / tested < .9) continue;
      final ratio = timing.travelling.inSeconds / estimate;
      if (ratio < .6 || ratio > 1.6) continue;
      values.putIfAbsent(band, () => []).add(ratio);
    }
    return EtaCalibration(values);
  }

  double factorFor(ImportedRoute route, {double populationFactor = 1}) {
    final samples = ratios[etaBand(route)] ?? const [];
    final prior = populationFactor.clamp(.85, 1.15);
    if (samples.length < 3) return prior.toDouble();
    final sorted = samples.toList()..sort();
    final median = sorted.length.isOdd
        ? sorted[sorted.length ~/ 2]
        : (sorted[sorted.length ~/ 2 - 1] + sorted[sorted.length ~/ 2]) / 2;
    // A few trips cannot overwrite the provider. Evidence builds gradually;
    // one unusually quick or slow journey cannot dominate a median.
    final weight = samples.length / (samples.length + 8);
    return (prior + (median - prior) * weight).clamp(.8, 1.2).toDouble();
  }

  Map<String, double> get anonymousProfile => {
    for (final entry in ratios.entries)
      if (entry.value.length >= 3) entry.key: _roundedMedian(entry.value),
  };
}

double _roundedMedian(List<double> values) {
  final sorted = values.toList()..sort();
  final median = sorted.length.isOdd
      ? sorted[sorted.length ~/ 2]
      : (sorted[sorted.length ~/ 2 - 1] + sorted[sorted.length ~/ 2]) / 2;
  return (median.clamp(.8, 1.2) * 20).round() / 20;
}

bool _nearPlan(GeoPoint point, ImportedRoute plan) {
  const metresPerDegree = 111195.0;
  final xScale = metresPerDegree * math.cos(point.latitude * math.pi / 180);
  for (final path in plan.paths) {
    for (var i = 1; i < path.points.length; i++) {
      final a = path.points[i - 1], b = path.points[i];
      final ax = (a.longitude - point.longitude) * xScale,
          ay = (a.latitude - point.latitude) * metresPerDegree;
      final bx = (b.longitude - point.longitude) * xScale,
          by = (b.latitude - point.latitude) * metresPerDegree;
      final dx = bx - ax, dy = by - ay;
      final squared = dx * dx + dy * dy;
      final t = squared == 0 ? 0 : (-(ax * dx + ay * dy) / squared).clamp(0, 1);
      if (math.pow(ax + t * dx, 2) + math.pow(ay + t * dy, 2) <= 10000) {
        return true;
      }
    }
  }
  return false;
}
