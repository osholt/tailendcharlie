import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../domain/geo_point.dart';
import 'geo_calculations.dart';
import 'leader_ride_status.dart' show TecAvailability;

/// Which way the gap to the Tail End Charlie is going.
///
/// Requested from the field, with the reasoning:
///
/// > for lead and tec, distance between is often less relevant than distance
/// > trend. Could we have the 'distance to tec' field RAG for 'Tec stopped /
/// > about the same speed / distance closing' or similar?
///
/// A leader reading "1.2 miles" learns almost nothing - on a fast road that is
/// normal, in town it means the group has split. The same number *falling* means
/// the group is coming back together, and *rising* means it is coming apart. Only
/// the second reading tells a leader whether to slow down (#181).
enum TecGapTrend {
  /// Not enough recent, trustworthy samples to say. Also every state where the
  /// TEC's position cannot be trusted - a stale fix must never read as a
  /// stopped rider, which is the distinction #132 and #134 both turned on.
  unknown,

  /// The TEC is not moving. A claim about the rider, not about the gap.
  stopped,

  /// The gap is shrinking.
  closing,

  /// The gap is holding station.
  holding,

  /// The gap is growing. The state the original request did not list, and the
  /// one that actually tells a leader to ease off.
  opening,
}

extension TecGapTrendLabel on TecGapTrend {
  /// Paired with colour, never replaced by it. Riders wear tinted visors in
  /// direct sunlight - the condition #107 and #143 exist for - and some riders
  /// cannot tell red from green at all.
  String get label => switch (this) {
    TecGapTrend.unknown => 'Trend unknown',
    TecGapTrend.stopped => 'TEC stopped',
    TecGapTrend.closing => 'Closing',
    TecGapTrend.holding => 'Holding',
    TecGapTrend.opening => 'Opening',
  };

  /// A shape as well as a word, so the meaning survives a glance.
  String get arrow => switch (this) {
    TecGapTrend.unknown => '·',
    TecGapTrend.stopped => '■',
    TecGapTrend.closing => '↓',
    TecGapTrend.holding => '=',
    TecGapTrend.opening => '↑',
  };
}

@immutable
class _GapSample {
  const _GapSample({
    required this.at,
    required this.gapMeters,
    required this.tecPosition,
  });

  final DateTime at;
  final double gapMeters;
  final GeoPoint? tecPosition;
}

/// Tracks the gap to the TEC over time and reports which way it is going.
///
/// Stateful because a trend is not a property of one fix. Position fixes are
/// noisy and arrive irregularly, so a naive difference between the last two
/// samples flickers between closing and opening while nothing has really
/// changed - which would be worse than showing no trend at all.
class TecGapTrendTracker {
  TecGapTrendTracker({
    this.window = const Duration(seconds: 30),
    this.minimumRateMetersPerSecond = 0.6,
    this.stoppedMovementMeters = 15,
    this.minimumSamples = 3,
  }) : assert(minimumRateMetersPerSecond > 0),
       assert(minimumSamples >= 2);

  /// How much history the trend is fitted over.
  ///
  /// 30 seconds: long enough that GPS noise and one slow corner do not flip the
  /// state, short enough that a genuine split shows up while the leader can
  /// still act on it. At the configured 10 m position filter that is several
  /// samples on a moving bike.
  final Duration window;

  /// The rate a gap has to change at, sustained across [window], before it
  /// counts as closing or opening rather than holding.
  ///
  /// 0.6 m/s is about 2 km/h of difference between two riders - below that they
  /// are riding the same speed and the number is drifting, not moving.
  final double minimumRateMetersPerSecond;

  /// How little the TEC may move across [window] and still be called stopped.
  /// Wide enough to absorb a stationary fix wandering, tight enough that walking
  /// pace is not "stopped".
  final double stoppedMovementMeters;

  final int minimumSamples;

  final List<_GapSample> _samples = [];

