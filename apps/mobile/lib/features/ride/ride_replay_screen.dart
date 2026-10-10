import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../domain/completed_ride.dart';
import '../../domain/imported_route.dart';
import '../../services/ride_replay.dart';

/// Builds the map a replay is drawn on, given the marker to move along it.
///
/// Passed in rather than built here so this screen holds no platform map: the
/// ride-history map owns that, and a widget test can stand a placeholder in.
typedef ReplayMapBuilder =
    Widget Function(BuildContext context, ValueListenable<GeoPoint?> position);

/// Replays a finished ride's own recorded track: play, pause, speed and scrub
/// (#305).
///
/// One rider's ride only. Once a ride is archived the app keeps this phone's
/// timed track and nothing of the other riders', so this cannot show where the
/// group was, and the screen says so rather than implying it.
class RideReplayScreen extends StatefulWidget {
  const RideReplayScreen({
    super.key,
    required this.ride,
    required this.timeline,
    required this.mapBuilder,
  });

  final CompletedRide ride;
  final RideReplayTimeline timeline;
  final ReplayMapBuilder mapBuilder;

  @override
  State<RideReplayScreen> createState() => _RideReplayScreenState();
}

class _RideReplayScreenState extends State<RideReplayScreen>
    with SingleTickerProviderStateMixin {
  late final RideReplayController _replay = RideReplayController(
    widget.timeline,
  );
  late final ValueNotifier<GeoPoint?> _marker = ValueNotifier(_replay.location);
  late final Ticker _ticker;
  Duration _lastElapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    // Made here, not lazily: a ticker first asked for in dispose() is created on
    // a deactivated element.
    _ticker = createTicker(_onTick);
    _replay.addListener(_onReplayChanged);
  }

  @override
  void dispose() {
    _replay.removeListener(_onReplayChanged);
    _ticker.dispose();
    _replay.dispose();
    _marker.dispose();
    super.dispose();
  }

  void _onTick(Duration elapsed) {
    final delta = elapsed - _lastElapsed;
    _lastElapsed = elapsed;
    _replay.advance(delta);
  }

  /// The ticker runs only while playing, so a paused replay costs no frames.
  void _onReplayChanged() {
    _marker.value = _replay.location;
    if (_replay.playing && !_ticker.isActive) {
      _lastElapsed = Duration.zero;
      _ticker.start();
    } else if (!_replay.playing && _ticker.isActive) {
      _ticker.stop();
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final timeline = widget.timeline;
    const tabular = TextStyle(fontFeatures: [FontFeature.tabularFigures()]);
    final play = IconButton.filled(
      key: const Key('replay-play-pause'),
      tooltip: _replay.playing
          ? 'Pause'
          : _replay.finished
          ? 'Replay from the start'
          : 'Play',
      onPressed: _replay.toggle,
      icon: Icon(
        _replay.playing
            ? Icons.pause
            : _replay.finished
            ? Icons.replay
            : Icons.play_arrow,
      ),
    );
    final elapsed = Text(
      _clock(_replay.position),
      key: const Key('replay-elapsed'),
      style: tabular,
    );
    final scrubber = Slider(
      key: const Key('replay-scrubber'),
      value: _replay.progress.clamp(0.0, 1.0),
      onChanged: _replay.seekToFraction,
    );
    final total = Text(
      _clock(timeline.duration),
      key: const Key('replay-total'),
      style: tabular,
    );
    // The time of day it was, beside a clock so it is not read as a duration.
    final timeOfDay = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.schedule, size: 15, color: Color(0xFFA9B4C2)),
        const SizedBox(width: 4),
        Text(
          _timeOfDay(timeline.clockTimeAt(_replay.position)),
          key: const Key('replay-time-of-day'),
          style: const TextStyle(color: Color(0xFFA9B4C2)),
        ),
      ],
    );
    // Scales down rather than overflowing on a narrow phone or at a large text
    // size.
    final speed = FittedBox(
      fit: BoxFit.scaleDown,
      child: SegmentedButton<double>(
        key: const Key('replay-speed'),
        showSelectedIcon: false,
        style: const ButtonStyle(visualDensity: VisualDensity.compact),
        segments: [
          for (final value in RideReplayController.speeds)
            ButtonSegment(value: value, label: Text('${value.round()}×')),
        ],
        selected: {_replay.speed},
        onSelectionChanged: (selection) => _replay.setSpeed(selection.single),
      ),
    );
    return Scaffold(
      appBar: AppBar(
        title: Text('Replay · ${widget.ride.title}', maxLines: 1),
        toolbarHeight: landscape ? 42 : null,
      ),
      body: Column(
        children: [
          Expanded(child: widget.mapBuilder(context, _marker)),
          Material(
            color: const Color(0xFF17212B),
            child: SafeArea(
              top: false,
              child: Padding(
                padding: EdgeInsets.fromLTRB(16, landscape ? 2 : 8, 16, 8),
                // Turned on its side the whole control is one row, so the map
                // keeps the height; upright there is room for two and a note.
                child: landscape
                    ? Row(
                        children: [
                          play,
                          const SizedBox(width: 10),
                          elapsed,
                          Expanded(child: scrubber),
                          total,
                          const SizedBox(width: 14),
                          timeOfDay,
                          const SizedBox(width: 14),
                          Flexible(child: speed),
                        ],
                      )
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              play,
                              const SizedBox(width: 10),
                              elapsed,
                              Expanded(child: scrubber),
                              total,
                            ],
                          ),
                          Row(
                            children: [
                              timeOfDay,
                              const SizedBox(width: 12),
                              Expanded(
                                child: Align(
                                  alignment: Alignment.centerRight,
                                  child: speed,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            key: const Key('replay-note'),
                            _note(timeline),
                            style: const TextStyle(
                              color: Color(0xFFA9B4C2),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// What this replay is and is not, in the words a rider would need.
  static String _note(RideReplayTimeline timeline) {
    final gaps = timeline.skippedGaps;
    return 'Your own recorded track at the ride\'s real pace, sped up. '
        'Other riders are not kept once a ride ends.'
        '${gaps == 0 ? '' : ' Recording paused ${gaps == 1 ? 'once' : '$gaps times'}; '
                  'the replay skips ${gaps == 1 ? 'it' : 'them'}.'}';
  }

  static String _clock(Duration value) {
    final hours = value.inHours;
    final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours == 0 ? '$minutes:$seconds' : '$hours:$minutes:$seconds';
  }

  static String _timeOfDay(DateTime value) {
    final local = value.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }
}
