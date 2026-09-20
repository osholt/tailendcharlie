import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../domain/imported_route.dart';
import '../../services/basemap_configuration.dart';
import '../../services/route_correction.dart';
import '../../services/road_routing.dart';
import 'resolved_route_map_preview.dart';

class RouteCorrectionScreen extends StatefulWidget {
  const RouteCorrectionScreen({
    super.key,
    required this.source,
    required this.basemapConfiguration,
    this.router,
  });
  final ImportedRoute source;
  final BasemapConfiguration basemapConfiguration;
  final RoadRoutingService? router;
  static Future<ImportedRoute?> show(
    BuildContext context, {
    required ImportedRoute source,
    required BasemapConfiguration basemapConfiguration,
  }) => Navigator.of(context).push<ImportedRoute>(
    MaterialPageRoute(
      builder: (_) => RouteCorrectionScreen(
        source: source,
        basemapConfiguration: basemapConfiguration,
      ),
    ),
  );
  @override
  State<RouteCorrectionScreen> createState() => _RouteCorrectionScreenState();
}

class _RouteCorrectionScreenState extends State<RouteCorrectionScreen> {
  late ImportedRoute _draft = RouteCorrection.copyOf(widget.source);
  late final _name = TextEditingController(text: _draft.name);
  final _client = http.Client();
  late final RoadRoutingService _router =
      widget.router ??
      PreferenceAwareRoadRoutingService(
        osrm: OsrmRoadRoutingService(
          client: _client,
          baseUrl: RoutingConfiguration.fromEnvironment().routingBaseUrl,
        ),
        motorcycle: ValhallaMotorcycleRoutingService(
          client: _client,
          routeUrl: RoutingConfiguration.fromEnvironment().motorcycleRoutingUrl,
        ),
      );
  final _undo = <ImportedRoute>[];
  int? _first, _last;
  bool _busy = false;
  String? _error;
  List<GeoPoint> get _points =>
      _draft.paths.expand((path) => path.points).toList();
  bool get _selected => _first != null && _last != null && _first != _last;
  void _select(int index) {
    if (_busy || index >= _points.length) return;
    setState(() {
      if (_first == null || _last != null) {
        _first = index;
        _last = null;
      } else {
        _last = math.max(_first!, index);
        _first = math.min(_first!, index);
      }
    });
  }

  void _apply(ImportedRoute next) {
    setState(() {
      _undo.add(_draft);
      if (_undo.length > 20) _undo.removeAt(0);
      _draft = next;
      _first = _last = null;
      _error = null;
    });
  }

  Future<void> _replace() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final next = await RouteCorrection.replaceSection(
        _draft,
        _first!,
        _last!,
        _router,
      );
      if (mounted) _apply(next);
    } on Object catch (error) {
      if (mounted) {
        setState(
          () => _error = error is FormatException
              ? error.message.toString()
              : 'Could not route this section. Connect to the internet and retry.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _client.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final points = _points;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Make a corrected copy'),
        actions: [
          TextButton(
            key: const Key('save-corrected-copy'),
            onPressed: _busy
                ? null
                : () {
                    if (_name.text.trim().isEmpty) {
                      setState(() => _error = 'Give the copy a name.');
                      return;
                    }
                    Navigator.pop(
                      context,
                      _draft.withLibraryDetails(name: _name.text.trim()),
                    );
                  },
            child: const Text('Save copy'),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ResolvedRouteMapPreview(
              paths: [for (final path in _draft.paths) path.points],
              basemapConfiguration: widget.basemapConfiguration,
              onPointTap: _select,
              preserveCameraOnUpdate: true,
              pins: [
                if (_first case final index?)
                  RoutePreviewPin(
                    point: points[index],
                    kind: 'start',
                    label: 'A',
                    includeInFraming: false,
                  ),
                if (_last case final index?)
                  RoutePreviewPin(
                    point: points[index],
                    kind: 'finish',
                    label: 'B',
                    includeInFraming: false,
                  ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 290),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: _name,
                      decoration: const InputDecoration(labelText: 'Copy name'),
                      maxLength: 120,
                    ),
                    const Text(
                      'Your original ride and timings stay unchanged. Tap the track before and after a wrong turn, then replace that section by road. Zoom in to separate overlapping points.',
                    ),
                    Text(
                      _selected
                          ? 'Section A–B selected. Check the new line before saving.'
                          : _first == null
                          ? 'Tap the first point on the track.'
                          : 'Now tap the end of the section.',
                    ),
                    if (_busy) const LinearProgressIndicator(),
                    if (_error case final error?)
                      Text(
                        error,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    Wrap(
                      spacing: 8,
                      children: [
                        FilledButton(
                          onPressed: _selected && !_busy ? _replace : null,
                          child: const Text('Replace section by road'),
                        ),
                        TextButton(
                          onPressed: _selected && !_busy
                              ? () => _apply(
                                  RouteCorrection.trim(_draft, _first!, _last!),
                                )
                              : null,
                          child: const Text('Trim to selection'),
                        ),
                        TextButton(
                          onPressed: _busy
                              ? null
                              : () => _apply(RouteCorrection.tidy(_draft)),
                          child: const Text('Remove stationary wander'),
                        ),
                        TextButton(
                          onPressed: _busy || _undo.isEmpty
                              ? null
                              : () => setState(() {
                                  _draft = _undo.removeLast();
                                  _first = _last = null;
                                  _error = null;
                                }),
                          child: const Text('Undo'),
                        ),
                        if (_first != null)
                          TextButton(
                            onPressed: _busy
                                ? null
                                : () => setState(() {
                                    _first = _last = null;
                                  }),
                            child: const Text('Clear selection'),
                          ),
                      ],
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
}