  /// Forgets the history. Used when the TEC changes, or the role moves: the
  /// previous rider's gap says nothing about the new one's.
  void reset() => _samples.clear();

  @visibleForTesting
  int get sampleCount => _samples.length;

  /// Feeds one reading in and returns the current trend.
  ///
  /// [availability] is the one TEC model from `leader_ride_status.dart`. Anything
  /// other than tracking clears the history and reports [TecGapTrend.unknown]:
  /// a gap computed from a fix that can no longer be trusted is not a gap, and a
  /// TEC whose position has gone stale is emphatically not a stopped rider.
  TecGapTrend update({
    required TecAvailability availability,
    required double? gapMeters,
    required GeoPoint? tecPosition,
    required DateTime now,
  }) {
    if (availability != TecAvailability.tracking || gapMeters == null) {
      _samples.clear();
      return TecGapTrend.unknown;
    }
    _samples.add(
      _GapSample(at: now, gapMeters: gapMeters, tecPosition: tecPosition),
    );
    final cutoff = now.subtract(window);
    _samples.removeWhere((sample) => sample.at.isBefore(cutoff));
    if (_samples.length < minimumSamples) return TecGapTrend.unknown;

    final elapsed = _samples.last.at.difference(_samples.first.at);
    // A window's worth of samples that all arrived in the same instant says
    // nothing about a rate.
    if (elapsed.inMilliseconds <= 0) return TecGapTrend.unknown;

    if (_tecHasStopped()) return TecGapTrend.stopped;

    final rate = _gapRateMetersPerSecond();
    if (rate <= -minimumRateMetersPerSecond) return TecGapTrend.closing;
    if (rate >= minimumRateMetersPerSecond) return TecGapTrend.opening;
    return TecGapTrend.holding;
  }

  /// Whether the TEC's own positions have barely moved across the window.
  ///
  /// Deliberately about the rider's positions rather than about the gap: a gap
  /// can hold steady with both riders doing 60, and that is not stopped.
  bool _tecHasStopped() {
    final positions = _samples
        .map((sample) => sample.tecPosition)
        .whereType<GeoPoint>()
        .toList(growable: false);
    if (positions.length < minimumSamples) return false;
    if (_samples.last.at.difference(_samples.first.at) < window ~/ 2) {
      // Too little history to call somebody stopped; they may have just been
      // picked up at a set of lights.
      return false;
    }
    for (final position in positions.skip(1)) {
      if (GeoCalculations.distanceMeters(positions.first, position) >
          stoppedMovementMeters) {
        return false;
      }
    }
    return true;
  }

  /// Median of the pairwise slopes of gap against time, in metres per second.
  ///
  /// Theil-Sen rather than least squares. A least-squares fit is not robust to
  /// outliers, and a bad fix - or a position projected onto a folded route -
  /// moves the gap by hundreds of metres for one sample. On a four-point window
  /// a single 400 m spike drags a least-squares slope to 3.8 m/s and reports a
  /// gap opening when nothing has changed. Taking the median of the slopes
  /// between every pair of samples ignores it, which is what the "does not
  /// flicker" requirement in #181 actually needs.
  double _gapRateMetersPerSecond() {
    final slopes = <double>[];
    for (var first = 0; first < _samples.length - 1; first += 1) {
      for (var second = first + 1; second < _samples.length; second += 1) {
        final seconds =
            _samples[second].at.difference(_samples[first].at).inMilliseconds /
            1000;
        if (seconds <= 0) continue;
        slopes.add(
          (_samples[second].gapMeters - _samples[first].gapMeters) / seconds,
        );
      }
    }
    if (slopes.isEmpty) return 0;
    slopes.sort();
    final middle = slopes.length ~/ 2;
    return slopes.length.isOdd
        ? slopes[middle]
        : (slopes[middle - 1] + slopes[middle]) / 2;
  }

  /// The window a surface should state, so the number a rider reads is
  /// attributable rather than magic.
  String get windowDescription =>
      'over the last ${math.max(1, window.inSeconds)} seconds';
}
