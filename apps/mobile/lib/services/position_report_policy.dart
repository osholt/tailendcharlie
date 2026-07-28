import '../domain/geo_point.dart';
import '../domain/rider_location.dart';
import 'geo_calculations.dart';

/// Why a fix became a durable position report.
///
/// Named rather than boolean so the reason can be asserted in a test and, more
/// importantly, so the keep-alive is visibly a different thing from a movement
/// report. Conflating the two is what #166 exists to undo.
enum PositionReportReason {
  /// Nothing has been reported yet, so there is no baseline to measure against.
  firstFix,

  /// The rider has travelled at least [PositionReportPolicy.distanceMeters]
  /// since the last report, and has ended up somewhere meaningfully different.
  movedFarEnough,

  /// Withholding this fix would draw the trail somewhere the rider was not: a
  /// fix already withheld sits more than [PositionReportPolicy.shapeToleranceMeters]
  /// from the straight line the two reports would be joined by.
  changedShape,

  /// The keep-alive: nothing has been reported for
  /// [PositionReportPolicy.keepAliveAfter], whether or not the rider has moved.
  keepAlive,
}

extension PositionReportReasonLabels on PositionReportReason {
  /// True when this report exists because of where the rider is, rather than to
  /// prove they are still there.
  bool get isMovement =>
      this == PositionReportReason.movedFarEnough ||
      this == PositionReportReason.changedShape;
}

/// When a GPS fix is worth turning into a durable, relayed position report.
///
/// Three layers decide how often a rider's position is published, and they are
/// deliberately different sizes:
///
///  1. The platform `distanceFilter` (10 m, in `DeviceLocationSource`) decides
///     when the OS wakes this app with a fix at all. It stays **below**
///     [distanceMeters] on purpose. It is the sub-threshold sampler: it gives
///     this policy two or more candidate fixes per reported position, which is
///     what lets the reported path follow the road through a bend rather than
///     cutting across it. Raising it to 20 m would leave the two layers
///     fighting: the app could no longer see inside its own threshold.
///  2. This policy decides which of those fixes becomes a durable
///     `riderLocationUpdated` event — the expensive one: signed, journalled,
///     uploaded, replayed, and drawn as a trail.
///  3. The ephemeral presence channel is *not* gated here. Every fix goes to it,
///     because that channel is a fixed-cost poll that runs whether or not there
///     is anything to say (#134), and presence must never depend on movement.
class PositionReportPolicy {
  const PositionReportPolicy({
    this.distanceMeters = defaultDistanceMeters,
    this.minimumDisplacementMeters = defaultMinimumDisplacementMeters,
    this.shapeToleranceMeters = defaultShapeToleranceMeters,
    this.movingSpeedMetersPerSecond = defaultMovingSpeedMetersPerSecond,
    this.keepAliveAfter = defaultKeepAliveAfter,
  }) : assert(distanceMeters > 0),
       assert(minimumDisplacementMeters >= 0),
       assert(minimumDisplacementMeters < distanceMeters),
       assert(shapeToleranceMeters > 0),
       assert(movingSpeedMetersPerSecond >= 0);

  /// 18 m of **travel**. The field request said "say 20 m"; 20 m measured worse
  /// than 18 m, and this is why.
  ///
  /// A reported position is a vertex and the drawn trail is the chord between
  /// two of them, so the error a threshold introduces is the sagitta of that
  /// chord against the real arc. The case #166 names is a 30 m hairpin — 15 m
  /// radius.
  ///
  /// The threshold can only be met at a *delivered* fix, and the platform
  /// delivers every 10 m, so the reported chord is never the threshold: it is
  /// the first multiple of 10 m at or beyond it. At 20 m the accumulator lands
  /// on that boundary — 19.8 m after two fixes, once real arc steps are summed —
  /// so it slips to the third fix and the chord becomes 30 m, which on a 15 m
  /// radius is the whole diameter. Measured on a six-hairpin road:
  ///
  /// | threshold | reports | worst deviation |
  /// |-----------|---------|-----------------|
  /// | 15 m      | 28/56   | 3.2 m           |
  /// | 18 m      | 28/56   | 3.2 m           |
  /// | 20 m      | 22/56   | 6.9 m           |
  ///
  /// 18 m clears at the second fix with 10% of margin against fix-spacing
  /// jitter, giving 20 m chords and a 3.2 m sagitta — inside the 5 m tolerance
  /// `TrailDisplaySimplifier` already applies to every drawn trail. It costs
  /// nothing: on a 2 km town leg both 18 m and 20 m report 100 of 200 fixes,
  /// because both are more than one platform filter and less than two. Any value
  /// strictly between 10 m and 20 m behaves the same way; the interval, not the
  /// number, is the real constraint.
  ///
  /// Measured as distance travelled along the fixes, not as straight-line
  /// displacement from the last report, and the distinction is not academic: on
  /// a hairpin, displacement grows far more slowly than travel, so a
  /// displacement threshold is not reached until the rider is most of the way
  /// round the bend and the chord then cuts across it. Measured that way the
  /// same hairpin is cut by 16 m.
  static const defaultDistanceMeters = 18.0;

