// Which way the gap to the TEC is going (#181).
//
//   "for lead and tec, distance between is often less relevant than distance
//    trend. Could we have the 'distance to tec' field RAG for 'Tec stopped /
//    about the same speed / distance closing' or similar?"
//
// The cases that matter most are the two the request did not name: a gap that is
// *opening*, which is what tells a leader to ease off, and a **stale** fix, which
// must never read as a stopped rider. #132 and #134 both turned on that second
// distinction.

import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/geo_point.dart';
import 'package:ride_relay/services/leader_ride_status.dart'
    show TecAvailability;
import 'package:ride_relay/services/tec_gap_trend.dart';

void main() {
  final start = DateTime.utc(2026, 7, 28, 10);

  /// Feeds a sequence of gaps at 10-second intervals and returns the last trend.
  TecGapTrend trendFor(
    List<double> gaps, {
    TecAvailability availability = TecAvailability.tracking,
    GeoPoint? Function(int index)? tecPosition,
    TecGapTrendTracker? tracker,
  }) {
    final subject = tracker ?? TecGapTrendTracker();
    var trend = TecGapTrend.unknown;
    for (final (index, gap) in gaps.indexed) {
      trend = subject.update(
        availability: availability,
        gapMeters: gap,
        tecPosition: tecPosition?.call(index) ?? _movingTec(index),
        now: start.add(Duration(seconds: 10 * index)),
      );
    }
    return trend;
  }

  group('the three states the request asked for', () {
    test('a shrinking gap is closing', () {
      // 20 m/s of closure - a leader easing off while the TEC catches up.
      expect(trendFor([1200, 1000, 800, 600]), TecGapTrend.closing);
    });

    test('a steady gap is holding', () {
      // Both riding the same speed, with the number drifting on GPS noise.
      expect(trendFor([800, 803, 797, 801]), TecGapTrend.holding);
    });

    test('a stationary TEC is stopped', () {
      expect(
        trendFor(
          [400, 600, 800, 1000],
          tecPosition: (_) => const GeoPoint(latitude: 51.46, longitude: -2.5),
        ),
        TecGapTrend.stopped,
        reason: 'stopped is a claim about the rider, not about the gap',
      );
    });
  });

  group('the state the request did not name', () {
    test('a growing gap is opening', () {
      expect(
        trendFor([600, 800, 1000, 1200]),
        TecGapTrend.opening,
        reason: 'this is the one that tells a leader to slow down',
      );
    });

    test('opening is distinguished from stopped by the TEC moving', () {
      // Identical gaps to the stopped case above; the difference is that the TEC
      // is travelling.
      expect(trendFor([400, 600, 800, 1000]), TecGapTrend.opening);
    });
  });

  group('a fix that cannot be trusted is never a stopped rider', () {
    for (final availability in [
      TecAvailability.none,
      TecAvailability.awaitingLocation,
      TecAvailability.stale,
    ]) {
      test('${availability.name} reads as unknown', () {
        expect(
          trendFor([1000, 1000, 1000, 1000], availability: availability),
          TecGapTrend.unknown,
        );
      });
    }

    test('going stale clears the history rather than freezing a trend', () {
      final tracker = TecGapTrendTracker();
      trendFor([1200, 1000, 800, 600], tracker: tracker);
      expect(tracker.sampleCount, greaterThan(0));

      final trend = tracker.update(
        availability: TecAvailability.stale,
        gapMeters: null,
        tecPosition: null,
        now: start.add(const Duration(seconds: 40)),
      );

      expect(trend, TecGapTrend.unknown);
      expect(
        tracker.sampleCount,
        0,
        reason: 'a resumed TEC starts a fresh trend, not the old one',
      );
    });
  });

  group('it does not flicker', () {
    test('too few samples says unknown rather than guessing', () {
      expect(trendFor([1000, 900]), TecGapTrend.unknown);
    });

    test('noise around a steady gap never reads as closing or opening', () {
      // +/- 12 m of jitter on an 800 m gap, which is well inside a phone fix.
      const jitter = <double>[800, 812, 788, 806, 794, 809, 791, 803];
      expect(trendFor(jitter), TecGapTrend.holding);
    });

    test('one wild fix does not decide the state', () {
      // A steady gap with a single 400 m outlier in the middle. A last-minus-
      // first difference would call this closing; a fit does not.
      expect(trendFor([800, 805, 400, 802, 798]), TecGapTrend.holding);
    });

    test('samples older than the window are dropped', () {
      final tracker = TecGapTrendTracker(window: const Duration(seconds: 30));
      // Four samples at 10 s intervals fills the window exactly; a fifth pushes
      // the first out.
      for (var index = 0; index < 5; index += 1) {
        tracker.update(
          availability: TecAvailability.tracking,
          gapMeters: 800,
          tecPosition: _movingTec(index),
          now: start.add(Duration(seconds: 10 * index)),
        );
      }
      expect(tracker.sampleCount, lessThanOrEqualTo(4));
    });
  });

  group('what a rider reads', () {
    test('every trend has a word and a shape, not just a colour', () {
      for (final trend in TecGapTrend.values) {
        expect(trend.label, isNotEmpty, reason: '${trend.name} has no label');
        expect(trend.arrow, isNotEmpty, reason: '${trend.name} has no shape');
      }
    });

    test('the labels are distinct, so two states cannot read alike', () {
      final labels = TecGapTrend.values.map((trend) => trend.label).toSet();
      expect(labels, hasLength(TecGapTrend.values.length));
    });

    test('the smoothing window is stated rather than magic', () {
      expect(
        TecGapTrendTracker(
          window: const Duration(seconds: 30),
        ).windowDescription,
        'over the last 30 seconds',
      );
    });
  });
}

/// A TEC travelling steadily north, so the stopped check does not fire.
GeoPoint _movingTec(int index) =>
    GeoPoint(latitude: 51.46 + index * 0.002, longitude: -2.5);
