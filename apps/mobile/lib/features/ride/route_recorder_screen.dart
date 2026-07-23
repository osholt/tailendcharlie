import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../controllers/route_recorder_controller.dart';
import '../../domain/imported_route.dart' show GeoPoint;
import '../../domain/recorded_route_store.dart';
import '../../services/basemap_configuration.dart';
import '../map/resolved_route_map_preview.dart';
import 'route_sketch.dart';

const _surface = Color(0xFF171D25);
const _muted = Color(0xFF8D98A7);

enum _Phase { recording, review }

/// Records a GPS track ahead of a ride, lets the leader preview/trim it,
/// name it, and save it to [store] for use when creating a ride later.
///
/// Returns true via [Navigator.pop] if a recording was saved.
class RouteRecorderScreen extends StatefulWidget {
  const RouteRecorderScreen({
    super.key,
    required this.store,
    this.controller,
    this.basemapConfiguration = const BasemapConfiguration(),
    this.mapStyleString,
  });

  final RecordedRouteStore store;
  final RouteRecorderController? controller;
  final BasemapConfiguration basemapConfiguration;
  final String? mapStyleString;

  static Future<bool> show(
    BuildContext context,
    RecordedRouteStore store, {
    BasemapConfiguration? basemapConfiguration,
    String? mapStyleString,
  }) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => RouteRecorderScreen(
          store: store,
          basemapConfiguration:
              basemapConfiguration ??
              BasemapConfiguration.fromEnvironment().forBrightness(dark: true),
          mapStyleString: mapStyleString,
        ),
      ),
    );
    return saved ?? false;
  }

  @override
  State<RouteRecorderScreen> createState() => _RouteRecorderScreenState();
}

class _RouteRecorderScreenState extends State<RouteRecorderScreen> {
  static const _tapHitRadius = 24.0;

