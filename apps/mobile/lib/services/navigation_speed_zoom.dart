import 'dart:math' as math;

/// How far the follow camera's zoom moves with road speed (#936).
///
/// > I think the map zoom should change based on vehicle speed. Around town
/// > being more zoomed in would be useful.
///
/// `NavigationCameraPlanner` has always taken the zoom down by 0.8 of a level
/// across 0-30 m/s, from a speed smoothed per fix that falls to zero at every
/// stop. A town ride therefore sat at almost the same scale as an A road, and the
/// scale pumped whenever a junction dragged the speed down. This file is the
/// replacement, in two pure parts: [NavigationSpeedZoom] says what zoom a speed
/// calls for, and [NavigationZoomGovernor] decides when the camera is allowed to
/// act on it.
///
/// Both work in **zoom offsets**: levels added to the planner's base zoom for the
/// orientation (14.65 portrait, 14.15 landscape). A level is a factor of two in
/// scale on either renderer, so the same offset means the same on MapLibre and on
/// `flutter_map` whatever their tile sizes.

/// At or below this speed the camera is as close as it goes: crawling, a
/// junction, a town centre. 15 mph.
const double navigationZoomTownSpeedMetersPerSecond = 6.7;

/// At or above this speed the camera is as far out as it goes: the open road
/// and the motorway. 65 mph. Further out only shrinks the near field.
const double navigationZoomOpenRoadSpeedMetersPerSecond = 29;

/// Levels in from the base zoom at town speed. 15.55 in portrait, which on a
/// tilted map shows a few streets either side of the rider.
const double navigationZoomTownOffset = 0.9;

/// Levels out from the base zoom at open-road speed. The same 0.8 the planner
/// always used for its fastest framing, so the far end of the range is not new.
const double navigationZoomOpenRoadOffset = -0.8;

/// How the speed that picks the zoom is filtered. Slowing down is believed
/// slowly and speeding up quickly: a rider who has slowed for a junction is
/// about to speed up again, and a rider pulling onto a fast road wants the view
/// to open at once.
const double navigationZoomSpeedRiseSeconds = 4;
const double navigationZoomSpeedFallSeconds = 10;

/// Below this speed the rider is stopped, and nothing about the zoom moves: not
/// the filtered speed, not the dwell clock, not the camera. A red light says
/// nothing about the road ahead.
const double navigationZoomStoppedBelowMetersPerSecond = 1;

/// The zoom has to want to move at least this far before it does, so a speed
/// wandering around a threshold changes nothing.
const double navigationZoomDeadbandLevels = 0.2;

/// How long the zoom has to have wanted to come **in** by more than the
/// deadband, while moving, before it does. Zooming out is not delayed. A
/// junction slow-down is over before this runs out; leaving a motorway for a
/// town is not. Both the filtered speed and the speed of the fix itself have to
/// want it for the clock to run.
const double navigationZoomInDwellSeconds = 8;

/// The fastest the zoom moves once it moves, in levels a second: a whole range
/// takes about eleven seconds, which reads as the view settling, not jumping.
const double navigationZoomMaximumRateLevelsPerSecond = 0.15;

/// A gap between two fixes longer than this is treated as this long, so a
/// signal drop does not make one step as large as the whole range.
const double navigationZoomMaximumStepSeconds = 3;

/// The zoom a speed calls for, before any smoothing.
abstract final class NavigationSpeedZoom {
  /// The offset from the base zoom for [speedMetersPerSecond].
  ///
  /// Flat at both ends and a smoothstep between them, so the value and its
  /// gradient are continuous at the thresholds and nothing snaps as the rider
  /// crosses one. Monotonic: faster is never closer. An unknown or non-finite
  /// speed is read as stopped, as the planner already reads it.
  static double offsetFor(double? speedMetersPerSecond) {
    final speed = speedMetersPerSecond;
    if (speed == null || !speed.isFinite) return navigationZoomTownOffset;
    final t =
        ((speed - navigationZoomTownSpeedMetersPerSecond) /
                (navigationZoomOpenRoadSpeedMetersPerSecond -
                    navigationZoomTownSpeedMetersPerSecond))
            .clamp(0.0, 1.0);
    final eased = t * t * (3 - 2 * t);
    return navigationZoomTownOffset * (1 - eased) +
        navigationZoomOpenRoadOffset * eased;
  }
}