  /// 10 m — one platform filter, half the threshold. The rider has to have ended
  /// up somewhere, not merely accumulated distance.
  ///
  /// This is what stops a stationary phone reporting. A receiver sitting still
  /// wanders, and wander accumulates travel indefinitely while going nowhere; a
  /// travel threshold on its own would read that as a rider moving. Displacement
  /// from the last reported position cannot accumulate, so wander inside ±5 m —
  /// which is what a fix this app accepts looks like — can never clear it.
  static const defaultMinimumDisplacementMeters = 10.0;

  /// 5 m, the same tolerance `TrailDisplaySimplifier` applies to a drawn trail.
  ///
  /// This is the rule that actually holds a bend, and it exists because a
  /// measured attempt to do the job with a bearing-change threshold failed. A
  /// turn measured as the bearing from the last *reported* position is diluted by
  /// however far back that position is: entering a 15 m-radius hairpin 20 m
  /// after the last report, the chord bearing has moved 9°, so every threshold
  /// from 15° to 45° withheld exactly the same fixes and left the bend cut by
  /// 5.7 m.
  ///
  /// Cross-track error does not dilute. A withheld fix that sits more than this
  /// far from the line the trail would be drawn along is a fix whose absence
  /// would put the trail on the wrong side of the road, so it is reported —
  /// which is the same judgement, and the same number, the renderer already
  /// makes when it simplifies. Reporting and drawing therefore cannot disagree
  /// about what "close enough" means.
  static const defaultShapeToleranceMeters = 5.0;

  /// 0.5 m/s — under 2 km/h, below any real riding and above receiver noise.
  ///
  /// A fix reporting less than this is not travel, and neither its distance nor
  /// its shape may be treated as such. Wander on a stationary phone accumulates
  /// travel indefinitely while going nowhere and produces large, random
  /// direction changes; without this guard a receiver sitting still reported
  /// 60 of 300 fixes as movement at a 6 m wander radius, and 150 of 300 at 10 m.
  ///
  /// A fix with no speed at all — an older platform, some simulators — falls
  /// back to [minimumDisplacementMeters] alone rather than being refused.
  static const defaultMovingSpeedMetersPerSecond = 0.5;

  /// 15 s, and it is bounded from above by two thresholds it must not cross:
  ///
  ///  - `RouteDeviationConfig.staleAfter` (30 s). A position older than that is
  ///    reported as `gpsStale` — "No recent GPS position is available" — and at
  ///    90 s it escalates to the coordinators. A stationary rider whose receiver
  ///    is working must never produce that alarm, so the keep-alive has to
  ///    refresh the position well inside 30 s.
  ///  - `PresenceFreshnessPolicy.liveWithin` (20 s). Keeping the interval under
  ///    it means a stationary rider's own marker stays `live` rather than
  ///    flickering to `ageing` between keep-alives.
  ///
  /// 15 s satisfies both with margin and matches the ride shell's existing
  /// staleness-refresh period, so the two ticks stay in step. It is 4 reports a
  /// minute while stationary, against roughly 60 at the 1 Hz the platform
  /// delivers while moving.
  static const defaultKeepAliveAfter = Duration(seconds: 15);

  final double distanceMeters;
  final double minimumDisplacementMeters;
  final double shapeToleranceMeters;
  final double movingSpeedMetersPerSecond;
  final Duration keepAliveAfter;
}

/// The running decision for one rider's fixes. Stateful, because every rule is
/// relative to what was last reported.
class PositionReportGate {
  PositionReportGate({this.policy = const PositionReportPolicy()});

  final PositionReportPolicy policy;