  late final RouteRecorderController _controller;
  final _nameController = TextEditingController();
  _Phase _phase = _Phase.recording;
  RangeValues? _trimRange;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = widget.controller ?? RouteRecorderController();
    _controller.addListener(_onControllerChanged);
  }

  void _onControllerChanged() => setState(() {});

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    if (widget.controller == null) _controller.dispose();
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Record a route')),
    body: SafeArea(
      child: _saving
          ? const Center(child: CircularProgressIndicator())
          : _phase == _Phase.recording
          ? _buildRecording(context)
          : _buildReview(context),
    ),
  );

  Widget _buildRecording(BuildContext context) {
    final state = _controller.state;
    final points = [
      for (final sample in _controller.samples)
        GeoPoint(
          latitude: sample.position.latitude,
          longitude: sample.position.longitude,
        ),
    ];
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: _surface,
                borderRadius: BorderRadius.circular(20),
              ),
              padding: const EdgeInsets.all(20),
              child: widget.basemapConfiguration.usesMapLibre
                  ? Stack(
                      children: [
                        Positioned.fill(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: ResolvedRouteMapPreview(
                              paths: points.isEmpty ? const [] : [points],
                              basemapConfiguration: widget.basemapConfiguration,
                              mapStyleString: widget.mapStyleString,
                              lineColor: '#FF7A1A',
                            ),
                          ),
                        ),
                        if (points.length < 2)
                          Center(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: const Color(0xD9111820),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Text(
                                  state == RouteRecorderState.idle
                                      ? 'Start recording to trace your route.'
                                      : 'Waiting for a GPS fix…',
                                  style: const TextStyle(color: _muted),
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            ),
                          ),
                      ],
                    )
                  : points.length >= 2
                  ? CustomPaint(
                      size: Size.infinite,
                      painter: RouteSketchPainter(normalizeRoutePoints(points)),
                    )
                  : Center(
                      child: Text(
                        state == RouteRecorderState.idle
                            ? 'Start recording to trace your route.'
                            : 'Waiting for a GPS fix…',
                        style: const TextStyle(color: _muted),
                        textAlign: TextAlign.center,
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _Stat(label: 'Time', value: _formatDuration(_controller.elapsed)),
              _Stat(
                label: 'Distance',
                value:
                    '${(_controller.distanceMeters / 1000).toStringAsFixed(1)} km',
              ),
              _Stat(label: 'Points', value: '${_controller.pointCount}'),
            ],
          ),
          if (_controller.error case final error?) ...[
            const SizedBox(height: 12),
            Text(error, style: const TextStyle(color: Colors.redAccent)),
          ],
          const SizedBox(height: 20),
          _buildRecordingControls(state),
        ],
      ),
    );
  }

  Widget _buildRecordingControls(RouteRecorderState state) {
    if (state == RouteRecorderState.idle) {
      return FilledButton.icon(
        key: const Key('start-recording-button'),
        onPressed: () => _controller.start(),
        icon: const Icon(Icons.fiber_manual_record),
        label: const Text('Start recording'),
      );
    }
    final canFinish = _controller.pointCount >= 2;
    return Column(
      children: [
        Row(
          children: [
            if (state == RouteRecorderState.recording)
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _controller.pause(),
                  icon: const Icon(Icons.pause),
                  label: const Text('Pause'),
                ),
              )
            else ...[
              Expanded(
                child: OutlinedButton.icon(
                  key: const Key('discard-recording-button'),
                  onPressed: _confirmDiscard,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Discard'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _controller.start(),
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Resume'),
                ),
              ),
            ],
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                key: const Key('finish-recording-button'),
                onPressed: canFinish ? _startReview : null,
                icon: const Icon(Icons.check),
                label: const Text('Finish'),
              ),
            ),
          ],
        ),
        if (_controller.pointCount > 0) ...[
          const SizedBox(height: 8),
          TextButton.icon(
            key: const Key('remove-last-point-button'),
            onPressed: () =>
                _controller.removePoint(_controller.pointCount - 1),
            icon: const Icon(Icons.undo, size: 18),
            label: const Text('Remove last point'),
          ),
        ],
      ],
    );
  }

  Future<void> _confirmDiscard() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Discard this recording?'),
        content: const Text('The route traced so far will be lost.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Keep recording'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      await _controller.discard();
    }
  }

  void _startReview() {
    setState(() {
      _phase = _Phase.review;
      _trimRange = RangeValues(0, (_controller.pointCount - 1).toDouble());
      _error = null;
    });
  }

  Widget _buildReview(BuildContext context) {
    final maxIndex = (_controller.pointCount - 1).toDouble();
    final range = _trimRange ?? RangeValues(0, maxIndex);
    final start = range.start.round();
    final end = range.end.round();
    final points = [
      for (var index = start; index <= end; index += 1)
        GeoPoint(
          latitude: _controller.samples[index].position.latitude,
          longitude: _controller.samples[index].position.longitude,
        ),
    ];
    final normalized = normalizeRoutePoints(points);
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: _surface,
                borderRadius: BorderRadius.circular(20),
              ),
              padding: const EdgeInsets.all(20),
              child: widget.basemapConfiguration.usesMapLibre
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: ResolvedRouteMapPreview(
                        key: const Key('route-sketch-gesture-detector'),
                        paths: [points],
                        basemapConfiguration: widget.basemapConfiguration,
                        mapStyleString: widget.mapStyleString,
                        lineColor: '#FF7A1A',
                        onPointTap: (index) =>
                            _removeDisplayedPoint(index, rangeStart: start),
                      ),
                    )
                  : LayoutBuilder(
                      builder: (context, constraints) => GestureDetector(
                        key: const Key('route-sketch-gesture-detector'),
                        behavior: HitTestBehavior.opaque,
                        onTapUp: (details) => _removeTappedPoint(
                          tapPosition: details.localPosition,
                          canvasSize: constraints.biggest,
                          normalized: normalized,
                          rangeStart: start,
                        ),
                        child: CustomPaint(
                          size: Size.infinite,
                          painter: RouteSketchPainter(normalized),
                        ),
                      ),
                    ),
            ),
          ),
          if (points.length > 2) ...[
            const SizedBox(height: 8),
            const Text(
              'Tap a point on the sketch to remove it.',
              style: TextStyle(color: _muted, fontSize: 12),
            ),
          ],
          const SizedBox(height: 4),
          Text(
            'Trim the start/end if needed (${points.length} of '
            '${_controller.pointCount} points kept).',
            style: const TextStyle(color: _muted),
          ),
          RangeSlider(
            key: const Key('trim-range-slider'),
            min: 0,
            max: maxIndex,
            divisions: maxIndex > 0 ? maxIndex.round() : null,
            values: range,
            onChanged: (value) => setState(() => _trimRange = value),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('recording-name-field'),
            controller: _nameController,
            decoration: const InputDecoration(
              labelText: 'Route name',
              hintText: 'e.g. Peak District loop',
            ),
          ),
          if (_error case final error?) ...[
            const SizedBox(height: 12),
            Text(error, style: const TextStyle(color: Colors.redAccent)),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => setState(() => _phase = _Phase.recording),
                  child: const Text('Back'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  key: const Key('save-recording-button'),
                  onPressed: () => _save(start: start, end: end),
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('Save recording'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Removes whichever displayed point is closest to a tap on the review
  /// sketch, provided it's within [_tapHitRadius] - and keeps the trim
  /// range's start/end pointing at the same surviving points, since
  /// [RouteRecorderController.removePoint] shifts every later sample down
  /// by one index.
  void _removeTappedPoint({
    required Offset tapPosition,
    required Size canvasSize,
    required List<Offset> normalized,
    required int rangeStart,
  }) {
    if (normalized.length <= 2) return;
    var closestIndex = -1;
    var closestDistance = double.infinity;
    for (var index = 0; index < normalized.length; index += 1) {
      final scaled = Offset(
        normalized[index].dx * canvasSize.width,
        normalized[index].dy * canvasSize.height,
      );
      final distance = (scaled - tapPosition).distance;
      if (distance < closestDistance) {
        closestDistance = distance;
        closestIndex = index;
      }
    }
    if (closestIndex == -1 || closestDistance > _tapHitRadius) return;

    _removeDisplayedPoint(closestIndex, rangeStart: rangeStart);
  }

  void _removeDisplayedPoint(int displayedIndex, {required int rangeStart}) {
    final removedIndex = rangeStart + displayedIndex;
    _controller.removePoint(removedIndex);
    final range = _trimRange!;
    final start = range.start.round();
    final end = range.end.round();
    setState(() {
      _trimRange = RangeValues(
        (removedIndex < start ? start - 1 : start).toDouble(),
        (removedIndex <= end ? end - 1 : end).toDouble(),
      );
    });
  }

  Future<void> _save({required int start, required int end}) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final route = _controller.build(
        name: _nameController.text,
        id: const Uuid().v7(),
        start: start,
        end: end,
      );
      if (route == null) {
        setState(() {
          _saving = false;
          _error = 'Select at least two points to save a route.';
        });
        return;
      }
      await widget.store.save(route);
      if (mounted) Navigator.of(context).pop(true);
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Could not save recording: $error';
        });
      }
    }
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Text(
        value,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w800,
          fontSize: 20,
        ),
      ),
      Text(label, style: const TextStyle(color: _muted, fontSize: 12)),
    ],
  );
}

String _formatDuration(Duration duration) {
  final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  final hours = duration.inHours;
  return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
}
