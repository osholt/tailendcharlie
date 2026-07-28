import 'dart:math' as math;

import '../domain/imported_route.dart' show GeoPoint;
import 'trail_display_simplifier.dart';

/// Turns a recorded GPS track into the line the rider meant to ride.
///
/// A recording is not a plan. Riding a route produces a fix roughly every 10 m
/// — the platform `distanceFilter` — plus a cluster of wandering fixes at every
/// place the bike stopped, because a stationary phone still reports movement
/// when the fix drifts. Handing that straight back as a route gives a rider a
/// line that stutters at every set of lights and doubles back on itself in
/// every car park.
///
/// Two passes, in this order, because they remove different things:
///
/// 1. **Dwell collapse.** A run of consecutive fixes that all stay within
///    [dwellRadiusMeters] of where the run started, and that is at least
///    [minimumDwellFixes] long, is the bike standing still. It collapses to the
///    single fix the run began at.
/// 2. **Ramer-Douglas-Peucker**, via the shared [TrailDisplaySimplifier], which
///    removes the remaining along-the-road jitter and bounds the point count.
///
/// What this deliberately does **not** do is guess. A wrong turn, a fuel stop
/// detour and a lap of a car park are all roads the bike genuinely rode, and
/// nothing here can tell them apart from the route. They survive, and the
/// rider is told so when they pick a recording (#155).
class RecordedTrackCleaner {
  const RecordedTrackCleaner({
    this.dwellRadiusMeters = 15,
    this.minimumDwellFixes = 4,
    this.simplifier = const TrailDisplaySimplifier(),
  }) : assert(dwellRadiusMeters > 0),
       assert(minimumDwellFixes >= 2);

  /// 15 m, a little above the worst civilian-GPS wander a stationary phone
  /// reports, and below the spacing a moving bike produces.
  final double dwellRadiusMeters;

  /// A run this long or longer is a stop. Two or three fixes inside the radius
  /// is what a bike rounding a tight bend looks like, and a hairpin apex must
  /// not be mistaken for a stop, so short runs are left completely alone.
  final int minimumDwellFixes;

  final TrailDisplaySimplifier simplifier;

  /// The tidied track. The first and last fixes are always kept, so a route
  /// never appears to begin or end somewhere the rider was not.
  ///
  /// Returns [points] unchanged when tidying cannot leave a usable line — a
  /// two-point track, or a recording that is one long stop.
  List<GeoPoint> clean(List<GeoPoint> points) {
    if (points.length <= 2) return points;
    final withoutDwells = _collapseDwells(points);
    if (withoutDwells.length < 2) return points;
    final simplified = simplifier.simplify(withoutDwells);
    return simplified.length < 2 ? withoutDwells : simplified;
  }

  List<GeoPoint> _collapseDwells(List<GeoPoint> points) {
    final metresPerDegreeLongitude =
        _metresPerDegreeLatitude *
        math.cos(points[points.length ~/ 2].latitude * math.pi / 180).abs();
    final kept = <GeoPoint>[];
    var index = 0;
    while (index < points.length) {
      var end = index;
      while (end + 1 < points.length &&
          _metersBetween(
                points[index],
                points[end + 1],
                metresPerDegreeLongitude,
              ) <=
              dwellRadiusMeters) {
        end += 1;
      }
      kept.add(points[index]);
      // A run shorter than a stop is ordinary riding: advance one fix so its
      // geometry is handed to the simplifier intact.
      index = end - index + 1 >= minimumDwellFixes ? end + 1 : index + 1;
    }
    // A dwell that runs to the end of the recording swallows the final fix.
    if (!identical(kept.last, points.last)) kept.add(points.last);
    return kept;
  }

  /// Equirectangular, evaluated once at the track's own latitude — the same
  /// approximation [TrailDisplaySimplifier] makes and for the same reason: a
  /// single ride never spans enough latitude for it to drift meaningfully, and
  /// it keeps a per-fix comparison to flat arithmetic.
  double _metersBetween(
    GeoPoint first,
    GeoPoint second,
    double metresPerDegreeLongitude,
  ) {
    final x = (second.longitude - first.longitude) * metresPerDegreeLongitude;
    final y = (second.latitude - first.latitude) * _metresPerDegreeLatitude;
    return math.sqrt(x * x + y * y);
  }

  static const _metresPerDegreeLatitude = 111132.0;
}