/// Decides when the follow camera acts on [NavigationSpeedZoom].
///
/// Feed it one speed per location fix with [update]; read the zoom to command
/// from [offset]. It is a plain object with the clock passed in, so a ride can
/// be replayed through it in a test.
///
/// What it does, in order, for each fix:
///
/// 1. **Filters the speed**, asymmetrically ([navigationZoomSpeedRiseSeconds],
///    [navigationZoomSpeedFallSeconds]).
/// 2. **Holds still when stopped**, so a light changes nothing.
/// 3. **Ignores a small want**: a change of less than
///    [navigationZoomDeadbandLevels] is not made.
/// 4. **Waits before coming in**: a want to zoom in must last
///    [navigationZoomInDwellSeconds] of moving time, and the current fix has to
///    share it. A want to zoom out does not wait.
/// 5. **Moves at a bounded rate**, and once moving carries on to the target
///    rather than stopping a deadband short of it.
class NavigationZoomGovernor {
  double _offset = 0;
  double? _filteredSpeed;
  DateTime? _lastAt;
  bool _settling = false;
  double _wantsInSeconds = 0;

  /// Levels to add to the planner's base zoom. Zero until the first speed has
  /// been seen, which is the planner's own resting zoom.
  double get offset => _offset;

  /// Whether a speed has been seen yet.
  bool get hasObservation => _filteredSpeed != null;

  /// The filtered speed the zoom is following, for diagnostics and tests.
  double? get filteredSpeedMetersPerSecond => _filteredSpeed;

  /// Forgets everything, so the next speed starts afresh.
  void reset() {
    _offset = 0;
    _filteredSpeed = null;
    _lastAt = null;
    _settling = false;
    _wantsInSeconds = 0;
  }

  /// Takes one fix's [speedMetersPerSecond] observed at [at] and returns the
  /// offset to command. A non-finite speed is no information and changes
  /// nothing.
  double update({required double speedMetersPerSecond, required DateTime at}) {
    if (!speedMetersPerSecond.isFinite) return _offset;
    final speed = speedMetersPerSecond.clamp(0.0, 50.0);
    final previous = _lastAt;
    if (previous == null || _filteredSpeed == null) {
      // The first speed is taken as it is. Easing in from an arbitrary default
      // would zoom a rider the wrong way for ten seconds at the start.
      _lastAt = at;
      _filteredSpeed = speed;
      _offset = NavigationSpeedZoom.offsetFor(speed);
      return _offset;
    }
    final elapsed = at.difference(previous).inMicroseconds / 1e6;
    // A fix out of order or on the same instant tells nothing new.
    if (elapsed <= 0) return _offset;
    _lastAt = at;
    final step = math.min(elapsed, navigationZoomMaximumStepSeconds);

    if (speed < navigationZoomStoppedBelowMetersPerSecond) return _offset;

    final filtered = _filteredSpeed!;
    final seconds = speed > filtered
        ? navigationZoomSpeedRiseSeconds
        : navigationZoomSpeedFallSeconds;
    final next =
        filtered + (speed - filtered) * (1 - math.exp(-step / seconds));
    _filteredSpeed = next;

    final target = NavigationSpeedZoom.offsetFor(next);
    final gap = target - _offset;
    if (!_settling) {
      if (gap.abs() < navigationZoomDeadbandLevels) {
        _wantsInSeconds = 0;
        return _offset;
      }
      if (gap > 0) {
        // The slow filter alone would go on wanting to come in for as long as it
        // takes to recover from a dip, long after the rider has speeded up
        // again, so the speed this fix reports has to want it too.
        final wantedNow = NavigationSpeedZoom.offsetFor(speed) - _offset;
        if (wantedNow < navigationZoomDeadbandLevels) {
          _wantsInSeconds = 0;
          return _offset;
        }
        _wantsInSeconds += step;
        if (_wantsInSeconds < navigationZoomInDwellSeconds) return _offset;
      }
      _settling = true;
    }
    _wantsInSeconds = 0;
    final limit = navigationZoomMaximumRateLevelsPerSecond * step;
    _offset += gap.clamp(-limit, limit);
    if ((target - _offset).abs() < 0.01) {
      _offset = target;
      _settling = false;
    }
    return _offset;
  }
}
