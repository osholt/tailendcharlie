import 'package:flutter/material.dart';

import '../../domain/distance_unit.dart';
import '../../domain/imported_route.dart' show GeoPoint;
import '../../services/measurement_formatter.dart';
import '../../services/stored_route_library.dart';
import '../ride/route_sketch.dart';
import 'route_review_screen.dart' show routeLengthMeters;

/// Picks a route out of the geometry already on this phone.
///
/// This exists so the data the app already holds is a route source in its own
/// right. A rider who has just ridden a route, or deliberately recorded one, no
/// longer has to export a GPX and import it back to ride it again (#155).
///
/// It hands back a [StoredRouteSelection] and nothing else: building geometry
/// and activating a route stay with the map, which owns the route pipeline.
class StoredRoutePickerScreen extends StatefulWidget {
  const StoredRoutePickerScreen({
    super.key,
    required this.library,
    required this.distanceUnit,
  });

  final StoredRouteLibrary library;
  final DistanceUnit distanceUnit;

  static Future<StoredRouteSelection?> show(
    BuildContext context, {
    required StoredRouteLibrary library,
    required DistanceUnit distanceUnit,
  }) => Navigator.of(context).push<StoredRouteSelection>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) =>
          StoredRoutePickerScreen(library: library, distanceUnit: distanceUnit),
    ),
  );

  @override
  State<StoredRoutePickerScreen> createState() =>
      _StoredRoutePickerScreenState();
}

class _StoredRoutePickerScreenState extends State<StoredRoutePickerScreen> {
  late final Future<List<StoredRouteCandidate>> _candidates = widget.library
      .list();

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Use a saved route')),
    body: FutureBuilder<List<StoredRouteCandidate>>(
      future: _candidates,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _Message(
            title: 'Could not read saved routes',
            body: '${snapshot.error}',
          );
        }
        final candidates = snapshot.data;
        if (candidates == null) {
          return const Center(child: CircularProgressIndicator());
        }
        if (candidates.isEmpty) return const _EmptyLibrary();
        final recordings = candidates
            .where(
              (candidate) =>
                  candidate.origin == StoredRouteOrigin.recordedRoute,
            )
            .toList(growable: false);
        final rides = candidates
            .where(
              (candidate) =>
                  candidate.origin != StoredRouteOrigin.recordedRoute,
            )
            .toList(growable: false);
        return ListView(
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 28),
          children: [
            const Text(
              'Routes already on this phone. No file, no export step, and '
              'nothing leaves the phone to use one.',
              style: TextStyle(color: Color(0xFFABB5C1), height: 1.4),
            ),
            if (recordings.isNotEmpty) ...[
              const _SectionHeading('Recorded routes'),
              for (final candidate in recordings) _tile(candidate),
            ],
            if (rides.isNotEmpty) ...[
              const _SectionHeading('Previous rides'),
              for (final candidate in rides) _tile(candidate),
            ],
          ],
        );
      },
    ),
  );

  Widget _tile(StoredRouteCandidate candidate) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: StoredRouteCandidateTile(
      candidate: candidate,
      distanceUnit: widget.distanceUnit,
      onTap: () => _chooseOptions(candidate),
    ),
  );

  Future<void> _chooseOptions(StoredRouteCandidate candidate) async {
    final selection = await showModalBottomSheet<StoredRouteSelection>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => StoredRouteOptionsSheet(
        candidate: candidate,
        distanceUnit: widget.distanceUnit,
      ),
    );
    if (selection == null || !mounted) return;
    Navigator.of(context).pop(selection);
  }
}

/// One choosable stored route: its shape, what it is, when it was ridden and
/// how far it goes. A list of dates is not choosable.
class StoredRouteCandidateTile extends StatelessWidget {
  const StoredRouteCandidateTile({
    super.key,
    required this.candidate,
    required this.distanceUnit,
    required this.onTap,
  });

  final StoredRouteCandidate candidate;
  final DistanceUnit distanceUnit;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      key: Key('stored-route-candidate-${candidate.id}'),
      contentPadding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      leading: SizedBox.square(
        dimension: 52,
        child: StoredRouteShapePreview(candidate: candidate),
      ),
      title: Text(candidate.title),
      subtitle: Text(
        '${storedRouteKindLabel(candidate.origin)} · '
        '${_date(candidate.storedAt)}\n'
        '${MeasurementFormatter(distanceUnit).distance(routeLengthMeters(candidate.geometry))} · '
        '${candidate.pointCount} points'
        '${candidate.rideCode == null ? '' : ' · ride ${candidate.rideCode}'}',
      ),
      isThreeLine: true,
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    ),
  );
}

/// A map-free thumbnail of the route's shape, drawn from the geometry already
/// in memory. Cheap enough for a list: no tiles, no network, and a subsample
/// rather than every recorded fix.
class StoredRouteShapePreview extends StatelessWidget {
  const StoredRouteShapePreview({super.key, required this.candidate});

  static const _maximumPreviewPoints = 120;

