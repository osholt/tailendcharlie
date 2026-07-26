import 'dart:math' as math;

/// Normalises any bearing onto `[0, 360)`.
double normaliseBearingDegrees(double degrees) {
  final wrapped = degrees % 360;
  return wrapped < 0 ? wrapped + 360 : wrapped;
}

/// Signed shortest angular distance from [from] to [to], in `(-180, 180]`.
///
/// Every comparison in the smoother goes through this, which is what keeps
/// 359 degrees to 1 degree a two degree turn to the right rather than a 358
/// degree sweep the long way round.
double shortestBearingDeltaDegrees(double to, double from) {
  final delta = (to - from + 540) % 360;
  return (delta < 0 ? delta + 360 : delta) - 180;
}

/// Turns a noisy per-fix GPS course into a bearing the map can be rotated to.
///
/// ## Which source is authoritative
///
/// GPS course over ground is the only source used to rotate the map, and only
/// at or above [freezeBelowMetersPerSecond]. A device compass is deliberately
/// never mixed in: a phone clamped to a steel motorcycle sits inside the
/// bike's own magnetic field and next to its charging loom, so its magnetometer
/// heading is unreliable exactly where it would be needed. The single
/// exception is the very first bearing of a ride, when no course has ever been
/// observed and holding an arbitrary north-up map would be worse than adopting
/// whatever heading the platform supplies. Below the freeze speed the last
/// stable bearing is held, so a stationary bike does not make the map wander.
///
/// ## What the smoother does, in order
///
/// 1. **Outlier rejection.** A course change larger than [outlierDegrees] is
///    not animated to. It is remembered, and adopted only when a following fix
///    corroborates it, so a tunnel re-acquisition or a single bad fix costs one
///    update of latency instead of spinning the map.
/// 2. **Low pass.** The accepted course feeds a first-order filter with a
///    [smoothingTimeConstant] time constant, which removes per-fix jitter.
/// 3. **Deadband.** While the filtered heading stays within [deadbandDegrees]
///    of the committed bearing the map does not rotate at all, so ordinary road
///    curvature produces no movement. Once that band is broken the smoother
///    tracks continuously until the two agree to within [settleDegrees], so a
///    long sweeping bend rotates smoothly instead of ratcheting in steps.
///    [maneuverDeadbandDegrees] replaces the deadband when a manoeuvre is
///    imminent, so the bearing cannot lag at the junction the rider is being
///    told about.
/// 4. **Rate limit.** Each step is capped at
///    [maximumRotationDegreesPerSecond], so a genuine change eases to the new
///    bearing over a bounded time: about 2 seconds for a 90 degree junction and
///    4 seconds for a full reversal, plus the filter's own lag.
class NavigationHeadingSmoother {
  NavigationHeadingSmoother({
    this.deadbandDegrees = 9,
    this.maneuverDeadbandDegrees = 3,
    this.settleDegrees = 1.5,
    this.maximumRotationDegreesPerSecond = 45,
    this.smoothingTimeConstant = const Duration(milliseconds: 900),
    this.freezeBelowMetersPerSecond = 1.5,
    this.outlierDegrees = 95,
    this.outlierCorroborationDegrees = 30,
    this.maximumStepInterval = const Duration(seconds: 2),
  });

  final double deadbandDegrees;
  final double maneuverDeadbandDegrees;
  final double settleDegrees;
  final double maximumRotationDegreesPerSecond;
  final Duration smoothingTimeConstant;
  final double freezeBelowMetersPerSecond;
  final double outlierDegrees;
  final double outlierCorroborationDegrees;
  final Duration maximumStepInterval;

  double? _bearing;
  double? _filtered;
  double? _pendingOutlier;
  DateTime? _lastSampleAt;
  bool _settling = false;

  /// The bearing the map should currently be rotated to, or null before any
  /// usable heading has been observed.
  double? get bearingDegrees => _bearing;

  /// True while the smoother is still easing towards a new bearing.
  bool get settling => _settling;

  void reset() {
    _bearing = null;
    _filtered = null;
    _pendingOutlier = null;
    _lastSampleAt = null;
    _settling = false;
  }

  /// Folds one position fix into the camera bearing and returns the bearing to
  /// use. The result only changes when the rules above allow it, so callers can
  /// hand it straight to the map on every fix.
  double? update({
    required double? headingDegrees,
    required double? speedMetersPerSecond,
    required DateTime at,
    bool maneuverImminent = false,
  }) {
    if (headingDegrees == null || !headingDegrees.isFinite) return _bearing;
    final heading = normaliseBearingDegrees(headingDegrees);
    final speed = (speedMetersPerSecond ?? 0).isFinite
        ? (speedMetersPerSecond ?? 0)
        : 0.0;

    if (_bearing == null || _filtered == null) {
      // First usable heading of the ride: adopt it rather than starting the
      // map north-up and rotating away from it.
      _bearing = heading;
      _filtered = heading;
      _lastSampleAt = at;
      _settling = false;
      return _bearing;
    }

    if (speed < freezeBelowMetersPerSecond) {
      // Stationary or crawling: the reported course is noise. Hold the last
      // stable bearing and keep the clock moving so the first moving fix is
      // rate limited from now rather than from the last moving fix.
      _lastSampleAt = at;
      _pendingOutlier = null;
      return _bearing;
    }

    final intervalSeconds = _intervalSeconds(at);
    _lastSampleAt = at;

    final sampleDelta = shortestBearingDeltaDegrees(heading, _filtered!);
    if (sampleDelta.abs() > outlierDegrees) {
      final pending = _pendingOutlier;
      if (pending == null ||
          shortestBearingDeltaDegrees(heading, pending).abs() >
              outlierCorroborationDegrees) {
        _pendingOutlier = heading;
        return _bearing;
      }
      // A second fix agrees: the jump is real (a hairpin, or a fix recovered
      // after a tunnel). Accept it into the filter and let the rate limit
      // below ease the map round.
      _pendingOutlier = null;
      _filtered = heading;
    } else {
      _pendingOutlier = null;
      final alpha =
          1 -
          math.exp(
            -intervalSeconds / (smoothingTimeConstant.inMilliseconds / 1000),
          );
      _filtered = normaliseBearingDegrees(_filtered! + sampleDelta * alpha);
    }

    final deadband = maneuverImminent
        ? maneuverDeadbandDegrees
        : deadbandDegrees;
    final pendingDelta = shortestBearingDeltaDegrees(_filtered!, _bearing!);
    if (_settling) {
      if (pendingDelta.abs() <= settleDegrees) {
        _settling = false;
        return _bearing;
      }
    } else if (pendingDelta.abs() < deadband) {
      return _bearing;
    } else {
      _settling = true;
    }

    final maximumStep = maximumRotationDegreesPerSecond * intervalSeconds;
    final step = pendingDelta.clamp(-maximumStep, maximumStep);
    _bearing = normaliseBearingDegrees(_bearing! + step);
    return _bearing;
  }

  /// Seconds since the previous accepted sample, bounded so a long gap in
  /// fixes cannot turn into an unbounded rotation step or a filter that jumps
  /// straight to the new heading.
  double _intervalSeconds(DateTime at) {
    final previous = _lastSampleAt;
    if (previous == null) return 1;
    final elapsed = at.difference(previous);
    if (elapsed <= Duration.zero) return 0.05;
    final bounded = elapsed > maximumStepInterval
        ? maximumStepInterval
        : elapsed;
    return math.max(0.05, bounded.inMilliseconds / 1000);
  }
}
