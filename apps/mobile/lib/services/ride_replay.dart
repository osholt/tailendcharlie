import 'package:flutter/foundation.dart';

import '../domain/imported_route.dart';

/// A finished ride's own timed track, laid out on a replay clock (#305).
///
/// Built from [CompletedRide.traveledRoute]: the local rider's recorded path,
/// split into continuous segments wherever location stopped for more than two
/// minutes, with a `recordedAt` on every fix. Nothing else about a ride is kept
/// once it is archived - not the other riders' positions - so this is a replay
/// of one rider's ride and says so.
///
/// The clock runs only while the rider was recorded. A pause in the recording
/// (a signal drop, the phone switched off) is skipped rather than played as a
/// long stand-still, and the position jumps across it; [skippedGaps] says how
/// many such jumps there are so the screen can be honest about them.
class RideReplayTimeline {
  RideReplayTimeline._(this._segments, this.duration);

  /// Null when the route has no timed track to replay: fewer than two
  /// timestamped fixes in any continuous run, or fixes with no times at all
  /// (a ride imported or recorded before times were kept).
  static RideReplayTimeline? fromRoute(ImportedRoute? route) {
    if (route == null) return null;
    final segments = <_Segment>[];
    var start = Duration.zero;
    for (final path in route.paths) {
      if (path.kind != RoutePathKind.track) continue;
      final fixes = <_Fix>[];
      for (final point in path.points) {
        final at = point.recordedAt;
        if (at == null) continue;
        // Out-of-order and repeated times cannot be played forward.
        if (fixes.isNotEmpty && !at.isAfter(fixes.last.at)) continue;
        fixes.add(_Fix(point, at));
      }
      if (fixes.length < 2) continue;
      final length = fixes.last.at.difference(fixes.first.at);
      segments.add(_Segment(start, fixes));
      start += length;
    }
    if (segments.isEmpty) return null;
    return RideReplayTimeline._(List.unmodifiable(segments), start);
  }

  final List<_Segment> _segments;

  /// The length of the replay: the recorded time, gaps excluded.
  final Duration duration;

  /// How many times the recording paused and the replay jumps past it.
  int get skippedGaps => _segments.length - 1;

  /// Where the rider was [offset] into the replay clock, clamped to the ride.
  GeoPoint positionAt(Duration offset) {
    final segment = _segmentAt(offset);
    final fixes = segment.fixes;
    final at = segment.recordedAt(offset);
    // The last fix at or before [at]; the next one is what it moves toward.
    var low = 0;
    var high = fixes.length - 1;
    while (low < high) {
      final middle = (low + high + 1) ~/ 2;
      if (fixes[middle].at.isAfter(at)) {
        high = middle - 1;
      } else {
        low = middle;
      }
    }
    final from = fixes[low];
    if (low == fixes.length - 1) return _plain(from.point);
    final to = fixes[low + 1];
    final span = to.at.difference(from.at).inMicroseconds;
    final fraction = span == 0
        ? 0.0
        : (at.difference(from.at).inMicroseconds / span).clamp(0.0, 1.0);
    return GeoPoint(
      latitude:
          from.point.latitude +
          (to.point.latitude - from.point.latitude) * fraction,
      longitude:
          from.point.longitude +
          (to.point.longitude - from.point.longitude) * fraction,
    );
  }

  /// The time of day, on the day of the ride, that [offset] stands for.
  DateTime clockTimeAt(Duration offset) =>
      _segmentAt(offset).recordedAt(offset);

  _Segment _segmentAt(Duration offset) {
    final clamped = offset < Duration.zero
        ? Duration.zero
        : (offset > duration ? duration : offset);
    for (var index = _segments.length - 1; index >= 0; index -= 1) {
      if (clamped >= _segments[index].start) return _segments[index];
    }
    return _segments.first;
  }

  /// The fix without its time, which is what a marker needs.
  static GeoPoint _plain(GeoPoint point) =>
      GeoPoint(latitude: point.latitude, longitude: point.longitude);
}

class _Fix {
  const _Fix(this.point, this.at);

  final GeoPoint point;
  final DateTime at;
}

class _Segment {
  _Segment(this.start, this.fixes);

  /// Where this run begins on the replay clock.
  final Duration start;
  final List<_Fix> fixes;

  DateTime get firstAt => fixes.first.at;
  DateTime get lastAt => fixes.last.at;

  /// The recorded time at [offset] on the replay clock, kept inside this run.
  DateTime recordedAt(Duration offset) {
    final into = offset - start;
    final capped = into > lastAt.difference(firstAt)
        ? lastAt.difference(firstAt)
        : (into < Duration.zero ? Duration.zero : into);
    return firstAt.add(capped);
  }
}

/// Play, pause, speed and scrub over a [RideReplayTimeline] (#305).
///
/// A plain model with no timer of its own: the screen feeds it elapsed wall
/// time through [advance], which keeps it deterministic to test and means a
/// paused replay costs no frames.
class RideReplayController extends ChangeNotifier {
  RideReplayController(this.timeline, {this._speed = defaultSpeed});

  /// Rides are hours long, so even the slowest choice is faster than real time.
  static const speeds = [10.0, 30.0, 60.0, 120.0];
  static const defaultSpeed = 60.0;

  final RideReplayTimeline timeline;

  Duration _position = Duration.zero;
  bool _playing = false;
  double _speed;

  Duration get position => _position;
  bool get playing => _playing;

  /// Replay seconds per wall-clock second.
  double get speed => _speed;
  bool get finished => _position >= timeline.duration;
  double get progress => timeline.duration == Duration.zero
      ? 0
      : _position.inMicroseconds / timeline.duration.inMicroseconds;
  GeoPoint get location => timeline.positionAt(_position);

  /// Starts, or from the end starts over.
  void play() {
    if (finished) _position = Duration.zero;
    if (_playing) return;
    _playing = true;
    notifyListeners();
  }

  void pause() {
    if (!_playing) return;
    _playing = false;
    notifyListeners();
  }

  void toggle() => _playing ? pause() : play();

  /// Moves to [offset], clamped to the ride. Does not start or stop playback.
  void seek(Duration offset) {
    final clamped = offset < Duration.zero
        ? Duration.zero
        : (offset > timeline.duration ? timeline.duration : offset);
    if (clamped == _position) return;
    _position = clamped;
    notifyListeners();
  }

  void seekToFraction(double fraction) => seek(
    Duration(
      microseconds:
          (timeline.duration.inMicroseconds * fraction.clamp(0.0, 1.0)).round(),
    ),
  );

  void setSpeed(double value) {
    if (value <= 0 || value == _speed) return;
    _speed = value;
    notifyListeners();
  }

  /// Moves the replay on by [wall] of real time at the chosen speed. Does
  /// nothing while paused, and stops by itself at the end.
  void advance(Duration wall) {
    if (!_playing) return;
    final next =
        _position +
        Duration(microseconds: (wall.inMicroseconds * _speed).round());
    if (next >= timeline.duration) {
      _position = timeline.duration;
      _playing = false;
    } else {
      _position = next;
    }
    notifyListeners();
  }
}