  final StoredRouteCandidate candidate;

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: RouteSketchPainter(
      normalizeRoutePoints(_points()),
      strokeWidth: 2.5,
    ),
    child: const SizedBox.expand(),
  );

  List<GeoPoint> _points() {
    final longest = candidate.geometry.paths.fold<List<GeoPoint>>(
      const [],
      (best, path) => path.points.length > best.length ? path.points : best,
    );
    if (longest.length <= _maximumPreviewPoints) return longest;
    return List.generate(
      _maximumPreviewPoints,
      (index) =>
          longest[(index * (longest.length - 1) / (_maximumPreviewPoints - 1))
              .round()],
      growable: false,
    );
  }
}

/// States plainly which version of a recording the rider is about to ride, and
/// which direction it runs in.
class StoredRouteOptionsSheet extends StatefulWidget {
  const StoredRouteOptionsSheet({
    super.key,
    required this.candidate,
    required this.distanceUnit,
  });

  final StoredRouteCandidate candidate;
  final DistanceUnit distanceUnit;

  @override
  State<StoredRouteOptionsSheet> createState() =>
      _StoredRouteOptionsSheetState();
}

class _StoredRouteOptionsSheetState extends State<StoredRouteOptionsSheet> {
  StoredRouteVariant _variant = StoredRouteVariant.tidied;
  bool _reversed = false;

  @override
  Widget build(BuildContext context) {
    final candidate = widget.candidate;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              candidate.title,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 4),
            Text(
              '${storedRouteKindLabel(candidate.origin)} · '
              '${_date(candidate.storedAt)} · '
              '${MeasurementFormatter(widget.distanceUnit).distance(routeLengthMeters(candidate.geometry))}',
              style: const TextStyle(color: Color(0xFF98A3B1)),
            ),
            const SizedBox(height: 16),
            if (candidate.isRecording) ...[
              SegmentedButton<StoredRouteVariant>(
                key: const Key('stored-route-variant'),
                segments: const [
                  ButtonSegment(
                    value: StoredRouteVariant.tidied,
                    label: Text('Tidied'),
                  ),
                  ButtonSegment(
                    value: StoredRouteVariant.raw,
                    label: Text('Raw track'),
                  ),
                ],
                selected: {_variant},
                onSelectionChanged: (selection) =>
                    setState(() => _variant = selection.single),
              ),
              const SizedBox(height: 10),
              Text(
                _variant == StoredRouteVariant.tidied
                    ? 'Tidied: a recording, not a planned route. Stops and GPS '
                          'wander are removed. Every road the bike actually '
                          'took is kept, including any wrong turns and car '
                          'park loops.'
                    : 'Raw track: every fix exactly as recorded, including '
                          'stops, GPS wander and any wrong turns.',
                style: const TextStyle(color: Color(0xFF98A3B1), height: 1.4),
              ),
            ] else
              const Text(
                'This is the route that ride was planned with, so it is used '
                'exactly as it was planned.',
                style: TextStyle(color: Color(0xFF98A3B1), height: 1.4),
              ),
            const SizedBox(height: 6),
            SwitchListTile(
              key: const Key('stored-route-reverse'),
              contentPadding: EdgeInsets.zero,
              value: _reversed,
              onChanged: (value) => setState(() => _reversed = value),
              title: const Text('Ride it in reverse'),
              subtitle: Text(
                _reversed
                    ? 'Runs from the original finish to the original start. '
                          'Turn instructions from the original direction are '
                          'dropped.'
                    : 'Runs in the direction it was ridden.',
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              key: const Key('use-stored-route'),
              onPressed: () => Navigator.of(context).pop(
                StoredRouteSelection(
                  candidate: candidate,
                  variant: _variant,
                  reversed: _reversed,
                ),
              ),
              icon: const Icon(Icons.route_outlined),
              label: const Text('Use this route'),
            ),
          ],
        ),
      ),
    );
  }
}

String storedRouteKindLabel(StoredRouteOrigin origin) => switch (origin) {
  StoredRouteOrigin.recordedRoute => 'Recorded route',
  StoredRouteOrigin.previousRidePlan => 'Previous ride · planned route',
  StoredRouteOrigin.previousRideTrack => 'Previous ride · recorded track',
};

class _SectionHeading extends StatelessWidget {
  const _SectionHeading(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 20, bottom: 10),
    child: Text(
      label.toUpperCase(),
      style: const TextStyle(
        color: Color(0xFF8994A2),
        fontSize: 11,
        fontWeight: FontWeight.w800,
        letterSpacing: 0.9,
      ),
    ),
  );
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary();

  @override
  Widget build(BuildContext context) => const _Message(
    title: 'No saved routes yet',
    body:
        'Record one with "Record a route" on the home screen, or finish a ride '
        'and it will appear here. A ride whose geometry has been deleted is '
        'not listed, because there is nothing left to ride.',
  );
}

class _Message extends StatelessWidget {
  const _Message({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.route_outlined, size: 52, color: Color(0xFF7F8A98)),
          const SizedBox(height: 16),
          Text(
            title,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          Text(
            body,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Color(0xFFABB5C1), height: 1.4),
          ),
        ],
      ),
    ),
  );
}

String _date(DateTime value) {
  final local = value.toLocal();
  return '${local.day.toString().padLeft(2, '0')}/'
      '${local.month.toString().padLeft(2, '0')}/${local.year}';
}