  /// A withheld fix is kept only long enough to judge the shape of the leg it
  /// sits in. The travel threshold divided by the platform filter bounds this at
  /// two or three while moving; a stationary keep-alive window is the only case
  /// that fills it, and those fixes are all in the same place.
  static const _maximumWithheld = 64;

  GeoPoint? _reportedPosition;
  DateTime? _reportedAt;
  GeoPoint? _lastFixPosition;

  /// Fixes withheld since the last report, oldest first.
  final List<GeoPoint> _withheld = [];

  /// Distance travelled along the fixes seen since the last report. Reset on
  /// every report, never on a withheld fix — that accumulation is the whole
  /// point.
  double _travelledSinceReport = 0;

  /// The last position this gate agreed to report, or null before the first.
  GeoPoint? get lastReportedPosition => _reportedPosition;

  /// When the last reported fix was recorded, or null before the first.
  DateTime? get lastReportedAt => _reportedAt;

  /// Distance travelled since the last report, in metres.
  double get travelledSinceReportMeters => _travelledSinceReport;

  /// Whether [sample] should become a durable position report, and why.
  ///
  /// Returns null to withhold it. Withholding is not discarding: the fix has
  /// already gone to the ephemeral presence channel by the time this is asked,
  /// so the group still sees the rider. What is withheld is a journal event.
  ///
  /// Judged on [LocationSample.recordedAt] rather than a wall clock, so a
  /// replayed or simulated fix sequence behaves identically to a live one.
  PositionReportReason? consider(LocationSample sample) {
    final reason = _reasonFor(sample);
    if (reason == null) {
      _lastFixPosition = sample.position;
      if (_withheld.length < _maximumWithheld) _withheld.add(sample.position);
      return null;
    }
    _accept(sample);
    return reason;
  }

  PositionReportReason? _reasonFor(LocationSample sample) {
    final previous = _reportedPosition;
    final previousAt = _reportedAt;
    if (previous == null || previousAt == null) {
      return PositionReportReason.firstFix;
    }
    // An out-of-order fix says nothing new about where the rider is now, and
    // accepting it would rewind the baseline every rule is measured against.
    if (!sample.recordedAt.isAfter(previousAt)) return null;
    final moving = _isMoving(sample);
    if (moving) {
      _travelledSinceReport += GeoCalculations.distanceMeters(
        _lastFixPosition ?? previous,
        sample.position,
      );
    }
    final displacement = GeoCalculations.distanceMeters(
      previous,
      sample.position,
    );
    if (displacement >= policy.minimumDisplacementMeters) {
      if (_travelledSinceReport >= policy.distanceMeters) {
        return PositionReportReason.movedFarEnough;
      }
      if (moving && _wouldMisdrawTrail(previous, sample.position)) {
        return PositionReportReason.changedShape;
      }
    }
    if (sample.recordedAt.difference(previousAt) >= policy.keepAliveAfter) {
      return PositionReportReason.keepAlive;
    }
    return null;
  }

  /// Whether the platform says this fix is travel rather than a stationary
  /// receiver wandering. A fix with no speed is given the benefit of the doubt,
  /// because refusing it would stop a whole platform reporting at all.
  bool _isMoving(LocationSample sample) {
    final speed = sample.speedMetersPerSecond;
    return speed == null || speed >= policy.movingSpeedMetersPerSecond;
  }

  /// Whether joining [previous] straight to [candidate] would put the trail more
  /// than [PositionReportPolicy.shapeToleranceMeters] from a place the rider
  /// demonstrably was.
  bool _wouldMisdrawTrail(GeoPoint previous, GeoPoint candidate) {
    for (final point in _withheld) {
      final distance = GeoCalculations.distanceToPolylineMeters(point, [
        previous,
        candidate,
      ]);
      if (distance > policy.shapeToleranceMeters) return true;
    }
    return false;
  }

  void _accept(LocationSample sample) {
    _reportedPosition = sample.position;
    _reportedAt = sample.recordedAt;
    _lastFixPosition = sample.position;
    _travelledSinceReport = 0;
    _withheld.clear();
  }

  /// Forgets the baseline, so the next fix reports unconditionally. Used when
  /// the rider's reporting stops and starts again — a ride start, or location
  /// sharing being turned back on — because the gap in between is not travel.
  void reset() {
    _reportedPosition = null;
    _reportedAt = null;
    _lastFixPosition = null;
    _travelledSinceReport = 0;
    _withheld.clear();
  }
}
